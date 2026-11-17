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
  parent_id uuid, -- the aggregate the entity belongs to (07: the issue); no FK so 06 can point at its own parent
  begin_request_id uuid, -- the request id of iss_attachment_begin: a retried begin returns the same pending row
  created_at timestamptz not null default now(),
  ready_at timestamptz,
  constraint attachment_tenant_id_key unique (tenant_id, id),
  constraint attachment_ready_at check ((status = 'ready') = (ready_at is not null)),
  constraint attachment_path_tenant check (storage_path like 'tenant/' || tenant_id::text || '/%')
);
create unique index attachment_begin_request_key on public.attachment (uploaded_by, begin_request_id) where begin_request_id is not null;
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
     and (new.id, new.tenant_id, new.entity_type, new.entity_id, new.storage_path, new.mime, new.size_bytes, new.sha256, new.uploaded_by, new.created_at, new.parent_id, new.begin_request_id)
         is not distinct from
         (old.id, old.tenant_id, old.entity_type, old.entity_id, old.storage_path, old.mime, old.size_bytes, old.sha256, old.uploaded_by, old.created_at, old.parent_id, old.begin_request_id) then
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

-- 6. Authorisation and lookup helpers (step 2) --------------------------------------------------------------------------------------
-- Same contract as 04's _pm_authorise (per-tenant row lock first, idempotency by request id + source, generic audited denial) but any active
-- member passes unless p_ua_only. The iss_* RPCs call app._pm_authorise( first for callers without a membership (a Super Admin, a stranger), so
-- that denial rule lives in one place and 022's static check holds.
create function app._iss_authorise(p_request_id uuid, p_source text, p_ua_only boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_tenant uuid;
  a record;
  v_reason text;
  v_done uuid;
begin
  select m.tenant_id into v_tenant from public.membership m where m.user_id = v_actor;
  if v_tenant is not null then
    perform 1 from public.tenant t where t.id = v_tenant for no key update;
  end if;
  select m.tenant_id, m.role, m.status, m.must_change_password, t.status as tenant_status
    into a
    from public.membership m join public.tenant t on t.id = m.tenant_id
    where m.user_id = v_actor;
  if not found then
    v_reason := 'no_membership';
  elsif a.status <> 'active' or a.tenant_status <> 'active' then
    v_reason := 'inactive';
  elsif a.must_change_password then
    v_reason := 'must_change_password';
  elsif p_ua_only and a.role <> 'unit_admin' then
    v_reason := 'role';
  end if;
  if v_reason is not null then
    perform app.audit_denied(v_actor, v_tenant, a.role::text, v_reason, null, null, p_source);
    return jsonb_build_object('ok', false, 'code', 'not_allowed');
  end if;
  if p_request_id is null then
    perform app._pm_fail('validation', 'A request id is required', 'request_id');
  end if;
  select e.entity_id into v_done from public.audit_event e where e.actor_user_id = v_actor and e.request_id = p_request_id and e.source = p_source;
  return jsonb_build_object('ok', true, 'tenant_id', a.tenant_id, 'actor', v_actor, 'role', a.role, 'done', v_done);
end
$$;

-- 'ok' when the row exists in the caller's tenant, else 'cross_tenant' (exists elsewhere) or 'not_found'. kind: issue | category.
create function app._iss_owned(p_kind text, p_id uuid, p_tenant uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  if p_id is null then return 'not_found'; end if;
  if p_kind = 'issue' then select i.tenant_id into v_tenant from public.machine_issue i where i.id = p_id;
  elsif p_kind = 'category' then select c.tenant_id into v_tenant from public.issue_category c where c.id = p_id;
  else raise exception 'unknown kind %', p_kind; end if;
  if v_tenant is null then return 'not_found'; end if;
  if v_tenant <> p_tenant then return 'cross_tenant'; end if;
  return 'ok';
end
$$;

-- The user when they are an active supervisor (not waiting for a password change), else null. Inactive owners count as "nobody".
create function app._iss_active_sup(p_user uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.user_id from public.membership m
  where m.user_id = p_user and m.role = 'supervisor' and m.status = 'active' and m.must_change_password = false
$$;

-- D3: the running occurrences of any shift for a machine (earliest-started first) with the active supervisor who owns it there (null = unassigned).
-- Caller's tenant only (service role: any), like app.current_occurrences.
create function app.machine_owner_now_src(p_machine uuid, p_at timestamptz default now())
returns table (shift_id uuid, shift_date date, supervisor_id uuid, started_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select o.shift_id, o.shift_date, app._iss_active_sup(app.machine_owner(p_machine, o.shift_id, o.shift_date)), lower(o.span)
  from app.current_occurrences(p_at) o
  where exists (select 1 from public.machine m where m.id = p_machine and m.tenant_id = o.tenant_id)
  order by lower(o.span), o.shift_id
$$;

-- The owner of a machine now = the owner in the earliest-started running occurrence (null when none runs or it is unassigned).
create function app.machine_owner_now(p_machine uuid, p_at timestamptz default now())
returns uuid
language sql
stable
security definer
set search_path = ''
as $$ select r.supervisor_id from app.machine_owner_now_src(p_machine, p_at) r limit 1 $$;

-- The occurrence to record on an issue for a user: a running one in which they own the machine, else the earliest-started running one (null, null if none).
create function app._iss_occurrence(p_machine uuid, p_user uuid, p_at timestamptz)
returns table (shift_id uuid, shift_date date)
language sql
stable
security definer
set search_path = ''
as $$
  select r.shift_id, r.shift_date from app.machine_owner_now_src(p_machine, p_at) r
  order by (r.supervisor_id is not distinct from p_user) desc, r.started_at, r.shift_id
  limit 1
$$;

-- D4: may this user verify the issue now? Pure (explicit p_at). status resolved + priority high/critical, and
--  - a supervisor: owns the machine in an occurrence that started after the resolve time (running counts) and is not the resolver;
--  - a Unit Admin: only when no active supervisor is assigned to the machine in the first occurrence of EVERY shift that starts after the resolve time.
-- Retired shifts are ignored. Occurrences are read through app.shift_window, so the caller's tenant (or the service role) applies.
create function app.issue_can_verify(p_issue uuid, p_user uuid, p_at timestamptz default now())
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  i public.machine_issue;
  mem record;
  v_from date;
  v_to date;
begin
  select * into i from public.machine_issue x where x.id = p_issue;
  if not found or i.status <> 'resolved' or i.priority not in ('high', 'critical') or i.resolved_at is null then return false; end if;
  select m.role, m.status, m.must_change_password into mem from public.membership m where m.user_id = p_user and m.tenant_id = i.tenant_id;
  if not found or mem.status <> 'active' or mem.must_change_password then return false; end if;
  v_from := app.plant_date_at(i.tenant_id, i.resolved_at) - 1;
  v_to := greatest(app.plant_date_at(i.tenant_id, p_at), v_from);
  if mem.role = 'supervisor' then
    if p_user = i.resolved_by then return false; end if;
    return exists (
      select 1
      from public.shift s
      cross join lateral generate_series(0, v_to - v_from) as g(n)
      cross join lateral (select app.shift_window(s.id, v_from + g.n) as w) x
      where s.tenant_id = i.tenant_id and s.retired_at is null
        and lower(x.w) > i.resolved_at and lower(x.w) <= p_at
        and app._iss_active_sup(app.machine_owner(i.machine_id, s.id, v_from + g.n)) = p_user);
  end if;
  if mem.role <> 'unit_admin' then return false; end if;
  return not exists (
    select 1
    from public.shift s
    cross join lateral (
      select min(v_from + g.n) as d
      from generate_series(0, v_to - v_from + 3) as g(n)
      where lower(app.shift_window(s.id, v_from + g.n)) > i.resolved_at
    ) f
    where s.tenant_id = i.tenant_id and s.retired_at is null and f.d is not null
      and app._iss_active_sup(app.machine_owner(i.machine_id, s.id, f.d)) is not null);
end
$$;

-- FR-4: may this user (default: the caller) see the issue? A Unit Admin sees every issue of the tenant; a supervisor the issues they are accountable
-- for or reported, issues on a machine they own now, and issues awaiting their verification. Nobody else (a Super Admin never).
create function app.can_see_issue(p_issue uuid, p_user uuid default null, p_at timestamptz default now())
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  u uuid := coalesce(p_user, auth.uid());
  i public.machine_issue;
  mem record;
begin
  select * into i from public.machine_issue x where x.id = p_issue;
  if not found then return false; end if;
  select m.role, m.status, m.must_change_password, t.status as tenant_status into mem
    from public.membership m join public.tenant t on t.id = m.tenant_id
    where m.user_id = u and m.tenant_id = i.tenant_id;
  if not found or mem.status <> 'active' or mem.tenant_status <> 'active' or mem.must_change_password then return false; end if;
  if mem.role = 'unit_admin' then return true; end if;
  if mem.role <> 'supervisor' then return false; end if;
  return i.accountable_owner_id = u or i.reported_by = u
      or exists (select 1 from app.machine_owner_now_src(i.machine_id, p_at) r where r.supervisor_id = u)
      or app.issue_can_verify(p_issue, u, p_at);
end
$$;

-- FR-4: the open issues of a machine (not closed), for 08's carry-forward and 06's context. Caller's tenant only (service role: any).
create function app.issue_open_for_machine(p_machine uuid)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select i.id from public.machine_issue i
  where i.machine_id = p_machine and i.status <> 'closed'
    and (auth.role() = 'service_role' or i.tenant_id = app.current_tenant_id())
  order by i.reported_at
$$;

-- 7. Write RPCs (step 2, D2) ---------------------------------------------------------------------------------------------------------------
-- public.iss_*: security definer, executable by authenticated. Each authorises first (a caller without a membership goes through
-- app._pm_authorise, which audits the denial; members go through app._iss_authorise), validates, writes and audits in one transaction.
-- Authorisation failures COMMIT an access.denied row and RETURN {ok:false, code:'not_allowed'}; validation / guard / duplicate failures RAISE P0001
-- with detail {code, field?}. Success returns {ok:true, id, ...}. Time: write RPCs use now() (05's rule).

create function public.iss_report(
  p_request_id uuid, p_machine_id uuid, p_category_id uuid, p_priority text, p_description text, p_machine_stopped boolean
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:iss_report';
  a jsonb;
  v_tenant uuid;
  v_actor uuid;
  v_own text;
  v_desc text := btrim(p_description);
  v_prio text := lower(btrim(p_priority));
  v_owner uuid;
  v_shift uuid;
  v_date date;
  v_cat public.issue_category;
  v_machine public.machine;
  v_id uuid;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._iss_authorise(p_request_id, c_src, false);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;
  v_actor := (a->>'actor')::uuid;

  v_own := app._pm_owned('machine', p_machine_id, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'machine', p_machine_id, c_src); end if;
  v_own := app._iss_owned('category', p_category_id, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'issue_category', p_category_id, c_src); end if;

  perform app._pm_len(v_desc, 1, 1000, 'description', 'Describe the problem in 1 to 1000 characters');
  if p_machine_stopped is null then perform app._pm_fail('validation', 'Say whether the machine is stopped', 'machine_stopped'); end if;
  if p_machine_stopped then
    v_prio := 'critical'; -- a stopped machine is always Critical (owner)
  elsif v_prio is null or v_prio not in ('low', 'medium', 'high', 'critical') then
    perform app._pm_fail('validation', 'Choose Low, Medium, High or Critical', 'priority');
  end if;
  select * into v_machine from public.machine m where m.id = p_machine_id;
  if v_machine.retired_at is not null then perform app._pm_fail('guard', 'This machine is retired', 'machine_id'); end if;
  select * into v_cat from public.issue_category c where c.id = p_category_id;
  if v_cat.retired_at is not null then perform app._pm_fail('guard', 'This category is retired', 'category_id'); end if;

  -- AC-2: a supervisor who owns the machine now is accountable; otherwise the machine's owner now; otherwise the reporter if a supervisor, else nobody.
  select o.shift_id, o.shift_date into v_shift, v_date from app._iss_occurrence(p_machine_id, v_actor, now()) o;
  if a->>'role' = 'supervisor' and exists (select 1 from app.machine_owner_now_src(p_machine_id, now()) r where r.supervisor_id = v_actor) then
    v_owner := v_actor;
  else
    v_owner := app.machine_owner_now(p_machine_id, now());
    if v_owner is null and a->>'role' = 'supervisor' then v_owner := v_actor; end if;
  end if;

  insert into public.machine_issue (tenant_id, machine_id, category_id, priority, description, machine_stopped, accountable_owner_id,
                                    reported_by, reported_shift_id, reported_shift_date)
  values (v_tenant, p_machine_id, p_category_id, v_prio, v_desc, p_machine_stopped, v_owner, v_actor, v_shift, v_date)
  returning id into v_id;
  insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, status_after, request_id)
  values (v_tenant, v_id, v_actor, a->>'role', 'report', 'open', p_request_id);
  insert into public.issue_ownership_history (tenant_id, issue_id, previous_owner, new_owner, source, actor_id)
  values (v_tenant, v_id, null, v_owner, 'report', v_actor);
  perform app._pm_audit(a, 'issue.reported', 'machine_issue', v_id, null,
    jsonb_build_object('machine_code', v_machine.code, 'category', v_cat.name, 'priority', v_prio, 'machine_stopped', p_machine_stopped, 'owner_id', v_owner),
    p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', v_id, 'priority', v_prio, 'owner_id', v_owner);
end
$$;

-- Shared prelude of the actions on an existing issue (the caller has already routed non-members to app._pm_authorise). Returns the authorisation result; when it is ok, the issue row is the caller's (a foreign or
-- unknown id gives the generic audited denial). p_mode: any (a member who can see it) | owner (accountable owner or Unit Admin) | owner_only | ua.
create function app._iss_act(p_request_id uuid, p_source text, p_issue uuid, p_mode text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a jsonb;
  v_own text;
  i public.machine_issue;
begin
  a := app._iss_authorise(p_request_id, p_source, p_mode = 'ua');
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true, 'replay', true); end if;
  v_own := app._iss_owned('issue', p_issue, (a->>'tenant_id')::uuid);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'machine_issue', p_issue, p_source); end if;
  select * into i from public.machine_issue x where x.id = p_issue;
  if p_mode = 'any' and not app.can_see_issue(p_issue, (a->>'actor')::uuid) then
    return app._pm_deny(a, 'not_visible', 'machine_issue', p_issue, p_source);
  elsif p_mode = 'owner' and a->>'role' <> 'unit_admin' and i.accountable_owner_id is distinct from (a->>'actor')::uuid then
    return app._pm_deny(a, 'not_owner', 'machine_issue', p_issue, p_source);
  elsif p_mode = 'owner_only' and (a->>'role' <> 'supervisor' or i.accountable_owner_id is distinct from (a->>'actor')::uuid) then
    return app._pm_deny(a, 'not_owner', 'machine_issue', p_issue, p_source);
  end if;
  return a;
end
$$;

create function public.iss_note(p_request_id uuid, p_issue_id uuid, p_notes text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:iss_note';
  a jsonb;
  v_notes text := btrim(p_notes);
  i public.machine_issue;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._iss_act(p_request_id, c_src, p_issue_id, 'any');
  if not (a->>'ok')::boolean or a ? 'replay' then return a - 'replay'; end if;
  perform app._pm_len(v_notes, 1, 1000, 'notes', 'Enter a note of 1 to 1000 characters');
  select * into i from public.machine_issue x where x.id = p_issue_id;
  insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, notes, status_before, status_after, request_id)
  values (i.tenant_id, i.id, (a->>'actor')::uuid, a->>'role', 'note', v_notes, i.status, i.status, p_request_id);
  perform app._pm_audit(a, 'issue.noted', 'machine_issue', i.id, null, jsonb_build_object('status', i.status), p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', i.id);
end
$$;

create function public.iss_start(p_request_id uuid, p_issue_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:iss_start';
  a jsonb;
  i public.machine_issue;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._iss_act(p_request_id, c_src, p_issue_id, 'owner');
  if not (a->>'ok')::boolean or a ? 'replay' then return a - 'replay'; end if;
  select * into i from public.machine_issue x where x.id = p_issue_id;
  if i.status <> 'open' then perform app._pm_fail('guard', 'Only an open issue can be started', 'invalid_status'); end if;
  update public.machine_issue x set status = 'in_progress', updated_at = now() where x.id = i.id;
  insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, status_before, status_after, request_id)
  values (i.tenant_id, i.id, (a->>'actor')::uuid, a->>'role', 'start', 'open', 'in_progress', p_request_id);
  perform app._pm_audit(a, 'issue.started', 'machine_issue', i.id, jsonb_build_object('status', 'open'), jsonb_build_object('status', 'in_progress'), p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', i.id);
end
$$;

create function public.iss_set_assignee(p_request_id uuid, p_issue_id uuid, p_assignee text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:iss_set_assignee';
  a jsonb;
  v_name text := btrim(p_assignee);
  i public.machine_issue;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._iss_act(p_request_id, c_src, p_issue_id, 'owner');
  if not (a->>'ok')::boolean or a ? 'replay' then return a - 'replay'; end if;
  perform app._pm_len(v_name, 1, 80, 'assignee', 'Enter who is fixing it, up to 80 characters');
  select * into i from public.machine_issue x where x.id = p_issue_id;
  if i.status = 'closed' then perform app._pm_fail('guard', 'This issue is closed', 'invalid_status'); end if;
  update public.machine_issue x set technical_assignee = v_name, updated_at = now() where x.id = i.id;
  insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, notes, status_before, status_after, request_id)
  values (i.tenant_id, i.id, (a->>'actor')::uuid, a->>'role', 'assignee', v_name, i.status, i.status, p_request_id);
  perform app._pm_audit(a, 'issue.assignee_set', 'machine_issue', i.id, jsonb_build_object('assignee', i.technical_assignee), jsonb_build_object('assignee', v_name), p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', i.id);
end
$$;

create function public.iss_escalate(p_request_id uuid, p_issue_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:iss_escalate';
  a jsonb;
  v_reason text := btrim(p_reason);
  i public.machine_issue;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._iss_act(p_request_id, c_src, p_issue_id, 'owner_only');
  if not (a->>'ok')::boolean or a ? 'replay' then return a - 'replay'; end if;
  perform app._pm_len(v_reason, 1, 200, 'reason', 'Enter a reason of 1 to 200 characters');
  select * into i from public.machine_issue x where x.id = p_issue_id;
  if i.status not in ('open', 'in_progress') then perform app._pm_fail('guard', 'Only an open issue can be escalated', 'invalid_status'); end if;
  if i.escalated_at is not null then perform app._pm_fail('guard', 'This issue is already escalated', 'already_escalated'); end if;
  update public.machine_issue x set escalated_at = now(), updated_at = now() where x.id = i.id;
  insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, notes, status_before, status_after, request_id)
  values (i.tenant_id, i.id, (a->>'actor')::uuid, a->>'role', 'escalate', v_reason, i.status, i.status, p_request_id);
  perform app._pm_audit(a, 'issue.escalated', 'machine_issue', i.id, jsonb_build_object('escalated', false), jsonb_build_object('escalated', true, 'reason', v_reason), p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', i.id);
end
$$;

create function public.iss_ack_escalation(p_request_id uuid, p_issue_id uuid, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:iss_ack_escalation';
  a jsonb;
  v_note text := btrim(p_note);
  i public.machine_issue;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._iss_act(p_request_id, c_src, p_issue_id, 'ua');
  if not (a->>'ok')::boolean or a ? 'replay' then return a - 'replay'; end if;
  perform app._pm_len(v_note, 1, 200, 'note', 'Enter a note of 1 to 200 characters');
  select * into i from public.machine_issue x where x.id = p_issue_id;
  if i.escalated_at is null then perform app._pm_fail('guard', 'This issue is not escalated', 'not_escalated'); end if;
  update public.machine_issue x set escalated_at = null, updated_at = now() where x.id = i.id;
  insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, notes, status_before, status_after, request_id)
  values (i.tenant_id, i.id, (a->>'actor')::uuid, a->>'role', 'escalation_ack', v_note, i.status, i.status, p_request_id);
  perform app._pm_audit(a, 'issue.escalation_acknowledged', 'machine_issue', i.id, jsonb_build_object('escalated', true), jsonb_build_object('escalated', false), p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', i.id);
end
$$;

create function public.iss_reassign(p_request_id uuid, p_issue_id uuid, p_new_owner uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:iss_reassign';
  a jsonb;
  v_own text;
  v_reason text := btrim(p_reason);
  i public.machine_issue;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._iss_act(p_request_id, c_src, p_issue_id, 'ua');
  if not (a->>'ok')::boolean or a ? 'replay' then return a - 'replay'; end if;
  if p_new_owner is not null then
    v_own := app._sh_owned('member', p_new_owner, (a->>'tenant_id')::uuid);
    if v_own <> 'ok' then return app._pm_deny(a, v_own, 'member', p_new_owner, c_src); end if;
  end if;
  perform app._pm_len(v_reason, 1, 200, 'reason', 'Enter a reason of 1 to 200 characters');
  if p_new_owner is null or app._iss_active_sup(p_new_owner) is null then perform app._pm_fail('validation', 'Choose an active supervisor', 'supervisor'); end if;
  select * into i from public.machine_issue x where x.id = p_issue_id;
  if i.status = 'closed' then perform app._pm_fail('guard', 'This issue is closed', 'invalid_status'); end if;
  if i.accountable_owner_id is not distinct from p_new_owner then perform app._pm_fail('guard', 'This supervisor is already accountable', 'same_owner'); end if;
  update public.machine_issue x set accountable_owner_id = p_new_owner, escalated_at = null, updated_at = now() where x.id = i.id;
  insert into public.issue_ownership_history (tenant_id, issue_id, previous_owner, new_owner, source, reason, actor_id)
  values (i.tenant_id, i.id, i.accountable_owner_id, p_new_owner, 'reassign', v_reason, (a->>'actor')::uuid);
  insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, notes, status_before, status_after, request_id)
  values (i.tenant_id, i.id, (a->>'actor')::uuid, a->>'role', 'reassign', v_reason, i.status, i.status, p_request_id);
  perform app._pm_audit(a, 'issue.reassigned', 'machine_issue', i.id,
    jsonb_build_object('owner_id', i.accountable_owner_id), jsonb_build_object('owner_id', p_new_owner, 'reason', v_reason), p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', i.id);
end
$$;

create function public.iss_resolve(p_request_id uuid, p_issue_id uuid, p_notes text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:iss_resolve';
  a jsonb;
  v_notes text := btrim(p_notes);
  v_actor uuid;
  v_shift uuid;
  v_date date;
  v_after text;
  i public.machine_issue;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._iss_act(p_request_id, c_src, p_issue_id, 'owner');
  if not (a->>'ok')::boolean or a ? 'replay' then return a - 'replay'; end if;
  v_actor := (a->>'actor')::uuid;
  perform app._pm_len(v_notes, 1, 1000, 'notes', 'Enter resolution notes of 1 to 1000 characters');
  select * into i from public.machine_issue x where x.id = p_issue_id;
  if i.status not in ('open', 'in_progress') then perform app._pm_fail('guard', 'Only an open issue can be resolved', 'invalid_status'); end if;
  v_after := case when i.priority in ('high', 'critical') then 'resolved' else 'closed' end; -- AC-7
  select o.shift_id, o.shift_date into v_shift, v_date from app._iss_occurrence(i.machine_id, v_actor, now()) o;
  update public.machine_issue x
     set status = v_after, escalated_at = null, resolved_by = v_actor, resolved_at = now(), resolved_shift_id = v_shift, resolved_shift_date = v_date,
         resolution_notes = v_notes, closed_at = case when v_after = 'closed' then now() end, closed_by = case when v_after = 'closed' then v_actor end,
         updated_at = now()
   where x.id = i.id;
  insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, notes, status_before, status_after, request_id)
  values (i.tenant_id, i.id, v_actor, a->>'role', 'resolve', v_notes, i.status, v_after, p_request_id);
  perform app._pm_audit(a, 'issue.resolved', 'machine_issue', i.id, jsonb_build_object('status', i.status),
    jsonb_build_object('status', v_after, 'priority', i.priority), p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', i.id, 'status', v_after);
end
$$;

create function public.iss_verify(p_request_id uuid, p_issue_id uuid, p_confirm boolean, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:iss_verify';
  a jsonb;
  v_reason text := nullif(btrim(p_reason), '');
  v_actor uuid;
  i public.machine_issue;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._iss_act(p_request_id, c_src, p_issue_id, 'verify');
  if not (a->>'ok')::boolean or a ? 'replay' then return a - 'replay'; end if;
  v_actor := (a->>'actor')::uuid;
  select * into i from public.machine_issue x where x.id = p_issue_id;
  if p_confirm is null then perform app._pm_fail('validation', 'Choose Confirm fixed or Not fixed', 'confirm'); end if;
  if i.status <> 'resolved' then perform app._pm_fail('guard', 'This issue is not awaiting verification', 'invalid_status'); end if;
  -- AC-8: only a later-shift owner (never the resolver), or a Unit Admin when no later-shift supervisor is assigned
  if not app.issue_can_verify(i.id, v_actor, now()) then
    return app._pm_deny(a, 'not_verifier', 'machine_issue', i.id, c_src);
  end if;
  if p_confirm then
    perform app._pm_len(v_reason, 0, 200, 'reason', 'Enter a note of up to 200 characters');
    update public.machine_issue x set status = 'closed', closed_at = now(), closed_by = v_actor, updated_at = now() where x.id = i.id;
    insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, notes, status_before, status_after, request_id)
    values (i.tenant_id, i.id, v_actor, a->>'role', 'verify_confirm', v_reason, 'resolved', 'closed', p_request_id);
    perform app._pm_audit(a, 'issue.verified', 'machine_issue', i.id, jsonb_build_object('status', 'resolved'), jsonb_build_object('status', 'closed'), p_request_id, c_src);
    return jsonb_build_object('ok', true, 'id', i.id, 'status', 'closed');
  end if;
  perform app._pm_len(v_reason, 1, 200, 'reason', 'Enter a reason of 1 to 200 characters');
  -- reject: back to In progress; a rejecting supervisor becomes the accountable owner (ownership history, source verification_rejected)
  update public.machine_issue x
     set status = 'in_progress', updated_at = now(),
         accountable_owner_id = case when a->>'role' = 'supervisor' then v_actor else x.accountable_owner_id end
   where x.id = i.id;
  if a->>'role' = 'supervisor' and i.accountable_owner_id is distinct from v_actor then
    insert into public.issue_ownership_history (tenant_id, issue_id, previous_owner, new_owner, source, reason, actor_id)
    values (i.tenant_id, i.id, i.accountable_owner_id, v_actor, 'verification_rejected', v_reason, v_actor);
  end if;
  insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, notes, status_before, status_after, request_id)
  values (i.tenant_id, i.id, v_actor, a->>'role', 'verify_reject', v_reason, 'resolved', 'in_progress', p_request_id);
  perform app._pm_audit(a, 'issue.verification_rejected', 'machine_issue', i.id, jsonb_build_object('status', 'resolved', 'owner_id', i.accountable_owner_id),
    jsonb_build_object('status', 'in_progress', 'reason', v_reason), p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', i.id, 'status', 'in_progress');
end
$$;

create function public.iss_reopen(p_request_id uuid, p_issue_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:iss_reopen';
  a jsonb;
  v_reason text := btrim(p_reason);
  i public.machine_issue;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._iss_act(p_request_id, c_src, p_issue_id, 'ua');
  if not (a->>'ok')::boolean or a ? 'replay' then return a - 'replay'; end if;
  perform app._pm_len(v_reason, 1, 200, 'reason', 'Enter a reason of 1 to 200 characters');
  select * into i from public.machine_issue x where x.id = p_issue_id;
  if i.status <> 'closed' then perform app._pm_fail('guard', 'Only a closed issue can be reopened', 'invalid_status'); end if;
  update public.machine_issue x set status = 'in_progress', closed_at = null, closed_by = null, updated_at = now() where x.id = i.id;
  insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, notes, status_before, status_after, request_id)
  values (i.tenant_id, i.id, (a->>'actor')::uuid, a->>'role', 'reopen', v_reason, 'closed', 'in_progress', p_request_id);
  perform app._pm_audit(a, 'issue.reopened', 'machine_issue', i.id, jsonb_build_object('status', 'closed'),
    jsonb_build_object('status', 'in_progress', 'reason', v_reason), p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', i.id);
end
$$;

-- Categories (Unit Admin only) ------------------------------------------------------------------------------------------------------------
create function public.iss_category_save(p_request_id uuid, p_id uuid, p_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:iss_category_save';
  a jsonb;
  v_tenant uuid;
  v_own text;
  v_name text := btrim(p_name);
  cur public.issue_category;
  upd public.issue_category;
  v_c text;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._iss_authorise(p_request_id, c_src, true);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;
  if p_id is not null then
    v_own := app._iss_owned('category', p_id, v_tenant);
    if v_own <> 'ok' then return app._pm_deny(a, v_own, 'issue_category', p_id, c_src); end if;
  end if;
  perform app._pm_len(v_name, 1, 40, 'name', 'Enter a name of 1 to 40 characters');
  begin
    if p_id is null then
      insert into public.issue_category (tenant_id, name, sort) values (v_tenant, v_name,
        coalesce((select max(c.sort) from public.issue_category c where c.tenant_id = v_tenant), 0) + 10) returning * into upd;
    else
      select * into cur from public.issue_category c where c.id = p_id;
      update public.issue_category c set name = v_name, updated_at = now() where c.id = p_id returning * into upd;
    end if;
  exception when unique_violation then
    get stacked diagnostics v_c = constraint_name;
    if v_c = 'issue_category_tenant_name_key' then perform app._pm_fail('duplicate', 'A category with this name already exists', 'name'); end if;
    raise;
  end;
  if p_id is null then
    perform app._pm_audit(a, 'issue_category.created', 'issue_category', upd.id, null, jsonb_build_object('name', upd.name), p_request_id, c_src);
  else
    perform app._pm_audit(a, 'issue_category.updated', 'issue_category', upd.id, jsonb_build_object('name', cur.name), jsonb_build_object('name', upd.name), p_request_id, c_src);
  end if;
  return jsonb_build_object('ok', true, 'id', upd.id);
end
$$;

create function public.iss_category_set_retired(p_request_id uuid, p_id uuid, p_retired boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:iss_category_set_retired';
  a jsonb;
  v_own text;
  cur public.issue_category;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._iss_authorise(p_request_id, c_src, true);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_own := app._iss_owned('category', p_id, (a->>'tenant_id')::uuid);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'issue_category', p_id, c_src); end if;
  if p_retired is null then perform app._pm_fail('validation', 'Choose retire or reinstate', 'retired'); end if;
  select * into cur from public.issue_category c where c.id = p_id;
  if (cur.retired_at is not null) = p_retired then return jsonb_build_object('ok', true, 'id', p_id, 'changed', false); end if;
  update public.issue_category c set retired_at = case when p_retired then now() end, updated_at = now() where c.id = p_id;
  perform app._pm_audit(a, case when p_retired then 'issue_category.retired' else 'issue_category.reinstated' end, 'issue_category', p_id,
    jsonb_build_object('name', cur.name, 'retired', cur.retired_at is not null), jsonb_build_object('name', cur.name, 'retired', p_retired), p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', p_id, 'changed', true);
end
$$;

-- 8. Attachments and Storage (step 3, D6) ---------------------------------------------------------------------------------------------------------
-- Two-phase upload: iss_attachment_begin writes a pending row and returns the storage path; the client uploads the bytes to the private bucket
-- `attachments` (the INSERT policy only lets a user write the path of their own pending row, within 10 minutes); iss_attachment_commit checks the
-- object exists with the declared size and type, marks the row ready and appends a `photo` action. Reading goes through the SELECT policy, which asks
-- whether the caller may see the issue the photo belongs to. No UPDATE or DELETE policy exists, so clients can never change or remove an object.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('attachments', 'attachments', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = false, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

-- The two Storage policy helpers live in their own schema: storage.objects policies run as the calling role, which therefore needs EXECUTE, and
-- 02's test 004 forbids client-executable functions in `app` (except the two RLS helpers). `app_policy` is not exposed through the API (only `public`
-- is), so these are reachable only from policy expressions. Both are security definer and call the `app` helpers as their owner.
create schema app_policy;
revoke all on schema app_policy from public;
grant usage on schema app_policy to authenticated;

-- INSERT: the caller may write exactly the path of their own pending attachment created in the last 10 minutes (tenant must still be theirs).
create function app_policy.attachment_upload_ok(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.attachment a
    where a.storage_path = p_name and a.status = 'pending' and a.uploaded_by = auth.uid()
      and a.created_at > now() - interval '10 minutes'
      and a.tenant_id = app.current_tenant_id())
$$;

-- SELECT: the uploader sees their own pending object (an INSERT ... RETURNING needs it); a ready object is visible to whoever may see the issue.
create function app_policy.can_see_attachment(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.attachment a
    where a.storage_path = p_name
      and a.tenant_id = app.current_tenant_id()
      and (
        (a.status = 'pending' and a.uploaded_by = auth.uid())
        or (a.status = 'ready' and a.entity_type = 'issue_action'
            and exists (select 1 from public.issue_action x where x.id = a.entity_id and x.tenant_id = a.tenant_id and app.can_see_issue(x.issue_id)))))
$$;
revoke all on function app_policy.attachment_upload_ok(text), app_policy.can_see_attachment(text) from public, anon;
grant execute on function app_policy.attachment_upload_ok(text), app_policy.can_see_attachment(text) to authenticated;

create policy attachments_insert_own_pending on storage.objects for insert to authenticated
  with check (bucket_id = 'attachments' and app_policy.attachment_upload_ok(name));
create policy attachments_select_visible on storage.objects for select to authenticated
  using (bucket_id = 'attachments' and app_policy.can_see_attachment(name));

create function public.iss_attachment_begin(p_request_id uuid, p_issue_id uuid, p_mime text, p_size bigint, p_sha256 text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:iss_attachment_begin';
  a jsonb;
  v_actor uuid;
  v_sha text := lower(btrim(p_sha256));
  v_ext text;
  v_id uuid := gen_random_uuid();
  v_path text;
  v_action uuid := gen_random_uuid();
  ex public.attachment;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._iss_act(p_request_id, c_src, p_issue_id, 'any');
  if not (a->>'ok')::boolean or a ? 'replay' then return a - 'replay'; end if;
  v_actor := (a->>'actor')::uuid;

  v_ext := case lower(btrim(p_mime)) when 'image/jpeg' then 'jpg' when 'image/png' then 'png' when 'image/webp' then 'webp' end;
  if v_ext is null then perform app._pm_fail('validation', 'Photos must be JPEG, PNG or WebP', 'mime'); end if;
  if p_size is null or p_size < 1 or p_size > 5242880 then perform app._pm_fail('validation', 'A photo must be 5 MB or smaller', 'size'); end if;
  if v_sha is null or v_sha !~ '^[0-9a-f]{64}$' then perform app._pm_fail('validation', 'The checksum must be a SHA-256 hex digest', 'sha256'); end if;

  -- a retried begin (same request id) returns the same row
  select * into ex from public.attachment x where x.uploaded_by = v_actor and x.begin_request_id = p_request_id;
  if found then
    if ex.parent_id is distinct from p_issue_id then perform app._pm_fail('validation', 'This request id was already used for another action', 'request_id'); end if;
    return jsonb_build_object('ok', true, 'id', ex.id, 'path', ex.storage_path, 'action_id', ex.entity_id, 'status', ex.status, 'already', true);
  end if;

  if (select count(*) from public.attachment x where x.uploaded_by = v_actor and x.parent_id = p_issue_id and x.status = 'pending'
        and x.created_at > now() - interval '10 minutes') >= 5 then
    perform app._pm_fail('guard', 'Finish or wait for the photos already being uploaded (up to 5 at a time)', 'too_many_pending');
  end if;
  if (select count(*) from public.attachment x where x.parent_id = p_issue_id and x.entity_type = 'issue_action' and x.status = 'ready') >= 30 then
    perform app._pm_fail('guard', 'This issue already has 30 photos', 'photo_limit');
  end if;

  v_path := 'tenant/' || (a->>'tenant_id') || '/issue/' || p_issue_id::text || '/' || v_id::text || '.' || v_ext;
  insert into public.attachment (id, tenant_id, entity_type, entity_id, storage_path, mime, size_bytes, sha256, uploaded_by, parent_id, begin_request_id)
  values (v_id, (a->>'tenant_id')::uuid, 'issue_action', v_action, v_path, lower(btrim(p_mime)), p_size::integer, v_sha, v_actor, p_issue_id, p_request_id);
  return jsonb_build_object('ok', true, 'id', v_id, 'path', v_path, 'action_id', v_action, 'status', 'pending');
end
$$;

create function public.iss_attachment_commit(p_request_id uuid, p_attachment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:iss_attachment_commit';
  a jsonb;
  v_actor uuid;
  v_own text;
  att public.attachment;
  obj record;
  i public.machine_issue;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._iss_authorise(p_request_id, c_src, false);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_actor := (a->>'actor')::uuid;

  select * into att from public.attachment x where x.id = p_attachment_id;
  if not found then return app._pm_deny(a, 'not_found', 'attachment', p_attachment_id, c_src); end if;
  if att.tenant_id <> (a->>'tenant_id')::uuid then return app._pm_deny(a, 'cross_tenant', 'attachment', p_attachment_id, c_src); end if;
  if att.uploaded_by <> v_actor then return app._pm_deny(a, 'not_uploader', 'attachment', p_attachment_id, c_src); end if;
  if att.entity_type <> 'issue_action' then perform app._pm_fail('guard', 'This attachment is not an issue photo', 'entity_type'); end if;
  if att.status <> 'pending' then perform app._pm_fail('guard', 'This photo is already attached', 'already_ready'); end if;
  if att.created_at < now() - interval '1 hour' then perform app._pm_fail('guard', 'This upload expired. Start again', 'expired'); end if;
  if not app.can_see_issue(att.parent_id, v_actor) then return app._pm_deny(a, 'not_visible', 'attachment', p_attachment_id, c_src); end if;

  select o.metadata into obj from storage.objects o where o.bucket_id = 'attachments' and o.name = att.storage_path;
  if not found then perform app._pm_fail('guard', 'The photo has not been uploaded', 'not_uploaded'); end if;
  if (obj.metadata->>'size')::bigint is distinct from att.size_bytes or obj.metadata->>'mimetype' is distinct from att.mime then
    perform app._pm_fail('guard', 'The uploaded photo does not match what was declared', 'mismatch');
  end if;

  select * into i from public.machine_issue x where x.id = att.parent_id;
  update public.attachment x set status = 'ready', ready_at = now() where x.id = att.id;
  insert into public.issue_action (id, tenant_id, issue_id, actor_id, actor_role, type, status_before, status_after, request_id)
  values (att.entity_id, att.tenant_id, i.id, v_actor, a->>'role', 'photo', i.status, i.status, p_request_id);
  update public.machine_issue x set updated_at = now() where x.id = i.id;
  perform app._pm_audit(a, 'attachment.added', 'attachment', att.id, null,
    jsonb_build_object('issue_id', i.id, 'mime', att.mime, 'size_bytes', att.size_bytes, 'sha256', att.sha256), p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', att.id, 'action_id', att.entity_id);
end
$$;

-- 99. Function privileges: no app function is executable by clients (test 004); the public entry points are executable by authenticated only.
-- (Repeated at the end of every step's section: each step adds functions, the loop is re-run over the whole 07 name range.)
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig, n.nspname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname = 'app' and p.proname ~ '^(iss_|_iss_|issue_|attachment_|machine_owner_now|can_see_)')
       or (n.nspname = 'public' and p.proname ~ '^(iss_|issue_)')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.nspname = 'public' then
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;
