-- 06-shift-readings, review fixes (8b). Additive on top of 20261117400000_readings.sql (already applied to dev): one new column, one index, a backfill and
-- `create or replace` of the functions that change. Nothing in the first migration file is edited.
--   S1 the counter maximum in force is stored with each closing (and carried through corrections); the summary rolls over from the stored value.
--   S2 reading_detail.allowed follows the same retired checks as rd_closing / rd_correct.
--   N2 photos only while the caller could still correct the reading (begin and commit).
--   N4 the Today board shows only the summary's own target once a summary exists.
--   N5 a non-partial index for every current-reading lookup; the lookups carry tenant_id.

alter table public.production_reading add column counter_max bigint check (counter_max is null or counter_max between 9 and 1000000000000);
-- Existing closings take the maximum currently set on their machine (the only value known for them). The append-only trigger is lifted for this one backfill.
alter table public.production_reading disable trigger production_reading_no_update_delete;
update public.production_reading r set counter_max = m.counter_max from public.machine m where m.id = r.machine_id and r.kind = 'closing' and r.counter_max is null;
alter table public.production_reading enable trigger production_reading_no_update_delete;
create index production_reading_current_idx on public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind);


create or replace function app._rd_current(p_machine uuid, p_shift uuid, p_date date, p_kind text)
returns setof public.production_reading
language sql
stable
security definer
set search_path = ''
as $$
  select r.*
  from public.production_reading r
  where r.machine_id = p_machine and r.shift_id = p_shift and r.shift_date = p_date and r.kind = p_kind
    and r.tenant_id = (select m.tenant_id from public.machine m where m.id = p_machine)
    and (auth.role() = 'service_role' or r.tenant_id = app.current_tenant_id())
    and not exists (select 1 from public.production_reading n where n.supersedes_id = r.id)
$$;

create or replace function app._rd_compute_summary(p_tenant uuid, p_actor uuid, p_machine uuid, p_shift uuid, p_date date, p_request uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_version constant integer := 1;
  o public.production_reading;
  c public.production_reading;
  m public.machine;
  v_cav integer;
  v_target integer;
  v_units bigint;
  v_pieces bigint;
  v_unacc bigint;
  v_att numeric;
  v_rollover boolean := false;
  v_review boolean := false;
  v_id uuid;
begin
  select * into o from app._rd_current(p_machine, p_shift, p_date, 'opening');
  select * into c from app._rd_current(p_machine, p_shift, p_date, 'closing');
  if o.id is null or c.id is null then return null; end if;
  select * into m from public.machine x where x.id = p_machine;

  v_cav := case when m.counter_unit = 'shots' then app.cavities_for(p_machine, o.product_id, p_date) else 1 end;
  v_target := app.effective_target(p_machine, o.product_id, p_shift, p_date);

  if c.counter_value >= o.counter_value then
    v_units := c.counter_value - o.counter_value;
  elsif c.counter_max is not null and o.counter_value <= c.counter_max then
    v_units := (c.counter_max + 1 - o.counter_value) + c.counter_value;
    v_rollover := true;
  else
    v_review := true;
  end if;
  v_pieces := v_units * v_cav;
  v_unacc := v_pieces - c.good - c.reject;
  if v_target is not null then v_att := round(c.good * 100.0 / v_target, 2); end if;

  insert into public.production_summary (
    tenant_id, machine_id, shift_id, shift_date, calc_version, product_id, counter_unit, cavities, counter_max, opening_reading_id, closing_reading_id,
    opening_counter, closing_counter, good, reject, target, movement_units, movement_pieces, unaccounted, attainment_pct,
    rollover, needs_review, over_reported, late_opening, late_closing, early_closing, entered_by_ua, recorded_by, request_id)
  values (
    p_tenant, p_machine, p_shift, p_date, c_version, o.product_id, m.counter_unit, v_cav, c.counter_max, o.id, c.id,
    o.counter_value, c.counter_value, c.good, c.reject, v_target, v_units, v_pieces, v_unacc, v_att,
    v_rollover, v_review, coalesce(c.good + c.reject > v_pieces, false), o.late, c.late, c.early, (o.entered_by_ua or c.entered_by_ua), p_actor, p_request)
  returning id into v_id;
  return v_id;
end
$$;

create or replace function public.rd_closing(
  p_request_id uuid, p_machine_id uuid, p_shift_id uuid, p_shift_date date, p_counter bigint, p_good integer, p_reject integer, p_remarks text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:rd_closing';
  a jsonb;
  v_tenant uuid;
  v_deny jsonb;
  v_remarks text;
  m public.machine;
  v_w tstzrange;
  o public.production_reading;
  cur public.production_reading;
  s public.shift;
  v_late boolean;
  v_early boolean;
  v_ua boolean;
  v_id uuid;
  v_summary uuid;
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
  perform app._rd_counter_ok(p_counter, 'counter', 'Counter');
  perform app._rd_qty_ok(p_good, 'good', 'Good');
  perform app._rd_qty_ok(p_reject, 'reject', 'Reject');
  v_remarks := app._rd_remarks(p_remarks);

  select * into m from public.machine x where x.id = p_machine_id;
  select * into s from public.shift x where x.id = p_shift_id;
  if m.retired_at is not null then perform app._pm_fail('guard', 'This machine is retired', 'machine_retired'); end if;
  if s.retired_at is not null then perform app._pm_fail('guard', 'This shift is retired', 'shift_retired'); end if;
  select * into o from app._rd_current(p_machine_id, p_shift_id, p_shift_date, 'opening');
  if o.id is null then perform app._pm_fail('guard', 'Record the opening reading first', 'no_opening'); end if;
  -- D5: allowed from the opening until 12 hours after the occurrence ends.
  v_w := app.shift_window(p_shift_id, p_shift_date);
  if now() > upper(v_w) + interval '12 hours' then
    perform app._pm_fail('guard', 'The closing window (12 hours after the shift) has passed', 'window_closed');
  end if;
  select * into cur from app._rd_current(p_machine_id, p_shift_id, p_shift_date, 'closing');
  if cur.id is not null then
    perform app._pm_fail('guard', 'The closing reading is already recorded. Submit a correction instead.', 'already_recorded');
  end if;

  v_late := app._rd_is_late(upper(v_w), now());
  v_early := app._rd_is_early(upper(v_w), now());
  v_ua := a->>'role' = 'unit_admin';
  insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, counter_value, good, reject, remarks, late, early, entered_by_ua, counter_max, recorded_by, recorded_at, request_id)
  values (v_tenant, p_machine_id, p_shift_id, p_shift_date, 'closing', p_counter, p_good, p_reject, v_remarks, v_late, v_early, v_ua, m.counter_max, (a->>'actor')::uuid, now(), p_request_id)
  returning id into v_id;
  v_summary := app._rd_compute_summary(v_tenant, (a->>'actor')::uuid, p_machine_id, p_shift_id, p_shift_date, p_request_id);
  perform app._pm_audit(a, 'reading.closing', 'production_reading', v_id, null,
    jsonb_build_object('machine_code', m.code, 'shift_id', p_shift_id, 'shift_date', p_shift_date, 'counter', p_counter, 'good', p_good, 'reject', p_reject,
                       'late', v_late, 'early', v_early, 'entered_by_ua', v_ua, 'summary_id', v_summary),
    p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', v_id, 'late', v_late, 'early', v_early, 'entered_by_ua', v_ua, 'summary_id', v_summary);
end
$$;

create or replace function public.rd_correct(
  p_request_id uuid, p_reading_id uuid, p_counter bigint, p_product_id uuid, p_good integer, p_reject integer, p_remarks text, p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:rd_correct';
  a jsonb;
  v_tenant uuid;
  v_own text;
  v_remarks text;
  v_reason text := btrim(p_reason);
  old public.production_reading;
  cur public.production_reading;
  m public.machine;
  p public.product;
  s public.shift;
  v_ua boolean;
  v_id uuid;
  v_summary uuid;
begin
  if not exists (select 1 from public.membership x where x.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._rd_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;

  v_own := app._rd_owned(p_reading_id, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'production_reading', p_reading_id, c_src); end if;
  select * into old from public.production_reading r where r.id = p_reading_id;
  if a->>'role' = 'supervisor' and app.machine_owner(old.machine_id, old.shift_id, old.shift_date) is distinct from (a->>'actor')::uuid then
    return app._pm_deny(a, 'not_owner', 'production_reading', p_reading_id, c_src);
  end if;

  perform app._pm_len(v_reason, 1, 200, 'reason', 'Enter a reason of 1 to 200 characters');
  perform app._rd_counter_ok(p_counter, 'counter', 'Counter');
  v_remarks := app._rd_remarks(p_remarks);
  if old.kind = 'opening' then
    if p_good is not null or p_reject is not null then perform app._pm_fail('validation', 'An opening reading has no good or reject quantity', 'good'); end if;
    if p_product_id is null then perform app._pm_fail('validation', 'Choose the product', 'product_id'); end if;
    v_own := app._pm_owned('product', p_product_id, v_tenant);
    if v_own <> 'ok' then return app._pm_deny(a, v_own, 'product', p_product_id, c_src); end if;
    select * into p from public.product x where x.id = p_product_id;
    if p.retired_at is not null then perform app._pm_fail('guard', 'This product is retired', 'product_id'); end if;
  else
    if p_product_id is not null then perform app._pm_fail('validation', 'A closing reading has no product', 'product_id'); end if;
    perform app._rd_qty_ok(p_good, 'good', 'Good');
    perform app._rd_qty_ok(p_reject, 'reject', 'Reject');
  end if;

  select * into cur from app._rd_current(old.machine_id, old.shift_id, old.shift_date, old.kind);
  if cur.id is distinct from old.id then
    perform app._pm_fail('guard', 'This reading was already corrected; correct the latest one', 'not_current');
  end if;
  -- AC-6: the supervisor may correct until the next occurrence of the shift starts; a Unit Admin may at any time.
  if a->>'role' = 'supervisor' and now() >= lower(app.shift_window(old.shift_id, old.shift_date + 1)) then
    perform app._pm_fail('guard', 'The next shift has started; ask a Unit Admin to correct this reading', 'correction_window_closed');
  end if;

  select * into m from public.machine x where x.id = old.machine_id;
  select * into s from public.shift x where x.id = old.shift_id;
  if m.retired_at is not null then perform app._pm_fail('guard', 'This machine is retired', 'machine_retired'); end if;
  if s.retired_at is not null then perform app._pm_fail('guard', 'This shift is retired', 'shift_retired'); end if;
  v_ua := a->>'role' = 'unit_admin';
  insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, good, reject, remarks, late, early, entered_by_ua, counter_max,
                                         supersedes_id, correction_reason, recorded_by, recorded_at, request_id)
  values (v_tenant, old.machine_id, old.shift_id, old.shift_date, old.kind, p_product_id, p_counter, p_good, p_reject, v_remarks, old.late, old.early, v_ua, old.counter_max,
          old.id, v_reason, (a->>'actor')::uuid, now(), p_request_id)
  returning id into v_id;
  v_summary := app._rd_compute_summary(v_tenant, (a->>'actor')::uuid, old.machine_id, old.shift_id, old.shift_date, p_request_id);
  perform app._pm_audit(a, 'reading.corrected', 'production_reading', v_id,
    jsonb_build_object('reading_id', old.id, 'kind', old.kind, 'counter', old.counter_value, 'product_id', old.product_id, 'good', old.good, 'reject', old.reject),
    jsonb_build_object('machine_code', m.code, 'shift_id', old.shift_id, 'shift_date', old.shift_date, 'kind', old.kind, 'counter', p_counter, 'product_id', p_product_id,
                       'good', p_good, 'reject', p_reject, 'reason', v_reason, 'late', old.late, 'entered_by_ua', v_ua, 'summary_id', v_summary),
    p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', v_id, 'late', old.late, 'entered_by_ua', v_ua, 'summary_id', v_summary);
end
$$;

create or replace function app.reading_state_at(p_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:reading_state';
  a jsonb;
  v_tenant uuid;
  v_uid uuid;
  v_plant date;
  v_occ jsonb;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(null, c_src);
  end if;
  a := app._sh_read_authorise(c_src, false);
  if not (a->>'ok')::boolean then return a; end if;
  v_tenant := (a->>'tenant_id')::uuid;
  v_uid := (a->>'actor')::uuid;
  if not exists (select 1 from public.shift s where s.tenant_id = v_tenant and s.retired_at is null) then
    return jsonb_build_object('ok', true, 'state', 'no_shifts', 'occurrences', '[]'::jsonb);
  end if;

  v_plant := app.plant_date_at(v_tenant, p_at);
  with cand as (
    select s.id as shift_id, s.name, s.start_time, s.end_time, z.timezone as tz, d.d as shift_date, app._rd_window(s.start_time, s.end_time, d.d, z.timezone) as w
      from public.shift s
      join public.site z on z.id = s.site_id
      cross join lateral unnest(array[v_plant - 2, v_plant - 1, v_plant, v_plant + 1]) as d(d)
     where s.tenant_id = v_tenant and s.retired_at is null
  ), win as (
    select c.* from cand c where p_at >= lower(c.w) - interval '30 minutes' and p_at <= upper(c.w) + interval '12 hours'
  ), mine as (
    select w.*, (w.w @> p_at) as running, m.id as machine_id, m.code, m.name as machine_name, m.counter_unit, m.counter_max, l.name as line
      from win w
      join public.machine m on m.tenant_id = v_tenant and m.retired_at is null
      left join public.line l on l.id = m.line_id
      left join lateral (select true as found, c.supervisor_id from public.assignment_cover c
                          where c.shift_id = w.shift_id and c.shift_date = w.shift_date and c.machine_id = m.id
                          order by c.recorded_at desc, c.id desc limit 1) cv on true
      left join lateral (select v.supervisor_id from public.assignment_version v
                          where v.shift_id = w.shift_id and v.machine_id = m.id and v.effective_from <= w.shift_date
                          order by v.effective_from desc, v.recorded_at desc, v.id desc limit 1) pv on true
     where (case when cv.found then cv.supervisor_id else pv.supervisor_id end) = v_uid
  ), rd as (
    select mi.*, o.id as o_id, o.counter_value as o_counter, o.product_id as o_product, op.code as o_product_code, o.recorded_at as o_at, o.late as o_late,
           o.entered_by_ua as o_ua, o.remarks as o_remarks,
           c.id as c_id, c.counter_value as c_counter, c.good as c_good, c.reject as c_reject, c.recorded_at as c_at, c.late as c_late, c.early as c_early, c.entered_by_ua as c_ua, c.remarks as c_remarks,
           sm.id as s_id, sm.target as s_target, sm.movement_pieces as s_pieces, sm.good as s_good, sm.reject as s_reject, sm.unaccounted as s_unacc, sm.attainment_pct as s_att,
           sm.rollover as s_roll, sm.needs_review as s_review, sm.over_reported as s_over, sm.early_closing as s_early,
           dp.product_id as default_product,
           lower(app._rd_window(mi.start_time, mi.end_time, mi.shift_date + 1, mi.tz)) as next_start
      from mine mi
      left join lateral (select r.* from public.production_reading r
                          where r.tenant_id = v_tenant and r.machine_id = mi.machine_id and r.shift_id = mi.shift_id and r.shift_date = mi.shift_date and r.kind = 'opening'
                            and not exists (select 1 from public.production_reading n where n.supersedes_id = r.id) limit 1) o on true
      left join public.product op on op.id = o.product_id
      left join lateral (select r.* from public.production_reading r
                          where r.tenant_id = v_tenant and r.machine_id = mi.machine_id and r.shift_id = mi.shift_id and r.shift_date = mi.shift_date and r.kind = 'closing'
                            and not exists (select 1 from public.production_reading n where n.supersedes_id = r.id) limit 1) c on true
      left join lateral (select x.* from public.production_summary x
                          where x.tenant_id = v_tenant and x.machine_id = mi.machine_id and x.shift_id = mi.shift_id and x.shift_date = mi.shift_date
                          order by x.recorded_at desc, x.id desc limit 1) sm on true
      left join lateral (select r.product_id from public.production_reading r join public.product p on p.id = r.product_id and p.retired_at is null
                          join public.shift hs on hs.id = r.shift_id
                          where r.tenant_id = v_tenant and r.machine_id = mi.machine_id and r.kind = 'opening' and not exists (select 1 from public.production_reading n where n.supersedes_id = r.id)
                          order by r.shift_date desc, hs.start_time desc, r.recorded_at desc, r.id desc limit 1) dp on true
  ), mach as (
    select x.shift_id, x.name, x.start_time, x.end_time, x.shift_date, x.w, x.running,
           jsonb_build_object(
             'machine_id', x.machine_id, 'code', x.code, 'name', x.machine_name, 'line', x.line, 'counter_unit', x.counter_unit, 'counter_max', x.counter_max,
             'state', case when x.c_id is not null then 'closed'
                           when x.o_id is not null then case when p_at >= upper(x.w) then 'closing_due' else 'opening_done' end
                           when p_at >= upper(x.w) then 'opening_missed'
                           else 'opening_due' end,
             'can_open', (x.o_id is null and p_at >= lower(x.w) - interval '30 minutes' and p_at <= upper(x.w) + interval '12 hours'),
             'can_close', (x.o_id is not null and x.c_id is null and p_at <= upper(x.w) + interval '12 hours'),
             'can_correct', ((x.o_id is not null or x.c_id is not null) and p_at < x.next_start),
             'default_product_id', x.default_product,
             'opening', case when x.o_id is null then null else jsonb_build_object('id', x.o_id, 'counter', x.o_counter, 'product_id', x.o_product, 'product_code', x.o_product_code,
                          'recorded_at', x.o_at, 'late', x.o_late, 'entered_by_ua', x.o_ua, 'remarks', x.o_remarks) end,
             'closing', case when x.c_id is null then null else jsonb_build_object('id', x.c_id, 'counter', x.c_counter, 'good', x.c_good, 'reject', x.c_reject,
                          'recorded_at', x.c_at, 'late', x.c_late, 'early', x.c_early, 'entered_by_ua', x.c_ua, 'remarks', x.c_remarks) end,
             'summary', case when x.s_id is null then null else jsonb_build_object('id', x.s_id, 'target', x.s_target, 'movement_pieces', x.s_pieces, 'good', x.s_good,
                          'reject', x.s_reject, 'unaccounted', x.s_unacc, 'attainment_pct', x.s_att, 'rollover', x.s_roll, 'needs_review', x.s_review, 'over_reported', x.s_over, 'early_closing', x.s_early) end
           ) as j, x.code
      from rd x
  ), occ as (
    select m.shift_id, m.name, m.start_time, m.end_time, m.shift_date, m.w, m.running, jsonb_agg(m.j order by m.code) as machines
      from mach m group by m.shift_id, m.name, m.start_time, m.end_time, m.shift_date, m.w, m.running
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'shift', jsonb_build_object('id', o.shift_id, 'name', o.name, 'start_time', to_char(o.start_time, 'HH24:MI'), 'end_time', to_char(o.end_time, 'HH24:MI')),
           'shift_date', o.shift_date, 'starts_at', lower(o.w), 'ends_at', upper(o.w), 'running', o.running, 'machines', o.machines)
           order by lower(o.w), o.name), '[]'::jsonb)
    into v_occ
    from occ o;
  return jsonb_build_object('ok', true, 'state', case when jsonb_array_length(v_occ) = 0 then 'none' else 'active' end, 'occurrences', v_occ);
end
$$;

create or replace function app.reading_detail_at(p_machine uuid, p_shift uuid, p_date date, p_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:reading_detail';
  a jsonb;
  v_tenant uuid;
  v_own text;
  v_owner uuid;
  v_w tstzrange;
  m public.machine;
  s public.shift;
  o public.production_reading;
  c public.production_reading;
  sm public.production_summary;
  v_hist jsonb;
  v_n int;
  v_next timestamptz;
begin
  if not exists (select 1 from public.membership x where x.user_id = auth.uid()) then
    return app._pm_authorise(null, c_src);
  end if;
  a := app._sh_read_authorise(c_src, false);
  if not (a->>'ok')::boolean then return a; end if;
  v_tenant := (a->>'tenant_id')::uuid;
  v_own := app._pm_owned('machine', p_machine, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'machine', p_machine, c_src); end if;
  v_own := app._sh_owned('shift', p_shift, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'shift', p_shift, c_src); end if;
  if p_date is null then perform app._pm_fail('validation', 'Choose the shift date', 'shift_date'); end if;
  v_owner := app.machine_owner(p_machine, p_shift, p_date);
  if a->>'role' = 'supervisor' and v_owner is distinct from (a->>'actor')::uuid then
    return app._pm_deny(a, 'not_owner', 'machine', p_machine, c_src);
  end if;

  select * into m from public.machine x where x.id = p_machine;
  select * into s from public.shift x where x.id = p_shift;
  v_w := app.shift_window(p_shift, p_date);
  select * into o from app._rd_current(p_machine, p_shift, p_date, 'opening');
  select * into c from app._rd_current(p_machine, p_shift, p_date, 'closing');
  select * into sm from public.production_summary x
    where x.tenant_id = v_tenant and x.machine_id = p_machine and x.shift_id = p_shift and x.shift_date = p_date order by x.recorded_at desc, x.id desc limit 1;
  select count(*)::int into v_n from public.production_summary x where x.tenant_id = v_tenant and x.machine_id = p_machine and x.shift_id = p_shift and x.shift_date = p_date;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'kind', r.kind, 'counter', r.counter_value, 'product_id', r.product_id, 'product_code', p.code, 'good', r.good, 'reject', r.reject,
           'remarks', r.remarks, 'late', r.late, 'early', r.early, 'entered_by_ua', r.entered_by_ua, 'supersedes_id', r.supersedes_id, 'correction_reason', r.correction_reason,
           'recorded_by', r.recorded_by, 'recorded_by_name', mem.full_name, 'recorded_at', r.recorded_at,
           'current', not exists (select 1 from public.production_reading n where n.supersedes_id = r.id)) order by r.kind desc, r.recorded_at, r.id), '[]'::jsonb)
    into v_hist
    from public.production_reading r
    left join public.product p on p.id = r.product_id
    left join public.membership mem on mem.user_id = r.recorded_by and mem.tenant_id = v_tenant
    where r.tenant_id = v_tenant and r.machine_id = p_machine and r.shift_id = p_shift and r.shift_date = p_date;
  v_next := lower(app.shift_window(p_shift, p_date + 1));

  return jsonb_build_object(
    'ok', true,
    'machine', jsonb_build_object('id', m.id, 'code', m.code, 'name', m.name, 'counter_unit', m.counter_unit, 'counter_max', m.counter_max),
    'shift', jsonb_build_object('id', s.id, 'name', s.name, 'start_time', to_char(s.start_time, 'HH24:MI'), 'end_time', to_char(s.end_time, 'HH24:MI')),
    'shift_date', p_date, 'starts_at', lower(v_w), 'ends_at', upper(v_w),
    'default_product_id', (select r.product_id from public.production_reading r join public.product dp on dp.id = r.product_id and dp.retired_at is null
                             join public.shift hs on hs.id = r.shift_id
                            where r.tenant_id = v_tenant and r.machine_id = p_machine and r.kind = 'opening' and not exists (select 1 from public.production_reading n where n.supersedes_id = r.id)
                            order by r.shift_date desc, hs.start_time desc, r.recorded_at desc, r.id desc limit 1),
    'owner_id', v_owner, 'owner_name', (select mem.full_name from public.membership mem where mem.user_id = v_owner and mem.tenant_id = v_tenant),
    'readings', v_hist,
    'opening', case when o.id is null then null else v_hist -> (select (i - 1)::int from jsonb_array_elements(v_hist) with ordinality as e(x, i) where (e.x ->> 'id')::uuid = o.id) end,
    'closing', case when c.id is null then null else v_hist -> (select (i - 1)::int from jsonb_array_elements(v_hist) with ordinality as e(x, i) where (e.x ->> 'id')::uuid = c.id) end,
    'summary', case when sm.id is null then null else to_jsonb(sm) - 'tenant_id' - 'request_id' end,
    'summary_count', v_n,
    'photos', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'reading_id', t.entity_id, 'path', t.storage_path, 'mime', t.mime, 'ready_at', t.ready_at) order by t.ready_at, t.id), '[]'::jsonb)
                 from public.attachment t
                 where t.entity_type = 'production_reading' and t.status = 'ready' and t.tenant_id = v_tenant
                   and t.entity_id in (select (e.x ->> 'id')::uuid from jsonb_array_elements(v_hist) e(x))),
    'allowed', jsonb_build_object(
      'can_open', (o.id is null and p_at >= lower(v_w) - interval '30 minutes' and p_at <= upper(v_w) + interval '12 hours' and m.retired_at is null and s.retired_at is null),
      'can_close', (o.id is not null and c.id is null and p_at <= upper(v_w) + interval '12 hours' and m.retired_at is null and s.retired_at is null),
      'can_correct', ((o.id is not null or c.id is not null) and (a->>'role' = 'unit_admin' or p_at < v_next) and m.retired_at is null and s.retired_at is null)));
end
$$;

create or replace function app.today_board_at(p_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:today_board';
  a jsonb;
  v_tenant uuid;
  v_plant date;
  v_occ jsonb;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(null, c_src);
  end if;
  a := app._sh_read_authorise(c_src, true);
  if not (a->>'ok')::boolean then return a; end if;
  v_tenant := (a->>'tenant_id')::uuid;
  v_plant := app.plant_date_at(v_tenant, p_at);

  with cand as (
    select s.id as shift_id, s.name, s.start_time, s.end_time, z.timezone as tz, d.d as shift_date, app._rd_window(s.start_time, s.end_time, d.d, z.timezone) as w
      from public.shift s
      join public.site z on z.id = s.site_id
      cross join lateral unnest(array[v_plant - 2, v_plant - 1, v_plant, v_plant + 1]) as d(d)
     where s.tenant_id = v_tenant and s.retired_at is null
  ), started as (
    select c.*, row_number() over (partition by c.shift_id order by lower(c.w) desc) as rn from cand c where lower(c.w) <= p_at
  ), occ as (
    select * from started where rn <= 2
  ), assigned as (
    select o.*, m.id as machine_id, m.code, m.name as machine_name, m.counter_unit,
           (case when cv.found then cv.supervisor_id else pv.supervisor_id end) as owner_id
      from occ o
      join public.machine m on m.tenant_id = v_tenant
      left join lateral (select true as found, c.supervisor_id from public.assignment_cover c
                          where c.shift_id = o.shift_id and c.shift_date = o.shift_date and c.machine_id = m.id
                          order by c.recorded_at desc, c.id desc limit 1) cv on true
      left join lateral (select v.supervisor_id from public.assignment_version v
                          where v.shift_id = o.shift_id and v.machine_id = m.id and v.effective_from <= o.shift_date
                          order by v.effective_from desc, v.recorded_at desc, v.id desc limit 1) pv on true
     where (case when cv.found then cv.supervisor_id else pv.supervisor_id end) is not null
       and (m.retired_at is null or exists (select 1 from public.production_reading r where r.machine_id = m.id and r.shift_id = o.shift_id and r.shift_date = o.shift_date))
  ), rd as (
    select x.*, mem.full_name as owner_name,
           o.id as o_id, o.product_id as o_product, op.code as o_product_code, o.late as o_late, o.entered_by_ua as o_ua, o.counter_value as o_counter,
           c.id as c_id, c.late as c_late, c.early as c_early, c.entered_by_ua as c_ua, c.counter_value as c_counter,
           sm.id as s_id, sm.target as s_target, sm.movement_pieces as s_pieces, sm.good as s_good, sm.reject as s_reject, sm.unaccounted as s_unacc,
           sm.attainment_pct as s_att, sm.rollover as s_roll, sm.needs_review as s_review, sm.over_reported as s_over,
           dp.product_id as default_product
      from assigned x
      left join public.membership mem on mem.user_id = x.owner_id and mem.tenant_id = v_tenant
      left join lateral (select r.* from public.production_reading r
                          where r.tenant_id = v_tenant and r.machine_id = x.machine_id and r.shift_id = x.shift_id and r.shift_date = x.shift_date and r.kind = 'opening'
                            and not exists (select 1 from public.production_reading n where n.supersedes_id = r.id) limit 1) o on true
      left join public.product op on op.id = o.product_id
      left join lateral (select r.* from public.production_reading r
                          where r.tenant_id = v_tenant and r.machine_id = x.machine_id and r.shift_id = x.shift_id and r.shift_date = x.shift_date and r.kind = 'closing'
                            and not exists (select 1 from public.production_reading n where n.supersedes_id = r.id) limit 1) c on true
      left join lateral (select y.* from public.production_summary y
                          where y.tenant_id = v_tenant and y.machine_id = x.machine_id and y.shift_id = x.shift_id and y.shift_date = x.shift_date
                          order by y.recorded_at desc, y.id desc limit 1) sm on true
      left join lateral (select r.product_id from public.production_reading r join public.product p on p.id = r.product_id and p.retired_at is null
                          join public.shift hs on hs.id = r.shift_id
                          where o.id is null and r.tenant_id = v_tenant and r.machine_id = x.machine_id and r.kind = 'opening' and not exists (select 1 from public.production_reading n where n.supersedes_id = r.id)
                          order by r.shift_date desc, hs.start_time desc, r.recorded_at desc, r.id desc limit 1) dp on true
  ), calc as (
    select r.*,
           case when r.s_id is not null then r.s_target -- N4: a summary carries its own target; never today's effective one
                else case when coalesce(r.o_product, r.default_product) is not null
                          then app.effective_target(r.machine_id, coalesce(r.o_product, r.default_product), r.shift_id, r.shift_date) end end as target,
           (r.s_target is null and r.o_id is null and r.default_product is not null) as target_assumed,
           case when r.o_id is null then 'missing' when r.o_late then 'late' else 'on_time' end as o_status,
           case when r.c_id is null then 'missing' when r.c_late then 'late' when r.c_early then 'early' else 'on_time' end as c_status
      from rd r
  ), shaped as (
    select k.shift_id, k.name, k.start_time, k.end_time, k.shift_date, k.w, k.rn, k.code, k.target, k.target_assumed, k.o_status, k.c_status, k.c_id, k.s_good,
           jsonb_build_object(
             'machine_id', k.machine_id, 'code', k.code, 'name', k.machine_name, 'counter_unit', k.counter_unit, 'owner_id', k.owner_id, 'owner_name', k.owner_name,
             'product_id', k.o_product, 'product_code', k.o_product_code, 'target', k.target, 'target_assumed', k.target_assumed,
             'opening_status', k.o_status, 'closing_status', k.c_status, 'opening_counter', k.o_counter, 'closing_counter', k.c_counter,
             'movement_pieces', k.s_pieces, 'good', k.s_good, 'reject', k.s_reject, 'unaccounted', k.s_unacc, 'attainment_pct', k.s_att,
             'flags', to_jsonb(array_remove(array[
                case when k.o_late then 'late_opening' end, case when k.c_late then 'late_closing' end, case when k.c_early then 'early_closing' end, case when k.s_roll then 'rollover' end,
                case when k.s_review then 'needs_review' end, case when k.s_over then 'over_reported' end,
                case when coalesce(k.o_ua, false) or coalesce(k.c_ua, false) then 'entered_by_ua' end], null))) as j
      from calc k
  ), agg as (
    select h.shift_id, h.name, h.start_time, h.end_time, h.shift_date, h.w, h.rn,
           jsonb_agg(h.j order by h.code) as machines,
           count(*) as expected,
           count(*) filter (where h.o_status = 'on_time') as openings_on_time,
           count(*) filter (where h.c_status = 'on_time') as closings_on_time,
           count(*) filter (where h.o_status = 'on_time' and h.c_status = 'on_time') as both_on_time,
           coalesce(sum(h.target) filter (where h.target is not null), 0) as t_all,
           coalesce(sum(h.target) filter (where h.target is not null and h.target_assumed), 0) as t_assumed,
           coalesce(sum(h.target) filter (where h.target is not null and h.c_id is not null), 0) as t_closed,
           coalesce(sum(h.s_good) filter (where h.c_id is not null), 0) as g_closed,
           coalesce(sum(h.s_good) filter (where h.c_id is not null and h.target is not null), 0) as g_closed_t
      from shaped h group by h.shift_id, h.name, h.start_time, h.end_time, h.shift_date, h.w, h.rn
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'shift', jsonb_build_object('id', g.shift_id, 'name', g.name, 'start_time', to_char(g.start_time, 'HH24:MI'), 'end_time', to_char(g.end_time, 'HH24:MI')),
           'shift_date', g.shift_date, 'starts_at', lower(g.w), 'ends_at', upper(g.w), 'running', (g.w @> p_at), 'current', (g.rn = 1), 'machines', g.machines, 'assumed_target', g.t_assumed,
           'totals', jsonb_build_object('machines_expected', g.expected, 'openings_on_time', g.openings_on_time, 'closings_on_time', g.closings_on_time,
                                        'both_on_time', g.both_on_time, 'target', g.t_all, 'target_closed', g.t_closed, 'good', g.g_closed,
                                        'attainment_pct', case when g.t_closed > 0 then round(g.g_closed_t * 100.0 / g.t_closed, 2) end))
           order by g.name, lower(g.w) desc), '[]'::jsonb)
    into v_occ
    from agg g;
  return jsonb_build_object('ok', true, 'as_of', p_at, 'occurrences', v_occ);
end
$$;

create or replace function app.reading_capture_at(p_tenant uuid, p_from date, p_to date, p_at timestamptz)
returns table (expected bigint, on_time bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_tenant is null or p_from is null or p_to is null or p_to < p_from then
    perform app._pm_fail('validation', 'Choose a valid date range', 'range');
  end if;
  if p_to - p_from > 366 then
    perform app._pm_fail('validation', 'Choose at most 367 days', 'range');
  end if;
  return query
  with occ as (
    select s.id as shift_id, d.d as shift_date, app._rd_window(s.start_time, s.end_time, d.d, z.timezone) as w, s.retired_at as s_retired
      from public.shift s
      join public.site z on z.id = s.site_id
      cross join lateral (select (p_from + g.n) as d from generate_series(0, p_to - p_from) as g(n)) d
     where s.tenant_id = p_tenant
  ), ended as (
    select o.* from occ o where upper(o.w) + interval '30 minutes' <= p_at and (o.s_retired is null or o.s_retired >= upper(o.w))
  ), owned as (
    select e.shift_id, e.shift_date, m.id as machine_id
      from ended e
      join public.machine m on m.tenant_id = p_tenant and (m.retired_at is null or m.retired_at >= upper(e.w))
      left join lateral (select true as found, c.supervisor_id from public.assignment_cover c
                          where c.shift_id = e.shift_id and c.shift_date = e.shift_date and c.machine_id = m.id
                          order by c.recorded_at desc, c.id desc limit 1) cv on true
      left join lateral (select v.supervisor_id from public.assignment_version v
                          where v.shift_id = e.shift_id and v.machine_id = m.id and v.effective_from <= e.shift_date
                          order by v.effective_from desc, v.recorded_at desc, v.id desc limit 1) pv on true
     where (case when cv.found then cv.supervisor_id else pv.supervisor_id end) is not null
  )
  select count(*)::bigint,
         count(*) filter (where o.id is not null and not o.late and c.id is not null and not c.late and not c.early)::bigint
    from owned w
    left join lateral (select r.id, r.late from public.production_reading r
                        where r.tenant_id = p_tenant and r.machine_id = w.machine_id and r.shift_id = w.shift_id and r.shift_date = w.shift_date and r.kind = 'opening'
                          and not exists (select 1 from public.production_reading n where n.supersedes_id = r.id) limit 1) o on true
    left join lateral (select r.id, r.late, r.early from public.production_reading r
                        where r.tenant_id = p_tenant and r.machine_id = w.machine_id and r.shift_id = w.shift_id and r.shift_date = w.shift_date and r.kind = 'closing'
                          and not exists (select 1 from public.production_reading n where n.supersedes_id = r.id) limit 1) c on true;
end
$$;

create or replace function public.rd_attachment_begin(p_request_id uuid, p_reading_id uuid, p_mime text, p_size bigint, p_sha256 text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:rd_attachment_begin';
  a jsonb;
  v_actor uuid;
  v_tenant uuid;
  v_own text;
  v_sha text := lower(btrim(p_sha256));
  v_ext text;
  v_id uuid := gen_random_uuid();
  v_path text;
  ex public.attachment;
  r public.production_reading;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._rd_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  v_actor := (a->>'actor')::uuid;
  v_tenant := (a->>'tenant_id')::uuid;
  -- begin writes no audit row, so an audit row with this request id belongs to another RPC (reuse across RPCs -> validation)
  if exists (select 1 from public.audit_event e where e.actor_user_id = v_actor and e.request_id = p_request_id) then
    perform app._pm_fail('validation', 'This request id was already used for another action', 'request_id');
  end if;

  v_own := app._rd_owned(p_reading_id, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'production_reading', p_reading_id, c_src); end if;
  select * into r from public.production_reading x where x.id = p_reading_id;
  if a->>'role' = 'supervisor' and app.machine_owner(r.machine_id, r.shift_id, r.shift_date) is distinct from v_actor then
    return app._pm_deny(a, 'not_owner', 'production_reading', p_reading_id, c_src);
  end if;

  if exists (select 1 from public.production_reading n where n.supersedes_id = p_reading_id) then
    perform app._pm_fail('guard', 'This reading was corrected; attach the photo to the latest reading', 'not_current');
  end if;

  if a->>'role' = 'supervisor' and now() >= lower(app.shift_window(r.shift_id, r.shift_date + 1)) then
    perform app._pm_fail('guard', 'The correction window for this reading has closed; photos can no longer be added', 'correction_window_closed');
  end if;

  v_ext := case lower(btrim(p_mime)) when 'image/jpeg' then 'jpg' when 'image/png' then 'png' when 'image/webp' then 'webp' end;
  if v_ext is null then perform app._pm_fail('validation', 'Photos must be JPEG, PNG or WebP', 'mime'); end if;
  if p_size is null or p_size < 1 or p_size > 5242880 then perform app._pm_fail('validation', 'A photo must be 5 MB or smaller', 'size'); end if;
  if v_sha is null or v_sha !~ '^[0-9a-f]{64}$' then perform app._pm_fail('validation', 'The checksum must be a SHA-256 hex digest', 'sha256'); end if;

  -- a retried begin (same request id) returns the same row
  select * into ex from public.attachment x where x.uploaded_by = v_actor and x.begin_request_id = p_request_id;
  if found then
    if ex.parent_id is distinct from p_reading_id or ex.entity_type <> 'production_reading' then
      perform app._pm_fail('validation', 'This request id was already used for another action', 'request_id');
    end if;
    return jsonb_build_object('ok', true, 'id', ex.id, 'path', ex.storage_path, 'status', ex.status, 'already', true);
  end if;

  if (select count(*) from public.attachment x where x.uploaded_by = v_actor and x.parent_id = p_reading_id and x.status = 'pending'
        and x.created_at > now() - interval '10 minutes') >= 3 then
    perform app._pm_fail('guard', 'Finish or wait for the photos already being uploaded (up to 3 at a time)', 'too_many_pending');
  end if;
  if (select count(*) from public.attachment x where x.parent_id = p_reading_id and x.entity_type = 'production_reading' and x.status = 'ready') >= 3 then
    perform app._pm_fail('guard', 'This reading already has 3 photos', 'photo_limit');
  end if;

  v_path := 'tenant/' || v_tenant::text || '/reading/' || p_reading_id::text || '/' || v_id::text || '.' || v_ext;
  insert into public.attachment (id, tenant_id, entity_type, entity_id, storage_path, mime, size_bytes, sha256, uploaded_by, parent_id, begin_request_id)
  values (v_id, v_tenant, 'production_reading', p_reading_id, v_path, lower(btrim(p_mime)), p_size::integer, v_sha, v_actor, p_reading_id, p_request_id);
  return jsonb_build_object('ok', true, 'id', v_id, 'path', v_path, 'status', 'pending');
end
$$;

create or replace function public.rd_attachment_commit(p_request_id uuid, p_attachment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:rd_attachment_commit';
  a jsonb;
  v_actor uuid;
  att public.attachment;
  obj record;
  r public.production_reading;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._rd_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_actor := (a->>'actor')::uuid;

  select * into att from public.attachment x where x.id = p_attachment_id;
  if not found then return app._pm_deny(a, 'not_found', 'attachment', p_attachment_id, c_src); end if;
  if att.tenant_id <> (a->>'tenant_id')::uuid then return app._pm_deny(a, 'cross_tenant', 'attachment', p_attachment_id, c_src); end if;
  if att.uploaded_by <> v_actor then return app._pm_deny(a, 'not_uploader', 'attachment', p_attachment_id, c_src); end if;
  if att.entity_type <> 'production_reading' then perform app._pm_fail('guard', 'This attachment is not a reading photo', 'entity_type'); end if;
  if att.status <> 'pending' then perform app._pm_fail('guard', 'This photo is already attached', 'already_ready'); end if;
  if att.created_at < now() - interval '1 hour' then perform app._pm_fail('guard', 'This upload expired. Start again', 'expired'); end if;
  if not app._rd_can_see_reading(att.parent_id, v_actor) then return app._pm_deny(a, 'not_visible', 'attachment', p_attachment_id, c_src); end if;

  select o.metadata into obj from storage.objects o where o.bucket_id = 'attachments' and o.name = att.storage_path;
  if not found then perform app._pm_fail('guard', 'The photo has not been uploaded', 'not_uploaded'); end if;
  if (obj.metadata->>'size')::bigint is distinct from att.size_bytes or obj.metadata->>'mimetype' is distinct from att.mime then
    perform app._pm_fail('guard', 'The uploaded photo does not match what was declared', 'mismatch');
  end if;

  select * into r from public.production_reading x where x.id = att.parent_id;
  if exists (select 1 from public.production_reading n where n.supersedes_id = r.id) then
    perform app._pm_fail('guard', 'This reading was corrected; attach the photo to the latest reading', 'not_current');
  end if;
  if a->>'role' = 'supervisor' and now() >= lower(app.shift_window(r.shift_id, r.shift_date + 1)) then
    perform app._pm_fail('guard', 'The correction window for this reading has closed; photos can no longer be added', 'correction_window_closed');
  end if;
  if (select count(*) from public.attachment x where x.parent_id = r.id and x.entity_type = 'production_reading' and x.status = 'ready') >= 3 then
    perform app._pm_fail('guard', 'This reading already has 3 photos', 'photo_limit');
  end if;
  update public.attachment x set status = 'ready', ready_at = now() where x.id = att.id;
  perform app._pm_audit(a, 'attachment.added', 'attachment', att.id, null,
    jsonb_build_object('reading_id', r.id, 'kind', r.kind, 'mime', att.mime, 'size_bytes', att.size_bytes, 'sha256', att.sha256), p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', att.id);
end
$$;


-- 99. Function privileges: no app function is executable by clients (test 004); the public entry points are executable by authenticated only.
-- Repeated at the end of every step's section: each step adds functions, the loop runs over the whole 06 name range.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig, n.nspname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname = 'app' and p.proname ~ '^(_rd_|rd_|reading_|today_board|cavities_for$|_cavities_raw$)')
       or (n.nspname = 'public' and p.proname ~ '^(rd_|reading_|today_board$)')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.nspname = 'public' then
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;
