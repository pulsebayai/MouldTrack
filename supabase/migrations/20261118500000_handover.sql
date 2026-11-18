-- 08-shift-handover-ack (schema lock): per-issue acknowledgement + declaration at shift opening, UA exceptions, outgoing notes, the handover
-- compliance metric. Built step by step in one file: 1 tables + enforcement + registration hook, 2 helpers, 3 write RPCs + the rd_opening gate,
-- 4 reads + compliance. Every table is append-only except handover_setting (changed only through ho_set_overdue); every write goes through
-- public.ho_* RPCs (06 uses rd_*, 07 iss_*: earlier tests pin per-prefix counts).
--
-- D1 enforcement: the rd_opening gate applies to tenants whose handover_setting row has required = true. Every tenant registered through the
-- Console (app.pa_tenant_create) gets that row in the same transaction and this migration backfills every tenant that exists now. Tenants that
-- tests insert directly have no row and are not gated, so 06's tests stay unchanged. There is no RPC to switch enforcement off.

-- 1. Audit actions + issue_action types ----------------------------------------------------------------------------------------------
insert into app.audit_action (action, feature) values
  ('handover.acknowledged', '08'), ('handover.refused', '08'), ('handover.declared', '08'),
  ('handover.exception', '08'), ('handover.setting_updated', '08'), ('handover.note_added', '08');

-- 07's issue_action.type gains the two handover steps (an additive widening of the CHECK; 07's tests only insert the old types).
alter table public.issue_action drop constraint issue_action_type_check;
alter table public.issue_action add constraint issue_action_type_check check (type in (
  'report', 'note', 'photo', 'start', 'assignee', 'escalate', 'escalation_ack', 'reassign', 'resolve', 'verify_confirm', 'verify_reject', 'reopen',
  'handover_ack', 'handover_refuse'));

-- 2. Tables --------------------------------------------------------------------------------------------------------------------------
-- Per-tenant handover settings. required = the rd_opening gate applies (D1). Changed only by ho_set_overdue (overdue minutes) and the
-- registration hook / backfill (required).
create table public.handover_setting (
  tenant_id uuid primary key references public.tenant (id) on delete restrict,
  overdue_minutes integer not null default 60 check (overdue_minutes between 15 and 480),
  required boolean not null default true,
  updated_by uuid,
  updated_at timestamptz not null default now()
);

-- Written once per (supervisor, occurrence, handover start) when the checklist is first read: snapshots the overdue minutes (AC-8).
create table public.handover_session (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  shift_id uuid not null,
  shift_date date not null,
  supervisor_id uuid not null,
  handover_start timestamptz not null,
  overdue_minutes integer not null check (overdue_minutes between 15 and 480),
  opened_at timestamptz not null default clock_timestamp(),
  constraint handover_session_tenant_id_key unique (tenant_id, id),
  constraint handover_session_once_key unique (tenant_id, shift_id, shift_date, supervisor_id, handover_start),
  constraint handover_session_shift_fk foreign key (tenant_id, shift_id) references public.shift (tenant_id, id) on delete restrict
);

-- kind acknowledged (remark optional) | refused (reason required).
create table public.issue_acknowledgement (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  issue_id uuid not null,
  shift_id uuid not null,
  shift_date date not null,
  supervisor_id uuid not null,
  kind text not null check (kind in ('acknowledged', 'refused')),
  remark text check (remark = btrim(remark) and length(remark) between 1 and 200),
  at timestamptz not null default clock_timestamp(),
  request_id uuid,
  constraint issue_acknowledgement_tenant_id_key unique (tenant_id, id),
  constraint issue_acknowledgement_refusal_reason check (kind = 'acknowledged' or remark is not null),
  constraint issue_acknowledgement_issue_fk foreign key (tenant_id, issue_id) references public.machine_issue (tenant_id, id) on delete restrict,
  constraint issue_acknowledgement_shift_fk foreign key (tenant_id, shift_id) references public.shift (tenant_id, id) on delete restrict
);
create index issue_acknowledgement_lookup_idx on public.issue_acknowledgement (shift_id, shift_date, supervisor_id, issue_id, at);
create index issue_acknowledgement_issue_idx on public.issue_acknowledgement (issue_id);

create table public.handover_declaration (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  shift_id uuid not null,
  shift_date date not null,
  supervisor_id uuid not null,
  text_version integer not null default 1,
  covered_issue_ids uuid[] not null default '{}',
  at timestamptz not null default clock_timestamp(),
  request_id uuid,
  constraint handover_declaration_tenant_id_key unique (tenant_id, id),
  constraint handover_declaration_shift_fk foreign key (tenant_id, shift_id) references public.shift (tenant_id, id) on delete restrict
);
create index handover_declaration_lookup_idx on public.handover_declaration (shift_id, shift_date, supervisor_id, at);

-- A Unit Admin's decision on a refused issue: reason + the owner afterwards (kept = ownership unchanged).
create table public.handover_exception (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  issue_id uuid not null,
  shift_id uuid not null,
  shift_date date not null,
  ua_id uuid not null,
  reason text not null check (reason = btrim(reason) and length(reason) between 1 and 200),
  owner_id uuid not null,
  kept boolean not null,
  at timestamptz not null default clock_timestamp(),
  request_id uuid,
  constraint handover_exception_tenant_id_key unique (tenant_id, id),
  constraint handover_exception_issue_fk foreign key (tenant_id, issue_id) references public.machine_issue (tenant_id, id) on delete restrict,
  constraint handover_exception_shift_fk foreign key (tenant_id, shift_id) references public.shift (tenant_id, id) on delete restrict
);
create index handover_exception_lookup_idx on public.handover_exception (issue_id, shift_id, shift_date, at);

-- Outgoing note: the owner of the machine adds it to an unresolved issue; the latest per issue is shown in the next checklists.
create table public.handover_note (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  issue_id uuid not null,
  author_id uuid not null,
  shift_id uuid not null,
  shift_date date not null,
  note text not null check (note = btrim(note) and length(note) between 1 and 300),
  at timestamptz not null default clock_timestamp(),
  request_id uuid,
  constraint handover_note_tenant_id_key unique (tenant_id, id),
  constraint handover_note_issue_fk foreign key (tenant_id, issue_id) references public.machine_issue (tenant_id, id) on delete restrict,
  constraint handover_note_shift_fk foreign key (tenant_id, shift_id) references public.shift (tenant_id, id) on delete restrict
);
create index handover_note_issue_idx on public.handover_note (issue_id, at);

-- 3. Row-level security: Unit Admins read the tenant's rows; supervisors read through functions (step 4); nobody writes through the API ------
do $$
declare t text;
begin
  foreach t in array array['handover_setting', 'handover_session', 'issue_acknowledgement', 'handover_declaration', 'handover_exception', 'handover_note'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format($p$create policy %I on public.%I for select to authenticated
      using (tenant_id = (select app.current_tenant_id()) and (select app."current_role"()) = 'unit_admin')$p$, t || '_select_ua', t);
    execute format('revoke all on public.%I from public, anon, authenticated, service_role', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant select, insert on public.%I to service_role', t);
  end loop;
  grant update on public.handover_setting to service_role;
end $$;

-- 4. Append-only history (no privilege for any role, plus triggers that also stop the owner) ----------------------------------------------
create function app.ho_append_only()
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
  foreach t in array array['handover_session', 'issue_acknowledgement', 'handover_declaration', 'handover_exception', 'handover_note'] loop
    execute format('create trigger %I before update on public.%I for each row execute function app.ho_append_only()', t || '_no_update', t);
    execute format('create trigger %I before delete on public.%I for each row execute function app.ho_append_only()', t || '_no_delete', t);
    execute format('create trigger %I before truncate on public.%I for each statement execute function app.ho_append_only()', t || '_no_truncate', t);
  end loop;
end $$;
-- handover_setting is never deleted.
create trigger handover_setting_no_delete before delete on public.handover_setting for each row execute function app.ho_append_only();
create trigger handover_setting_no_truncate before truncate on public.handover_setting for each statement execute function app.ho_append_only();

-- Users named on a handover row must belong to its tenant (no foreign key: history outlives the membership).
create function app.ho_member_same_tenant()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ids uuid[];
begin
  if tg_table_name in ('handover_session', 'issue_acknowledgement', 'handover_declaration') then v_ids := array[new.supervisor_id];
  elsif tg_table_name = 'handover_exception' then v_ids := array[new.ua_id, new.owner_id];
  elsif tg_table_name = 'handover_note' then v_ids := array[new.author_id];
  else v_ids := array[new.updated_by];
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
  foreach t in array array['handover_setting', 'handover_session', 'issue_acknowledgement', 'handover_declaration', 'handover_exception', 'handover_note'] loop
    execute format('create trigger %I before insert or update on public.%I for each row execute function app.ho_member_same_tenant()', t || '_members', t);
  end loop;
end $$;

-- 5. D1: enforcement for every tenant that exists now and for every tenant the Console registers --------------------------------------------
create function app._ho_backfill()
returns integer
language sql
security definer
set search_path = ''
as $$
  with ins as (
    insert into public.handover_setting (tenant_id, required)
    select t.id, true from public.tenant t
    on conflict (tenant_id) do update set required = true where public.handover_setting.required = false
    returning 1)
  select count(*)::int from ins
$$;
select app._ho_backfill();

-- app.pa_tenant_create (03), redefined additively: the body is 03's unchanged plus the handover_setting row in the same transaction.
create or replace function app.pa_tenant_create(p_actor uuid, p_request_id uuid, p_name text, p_timezone text, p_plan text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth jsonb;
  v_done uuid;
  v_name text := btrim(p_name);
  v_tz text := coalesce(nullif(btrim(p_timezone), ''), 'Asia/Kolkata');
  v_plan text := coalesce(nullif(btrim(p_plan), ''), 'trial');
  t public.tenant;
begin
  v_auth := app._pa_authorise(p_actor);
  if not (v_auth->>'ok')::boolean then return v_auth; end if;
  v_done := app._pa_done(p_actor, p_request_id, array['tenant.created']);
  if v_done is not null then
    return jsonb_build_object('ok', true, 'already', true, 'tenant_id', v_done);
  end if;
  perform app._pa_validate_tenant(v_name, v_tz, v_plan, true);
  if app._pa_name_taken(v_name, null) then
    perform app._ua_fail('duplicate', 'A tenant with this name already exists', 'name');
  end if;
  begin
    insert into public.tenant (name, timezone, plan_label, status) values (v_name, v_tz, v_plan::public.plan_label, 'active') returning * into t;
  exception when unique_violation then
    perform app._ua_fail('duplicate', 'A tenant with this name already exists', 'name');
  end;
  insert into public.handover_setting (tenant_id, required) values (t.id, true);
  perform app._pa_audit(p_actor, t.id, 'tenant.created', 'tenant', t.id, null, app._pa_tenant_snapshot(t), p_request_id);
  return jsonb_build_object('ok', true, 'tenant_id', t.id);
end
$$;

create function app._ho_enforced(p_tenant uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$ select coalesce((select s.required from public.handover_setting s where s.tenant_id = p_tenant), false) $$;

-- 99. Function privileges (re-run at the end of every step): no app function is executable by clients; the public ho_* / handover_* entry points
-- are executable by authenticated only.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig, n.nspname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname = 'app' and p.proname ~ '^(ho_|_ho_|handover_)')
       or (n.nspname = 'public' and p.proname ~ '^(ho_|handover_)')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.nspname = 'public' then
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;
