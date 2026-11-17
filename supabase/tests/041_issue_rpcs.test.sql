-- 07 step 2 (AC-1..AC-10, AC-15 DB part): the iss_* write RPCs. Owner resolution at report, categories, note/start/assignee/escalate/ack/reassign,
-- resolve by priority, verify eligibility (issue_can_verify, pure, explicit moments, overnight/cover/unassigned/inactive), reject/reopen, invalid
-- transitions, timestamps, audit rows, denials, idempotency, isolation. Self-contained; rolled back.
-- Clock (D10): write RPCs use now(). Tenant X has a shift R that is running now and a shift N that starts about 3.5 h from now, both built from the
-- current time, so every case is constructible at any time of day. issue_can_verify takes explicit moments and is tested on tenant Z with fixed shifts.
begin;
create extension if not exists pgtap with schema extensions;
select plan(200);

create temp table ids (k text primary key, v uuid);
create function pg_temp.id(k text) returns uuid language sql as $$ select v from ids where k = $1 $$;
create function pg_temp.as_user(k text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where ids.k = $1), 'role', 'authenticated')::text, true) $$;
grant select on ids to authenticated, anon;
-- Runs a SELECT returning jsonb as a user; a raised P0001 comes back as its detail ({code, field}) plus message/sqlstate.
create function pg_temp.rpc(u text, q text) returns jsonb language plpgsql as $f$
declare d text; m text; st text; r jsonb;
begin
  perform pg_temp.as_user(u);
  execute q into r;
  return r;
exception when others then
  get stacked diagnostics d = pg_exception_detail, m = message_text, st = returned_sqlstate;
  return coalesce(case when d ~ '^[{]' then d::jsonb end, '{}'::jsonb) || jsonb_build_object('raised', true, 'message', m, 'sqlstate', st);
end $f$;
-- rpc + remember the id of a successful call
create function pg_temp.rpck(k text, u text, q text) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  r := pg_temp.rpc(u, q);
  if (r->>'ok')::boolean then insert into ids values (k, (r->>'id')::uuid) on conflict on constraint ids_pkey do update set v = excluded.v; end if;
  return r;
end $f$;
create function pg_temp.n_audit(a text, t text) returns int language sql as $$
  select count(*)::int from public.audit_event where action = a and tenant_id = pg_temp.id(t) $$;
create function pg_temp.denied(src text, why text, t text) returns int language sql as $$
  select count(*)::int from public.audit_event where action = 'access.denied' and source = 'rpc:' || src and reason = why and tenant_id = pg_temp.id(t) $$;
create function pg_temp.iss(k text) returns public.machine_issue language sql as $$ select * from public.machine_issue where id = pg_temp.id(k) $$;
create function pg_temp.f15(t timestamp) returns text language sql as $$
  select to_char(date_trunc('hour', t) + (extract(minute from t)::int / 15) * interval '15 minutes', 'HH24:MI') $$;

-- Fixtures (as postgres) -------------------------------------------------------------------------------------------------
insert into auth.users (id, email, aud, role)
select u, 'tap41-' || n || '@example.test', 'authenticated', 'authenticated' from (values
  ('00000000-0000-4000-c710-0000000000a1'::uuid, 'uax'), ('00000000-0000-4000-c710-0000000000a2', 's1'), ('00000000-0000-4000-c710-0000000000a3', 's2'),
  ('00000000-0000-4000-c710-0000000000a4', 's3'), ('00000000-0000-4000-c710-0000000000a5', 's4'), ('00000000-0000-4000-c710-0000000000a6', 's5'),
  ('00000000-0000-4000-c710-0000000000a7', 'fresh'), ('00000000-0000-4000-c710-0000000000a8', 'uax2'),
  ('00000000-0000-4000-c710-0000000000b1', 'uay'), ('00000000-0000-4000-c710-0000000000b2', 'sy'),
  ('00000000-0000-4000-c710-0000000000d1', 'uas'), ('00000000-0000-4000-c710-0000000000d2', 'ssus'),
  ('00000000-0000-4000-c710-0000000000c1', 'nomem'), ('00000000-0000-4000-c710-0000000000f1', 'sa'),
  ('00000000-0000-4000-c710-0000000000e1', 'uaz'), ('00000000-0000-4000-c710-0000000000e2', 'z1'), ('00000000-0000-4000-c710-0000000000e3', 'z2'),
  ('00000000-0000-4000-c710-0000000000e4', 'z3'), ('00000000-0000-4000-c710-0000000000e5', 'zinact')) t(u, n);
insert into ids values ('uax', '00000000-0000-4000-c710-0000000000a1'), ('s1', '00000000-0000-4000-c710-0000000000a2'), ('s2', '00000000-0000-4000-c710-0000000000a3'),
  ('s3', '00000000-0000-4000-c710-0000000000a4'), ('s4', '00000000-0000-4000-c710-0000000000a5'), ('s5', '00000000-0000-4000-c710-0000000000a6'),
  ('fresh', '00000000-0000-4000-c710-0000000000a7'), ('uax2', '00000000-0000-4000-c710-0000000000a8'),
  ('uay', '00000000-0000-4000-c710-0000000000b1'), ('sy', '00000000-0000-4000-c710-0000000000b2'), ('uas', '00000000-0000-4000-c710-0000000000d1'),
  ('ssus', '00000000-0000-4000-c710-0000000000d2'), ('nomem', '00000000-0000-4000-c710-0000000000c1'), ('sa', '00000000-0000-4000-c710-0000000000f1'),
  ('uaz', '00000000-0000-4000-c710-0000000000e1'), ('z1', '00000000-0000-4000-c710-0000000000e2'), ('z2', '00000000-0000-4000-c710-0000000000e3'),
  ('z3', '00000000-0000-4000-c710-0000000000e4'), ('zinact', '00000000-0000-4000-c710-0000000000e5'),
  ('tx', '50000000-0000-4000-c710-00000000000a'), ('ty', '50000000-0000-4000-c710-00000000000b'), ('ts', '50000000-0000-4000-c710-00000000000d'),
  ('tz', '50000000-0000-4000-c710-00000000000e');
insert into public.tenant (id, name, status, timezone) values
  ('50000000-0000-4000-c710-00000000000a', 'tap41 org X', 'active', 'Asia/Kolkata'), ('50000000-0000-4000-c710-00000000000b', 'tap41 org Y', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c710-00000000000d', 'tap41 org S', 'suspended', 'Asia/Kolkata'), ('50000000-0000-4000-c710-00000000000e', 'tap41 org Z', 'active', 'Asia/Kolkata');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('50000000-0000-4000-c710-00000000000a', '00000000-0000-4000-c710-0000000000a1', 'unit_admin', 'active', 'UA X', 'UA-X', '+919000020711', false),
  ('50000000-0000-4000-c710-00000000000a', '00000000-0000-4000-c710-0000000000a2', 'supervisor', 'active', 'Sup One', 'S1', '+919000020712', false),
  ('50000000-0000-4000-c710-00000000000a', '00000000-0000-4000-c710-0000000000a3', 'supervisor', 'active', 'Sup Two', 'S2', '+919000020713', false),
  ('50000000-0000-4000-c710-00000000000a', '00000000-0000-4000-c710-0000000000a4', 'supervisor', 'active', 'Sup Three', 'S3', '+919000020714', false),
  ('50000000-0000-4000-c710-00000000000a', '00000000-0000-4000-c710-0000000000a5', 'supervisor', 'inactive', 'Sup Gone', 'S4', '+919000020715', false),
  ('50000000-0000-4000-c710-00000000000a', '00000000-0000-4000-c710-0000000000a6', 'supervisor', 'active', 'Sup Five', 'S5', '+919000020716', false),
  ('50000000-0000-4000-c710-00000000000a', '00000000-0000-4000-c710-0000000000a7', 'supervisor', 'active', 'Fresh', 'FR', '+919000020717', true),
  ('50000000-0000-4000-c710-00000000000a', '00000000-0000-4000-c710-0000000000a8', 'unit_admin', 'active', 'UA X2', 'UA-X2', '+919000020718', false),
  ('50000000-0000-4000-c710-00000000000b', '00000000-0000-4000-c710-0000000000b1', 'unit_admin', 'active', 'UA Y', 'UA-Y', '+919000020719', false),
  ('50000000-0000-4000-c710-00000000000b', '00000000-0000-4000-c710-0000000000b2', 'supervisor', 'active', 'Sup Y', 'SY', '+919000020720', false),
  ('50000000-0000-4000-c710-00000000000d', '00000000-0000-4000-c710-0000000000d1', 'unit_admin', 'active', 'UA S', 'UA-S', '+919000020721', false),
  ('50000000-0000-4000-c710-00000000000d', '00000000-0000-4000-c710-0000000000d2', 'supervisor', 'active', 'Sup S', 'SS', '+919000020722', false),
  ('50000000-0000-4000-c710-00000000000e', '00000000-0000-4000-c710-0000000000e1', 'unit_admin', 'active', 'UA Z', 'UA-Z', '+919000020723', false),
  ('50000000-0000-4000-c710-00000000000e', '00000000-0000-4000-c710-0000000000e2', 'supervisor', 'active', 'Z One', 'Z1', '+919000020724', false),
  ('50000000-0000-4000-c710-00000000000e', '00000000-0000-4000-c710-0000000000e3', 'supervisor', 'active', 'Z Two', 'Z2', '+919000020725', false),
  ('50000000-0000-4000-c710-00000000000e', '00000000-0000-4000-c710-0000000000e4', 'supervisor', 'active', 'Z Three', 'Z3', '+919000020726', false),
  ('50000000-0000-4000-c710-00000000000e', '00000000-0000-4000-c710-0000000000e5', 'supervisor', 'inactive', 'Z Gone', 'Z4', '+919000020727', false);
insert into public.platform_admin (user_id, full_name, phone_e164, status, must_change_password) values ('00000000-0000-4000-c710-0000000000f1', 'SA 41', '+919000020728', 'active', false);
insert into public.site (id, tenant_id, name, timezone) values
  ('51000000-0000-4000-c710-00000000000a', pg_temp.id('tx'), 'Plant X', 'Asia/Kolkata'), ('51000000-0000-4000-c710-00000000000b', pg_temp.id('ty'), 'Plant Y', 'Asia/Kolkata'),
  ('51000000-0000-4000-c710-00000000000d', pg_temp.id('ts'), 'Plant S', 'Asia/Kolkata'), ('51000000-0000-4000-c710-00000000000e', pg_temp.id('tz'), 'Plant Z', 'Asia/Kolkata');
insert into public.machine (id, tenant_id, site_id, code, name, retired_at) values
  ('53000000-0000-4000-c710-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c710-00000000000a', 'M-A', 'Press A', null),
  ('53000000-0000-4000-c710-0000000000a2', pg_temp.id('tx'), '51000000-0000-4000-c710-00000000000a', 'M-B', 'Press B', null),
  ('53000000-0000-4000-c710-0000000000a3', pg_temp.id('tx'), '51000000-0000-4000-c710-00000000000a', 'M-C', 'Press C', null),
  ('53000000-0000-4000-c710-0000000000a4', pg_temp.id('tx'), '51000000-0000-4000-c710-00000000000a', 'M-D', 'Retired press', now()),
  ('53000000-0000-4000-c710-0000000000a5', pg_temp.id('tx'), '51000000-0000-4000-c710-00000000000a', 'M-E', 'Press E (never assigned)', null),
  ('53000000-0000-4000-c710-0000000000b1', pg_temp.id('ty'), '51000000-0000-4000-c710-00000000000b', 'Y-1', 'Y press', null),
  ('53000000-0000-4000-c710-0000000000e1', pg_temp.id('tz'), '51000000-0000-4000-c710-00000000000e', 'Z-A', 'Z press A', null),
  ('53000000-0000-4000-c710-0000000000e2', pg_temp.id('tz'), '51000000-0000-4000-c710-00000000000e', 'Z-B', 'Z press B', null),
  ('53000000-0000-4000-c710-0000000000e3', pg_temp.id('tz'), '51000000-0000-4000-c710-00000000000e', 'Z-C', 'Z press C', null),
  ('53000000-0000-4000-c710-0000000000e4', pg_temp.id('tz'), '51000000-0000-4000-c710-00000000000e', 'Z-D', 'Z press D', null);
insert into ids values ('mA', '53000000-0000-4000-c710-0000000000a1'), ('mB', '53000000-0000-4000-c710-0000000000a2'), ('mC', '53000000-0000-4000-c710-0000000000a3'),
  ('mD', '53000000-0000-4000-c710-0000000000a4'), ('mE', '53000000-0000-4000-c710-0000000000a5'), ('my', '53000000-0000-4000-c710-0000000000b1'),
  ('zA', '53000000-0000-4000-c710-0000000000e1'), ('zB', '53000000-0000-4000-c710-0000000000e2'), ('zC', '53000000-0000-4000-c710-0000000000e3'), ('zD', '53000000-0000-4000-c710-0000000000e4');
-- Tenant X shifts: R runs now (starts 90-105 min ago, ends 90-120 min ahead), N starts 3.25-3.5 h from now (never running now).
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time)
select * from (select '54000000-0000-4000-c710-0000000000a1'::uuid, pg_temp.id('tx'), '51000000-0000-4000-c710-00000000000a'::uuid, 'R running',
  pg_temp.f15(l - interval '90 minutes')::time, (pg_temp.f15(l + interval '90 minutes')::time + interval '15 minutes')::time
  from (select now() at time zone 'Asia/Kolkata' as l) q
  union all select '54000000-0000-4000-c710-0000000000a2'::uuid, pg_temp.id('tx'), '51000000-0000-4000-c710-00000000000a'::uuid, 'N next',
  pg_temp.f15(l + interval '210 minutes')::time, (pg_temp.f15(l + interval '210 minutes')::time + interval '3 hours')::time
  from (select now() at time zone 'Asia/Kolkata' as l) q) x;
insert into ids values ('R', '54000000-0000-4000-c710-0000000000a1'), ('N', '54000000-0000-4000-c710-0000000000a2');
-- Tenant X plan: R: A -> s1, B -> s2, C -> s4 (inactive); N: A -> s2, C -> s3.   (E and D are never assigned)
insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by)
select pg_temp.id('tx'), pg_temp.id(sh), pg_temp.id(m), pg_temp.id(sup), app.plant_date(pg_temp.id('tx')) - 30, pg_temp.id('uax')
from (values ('R', 'mA', 's1'), ('R', 'mB', 's2'), ('R', 'mC', 's4'), ('N', 'mA', 's2'), ('N', 'mC', 's3')) v(sh, m, sup);
-- Tenant Z: fixed shifts Day 06:00-14:00, Night 22:00-06:00, Old (retired) 00:00-23:45
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time, retired_at) values
  ('54000000-0000-4000-c710-0000000000e1', pg_temp.id('tz'), '51000000-0000-4000-c710-00000000000e', 'Day', '06:00', '14:00', null),
  ('54000000-0000-4000-c710-0000000000e2', pg_temp.id('tz'), '51000000-0000-4000-c710-00000000000e', 'Night', '22:00', '06:00', null),
  ('54000000-0000-4000-c710-0000000000e3', pg_temp.id('tz'), '51000000-0000-4000-c710-00000000000e', 'Old', '00:00', '23:45', now());
insert into ids values ('Day', '54000000-0000-4000-c710-0000000000e1'), ('Night', '54000000-0000-4000-c710-0000000000e2'), ('Old', '54000000-0000-4000-c710-0000000000e3');
-- Z plan: A: Day z1, Night z2; B: Day z1; C: Old -> z3 (retired shift); D: Day -> zinact (inactive)
insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by)
select pg_temp.id('tz'), pg_temp.id(sh), pg_temp.id(m), pg_temp.id(sup), app.plant_date(pg_temp.id('tz')) - 30, pg_temp.id('uaz')
from (values ('Day', 'zA', 'z1'), ('Night', 'zA', 'z2'), ('Day', 'zB', 'z1'), ('Old', 'zC', 'z3'), ('Day', 'zD', 'zinact')) v(sh, m, sup);
create temp table today as select app.plant_date(pg_temp.id('tz')) as d;
grant select on today to authenticated, anon;
create function pg_temp.at(off int, t text) returns timestamptz language sql as $$ select ((select d + $1 from today) + $2::time) at time zone 'Asia/Kolkata' $$;
-- Z issues, written directly as the table owner (resolved at explicit moments)
create function pg_temp.zissue(k text, mach text, prio text, st text, resolver text, res_at timestamptz) returns void language plpgsql as $$
declare v uuid;
begin
  insert into public.machine_issue (tenant_id, machine_id, category_id, priority, description, reported_by, accountable_owner_id, status, resolved_by, resolved_at, resolution_notes, closed_at, reported_at)
  values (pg_temp.id('tz'), pg_temp.id(mach), (select c.id from public.issue_category c where c.tenant_id = pg_temp.id('tz') and name = 'Mechanical'), prio, 'z issue ' || k,
          pg_temp.id('z3'), pg_temp.id('z3'), st, case when st in ('resolved', 'closed') then pg_temp.id(resolver) end, res_at, case when res_at is not null then 'fixed' end,
          case when st = 'closed' then res_at end, coalesce(res_at, now()) - interval '1 day')
  returning id into v;
  insert into ids values (k, v);
end $$;
insert into ids select 'catx', id from public.issue_category where tenant_id = pg_temp.id('tx') and name = 'Mechanical';
insert into ids select 'caty', id from public.issue_category where tenant_id = pg_temp.id('ty') and name = 'Mechanical';
insert into ids select 'catx2', id from public.issue_category where tenant_id = pg_temp.id('tx') and name = 'Electrical';

-- Preconditions: R is running, N is not ---------------------------------------------------------------------------------------
select pg_temp.as_user('uax');
select is((select count(*)::int from app.current_occurrences(now()) where shift_id = pg_temp.id('R')), 1, 'fixture: R is running now');
select is((select count(*)::int from app.current_occurrences(now()) where shift_id = pg_temp.id('N')), 0, 'fixture: N is not running now');
select is(app.machine_owner_now(pg_temp.id('mA')), pg_temp.id('s1'), 'machine_owner_now: s1 owns A in R');
select is(app.machine_owner_now(pg_temp.id('mC')), null, 'machine_owner_now: an inactive supervisor counts as nobody');
select is(app.machine_owner_now(pg_temp.id('mE')), null, 'machine_owner_now: an unassigned machine has no owner');

-- Report: owner resolution (AC-2) -------------------------------------------------------------------------------------------------
select is(pg_temp.rpck('iA1', 's1', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'medium', '  Oil leak  ', false)$q$, pg_temp.id('mA'), pg_temp.id('catx')))->>'ok', 'true', 'a supervisor reports on the machine they own');
select is((pg_temp.iss('iA1')).accountable_owner_id, pg_temp.id('s1'), 'AC-2: the owner-reporter is accountable');
select is((pg_temp.iss('iA1')).description, 'Oil leak', 'the description is trimmed');
select is((pg_temp.iss('iA1')).status, 'open', 'a new issue is Open');
select is((pg_temp.iss('iA1')).reported_shift_id, pg_temp.id('R'), 'the running shift is recorded');
select is((select count(*)::int from public.issue_ownership_history where issue_id = pg_temp.id('iA1') and source = 'report' and new_owner = pg_temp.id('s1') and previous_owner is null), 1, 'an ownership-history row records it (source report)');
select is((select string_agg(type, ',' order by at) from public.issue_action where issue_id = pg_temp.id('iA1')), 'report', 'the first action is the report');
select is(pg_temp.rpck('iA2', 's2', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'low', 'Noise', false)$q$, pg_temp.id('mA'), pg_temp.id('catx')))->>'ok', 'true', 'a supervisor reports on a machine they do not own');
select is((pg_temp.iss('iA2')).accountable_owner_id, pg_temp.id('s1'), 'AC-2: the machine''s owner now becomes accountable');
select is((pg_temp.iss('iA2')).reported_by, pg_temp.id('s2'), 'and the reporter is recorded');
select is(pg_temp.rpck('iE1', 's2', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'low', 'Guard loose', false)$q$, pg_temp.id('mE'), pg_temp.id('catx')))->>'ok', 'true', 'report on an unassigned machine');
select is((pg_temp.iss('iE1')).accountable_owner_id, pg_temp.id('s2'), 'AC-2: unassigned machine, supervisor reporter -> the reporter');
select is(pg_temp.rpck('iC1', 's2', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'low', 'Heater', false)$q$, pg_temp.id('mC'), pg_temp.id('catx')))->>'ok', 'true', 'report on a machine whose owner is inactive');
select is((pg_temp.iss('iC1')).accountable_owner_id, pg_temp.id('s2'), 'AC-2: an inactive owner counts as nobody -> the reporter');
select is(pg_temp.rpck('iA3', 'uax', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'high', 'Vibration', false)$q$, pg_temp.id('mA'), pg_temp.id('catx')))->>'ok', 'true', 'a Unit Admin reports');
select is((pg_temp.iss('iA3')).accountable_owner_id, pg_temp.id('s1'), 'AC-2: a Unit Admin''s issue goes to the machine''s owner now');
select is(pg_temp.rpck('iE2', 'uax', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'high', 'Needs a owner', false)$q$, pg_temp.id('mE')	, pg_temp.id('catx')))->>'ok', 'true', 'a Unit Admin reports on an unassigned machine');
select is((pg_temp.iss('iE2')).accountable_owner_id, null, 'AC-2: UA + unassigned -> "Needs owner" (null)');
select is((select count(*)::int from public.issue_ownership_history where issue_id = pg_temp.id('iE2') and new_owner is null and source = 'report'), 1, 'and the ownership row says so');

-- Stopped machine forces Critical (AC-1) ---------------------------------------------------------------------------------------
select is(pg_temp.rpck('iS1', 's1', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'low', 'Press stopped', true)$q$, pg_temp.id('mA'), pg_temp.id('catx')))->>'priority', 'critical', 'machine stopped forces Critical (low sent)');
select is((pg_temp.iss('iS1')).priority, 'critical', 'and it is stored Critical');
select is(pg_temp.rpc('s1', format($q$select public.iss_report(gen_random_uuid(), %L, %L, null, 'Stopped, no priority', true)$q$, pg_temp.id('mA'), pg_temp.id('catx')))->>'priority', 'critical', 'stopped needs no priority');
select is(pg_temp.rpc('s1', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'low', 'x', null)$q$, pg_temp.id('mA'), pg_temp.id('catx')))->>'field', 'machine_stopped', 'the stopped answer is required');

-- Report validation, guards, denials -------------------------------------------------------------------------------------------
select is(pg_temp.rpc('s1', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'urgent', 'x', false)$q$, pg_temp.id('mA'), pg_temp.id('catx')))->>'field', 'priority', 'validation: priority');
select is(pg_temp.rpc('s1', format($q$select public.iss_report(gen_random_uuid(), %L, %L, null, 'x', false)$q$, pg_temp.id('mA'), pg_temp.id('catx')))->>'field', 'priority', 'validation: priority required when not stopped');
select is(pg_temp.rpc('s1', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'low', '   ', false)$q$, pg_temp.id('mA'), pg_temp.id('catx')))->>'field', 'description', 'validation: empty description');
select is(pg_temp.rpc('s1', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'low', %L, false)$q$, pg_temp.id('mA'), pg_temp.id('catx'), repeat('x', 1001)))->>'field', 'description', 'validation: description over 1000');
select is(pg_temp.rpc('s1', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'low', %L, false)$q$, pg_temp.id('mA'), pg_temp.id('catx'), repeat('x', 1000)))->>'ok', 'true', '1000 characters are fine');
select is(pg_temp.rpc('s1', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'low', 'x', false)$q$, pg_temp.id('mD'), pg_temp.id('catx')))->>'field', 'machine_id', 'guard: a retired machine');
select is(pg_temp.rpc('s1', format($q$select public.iss_report(null, %L, %L, 'low', 'x', false)$q$, pg_temp.id('mA'), pg_temp.id('catx')))->>'field', 'request_id', 'a request id is required');
select is(pg_temp.rpc('s1', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'low', 'x', false)$q$, pg_temp.id('my'), pg_temp.id('catx')))->>'code', 'not_allowed', 'another tenant''s machine: generic denial');
select is(pg_temp.denied('iss_report', 'cross_tenant', 'tx'), 1, 'and the denial is audited (cross_tenant)');
select is(pg_temp.rpc('s1', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'low', 'x', false)$q$, pg_temp.id('mA'), pg_temp.id('caty')))->>'code', 'not_allowed', 'another tenant''s category: generic denial');
select is(pg_temp.rpc('s1', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'low', 'x', false)$q$, gen_random_uuid(), pg_temp.id('catx')))->>'code', 'not_allowed', 'an unknown machine: the same denial');
select is(pg_temp.rpc('fresh', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'low', 'x', false)$q$, pg_temp.id('mA'), pg_temp.id('catx')))->>'code', 'not_allowed', 'a user with a temporary password is denied');
select is(pg_temp.denied('iss_report', 'must_change_password', 'tx'), 1, 'audited as must_change_password');
select is(pg_temp.rpc('ssus', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'low', 'x', false)$q$, pg_temp.id('mA'), pg_temp.id('catx')))->>'code', 'not_allowed', 'a suspended tenant is denied');
select is(pg_temp.rpc('sa', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'low', 'x', false)$q$, pg_temp.id('mA'), pg_temp.id('catx')))->>'code', 'not_allowed', 'a Super Admin is denied');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and source = 'rpc:iss_report' and actor_role = 'platform_admin' and reason = 'platform_admin'), 1, 'and audited as a platform event');
select is(pg_temp.rpc('nomem', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'low', 'x', false)$q$, pg_temp.id('mA'), pg_temp.id('catx')))->>'code', 'not_allowed', 'a stranger is denied');
select is(pg_temp.rpc('s4', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'low', 'x', false)$q$, pg_temp.id('mA'), pg_temp.id('catx')))->>'code', 'not_allowed', 'an inactive supervisor is denied');

-- Report idempotency and request-id tie ------------------------------------------------------------------------------------------
select set_config('t.req', gen_random_uuid()::text, true);
select is(pg_temp.rpck('iR1', 's1', format($q$select public.iss_report(%L, %L, %L, 'low', 'Replay me', false)$q$, current_setting('t.req'), pg_temp.id('mA'), pg_temp.id('catx')))->>'ok', 'true', 'first call');
select is(pg_temp.rpc('s1', format($q$select public.iss_report(%L, %L, %L, 'low', 'Replay me', false)$q$, current_setting('t.req'), pg_temp.id('mA'), pg_temp.id('catx')))->>'id', pg_temp.id('iR1')::text, 'a replay returns the first outcome');
select is((select count(*)::int from public.machine_issue where description = 'Replay me'), 1, 'and creates nothing');
select is(pg_temp.rpc('s1', format($q$select public.iss_note(%L, %L, 'reuse')$q$, current_setting('t.req'), pg_temp.id('iR1')))->>'field', 'request_id', 'the same id on another RPC is a validation error');

-- Notes, start, assignee (AC-4) ---------------------------------------------------------------------------------------------------
select is(pg_temp.rpc('s2', format($q$select public.iss_note(gen_random_uuid(), %L, 'Seems worse')$q$, pg_temp.id('iA2')))->>'ok', 'true', 'the reporter can add a note');
select is(pg_temp.rpc('s1', format($q$select public.iss_note(gen_random_uuid(), %L, 'On it')$q$, pg_temp.id('iA2')))->>'ok', 'true', 'the accountable owner can add a note');
select is(pg_temp.rpc('uax', format($q$select public.iss_note(gen_random_uuid(), %L, 'Admin note')$q$, pg_temp.id('iA2')))->>'ok', 'true', 'a Unit Admin can add a note');
select is(pg_temp.rpc('s5', format($q$select public.iss_note(gen_random_uuid(), %L, 'drive-by')$q$, pg_temp.id('iA2')))->>'code', 'not_allowed', 'a supervisor who cannot see the issue is denied');
select is(pg_temp.denied('iss_note', 'not_visible', 'tx'), 1, 'audited as not_visible');
select is(pg_temp.rpc('s1', format($q$select public.iss_note(gen_random_uuid(), %L, '')$q$, pg_temp.id('iA2')))->>'field', 'notes', 'validation: empty note');
select is(pg_temp.rpc('uay', format($q$select public.iss_note(gen_random_uuid(), %L, 'cross')$q$, pg_temp.id('iA2')))->>'code', 'not_allowed', 'another tenant''s Unit Admin is denied');
select is(pg_temp.denied('iss_note', 'cross_tenant', 'ty'), 1, 'audited under the caller''s tenant');
select is((select count(*)::int from public.issue_action where issue_id = pg_temp.id('iA2') and type = 'note'), 3, 'three notes were appended');
select is(pg_temp.rpc('s2', format($q$select public.iss_start(gen_random_uuid(), %L)$q$, pg_temp.id('iA2')))->>'code', 'not_allowed', 'the reporter who is not the owner cannot start work');
select is(pg_temp.denied('iss_start', 'not_owner', 'tx'), 1, 'audited as not_owner');
select set_config('t.req', gen_random_uuid()::text, true);
select is(pg_temp.rpc('s1', format($q$select public.iss_start(%L, %L)$q$, current_setting('t.req'), pg_temp.id('iA2')))->>'ok', 'true', 'the owner starts work');
select is((pg_temp.iss('iA2')).status, 'in_progress', 'Open -> In progress');
select is(pg_temp.rpc('s1', format($q$select public.iss_start(%L, %L)$q$, current_setting('t.req'), pg_temp.id('iA2')))->>'already', 'true', 'a replayed start is a no-op');
select is(pg_temp.rpc('s1', format($q$select public.iss_start(gen_random_uuid(), %L)$q$, pg_temp.id('iA2')))->>'field', 'invalid_status', 'guard: only an open issue can be started');
select is(pg_temp.rpc('uax', format($q$select public.iss_start(gen_random_uuid(), %L)$q$, pg_temp.id('iA3')))->>'ok', 'true', 'a Unit Admin can start work');
select is(pg_temp.rpc('s1', format($q$select public.iss_set_assignee(gen_random_uuid(), %L, 'Maintenance - Ravi')$q$, pg_temp.id('iA2')))->>'ok', 'true', 'the owner sets the technical assignee');
select is((pg_temp.iss('iA2')).technical_assignee, 'Maintenance - Ravi', 'and it is stored');
select is(pg_temp.rpc('s1', format($q$select public.iss_set_assignee(gen_random_uuid(), %L, %L)$q$, pg_temp.id('iA2'), repeat('x', 81)))->>'field', 'assignee', 'validation: assignee over 80');
select is(pg_temp.rpc('s2', format($q$select public.iss_set_assignee(gen_random_uuid(), %L, 'Vendor')$q$, pg_temp.id('iA2')))->>'code', 'not_allowed', 'a non-owner cannot set the assignee');

-- Escalate / acknowledge / reassign (AC-5, AC-6) -----------------------------------------------------------------------------------------
select is(pg_temp.rpc('uax', format($q$select public.iss_escalate(gen_random_uuid(), %L, 'x')$q$, pg_temp.id('iA2')))->>'code', 'not_allowed', 'only the accountable owner escalates (not a UA)');
select is(pg_temp.rpc('s2', format($q$select public.iss_escalate(gen_random_uuid(), %L, 'x')$q$, pg_temp.id('iA2')))->>'code', 'not_allowed', 'nor a non-owner supervisor');
select is(pg_temp.rpc('s1', format($q$select public.iss_escalate(gen_random_uuid(), %L, '')$q$, pg_temp.id('iA2')))->>'field', 'reason', 'validation: a reason is required');
select is(pg_temp.rpc('s1', format($q$select public.iss_escalate(gen_random_uuid(), %L, 'Need a vendor')$q$, pg_temp.id('iA2')))->>'ok', 'true', 'the owner escalates');
select ok((pg_temp.iss('iA2')).escalated_at is not null and (pg_temp.iss('iA2')).accountable_owner_id = pg_temp.id('s1'), 'flagged Escalated, owner unchanged');
select is(pg_temp.rpc('s1', format($q$select public.iss_escalate(gen_random_uuid(), %L, 'again')$q$, pg_temp.id('iA2')))->>'field', 'already_escalated', 'guard: already escalated');
select is(pg_temp.rpc('s1', format($q$select public.iss_ack_escalation(gen_random_uuid(), %L, 'seen')$q$, pg_temp.id('iA2')))->>'code', 'not_allowed', 'a supervisor cannot acknowledge');
select is(pg_temp.denied('iss_ack_escalation', 'role', 'tx'), 1, 'audited as role');
select is(pg_temp.rpc('uax', format($q$select public.iss_ack_escalation(gen_random_uuid(), %L, '')$q$, pg_temp.id('iA2')))->>'field', 'note', 'validation: a note is required');
select is(pg_temp.rpc('uax', format($q$select public.iss_ack_escalation(gen_random_uuid(), %L, 'Vendor called')$q$, pg_temp.id('iA2')))->>'ok', 'true', 'a Unit Admin acknowledges');
select is((pg_temp.iss('iA2')).escalated_at, null, 'the flag is cleared');
select is(pg_temp.rpc('uax', format($q$select public.iss_ack_escalation(gen_random_uuid(), %L, 'again')$q$, pg_temp.id('iA2')))->>'field', 'not_escalated', 'guard: not escalated');
select is(pg_temp.rpc('s1', format($q$select public.iss_escalate(gen_random_uuid(), %L, 'Still broken')$q$, pg_temp.id('iA2')))->>'ok', 'true', 'it can be escalated again after an acknowledgement');
select is(pg_temp.rpc('s1', format($q$select public.iss_reassign(gen_random_uuid(), %L, %L, 'x')$q$, pg_temp.id('iA2'), pg_temp.id('s2')))->>'code', 'not_allowed', 'a supervisor cannot reassign');
select is(pg_temp.rpc('uax', format($q$select public.iss_reassign(gen_random_uuid(), %L, %L, 'Better placed')$q$, pg_temp.id('iA2'), pg_temp.id('s2')))->>'ok', 'true', 'a Unit Admin reassigns');
select ok((pg_temp.iss('iA2')).accountable_owner_id = pg_temp.id('s2') and (pg_temp.iss('iA2')).escalated_at is null, 'the owner changed and the escalation is cleared');
select is((select count(*)::int from public.issue_ownership_history where issue_id = pg_temp.id('iA2') and source = 'reassign' and previous_owner = pg_temp.id('s1') and new_owner = pg_temp.id('s2') and reason = 'Better placed'), 1, 'ownership history: reassign with previous owner and reason');
select is(pg_temp.rpc('uax', format($q$select public.iss_reassign(gen_random_uuid(), %L, %L, 'x')$q$, pg_temp.id('iA2'), pg_temp.id('s2')))->>'field', 'same_owner', 'guard: same owner');
select is(pg_temp.rpc('uax', format($q$select public.iss_reassign(gen_random_uuid(), %L, %L, 'x')$q$, pg_temp.id('iA2'), pg_temp.id('s4')))->>'field', 'supervisor', 'validation: an inactive supervisor');
select is(pg_temp.rpc('uax', format($q$select public.iss_reassign(gen_random_uuid(), %L, %L, 'x')$q$, pg_temp.id('iA2'), pg_temp.id('uax2')))->>'field', 'supervisor', 'validation: a Unit Admin is not a valid owner');
select is(pg_temp.rpc('uax', format($q$select public.iss_reassign(gen_random_uuid(), %L, %L, 'x')$q$, pg_temp.id('iA2'), pg_temp.id('fresh')))->>'field', 'supervisor', 'validation: a supervisor with a temporary password');
select is(pg_temp.rpc('uax', format($q$select public.iss_reassign(gen_random_uuid(), %L, %L, 'x')$q$, pg_temp.id('iA2'), pg_temp.id('sy')))->>'code', 'not_allowed', 'another tenant''s supervisor: generic denial');
select is(pg_temp.rpc('uax', format($q$select public.iss_reassign(gen_random_uuid(), %L, %L, '')$q$, pg_temp.id('iA2'), pg_temp.id('s3')))->>'field', 'reason', 'validation: a reason is required');

-- Resolve by priority (AC-7) -----------------------------------------------------------------------------------------------------------
select is(pg_temp.rpc('s1', format($q$select public.iss_resolve(gen_random_uuid(), %L, 'x')$q$, pg_temp.id('iA2')))->>'code', 'not_allowed', 'a former owner cannot resolve');
select is(pg_temp.rpc('s2', format($q$select public.iss_resolve(gen_random_uuid(), %L, '')$q$, pg_temp.id('iA2')))->>'field', 'notes', 'validation: resolution notes are required');
select is(pg_temp.rpc('s2', format($q$select public.iss_resolve(gen_random_uuid(), %L, 'Seal replaced')$q$, pg_temp.id('iA2')))->>'status', 'closed', 'Low: resolving closes the issue');
select ok((pg_temp.iss('iA2')).closed_at is not null and (pg_temp.iss('iA2')).resolved_at is not null and (pg_temp.iss('iA2')).closed_by = pg_temp.id('s2') and (pg_temp.iss('iA2')).resolution_notes = 'Seal replaced', 'closed_at, resolved_at, closed_by and the notes are set');
select ok((pg_temp.iss('iA2')).closed_at - (pg_temp.iss('iA2')).reported_at >= interval '0', 'AC-10: resolution time (closed_at - reported_at) is computable');
select is(pg_temp.rpc('s2', format($q$select public.iss_resolve(gen_random_uuid(), %L, 'again')$q$, pg_temp.id('iA2')))->>'field', 'invalid_status', 'guard: a closed issue cannot be resolved');
select is(pg_temp.rpc('s1', format($q$select public.iss_start(gen_random_uuid(), %L)$q$, pg_temp.id('iA2')))->>'code', 'not_allowed', 'guard order: a non-owner is denied first');
select is(pg_temp.rpc('uax', format($q$select public.iss_set_assignee(gen_random_uuid(), %L, 'late')$q$, pg_temp.id('iA2')))->>'field', 'invalid_status', 'guard: no assignee on a closed issue');
select is(pg_temp.rpc('uax', format($q$select public.iss_reassign(gen_random_uuid(), %L, %L, 'late')$q$, pg_temp.id('iA2'), pg_temp.id('s3')))->>'field', 'invalid_status', 'guard: no reassignment of a closed issue');
select is(pg_temp.rpc('uax', format($q$select public.iss_note(gen_random_uuid(), %L, 'After close')$q$, pg_temp.id('iA2')))->>'ok', 'true', 'a note can still be added to a closed issue');
select is(pg_temp.rpc('s1', format($q$select public.iss_resolve(gen_random_uuid(), %L, 'Replaced bearings')$q$, pg_temp.id('iA3')))->>'status', 'resolved', 'High: resolving waits for verification');
select ok((pg_temp.iss('iA3')).closed_at is null and (pg_temp.iss('iA3')).resolved_by = pg_temp.id('s1') and (pg_temp.iss('iA3')).resolved_shift_id = pg_temp.id('R')
  and (pg_temp.iss('iA3')).resolved_shift_date is not null, 'resolver, time and the running occurrence are recorded; not closed');
select is(pg_temp.rpc('uax', format($q$select public.iss_resolve(gen_random_uuid(), %L, 'Fixed by admin')$q$, pg_temp.id('iS1')))->>'status', 'resolved', 'Critical (stopped machine): a Unit Admin resolves, awaiting verification');
select is(pg_temp.rpc('s1', format($q$select public.iss_start(gen_random_uuid(), %L)$q$, pg_temp.id('iA3')))->>'field', 'invalid_status', 'guard: a resolved issue cannot be started');
select is(pg_temp.rpc('s1', format($q$select public.iss_escalate(gen_random_uuid(), %L, 'x')$q$, pg_temp.id('iA3')))->>'field', 'invalid_status', 'guard: a resolved issue cannot be escalated');

-- Verify through the RPC (AC-8): states written directly with resolve times in the past ----------------------------------------------------------
-- vA: High on A (R owner s1; N owner s2), resolved by s3 5 h ago, accountable s1.  vB: High on B (R owner s2), resolved by s3, accountable s1.
-- vC: Critical on A resolved by s1 (the owner) 5 h ago.  vE: High on E (never assigned) resolved by s2.  vL: Low (closed).
create function pg_temp.xissue(k text, mach text, prio text, resolver text, owner text, res_at timestamptz) returns void language plpgsql as $$
declare v uuid;
begin
  insert into public.machine_issue (tenant_id, machine_id, category_id, priority, description, reported_by, accountable_owner_id, status, resolved_by, resolved_at, resolution_notes, reported_at)
  values (pg_temp.id('tx'), pg_temp.id(mach), pg_temp.id('catx'), prio, 'x issue ' || k, pg_temp.id(owner), pg_temp.id(owner), 'resolved', pg_temp.id(resolver), res_at, 'fixed', res_at - interval '1 day')
  returning id into v;
  insert into ids values (k, v);
end $$;
select pg_temp.xissue('vA', 'mA', 'high', 's3', 's1', now() - interval '5 hours');
select pg_temp.xissue('vB', 'mB', 'high', 's3', 's1', now() - interval '5 hours');
select pg_temp.xissue('vC', 'mA', 'critical', 's1', 's1', now() - interval '5 hours');
select pg_temp.xissue('vE', 'mE', 'high', 's2', 's2', now() - interval '5 hours');
select pg_temp.xissue('vF', 'mA', 'high', 's3', 's1', now() - interval '5 hours');
select pg_temp.xissue('vG', 'mB', 'high', 's3', 's1', now() - interval '30 minutes');

select is(pg_temp.rpc('s3', format($q$select public.iss_verify(gen_random_uuid(), %L, true)$q$, pg_temp.id('vA')))->>'code', 'not_allowed', 'the resolver cannot verify');
select is(pg_temp.denied('iss_verify', 'not_verifier', 'tx'), 1, 'audited as not_verifier');
select is(pg_temp.rpc('s1', format($q$select public.iss_verify(gen_random_uuid(), %L, true)$q$, pg_temp.id('vC')))->>'code', 'not_allowed', 'the resolver cannot verify even when they also own the next shift');
select is(pg_temp.rpc('s5', format($q$select public.iss_verify(gen_random_uuid(), %L, true)$q$, pg_temp.id('vA')))->>'code', 'not_allowed', 'a supervisor who owns nothing is denied');
select is(pg_temp.rpc('s2', format($q$select public.iss_verify(gen_random_uuid(), %L, true)$q$, pg_temp.id('vA')))->>'code', 'not_allowed', 'a supervisor whose shift has not started yet is denied (N is later)');
select is(pg_temp.rpc('uax', format($q$select public.iss_verify(gen_random_uuid(), %L, true)$q$, pg_temp.id('vA')))->>'code', 'not_allowed', 'a Unit Admin is denied while a later-shift supervisor is assigned');
select is(pg_temp.rpc('s1', format($q$select public.iss_verify(gen_random_uuid(), %L, null)$q$, pg_temp.id('vA')))->>'field', 'confirm', 'validation: confirm or reject');
select is(pg_temp.rpc('s1', format($q$select public.iss_verify(gen_random_uuid(), %L, false, '')$q$, pg_temp.id('vA')))->>'field', 'reason', 'validation: rejecting needs a reason');
select is(pg_temp.rpc('s1', format($q$select public.iss_verify(gen_random_uuid(), %L, true)$q$, pg_temp.id('vA')))->>'status', 'closed', 'the later-shift owner (s1 in R, started after the resolve) confirms -> Closed');
select ok((pg_temp.iss('vA')).closed_at is not null and (pg_temp.iss('vA')).closed_by = pg_temp.id('s1'), 'closed_at and closed_by are set (closed = verified)');
select is((select count(*)::int from public.issue_action where issue_id = pg_temp.id('vA') and type = 'verify_confirm' and status_before = 'resolved' and status_after = 'closed'), 1, 'a verify_confirm action is appended');
select is(pg_temp.rpc('s1', format($q$select public.iss_verify(gen_random_uuid(), %L, true)$q$, pg_temp.id('vA')))->>'field', 'invalid_status', 'guard: not awaiting verification any more');
-- reject: s2 owns B in R (started after the resolve); accountable owner was s1
select is(pg_temp.rpc('s2', format($q$select public.iss_verify(gen_random_uuid(), %L, false, 'Still leaking')$q$, pg_temp.id('vB')))->>'status', 'in_progress', 'reject -> In progress');
select is((pg_temp.iss('vB')).accountable_owner_id, pg_temp.id('s2'), 'the rejecting supervisor becomes accountable');
select is((select count(*)::int from public.issue_ownership_history where issue_id = pg_temp.id('vB') and source = 'verification_rejected' and previous_owner = pg_temp.id('s1') and new_owner = pg_temp.id('s2') and reason = 'Still leaking'), 1, 'ownership history: verification_rejected');
select ok((pg_temp.iss('vB')).closed_at is null, 'not closed');
-- a rejected issue can be resolved again, then verified by a later owner
select is(pg_temp.rpc('s2', format($q$select public.iss_resolve(gen_random_uuid(), %L, 'Second fix')$q$, pg_temp.id('vB')))->>'status', 'resolved', 'it can be resolved again');
select is(pg_temp.rpc('s2', format($q$select public.iss_verify(gen_random_uuid(), %L, true)$q$, pg_temp.id('vB')))->>'code', 'not_allowed', 'the new resolver cannot verify it');
-- a verifier whose occurrence started BEFORE the resolve (vG resolved 30 minutes ago; R started 90+ minutes ago) is refused: same/earlier occurrence
select is(pg_temp.rpc('s2', format($q$select public.iss_verify(gen_random_uuid(), %L, true)$q$, pg_temp.id('vG')))->>'code', 'not_allowed', 'an occurrence that started before the resolve does not qualify');
select is(pg_temp.rpc('uax', format($q$select public.iss_verify(gen_random_uuid(), %L, true)$q$, pg_temp.id('vG')))->>'code', 'not_allowed', 'and the Unit Admin fallback is not open (R assigns B again after the resolve)');
-- UA fallback: E is never assigned in any shift
select is(pg_temp.rpc('s5', format($q$select public.iss_verify(gen_random_uuid(), %L, true)$q$, pg_temp.id('vE')))->>'code', 'not_allowed', 'unassigned machine: a supervisor without ownership is denied');
select is(pg_temp.rpc('uax', format($q$select public.iss_verify(gen_random_uuid(), %L, false, 'Not good')$q$, pg_temp.id('vE')))->>'status', 'in_progress', 'unassigned machine: a Unit Admin can verify (reject)');
select is((pg_temp.iss('vE')).accountable_owner_id, pg_temp.id('s2'), 'a Unit Admin''s rejection leaves the owner unchanged');
select is((select count(*)::int from public.issue_ownership_history where issue_id = pg_temp.id('vE') and source = 'verification_rejected'), 0, 'and writes no ownership row');
select is(pg_temp.rpc('s1', format($q$select public.iss_verify(gen_random_uuid(), %L, true)$q$, pg_temp.id('iA2')))->>'field', 'invalid_status', 'a closed Low issue is not awaiting verification');
select is(pg_temp.rpc('uay', format($q$select public.iss_verify(gen_random_uuid(), %L, true)$q$, pg_temp.id('vF')))->>'code', 'not_allowed', 'another tenant cannot verify');

-- Reopen (AC-9) ---------------------------------------------------------------------------------------------------------------------------
select is(pg_temp.rpc('s1', format($q$select public.iss_reopen(gen_random_uuid(), %L, 'back')$q$, pg_temp.id('vA')))->>'code', 'not_allowed', 'a supervisor cannot reopen');
select is(pg_temp.rpc('uax', format($q$select public.iss_reopen(gen_random_uuid(), %L, '')$q$, pg_temp.id('vA')))->>'field', 'reason', 'validation: a reason is required');
select is(pg_temp.rpc('uax', format($q$select public.iss_reopen(gen_random_uuid(), %L, 'Leak is back')$q$, pg_temp.id('vF')))->>'field', 'invalid_status', 'guard: only a closed issue can be reopened');
select is(pg_temp.rpc('uax', format($q$select public.iss_reopen(gen_random_uuid(), %L, 'Leak is back')$q$, pg_temp.id('vA')))->>'ok', 'true', 'a Unit Admin reopens a closed issue');
select ok((pg_temp.iss('vA')).status = 'in_progress' and (pg_temp.iss('vA')).closed_at is null and (pg_temp.iss('vA')).accountable_owner_id = pg_temp.id('s1'), 'AC-9/10: In progress, closed_at cleared, owner unchanged');
select is((select count(*)::int from public.issue_action where issue_id = pg_temp.id('vA') and type in ('verify_confirm', 'reopen')), 2, 'the history keeps both the confirm and the reopen');
select is(pg_temp.rpc('s1', format($q$select public.iss_resolve(gen_random_uuid(), %L, 'Fixed properly')$q$, pg_temp.id('vA')))->>'status', 'resolved', 'it can be resolved again after a reopen');

-- Categories (AC-3) ---------------------------------------------------------------------------------------------------------------------------
select is(pg_temp.rpck('cNew', 'uax', $q$select public.iss_category_save(gen_random_uuid(), null, 'Hydraulics')$q$)->>'ok', 'true', 'a Unit Admin adds a category');
select is((select sort from public.issue_category where id = pg_temp.id('cNew')), 80, 'it sorts after the existing ones');
select is(pg_temp.rpc('uax', $q$select public.iss_category_save(gen_random_uuid(), null, 'hydraulics')$q$)->>'code', 'duplicate', 'duplicate names (case-insensitive) are refused');
select is(pg_temp.rpc('uax', $q$select public.iss_category_save(gen_random_uuid(), null, '')$q$)->>'field', 'name', 'validation: name');
select is(pg_temp.rpc('uax', format($q$select public.iss_category_save(gen_random_uuid(), %L, repeat('x', 41))$q$, pg_temp.id('cNew')))->>'field', 'name', 'validation: name over 40');
select is(pg_temp.rpc('uax', format($q$select public.iss_category_save(gen_random_uuid(), %L, 'Hydraulic system')$q$, pg_temp.id('cNew')))->>'ok', 'true', 'rename');
select is((select name from public.issue_category where id = pg_temp.id('cNew')), 'Hydraulic system', 'the new name is stored');
select is(pg_temp.rpc('s1', $q$select public.iss_category_save(gen_random_uuid(), null, 'Sup category')$q$)->>'code', 'not_allowed', 'a supervisor cannot add categories');
select is(pg_temp.rpc('uax', format($q$select public.iss_category_save(gen_random_uuid(), %L, 'Hijack')$q$, pg_temp.id('caty')))->>'code', 'not_allowed', 'another tenant''s category cannot be renamed');
select is(pg_temp.rpc('uax', format($q$select public.iss_category_set_retired(gen_random_uuid(), %L, true)$q$, pg_temp.id('cNew')))->>'changed', 'true', 'retire');
select is(pg_temp.rpc('s1', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'low', 'x', false)$q$, pg_temp.id('mA'), pg_temp.id('cNew')))->>'field', 'category_id', 'a retired category is not offered for new issues');
select is(pg_temp.rpc('uax', format($q$select public.iss_category_set_retired(gen_random_uuid(), %L, true)$q$, pg_temp.id('cNew')))->>'changed', 'false', 'retiring twice is a no-op');
select is(pg_temp.rpc('uax', format($q$select public.iss_category_set_retired(gen_random_uuid(), %L, false)$q$, pg_temp.id('cNew')))->>'changed', 'true', 'reinstate');
select is(pg_temp.rpc('s1', format($q$select public.iss_category_set_retired(gen_random_uuid(), %L, true)$q$, pg_temp.id('catx')))->>'code', 'not_allowed', 'a supervisor cannot retire');
select is(pg_temp.rpc('uax', format($q$select public.iss_category_set_retired(gen_random_uuid(), %L, null)$q$, pg_temp.id('catx')))->>'field', 'retired', 'validation: retire or reinstate');
select is(pg_temp.rpc('s1', format($q$select public.iss_report(gen_random_uuid(), %L, %L, 'low', 'Hyd', false)$q$, pg_temp.id('mA'), pg_temp.id('cNew')))->>'ok', 'true', 'a reinstated category can be used');
select is(pg_temp.rpc('uax', format($q$select public.iss_category_set_retired(gen_random_uuid(), %L, true)$q$, pg_temp.id('cNew')))->>'changed', 'true', 'a category in use can be retired (history kept)');

-- Audit rows (every action) -----------------------------------------------------------------------------------------------------------------------
select ok(pg_temp.n_audit('issue.reported', 'tx') >= 9, 'issue.reported audited');
select ok(pg_temp.n_audit('issue.noted', 'tx') = 4, 'issue.noted audited (4 notes)');
select ok(pg_temp.n_audit('issue.started', 'tx') = 2 and pg_temp.n_audit('issue.assignee_set', 'tx') = 1 and pg_temp.n_audit('issue.escalated', 'tx') = 2
  and pg_temp.n_audit('issue.escalation_acknowledged', 'tx') = 1 and pg_temp.n_audit('issue.reassigned', 'tx') = 1, 'start, assignee, escalate, acknowledge and reassign are audited');
select ok(pg_temp.n_audit('issue.resolved', 'tx') >= 4 and pg_temp.n_audit('issue.verified', 'tx') = 1 and pg_temp.n_audit('issue.verification_rejected', 'tx') = 2
  and pg_temp.n_audit('issue.reopened', 'tx') = 1, 'resolve, verify, reject and reopen are audited');
select ok(pg_temp.n_audit('issue_category.created', 'tx') = 1 and pg_temp.n_audit('issue_category.updated', 'tx') = 1 and pg_temp.n_audit('issue_category.retired', 'tx') = 2
  and pg_temp.n_audit('issue_category.reinstated', 'tx') = 1, 'category actions are audited');
select is((select count(*)::int from public.audit_event where action like 'issue.%' and (after::text ~* 'password|phone' or before::text ~* 'password|phone')), 0, 'no secrets or phones in audit');
select is((select count(*)::int from public.audit_event where action like 'issue.%' and request_id is null), 0, 'every issue audit row carries its request id');

-- Append-only, also against the service role ------------------------------------------------------------------------------------------------------
select is((select count(*)::int from public.issue_action a join public.machine_issue i on i.id = a.issue_id where a.type = 'report' and i.tenant_id = pg_temp.id('tx')), (select count(*)::int from public.machine_issue where tenant_id = pg_temp.id('tx') and description not like 'x issue %'), 'every reported issue has exactly one report action');
set local role service_role;
select throws_ok($$ update public.issue_action set notes = 'x' $$, '42501', null, 'service_role cannot update issue_action');
select throws_ok($$ delete from public.issue_ownership_history $$, '42501', null, 'service_role cannot delete ownership history');
reset role;

-- issue_can_verify: pure, explicit moments, tenant Z (Day 06-14, Night 22-06 overnight, retired Old) ---------------------------------------------------------
select pg_temp.as_user('uaz');
select pg_temp.zissue('zi1', 'zA', 'high', 'resolved', 'z3', pg_temp.at(0, '10:00'));
select pg_temp.zissue('zi2', 'zC', 'high', 'resolved', 'z3', pg_temp.at(0, '10:00'));
select pg_temp.zissue('zi3', 'zB', 'critical', 'resolved', 'z3', pg_temp.at(0, '23:00'));
select pg_temp.zissue('zi4', 'zA', 'high', 'resolved', 'z3', pg_temp.at(0, '23:00'));
select pg_temp.zissue('zi5', 'zB', 'high', 'resolved', 'z1', pg_temp.at(0, '23:00'));
select pg_temp.zissue('zi6', 'zD', 'high', 'resolved', 'z3', pg_temp.at(0, '10:00'));
select pg_temp.zissue('zOpen', 'zA', 'high', 'open', null, null);
select pg_temp.zissue('zLow', 'zA', 'low', 'closed', 'z3', pg_temp.at(0, '10:00'));
select ok(not app.issue_can_verify(pg_temp.id('zi1'), pg_temp.id('z1'), pg_temp.at(0, '11:00')), 'z1 (Day) at 11:00: its Day shift started before the resolve (10:00)');
select ok(not app.issue_can_verify(pg_temp.id('zi1'), pg_temp.id('z1'), pg_temp.at(0, '21:59')), 'z1 at 21:59: no later Day yet');
select ok(app.issue_can_verify(pg_temp.id('zi1'), pg_temp.id('z1'), pg_temp.at(1, '06:00')), 'z1 at tomorrow 06:00: the next Day has started (boundary is inclusive)');
select ok(not app.issue_can_verify(pg_temp.id('zi1'), pg_temp.id('z1'), pg_temp.at(1, '05:59')), 'z1 at tomorrow 05:59: one minute early');
select ok(not app.issue_can_verify(pg_temp.id('zi1'), pg_temp.id('z2'), pg_temp.at(0, '21:59')), 'z2 (Night) at 21:59: Night has not started');
select ok(app.issue_can_verify(pg_temp.id('zi1'), pg_temp.id('z2'), pg_temp.at(0, '22:00')), 'z2 at 22:00: Night started after the resolve');
select ok(app.issue_can_verify(pg_temp.id('zi1'), pg_temp.id('z2'), pg_temp.at(1, '01:00')), 'overnight: z2 at tomorrow 01:00, the occurrence that began yesterday 22:00 counts');
select ok(not app.issue_can_verify(pg_temp.id('zi1'), pg_temp.id('uaz'), pg_temp.at(1, '07:00')), 'a Unit Admin is refused while Day/Night supervisors are assigned');
select ok(not app.issue_can_verify(pg_temp.id('zi1'), pg_temp.id('z3'), pg_temp.at(1, '07:00')), 'z3 (not assigned on A) is refused');
select ok(not app.issue_can_verify(pg_temp.id('zi4'), pg_temp.id('z2'), pg_temp.at(1, '01:00')), 'overnight: Night began (22:00) before the resolve (23:00): not a later occurrence');
select ok(app.issue_can_verify(pg_temp.id('zi4'), pg_temp.id('z2'), pg_temp.at(1, '23:00')), 'overnight: tomorrow''s Night qualifies');
select ok(not app.issue_can_verify(pg_temp.id('zi3'), pg_temp.id('z1'), pg_temp.at(1, '05:59')), 'B: Day tomorrow not started at 05:59');
select ok(app.issue_can_verify(pg_temp.id('zi3'), pg_temp.id('z1'), pg_temp.at(1, '06:00')), 'B: z1 qualifies at 06:00');
select ok(not app.issue_can_verify(pg_temp.id('zi5'), pg_temp.id('z1'), pg_temp.at(1, '07:00')), 'the resolver is never eligible, even when they own the later shift');
select ok(not app.issue_can_verify(pg_temp.id('zi3'), pg_temp.id('uaz'), pg_temp.at(1, '07:00')), 'B: the Unit Admin is refused (Day is assigned to z1)');
select ok(app.issue_can_verify(pg_temp.id('zi2'), pg_temp.id('uaz'), pg_temp.at(0, '11:00')), 'C: the retired shift is ignored, so no supervisor is assigned -> the Unit Admin may verify');
select ok(not app.issue_can_verify(pg_temp.id('zi2'), pg_temp.id('z3'), pg_temp.at(1, '07:00')), 'C: a supervisor owning only a retired shift cannot verify');
select ok(app.issue_can_verify(pg_temp.id('zi6'), pg_temp.id('uaz'), pg_temp.at(1, '07:00')), 'D: an inactive owner counts as unassigned -> the Unit Admin may verify');
select ok(not app.issue_can_verify(pg_temp.id('zi6'), pg_temp.id('zinact'), pg_temp.at(1, '07:00')), 'D: the inactive supervisor cannot verify');
select ok(not app.issue_can_verify(pg_temp.id('zOpen'), pg_temp.id('z1'), pg_temp.at(1, '07:00')), 'an issue that is not Resolved cannot be verified');
select ok(not app.issue_can_verify(pg_temp.id('zLow'), pg_temp.id('uaz'), pg_temp.at(1, '07:00')), 'a closed issue cannot be verified');
select ok(not app.issue_can_verify(gen_random_uuid(), pg_temp.id('uaz'), now()), 'an unknown issue cannot be verified');
-- R2: a Unit Admin may verify when no supervisor OTHER than the resolver can (a first later occurrence owned by the resolver counts as unassigned)
select ok(app.issue_can_verify(pg_temp.id('zi5'), pg_temp.id('uaz'), pg_temp.at(1, '07:00')), 'R2: the resolver z1 owns every later shift of B -> the Unit Admin may verify');
select pg_temp.zissue('zi7', 'zB', 'high', 'resolved', 'uaz', pg_temp.at(0, '23:00'));
select ok(not app.issue_can_verify(pg_temp.id('zi7'), pg_temp.id('uaz'), pg_temp.at(1, '07:00')), 'R2: another supervisor (z1) owns B''s next Day -> the Unit Admin who resolved is refused');
select ok(app.issue_can_verify(pg_temp.id('zi7'), pg_temp.id('z1'), pg_temp.at(1, '06:00')), 'R2: z1 verifies a Unit Admin''s fix');
select pg_temp.zissue('zi8', 'zC', 'high', 'resolved', 'uaz', pg_temp.at(0, '10:00'));
select ok(app.issue_can_verify(pg_temp.id('zi8'), pg_temp.id('uaz'), pg_temp.at(0, '11:00')), 'R2: nobody else is assigned (retired shift only) -> a Unit Admin may verify their own fix');
-- R1: the day series stops 60 days after the resolve
select pg_temp.zissue('zi9', 'zA', 'high', 'resolved', 'z3', pg_temp.at(-100, '10:00'));
select pg_temp.zissue('zi10', 'zA', 'high', 'resolved', 'z3', pg_temp.at(-3, '10:00'));
select ok(not app.issue_can_verify(pg_temp.id('zi9'), pg_temp.id('z1'), now()), 'R1: resolved 100 days ago -> beyond the 60-day window, no later-shift owner is found');
select ok(app.issue_can_verify(pg_temp.id('zi10'), pg_temp.id('z1'), now()), 'R1: control: resolved 3 days ago -> z1 is eligible');
-- a cover that leaves B unassigned for tomorrow's Day opens the Unit Admin fallback and closes z1's eligibility
insert into public.assignment_cover (tenant_id, shift_id, shift_date, machine_id, supervisor_id, reason, recorded_by)
values (pg_temp.id('tz'), pg_temp.id('Day'), (select d + 1 from today), pg_temp.id('zB'), null, 'nobody that day', pg_temp.id('uaz'));
select ok(app.issue_can_verify(pg_temp.id('zi3'), pg_temp.id('uaz'), pg_temp.at(1, '07:00')), 'cover: B unassigned in tomorrow''s Day and no Night -> the Unit Admin may verify');
select ok(not app.issue_can_verify(pg_temp.id('zi3'), pg_temp.id('z1'), pg_temp.at(1, '07:00')), 'cover: z1 no longer owns B tomorrow');

-- N-6: machine_owner_now is the first ASSIGNED running occurrence, not the first running one (Early 05:00-15:00 is unassigned for A and started before Day)
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time) values ('54000000-0000-4000-c710-0000000000e4', pg_temp.id('tz'), '51000000-0000-4000-c710-00000000000e', 'Early', '05:00', '15:00');
select is(app.machine_owner_now(pg_temp.id('zA'), pg_temp.at(0, '07:00')), pg_temp.id('z1'), 'N-6: Early (unassigned) started first but Day''s owner z1 is the owner');
select is(app.machine_owner_now(pg_temp.id('zA'), pg_temp.at(0, '14:30')), null, 'N-6: only the unassigned Early runs at 14:30 -> nobody');

select * from finish();
rollback;
