-- 07-issue-lifecycle (schema lock: issue_category, machine_issue, issue_action, issue_ownership_history, attachment, Storage bucket `attachments`).
-- Machine issues with an append-only history, tenant-private photo attachments and the in-app alerts that read them. Clients read the tables under
-- RLS (Unit Admins read the issue tables, every member reads categories); every write goes through public.iss_* RPC functions.
-- The RPCs are iss_* (not pm_* / sh_*): 04's test 011 pins the number of pm_* RPCs. One file, written step by step:
-- 1 tables, 2 write RPCs, 3 attachments + Storage, 4 reads.
--
-- Status transitions (D5), enforced by each RPC (anything else -> guard `invalid_status`):
--   open        -> in_progress  iss_start
--   open|in_progress -> closed      iss_resolve (low / medium)
--   open|in_progress -> resolved    iss_resolve (high / critical; awaits verification by a later-shift owner)
--   resolved    -> closed       iss_verify(confirm)
--   resolved    -> in_progress  iss_verify(reject; the rejecting supervisor becomes accountable)
--   closed      -> in_progress  iss_reopen (Unit Admin)

-- 1. Audit actions -------------------------------------------------------------------------------------------
insert into app.audit_action (action, feature) values
  ('issue.reported', '07'), ('issue.noted', '07'), ('issue.started', '07'), ('issue.assignee_set', '07'),
  ('issue.escalated', '07'), ('issue.escalation_acknowledged', '07'), ('issue.reassigned', '07'),
  ('issue.resolved', '07'), ('issue.verified', '07'), ('issue.verification_rejected', '07'), ('issue.reopened', '07'),
  ('issue_category.created', '07'), ('issue_category.updated', '07'), ('issue_category.retired', '07'), ('issue_category.reinstated', '07'),
  ('attachment.added', '07');

-- 2. Tables ------------------------------------------------------------------------------------------------------
-- Every child carries (tenant_id, parent_id) with a composite FK to the parent's (tenant_id, id), so a row can never reference another
-- tenant's parent. User ids (reporter, owner, resolver ...) have no FK on purpose: history outlives the membership; a trigger checks the tenant.
create table public.issue_category (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  name text not null check (name = btrim(name) and length(name) between 1 and 40),
  sort integer not null default 100,
  retired_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint issue_category_tenant_id_key unique (tenant_id, id)
);
create unique index issue_category_tenant_name_key on public.issue_category (tenant_id, lower(name));

-- Current state of an issue. Changed ONLY by the iss_* RPCs (no privilege for any client role).
create table public.machine_issue (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  machine_id uuid not null,
  category_id uuid not null,
  priority text not null check (priority in ('low', 'medium', 'high', 'critical')),
  description text not null check (description = btrim(description) and length(description) between 1 and 1000),
  machine_stopped boolean not null default false,
  status text not null default 'open' check (status in ('open', 'in_progress', 'resolved', 'closed')),
  escalated_at timestamptz,
  accountable_owner_id uuid,
  technical_assignee text check (technical_assignee = btrim(technical_assignee) and length(technical_assignee) between 1 and 80),
  reported_by uuid not null,
  reported_at timestamptz not null default now(),
  reported_shift_id uuid,
  reported_shift_date date,
  resolved_by uuid,
  resolved_at timestamptz,
  resolved_shift_id uuid,
  resolved_shift_date date,
  resolution_notes text check (resolution_notes = btrim(resolution_notes) and length(resolution_notes) between 1 and 1000),
  closed_at timestamptz,
  closed_by uuid,
  updated_at timestamptz not null default now(),
  constraint machine_issue_tenant_id_key unique (tenant_id, id),
  constraint machine_issue_machine_fk foreign key (tenant_id, machine_id) references public.machine (tenant_id, id) on delete restrict,
  constraint machine_issue_category_fk foreign key (tenant_id, category_id) references public.issue_category (tenant_id, id) on delete restrict,
  constraint machine_issue_reported_shift_fk foreign key (tenant_id, reported_shift_id) references public.shift (tenant_id, id) on delete restrict,
  constraint machine_issue_resolved_shift_fk foreign key (tenant_id, resolved_shift_id) references public.shift (tenant_id, id) on delete restrict,
  -- a stopped machine is always Critical (owner); the RPC forces it and the table refuses anything else
  constraint machine_issue_stopped_critical check (not machine_stopped or priority = 'critical'),
  -- resolution time = closed_at - reported_at must exist for every closed issue (AC-10)
  constraint machine_issue_closed_at check ((status = 'closed') = (closed_at is not null)),
  constraint machine_issue_resolved_at check (status not in ('resolved', 'closed') or (resolved_at is not null and resolved_by is not null))
);
create index machine_issue_tenant_status_idx on public.machine_issue (tenant_id, status, reported_at desc);
create index machine_issue_machine_idx on public.machine_issue (machine_id);
create index machine_issue_owner_idx on public.machine_issue (accountable_owner_id) where accountable_owner_id is not null;
create index machine_issue_category_idx on public.machine_issue (category_id);

-- Append-only: every lifecycle step is an action. type: report | note | photo | start | assignee | escalate | escalation_ack | reassign |
-- resolve | verify_confirm | verify_reject | reopen.
create table public.issue_action (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  issue_id uuid not null,
  actor_id uuid not null,
  actor_role text not null check (actor_role in ('unit_admin', 'supervisor')),
  type text not null check (type in ('report', 'note', 'photo', 'start', 'assignee', 'escalate', 'escalation_ack', 'reassign',
                                     'resolve', 'verify_confirm', 'verify_reject', 'reopen')),
  notes text check (notes = btrim(notes) and length(notes) between 1 and 1000),
  status_before text check (status_before in ('open', 'in_progress', 'resolved', 'closed')),
  status_after text check (status_after in ('open', 'in_progress', 'resolved', 'closed')),
  request_id uuid,
  at timestamptz not null default clock_timestamp(), -- strictly ordered even inside one transaction
  constraint issue_action_tenant_id_key unique (tenant_id, id),
  constraint issue_action_issue_fk foreign key (tenant_id, issue_id) references public.machine_issue (tenant_id, id) on delete restrict
);
create index issue_action_issue_idx on public.issue_action (issue_id, at);
create unique index issue_action_actor_request_key on public.issue_action (actor_id, request_id) where request_id is not null;

-- Append-only accountable-owner history. source: report | reassign | verification_rejected | handover (08).
create table public.issue_ownership_history (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  issue_id uuid not null,
  previous_owner uuid,
  new_owner uuid,
  source text not null check (source in ('report', 'reassign', 'verification_rejected', 'handover')),
  reason text check (reason = btrim(reason) and length(reason) between 1 and 200),
  actor_id uuid not null,
  at timestamptz not null default clock_timestamp(),
  constraint issue_ownership_history_issue_fk foreign key (tenant_id, issue_id) references public.machine_issue (tenant_id, id) on delete restrict
);
create index issue_ownership_history_issue_idx on public.issue_ownership_history (issue_id, at);

-- Photo metadata; the bytes live in Storage bucket `attachments` under tenant/<tenant_id>/... (section 3 of step 3). entity_type is free text
-- so 06 can add its own kind without touching this table; 07 uses 'issue_action' (entity_id = the photo action created at commit).
-- Append-only except the single pending -> ready transition (trigger).
create table public.attachment (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  entity_type text not null check (entity_type ~ '^[a-z_]{1,40}$'),
  entity_id uuid not null,
  storage_path text not null unique,
  mime text not null check (mime in ('image/jpeg', 'image/png', 'image/webp')),
  size_bytes integer not null check (size_bytes between 1 and 5242880),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  status text not null default 'pending' check (status in ('pending', 'ready')),
  uploaded_by uuid not null,
  created_at timestamptz not null default now(),
  ready_at timestamptz,
  constraint attachment_tenant_id_key unique (tenant_id, id),
  constraint attachment_ready_at check ((status = 'ready') = (ready_at is not null)),
  constraint attachment_path_tenant check (storage_path like 'tenant/' || tenant_id::text || '/%')
);
create index attachment_entity_idx on public.attachment (entity_type, entity_id);
create index attachment_pending_idx on public.attachment (uploaded_by, created_at) where status = 'pending';

-- 3. Row-level security ------------------------------------------------------------------------------------------
-- issue_category: every active member of the tenant reads (the report form lists them). The issue tables: Unit Admins only; a supervisor reads
-- issues through issue_list / issue_detail (step 4), never the raw tables. Nobody writes through the API.
alter table public.issue_category enable row level security;
alter table public.issue_category force row level security;
create policy issue_category_select_member on public.issue_category for select to authenticated using (tenant_id = (select app.current_tenant_id()));
revoke all on public.issue_category from public, anon, authenticated, service_role;
grant select on public.issue_category to authenticated;
grant select, insert, update, delete on public.issue_category to service_role;

do $$
declare t text;
begin
  foreach t in array array['machine_issue', 'issue_action', 'issue_ownership_history', 'attachment'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format($p$create policy %I on public.%I for select to authenticated
      using (tenant_id = (select app.current_tenant_id()) and (select app."current_role"()) = 'unit_admin')$p$, t || '_select_ua', t);
    execute format('revoke all on public.%I from public, anon, authenticated, service_role', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant select, insert on public.%I to service_role', t);
  end loop;
end $$;

-- 4. Append-only history and the attachment guard (no privilege for any role, plus triggers that also stop the owner) --------------------
create function app.iss_append_only()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception '% is append-only', tg_table_name using errcode = 'P0001';
end
$$;
do $$
declare t text;
begin
  foreach t in array array['issue_action', 'issue_ownership_history', 'attachment'] loop
    execute format('create trigger %I before delete on public.%I for each row execute function app.iss_append_only()', t || '_no_delete', t);
    execute format('create trigger %I before truncate on public.%I for each statement execute function app.iss_append_only()', t || '_no_truncate', t);
  end loop;
  foreach t in array array['issue_action', 'issue_ownership_history'] loop
    execute format('create trigger %I before update on public.%I for each row execute function app.iss_append_only()', t || '_no_update', t);
  end loop;
end $$;

-- attachment: the only change ever allowed is pending -> ready (+ ready_at); every other column stays as it was.
create function app.attachment_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status = 'pending' and new.status = 'ready'
     and (new.id, new.tenant_id, new.entity_type, new.entity_id, new.storage_path, new.mime, new.size_bytes, new.sha256, new.uploaded_by, new.created_at)
         is not distinct from
         (old.id, old.tenant_id, old.entity_type, old.entity_id, old.storage_path, old.mime, old.size_bytes, old.sha256, old.uploaded_by, old.created_at) then
    return new;
  end if;
  raise exception 'attachment is append-only (only pending to ready)' using errcode = 'P0001';
end
$$;
create trigger attachment_guard before update on public.attachment for each row execute function app.attachment_guard();

-- Users named on an issue (reporter, owner, resolver, closer) must belong to the issue's tenant (no foreign key, see above).
create function app.iss_member_same_tenant()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ids uuid[];
begin
  if tg_table_name = 'machine_issue' then
    v_ids := array[new.reported_by, new.accountable_owner_id, new.resolved_by, new.closed_by];
  elsif tg_table_name = 'issue_action' then
    v_ids := array[new.actor_id];
  elsif tg_table_name = 'issue_ownership_history' then
    v_ids := array[new.previous_owner, new.new_owner, new.actor_id];
  else
    v_ids := array[new.uploaded_by];
  end if;
  if exists (select 1 from unnest(v_ids) u(u)
             where u.u is not null
               and not exists (select 1 from public.membership m where m.user_id = u.u and m.tenant_id = new.tenant_id)) then
    raise exception 'The user does not belong to this tenant' using errcode = '23514';
  end if;
  return new;
end
$$;
do $$
declare t text;
begin
  foreach t in array array['machine_issue', 'issue_action', 'issue_ownership_history', 'attachment'] loop
    execute format('create trigger %I before insert or update on public.%I for each row execute function app.iss_member_same_tenant()', t || '_members', t);
  end loop;
end $$;

-- 5. Categories: starter list for every tenant (existing ones now, new ones by trigger) ---------------------------------------------------
create function app.issue_seed_categories(p_tenant uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.issue_category (tenant_id, name, sort)
  select p_tenant, c.name, c.sort
  from (values ('Mechanical', 10), ('Electrical', 20), ('Mould/Tool', 30), ('Material', 40), ('Quality', 50), ('Safety', 60), ('Other', 70)) c(name, sort)
  on conflict do nothing
$$;

create function app.issue_tenant_seed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.issue_seed_categories(new.id);
  return new;
end
$$;
create trigger tenant_issue_categories after insert on public.tenant for each row execute function app.issue_tenant_seed();
select app.issue_seed_categories(t.id) from public.tenant t;

-- 99. Function privileges: no app function is executable by clients (test 004); the public entry points are executable by authenticated only.
-- (Repeated at the end of every step's section: each step adds functions, the loop is re-run over the whole 07 name range.)
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig, n.nspname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname = 'app' and p.proname ~ '^(iss_|_iss_|issue_|attachment_|machine_owner_now$|can_see_)')
       or (n.nspname = 'public' and p.proname ~ '^(iss_|issue_)')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.nspname = 'public' then
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;
