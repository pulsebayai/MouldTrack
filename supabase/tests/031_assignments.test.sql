-- 05 AC-3..AC-6, AC-12 (DB part, assignments): sh_assign / sh_unassign / sh_cover, ownership resolution (app.machine_owner) for the AC-5 cases,
-- supervisor validity, no backdating, the later_change guard, append-only history, audited denials, idempotency, isolation.
-- Self-contained; rolled back. Plan dates are offsets from today's plant date so the test is date-independent.
begin;
create extension if not exists pgtap with schema extensions;
select plan(142);

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
select u, 'tap31-' || n || '@example.test', 'authenticated', 'authenticated' from (values
  ('00000000-0000-4000-c610-0000000000a1'::uuid, 'uax'), ('00000000-0000-4000-c610-0000000000a2', 'uax2'), ('00000000-0000-4000-c610-0000000000a3', 's1'),
  ('00000000-0000-4000-c610-0000000000a4', 's2'), ('00000000-0000-4000-c610-0000000000a5', 'sinact'), ('00000000-0000-4000-c610-0000000000a6', 'sfresh'),
  ('00000000-0000-4000-c610-0000000000a7', 'freshua'), ('00000000-0000-4000-c610-0000000000b1', 'uay'), ('00000000-0000-4000-c610-0000000000b2', 'sy'),
  ('00000000-0000-4000-c610-0000000000d1', 'uas'), ('00000000-0000-4000-c610-0000000000c1', 'nomem'), ('00000000-0000-4000-c610-0000000000a8', 'inactua')) t(u, n);
insert into ids values ('uax', '00000000-0000-4000-c610-0000000000a1'), ('uax2', '00000000-0000-4000-c610-0000000000a2'), ('s1', '00000000-0000-4000-c610-0000000000a3'),
  ('s2', '00000000-0000-4000-c610-0000000000a4'), ('sinact', '00000000-0000-4000-c610-0000000000a5'), ('sfresh', '00000000-0000-4000-c610-0000000000a6'),
  ('freshua', '00000000-0000-4000-c610-0000000000a7'), ('inactua', '00000000-0000-4000-c610-0000000000a8'), ('uay', '00000000-0000-4000-c610-0000000000b1'),
  ('sy', '00000000-0000-4000-c610-0000000000b2'), ('uas', '00000000-0000-4000-c610-0000000000d1'), ('nomem', '00000000-0000-4000-c610-0000000000c1'),
  ('tx', '50000000-0000-4000-c610-00000000000a'), ('ty', '50000000-0000-4000-c610-00000000000b'), ('ts', '50000000-0000-4000-c610-00000000000d');
insert into public.tenant (id, name, status, timezone) values
  ('50000000-0000-4000-c610-00000000000a', 'tap31 org X', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c610-00000000000b', 'tap31 org Y', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c610-00000000000d', 'tap31 org S', 'suspended', 'Asia/Kolkata');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('50000000-0000-4000-c610-00000000000a', '00000000-0000-4000-c610-0000000000a1', 'unit_admin', 'active', 'UA X', 'UA-X', '+919000020101', false),
  ('50000000-0000-4000-c610-00000000000a', '00000000-0000-4000-c610-0000000000a2', 'unit_admin', 'active', 'UA X2', 'UA-X2', '+919000020102', false),
  ('50000000-0000-4000-c610-00000000000a', '00000000-0000-4000-c610-0000000000a3', 'supervisor', 'active', 'Sup One', 'S1', '+919000020103', false),
  ('50000000-0000-4000-c610-00000000000a', '00000000-0000-4000-c610-0000000000a4', 'supervisor', 'active', 'Sup Two', 'S2', '+919000020104', false),
  ('50000000-0000-4000-c610-00000000000a', '00000000-0000-4000-c610-0000000000a5', 'supervisor', 'inactive', 'Sup Gone', 'S3', '+919000020105', false),
  ('50000000-0000-4000-c610-00000000000a', '00000000-0000-4000-c610-0000000000a6', 'supervisor', 'active', 'Sup Fresh', 'S4', '+919000020106', true),
  ('50000000-0000-4000-c610-00000000000a', '00000000-0000-4000-c610-0000000000a7', 'unit_admin', 'active', 'Fresh UA', 'FUA', '+919000020107', true),
  ('50000000-0000-4000-c610-00000000000a', '00000000-0000-4000-c610-0000000000a8', 'unit_admin', 'inactive', 'Gone UA', 'GUA', '+919000020108', false),
  ('50000000-0000-4000-c610-00000000000b', '00000000-0000-4000-c610-0000000000b1', 'unit_admin', 'active', 'UA Y', 'UA-Y', '+919000020109', false),
  ('50000000-0000-4000-c610-00000000000b', '00000000-0000-4000-c610-0000000000b2', 'supervisor', 'active', 'Sup Y', 'SY', '+919000020110', false),
  ('50000000-0000-4000-c610-00000000000d', '00000000-0000-4000-c610-0000000000d1', 'unit_admin', 'active', 'UA S', 'UA-S', '+919000020111', false);
insert into public.site (id, tenant_id, name, timezone) values
  ('51000000-0000-4000-c610-00000000000a', '50000000-0000-4000-c610-00000000000a', 'Plant X', 'Asia/Kolkata'),
  ('51000000-0000-4000-c610-00000000000b', '50000000-0000-4000-c610-00000000000b', 'Plant Y', 'Asia/Kolkata'),
  ('51000000-0000-4000-c610-00000000000d', '50000000-0000-4000-c610-00000000000d', 'Plant S', 'Asia/Kolkata');
insert into public.machine (id, tenant_id, site_id, code, name, retired_at) values
  ('53000000-0000-4000-c610-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c610-00000000000a', 'M-1', 'Press 1', null),
  ('53000000-0000-4000-c610-0000000000a2', pg_temp.id('tx'), '51000000-0000-4000-c610-00000000000a', 'M-2', 'Press 2', null),
  ('53000000-0000-4000-c610-0000000000a3', pg_temp.id('tx'), '51000000-0000-4000-c610-00000000000a', 'M-3', 'Press 3', null),
  ('53000000-0000-4000-c610-0000000000a4', pg_temp.id('tx'), '51000000-0000-4000-c610-00000000000a', 'M-4', 'Press 4', null),
  ('53000000-0000-4000-c610-0000000000a5', pg_temp.id('tx'), '51000000-0000-4000-c610-00000000000a', 'M-5', 'Retired press', now()),
  ('53000000-0000-4000-c610-0000000000a6', pg_temp.id('tx'), '51000000-0000-4000-c610-00000000000a', 'M-6', 'Press 6', null),
  ('53000000-0000-4000-c610-0000000000b1', pg_temp.id('ty'), '51000000-0000-4000-c610-00000000000b', 'Y-1', 'Y press', null);
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time, retired_at) values
  ('54000000-0000-4000-c610-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c610-00000000000a', 'Day', '06:00', '14:00', null),
  ('54000000-0000-4000-c610-0000000000a2', pg_temp.id('tx'), '51000000-0000-4000-c610-00000000000a', 'Night', '22:00', '06:00', null),
  ('54000000-0000-4000-c610-0000000000a3', pg_temp.id('tx'), '51000000-0000-4000-c610-00000000000a', 'Gone', '10:00', '12:00', now()),
  ('54000000-0000-4000-c610-0000000000a4', pg_temp.id('tx'), '51000000-0000-4000-c610-00000000000a', 'CovA', '00:00', '23:45', null),
  ('54000000-0000-4000-c610-0000000000a5', pg_temp.id('tx'), '51000000-0000-4000-c610-00000000000a', 'CovB', '23:45', '00:00', null),
  ('54000000-0000-4000-c610-0000000000b1', pg_temp.id('ty'), '51000000-0000-4000-c610-00000000000b', 'Y shift', '06:00', '14:00', null);
insert into ids values ('m1', '53000000-0000-4000-c610-0000000000a1'), ('m2', '53000000-0000-4000-c610-0000000000a2'), ('m3', '53000000-0000-4000-c610-0000000000a3'),
  ('m4', '53000000-0000-4000-c610-0000000000a4'), ('m5', '53000000-0000-4000-c610-0000000000a5'), ('m6', '53000000-0000-4000-c610-0000000000a6'), ('my', '53000000-0000-4000-c610-0000000000b1'),
  ('day', '54000000-0000-4000-c610-0000000000a1'), ('night', '54000000-0000-4000-c610-0000000000a2'), ('gone', '54000000-0000-4000-c610-0000000000a3'),
  ('cova', '54000000-0000-4000-c610-0000000000a4'), ('covb', '54000000-0000-4000-c610-0000000000a5'), ('shifty', '54000000-0000-4000-c610-0000000000b1');
grant select on ids to authenticated, anon;
create temp table today as select app.plant_date(pg_temp.id('tx')) as d;
grant select on today to authenticated, anon;
-- who owns a machine on shift occurrence today + off: the fixture key of the supervisor, 'none' when unassigned
create function pg_temp.own(m text, sh text, off int) returns text language sql as $$
  select coalesce((select k from ids where v = app.machine_owner(pg_temp.id($1), pg_temp.id($2), (select d + $3 from today))), 'none') $$;
create function pg_temp.src(m text, sh text, off int) returns text language sql as $$
  select (select o.source from app.machine_owner_src(pg_temp.id($1), pg_temp.id($2), (select d + $3 from today)) o) $$;
create function pg_temp.nv(sh text) returns int language sql as $$ select count(*)::int from public.assignment_version where shift_id = pg_temp.id($1) $$;
create function pg_temp.assign(sup text, ms text[], from_off int, until_off int default null) returns jsonb language sql as $$
  select public.sh_assign(gen_random_uuid(), pg_temp.id('day'), pg_temp.id($1), (select array_agg(pg_temp.id(m)) from unnest($2) m), (select d + $3 from today), (select d + $4 from today)) $$;

-- Privileges ----------------------------------------------------------------------
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('sh_assign', 'sh_unassign', 'sh_cover')
             and has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute')
             and p.prosecdef and p.proconfig is not null and 'search_path=""' = any (p.proconfig)), 3,
  'the three assignment RPCs are security definer, empty search_path, executable by authenticated and not by anon');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'app' and p.proname ~ '^(_sh_|machine_owner)'
             and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')
                  or not p.prosecdef or p.proconfig is null or not ('search_path=""' = any (p.proconfig)))), 0,
  'the ownership functions and helpers are security definer with an empty search_path and not executable by clients');

-- Recurring plan (AC-3, AC-5) --------------------------------------------------------------
select pg_temp.as_user('uax');
select is(pg_temp.own('m1', 'day', 1), 'none', 'before any plan the machine is unassigned');
select is(pg_temp.src('m1', 'day', 1), 'none', 'and its source is none');
insert into ids values ('rq_a1', gen_random_uuid());
select is((public.sh_assign(pg_temp.id('rq_a1'), pg_temp.id('day'), pg_temp.id('s1'), array[pg_temp.id('m1'), pg_temp.id('m2')], (select d + 1 from today)))->>'ok', 'true', 'assign: two machines to Sup One from tomorrow');
select is(pg_temp.nv('day'), 2, 'one plan version per machine');
select results_eq($$ select recorded_by, request_id, supervisor_id, effective_from from public.assignment_version where machine_id = pg_temp.id('m1') $$,
  $$ values (pg_temp.id('uax'), pg_temp.id('rq_a1'), pg_temp.id('s1'), (select d + 1 from today)) $$, 'recorded by the caller with the request id');
select is(pg_temp.n_audit('assignment.set', 'tx'), 1, 'one audit row per call');
select results_eq($$ select after->'machines', after->>'supervisor_id', after->>'from', (before->'previous'->0->>'supervisor_id') is null
  from public.audit_event where action = 'assignment.set' and tenant_id = pg_temp.id('tx') $$,
  $$ select '["M-1","M-2"]'::jsonb, pg_temp.id('s1')::text, (select (d + 1)::text from today), true $$, 'the audit lists the machines, the supervisor, the date and the previous owners');
select is((public.sh_assign(pg_temp.id('rq_a1'), pg_temp.id('day'), pg_temp.id('s1'), array[pg_temp.id('m1'), pg_temp.id('m2')], (select d + 1 from today)))->>'already', 'true', 'a repeat reports already done');
select is(pg_temp.nv('day'), 2, 'the repeat records no new version');
select is(pg_temp.n_audit('assignment.set', 'tx'), 1, 'the repeat writes no second audit row');
select is(pg_temp.own('m1', 'day', 0), 'none', 'AC-5 plan only: nobody before the start date');
select is(pg_temp.own('m1', 'day', 1), 's1', 'AC-5 plan only: the supervisor from the start date');
select is(pg_temp.src('m1', 'day', 1), 'plan', 'its source is the plan');
select is(pg_temp.own('m1', 'day', 400), 's1', 'AC-5: the plan has no end unless set');
select is(pg_temp.own('m3', 'day', 1), 'none', 'a machine nobody covers is unassigned');
select is(pg_temp.own('m1', 'night', 1), 'none', 'the plan belongs to its shift only');
-- plan change on day D replaces the owner from D (AC-3, AC-5)
select is((pg_temp.assign('s2', array['m1'], 3))->>'ok', 'true', 'assign: another supervisor takes M-1 from day 3');
select is(pg_temp.own('m1', 'day', 2), 's1', 'AC-5 plan change on day D: the old owner the day before');
select is(pg_temp.own('m1', 'day', 3), 's2', 'AC-5 plan change on day D: the new owner from D');
select is((select (before->'previous'->0->>'supervisor_id')::uuid from public.audit_event e where action = 'assignment.set' and tenant_id = pg_temp.id('tx')
           and (after->>'from')::date = (select d + 3 from today)), pg_temp.id('s1'), 'the audit names the supervisor who loses the machine');
-- until
select is((pg_temp.assign('s1', array['m3'], 1, 5))->>'ok', 'true', 'assign with an end date');
select is(pg_temp.own('m3', 'day', 5), 's1', 'AC-5 until: the last day is covered');
select is(pg_temp.own('m3', 'day', 6), 'none', 'AC-5 until: unassigned the day after');
select is((select count(*)::int from public.assignment_version where machine_id = pg_temp.id('m3')), 2, 'the end is a null version at until + 1');
-- R4: re-planning supersedes the changes already scheduled later (no later_change guard any more)
select is((pg_temp.assign('s2', array['m1'], 2))->>'ok', 'true', 'R4: re-planning before a later scheduled change is accepted');
select is(pg_temp.own('m1', 'day', 2), 's2', 'R4: the new owner from the new start date');
select is(pg_temp.own('m1', 'day', 3), 's2', 'R4: the later scheduled version (same supervisor) still resolves to the new plan');
select results_eq($$ select after->'superseded' from public.audit_event where action = 'assignment.set' and tenant_id = pg_temp.id('tx') and (after->>'from')::date = (select d + 2 from today) $$,
  $$ select jsonb_build_array(jsonb_build_object('machine_code', 'M-1', 'dates', jsonb_build_array((select (d + 3)::text from today)))) $$, 'R4: the audit row lists the superseded dates per machine');
-- the reviewer's sequence on M-6: a week of Sup One, then a re-plan that starts before it
select is((pg_temp.assign('s1', array['m6'], 5, 9))->>'ok', 'true', 'R4 sequence: Sup One from day 5 to day 9');
select is(pg_temp.own('m6', 'day', 10), 'none', 'R4 sequence: unassigned from day 10');
select is((pg_temp.assign('s2', array['m6'], 3))->>'ok', 'true', 'R4 sequence: Sup Two from day 3, no end date, before the scheduled week');
select results_eq($$ select pg_temp.own('m6', 'day', 2), pg_temp.own('m6', 'day', 3), pg_temp.own('m6', 'day', 5), pg_temp.own('m6', 'day', 9), pg_temp.own('m6', 'day', 10), pg_temp.own('m6', 'day', 11) $$,
  $$ values ('none'::text, 's2'::text, 's2'::text, 's2'::text, 's2'::text, 's2'::text) $$, 'R4 sequence: Sup Two owns it from day 3 on, the old week and its end no longer win');
select results_eq($$ select after->'superseded' from public.audit_event where action = 'assignment.set' and tenant_id = pg_temp.id('tx') and (after->>'from')::date = (select d + 3 from today)
                       and after->'machines' = '["M-6"]'::jsonb $$,
  $$ select jsonb_build_array(jsonb_build_object('machine_code', 'M-6', 'dates', jsonb_build_array((select (d + 5)::text from today), (select (d + 10)::text from today)))) $$, 'R4 sequence: the audit lists both superseded dates');
select is((pg_temp.assign('s1', array['m6'], 3, 7))->>'ok', 'true', 'R4 until: Sup One from day 3 to day 7');
select results_eq($$ select pg_temp.own('m6', 'day', 3), pg_temp.own('m6', 'day', 5), pg_temp.own('m6', 'day', 7), pg_temp.own('m6', 'day', 8), pg_temp.own('m6', 'day', 9), pg_temp.own('m6', 'day', 10) $$,
  $$ values ('s1'::text, 's1'::text, 's1'::text, 'none'::text, 'none'::text, 's2'::text) $$, 'R4 until: the end date unassigns after it; a change scheduled beyond the end date stays');
-- same-day correction
select is((pg_temp.assign('s2', array['m2'], 1))->>'ok', 'true', 'a same-day correction is accepted');
select is(pg_temp.own('m2', 'day', 1), 's2', 'the latest version for the date wins');
-- overnight occurrence
select is((public.sh_assign(gen_random_uuid(), pg_temp.id('night'), pg_temp.id('s1'), array[pg_temp.id('m4')], (select d + 1 from today)))->>'ok', 'true', 'assign on the overnight shift');
select is(pg_temp.own('m4', 'night', 1), 's1', 'AC-5 overnight: the occurrence that starts on the start date');
select is(pg_temp.own('m4', 'night', 0), 'none', 'AC-5 overnight: not the occurrence the day before');
-- duplicates in the list record one version
select is((pg_temp.assign('s1', array['m4', 'm4'], 2))->>'machines', '1', 'a machine listed twice is assigned once');
select is((select count(*)::int from public.assignment_version where machine_id = pg_temp.id('m4') and shift_id = pg_temp.id('day')), 1, 'and gets one version');
-- validation and guards
select is((pg_temp.err(format($$ select public.sh_assign(gen_random_uuid(), %L, %L, array[%L::uuid], %L) $$, pg_temp.id('day'), pg_temp.id('s1'), pg_temp.id('m1'), (select d - 1 from today))))->>'field', 'from', 'backdating is refused on field from');
select is((pg_temp.err(format($$ select public.sh_assign(gen_random_uuid(), %L, %L, array[%L::uuid], null) $$, pg_temp.id('day'), pg_temp.id('s1'), pg_temp.id('m1'))))->>'field', 'from', 'a missing start date is refused');
select is((pg_temp.err(format($$ select public.sh_assign(gen_random_uuid(), %L, %L, array[%L::uuid], %L, %L) $$, pg_temp.id('day'), pg_temp.id('s1'), pg_temp.id('m1'), (select d + 40 from today), (select d + 39 from today))))->>'field', 'until', 'an end date before the start is refused on field until');
select is((pg_temp.err(format($$ select public.sh_assign(gen_random_uuid(), %L, %L, array[]::uuid[], %L) $$, pg_temp.id('day'), pg_temp.id('s1'), (select d + 40 from today))))->>'field', 'machine_ids', 'an empty machine list is refused');
select is((pg_temp.err(format($$ select public.sh_assign(gen_random_uuid(), %L, %L, null, %L) $$, pg_temp.id('day'), pg_temp.id('s1'), (select d + 40 from today))))->>'field', 'machine_ids', 'a null machine list is refused');
select is((pg_temp.err(format($$ select public.sh_assign(gen_random_uuid(), %L, null, array[%L::uuid], %L) $$, pg_temp.id('day'), pg_temp.id('m1'), (select d + 40 from today))))->>'field', 'supervisor', 'a missing supervisor is refused');
select is((pg_temp.err(format($$ select public.sh_assign(null, %L, %L, array[%L::uuid], %L) $$, pg_temp.id('day'), pg_temp.id('s1'), pg_temp.id('m1'), (select d + 40 from today))))->>'field', 'request_id', 'a null request id is refused');
select is((pg_temp.err(format($$ select public.sh_assign(gen_random_uuid(), %L, %L, array[%L::uuid], %L) $$, pg_temp.id('day'), pg_temp.id('s1'), pg_temp.id('m5'), (select d + 40 from today))))
  - 'message', '{"code":"guard","field":"machine_ids","machines":["M-5"],"sqlstate":"P0001"}'::jsonb, 'a retired machine cannot be assigned (lists it)');
select is((pg_temp.err(format($$ select public.sh_assign(gen_random_uuid(), %L, %L, array[%L::uuid], %L) $$, pg_temp.id('gone'), pg_temp.id('s1'), pg_temp.id('m1'), (select d + 40 from today))))->>'field', 'shift_id', 'a retired shift cannot be assigned');
-- supervisor validity (AC-6)
select is((pg_temp.err(format($$ select public.sh_assign(gen_random_uuid(), %L, %L, array[%L::uuid], %L) $$, pg_temp.id('day'), pg_temp.id('uax2'), pg_temp.id('m1'), (select d + 40 from today))))
  - 'message', '{"code":"validation","field":"supervisor","sqlstate":"P0001"}'::jsonb, 'AC-6: a Unit Admin cannot be assigned');
select is((pg_temp.err(format($$ select public.sh_assign(gen_random_uuid(), %L, %L, array[%L::uuid], %L) $$, pg_temp.id('day'), pg_temp.id('sinact'), pg_temp.id('m1'), (select d + 40 from today))))->>'field', 'supervisor', 'AC-6: an inactive supervisor cannot be assigned');
select is((pg_temp.err(format($$ select public.sh_assign(gen_random_uuid(), %L, %L, array[%L::uuid], %L) $$, pg_temp.id('day'), pg_temp.id('sfresh'), pg_temp.id('m1'), (select d + 40 from today))))->>'field', 'supervisor', 'AC-6: a supervisor with a temporary password cannot be assigned');
select is(pg_temp.n_audit('assignment.set', 'tx'), 10, 'refused calls wrote no audit rows (ten successful assignments so far)');

-- Unassign ----------------------------------------------------------------------------------
-- R4: unassigning supersedes every later scheduled version of those machines
select is((public.sh_unassign(gen_random_uuid(), pg_temp.id('day'), array[pg_temp.id('m6')], (select d + 4 from today)))->>'machines', '1', 'R4 unassign: M-6 is unassigned from day 4');
select results_eq($$ select pg_temp.own('m6', 'day', 3), pg_temp.own('m6', 'day', 4), pg_temp.own('m6', 'day', 5), pg_temp.own('m6', 'day', 10), pg_temp.own('m6', 'day', 30) $$,
  $$ values ('s1'::text, 'none'::text, 'none'::text, 'none'::text, 'none'::text) $$, 'R4 unassign: none from day 4 on, whatever was scheduled later');
select results_eq($$ select after->'superseded' from public.audit_event where action = 'assignment.ended' and tenant_id = pg_temp.id('tx') and after->'machines' = '["M-6"]'::jsonb $$,
  $$ select jsonb_build_array(jsonb_build_object('machine_code', 'M-6', 'dates', jsonb_build_array((select (d + 5)::text from today), (select (d + 8)::text from today), (select (d + 10)::text from today)))) $$,
  'R4 unassign: the audit lists the superseded dates');
select is((pg_temp.err(format($$ select public.sh_unassign(gen_random_uuid(), %L, array[%L::uuid], %L) $$, pg_temp.id('day'), pg_temp.id('m1'), (select d - 1 from today))))->>'field', 'from', 'unassign: backdating is refused');
select is((pg_temp.err(format($$ select public.sh_unassign(gen_random_uuid(), %L, array[]::uuid[], %L) $$, pg_temp.id('day'), (select d + 10 from today))))->>'field', 'machine_ids', 'unassign: an empty list is refused');
select is((pg_temp.err(format($$ select public.sh_unassign(gen_random_uuid(), %L, array[%L::uuid], %L) $$, pg_temp.id('night'), pg_temp.id('m1'), (select d + 10 from today))))->>'field', 'not_assigned', 'unassign: refused when no machine is assigned from that date');
insert into ids values ('rq_u1', gen_random_uuid());
select is((public.sh_unassign(pg_temp.id('rq_u1'), pg_temp.id('day'), array[pg_temp.id('m1'), pg_temp.id('m3')], (select d + 10 from today)))->>'machines', '1', 'unassign: only machines that have a supervisor that day are ended (M-3 already ended on day 5)');
select is(pg_temp.own('m1', 'day', 9), 's2', 'unassign: still covered the day before');
select is(pg_temp.own('m1', 'day', 10), 'none', 'unassign: unassigned from that date');
select is(pg_temp.n_audit('assignment.ended', 'tx'), 2, 'unassign: one audit row for this call (plus the R4 one)');
select results_eq($$ select after->'machines', before->'previous'->0->>'supervisor_id' from public.audit_event where action = 'assignment.ended' and tenant_id = pg_temp.id('tx') and after->'machines' = '["M-1"]'::jsonb $$,
  $$ select '["M-1"]'::jsonb, pg_temp.id('s2')::text $$, 'unassign: audit lists the ended machines and their previous owner');
select is((public.sh_unassign(pg_temp.id('rq_u1'), pg_temp.id('day'), array[pg_temp.id('m1'), pg_temp.id('m3')], (select d + 10 from today)))->>'already', 'true', 'unassign: a repeat reports already done');
select is(pg_temp.n_audit('assignment.ended', 'tx'), 2, 'unassign: the repeat writes no second audit row');

-- Cover (AC-4, AC-5) ---------------------------------------------------------------------------
-- a plan for the always-running shifts, then cover the occurrence that is running right now
-- (R1: the RPC refuses a plan that starts on a started occurrence, so these two plan rows are fixtures inserted directly, as the table owner)
insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by)
select pg_temp.id('tx'), pg_temp.id(sh), pg_temp.id('m1'), pg_temp.id('s1'), (select d - 5 from today), pg_temp.id('uax') from (values ('cova'), ('covb')) t(sh);
select is((select count(*)::int from public.assignment_version where shift_id in (pg_temp.id('cova'), pg_temp.id('covb'))), 2, 'plan: Sup One owns M-1 on CovA and CovB (fixture rows)');
create temp table cur as select o.shift_id, o.shift_date, s.name from app.current_occurrences() o join public.shift s on s.id = o.shift_id where s.name in ('CovA', 'CovB');
insert into ids select 'curshift', shift_id from cur;
select is((select count(*)::int from cur), 1, 'exactly one of CovA / CovB is running now');
create function pg_temp.cur_date() returns date language sql as $$ select shift_date from cur $$;
create function pg_temp.cur_owner(m text) returns text language sql as $$
  select coalesce((select k from ids where v = app.machine_owner(pg_temp.id($1), pg_temp.id('curshift'), pg_temp.cur_date())), 'none') $$;
select is(pg_temp.cur_owner('m1'), 's1', 'the running occurrence is owned by the plan before any cover');
insert into ids values ('rq_c1', gen_random_uuid());
select is((public.sh_cover(pg_temp.id('rq_c1'), pg_temp.id('curshift'), pg_temp.cur_date(), array[pg_temp.id('m1')], pg_temp.id('s2'), '  Sup One is on leave  '))->>'ok', 'true', 'cover: an occurrence that is running now can be covered');
select is(pg_temp.cur_owner('m1'), 's2', 'AC-5 cover: the covering supervisor owns the machine for that occurrence');
select is((select o.source || ':' || o.reason from app.machine_owner_src(pg_temp.id('m1'), pg_temp.id('curshift'), pg_temp.cur_date()) o), 'cover:Sup One is on leave', 'the source is the cover, with its trimmed reason');
select is((select count(*)::int from public.assignment_version where shift_id in (pg_temp.id('cova'), pg_temp.id('covb'))), 2, 'the plan is unchanged by a cover');
select is(app.machine_owner(pg_temp.id('m1'), pg_temp.id('curshift'), pg_temp.cur_date() + 1), pg_temp.id('s1'), 'the next occurrence is still the plan');
select is(pg_temp.n_audit('assignment.covered', 'tx'), 1, 'cover: one audit row');
select results_eq($$ select after->>'reason', after->'machines', before->'previous'->0->>'supervisor_id' from public.audit_event where action = 'assignment.covered' and tenant_id = pg_temp.id('tx') $$,
  $$ select 'Sup One is on leave'::text, '["M-1"]'::jsonb, pg_temp.id('s1')::text $$, 'cover: audit has reason, machines and the previous owner');
select is((public.sh_cover(pg_temp.id('rq_c1'), pg_temp.id('curshift'), pg_temp.cur_date(), array[pg_temp.id('m1')], pg_temp.id('s2'), 'Sup One is on leave'))->>'already', 'true', 'cover: a repeat reports already done');
select is((select count(*)::int from public.assignment_cover), 1, 'cover: the repeat records no second row');
select is((public.sh_cover(gen_random_uuid(), pg_temp.id('curshift'), pg_temp.cur_date(), array[pg_temp.id('m1')], pg_temp.id('s1'), 'Back again'))->>'ok', 'true', 'cover: re-cover the same machine and occurrence');
select is(pg_temp.cur_owner('m1'), 's1', 'AC-5 cover then re-cover: the latest wins');
select is((public.sh_cover(gen_random_uuid(), pg_temp.id('curshift'), pg_temp.cur_date(), array[pg_temp.id('m1')], null, 'Machine is down'))->>'ok', 'true', 'cover: to unassigned');
select is(pg_temp.cur_owner('m1'), 'none', 'AC-5 cover to unassigned: nobody owns it');
select is((select o.source from app.machine_owner_src(pg_temp.id('m1'), pg_temp.id('curshift'), pg_temp.cur_date()) o), 'cover', 'and the source is still the cover');
select is(app.machine_owner(pg_temp.id('m1'), pg_temp.id('curshift'), pg_temp.cur_date() + 1), pg_temp.id('s1'), 'the plan resumes the next day');
select is((select count(*)::int from public.assignment_cover), 3, 'cover history keeps every row');
-- R1: a plan change never rewrites an occurrence that has started (running or ended); it starts at the first one that hasn't
select is((pg_temp.err(format($$ select public.sh_assign(gen_random_uuid(), %L, %L, array[%L::uuid], %L) $$, pg_temp.id('curshift'), pg_temp.id('s2'), pg_temp.id('m3'), pg_temp.cur_date())) - 'message'),
  '{"code":"guard","field":"occurrence_started","sqlstate":"P0001"}'::jsonb, 'R1: assigning from the date of a running occurrence is refused');
select is((pg_temp.err(format($$ select public.sh_assign(gen_random_uuid(), %L, %L, array[%L::uuid], %L) $$, pg_temp.id('curshift'), pg_temp.id('s2'), pg_temp.id('m3'), pg_temp.cur_date())))->>'message',
  'This shift has already started — use Cover for this shift', 'R1: the message points to Cover');
select is((pg_temp.err(format($$ select public.sh_unassign(gen_random_uuid(), %L, array[%L::uuid], %L) $$, pg_temp.id('curshift'), pg_temp.id('m1'), pg_temp.cur_date())))->>'field',
  'occurrence_started', 'R1: ending from the date of a running occurrence is refused too');
select is(pg_temp.n_audit('assignment.set', 'tx'), 10, 'R1: refused calls wrote no audit row');
select is((public.sh_assign(gen_random_uuid(), pg_temp.id('curshift'), pg_temp.id('s2'), array[pg_temp.id('m3')], pg_temp.cur_date() + 1))->>'ok', 'true', 'R1: the next occurrence of the same shift can be planned');
-- an occurrence that ended today: Early starts at 00:00 and ends at 00:15 (skipped in the first 15 minutes of the plant day, when it is still running)
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time) values
  ('54000000-0000-4000-c610-0000000000a6', pg_temp.id('tx'), '51000000-0000-4000-c610-00000000000a', 'Early', '00:00', '00:15'),
  ('54000000-0000-4000-c610-0000000000a7', pg_temp.id('tx'), '51000000-0000-4000-c610-00000000000a', 'Soon', '00:00', '00:15');
insert into ids values ('early', '54000000-0000-4000-c610-0000000000a6'), ('soon', '54000000-0000-4000-c610-0000000000a7');
select case when (now() at time zone 'Asia/Kolkata')::time >= time '00:15'
  then is((pg_temp.err(format($$ select public.sh_assign(gen_random_uuid(), %L, %L, array[%L::uuid], %L) $$, pg_temp.id('early'), pg_temp.id('s2'), pg_temp.id('m3'), (select d from today))))->>'field',
        'occurrence_started', 'R1: assigning from today on a shift whose occurrence today has ended is refused')
  else pass('R1 skipped: the Early shift is still running in the first 15 minutes of the plant day') end;
-- a shift that has not started today: Soon starts at an hour boundary at least two hours ahead
update public.shift set start_time = date_trunc('hour', (now() at time zone 'Asia/Kolkata') + interval '3 hours')::time,
                        end_time = date_trunc('hour', (now() at time zone 'Asia/Kolkata') + interval '4 hours')::time
 where id = pg_temp.id('soon');
select case when (now() at time zone 'Asia/Kolkata')::time < time '20:00'
  then is((public.sh_assign(gen_random_uuid(), pg_temp.id('soon'), pg_temp.id('s2'), array[pg_temp.id('m3')], (select d from today)))->>'ok', 'true',
        'R1: from today is fine when today''s occurrence has not started')
  else pass('R1 skipped: after 20:00 (plant time) the Soon shift would wrap into tomorrow') end;
-- a future occurrence can be covered; an ended one cannot
select is((public.sh_cover(gen_random_uuid(), pg_temp.id('day'), (select d + 4 from today), array[pg_temp.id('m1'), pg_temp.id('m2')], pg_temp.id('s1'), 'Training day'))->>'ok', 'true', 'cover: a future occurrence');
select is(pg_temp.own('m2', 'day', 4), 's1', 'cover on a future date applies to that date only');
select is(pg_temp.own('m2', 'day', 5), 's2', 'and the plan applies on the next');
select is((pg_temp.err(format($$ select public.sh_cover(gen_random_uuid(), %L, %L, array[%L::uuid], %L, 'Late') $$, pg_temp.id('day'), (select d - 3 from today), pg_temp.id('m1'), pg_temp.id('s1'))))
  - 'message', '{"code":"guard","field":"occurrence_ended","sqlstate":"P0001"}'::jsonb, 'cover: an occurrence that has ended is refused');
select is((pg_temp.err(format($$ select public.sh_cover(gen_random_uuid(), %L, %L, array[%L::uuid], %L, '') $$, pg_temp.id('day'), (select d + 4 from today), pg_temp.id('m1'), pg_temp.id('s1'))))->>'field', 'reason', 'cover: a reason is required');
select is((pg_temp.err(format($$ select public.sh_cover(gen_random_uuid(), %L, %L, array[%L::uuid], %L, repeat('x', 201)) $$, pg_temp.id('day'), (select d + 4 from today), pg_temp.id('m1'), pg_temp.id('s1'))))->>'field', 'reason', 'cover: a reason over 200 characters is refused');
select is((pg_temp.err(format($$ select public.sh_cover(gen_random_uuid(), %L, null, array[%L::uuid], %L, 'x') $$, pg_temp.id('day'), pg_temp.id('m1'), pg_temp.id('s1'))))->>'field', 'shift_date', 'cover: a shift date is required');
select is((pg_temp.err(format($$ select public.sh_cover(gen_random_uuid(), %L, %L, array[%L::uuid], %L, 'x') $$, pg_temp.id('day'), (select d + 4 from today), pg_temp.id('m1'), pg_temp.id('uax2'))))->>'field', 'supervisor', 'cover: a Unit Admin cannot cover');
select is((pg_temp.err(format($$ select public.sh_cover(gen_random_uuid(), %L, %L, array[%L::uuid], %L, 'x') $$, pg_temp.id('day'), (select d + 4 from today), pg_temp.id('m1'), pg_temp.id('sinact'))))->>'field', 'supervisor', 'cover: an inactive supervisor cannot cover');
select is((pg_temp.err(format($$ select public.sh_cover(gen_random_uuid(), %L, %L, array[%L::uuid], %L, 'x') $$, pg_temp.id('day'), (select d + 4 from today), pg_temp.id('m5'), pg_temp.id('s1'))))->>'field', 'machine_ids', 'cover: a retired machine is refused');
select is((pg_temp.err(format($$ select public.sh_cover(gen_random_uuid(), %L, %L, array[%L::uuid], %L, 'x') $$, pg_temp.id('gone'), (select d + 4 from today), pg_temp.id('m1'), pg_temp.id('s1'))))->>'field', 'shift_id', 'cover: a retired shift is refused');

-- Append-only history ------------------------------------------------------------------------------
select throws_ok($$ update public.assignment_version set supervisor_id = null $$, 'P0001', 'assignment_version is append-only', 'plan versions cannot be updated (owner)');
select throws_ok($$ delete from public.assignment_version $$, 'P0001', 'assignment_version is append-only', 'plan versions cannot be deleted (owner)');
select throws_ok($$ truncate public.assignment_version $$, 'P0001', 'assignment_version is append-only', 'plan versions cannot be truncated (owner)');
select throws_ok($$ update public.assignment_cover set reason = 'x' $$, 'P0001', 'assignment_cover is append-only', 'covers cannot be updated (owner)');
select throws_ok($$ delete from public.assignment_cover $$, 'P0001', 'assignment_cover is append-only', 'covers cannot be deleted (owner)');
select throws_ok($$ truncate public.assignment_cover $$, 'P0001', 'assignment_cover is append-only', 'covers cannot be truncated (owner)');
set local role service_role;
select throws_ok($$ update public.assignment_version set supervisor_id = null $$, '42501', null, 'the service role has no update on plan versions');
select throws_ok($$ delete from public.assignment_cover $$, '42501', null, 'the service role has no delete on covers');
reset role;
select throws_ok($$ insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by)
  values (pg_temp.id('tx'), pg_temp.id('day'), pg_temp.id('m1'), pg_temp.id('sy'), current_date, pg_temp.id('uax')) $$, '23514', null, 'a plan version cannot name another tenant''s supervisor');
select throws_ok($$ insert into public.assignment_cover (tenant_id, shift_id, shift_date, machine_id, supervisor_id, reason, recorded_by)
  values (pg_temp.id('tx'), pg_temp.id('day'), current_date, pg_temp.id('m1'), pg_temp.id('sy'), 'x', pg_temp.id('uax')) $$, '23514', null, 'a cover cannot name another tenant''s supervisor');
select throws_ok($$ insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by)
  values (pg_temp.id('tx'), pg_temp.id('day'), pg_temp.id('my'), null, current_date, pg_temp.id('uax')) $$, '23503', null, 'composite FK: a plan version cannot use another tenant''s machine');
select throws_ok($$ insert into public.assignment_cover (tenant_id, shift_id, shift_date, machine_id, supervisor_id, reason, recorded_by)
  values (pg_temp.id('tx'), pg_temp.id('shifty'), current_date, pg_temp.id('m1'), null, 'x', pg_temp.id('uax')) $$, '23503', null, 'composite FK: a cover cannot use another tenant''s shift');

-- A supervisor deactivated later stays in the plan (AC-6); the plan still resolves to them
update public.membership set status = 'inactive' where user_id = pg_temp.id('s2');
select is(pg_temp.own('m2', 'day', 5), 's2', 'AC-6: a deactivated supervisor still owns their machines until the Unit Admin changes the plan');
update public.membership set status = 'active' where user_id = pg_temp.id('s2');

-- Denials (AC-12) ---------------------------------------------------------------------------
create temp table calls (n text, q text);
insert into calls values
  ('assign', format($$ select public.sh_assign(gen_random_uuid(), %L, %L, array[%L::uuid], current_date + 60) $$, pg_temp.id('day'), pg_temp.id('s1'), pg_temp.id('m1'))),
  ('unassign', format($$ select public.sh_unassign(gen_random_uuid(), %L, array[%L::uuid], current_date + 60) $$, pg_temp.id('day'), pg_temp.id('m1'))),
  ('cover', format($$ select public.sh_cover(gen_random_uuid(), %L, current_date + 60, array[%L::uuid], %L, 'x') $$, pg_temp.id('day'), pg_temp.id('m1'), pg_temp.id('s1')));
create function pg_temp.run_all() returns int language plpgsql as $$
declare c record; ok int := 0; r jsonb;
begin
  for c in select * from calls loop
    execute c.q into r;
    if r = '{"ok": false, "code": "not_allowed"}'::jsonb then ok := ok + 1; end if;
  end loop;
  return ok;
end $$;
create temp table before_counts as select (select count(*) from public.assignment_version) v, (select count(*) from public.assignment_cover) c,
  (select count(*) from public.audit_event where action <> 'access.denied') a;
select pg_temp.as_user('s1');
select is(pg_temp.run_all(), 3, 'a supervisor gets the generic denial from every assignment RPC');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('s1') and reason = 'role'
           and actor_role = 'supervisor' and tenant_id = pg_temp.id('tx') and request_id is null and source like 'rpc:sh_%'), 3, 'each supervisor denial is audited (reason role)');
select pg_temp.as_user('freshua');
select is(pg_temp.run_all(), 3, 'a Unit Admin with a temporary password is denied');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('freshua') and reason = 'must_change_password'), 3, 'must-change denials audited');
select pg_temp.as_user('uas');
select is(pg_temp.run_all(), 3, 'a Unit Admin of a suspended tenant is denied');
select pg_temp.as_user('inactua');
select is(pg_temp.run_all(), 3, 'an inactive Unit Admin is denied');
select pg_temp.as_user('nomem');
select is(pg_temp.run_all(), 3, 'a caller with no membership is denied');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('nomem') and reason = 'no_membership' and tenant_id is null), 3, 'no-membership denials audited without a tenant');
select results_eq($$ select (select count(*) from public.assignment_version), (select count(*) from public.assignment_cover), (select count(*) from public.audit_event where action <> 'access.denied') $$,
  $$ select v, c, a from before_counts $$, 'denied callers changed nothing');

-- Cross-tenant ids ----------------------------------------------------------------------------
select pg_temp.as_user('uax');
create temp table x_calls (n text, q text);
insert into x_calls values
  ('assign_shift', format($$ select public.sh_assign(gen_random_uuid(), %L, %L, array[%L::uuid], current_date + 60) $$, pg_temp.id('shifty'), pg_temp.id('s1'), pg_temp.id('m1'))),
  ('assign_machine', format($$ select public.sh_assign(gen_random_uuid(), %L, %L, array[%L::uuid], current_date + 60) $$, pg_temp.id('day'), pg_temp.id('s1'), pg_temp.id('my'))),
  ('assign_sup', format($$ select public.sh_assign(gen_random_uuid(), %L, %L, array[%L::uuid], current_date + 60) $$, pg_temp.id('day'), pg_temp.id('sy'), pg_temp.id('m1'))),
  ('unassign_shift', format($$ select public.sh_unassign(gen_random_uuid(), %L, array[%L::uuid], current_date + 60) $$, pg_temp.id('shifty'), pg_temp.id('m1'))),
  ('unassign_machine', format($$ select public.sh_unassign(gen_random_uuid(), %L, array[%L::uuid], current_date + 60) $$, pg_temp.id('day'), pg_temp.id('my'))),
  ('cover_shift', format($$ select public.sh_cover(gen_random_uuid(), %L, current_date + 60, array[%L::uuid], %L, 'x') $$, pg_temp.id('shifty'), pg_temp.id('m1'), pg_temp.id('s1'))),
  ('cover_machine', format($$ select public.sh_cover(gen_random_uuid(), %L, current_date + 60, array[%L::uuid, %L::uuid], %L, 'x') $$, pg_temp.id('day'), pg_temp.id('m1'), pg_temp.id('my'), pg_temp.id('s1'))),
  ('cover_sup', format($$ select public.sh_cover(gen_random_uuid(), %L, current_date + 60, array[%L::uuid], %L, 'x') $$, pg_temp.id('day'), pg_temp.id('m1'), pg_temp.id('sy')));
create function pg_temp.run_x() returns int language plpgsql as $$
declare c record; ok int := 0; r jsonb;
begin
  for c in select * from x_calls loop
    execute c.q into r;
    if r = '{"ok": false, "code": "not_allowed"}'::jsonb then ok := ok + 1; end if;
  end loop;
  return ok;
end $$;
select is(pg_temp.run_x(), 8, 'every RPC given another tenant''s shift, machine or supervisor returns the generic denial');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('uax') and reason = 'cross_tenant' and tenant_id = pg_temp.id('tx')), 8, 'cross-tenant denials are audited under the caller''s tenant');
select is(public.sh_assign(gen_random_uuid(), pg_temp.id('day'), gen_random_uuid(), array[pg_temp.id('m1')], (select d + 60 from today)), '{"ok": false, "code": "not_allowed"}'::jsonb, 'an unknown supervisor id gives the same generic denial');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('uax') and reason = 'not_found'), 1, 'an unknown id is audited as not_found');
select results_eq($$ select (select count(*) from public.assignment_version), (select count(*) from public.assignment_cover), (select count(*) from public.audit_event where action <> 'access.denied') $$,
  $$ select v, c, a from before_counts $$, 'cross-tenant attempts changed nothing');
-- request id reuse across RPCs
select is((pg_temp.err(format($$ select public.sh_unassign(%L, %L, array[%L::uuid], %L) $$, pg_temp.id('rq_a1'), pg_temp.id('day'), pg_temp.id('m2'), (select d + 20 from today))))->>'field', 'request_id', 'the same request id on another RPC is a validation error');

-- Resolution is tenant-scoped like target_for --------------------------------------------------
select pg_temp.as_user('uay');
select is(app.machine_owner(pg_temp.id('m1'), pg_temp.id('day'), (select d + 1 from today)), null, 'another tenant''s caller resolves nothing');
select is((select count(*)::int from app.machine_owner_src(pg_temp.id('m1'), pg_temp.id('day'), (select d + 1 from today))), 0, 'and gets no row at all');
select set_config('request.jwt.claims', '', true);
select is((select count(*)::int from app.machine_owner_src(pg_temp.id('m1'), pg_temp.id('day'), (select d + 1 from today))), 0, 'no claims at all: no row');
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select is(app.machine_owner(pg_temp.id('m1'), pg_temp.id('day'), (select d + 1 from today)), pg_temp.id('s1'), 'the service role resolves any tenant');
select is((select o.source from app.machine_owner_src(pg_temp.id('m3'), pg_temp.id('day'), (select d + 400 from today)) o), 'none', 'the service role gets source none for an unassigned machine');

-- Called by the real client role --------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c610-0000000000a1","role":"authenticated"}', true);
select is((public.sh_assign(gen_random_uuid(), pg_temp.id('day'), pg_temp.id('s2'), array[pg_temp.id('m4')], (select d + 30 from today)))->>'ok', 'true', 'an authenticated Unit Admin can call sh_assign');
select is((select count(*)::int from public.assignment_version where machine_id = pg_temp.id('m4')), 3, 'and reads the result back under RLS');
reset role;

select * from finish();
rollback;
