-- Demo tenant consistency checks (dev-reset step 3a). Run by CI (reset-roundtrip) against the LOCAL stack after the demo seed:
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f scripts/demo-checks.sql
-- 1. every seeded production summary equals what the server's own app._rd_compute_summary calculates from the same readings;
-- 2. the awaiting-verification issue can be verified by the other supervisor and not by its resolver (app.issue_can_verify);
-- 3. the demo Unit Admin sees the demo data through RLS, while another tenant's Unit Admin and a Super Admin see none of it.
-- Everything runs in one transaction that is rolled back. A failed assertion divides by zero (ON_ERROR_STOP => non-zero exit).
\set ON_ERROR_STOP on
begin;

select id as tid from public.tenant where name = 'Demo Plastics (fixture)' \gset
select (:'tid' <> '') as has_demo \gset
select 1 / (case when :'has_demo' = 't' then 1 else 0 end) as demo_tenant_exists;

-- 1. summaries equal the server calculation ------------------------------------------------------------------------------------------
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
do $$
declare
  t uuid := (select id from public.tenant where name = 'Demo Plastics (fixture)');
  s public.production_summary;
  r public.production_summary;
  v uuid;
  n integer := 0;
  rollovers integer := 0;
begin
  for s in select * from public.production_summary where tenant_id = t loop
    v := app._rd_compute_summary(t, s.recorded_by, s.machine_id, s.shift_id, s.shift_date, null);
    if v is null then raise exception 'summary % : the server found no current readings', s.id; end if;
    select * into r from public.production_summary where id = v;
    if (r.product_id, r.counter_unit, r.cavities, r.counter_max, r.opening_reading_id, r.closing_reading_id, r.opening_counter, r.closing_counter, r.good, r.reject,
        r.target, r.movement_units, r.movement_pieces, r.unaccounted, r.attainment_pct, r.rollover, r.needs_review, r.over_reported, r.late_opening, r.late_closing,
        r.early_closing, r.entered_by_ua, r.calc_version)
       is distinct from
       (s.product_id, s.counter_unit, s.cavities, s.counter_max, s.opening_reading_id, s.closing_reading_id, s.opening_counter, s.closing_counter, s.good, s.reject,
        s.target, s.movement_units, s.movement_pieces, s.unaccounted, s.attainment_pct, s.rollover, s.needs_review, s.over_reported, s.late_opening, s.late_closing,
        s.early_closing, s.entered_by_ua, s.calc_version)
    then
      raise exception 'seeded summary % differs from app._rd_compute_summary: seeded %, server %', s.id, to_jsonb(s), to_jsonb(r);
    end if;
    n := n + 1;
    if s.rollover then rollovers := rollovers + 1; end if;
  end loop;
  if n = 0 then raise exception 'the demo tenant has no summaries'; end if;
  if rollovers = 0 then raise exception 'the demo history has no rollover'; end if;
  raise notice 'demo: % seeded summaries equal app._rd_compute_summary (% rollovers)', n, rollovers;
end $$;
-- the check above appended one row per summary: they are rolled back at the end, but the counts below must not see them
rollback;
begin;

-- 2. verification eligibility -----------------------------------------------------------------------------------------------------
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select i.id as vid from public.machine_issue i where i.tenant_id = :'tid' and i.status = 'resolved' and i.priority in ('high', 'critical') \gset
select m.user_id as s2 from public.membership m where m.tenant_id = :'tid' and m.employee_id = 'DM-S2' \gset
select m.user_id as s1 from public.membership m where m.tenant_id = :'tid' and m.employee_id = 'DM-S1' \gset
select m.user_id as uaid from public.membership m where m.tenant_id = :'tid' and m.employee_id = 'DM-UA' \gset
select app.issue_can_verify(:'vid'::uuid, :'s2'::uuid, now()) as ok \gset
select 1 / (case when :'ok' = 't' then 1 else 0 end) as other_supervisor_can_verify;
select app.issue_can_verify(:'vid'::uuid, :'s1'::uuid, now()) as ok \gset
select 1 / (case when :'ok' = 'f' then 1 else 0 end) as resolver_cannot_verify;

-- 3. visibility through RLS ---------------------------------------------------------------------------------------------------------
select count(*) as n_summary from public.production_summary where tenant_id = :'tid' \gset
select count(*) as n_reading from public.production_reading where tenant_id = :'tid' \gset
select count(*) as n_machine from public.machine where tenant_id = :'tid' \gset
select count(*) as n_issue from public.machine_issue where tenant_id = :'tid' \gset
select m.user_id as other_ua from public.membership m where m.phone_e164 = '+919000000006' \gset
select p.user_id as sa from public.platform_admin p where p.phone_e164 = '+919000000098' \gset

select set_config('request.jwt.claims', json_build_object('sub', :'uaid'::text, 'role', 'authenticated')::text, true);
set local role authenticated;
select (select count(*) from public.production_summary) = :n_summary
   and (select count(*) from public.production_reading) = :n_reading
   and (select count(*) from public.machine) = :n_machine
   and (select count(*) from public.machine_issue) = :n_issue
   and :n_summary > 0 and :n_issue > 0 as ok \gset
reset role;
select 1 / (case when :'ok' = 't' then 1 else 0 end) as demo_unit_admin_sees_demo_data;

select set_config('request.jwt.claims', json_build_object('sub', :'other_ua'::text, 'role', 'authenticated')::text, true);
set local role authenticated;
select (select count(*) from public.production_summary where tenant_id = :'tid') = 0
   and (select count(*) from public.production_reading where tenant_id = :'tid') = 0
   and (select count(*) from public.machine where tenant_id = :'tid') = 0
   and (select count(*) from public.machine_issue where tenant_id = :'tid') = 0
   and (select count(*) from public.membership where tenant_id = :'tid') = 0 as ok \gset
reset role;
select 1 / (case when :'ok' = 't' then 1 else 0 end) as other_tenant_sees_no_demo_data;

select set_config('request.jwt.claims', json_build_object('sub', :'sa'::text, 'role', 'authenticated')::text, true);
set local role authenticated;
select (select count(*) from public.production_summary) = 0
   and (select count(*) from public.production_reading) = 0
   and (select count(*) from public.machine) = 0
   and (select count(*) from public.machine_issue) = 0
   and (select count(*) from public.membership) = 0 as ok \gset
reset role;
select 1 / (case when :'ok' = 't' then 1 else 0 end) as super_admin_sees_no_demo_data;

rollback;
\echo demo checks passed
