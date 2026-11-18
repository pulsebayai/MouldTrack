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
