-- 06 AC-1, AC-2, AC-15 (DB part), D3, D4: the 06 tables (RLS, composite FKs, append-only incl. the service role, shape checks, linear correction
-- chain), the counter settings on machine (unit lock, maximum), cavities (set / end / cavities_for) and the registry.
-- Self-contained; rolled back. Plant dates are offsets from today's plant date so the test is date-independent.
begin;
create extension if not exists pgtap with schema extensions;
select plan(127);

create temp table ids (k text primary key, v uuid);
create function pg_temp.id(k text) returns uuid language sql as $$ select v from ids where k = $1 $$;
create function pg_temp.as_user(k text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where ids.k = $1), 'role', 'authenticated')::text, true) $$;
create function pg_temp.err(q text) returns jsonb language plpgsql as $f$
declare d text; m text; st text;
begin
  execute q;
  return jsonb_build_object('raised', false);
exception when others then
  get stacked diagnostics d = pg_exception_detail, m = message_text, st = returned_sqlstate;
  return coalesce(case when d ~ '^[{]' then d::jsonb end, '{}'::jsonb) || jsonb_build_object('message', m, 'sqlstate', st);
end $f$;
create function pg_temp.n_audit(a text, t text) returns int language sql as $$
  select count(*)::int from public.audit_event where action = a and tenant_id = pg_temp.id(t) $$;

-- Fixtures (as postgres) ---------------------------------------------------
insert into auth.users (id, email, aud, role)
select u, 'tap50-' || n || '@example.test', 'authenticated', 'authenticated' from (values
  ('00000000-0000-4000-c650-0000000000a1'::uuid, 'uax'), ('00000000-0000-4000-c650-0000000000a2', 's1'), ('00000000-0000-4000-c650-0000000000a3', 'freshua'),
  ('00000000-0000-4000-c650-0000000000b1', 'uay'), ('00000000-0000-4000-c650-0000000000c1', 'nomem'), ('00000000-0000-4000-c650-0000000000d1', 'uas'),
  ('00000000-0000-4000-c650-0000000000f1', 'sa')) t(u, n);
insert into ids values ('uax', '00000000-0000-4000-c650-0000000000a1'), ('s1', '00000000-0000-4000-c650-0000000000a2'), ('freshua', '00000000-0000-4000-c650-0000000000a3'),
  ('uay', '00000000-0000-4000-c650-0000000000b1'), ('nomem', '00000000-0000-4000-c650-0000000000c1'), ('uas', '00000000-0000-4000-c650-0000000000d1'),
  ('sa', '00000000-0000-4000-c650-0000000000f1'),
  ('tx', '50000000-0000-4000-c650-00000000000a'), ('ty', '50000000-0000-4000-c650-00000000000b'), ('ts', '50000000-0000-4000-c650-00000000000d');
insert into public.tenant (id, name, status, timezone) values
  ('50000000-0000-4000-c650-00000000000a', 'tap50 org X', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c650-00000000000b', 'tap50 org Y', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c650-00000000000d', 'tap50 org S', 'suspended', 'Asia/Kolkata');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('50000000-0000-4000-c650-00000000000a', '00000000-0000-4000-c650-0000000000a1', 'unit_admin', 'active', 'UA X', 'UA-X', '+919000026001', false),
  ('50000000-0000-4000-c650-00000000000a', '00000000-0000-4000-c650-0000000000a2', 'supervisor', 'active', 'Sup One', 'S1', '+919000026002', false),
  ('50000000-0000-4000-c650-00000000000a', '00000000-0000-4000-c650-0000000000a3', 'unit_admin', 'active', 'Fresh UA', 'FUA', '+919000026003', true),
  ('50000000-0000-4000-c650-00000000000b', '00000000-0000-4000-c650-0000000000b1', 'unit_admin', 'active', 'UA Y', 'UA-Y', '+919000026004', false),
  ('50000000-0000-4000-c650-00000000000d', '00000000-0000-4000-c650-0000000000d1', 'unit_admin', 'active', 'UA S', 'UA-S', '+919000026005', false);
insert into public.platform_admin (user_id, full_name, phone_e164, status, must_change_password) values
  ('00000000-0000-4000-c650-0000000000f1', 'SA 50', '+919000026006', 'active', false);
insert into public.site (id, tenant_id, name, timezone) values
  ('51000000-0000-4000-c650-00000000000a', '50000000-0000-4000-c650-00000000000a', 'Plant X', 'Asia/Kolkata'),
  ('51000000-0000-4000-c650-00000000000b', '50000000-0000-4000-c650-00000000000b', 'Plant Y', 'Asia/Kolkata');
insert into public.machine (id, tenant_id, site_id, code, name, retired_at) values
  ('53000000-0000-4000-c650-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c650-00000000000a', 'M-1', 'Press 1', null),
  ('53000000-0000-4000-c650-0000000000a2', pg_temp.id('tx'), '51000000-0000-4000-c650-00000000000a', 'M-2', 'Press 2', null),
  ('53000000-0000-4000-c650-0000000000a3', pg_temp.id('tx'), '51000000-0000-4000-c650-00000000000a', 'M-3', 'Press 3', null),
  ('53000000-0000-4000-c650-0000000000a4', pg_temp.id('tx'), '51000000-0000-4000-c650-00000000000a', 'M-4', 'Retired press', now()),
  ('53000000-0000-4000-c650-0000000000b1', pg_temp.id('ty'), '51000000-0000-4000-c650-00000000000b', 'Y-1', 'Y press', null);
insert into public.product (id, tenant_id, code, description, retired_at) values
  ('54000000-0000-4000-c650-0000000000a1', pg_temp.id('tx'), 'P-1', 'Part 1', null),
  ('54000000-0000-4000-c650-0000000000a2', pg_temp.id('tx'), 'P-2', 'Part 2', null),
  ('54000000-0000-4000-c650-0000000000a3', pg_temp.id('tx'), 'P-3', 'Retired part', now()),
  ('54000000-0000-4000-c650-0000000000b1', pg_temp.id('ty'), 'Y-P', 'Y part', null);
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time) values
  ('55000000-0000-4000-c650-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c650-00000000000a', 'Day', '06:00', '14:00'),
  ('55000000-0000-4000-c650-0000000000b1', pg_temp.id('ty'), '51000000-0000-4000-c650-00000000000b', 'Y shift', '06:00', '14:00');
insert into ids values ('m1', '53000000-0000-4000-c650-0000000000a1'), ('m2', '53000000-0000-4000-c650-0000000000a2'), ('m3', '53000000-0000-4000-c650-0000000000a3'),
  ('mret', '53000000-0000-4000-c650-0000000000a4'), ('my', '53000000-0000-4000-c650-0000000000b1'),
  ('p1', '54000000-0000-4000-c650-0000000000a1'), ('p2', '54000000-0000-4000-c650-0000000000a2'), ('pret', '54000000-0000-4000-c650-0000000000a3'), ('py', '54000000-0000-4000-c650-0000000000b1'),
  ('day', '55000000-0000-4000-c650-0000000000a1'), ('shifty', '55000000-0000-4000-c650-0000000000b1');
grant select on ids to authenticated, anon;

-- Registry -----------------------------------------------------------------
select is((select count(*)::int from app.audit_action where feature = '06'), 6, 'the six 06 actions are registered');

-- Machine columns ------------------------------------------------------------
select is((select counter_unit || '/' || coalesce(counter_max::text, 'null') from public.machine where id = pg_temp.id('m1')), 'pieces/null', 'existing machines default to pieces with no maximum');
select throws_ok($$ update public.machine set counter_unit = 'litres' where id = pg_temp.id('m1') $$, '23514', null, 'the unit must be pieces or shots');
select throws_ok($$ update public.machine set counter_max = 8 where id = pg_temp.id('m1') $$, '23514', null, 'the maximum must be at least 9');
select throws_ok($$ update public.machine set counter_max = 1000000000001 where id = pg_temp.id('m1') $$, '23514', null, 'the maximum is capped at 10^12');
select lives_ok($$ update public.machine set counter_max = 9999 where id = pg_temp.id('m1') $$, 'a valid maximum is accepted');
select lives_ok($$ update public.machine set counter_max = null where id = pg_temp.id('m1') $$, 'and may be cleared');

-- Table-level facts ------------------------------------------------------------
select is((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relname in ('cavity_version', 'production_reading', 'production_summary') and c.relrowsecurity and c.relforcerowsecurity), 3,
  'RLS is enabled and forced on all three tables');

-- Rows (as postgres): readings for tenant X and Y
insert into public.production_reading (id, tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, late, recorded_by, recorded_at) values
  ('56000000-0000-4000-c650-0000000000a1', pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-02', 'opening', pg_temp.id('p1'), 1000, false, pg_temp.id('s1'), timestamptz '2026-03-02 06:01+05:30'),
  ('56000000-0000-4000-c650-0000000000b1', pg_temp.id('ty'), pg_temp.id('my'), pg_temp.id('shifty'), date '2026-03-02', 'opening', pg_temp.id('py'), 5, false, pg_temp.id('uay'), timestamptz '2026-03-02 06:01+05:30');
insert into public.production_reading (id, tenant_id, machine_id, shift_id, shift_date, kind, counter_value, good, reject, late, recorded_by, recorded_at) values
  ('56000000-0000-4000-c650-0000000000a2', pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-02', 'closing', 1250, 240, 5, false, pg_temp.id('s1'), timestamptz '2026-03-02 14:01+05:30');
insert into public.production_summary (id, tenant_id, machine_id, shift_id, shift_date, calc_version, product_id, counter_unit, cavities, opening_reading_id, closing_reading_id,
  opening_counter, closing_counter, good, reject, target, movement_units, movement_pieces, unaccounted, attainment_pct, rollover, needs_review, over_reported, late_opening, late_closing, entered_by_ua) values
  ('57000000-0000-4000-c650-0000000000a1', pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-02', 1, pg_temp.id('p1'), 'pieces', 1,
   '56000000-0000-4000-c650-0000000000a1', '56000000-0000-4000-c650-0000000000a2', 1000, 1250, 240, 5, 300, 250, 250, 5, 80.00, false, false, false, false, false, false);
insert into public.cavity_version (id, tenant_id, machine_id, product_id, effective_from, cavities, recorded_by) values
  ('58000000-0000-4000-c650-0000000000a1', pg_temp.id('tx'), pg_temp.id('m2'), pg_temp.id('p1'), date '2026-01-01', 4, pg_temp.id('uax'));

-- RLS: Unit Admin reads, everyone else reads nothing -----------------------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('uax');
select is((select count(*)::int from public.production_reading), 2, 'a Unit Admin reads the tenant''s readings');
select is((select count(*)::int from public.production_summary), 1, 'and its summaries');
select is((select count(*)::int from public.cavity_version), 1, 'and its cavity versions');
select is((select count(*)::int from public.production_reading where tenant_id = pg_temp.id('ty')), 0, 'but not another tenant''s');
select pg_temp.as_user('s1');
select is((select count(*)::int from public.production_reading) + (select count(*)::int from public.production_summary) + (select count(*)::int from public.cavity_version), 0,
  'a supervisor has no direct table access (reads go through the RPCs)');
select pg_temp.as_user('uay');
select is((select count(*)::int from public.production_reading), 1, 'another tenant''s Unit Admin reads only its own reading');
select is((select count(*)::int from public.production_summary) + (select count(*)::int from public.cavity_version), 0, 'and none of X''s summaries or cavities');
select pg_temp.as_user('freshua');
select is((select count(*)::int from public.production_reading) + (select count(*)::int from public.production_summary) + (select count(*)::int from public.cavity_version), 0,
  'a Unit Admin with a temporary password reads nothing');
select pg_temp.as_user('nomem');
select is((select count(*)::int from public.production_reading) + (select count(*)::int from public.production_summary) + (select count(*)::int from public.cavity_version), 0, 'a user without membership reads nothing');
select pg_temp.as_user('sa');
select is((select count(*)::int from public.production_reading) + (select count(*)::int from public.production_summary) + (select count(*)::int from public.cavity_version), 0, 'a Super Admin reads nothing');
select pg_temp.as_user('uax');
select throws_ok($$ insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, late, recorded_by)
  values (pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-03', 'opening', pg_temp.id('p1'), 1, false, pg_temp.id('uax')) $$, '42501', null, 'a client cannot insert readings');
select throws_ok($$ update public.production_reading set good = 1 $$, '42501', null, 'a client cannot update readings');
select throws_ok($$ delete from public.production_summary $$, '42501', null, 'a client cannot delete summaries');
select throws_ok($$ insert into public.cavity_version (tenant_id, machine_id, product_id, effective_from, cavities, recorded_by) values (pg_temp.id('tx'), pg_temp.id('m2'), pg_temp.id('p1'), date '2027-01-01', 2, pg_temp.id('uax')) $$,
  '42501', null, 'a client cannot insert cavity versions');
reset role;

-- Append-only: no privilege for the service role, and a trigger that stops the owner too ------------------------------------------------------------
set local role service_role;
select throws_ok($$ update public.production_reading set good = 1 where kind = 'closing' $$, '42501', null, 'the service role cannot update readings');
select throws_ok($$ delete from public.production_reading $$, '42501', null, 'the service role cannot delete readings');
select throws_ok($$ update public.production_summary set good = 1 $$, '42501', null, 'the service role cannot update summaries');
select throws_ok($$ delete from public.cavity_version $$, '42501', null, 'the service role cannot delete cavity versions');
select throws_ok($$ truncate public.production_summary $$, '42501', null, 'the service role cannot truncate');
select lives_ok($$ insert into public.cavity_version (tenant_id, machine_id, product_id, effective_from, cavities, recorded_by)
  values ('50000000-0000-4000-c650-00000000000a', '53000000-0000-4000-c650-0000000000a2', '54000000-0000-4000-c650-0000000000a2', date '2026-02-01', 2, '00000000-0000-4000-c650-0000000000a1') $$,
  'the service role can append (fixtures)');
reset role;
select throws_ok($$ update public.production_reading set good = 1 where kind = 'closing' $$, 'P0001', 'production_reading is append-only', 'the owner cannot update readings either (trigger)');
select throws_ok($$ delete from public.production_reading $$, 'P0001', 'production_reading is append-only', 'nor delete them');
select throws_ok($$ update public.production_summary set good = 1 $$, 'P0001', 'production_summary is append-only', 'nor change summaries');
select throws_ok($$ delete from public.cavity_version $$, 'P0001', 'cavity_version is append-only', 'nor delete cavity versions');
select throws_ok($$ truncate public.production_reading cascade $$, 'P0001', null, 'nor truncate readings');

-- Composite foreign keys -------------------------------------------------------------------------------------------------------------------------------
select throws_ok($$ insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, late, recorded_by)
  values (pg_temp.id('tx'), pg_temp.id('my'), pg_temp.id('day'), date '2026-03-04', 'opening', pg_temp.id('p1'), 1, false, pg_temp.id('uax')) $$, '23503', null, 'a reading cannot name another tenant''s machine');
select throws_ok($$ insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, late, recorded_by)
  values (pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('shifty'), date '2026-03-04', 'opening', pg_temp.id('p1'), 1, false, pg_temp.id('uax')) $$, '23503', null, 'nor another tenant''s shift');
select throws_ok($$ insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, late, recorded_by)
  values (pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-04', 'opening', pg_temp.id('py'), 1, false, pg_temp.id('uax')) $$, '23503', null, 'nor another tenant''s product');
select throws_ok($$ insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, counter_value, good, reject, late, recorded_by, supersedes_id, correction_reason)
  values (pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-02', 'closing', 1, 1, 1, false, pg_temp.id('uax'), '56000000-0000-4000-c650-0000000000b1', 'x') $$, '23514', null,
  'nor supersede another tenant''s reading (the chain trigger refuses it before the FK)');
select throws_ok($$ insert into public.cavity_version (tenant_id, machine_id, product_id, effective_from, cavities, recorded_by) values (pg_temp.id('tx'), pg_temp.id('my'), pg_temp.id('p1'), date '2027-01-01', 2, pg_temp.id('uax')) $$,
  '23503', null, 'cavity versions cannot name another tenant''s machine');
select throws_ok($$ insert into public.production_summary (tenant_id, machine_id, shift_id, shift_date, calc_version, product_id, counter_unit, cavities, opening_reading_id, closing_reading_id, opening_counter, closing_counter, good, reject,
  rollover, needs_review, over_reported, late_opening, late_closing, entered_by_ua)
  values (pg_temp.id('ty'), pg_temp.id('my'), pg_temp.id('shifty'), date '2026-03-02', 1, pg_temp.id('py'), 'pieces', 1, '56000000-0000-4000-c650-0000000000a1', '56000000-0000-4000-c650-0000000000a2', 1, 2, 1, 0, false, false, false, false, false, false) $$,
  '23503', null, 'a summary cannot point at another tenant''s readings');

-- Shape, ranges and the correction chain ----------------------------------------------------------------------------------------------------------------
select throws_ok($$ insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, counter_value, good, reject, late, recorded_by)
  values (pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-05', 'closing', 1, 1, null, false, pg_temp.id('uax')) $$, '23514', null, 'a closing needs good and reject');
select throws_ok($$ insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, counter_value, late, recorded_by)
  values (pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-05', 'opening', 1, false, pg_temp.id('uax')) $$, '23514', null, 'an opening needs a product');
select throws_ok($$ insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, good, reject, late, recorded_by)
  values (pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-05', 'opening', pg_temp.id('p1'), 1, 1, 1, false, pg_temp.id('uax')) $$, '23514', null, 'an opening has no good or reject');
select throws_ok($$ insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, good, reject, late, recorded_by)
  values (pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-05', 'closing', pg_temp.id('p1'), 1, 1, 1, false, pg_temp.id('uax')) $$, '23514', null, 'a closing has no product');
select throws_ok($$ insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, late, recorded_by)
  values (pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-05', 'opening', pg_temp.id('p1'), -1, false, pg_temp.id('uax')) $$, '23514', null, 'a counter cannot be negative');
select throws_ok($$ insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, late, recorded_by)
  values (pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-05', 'opening', pg_temp.id('p1'), 1000000000001, false, pg_temp.id('uax')) $$, '23514', null, 'a counter is capped at 10^12');
select throws_ok($$ insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, counter_value, good, reject, late, recorded_by)
  values (pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-05', 'closing', 1, 10000001, 0, false, pg_temp.id('uax')) $$, '23514', null, 'good is capped at 10,000,000');
select throws_ok($$ insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, remarks, late, recorded_by)
  values (pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-05', 'opening', pg_temp.id('p1'), 1, repeat('x', 501), false, pg_temp.id('uax')) $$, '23514', null, 'remarks are capped at 500 characters');
select throws_ok($$ insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, late, recorded_by)
  values (pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-02', 'opening', pg_temp.id('p1'), 7, false, pg_temp.id('uax')) $$, '23505', null,
  'a second original reading of a kind for the same machine-occurrence is refused');
select throws_ok($$ insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, late, recorded_by, supersedes_id)
  values (pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-02', 'opening', pg_temp.id('p1'), 7, false, pg_temp.id('uax'), '56000000-0000-4000-c650-0000000000a1') $$, '23514', null,
  'a correction needs a reason');
select lives_ok($$ insert into public.production_reading (id, tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, late, recorded_by, supersedes_id, correction_reason)
  values ('56000000-0000-4000-c650-0000000000a3', pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-02', 'opening', pg_temp.id('p1'), 1001, false, pg_temp.id('uax'), '56000000-0000-4000-c650-0000000000a1', 'typo') $$,
  'a correction supersedes the reading');
select throws_ok($$ insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, late, recorded_by, supersedes_id, correction_reason)
  values (pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-02', 'opening', pg_temp.id('p1'), 1002, false, pg_temp.id('uax'), '56000000-0000-4000-c650-0000000000a1', 'again') $$, '23505', null,
  'a reading is superseded at most once (the chain is linear)');
select throws_ok($$ insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, counter_value, good, reject, late, recorded_by, supersedes_id, correction_reason)
  values (pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-02', 'closing', 1, 1, 1, false, pg_temp.id('uax'), '56000000-0000-4000-c650-0000000000a1', 'wrong kind') $$, '23514', null,
  'a correction must supersede a reading of the same kind');
select throws_ok($$ insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, late, recorded_by, supersedes_id, correction_reason)
  values (pg_temp.id('tx'), pg_temp.id('m2'), pg_temp.id('day'), date '2026-03-02', 'opening', pg_temp.id('p1'), 1, false, pg_temp.id('uax'), '56000000-0000-4000-c650-0000000000a3', 'other machine') $$, '23514', null,
  'nor one of another machine-occurrence');
select throws_ok($$ insert into public.cavity_version (tenant_id, machine_id, product_id, effective_from, cavities, recorded_by) values (pg_temp.id('tx'), pg_temp.id('m2'), pg_temp.id('p1'), date '2027-01-01', 0, pg_temp.id('uax')) $$,
  '23514', null, 'cavities must be at least 1');
select throws_ok($$ insert into public.cavity_version (tenant_id, machine_id, product_id, effective_from, cavities, recorded_by) values (pg_temp.id('tx'), pg_temp.id('m2'), pg_temp.id('p1'), date '2027-01-01', 257, pg_temp.id('uax')) $$,
  '23514', null, 'and at most 256');

-- The unit lock (D3), also for direct writes ---------------------------------------------------------------------------------------------------------
select is(pg_temp.err($$ update public.machine set counter_unit = 'shots' where id = pg_temp.id('m1') $$) ->> 'code', 'counter_unit_locked', 'a machine with readings cannot change its unit (trigger)');
select lives_ok($$ update public.machine set counter_unit = 'shots' where id = pg_temp.id('m3') $$, 'a machine without readings can');
select lives_ok($$ update public.machine set counter_unit = 'pieces' where id = pg_temp.id('m3') $$, 'and change it back');
select lives_ok($$ update public.machine set counter_unit = 'pieces', counter_max = 500 where id = pg_temp.id('m1') $$, 'an unchanged unit is not locked (the maximum may change)');
select lives_ok($$ update public.machine set counter_max = null where id = pg_temp.id('m1') $$, 'and be cleared again');

-- rd_set_machine_counter ----------------------------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('uax');
select is(public.rd_set_machine_counter('a0000000-0000-4000-c650-000000000001', pg_temp.id('m3'), 'shots', 99999) ->> 'changed', 'true', 'a Unit Admin sets unit and maximum');
select results_eq($$ select counter_unit, counter_max from public.machine where id = pg_temp.id('m3') $$, $$ values ('shots'::text, 99999::bigint) $$, 'the machine carries them');
select is(pg_temp.n_audit('machine_counter.updated', 'tx'), 1, 'one machine_counter.updated audit row');
select results_eq($$ select before ->> 'counter_unit', after ->> 'counter_unit', after ->> 'counter_max', after ->> 'machine_code' from public.audit_event where action = 'machine_counter.updated' and entity_id = pg_temp.id('m3') $$,
  $$ values ('pieces'::text, 'shots'::text, '99999'::text, 'M-3'::text) $$, 'with before and after');
select is(public.rd_set_machine_counter('a0000000-0000-4000-c650-000000000001', pg_temp.id('m3'), 'shots', 99999) ->> 'already', 'true', 'a replay returns the first outcome');
select is(pg_temp.n_audit('machine_counter.updated', 'tx'), 1, 'and writes nothing more');
select is(public.rd_set_machine_counter('a0000000-0000-4000-c650-000000000002', pg_temp.id('m3'), 'shots', 99999) ->> 'changed', 'false', 'an unchanged setting reports changed:false');
select is(pg_temp.n_audit('machine_counter.updated', 'tx'), 1, 'and is not audited');
select is(public.rd_set_machine_counter('a0000000-0000-4000-c650-000000000003', pg_temp.id('m3'), 'shots', null) ->> 'changed', 'true', 'the maximum can be cleared');
select is(public.rd_set_machine_counter('a0000000-0000-4000-c650-000000000004', pg_temp.id('m3'), 'pieces', 20) ->> 'changed', 'true', 'the unit can change while there are no readings');
select is(pg_temp.err($$ select public.rd_set_machine_counter('a0000000-0000-4000-c650-000000000005', pg_temp.id('m1'), 'shots', null) $$) ->> 'code', 'guard', 'once readings exist the unit cannot change (guard)');
select is(pg_temp.err($$ select public.rd_set_machine_counter('a0000000-0000-4000-c650-000000000005', pg_temp.id('m1'), 'shots', null) $$) ->> 'field', 'counter_unit_locked', 'with field counter_unit_locked');
select is(pg_temp.err($$ select public.rd_set_machine_counter('a0000000-0000-4000-c650-000000000005', pg_temp.id('m1'), 'shots', null) $$) ->> 'message', 'Readings already use this unit', 'and the message the spec names');
select is(public.rd_set_machine_counter('a0000000-0000-4000-c650-000000000006', pg_temp.id('m1'), 'pieces', 123456) ->> 'changed', 'true', 'the maximum can change when readings exist');
select is(pg_temp.err($$ select public.rd_set_machine_counter('a0000000-0000-4000-c650-000000000007', pg_temp.id('m3'), 'litres', null) $$) ->> 'field', 'counter_unit', 'a bad unit is a validation error on counter_unit');
select is(pg_temp.err($$ select public.rd_set_machine_counter('a0000000-0000-4000-c650-000000000007', pg_temp.id('m3'), 'pieces', 8) $$) ->> 'field', 'counter_max', 'a maximum below 9 is refused');
select is(pg_temp.err($$ select public.rd_set_machine_counter('a0000000-0000-4000-c650-000000000007', pg_temp.id('m3'), 'pieces', 1000000000001) $$) ->> 'field', 'counter_max', 'and one above 10^12');
select is(pg_temp.err($$ select public.rd_set_machine_counter(null, pg_temp.id('m3'), 'pieces', 20) $$) ->> 'field', 'request_id', 'a request id is required');
select is(pg_temp.err($$ select public.rd_set_machine_counter('a0000000-0000-4000-c650-000000000008', pg_temp.id('mret'), 'pieces', 20) $$) ->> 'field', 'retired', 'a retired machine cannot be edited');

-- Denials are returned and audited (D13) -----------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('s1');
select is(public.rd_set_machine_counter('a0000000-0000-4000-c650-000000000010', pg_temp.id('m3'), 'pieces', 20), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a supervisor is denied');
select pg_temp.as_user('freshua');
select is(public.rd_set_machine_counter('a0000000-0000-4000-c650-000000000011', pg_temp.id('m3'), 'pieces', 20), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a Unit Admin with a temporary password is denied');
select pg_temp.as_user('uas');
select is(public.rd_set_machine_counter('a0000000-0000-4000-c650-000000000012', pg_temp.id('m3'), 'pieces', 20), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a suspended tenant''s Unit Admin is denied');
select pg_temp.as_user('nomem');
select is(public.rd_set_machine_counter('a0000000-0000-4000-c650-000000000013', pg_temp.id('m3'), 'pieces', 20), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a user without membership is denied');
select pg_temp.as_user('sa');
select is(public.rd_set_machine_counter(null, null, null, null), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a Super Admin is denied');
select pg_temp.as_user('uay');
select is(public.rd_set_machine_counter('a0000000-0000-4000-c650-000000000014', pg_temp.id('m3'), 'pieces', 20), '{"ok": false, "code": "not_allowed"}'::jsonb, 'another tenant''s Unit Admin is denied (cross tenant)');
select is(public.rd_set_machine_counter('a0000000-0000-4000-c650-000000000015', gen_random_uuid(), 'pieces', 20), '{"ok": false, "code": "not_allowed"}'::jsonb, 'an unknown machine looks the same');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and source = 'rpc:rd_set_machine_counter' and reason in ('cross_tenant', 'not_found')), 2, 'cross-tenant and unknown ids are audited with their reason');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and source = 'rpc:rd_set_machine_counter' and reason in ('role', 'must_change_password', 'inactive', 'no_membership', 'platform_admin')), 5,
  'and so are the role, temporary-password, suspended-tenant, no-membership and Super Admin denials');
select is((select counter_unit from public.machine where id = pg_temp.id('m3')), 'pieces', 'the denied calls changed nothing');

-- Cavities (AC-2, D4) -------------------------------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('uax');
select is(app.cavities_for(pg_temp.id('m3'), pg_temp.id('p2'), current_date), 1, 'cavities default to 1 when unset');
select is(pg_temp.err($$ select public.rd_set_cavities('a0000000-0000-4000-c650-000000000020', pg_temp.id('m1'), pg_temp.id('p1'), 4, app.plant_date(pg_temp.id('tx'))) $$) ->> 'field', 'not_shots', 'cavities apply to shots machines only (guard not_shots)');
select is(public.rd_set_machine_counter('a0000000-0000-4000-c650-000000000021', pg_temp.id('m2'), 'shots', null) ->> 'changed', 'true', 'make m2 a shots machine');
select is(public.rd_set_cavities('a0000000-0000-4000-c650-000000000022', pg_temp.id('m2'), pg_temp.id('p1'), 8, app.plant_date(pg_temp.id('tx')) + 3) ->> 'ok', 'true', 'a Unit Admin sets cavities from a future date');
select is(pg_temp.n_audit('cavities.set', 'tx'), 1, 'one cavities.set audit row');
select is(app.cavities_for(pg_temp.id('m2'), pg_temp.id('p1'), app.plant_date(pg_temp.id('tx')) + 2), 4, 'before the date the earlier setting applies (fixture row: 4)');
select is(app.cavities_for(pg_temp.id('m2'), pg_temp.id('p1'), app.plant_date(pg_temp.id('tx')) + 3), 8, 'on the date the new one applies');
select is(app.cavities_for(pg_temp.id('m2'), pg_temp.id('p1'), app.plant_date(pg_temp.id('tx')) + 30), 8, 'and afterwards');
select results_eq($$ select (before ->> 'cavities')::int, (after ->> 'cavities')::int from public.audit_event where action = 'cavities.set' and tenant_id = pg_temp.id('tx') $$, $$ values (4, 8) $$, 'the audit row carries before and after');
select is(public.rd_set_cavities('a0000000-0000-4000-c650-000000000022', pg_temp.id('m2'), pg_temp.id('p1'), 8, app.plant_date(pg_temp.id('tx')) + 3) ->> 'already', 'true', 'a replay returns the first outcome');
select is((select count(*)::int from public.cavity_version where machine_id = pg_temp.id('m2') and product_id = pg_temp.id('p1')), 2, 'and appends nothing');
select is(pg_temp.err($$ select public.rd_set_cavities('a0000000-0000-4000-c650-000000000023', pg_temp.id('m2'), pg_temp.id('p1'), 4, app.plant_date(pg_temp.id('tx')) - 1) $$) ->> 'field', 'effective_from', 'cavities cannot start in the past');
select is(pg_temp.err($$ select public.rd_set_cavities('a0000000-0000-4000-c650-000000000023', pg_temp.id('m2'), pg_temp.id('p1'), 0, app.plant_date(pg_temp.id('tx'))) $$) ->> 'field', 'cavities', 'cavities must be at least 1');
select is(pg_temp.err($$ select public.rd_set_cavities('a0000000-0000-4000-c650-000000000023', pg_temp.id('m2'), pg_temp.id('p1'), 257, app.plant_date(pg_temp.id('tx'))) $$) ->> 'field', 'cavities', 'and at most 256');
select is(pg_temp.err($$ select public.rd_set_cavities('a0000000-0000-4000-c650-000000000023', pg_temp.id('m2'), pg_temp.id('p1'), 4, null) $$) ->> 'field', 'effective_from', 'a start date is required');
select is(pg_temp.err($$ select public.rd_set_cavities('a0000000-0000-4000-c650-000000000023', pg_temp.id('m2'), pg_temp.id('pret'), 4, app.plant_date(pg_temp.id('tx'))) $$) ->> 'field', 'product_id', 'a retired product is refused');
select is(pg_temp.err($$ select public.rd_set_cavities('a0000000-0000-4000-c650-000000000023', pg_temp.id('mret'), pg_temp.id('p1'), 4, app.plant_date(pg_temp.id('tx'))) $$) ->> 'field', 'machine_id', 'and a retired machine');
select is(pg_temp.err($$ select public.rd_set_cavities('a0000000-0000-4000-c650-000000000021', pg_temp.id('m2'), pg_temp.id('p2'), 4, app.plant_date(pg_temp.id('tx'))) $$) ->> 'field', 'request_id', 'a request id reused for another RPC is a validation error (D2)');
select is(public.rd_set_cavities('a0000000-0000-4000-c650-000000000024', pg_temp.id('my'), pg_temp.id('p1'), 4, app.plant_date(pg_temp.id('tx'))), '{"ok": false, "code": "not_allowed"}'::jsonb, 'another tenant''s machine is denied');
select is(public.rd_set_cavities('a0000000-0000-4000-c650-000000000025', pg_temp.id('m2'), pg_temp.id('py'), 4, app.plant_date(pg_temp.id('tx'))), '{"ok": false, "code": "not_allowed"}'::jsonb, 'and another tenant''s product');

-- "End means end": the end date plus every later scheduled change goes
select is(public.rd_end_cavities('a0000000-0000-4000-c650-000000000026', pg_temp.id('m2'), pg_temp.id('p1'), app.plant_date(pg_temp.id('tx')) + 1) -> 'cancelled', to_jsonb(array[app.plant_date(pg_temp.id('tx')) + 3]), 'ending from tomorrow cancels the change scheduled in 3 days');
select is(app.cavities_for(pg_temp.id('m2'), pg_temp.id('p1'), app.plant_date(pg_temp.id('tx')) + 1), 1, 'from the end date the default (1) applies');
select is(app.cavities_for(pg_temp.id('m2'), pg_temp.id('p1'), app.plant_date(pg_temp.id('tx')) + 30), 1, 'and stays so: the later scheduled setting no longer wins');
select is(app.cavities_for(pg_temp.id('m2'), pg_temp.id('p1'), app.plant_date(pg_temp.id('tx'))), 4, 'before the end date the earlier setting still applies');
select is(pg_temp.n_audit('cavities.ended', 'tx'), 1, 'one cavities.ended audit row');
select is(pg_temp.err($$ select public.rd_end_cavities('a0000000-0000-4000-c650-000000000027', pg_temp.id('m2'), pg_temp.id('p1'), app.plant_date(pg_temp.id('tx')) + 10) $$) ->> 'field', 'no_cavities', 'ending where nothing is in force is refused');
select is(pg_temp.err($$ select public.rd_end_cavities('a0000000-0000-4000-c650-000000000027', pg_temp.id('m2'), pg_temp.id('p1'), app.plant_date(pg_temp.id('tx')) - 1) $$) ->> 'field', 'effective_from', 'and ending in the past');
select pg_temp.as_user('s1');
select is(public.rd_set_cavities('a0000000-0000-4000-c650-000000000028', pg_temp.id('m2'), pg_temp.id('p1'), 4, app.plant_date(pg_temp.id('tx'))), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a supervisor cannot set cavities');
select is(public.rd_end_cavities('a0000000-0000-4000-c650-000000000029', pg_temp.id('m2'), pg_temp.id('p1'), app.plant_date(pg_temp.id('tx'))), '{"ok": false, "code": "not_allowed"}'::jsonb, 'nor end them');
select pg_temp.as_user('sa');
select is(public.rd_set_cavities(null, null, null, null, null), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a Super Admin is denied');
select is(public.rd_end_cavities(null, null, null, null), '{"ok": false, "code": "not_allowed"}'::jsonb, 'for ending too');

-- cavities_for has no bypass: only the tenant's own members (and the service role) see the settings ----------------------------------------------------
select pg_temp.as_user('uay');
select is(app._cavities_raw(pg_temp.id('m2'), pg_temp.id('p1'), current_date + 5), null, 'another tenant''s caller reads no setting');
select is(app.cavities_for(pg_temp.id('m2'), pg_temp.id('p1'), current_date + 5), 1, 'and gets the default');
select set_config('request.jwt.claims', '', true);
select is(app._cavities_raw(pg_temp.id('m2'), pg_temp.id('p1'), date '2026-02-01'), null, 'a caller with no claims reads no setting');
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select is(app._cavities_raw(pg_temp.id('m2'), pg_temp.id('p1'), date '2026-02-01'), 4, 'the service role does');

-- Privileges --------------------------------------------------------------------------------------------------------------------------------------------------
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname ~ '^(_rd_|rd_|cavities_for$|_cavities_raw$)'
              and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))), 0,
  'no 06 function in app is executable by clients');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname ~ '^rd_' and has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute')),
          (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname ~ '^rd_'),
  'every public rd_* RPC is executable by authenticated and not by anon');

-- 8b N5: a non-partial index serves every current-reading lookup
select is((select count(*)::int from pg_indexes where schemaname = 'public' and tablename = 'production_reading' and indexname = 'production_reading_current_idx'
             and indexdef like '%(tenant_id, machine_id, shift_id, shift_date, kind)%' and indexdef not like '%WHERE%'), 1, 'N5: production_reading has a non-partial (tenant_id, machine_id, shift_id, shift_date, kind) index');

select * from finish();
rollback;
