-- 08 step 8b (Opus final review): two fixes, additive (20261118500000 is already applied on dev and is not edited).
--
-- S1  The overdue-minutes snapshot (handover_session) is taken at the supervisor's FIRST INTERACTION of any kind with the occurrence: reading the
--     checklist (as before), ho_acknowledge, ho_refuse, ho_declare, or the rd_opening gate check. So a later ho_set_overdue can no longer rewrite
--     compliance for an occurrence the supervisor already acted on. Snapshot = the value in force at that first interaction. The fallback to the
--     tenant's current setting (then 60) remains only for an occurrence with no interaction at all; that occurrence is `no_declaration` whatever the
--     minutes, and has no acknowledgements that could count as overdue. (A call that fails and raises rolls its snapshot back with it; the first
--     successful interaction takes it.)
-- S2  A cover that gives a machine to the supervisor who already owned it just before (the previous cover, else the plan owner) is a no-op and does
--     not set `since`; a repeated cover to the same new supervisor keeps the time of the first cover of that run. So it cannot make a valid
--     declaration or acknowledgement stale (AC-6 applies to a real change of supervisor only).

-- S1 helper: the session snapshot(s) for supervisor p_sup in occurrence (p_shift, p_date): the window start and every cover time that gave the
-- supervisor a machine later (the same rows the checklist read writes), with the setting in force now. Idempotent (on conflict do nothing).
create function app._ho_snapshot(p_tenant uuid, p_shift uuid, p_date date, p_sup uuid)
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  insert into public.handover_session (tenant_id, shift_id, shift_date, supervisor_id, handover_start, overdue_minutes)
  select p_tenant, p_shift, p_date, p_sup, x.st, coalesce((select h.overdue_minutes from public.handover_setting h where h.tenant_id = p_tenant), 60)
    from (select o.w_start as st from app._ho_owners(p_tenant, p_date, p_date, p_shift) o where o.supervisor_id = p_sup
          union
          select o.since from app._ho_owners(p_tenant, p_date, p_date, p_shift) o where o.supervisor_id = p_sup and o.since is not null) x
  on conflict do nothing
$$;

-- S2: app._ho_owners with the no-op cover rule. Same signature and columns as before; only `since` changes. For the latest cover (as of p_at) the
-- run it belongs to starts after the latest earlier cover to a DIFFERENT supervisor (br); the owner before the run is that cover's supervisor, else
-- the plan owner. since = the first cover time of the run when the supervisor differs from that owner and the time is after the window start.
create or replace function app._ho_owners(p_tenant uuid, p_from date, p_to date, p_shift uuid default null, p_at timestamptz default null)
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
    select e.sid, e.sdate, m.id as mid, e.w, cv.found as cover_found, cv.supervisor_id as cover_sup, pv.supervisor_id as plan_sup,
           (select min(c.recorded_at) from public.assignment_cover c
             where c.shift_id = e.sid and c.shift_date = e.sdate and c.machine_id = m.id and c.recorded_at <= v_upto
               and (br.found is null or (c.recorded_at, c.id) > (br.recorded_at, br.id))) as run_at,
           case when br.found then br.supervisor_id else pv.supervisor_id end as before_sup
      from live e
      join public.machine m on m.tenant_id = p_tenant and (m.retired_at is null or m.retired_at >= upper(e.w))
      left join lateral (select true as found, c.supervisor_id, c.recorded_at from public.assignment_cover c
                          where c.shift_id = e.sid and c.shift_date = e.sdate and c.machine_id = m.id and c.recorded_at <= v_upto
                          order by c.recorded_at desc, c.id desc limit 1) cv on true
      left join lateral (select v.supervisor_id from public.assignment_version v
                          where v.shift_id = e.sid and v.machine_id = m.id and v.effective_from <= e.sdate
                          order by v.effective_from desc, v.recorded_at desc, v.id desc limit 1) pv on true
      left join lateral (select true as found, c.id, c.supervisor_id, c.recorded_at from public.assignment_cover c
                          where cv.found and c.shift_id = e.sid and c.shift_date = e.sdate and c.machine_id = m.id and c.recorded_at <= v_upto
                            and c.supervisor_id is distinct from cv.supervisor_id
                          order by c.recorded_at desc, c.id desc limit 1) br on true
  )
  select x.sid, x.sdate, x.mid, x.sup, lower(x.w), upper(x.w), x.since_at, coalesce(x.since_at, lower(x.w))
    from (select o.*, case when o.cover_found then o.cover_sup else o.plan_sup end as sup,
                 case when o.cover_found and o.cover_sup is not null and o.run_at > lower(o.w) and o.cover_sup is distinct from o.before_sup then o.run_at end as since_at
            from owned o) x
   where x.sup is not null;
end
$$;

-- S1: the four writers, bodies unchanged from 20261118500000 plus the snapshot call (before the first row they write).
create or replace function public.ho_acknowledge(p_request_id uuid, p_issue_id uuid, p_shift_id uuid, p_shift_date date, p_remark text default null)
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

  perform app._ho_snapshot(v_tenant, p_shift_id, p_shift_date, v_actor);
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
create or replace function public.ho_refuse(p_request_id uuid, p_issue_id uuid, p_shift_id uuid, p_shift_date date, p_reason text)
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

  perform app._ho_snapshot(v_tenant, p_shift_id, p_shift_date, v_actor);
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
create or replace function public.ho_declare(p_request_id uuid, p_shift_id uuid, p_shift_date date)
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
  perform app._ho_snapshot(v_tenant, p_shift_id, p_shift_date, v_actor);
  insert into public.handover_declaration (tenant_id, shift_id, shift_date, supervisor_id, text_version, covered_issue_ids, request_id)
  values (v_tenant, p_shift_id, p_shift_date, v_actor, 1, v_ids, p_request_id)
  returning id into v_id;
  perform app._pm_audit(a, 'handover.declared', 'handover_declaration', v_id, null,
    jsonb_build_object('shift_id', p_shift_id, 'shift_date', p_shift_date, 'issues', cardinality(v_ids), 'text_version', 1), p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', v_id, 'issues', cardinality(v_ids));
end
$$;
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
  if a->>'role' = 'supervisor' and app._ho_enforced(v_tenant) then
    perform app._ho_snapshot(v_tenant, p_shift_id, p_shift_date, (a->>'actor')::uuid);
  end if;
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

-- Function privileges (same rule as 20261118500000 section 99): no app function is executable by clients.
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
