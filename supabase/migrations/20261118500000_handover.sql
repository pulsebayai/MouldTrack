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
