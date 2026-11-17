-- 06 AC-11, AC-12, AC-13, AC-15, D8, D9: the read side. reading_state (a supervisor's machines per occurrence with state, default product and what they
-- may do), reading_detail (history, summary, owner rule), today_board (Unit Admin only; assigned machines only; current + previous occurrence; totals;
-- flags; volume), reading_capture (expected vs on time) and the pins: the public reads accept no client time, 06's inline owner rule equals 05's
-- (my_shift / machine_owner) and 06's window formula equals app.shift_window. The reads are driven with explicit moments through the app.*_at helpers
-- on fixed past dates (the readings are fixtures inserted as the table owner). Self-contained; rolled back.
begin;
create extension if not exists pgtap with schema extensions;
select plan(117);

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
create function pg_temp.ts(dd date, hhmm text) returns timestamptz language sql as $$ select (dd + hhmm::time) at time zone 'Asia/Kolkata' $$;
-- Readings inserted as the table owner. machine/shift/product by key; the ids are kept under `label`.
create function pg_temp.po(label text, mach text, shft text, dd date, counter bigint, prod text, at_ts timestamptz, late boolean default false, by text default 's1', supersedes text default null) returns void language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into public.production_reading (id, tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, late, recorded_by, recorded_at, supersedes_id, correction_reason)
  values (v, pg_temp.id('tx'), pg_temp.id(mach), pg_temp.id(shft), dd, 'opening', pg_temp.id(prod), counter, late, pg_temp.id(by), at_ts, case when supersedes is not null then pg_temp.id(supersedes) end, case when supersedes is not null then 'fix' end);
  insert into ids values (label, v);
end $$;
create function pg_temp.pc(label text, mach text, shft text, dd date, counter bigint, good int, reject int, at_ts timestamptz, late boolean default false, by text default 's1') returns void language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into public.production_reading (id, tenant_id, machine_id, shift_id, shift_date, kind, counter_value, good, reject, late, recorded_by, recorded_at)
  values (v, pg_temp.id('tx'), pg_temp.id(mach), pg_temp.id(shft), dd, 'closing', counter, good, reject, late, pg_temp.id(by), at_ts);
  insert into ids values (label, v);
end $$;
create function pg_temp.summ(mach text, shft text, dd date) returns uuid language sql as $$
  select app._rd_compute_summary(pg_temp.id('tx'), pg_temp.id('uax'), pg_temp.id(mach), pg_temp.id(shft), dd, null) $$;
-- One machine's entry in one occurrence of reading_state_at (as the current user)
create function pg_temp.ms(p_at timestamptz, shft text, dd date, code text) returns jsonb language sql as $$
  select m from jsonb_array_elements(app.reading_state_at($1) -> 'occurrences') o, jsonb_array_elements(o -> 'machines') m
   where (o -> 'shift' ->> 'id')::uuid = pg_temp.id($2) and (o ->> 'shift_date')::date = $3 and m ->> 'code' = $4 $$;
create function pg_temp.codes(p_at timestamptz, shft text, dd date) returns text language sql as $$
  select coalesce(string_agg(m ->> 'code', ',' order by m ->> 'code'), '-') from jsonb_array_elements(app.reading_state_at($1) -> 'occurrences') o, jsonb_array_elements(o -> 'machines') m
   where (o -> 'shift' ->> 'id')::uuid = pg_temp.id($2) and (o ->> 'shift_date')::date = $3 $$;
create function pg_temp.nocc(p_at timestamptz) returns int language sql as $$ select jsonb_array_length(app.reading_state_at($1) -> 'occurrences') $$;
-- One machine's entry in an occurrence of the board
create function pg_temp.bm(p_at timestamptz, shft text, dd date, code text) returns jsonb language sql as $$
  select m from jsonb_array_elements(app.today_board_at($1) -> 'occurrences') o, jsonb_array_elements(o -> 'machines') m
   where (o -> 'shift' ->> 'id')::uuid = pg_temp.id($2) and (o ->> 'shift_date')::date = $3 and m ->> 'code' = $4 $$;
create function pg_temp.bo(p_at timestamptz, shft text, dd date) returns jsonb language sql as $$
  select o from jsonb_array_elements(app.today_board_at($1) -> 'occurrences') o where (o -> 'shift' ->> 'id')::uuid = pg_temp.id($2) and (o ->> 'shift_date')::date = $3 $$;

-- Fixtures (as postgres) ---------------------------------------------------
insert into auth.users (id, email, aud, role)
select u, 'tap53-' || n || '@example.test', 'authenticated', 'authenticated' from (values
  ('00000000-0000-4000-c653-0000000000a1'::uuid, 'uax'), ('00000000-0000-4000-c653-0000000000a2', 's1'), ('00000000-0000-4000-c653-0000000000a3', 's2'),
  ('00000000-0000-4000-c653-0000000000a4', 'sinact'), ('00000000-0000-4000-c653-0000000000a5', 'sfresh'), ('00000000-0000-4000-c653-0000000000b1', 'uay'),
  ('00000000-0000-4000-c653-0000000000c1', 'nomem'), ('00000000-0000-4000-c653-0000000000e1', 'uaz'), ('00000000-0000-4000-c653-0000000000f1', 'sa'),
  ('00000000-0000-4000-c653-0000000000d1', 'uav'), ('00000000-0000-4000-c653-0000000000d2', 'sv')) t(u, n);
insert into ids values ('uax', '00000000-0000-4000-c653-0000000000a1'), ('s1', '00000000-0000-4000-c653-0000000000a2'), ('s2', '00000000-0000-4000-c653-0000000000a3'),
  ('sinact', '00000000-0000-4000-c653-0000000000a4'), ('sfresh', '00000000-0000-4000-c653-0000000000a5'), ('uay', '00000000-0000-4000-c653-0000000000b1'),
  ('nomem', '00000000-0000-4000-c653-0000000000c1'), ('uaz', '00000000-0000-4000-c653-0000000000e1'), ('sa', '00000000-0000-4000-c653-0000000000f1'),
  ('uav', '00000000-0000-4000-c653-0000000000d1'), ('sv', '00000000-0000-4000-c653-0000000000d2'),
  ('tx', '50000000-0000-4000-c653-00000000000a'), ('ty', '50000000-0000-4000-c653-00000000000b'), ('tz', '50000000-0000-4000-c653-00000000000e'), ('tv', '50000000-0000-4000-c653-00000000000d');
insert into public.tenant (id, name, status, timezone) values
  ('50000000-0000-4000-c653-00000000000a', 'tap53 org X', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c653-00000000000b', 'tap53 org Y', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c653-00000000000e', 'tap53 org Z (no shifts)', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c653-00000000000d', 'tap53 org V (volume)', 'active', 'Asia/Kolkata');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('50000000-0000-4000-c653-00000000000a', '00000000-0000-4000-c653-0000000000a1', 'unit_admin', 'active', 'UA X', 'UA-X', '+919000026301', false),
  ('50000000-0000-4000-c653-00000000000a', '00000000-0000-4000-c653-0000000000a2', 'supervisor', 'active', 'Sup One', 'S1', '+919000026302', false),
  ('50000000-0000-4000-c653-00000000000a', '00000000-0000-4000-c653-0000000000a3', 'supervisor', 'active', 'Sup Two', 'S2', '+919000026303', false),
  ('50000000-0000-4000-c653-00000000000a', '00000000-0000-4000-c653-0000000000a4', 'supervisor', 'inactive', 'Sup Gone', 'S3', '+919000026304', false),
  ('50000000-0000-4000-c653-00000000000a', '00000000-0000-4000-c653-0000000000a5', 'supervisor', 'active', 'Sup Fresh', 'S4', '+919000026305', true),
  ('50000000-0000-4000-c653-00000000000b', '00000000-0000-4000-c653-0000000000b1', 'unit_admin', 'active', 'UA Y', 'UA-Y', '+919000026306', false),
  ('50000000-0000-4000-c653-00000000000e', '00000000-0000-4000-c653-0000000000e1', 'unit_admin', 'active', 'UA Z', 'UA-Z', '+919000026307', false),
  ('50000000-0000-4000-c653-00000000000d', '00000000-0000-4000-c653-0000000000d1', 'unit_admin', 'active', 'UA V', 'UA-V', '+919000026308', false),
  ('50000000-0000-4000-c653-00000000000d', '00000000-0000-4000-c653-0000000000d2', 'supervisor', 'active', 'Sup V', 'SV', '+919000026309', false);
insert into public.platform_admin (user_id, full_name, phone_e164, status, must_change_password) values ('00000000-0000-4000-c653-0000000000f1', 'SA 53', '+919000026310', 'active', false);
insert into public.site (id, tenant_id, name, timezone) values
  ('51000000-0000-4000-c653-00000000000a', pg_temp.id('tx'), 'Plant X', 'Asia/Kolkata'), ('51000000-0000-4000-c653-00000000000b', pg_temp.id('ty'), 'Plant Y', 'Asia/Kolkata'),
  ('51000000-0000-4000-c653-00000000000e', pg_temp.id('tz'), 'Plant Z', 'Asia/Kolkata'), ('51000000-0000-4000-c653-00000000000d', pg_temp.id('tv'), 'Plant V', 'Asia/Kolkata');
insert into public.machine (id, tenant_id, site_id, code, name, counter_unit, retired_at) values
  ('53000000-0000-4000-c653-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c653-00000000000a', 'M1', 'Press 1', 'pieces', null),
  ('53000000-0000-4000-c653-0000000000a2', pg_temp.id('tx'), '51000000-0000-4000-c653-00000000000a', 'M2', 'Press 2', 'shots', null),
  ('53000000-0000-4000-c653-0000000000a3', pg_temp.id('tx'), '51000000-0000-4000-c653-00000000000a', 'M3', 'Press 3', 'pieces', null),
  ('53000000-0000-4000-c653-0000000000a4', pg_temp.id('tx'), '51000000-0000-4000-c653-00000000000a', 'M4', 'Unassigned press', 'pieces', null),
  ('53000000-0000-4000-c653-0000000000a5', pg_temp.id('tx'), '51000000-0000-4000-c653-00000000000a', 'M5', 'Retired later', 'pieces', now()),
  ('53000000-0000-4000-c653-0000000000a6', pg_temp.id('tx'), '51000000-0000-4000-c653-00000000000a', 'M6', 'Retired, no plan', 'pieces', now()),
  ('53000000-0000-4000-c653-0000000000a7', pg_temp.id('tx'), '51000000-0000-4000-c653-00000000000a', 'M7', 'Retired before', 'pieces', timestamptz '2026-01-15 00:00+05:30'),
  ('53000000-0000-4000-c653-0000000000a8', pg_temp.id('tx'), '51000000-0000-4000-c653-00000000000a', 'M8', 'Press 8', 'pieces', null),
  ('53000000-0000-4000-c653-0000000000b1', pg_temp.id('ty'), '51000000-0000-4000-c653-00000000000b', 'Y1', 'Y press', 'pieces', null);
insert into public.product (id, tenant_id, code, description, retired_at) values
  ('54000000-0000-4000-c653-0000000000a1', pg_temp.id('tx'), 'P-1', 'Part 1', null), ('54000000-0000-4000-c653-0000000000a2', pg_temp.id('tx'), 'P-2', 'Part 2', null),
  ('54000000-0000-4000-c653-0000000000a3', pg_temp.id('tx'), 'P-3', 'Retired part', now());
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time) values
  ('55000000-0000-4000-c653-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c653-00000000000a', 'Day', '06:00', '14:00'),
  ('55000000-0000-4000-c653-0000000000a2', pg_temp.id('tx'), '51000000-0000-4000-c653-00000000000a', 'Night', '22:00', '06:00'),
  ('55000000-0000-4000-c653-0000000000b1', pg_temp.id('ty'), '51000000-0000-4000-c653-00000000000b', 'Y shift', '06:00', '14:00');
insert into ids values ('m1', '53000000-0000-4000-c653-0000000000a1'), ('m2', '53000000-0000-4000-c653-0000000000a2'), ('m3', '53000000-0000-4000-c653-0000000000a3'),
  ('m4', '53000000-0000-4000-c653-0000000000a4'), ('m5', '53000000-0000-4000-c653-0000000000a5'), ('m6', '53000000-0000-4000-c653-0000000000a6'), ('m7', '53000000-0000-4000-c653-0000000000a7'),
  ('m8', '53000000-0000-4000-c653-0000000000a8'), ('my', '53000000-0000-4000-c653-0000000000b1'),
  ('p1', '54000000-0000-4000-c653-0000000000a1'), ('p2', '54000000-0000-4000-c653-0000000000a2'), ('pret', '54000000-0000-4000-c653-0000000000a3'),
  ('day', '55000000-0000-4000-c653-0000000000a1'), ('night', '55000000-0000-4000-c653-0000000000a2'), ('shifty', '55000000-0000-4000-c653-0000000000b1');
insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by) values
  (pg_temp.id('tx'), pg_temp.id('day'), pg_temp.id('m1'), pg_temp.id('s1'), date '2026-01-01', pg_temp.id('uax')),
  (pg_temp.id('tx'), pg_temp.id('night'), pg_temp.id('m1'), pg_temp.id('s1'), date '2026-01-01', pg_temp.id('uax')),
  (pg_temp.id('tx'), pg_temp.id('day'), pg_temp.id('m2'), pg_temp.id('s1'), date '2026-01-01', pg_temp.id('uax')),
  (pg_temp.id('tx'), pg_temp.id('day'), pg_temp.id('m3'), pg_temp.id('s2'), date '2026-01-01', pg_temp.id('uax')),
  (pg_temp.id('tx'), pg_temp.id('day'), pg_temp.id('m5'), pg_temp.id('s1'), date '2026-01-01', pg_temp.id('uax')),
  (pg_temp.id('tx'), pg_temp.id('day'), pg_temp.id('m7'), pg_temp.id('s1'), date '2026-01-01', pg_temp.id('uax')),
  (pg_temp.id('tx'), pg_temp.id('day'), pg_temp.id('m8'), pg_temp.id('s2'), date '2026-01-01', pg_temp.id('uax'));
insert into public.target_version (tenant_id, machine_id, product_id, effective_from, pieces_per_shift, recorded_by) values
  (pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('p1'), date '2026-01-01', 1000, pg_temp.id('uax')),
  (pg_temp.id('tx'), pg_temp.id('m2'), pg_temp.id('p1'), date '2026-01-01', 1200, pg_temp.id('uax')),
  (pg_temp.id('tx'), pg_temp.id('m3'), pg_temp.id('p2'), date '2026-01-01', 500, pg_temp.id('uax'));
insert into public.cavity_version (tenant_id, machine_id, product_id, effective_from, cavities, recorded_by) values
  (pg_temp.id('tx'), pg_temp.id('m2'), pg_temp.id('p1'), date '2026-01-01', 4, pg_temp.id('uax'));
grant select on ids to authenticated, anon;

-- Readings. D = 2026-03-10 (all of 06's fixture data lives on fixed past dates).
select pg_temp.po('o1_d', 'm1', 'day', date '2026-03-10', 1000, 'p1', pg_temp.ts(date '2026-03-10', '06:05'));
select pg_temp.pc('c1_d', 'm1', 'day', date '2026-03-10', 1250, 240, 5, pg_temp.ts(date '2026-03-10', '14:05'));
select pg_temp.po('o3_d', 'm3', 'day', date '2026-03-10', 50, 'p2', pg_temp.ts(date '2026-03-10', '06:40'), true, 's2');
select pg_temp.po('o5_d', 'm5', 'day', date '2026-03-10', 5, 'p1', pg_temp.ts(date '2026-03-10', '06:05'));
select pg_temp.po('o1_p', 'm1', 'day', date '2026-03-09', 10, 'p2', pg_temp.ts(date '2026-03-09', '06:05'));
select pg_temp.po('o2_p', 'm2', 'day', date '2026-03-09', 7, 'p1', pg_temp.ts(date '2026-03-09', '06:05'));
select pg_temp.po('o3_p', 'm3', 'day', date '2026-03-09', 40, 'pret', pg_temp.ts(date '2026-03-09', '06:05'), false, 's2');
select pg_temp.pc('c3_p', 'm3', 'day', date '2026-03-09', 90, 30, 2, pg_temp.ts(date '2026-03-09', '14:05'), false, 's2');
select pg_temp.po('o8_pp', 'm8', 'day', date '2026-03-08', 1, 'p1', pg_temp.ts(date '2026-03-08', '06:05'), false, 's2');
select pg_temp.po('o8_p', 'm8', 'day', date '2026-03-09', 2, 'pret', pg_temp.ts(date '2026-03-09', '06:05'), false, 's2');
select pg_temp.po('on1_p', 'm1', 'night', date '2026-03-09', 20000, 'p1', pg_temp.ts(date '2026-03-09', '22:05'));
select pg_temp.pc('cn1_p', 'm1', 'night', date '2026-03-09', 20300, 280, 10, pg_temp.ts(date '2026-03-10', '07:00'), true);
select pg_temp.as_user('uax');
select pg_temp.summ('m1', 'day', date '2026-03-10');
select pg_temp.summ('m1', 'night', date '2026-03-09');

-- Pins to 05 ---------------------------------------------------------------------------------------------------------------------------------------------
select is((select count(*)::int from (select s.id, d.d from public.shift s cross join (values (date '2026-03-10'), (date '2026-03-31'), (date '2026-12-31')) d(d)
            where app._rd_window(s.start_time, s.end_time, d.d, 'Asia/Kolkata') is distinct from app.shift_window(s.id, d.d) and s.tenant_id = pg_temp.id('tx')) q), 0,
  '06''s window formula equals app.shift_window for the day shift and the overnight shift');
select is(public.reading_state() ->> 'ok', 'true', 'the public reading_state works with no arguments');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('reading_state', 'reading_detail', 'today_board') and ('timestamptz'::regtype = any (p.proargtypes) or 'timestamp'::regtype = any (p.proargtypes))), 0,
  'no public read RPC accepts a client-supplied time (07 review R1)');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname in ('reading_state', 'today_board') and p.pronargs = 0), 2,
  'reading_state and today_board take no arguments at all');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname ~ '^(reading_|today_board|_rd_window)' and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))), 0,
  'the _at helpers, reading_capture and the window helper are not executable by clients');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('reading_state', 'reading_detail', 'today_board') and has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute')), 3,
  'the three public reads are executable by authenticated and not by anon');

-- reading_state (AC-11) ----------------------------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('s1');
select is(pg_temp.codes(pg_temp.ts(date '2026-03-10', '05:20'), 'day', date '2026-03-10'), '-', 'more than 30 minutes before the start the occurrence is not listed yet');
select is(pg_temp.codes(pg_temp.ts(date '2026-03-10', '05:20'), 'night', date '2026-03-09'), 'M1', 'while the overnight occurrence that started the evening before is still running');
select is((select (o ->> 'running')::boolean from jsonb_array_elements(app.reading_state_at(pg_temp.ts(date '2026-03-10', '05:20')) -> 'occurrences') o where (o ->> 'shift_date')::date = date '2026-03-09'), true, 'and is flagged running');
select is(pg_temp.codes(pg_temp.ts(date '2026-03-10', '05:30'), 'day', date '2026-03-10'), 'M1,M2', 'exactly 30 minutes before the start the occurrence is listed: the supervisor''s own machines (M5 retired, M3/M8 belong to the other supervisor)');
select is(pg_temp.ms(pg_temp.ts(date '2026-03-10', '05:40'), 'day', date '2026-03-10', 'M2') ->> 'state', 'opening_due', 'M2: opening due');
select is((pg_temp.ms(pg_temp.ts(date '2026-03-10', '05:40'), 'day', date '2026-03-10', 'M2') ->> 'can_open')::boolean, true, 'the supervisor can open it');
select is((pg_temp.ms(pg_temp.ts(date '2026-03-10', '05:40'), 'day', date '2026-03-10', 'M2') ->> 'can_close')::boolean, false, 'but not close it');
select is((pg_temp.ms(pg_temp.ts(date '2026-03-10', '05:40'), 'day', date '2026-03-10', 'M2') ->> 'can_correct')::boolean, false, 'nor correct anything');
select is(pg_temp.ms(pg_temp.ts(date '2026-03-10', '05:40'), 'day', date '2026-03-10', 'M2') ->> 'default_product_id', pg_temp.id('p1')::text, 'the default product is the latest opening''s product (P-1)');
select is(pg_temp.ms(pg_temp.ts(date '2026-03-10', '05:40'), 'day', date '2026-03-10', 'M2') ->> 'counter_unit', 'shots', 'the counter unit comes with the machine');
select is(pg_temp.ms(pg_temp.ts(date '2026-03-10', '08:00'), 'day', date '2026-03-10', 'M1') ->> 'state', 'closed', 'M1 has both readings (the fixtures are not time-filtered): closed');
select is(pg_temp.ms(pg_temp.ts(date '2026-03-10', '08:00'), 'day', date '2026-03-10', 'M1') #>> '{opening,late}', 'false', 'the opening shows when and whether it was late');
select is(pg_temp.ms(pg_temp.ts(date '2026-03-10', '08:00'), 'day', date '2026-03-10', 'M1') #>> '{summary,attainment_pct}', '24.00', 'and the summary its attainment (240 / 1000)');
select is(pg_temp.ms(pg_temp.ts(date '2026-03-10', '08:00'), 'day', date '2026-03-10', 'M1') #>> '{summary,target}', '1000', 'with the target');
select is(pg_temp.ms(pg_temp.ts(date '2026-03-10', '08:00'), 'day', date '2026-03-10', 'M1') #>> '{closing,good}', '240', 'and the closing''s good quantity');
select is((pg_temp.ms(pg_temp.ts(date '2026-03-10', '14:10'), 'day', date '2026-03-10', 'M1') ->> 'can_correct')::boolean, true, 'a closed machine can be corrected until the next occurrence starts');
select is(pg_temp.ms(pg_temp.ts(date '2026-03-10', '14:10'), 'day', date '2026-03-10', 'M2') ->> 'state', 'opening_missed', 'after the end, a machine with no opening is opening_missed');
select is((pg_temp.ms(pg_temp.ts(date '2026-03-10', '14:10'), 'day', date '2026-03-10', 'M2') ->> 'can_open')::boolean, false, 'and cannot be opened by the supervisor any more');
select pg_temp.as_user('s2');
select is(pg_temp.codes(pg_temp.ts(date '2026-03-10', '08:00'), 'day', date '2026-03-10'), 'M3,M8', 'the other supervisor sees only their machines');
select is(pg_temp.ms(pg_temp.ts(date '2026-03-10', '08:00'), 'day', date '2026-03-10', 'M3') ->> 'state', 'opening_done', 'M3: opening done');
select is(pg_temp.ms(pg_temp.ts(date '2026-03-10', '08:00'), 'day', date '2026-03-10', 'M3') #>> '{opening,late}', 'true', 'and it was late');
select is((pg_temp.ms(pg_temp.ts(date '2026-03-10', '08:00'), 'day', date '2026-03-10', 'M3') ->> 'can_close')::boolean, true, 'the closing can be recorded');
select is(pg_temp.ms(pg_temp.ts(date '2026-03-10', '14:10'), 'day', date '2026-03-10', 'M3') ->> 'state', 'closing_due', 'after the end an opening without closing is closing_due');
select is(pg_temp.ms(pg_temp.ts(date '2026-03-10', '08:00'), 'day', date '2026-03-10', 'M8') ->> 'default_product_id', pg_temp.id('p1')::text, 'a retired product is skipped for the default (P-3 is retired, the older P-1 is used)');
select is(pg_temp.ms(pg_temp.ts(date '2026-03-10', '08:00'), 'day', date '2026-03-10', 'M3') ->> 'default_product_id', pg_temp.id('p2')::text, 'and the latest opening wins otherwise (P-2 on the 10th)');
select is(pg_temp.codes(pg_temp.ts(date '2026-03-11', '02:00'), 'day', date '2026-03-10'), 'M3,M8', '12 hours after the end the occurrence is still listed (closing window)');
select is(pg_temp.codes(pg_temp.ts(date '2026-03-11', '02:00') + interval '1 second', 'day', date '2026-03-10'), '-', 'and one second later it is gone');
select is(pg_temp.codes(pg_temp.ts(date '2026-03-10', '14:10'), 'night', date '2026-03-10'), '-', 'a supervisor with no machine in the night shift sees nothing for it');
select pg_temp.as_user('uax');
select is(app.reading_state_at(pg_temp.ts(date '2026-03-10', '08:00')) ->> 'state', 'none', 'a Unit Admin owns no machines: nothing listed');
select pg_temp.as_user('uaz');
select is(app.reading_state_at(pg_temp.ts(date '2026-03-10', '08:00')) ->> 'state', 'no_shifts', 'a tenant without shifts says so');
-- covers: on 2026-03-17 M1 is covered by s2 and M2 by nobody
insert into public.assignment_cover (tenant_id, shift_id, shift_date, machine_id, supervisor_id, reason, recorded_by) values
  (pg_temp.id('tx'), pg_temp.id('day'), date '2026-03-17', pg_temp.id('m1'), pg_temp.id('s2'), 'sick', pg_temp.id('uax')),
  (pg_temp.id('tx'), pg_temp.id('day'), date '2026-03-17', pg_temp.id('m2'), null, 'nobody', pg_temp.id('uax'));
select pg_temp.as_user('s1');
select is(pg_temp.codes(pg_temp.ts(date '2026-03-17', '08:00'), 'day', date '2026-03-17'), '-', 'a covered-away machine and an explicitly unassigned one leave the planned owner''s list (M5 retired)');
select pg_temp.as_user('s2');
select is(pg_temp.codes(pg_temp.ts(date '2026-03-17', '08:00'), 'day', date '2026-03-17'), 'M1,M3,M8', 'and the covering supervisor gets M1');
select pg_temp.as_user('s1');
select is((select array_agg(m ->> 'code' order by m ->> 'code') from jsonb_array_elements(public.my_shift(pg_temp.ts(date '2026-03-10', '08:00')) -> 'occurrences') o, jsonb_array_elements(o -> 'machines') m where (o ->> 'running')::boolean),
          (select array_agg(m ->> 'code' order by m ->> 'code') from jsonb_array_elements(app.reading_state_at(pg_temp.ts(date '2026-03-10', '08:00')) -> 'occurrences') o, jsonb_array_elements(o -> 'machines') m where (o ->> 'running')::boolean),
  'pin: the running machines equal 05''s my_shift for the same supervisor and moment');
select pg_temp.as_user('s2');
select is((select array_agg(m ->> 'code' order by m ->> 'code') from jsonb_array_elements(public.my_shift(pg_temp.ts(date '2026-03-17', '08:00')) -> 'occurrences') o, jsonb_array_elements(o -> 'machines') m where (o ->> 'running')::boolean),
          (select array_agg(m ->> 'code' order by m ->> 'code') from jsonb_array_elements(app.reading_state_at(pg_temp.ts(date '2026-03-17', '08:00')) -> 'occurrences') o, jsonb_array_elements(o -> 'machines') m where (o ->> 'running')::boolean),
  'pin: and with a cover in play');
-- denials of the public wrapper
select pg_temp.as_user('sinact');
select is(public.reading_state(), '{"ok": false, "code": "not_allowed"}'::jsonb, 'an inactive user is denied');
select pg_temp.as_user('sfresh');
select is(public.reading_state(), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a user with a temporary password is denied');
select pg_temp.as_user('nomem');
select is(public.reading_state(), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a user without membership is denied');
select pg_temp.as_user('sa');
select is(public.reading_state(), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a Super Admin is denied');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and source = 'rpc:reading_state' and reason = 'platform_admin'), 1, 'the Super Admin denial is audited as a platform event');

-- reading_detail (AC-15) -----------------------------------------------------------------------------------------------------------------------------------
-- a correction of M1's opening on the 10th, so there is a history
select pg_temp.po('o1_d2', 'm1', 'day', date '2026-03-10', 1005, 'p1', pg_temp.ts(date '2026-03-10', '08:00'), false, 's1', 'o1_d');
select pg_temp.as_user('s1');
select is(app.reading_detail_at(pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-10', '14:10')) ->> 'ok', 'true', 'the owner reads the occurrence');
select is(jsonb_array_length(app.reading_detail_at(pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-10', '14:10')) -> 'readings'), 3, 'with the whole history (two openings and the closing)');
select is(app.reading_detail_at(pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-10', '14:10')) #>> '{opening,id}', pg_temp.id('o1_d2')::text, 'the current opening is the correction');
select is(app.reading_detail_at(pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-10', '14:10')) #>> '{opening,correction_reason}', 'fix', 'carrying its reason');
select is((select (e ->> 'current')::boolean from jsonb_array_elements(app.reading_detail_at(pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-10', '14:10')) -> 'readings') e where (e ->> 'id')::uuid = pg_temp.id('o1_d')), false, 'the superseded one is marked not current');
select is(app.reading_detail_at(pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-10', '14:10')) #>> '{closing,good}', '240', 'the closing is there');
select is(app.reading_detail_at(pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-10', '14:10')) #>> '{summary,movement_pieces}', '250', 'and the latest summary');
select is((app.reading_detail_at(pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-10', '14:10')) ->> 'summary_count')::int, 1, 'with the number of calculations so far');
select is(app.reading_detail_at(pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-10', '14:10')) ->> 'owner_name', 'Sup One', 'and the owner');
select is(app.reading_detail_at(pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-10', '14:10')) #>> '{readings,0,recorded_by_name}', 'Sup One', 'each reading names who recorded it');
select is((app.reading_detail_at(pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-10', '14:10')) #>> '{allowed,can_correct}')::boolean, true, 'the owner may correct on the same day');
select is((app.reading_detail_at(pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-11', '07:00')) #>> '{allowed,can_correct}')::boolean, false, 'but not once the next occurrence has started');
select is((app.reading_detail_at(pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-10', '14:10')) #>> '{allowed,can_close}')::boolean, false, 'a closed machine cannot be closed again');
select is(app.reading_detail_at(pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-09', pg_temp.ts(date '2026-03-10', '14:10')) ->> 'ok', 'true', 'the owner reads a past occurrence they owned');
select is(pg_temp.err($$ select app.reading_detail_at(pg_temp.id('m1'), pg_temp.id('day'), null, now()) $$) ->> 'field', 'shift_date', 'a date is required');
select pg_temp.as_user('s2');
select is(app.reading_detail_at(pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-10', '14:10')), '{"ok": false, "code": "not_allowed"}'::jsonb, 'another supervisor is denied');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and source = 'rpc:reading_detail' and reason = 'not_owner'), 1, 'and audited as not_owner');
select is(app.reading_detail_at(pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-17', pg_temp.ts(date '2026-03-17', '08:00')) ->> 'ok', 'true', 'the covering supervisor reads the occurrence they cover');
select pg_temp.as_user('s1');
select is(app.reading_detail_at(pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-17', pg_temp.ts(date '2026-03-17', '08:00')), '{"ok": false, "code": "not_allowed"}'::jsonb, 'and the planned owner no longer can');
select is(app.reading_detail_at(pg_temp.id('m4'), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-10', '08:00')), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a supervisor cannot read an unassigned machine');
select pg_temp.as_user('uax');
select is(app.reading_detail_at(pg_temp.id('m4'), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-10', '08:00')) ->> 'ok', 'true', 'a Unit Admin can');
select is(app.reading_detail_at(pg_temp.id('m4'), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-10', '08:00')) -> 'owner_id', 'null'::jsonb, 'with no owner');
select is((app.reading_detail_at(pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-11', '07:00')) #>> '{allowed,can_correct}')::boolean, true, 'a Unit Admin may correct at any time');
select pg_temp.as_user('uay');
select is(app.reading_detail_at(pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-10', '14:10')), '{"ok": false, "code": "not_allowed"}'::jsonb, 'another tenant''s Unit Admin is denied');
select is(app.reading_detail_at(gen_random_uuid(), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-10', '14:10')), '{"ok": false, "code": "not_allowed"}'::jsonb, 'an unknown machine too');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and source = 'rpc:reading_detail' and reason in ('cross_tenant', 'not_found')), 2, 'audited with their reasons');
select pg_temp.as_user('sa');
select is(public.reading_detail(null, null, null), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a Super Admin is denied');
select pg_temp.as_user('sfresh');
select is(public.reading_detail(pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-10'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a user with a temporary password is denied');

-- today_board (AC-12) ---------------------------------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('s1');
select is(app.today_board_at(pg_temp.ts(date '2026-03-10', '15:00')), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a supervisor is denied the board');
select pg_temp.as_user('sinact');
select is(public.today_board(), '{"ok": false, "code": "not_allowed"}'::jsonb, 'so is an inactive user');
select pg_temp.as_user('sa');
select is(public.today_board(), '{"ok": false, "code": "not_allowed"}'::jsonb, 'and a Super Admin');
select pg_temp.as_user('uax');
select is(jsonb_array_length(app.today_board_at(pg_temp.ts(date '2026-03-10', '15:00')) -> 'occurrences'), 4, 'the board shows the latest and the previous occurrence of each shift (day 10th and 9th, night 9th and 8th)');
select is(pg_temp.bo(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-10') ->> 'current', 'true', 'the latest started occurrence is the current one');
select is(pg_temp.bo(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-09') ->> 'current', 'false', 'the one before it is not');
select is(pg_temp.bo(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-10') ->> 'running', 'false', 'the day shift has ended at 15:00');
select is(pg_temp.bo(pg_temp.ts(date '2026-03-10', '10:00'), 'day', date '2026-03-10') ->> 'running', 'true', 'and is running at 10:00');
select is((select string_agg(m ->> 'code', ',' order by m ->> 'code') from jsonb_array_elements(pg_temp.bo(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-10') -> 'machines') m), 'M1,M2,M3,M5,M8',
  'assigned machines only: M4 (unassigned) and M6 (retired, no readings) are excluded; M5 (retired later, has a reading) and M7 (retired before... see next) ... are decided by the rule');
select is(pg_temp.bm(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-10', 'M7'), null, 'M7 (retired, no reading that occurrence) is not on the board');
select is(pg_temp.bm(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-10', 'M1') ->> 'opening_status' || '/' || (pg_temp.bm(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-10', 'M1') ->> 'closing_status'), 'on_time/on_time', 'M1: both readings on time');
select is(pg_temp.bm(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-10', 'M1') ->> 'attainment_pct', '24.00', 'with attainment');
select is(pg_temp.bm(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-10', 'M1') ->> 'owner_name', 'Sup One', 'the owner is named');
select is(pg_temp.bm(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-10', 'M1') -> 'flags', '[]'::jsonb, 'no flags');
select is(pg_temp.bm(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-10', 'M1') ->> 'movement_pieces' || '/' || (pg_temp.bm(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-10', 'M1') ->> 'unaccounted'), '250/5', 'movement and unaccounted are shown');
select is(pg_temp.bm(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-10', 'M2') ->> 'opening_status' || '/' || (pg_temp.bm(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-10', 'M2') ->> 'closing_status'), 'missing/missing', 'M2: both missing');
select is(pg_temp.bm(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-10', 'M2') ->> 'target' || '/' || (pg_temp.bm(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-10', 'M2') ->> 'target_assumed'), '1200/true',
  'a machine without an opening shows the target of its default product (1200 for P-1), marked as assumed');
select is(pg_temp.bm(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-10', 'M3') ->> 'opening_status', 'late', 'M3: late opening');
select is(pg_temp.bm(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-10', 'M3') -> 'flags', '["late_opening"]'::jsonb, 'flagged late_opening');
select is(pg_temp.bm(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-10', 'M3') ->> 'target' || '/' || (pg_temp.bm(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-10', 'M3') ->> 'target_assumed'), '500/false', 'its target comes from the product it opened with');
select is(pg_temp.bm(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-10', 'M5') ->> 'product_code', 'P-1', 'M5 (retired later) shows because it has a reading in the occurrence');
select is(pg_temp.bm(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-10', 'M8') ->> 'closing_status', 'missing', 'M8 has no closing');
select is(pg_temp.bm(pg_temp.ts(date '2026-03-10', '15:00'), 'night', date '2026-03-09', 'M1') -> 'flags', '["late_closing"]'::jsonb, 'the night occurrence''s late closing is flagged');
select is(pg_temp.bo(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-10') -> 'totals', jsonb_build_object('machines_expected', 5, 'openings_on_time', 2, 'closings_on_time', 1, 'both_on_time', 1,
  'target', 2700, 'target_closed', 1000, 'good', 240, 'attainment_pct', 24.00), 'totals: 5 expected, 2 openings and 1 closing on time, target 2700, closed target 1000, good 240, attainment 24.00');
select is(pg_temp.bo(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-09') #>> '{totals,machines_expected}', '4', 'the previous occurrence has its own totals (M5 is retired and has no reading that day, so 4)');
select is(pg_temp.bo(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-09') #>> '{totals,both_on_time}', '1', 'where M3 has both readings on time');
select is(pg_temp.bo(pg_temp.ts(date '2026-03-10', '15:00'), 'day', date '2026-03-09') #>> '{totals,attainment_pct}', null, 'and attainment is null when no closed machine has a target');
select is((select count(*)::int from jsonb_array_elements(app.today_board_at(pg_temp.ts(date '2026-03-10', '15:00')) -> 'occurrences') o where (o ->> 'shift_date')::date = date '2026-03-08' and (o -> 'shift' ->> 'id')::uuid = pg_temp.id('night')), 1,
  'the board looks back two occurrences per shift (the night of the 8th is the previous one)');
select pg_temp.as_user('uay');
select is(jsonb_array_length(app.today_board_at(pg_temp.ts(date '2026-03-10', '15:00')) -> 'occurrences'), 0, 'another tenant''s Unit Admin sees none of it');

-- Volume: 300 machines x 3 shifts, two occurrences each ------------------------------------------------------------------------------------------------------
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time)
select ('55000000-0000-4000-c653-0000000000d' || n)::uuid, pg_temp.id('tv'), '51000000-0000-4000-c653-00000000000d', 'V' || n, t.s, t.e from (values (1, time '00:00', time '08:00'), (2, time '08:00', time '16:00'), (3, time '16:00', time '00:00')) t(n, s, e);
insert into public.machine (id, tenant_id, site_id, code, name)
select ('53000000-0000-4000-c653-' || lpad(g::text, 12, '0'))::uuid, pg_temp.id('tv'), '51000000-0000-4000-c653-00000000000d', 'V' || g, 'Volume ' || g from generate_series(1, 300) g;
insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by)
select pg_temp.id('tv'), ('55000000-0000-4000-c653-0000000000d' || n)::uuid, ('53000000-0000-4000-c653-' || lpad(g::text, 12, '0'))::uuid, pg_temp.id('sv'), date '2026-01-01', pg_temp.id('uav')
  from generate_series(1, 3) n cross join generate_series(1, 300) g;
select pg_temp.as_user('uav');
create temp table vol as select clock_timestamp() as t0, app.today_board_at(pg_temp.ts(date '2026-03-10', '20:00')) as b, clock_timestamp() as t1;
select is((select count(*)::int from vol, jsonb_array_elements(b -> 'occurrences') o, jsonb_array_elements(o -> 'machines') m), 1800, 'volume: 300 machines x 3 shifts x 2 occurrences = 1800 board rows');
select ok((select extract(epoch from t1 - t0) < 10 from vol), 'and the board is built in well under 10 seconds (the target is 1 s on real hardware; this guards against a quadratic plan)');

-- reading_capture (AC-13, D9) ----------------------------------------------------------------------------------------------------------------------------------
select is((select expected || '/' || on_time from app.reading_capture_at(pg_temp.id('tx'), date '2026-03-09', date '2026-03-10', pg_temp.ts(date '2026-03-11', '00:00'))), '11/2',
  'capture 9th..10th at midnight: 11 assigned machine-occurrences ended (day 5 + 5, night of the 9th 1), 2 with both readings on time (M1 day 10th, M3 day 9th)');
select is((select expected from app.reading_capture_at(pg_temp.id('tx'), date '2026-03-10', date '2026-03-10', pg_temp.ts(date '2026-03-10', '10:00'))), 0::bigint, 'an occurrence that has not ended is not expected yet (and the night of the 9th is outside the range)');
select is((select expected from app.reading_capture_at(pg_temp.id('tx'), date '2026-03-10', date '2026-03-10', pg_temp.ts(date '2026-03-10', '14:00'))), 5::bigint, 'one that ends exactly at the moment is expected');
select is((select expected from app.reading_capture_at(pg_temp.id('tx'), date '2026-03-17', date '2026-03-17', pg_temp.ts(date '2026-03-18', '00:00'))), 4::bigint,
  'covers apply: on the 17th M1 (covered by S2) and M3, M5, M8 count, M2 (explicitly unassigned) does not; M4 never does; M7 (retired before) does not');
select is((select on_time from app.reading_capture_at(pg_temp.id('tx'), date '2026-03-09', date '2026-03-09', pg_temp.ts(date '2026-03-11', '00:00'))), 1::bigint, 'on time needs both readings on time: M3 yes; M1''s night closing was late and M2/M8 have no closing');
select is((select count(*)::int from app.reading_capture_at(pg_temp.id('ty'), date '2026-03-09', date '2026-03-10', now())), 1, 'another tenant is counted on its own (one result row)');
select is((select expected from app.reading_capture_at(pg_temp.id('ty'), date '2026-03-09', date '2026-03-10', now())), 0::bigint, 'with none of X''s machines');
select is(pg_temp.err($$ select * from app.reading_capture_at(pg_temp.id('tx'), date '2026-03-09', date '2026-03-08', now()) $$) ->> 'field', 'range', 'to before from is refused');
select is(pg_temp.err($$ select * from app.reading_capture_at(pg_temp.id('tx'), date '2026-01-01', date '2027-01-03', now()) $$) ->> 'field', 'range', 'a range over 367 days is refused (bounded series)');
select is(pg_temp.err($$ select * from app.reading_capture_at(pg_temp.id('tx'), null, date '2027-01-03', now()) $$) ->> 'field', 'range', 'a missing date is refused');
select lives_ok($$ select * from app.reading_capture_at(pg_temp.id('tx'), date '2026-01-01', date '2027-01-02', now()) $$, 'a range of exactly 367 days is accepted');
select is((select expected from app.reading_capture(pg_temp.id('tx'), date '2026-03-09', date '2026-03-10')), (select expected from app.reading_capture_at(pg_temp.id('tx'), date '2026-03-09', date '2026-03-10', now())), 'reading_capture is the same with now()');
select is(has_function_privilege('authenticated', 'app.reading_capture(uuid, date, date)', 'execute') or has_function_privilege('authenticated', 'app.reading_capture_at(uuid, date, date, timestamptz)', 'execute'), false, 'no client can execute the capture function');

select * from finish();
rollback;
