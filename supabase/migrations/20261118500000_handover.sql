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

-- 6. Helpers (step 2, D2-D4) ----------------------------------------------------------------------------------------------------------
-- Moment handling: the public reads and RPCs pass now(); pgTAP passes explicit moments. Rows written in the same transaction carry
-- clock_timestamp() (later than now()), so "as of the moment" means "no upper bound" when the moment is not in the past.
create function app._ho_upto(p_at timestamptz)
returns timestamptz
language sql
stable
set search_path = ''
as $$ select case when p_at is null or p_at >= now() then 'infinity'::timestamptz else p_at end $$;

-- Set-based owner resolution over a date range for ONE tenant: the machine-occurrences that have a supervisor (cover > plan; unassigned and
-- retired excluded) with their window, `since` (the cover time when a cover recorded after the start gave the machine to the supervisor, else null)
-- and the handover start (since, or the window start). The rule is a copy of 05's app.machine_owner_src and the window a copy of
-- app.shift_window (via 06's app._rd_window) for set-based queries; pgTAP 061 pins both to the originals. Covers recorded after p_at are ignored.
create function app._ho_owners(p_tenant uuid, p_from date, p_to date, p_shift uuid default null, p_at timestamptz default null)
returns table (shift_id uuid, shift_date date, machine_id uuid, supervisor_id uuid, w_start timestamptz, w_end timestamptz, since timestamptz, handover_start timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_upto timestamptz := app._ho_upto(p_at);
begin
  if p_tenant is null or p_from is null or p_to is null or p_to < p_from or p_to - p_from > 92 then
    perform app._pm_fail('validation', 'Choose a valid date range of at most 93 days', 'range');
  end if;
  return query
  with occ as (
    select s.id as sid, d.d as sdate, app._rd_window(s.start_time, s.end_time, d.d, z.timezone) as w, s.retired_at as s_retired
      from public.shift s
      join public.site z on z.id = s.site_id
      cross join lateral (select (p_from + g.n) as d from generate_series(0, p_to - p_from) as g(n)) d
     where s.tenant_id = p_tenant and (p_shift is null or s.id = p_shift)
  ), live as (
    select o.* from occ o where o.s_retired is null or o.s_retired >= upper(o.w)
  ), owned as (
    select e.sid, e.sdate, m.id as mid, e.w, cv.found as cover_found, cv.supervisor_id as cover_sup, cv.recorded_at as cover_at, pv.supervisor_id as plan_sup
      from live e
      join public.machine m on m.tenant_id = p_tenant and (m.retired_at is null or m.retired_at >= upper(e.w))
      left join lateral (select true as found, c.supervisor_id, c.recorded_at from public.assignment_cover c
                          where c.shift_id = e.sid and c.shift_date = e.sdate and c.machine_id = m.id and c.recorded_at <= v_upto
                          order by c.recorded_at desc, c.id desc limit 1) cv on true
      left join lateral (select v.supervisor_id from public.assignment_version v
                          where v.shift_id = e.sid and v.machine_id = m.id and v.effective_from <= e.sdate
                          order by v.effective_from desc, v.recorded_at desc, v.id desc limit 1) pv on true
  )
  select x.sid, x.sdate, x.mid, x.sup, lower(x.w), upper(x.w), x.since_at, coalesce(x.since_at, lower(x.w))
    from (select o.*, case when o.cover_found then o.cover_sup else o.plan_sup end as sup,
                 case when o.cover_found and o.cover_sup is not null and o.cover_at > lower(o.w) then o.cover_at end as since_at
            from owned o) x
   where x.sup is not null;
end
$$;

-- The status of an issue as of a moment: the latest action's status_after at or before it (07's history); an issue without any action row
-- (fixtures) has its current status. A moment that is not in the past reads the current row. Null = the issue did not exist yet.
create function app._ho_status_at(p_issue uuid, p_at timestamptz)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case when p_at is null or p_at >= now() then (select i.status from public.machine_issue i where i.id = p_issue)
              else coalesce((select a.status_after from public.issue_action a
                              where a.issue_id = p_issue and a.status_after is not null and a.at <= p_at order by a.at desc, a.id desc limit 1),
                            (select i.status from public.machine_issue i
                              where i.id = p_issue and i.reported_at <= p_at and not exists (select 1 from public.issue_action a where a.issue_id = i.id)))
         end
$$;

-- D4: the inherited issues of supervisor p_sup in occurrence (p_shift, p_date) as of p_at: unclosed issues on machines the supervisor owns there,
-- reported before the supervisor's handover start. state: pending | acknowledged | refused (the supervisor's latest acknowledgement made at or
-- after `since`; an earlier one is stale, AC-6). exception_pending: refused and no Unit Admin exception recorded since.
create function app.handover_items_at(p_sup uuid, p_shift uuid, p_date date, p_at timestamptz)
returns table (issue_id uuid, machine_id uuid, handover_start timestamptz, since timestamptz, status text, state text, exception_pending boolean, handled_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_upto timestamptz := app._ho_upto(p_at);
begin
  select s.tenant_id into v_tenant from public.shift s where s.id = p_shift;
  if v_tenant is null or p_sup is null or p_date is null then return; end if;
  return query
  select i.id, o.machine_id, o.handover_start, o.since, st.status,
         case when a.kind is null then 'pending' else a.kind end,
         coalesce(a.kind = 'refused' and not exists (select 1 from public.handover_exception x
                                                       where x.issue_id = i.id and x.shift_id = p_shift and x.shift_date = p_date and x.at >= a.at and x.at <= v_upto), false),
         a.at
    from app._ho_owners(v_tenant, p_date, p_date, p_shift, p_at) o
    join public.machine_issue i on i.tenant_id = v_tenant and i.machine_id = o.machine_id
    cross join lateral (select app._ho_status_at(i.id, p_at) as status) st
    left join lateral (select k.kind, k.at from public.issue_acknowledgement k
                        where k.issue_id = i.id and k.shift_id = p_shift and k.shift_date = p_date and k.supervisor_id = p_sup
                          and k.at <= v_upto and (o.since is null or k.at >= o.since)
                        order by k.at desc, k.id desc limit 1) a on true
   where o.supervisor_id = p_sup and i.reported_at < o.handover_start and st.status in ('open', 'in_progress', 'resolved')
   order by o.machine_id, i.reported_at, i.id;
end
$$;

-- D2: has the supervisor declared for the occurrence? A declaration made at or after the latest cover time among their inherited items counts
-- (a declaration made before a later cover is stale, AC-6); with no cover any declaration of the occurrence counts, made even in the 30 minutes
-- before the start.
create function app._ho_declared_at(p_sup uuid, p_shift uuid, p_date date, p_at timestamptz)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_since timestamptz;
  v_upto timestamptz := app._ho_upto(p_at);
begin
  if p_sup is null or p_shift is null or p_date is null then return false; end if;
  select max(i.since) into v_since from app.handover_items_at(p_sup, p_shift, p_date, p_at) i;
  return exists (select 1 from public.handover_declaration d
                  where d.shift_id = p_shift and d.shift_date = p_date and d.supervisor_id = p_sup and d.at <= v_upto and (v_since is null or d.at >= v_since));
end
$$;

create function app._ho_enforced(p_tenant uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$ select coalesce((select s.required from public.handover_setting s where s.tenant_id = p_tenant), false) $$;

-- 7. Write RPCs (step 3, D5, D6) ---------------------------------------------------------------------------------------------------------
-- public.ho_*: security definer, executable by authenticated. Same contract as 07's iss_*: a caller without a membership goes through
-- app._pm_authorise (audited denial, Super Admin included), members through app._ho_authorise; authorisation failures COMMIT an access.denied row and
-- RETURN {ok:false, code:'not_allowed'}; validation / guard failures RAISE P0001 with detail {code, field?}. The audit row of a success carries the
-- request id and the new row's id, so a replay returns the first outcome.

-- Authorises the caller with the given role (supervisor | unit_admin) after a per-tenant row lock; idempotency by request id + source.
create function app._ho_authorise(p_request_id uuid, p_source text, p_role text)
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
  elsif a.role::text <> p_role then
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

-- The issue (when given) and the shift must be the caller's tenant's, else the generic audited denial; the date is required. Null = fine.
create function app._ho_scope(p_a jsonb, p_src text, p_issue uuid, p_shift uuid, p_date date, p_check_issue boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_own text;
begin
  if p_check_issue then
    v_own := app._iss_owned('issue', p_issue, (p_a->>'tenant_id')::uuid);
    if v_own <> 'ok' then return app._pm_deny(p_a, v_own, 'machine_issue', p_issue, p_src); end if;
  end if;
  v_own := app._sh_owned('shift', p_shift, (p_a->>'tenant_id')::uuid);
  if v_own <> 'ok' then return app._pm_deny(p_a, v_own, 'shift', p_shift, p_src); end if;
  if p_date is null then perform app._pm_fail('validation', 'Choose the shift date', 'shift_date'); end if;
  return null;
end
$$;

-- D3: acknowledge / refuse / declare from 30 minutes before the start until 12 hours after the end; a note from the start until 2 hours after the end.
create function app._ho_window(p_shift uuid, p_date date, p_kind text)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_w tstzrange := app.shift_window(p_shift, p_date);
begin
  if v_w is null then perform app._pm_fail('guard', 'This shift is not available', 'shift_id'); end if;
  if p_kind = 'note' then
    if now() < lower(v_w) then perform app._pm_fail('guard', 'Notes open when the shift starts', 'window_not_open'); end if;
    if now() > upper(v_w) + interval '2 hours' then perform app._pm_fail('guard', 'The note window (2 hours after the shift) has passed', 'window_closed'); end if;
  else
    if now() < lower(v_w) - interval '30 minutes' then perform app._pm_fail('guard', 'The handover opens 30 minutes before the shift starts', 'window_not_open'); end if;
    if now() > upper(v_w) + interval '12 hours' then perform app._pm_fail('guard', 'The handover window (12 hours after the shift) has passed', 'window_closed'); end if;
  end if;
end
$$;

-- Does the supervisor own the machine in the occurrence (cover > plan)? Used for AC-13: another supervisor's occurrence is a denial, not a guard.
create function app._ho_owns(p_tenant uuid, p_sup uuid, p_machine uuid, p_shift uuid, p_date date)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$ select exists (select 1 from app._ho_owners(p_tenant, p_date, p_date, p_shift) o where o.machine_id = p_machine and o.supervisor_id = p_sup) $$;

-- Shared by ho_acknowledge and ho_refuse (after authorisation, scope, window and text checks): returns the item (one row) or raises the guard.
create function app._ho_pending_item(p_tenant uuid, p_sup uuid, p_issue uuid, p_shift uuid, p_date date)
returns public.machine_issue
language plpgsql
security definer
set search_path = ''
as $$
declare
  i public.machine_issue;
  it record;
begin
  select * into i from public.machine_issue x where x.id = p_issue;
  select * into it from app.handover_items_at(p_sup, p_shift, p_date, now()) x where x.issue_id = p_issue;
  if not found then
    perform app._pm_fail('guard', 'This issue is not on your handover checklist', 'not_required');
  end if;
  if it.state <> 'pending' then
    perform app._pm_fail('guard', 'You have already answered this issue', 'already_recorded');
  end if;
  return i;
end
$$;

create function public.ho_acknowledge(p_request_id uuid, p_issue_id uuid, p_shift_id uuid, p_shift_date date, p_remark text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:ho_acknowledge';
  a jsonb;
  v_deny jsonb;
  v_tenant uuid;
  v_actor uuid;
  v_remark text := nullif(btrim(p_remark), '');
  i public.machine_issue;
  v_id uuid;
  v_changed boolean;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._ho_authorise(p_request_id, c_src, 'supervisor');
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;
  v_actor := (a->>'actor')::uuid;
  v_deny := app._ho_scope(a, c_src, p_issue_id, p_shift_id, p_shift_date, true);
  if v_deny is not null then return v_deny; end if;
  perform app._pm_len(v_remark, 0, 200, 'remark', 'Remark: up to 200 characters');
  select * into i from public.machine_issue x where x.id = p_issue_id;
  if not app._ho_owns(v_tenant, v_actor, i.machine_id, p_shift_id, p_shift_date) then
    return app._pm_deny(a, 'not_owner', 'machine_issue', p_issue_id, c_src);
  end if;
  perform app._ho_window(p_shift_id, p_shift_date, 'handover');
  i := app._ho_pending_item(v_tenant, v_actor, p_issue_id, p_shift_id, p_shift_date);

  insert into public.issue_acknowledgement (tenant_id, issue_id, shift_id, shift_date, supervisor_id, kind, remark, request_id)
  values (v_tenant, i.id, p_shift_id, p_shift_date, v_actor, 'acknowledged', v_remark, p_request_id)
  returning id into v_id;
  v_changed := i.accountable_owner_id is distinct from v_actor;
  if v_changed then
    update public.machine_issue x set accountable_owner_id = v_actor, updated_at = now() where x.id = i.id;
    insert into public.issue_ownership_history (tenant_id, issue_id, previous_owner, new_owner, source, actor_id)
    values (v_tenant, i.id, i.accountable_owner_id, v_actor, 'handover', v_actor);
  end if;
  insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, notes, status_before, status_after, request_id)
  values (v_tenant, i.id, v_actor, 'supervisor', 'handover_ack', 'Acknowledged at handover' || coalesce(': ' || v_remark, ''), i.status, i.status, p_request_id);
  perform app._pm_audit(a, 'handover.acknowledged', 'issue_acknowledgement', v_id, null,
    jsonb_build_object('issue_id', i.id, 'shift_id', p_shift_id, 'shift_date', p_shift_date, 'owner_changed', v_changed, 'previous_owner', i.accountable_owner_id),
    p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', v_id, 'owner_changed', v_changed);
end
$$;

create function public.ho_refuse(p_request_id uuid, p_issue_id uuid, p_shift_id uuid, p_shift_date date, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:ho_refuse';
  a jsonb;
  v_deny jsonb;
  v_tenant uuid;
  v_actor uuid;
  v_reason text := btrim(p_reason);
  i public.machine_issue;
  v_id uuid;
  v_escalate boolean;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._ho_authorise(p_request_id, c_src, 'supervisor');
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;
  v_actor := (a->>'actor')::uuid;
  v_deny := app._ho_scope(a, c_src, p_issue_id, p_shift_id, p_shift_date, true);
  if v_deny is not null then return v_deny; end if;
  perform app._pm_len(v_reason, 1, 200, 'reason', 'Enter a reason of 1 to 200 characters');
  select * into i from public.machine_issue x where x.id = p_issue_id;
  if not app._ho_owns(v_tenant, v_actor, i.machine_id, p_shift_id, p_shift_date) then
    return app._pm_deny(a, 'not_owner', 'machine_issue', p_issue_id, c_src);
  end if;
  perform app._ho_window(p_shift_id, p_shift_date, 'handover');
  i := app._ho_pending_item(v_tenant, v_actor, p_issue_id, p_shift_id, p_shift_date);

  insert into public.issue_acknowledgement (tenant_id, issue_id, shift_id, shift_date, supervisor_id, kind, remark, request_id)
  values (v_tenant, i.id, p_shift_id, p_shift_date, v_actor, 'refused', v_reason, p_request_id)
  returning id into v_id;
  insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, notes, status_before, status_after, request_id)
  values (v_tenant, i.id, v_actor, 'supervisor', 'handover_refuse', 'Refused at handover: ' || v_reason, i.status, i.status, p_request_id);
  -- 07's escalation (owner unchanged); only an open / in progress issue can be escalated, a fix awaiting verification stays as it is
  v_escalate := i.escalated_at is null and i.status in ('open', 'in_progress');
  if v_escalate then
    update public.machine_issue x set escalated_at = now(), updated_at = now() where x.id = i.id;
    insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, notes, status_before, status_after, request_id)
    values (v_tenant, i.id, v_actor, 'supervisor', 'escalate', 'Refused at handover: ' || v_reason, i.status, i.status, p_request_id);
  end if;
  perform app._pm_audit(a, 'handover.refused', 'issue_acknowledgement', v_id, null,
    jsonb_build_object('issue_id', i.id, 'shift_id', p_shift_id, 'shift_date', p_shift_date, 'reason', v_reason, 'escalated', v_escalate),
    p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', v_id, 'escalated', v_escalate);
end
$$;

create function public.ho_declare(p_request_id uuid, p_shift_id uuid, p_shift_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:ho_declare';
  a jsonb;
  v_deny jsonb;
  v_tenant uuid;
  v_actor uuid;
  v_pending integer;
  v_ids uuid[];
  v_id uuid;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._ho_authorise(p_request_id, c_src, 'supervisor');
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;
  v_actor := (a->>'actor')::uuid;
  v_deny := app._ho_scope(a, c_src, null, p_shift_id, p_shift_date, false);
  if v_deny is not null then return v_deny; end if;
  -- only a supervisor who owns at least one machine in the occurrence has a handover to declare
  if not exists (select 1 from app._ho_owners(v_tenant, p_shift_date, p_shift_date, p_shift_id) o where o.supervisor_id = v_actor) then
    return app._pm_deny(a, 'not_owner', 'shift', p_shift_id, c_src);
  end if;
  perform app._ho_window(p_shift_id, p_shift_date, 'handover');
  select count(*) filter (where x.state = 'pending')::int, coalesce(array_agg(x.issue_id order by x.issue_id), '{}')
    into v_pending, v_ids from app.handover_items_at(v_actor, p_shift_id, p_shift_date, now()) x;
  if v_pending > 0 then
    perform app._pm_fail('guard', 'Acknowledge or refuse every issue first', 'items_pending', jsonb_build_object('pending', v_pending));
  end if;
  if app._ho_declared_at(v_actor, p_shift_id, p_shift_date, now()) then
    perform app._pm_fail('guard', 'You have already declared this handover', 'already_declared');
  end if;
  insert into public.handover_declaration (tenant_id, shift_id, shift_date, supervisor_id, text_version, covered_issue_ids, request_id)
  values (v_tenant, p_shift_id, p_shift_date, v_actor, 1, v_ids, p_request_id)
  returning id into v_id;
  perform app._pm_audit(a, 'handover.declared', 'handover_declaration', v_id, null,
    jsonb_build_object('shift_id', p_shift_id, 'shift_date', p_shift_date, 'issues', cardinality(v_ids), 'text_version', 1), p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', v_id, 'issues', cardinality(v_ids));
end
$$;

create function public.ho_add_note(p_request_id uuid, p_issue_id uuid, p_shift_id uuid, p_shift_date date, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:ho_add_note';
  a jsonb;
  v_deny jsonb;
  v_tenant uuid;
  v_actor uuid;
  v_note text := btrim(p_note);
  i public.machine_issue;
  v_id uuid;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._ho_authorise(p_request_id, c_src, 'supervisor');
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;
  v_actor := (a->>'actor')::uuid;
  v_deny := app._ho_scope(a, c_src, p_issue_id, p_shift_id, p_shift_date, true);
  if v_deny is not null then return v_deny; end if;
  perform app._pm_len(v_note, 1, 300, 'note', 'Enter a note of 1 to 300 characters');
  select * into i from public.machine_issue x where x.id = p_issue_id;
  if not app._ho_owns(v_tenant, v_actor, i.machine_id, p_shift_id, p_shift_date) then
    return app._pm_deny(a, 'not_owner', 'machine_issue', p_issue_id, c_src);
  end if;
  perform app._ho_window(p_shift_id, p_shift_date, 'note');
  if i.status not in ('open', 'in_progress') then
    perform app._pm_fail('guard', 'A note can only be added to an unresolved issue', 'invalid_status');
  end if;
  insert into public.handover_note (tenant_id, issue_id, author_id, shift_id, shift_date, note, request_id)
  values (v_tenant, i.id, v_actor, p_shift_id, p_shift_date, v_note, p_request_id)
  returning id into v_id;
  perform app._pm_audit(a, 'handover.note_added', 'handover_note', v_id, null,
    jsonb_build_object('issue_id', i.id, 'shift_id', p_shift_id, 'shift_date', p_shift_date), p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', v_id);
end
$$;

-- AC-7: a Unit Admin records the exception for an issue a supervisor refused in the occurrence: reason + the owner afterwards. The owner is an
-- active supervisor; choosing the current accountable owner keeps the issue with them (kept = true, no ownership row), anyone else is a 07 reassign.
create function public.ho_exception(p_request_id uuid, p_issue_id uuid, p_shift_id uuid, p_shift_date date, p_reason text, p_owner_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:ho_exception';
  a jsonb;
  v_deny jsonb;
  v_tenant uuid;
  v_actor uuid;
  v_reason text := btrim(p_reason);
  v_own text;
  i public.machine_issue;
  r public.issue_acknowledgement;
  v_kept boolean;
  v_id uuid;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._ho_authorise(p_request_id, c_src, 'unit_admin');
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;
  v_actor := (a->>'actor')::uuid;
  v_deny := app._ho_scope(a, c_src, p_issue_id, p_shift_id, p_shift_date, true);
  if v_deny is not null then return v_deny; end if;
  if p_owner_id is not null then
    v_own := app._sh_owned('member', p_owner_id, v_tenant);
    if v_own <> 'ok' then return app._pm_deny(a, v_own, 'member', p_owner_id, c_src); end if;
  end if;
  perform app._pm_len(v_reason, 1, 200, 'reason', 'Enter a reason of 1 to 200 characters');
  if p_owner_id is null or app._iss_active_sup(p_owner_id) is null then perform app._pm_fail('validation', 'Choose an active supervisor', 'owner'); end if;
  select * into i from public.machine_issue x where x.id = p_issue_id;
  if i.status = 'closed' then perform app._pm_fail('guard', 'This issue is closed', 'invalid_status'); end if;
  -- the latest refusal of this issue in this occurrence must still be waiting for an exception
  select k.* into r from public.issue_acknowledgement k
   where k.issue_id = i.id and k.shift_id = p_shift_id and k.shift_date = p_shift_date and k.kind = 'refused'
   order by k.at desc, k.id desc limit 1;
  if r.id is null or exists (select 1 from public.handover_exception x where x.issue_id = i.id and x.shift_id = p_shift_id and x.shift_date = p_shift_date and x.at >= r.at) then
    perform app._pm_fail('guard', 'No refusal is waiting for an exception on this issue', 'no_pending_exception');
  end if;
  v_kept := i.accountable_owner_id is not distinct from p_owner_id;
  insert into public.handover_exception (tenant_id, issue_id, shift_id, shift_date, ua_id, reason, owner_id, kept, request_id)
  values (v_tenant, i.id, p_shift_id, p_shift_date, v_actor, v_reason, p_owner_id, v_kept, p_request_id)
  returning id into v_id;
  if not v_kept then
    update public.machine_issue x set accountable_owner_id = p_owner_id, escalated_at = null, updated_at = now() where x.id = i.id;
    insert into public.issue_ownership_history (tenant_id, issue_id, previous_owner, new_owner, source, reason, actor_id)
    values (v_tenant, i.id, i.accountable_owner_id, p_owner_id, 'reassign', v_reason, v_actor);
    insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, notes, status_before, status_after, request_id)
    values (v_tenant, i.id, v_actor, 'unit_admin', 'reassign', v_reason, i.status, i.status, p_request_id);
  end if;
  perform app._pm_audit(a, 'handover.exception', 'handover_exception', v_id, jsonb_build_object('owner_id', i.accountable_owner_id),
    jsonb_build_object('issue_id', i.id, 'shift_id', p_shift_id, 'shift_date', p_shift_date, 'owner_id', p_owner_id, 'kept', v_kept, 'reason', v_reason), p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', v_id, 'kept', v_kept);
end
$$;

-- AC-8: the overdue minutes (15-480). A tenant without a setting row (a directly inserted one) gets a row with required = false: this RPC never
-- switches enforcement on or off.
create function public.ho_set_overdue(p_request_id uuid, p_minutes integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:ho_set_overdue';
  a jsonb;
  v_tenant uuid;
  v_before integer;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._ho_authorise(p_request_id, c_src, 'unit_admin');
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;
  if p_minutes is null or p_minutes < 15 or p_minutes > 480 then
    perform app._pm_fail('validation', 'Enter 15 to 480 minutes', 'minutes');
  end if;
  select s.overdue_minutes into v_before from public.handover_setting s where s.tenant_id = v_tenant;
  if found then
    update public.handover_setting s set overdue_minutes = p_minutes, updated_by = (a->>'actor')::uuid, updated_at = now() where s.tenant_id = v_tenant;
  else
    insert into public.handover_setting (tenant_id, overdue_minutes, required, updated_by) values (v_tenant, p_minutes, false, (a->>'actor')::uuid);
  end if;
  perform app._pm_audit(a, 'handover.setting_updated', 'handover_setting', v_tenant, jsonb_build_object('overdue_minutes', coalesce(v_before, 60)),
    jsonb_build_object('overdue_minutes', p_minutes), p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', v_tenant, 'overdue_minutes', p_minutes);
end
$$;

-- 8. The gate on 06's rd_opening (D6): 06's body unchanged plus the handover check after the owner/role check. Additive redefinition; 06's tests
-- record supervisor openings in tenants without a handover_setting row, which are not enforced (D1), so they pass unchanged.
create or replace function public.rd_opening(
  p_request_id uuid, p_machine_id uuid, p_shift_id uuid, p_shift_date date, p_product_id uuid, p_counter bigint, p_remarks text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:rd_opening';
  a jsonb;
  v_tenant uuid;
  v_deny jsonb;
  v_own text;
  v_remarks text;
  m public.machine;
  p public.product;
  s public.shift;
  v_w tstzrange;
  cur public.production_reading;
  v_late boolean;
  v_ua boolean;
  v_id uuid;
begin
  if not exists (select 1 from public.membership x where x.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._rd_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;

  v_deny := app._rd_check(a, p_machine_id, p_shift_id, p_shift_date, c_src);
  if v_deny is not null then return v_deny; end if;
  -- 08 (D6): in an enforced tenant a supervisor records the opening only after declaring the handover for the occurrence. A Unit Admin entering on
  -- the supervisor's behalf is not gated (the occurrence then shows "No declaration" in the compliance metric).
  if a->>'role' = 'supervisor' and app._ho_enforced(v_tenant)
     and not app._ho_declared_at((a->>'actor')::uuid, p_shift_id, p_shift_date, now()) then
    perform app._pm_fail('guard', 'Complete your handover checklist first', 'handover_pending');
  end if;
  if p_product_id is null then perform app._pm_fail('validation', 'Choose the product', 'product_id'); end if;
  v_own := app._pm_owned('product', p_product_id, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'product', p_product_id, c_src); end if;
  perform app._rd_counter_ok(p_counter, 'counter', 'Counter');
  v_remarks := app._rd_remarks(p_remarks);

  select * into m from public.machine x where x.id = p_machine_id;
  select * into p from public.product x where x.id = p_product_id;
  select * into s from public.shift x where x.id = p_shift_id;
  if m.retired_at is not null then perform app._pm_fail('guard', 'This machine is retired', 'machine_retired'); end if;
  if p.retired_at is not null then perform app._pm_fail('guard', 'This product is retired', 'product_id'); end if;
  if s.retired_at is not null then perform app._pm_fail('guard', 'This shift is retired', 'shift_retired'); end if;

  -- D5 (8a R4): allowed from 30 minutes before the occurrence starts until 12 hours after it ends (late readings are accepted and flagged Late).
  v_w := app.shift_window(p_shift_id, p_shift_date);
  if now() < lower(v_w) - interval '30 minutes' then
    perform app._pm_fail('guard', 'The opening reading opens 30 minutes before the shift starts', 'window_not_open');
  end if;
  if now() > upper(v_w) + interval '12 hours' then
    perform app._pm_fail('guard', 'The opening window (12 hours after the shift) has passed', 'window_closed');
  end if;
  select * into cur from app._rd_current(p_machine_id, p_shift_id, p_shift_date, 'opening');
  if cur.id is not null then
    perform app._pm_fail('guard', 'The opening reading is already recorded. Submit a correction instead.', 'already_recorded');
  end if;

  v_late := app._rd_is_late(lower(v_w), now());
  v_ua := a->>'role' = 'unit_admin';
  insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, remarks, late, entered_by_ua, recorded_by, recorded_at, request_id)
  values (v_tenant, p_machine_id, p_shift_id, p_shift_date, 'opening', p_product_id, p_counter, v_remarks, v_late, v_ua, (a->>'actor')::uuid, now(), p_request_id)
  returning id into v_id;
  perform app._pm_audit(a, 'reading.opening', 'production_reading', v_id, null,
    jsonb_build_object('machine_code', m.code, 'shift_id', p_shift_id, 'shift_date', p_shift_date, 'product_code', p.code, 'counter', p_counter,
                       'late', v_late, 'entered_by_ua', v_ua),
    p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', v_id, 'late', v_late, 'entered_by_ua', v_ua);
end
$$;

-- 9. Reads and compliance (step 4, D7) -------------------------------------------------------------------------------------------------
-- R1 of 07's review: clients cannot choose the clock. The bodies are app.*_at(p_at) (pgTAP passes explicit moments; only the owner can execute
-- them) and the public RPCs are thin wrappers that always pass now() and route callers without a membership through app._pm_authorise.

-- The overdue minutes in force for a supervisor's handover start: the session snapshot taken when the checklist first opened (AC-8), else the
-- tenant's current setting, else 60.
create function app._ho_overdue_for(p_tenant uuid, p_shift uuid, p_date date, p_sup uuid, p_start timestamptz)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select s.overdue_minutes from public.handover_session s
      where s.tenant_id = p_tenant and s.shift_id = p_shift and s.shift_date = p_date and s.supervisor_id = p_sup and s.handover_start = p_start),
    (select h.overdue_minutes from public.handover_setting h where h.tenant_id = p_tenant),
    60)
$$;

-- AC-1: the caller's checklists: every occurrence where they own a machine from 30 minutes before the start until the end (and, until 12 hours
-- after the end, while the declaration is still missing), with the inherited issues grouped by machine, the outgoing note, the last 3 actions, what
-- may be done now (allowed_actions) and the "Verify this fix" section. The only write from a read (D7): the first read of an occurrence inserts
-- the handover_session row (overdue minutes snapshot), at most once per (supervisor, occurrence, handover start).
create function app.handover_checklist_at(p_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:handover_checklist';
  a jsonb;
  v_tenant uuid;
  v_actor uuid;
  v_setting integer;
  v_date date;
  r record;
  v_occ jsonb := '[]'::jsonb;
  v_machines jsonb;
  v_items jsonb;
  v_pending integer;
  v_total_pending integer := 0;
  v_declared boolean;
  v_declared_at timestamptz;
  v_last_start timestamptz;
  v_overdue integer;
  v_verify jsonb;
  v_upto timestamptz := app._ho_upto(p_at);
begin
  if not exists (select 1 from public.membership x where x.user_id = auth.uid()) then
    return app._pm_authorise(null, c_src);
  end if;
  a := app._sh_read_authorise(c_src, false);
  if not (a->>'ok')::boolean then return a; end if;
  v_tenant := (a->>'tenant_id')::uuid;
  v_actor := (a->>'actor')::uuid;
  if a->>'role' <> 'supervisor' then
    perform app.audit_denied(v_actor, v_tenant, a->>'role', 'role', null, null, c_src);
    return jsonb_build_object('ok', false, 'code', 'not_allowed');
  end if;
  v_setting := coalesce((select h.overdue_minutes from public.handover_setting h where h.tenant_id = v_tenant), 60);
  v_date := app.plant_date_at(v_tenant, p_at);

  for r in
    select o.shift_id, o.shift_date, s.name as shift_name, s.start_time, s.end_time, min(o.w_start) as w_start, max(o.w_end) as w_end
      from app._ho_owners(v_tenant, v_date - 2, v_date + 1, null, p_at) o
      join public.shift s on s.id = o.shift_id
     where o.supervisor_id = v_actor and p_at >= o.w_start - interval '30 minutes' and p_at <= o.w_end + interval '12 hours'
     group by o.shift_id, o.shift_date, s.name, s.start_time, s.end_time
     order by min(o.w_start), o.shift_id
  loop
    v_declared := app._ho_declared_at(v_actor, r.shift_id, r.shift_date, p_at);
    -- after the end the checklist stays only while a declaration is still missing (a late supervisor can still declare, D3)
    continue when p_at > r.w_end and v_declared;
    -- the session snapshot(s): the window start, and every cover time that gave the supervisor a machine later (AC-6, AC-8)
    insert into public.handover_session (tenant_id, shift_id, shift_date, supervisor_id, handover_start, overdue_minutes)
    select v_tenant, r.shift_id, r.shift_date, v_actor, x.st, v_setting
      from (select r.w_start as st union select o.since from app._ho_owners(v_tenant, r.shift_date, r.shift_date, r.shift_id, p_at) o
             where o.supervisor_id = v_actor and o.since is not null) x
    on conflict do nothing;

    -- one pass over the inherited items (grouped by machine, ordered by code, issues by reported time)
    select coalesce(jsonb_agg(q.mj order by q.code), '[]'::jsonb), coalesce(sum(q.pending), 0)::int, coalesce(max(q.hs), r.w_start)
      into v_machines, v_pending, v_last_start
      from (
        select g.code, g.pending, g.hs,
               jsonb_build_object('machine_id', g.machine_id, 'code', g.code, 'name', g.name, 'items', g.items) as mj
          from (
            select i.machine_id, mc.code, mc.name, count(*) filter (where i.state = 'pending')::int as pending, max(i.handover_start) as hs,
                   jsonb_agg(
                     app._iss_row(i.issue_id, p_at) || jsonb_build_object(
                       'state', i.state, 'exception_pending', i.exception_pending, 'handled_at', i.handled_at, 'handover_start', i.handover_start,
                       'previous_owner_name', (select pm.full_name from public.membership pm
                                                 where pm.user_id = case when mi.accountable_owner_id is distinct from v_actor then mi.accountable_owner_id
                                                                         else (select h.previous_owner from public.issue_ownership_history h where h.issue_id = mi.id and h.new_owner = v_actor order by h.at desc limit 1) end),
                       'last_actions', (select coalesce(jsonb_agg(jsonb_build_object('type', q2.type, 'notes', q2.notes, 'at', q2.at, 'actor_name', am.full_name) order by q2.at desc, q2.id desc), '[]'::jsonb)
                                          from (select ia.id, ia.type, ia.notes, ia.at, ia.actor_id from public.issue_action ia where ia.issue_id = i.issue_id and ia.at <= v_upto order by ia.at desc, ia.id desc limit 3) q2
                                          left join public.membership am on am.user_id = q2.actor_id),
                       'note', (select jsonb_build_object('note', n.note, 'at', n.at, 'author_name', nm.full_name, 'shift_date', n.shift_date)
                                  from public.handover_note n left join public.membership nm on nm.user_id = n.author_id
                                 where n.issue_id = i.issue_id and n.at <= v_upto order by n.at desc, n.id desc limit 1),
                       'allowed_actions', (case when i.state = 'pending' then '["acknowledge","refuse"]'::jsonb else '[]'::jsonb end)
                                           || (case when i.status in ('open', 'in_progress') and p_at >= r.w_start and p_at <= r.w_end + interval '2 hours' then '["add_note"]'::jsonb else '[]'::jsonb end))
                     order by mi.reported_at, mi.id) as items
              from app.handover_items_at(v_actor, r.shift_id, r.shift_date, p_at) i
              join public.machine mc on mc.id = i.machine_id
              join public.machine_issue mi on mi.id = i.issue_id
             group by i.machine_id, mc.code, mc.name) g) q;

    select max(d.at) into v_declared_at from public.handover_declaration d
     where d.shift_id = r.shift_id and d.shift_date = r.shift_date and d.supervisor_id = v_actor and d.at <= v_upto;
    v_overdue := app._ho_overdue_for(v_tenant, r.shift_id, r.shift_date, v_actor, v_last_start);
    v_total_pending := v_total_pending + v_pending;
    v_occ := v_occ || jsonb_build_array(jsonb_build_object(
      'shift', jsonb_build_object('id', r.shift_id, 'name', r.shift_name, 'start_time', r.start_time, 'end_time', r.end_time),
      'shift_date', r.shift_date, 'window_start', r.w_start, 'window_end', r.w_end,
      'running', p_at >= r.w_start and p_at < r.w_end,
      'enforced', app._ho_enforced(v_tenant),
      'machines', v_machines, 'pending_count', v_pending,
      'declared', v_declared, 'declared_at', v_declared_at,
      'overdue_minutes', v_overdue, 'deadline', v_last_start + make_interval(mins => v_overdue),
      'allowed_actions', case when v_pending = 0 and not v_declared then '["declare"]'::jsonb else '[]'::jsonb end));
  end loop;

  -- "Verify this fix": resolved High/Critical issues the caller may verify now (non-blocking; 07's verify action does the rest)
  select coalesce(jsonb_agg(app._iss_row(q.id, p_at) order by q.resolved_at, q.id), '[]'::jsonb) into v_verify
    from (select i.id, i.resolved_at from public.machine_issue i
           where i.tenant_id = v_tenant and i.status = 'resolved' and i.priority in ('high', 'critical') and app.issue_can_verify(i.id, v_actor, p_at)
           order by i.resolved_at, i.id limit 20) q;
  return jsonb_build_object('ok', true, 'occurrences', v_occ, 'pending_total', v_total_pending, 'verify', v_verify);
end
$$;

-- AC-9: the Unit Admin's handover alerts: refusals waiting for an exception (oldest first) and overdue acknowledgements (most overdue first), each
-- bounded to 50 with the totals (07's bounded pattern; the screens show 5 on Home and "View all").
create function app.handover_alerts_at(p_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:handover_alerts';
  a jsonb;
  v_tenant uuid;
  v_date date;
  v_upto timestamptz := app._ho_upto(p_at);
  v_exc jsonb;
  v_exc_total integer;
  v_over jsonb;
  v_over_all jsonb;
  v_over_total integer;
begin
  if not exists (select 1 from public.membership x where x.user_id = auth.uid()) then
    return app._pm_authorise(null, c_src);
  end if;
  a := app._sh_read_authorise(c_src, true);
  if not (a->>'ok')::boolean then return a; end if;
  v_tenant := (a->>'tenant_id')::uuid;
  v_date := app.plant_date_at(v_tenant, p_at);

  -- overdue acknowledgements: a pending item whose deadline (handover start + the overdue minutes in force) has passed, in an occurrence that is
  -- running or ended less than 12 hours ago (older ones belong to the compliance report)
  select coalesce(jsonb_agg(jsonb_build_object('supervisor_id', q.sup, 'supervisor_name', q.sup_name, 'shift_id', q.shift_id, 'shift_name', q.shift_name,
           'shift_date', q.shift_date, 'machine_code', q.machine_code, 'issue_id', q.issue_id, 'description', q.description, 'priority', q.priority,
           'minutes_overdue', q.minutes_overdue) order by q.minutes_overdue desc, q.issue_id), '[]'::jsonb) into v_over_all
    from (select x.sup, mm.full_name as sup_name, x.shift_id, sh.name as shift_name, x.shift_date, mc.code as machine_code, i.issue_id, mi.description, mi.priority,
                 floor(extract(epoch from (p_at - (i.handover_start + make_interval(mins => app._ho_overdue_for(v_tenant, x.shift_id, x.shift_date, x.sup, i.handover_start))))) / 60)::int as minutes_overdue
            from (select distinct o.supervisor_id as sup, o.shift_id, o.shift_date from app._ho_owners(v_tenant, v_date - 2, v_date + 1, null, p_at) o
                   where o.w_start <= p_at and p_at <= o.w_end + interval '12 hours') x
            cross join lateral app.handover_items_at(x.sup, x.shift_id, x.shift_date, p_at) i
            join public.machine mc on mc.id = i.machine_id
            join public.machine_issue mi on mi.id = i.issue_id
            join public.shift sh on sh.id = x.shift_id
            left join public.membership mm on mm.user_id = x.sup
           where i.state = 'pending'
             and p_at > i.handover_start + make_interval(mins => app._ho_overdue_for(v_tenant, x.shift_id, x.shift_date, x.sup, i.handover_start))) q;
  v_over_total := jsonb_array_length(v_over_all);
  select coalesce(jsonb_agg(e.v order by e.n), '[]'::jsonb) into v_over from jsonb_array_elements(v_over_all) with ordinality e(v, n) where e.n <= 50;

  -- refusals waiting for an exception: the latest refusal of an issue in an occurrence with no exception recorded since (last 14 days)
  select count(*)::int into v_exc_total from public.issue_acknowledgement k
   where k.tenant_id = v_tenant and k.kind = 'refused' and k.at <= v_upto and k.at >= p_at - interval '14 days'
     and not exists (select 1 from public.issue_acknowledgement k2 where k2.issue_id = k.issue_id and k2.shift_id = k.shift_id and k2.shift_date = k.shift_date and k2.kind = 'refused' and (k2.at, k2.id) > (k.at, k.id))
     and not exists (select 1 from public.handover_exception x where x.issue_id = k.issue_id and x.shift_id = k.shift_id and x.shift_date = k.shift_date and x.at >= k.at and x.at <= v_upto);
  select coalesce(jsonb_agg(jsonb_build_object('issue_id', q.issue_id, 'supervisor_id', q.supervisor_id, 'supervisor_name', q.sup_name, 'shift_id', q.shift_id,
           'shift_name', q.shift_name, 'shift_date', q.shift_date, 'machine_code', q.code, 'description', q.description, 'priority', q.priority, 'reason', q.remark,
           'refused_at', q.at, 'owner_id', q.owner_id, 'owner_name', q.owner_name, 'minutes_waiting', floor(extract(epoch from (p_at - q.at)) / 60)::int) order by q.at, q.id), '[]'::jsonb)
    into v_exc
    from (select k.id, k.issue_id, k.supervisor_id, sm.full_name as sup_name, k.shift_id, sh.name as shift_name, k.shift_date, mc.code, mi.description, mi.priority, k.remark, k.at,
                 mi.accountable_owner_id as owner_id, om.full_name as owner_name
            from public.issue_acknowledgement k
            join public.machine_issue mi on mi.id = k.issue_id join public.machine mc on mc.id = mi.machine_id join public.shift sh on sh.id = k.shift_id
            left join public.membership sm on sm.user_id = k.supervisor_id left join public.membership om on om.user_id = mi.accountable_owner_id
           where k.tenant_id = v_tenant and k.kind = 'refused' and k.at <= v_upto and k.at >= p_at - interval '14 days'
             and not exists (select 1 from public.issue_acknowledgement k2 where k2.issue_id = k.issue_id and k2.shift_id = k.shift_id and k2.shift_date = k.shift_date and k2.kind = 'refused' and (k2.at, k2.id) > (k.at, k.id))
             and not exists (select 1 from public.handover_exception x where x.issue_id = k.issue_id and x.shift_id = k.shift_id and x.shift_date = k.shift_date and x.at >= k.at and x.at <= v_upto)
           order by k.at, k.id limit 50) q;
  return jsonb_build_object('ok', true, 'exceptions', v_exc, 'exceptions_total', v_exc_total, 'overdue', v_over, 'overdue_total', v_over_total,
                            'alert_count', v_exc_total + v_over_total);
end
$$;

-- AC-12: handover compliance per (supervisor, occurrence) for the occurrences that have ended by p_at (app-only; 09 wraps it; product metric 2).
-- compliant = a valid declaration made by the deadline AND every inherited issue answered by its deadline (acknowledged, or refused with a Unit Admin
-- exception recorded). reason: no_declaration | late | exception_missing. overdue_acks counts the inherited issues not answered by their deadline
-- (unanswered or answered late). An issue closed before its deadline without an answer drops out. Machine-occurrences with no supervisor are not
-- counted. Deadline = handover start (window start, or the cover time) + the minutes snapshotted when the checklist first opened (else the setting).
create function app.handover_compliance_at(p_tenant uuid, p_from date, p_to date, p_at timestamptz)
returns table (supervisor_id uuid, shift_id uuid, shift_date date, compliant boolean, reason text, declared_at timestamptz, deadline timestamptz,
               issues integer, answered_in_time integer, overdue_acks integer, refused_without_exception integer)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_tenant is null or p_from is null or p_to is null or p_to < p_from then
    perform app._pm_fail('validation', 'Choose a valid date range', 'range');
  end if;
  return query
  with so as (
    select o.* from app._ho_owners(p_tenant, p_from, p_to, null, p_at) o where o.w_end <= p_at
  ), items as (
    select so.supervisor_id as sup, so.shift_id as sid, so.shift_date as sdate, so.w_start, so.since, i.id as issue_id,
           so.handover_start + make_interval(mins => app._ho_overdue_for(p_tenant, so.shift_id, so.shift_date, so.supervisor_id, so.handover_start)) as dl
      from so join public.machine_issue i on i.tenant_id = p_tenant and i.machine_id = so.machine_id and i.reported_at < so.handover_start
     where app._ho_status_at(i.id, so.handover_start) in ('open', 'in_progress', 'resolved')
  ), answered as (
    select it.*, k.kind, k.at as k_at,
           exists (select 1 from public.handover_exception x where x.issue_id = it.issue_id and x.shift_id = it.sid and x.shift_date = it.sdate and k.at is not null and x.at >= k.at and x.at <= app._ho_upto(p_at)) as has_exc
      from items it
      left join lateral (select k.kind, k.at from public.issue_acknowledgement k
                          where k.issue_id = it.issue_id and k.shift_id = it.sid and k.shift_date = it.sdate and k.supervisor_id = it.sup
                            and (it.since is null or k.at >= it.since)
                          order by k.at, k.id limit 1) k on true
  ), live_items as (
    -- an unanswered issue that was already closed at its deadline dropped out of the checklist
    select x.* from answered x where not (x.k_at is null and app._ho_status_at(x.issue_id, least(x.dl, p_at)) = 'closed')
  ), per_item as (
    select x.sup, x.sid, x.sdate, x.since, x.dl,
           (x.k_at is not null and x.k_at <= x.dl) as in_time,
           (x.k_at is null or x.k_at > x.dl) as overdue,
           (x.kind = 'refused' and not x.has_exc) as refused_no_exc
      from live_items x
  ), per_so as (
    select s.supervisor_id as sup, s.shift_id as sid, s.shift_date as sdate, min(s.w_start) as w_start
      from so s group by s.supervisor_id, s.shift_id, s.shift_date
  ), agg as (
    select p.sup, p.sid, p.sdate, p.w_start,
           count(pi.sup)::int as n_items, (count(*) filter (where pi.in_time))::int as n_in_time, (count(*) filter (where pi.overdue))::int as n_overdue,
           (count(*) filter (where pi.refused_no_exc))::int as n_refused_no_exc, max(pi.since) as since_max, max(pi.dl) as dl_items
      from per_so p left join per_item pi on pi.sup = p.sup and pi.sid = p.sid and pi.sdate = p.sdate
     group by p.sup, p.sid, p.sdate, p.w_start
  ), dec as (
    select g.*, coalesce(g.dl_items, g.w_start + make_interval(mins => app._ho_overdue_for(p_tenant, g.sid, g.sdate, g.sup, g.w_start))) as decl_dl,
           (select min(d.at) from public.handover_declaration d
             where d.shift_id = g.sid and d.shift_date = g.sdate and d.supervisor_id = g.sup and (g.since_max is null or d.at >= g.since_max)) as decl_at
      from agg g
  )
  select d.sup, d.sid, d.sdate,
         (d.decl_at is not null and d.decl_at <= d.decl_dl and d.n_overdue = 0 and d.n_refused_no_exc = 0),
         case when d.decl_at is null then 'no_declaration'
              when d.decl_at > d.decl_dl or d.n_overdue > 0 then 'late'
              when d.n_refused_no_exc > 0 then 'exception_missing' end,
         d.decl_at, d.decl_dl, d.n_items, d.n_in_time, d.n_overdue, d.n_refused_no_exc
    from dec d
   order by d.sdate, d.sid, d.sup;
end
$$;
create function app.handover_compliance(p_tenant uuid, p_from date, p_to date)
returns table (supervisor_id uuid, shift_id uuid, shift_date date, compliant boolean, reason text, declared_at timestamptz, deadline timestamptz,
               issues integer, answered_in_time integer, overdue_acks integer, refused_without_exception integer)
language sql
stable
security definer
set search_path = ''
as $$ select * from app.handover_compliance_at(p_tenant, p_from, p_to, now()) $$;

create function public.handover_checklist()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(null, 'rpc:handover_checklist');
  end if;
  return app.handover_checklist_at(now());
end
$$;
create function public.handover_alerts()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(null, 'rpc:handover_alerts');
  end if;
  return app.handover_alerts_at(now());
end
$$;

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
