-- 05 AC-1, AC-2, AC-12 (DB part, shifts): the shift master, sh_save_shift / sh_set_shift_retired, shift_window / current_occurrences
-- at boundaries (day and overnight shifts), the time lock, RLS, audited denials, idempotency, isolation.
-- Self-contained; rolled back. Everything runs as postgres with the caller's JWT claims set (the RPCs are security definer and key on auth.uid()).
begin;
create extension if not exists pgtap with schema extensions;
select plan(114);

create temp table ids (k text primary key, v uuid);
create function pg_temp.id(k text) returns uuid language sql as $$ select v from ids where k = $1 $$;
create function pg_temp.as_user(k text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where ids.k = $1), 'role', 'authenticated')::text, true) $$;
create function pg_temp.as_service() returns void language sql as $$ select set_config('request.jwt.claims', '{"role":"service_role"}', true) $$;
create function pg_temp.keep(k text, r jsonb) returns jsonb language plpgsql as $$ begin insert into ids values (k, (r->>'id')::uuid); return r; end $$;
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
-- the occurrences running at a moment for one tenant, as "name:date" strings (service role sees every tenant)
create function pg_temp.occ(t text, at timestamptz) returns text language sql as $$
  select coalesce(string_agg(s.name || ':' || o.shift_date, ',' order by s.name), 'none')
  from app.current_occurrences(at) o join public.shift s on s.id = o.shift_id where o.tenant_id = pg_temp.id(t) $$;

-- Fixtures (as postgres) ---------------------------------------------------
insert into auth.users (id, email, aud, role)
select u, 'tap30-' || n || '@example.test', 'authenticated', 'authenticated' from (values
  ('00000000-0000-4000-c600-0000000000a1'::uuid, 'uax'), ('00000000-0000-4000-c600-0000000000a2', 'supx'), ('00000000-0000-4000-c600-0000000000a3', 'freshx'),
  ('00000000-0000-4000-c600-0000000000a4', 'inactx'), ('00000000-0000-4000-c600-0000000000b1', 'uay'), ('00000000-0000-4000-c600-0000000000d1', 'uas'),
  ('00000000-0000-4000-c600-0000000000c1', 'nomem'), ('00000000-0000-4000-c600-0000000000e1', 'uaw'), ('00000000-0000-4000-c600-0000000000f1', 'uan')) t(u, n);
insert into ids values ('uax', '00000000-0000-4000-c600-0000000000a1'), ('supx', '00000000-0000-4000-c600-0000000000a2'), ('freshx', '00000000-0000-4000-c600-0000000000a3'),
  ('inactx', '00000000-0000-4000-c600-0000000000a4'), ('uay', '00000000-0000-4000-c600-0000000000b1'), ('uas', '00000000-0000-4000-c600-0000000000d1'),
  ('nomem', '00000000-0000-4000-c600-0000000000c1'), ('uaw', '00000000-0000-4000-c600-0000000000e1'), ('uan', '00000000-0000-4000-c600-0000000000f1'),
  ('tx', '50000000-0000-4000-c600-00000000000a'), ('ty', '50000000-0000-4000-c600-00000000000b'), ('ts', '50000000-0000-4000-c600-00000000000d'),
  ('tw', '50000000-0000-4000-c600-00000000000e'), ('tn', '50000000-0000-4000-c600-00000000000f');
insert into public.tenant (id, name, status, timezone) values
  ('50000000-0000-4000-c600-00000000000a', 'tap30 org X', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c600-00000000000b', 'tap30 org Y', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c600-00000000000d', 'tap30 org S', 'suspended', 'Asia/Kolkata'),
  ('50000000-0000-4000-c600-00000000000e', 'tap30 org W (no site)', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c600-00000000000f', 'tap30 org N (New York)', 'active', 'America/New_York');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('50000000-0000-4000-c600-00000000000a', '00000000-0000-4000-c600-0000000000a1', 'unit_admin', 'active', 'UA X', 'UA-X', '+919000020001', false),
  ('50000000-0000-4000-c600-00000000000a', '00000000-0000-4000-c600-0000000000a2', 'supervisor', 'active', 'SUP X', 'SUP-X', '+919000020002', false),
  ('50000000-0000-4000-c600-00000000000a', '00000000-0000-4000-c600-0000000000a3', 'unit_admin', 'active', 'Fresh X', 'FR-X', '+919000020003', true),
  ('50000000-0000-4000-c600-00000000000a', '00000000-0000-4000-c600-0000000000a4', 'unit_admin', 'inactive', 'Gone X', 'GO-X', '+919000020004', false),
  ('50000000-0000-4000-c600-00000000000b', '00000000-0000-4000-c600-0000000000b1', 'unit_admin', 'active', 'UA Y', 'UA-Y', '+919000020005', false),
  ('50000000-0000-4000-c600-00000000000d', '00000000-0000-4000-c600-0000000000d1', 'unit_admin', 'active', 'UA S', 'UA-S', '+919000020006', false),
  ('50000000-0000-4000-c600-00000000000e', '00000000-0000-4000-c600-0000000000e1', 'unit_admin', 'active', 'UA W', 'UA-W', '+919000020007', false),
  ('50000000-0000-4000-c600-00000000000f', '00000000-0000-4000-c600-0000000000f1', 'unit_admin', 'active', 'UA N', 'UA-N', '+919000020008', false);
insert into public.site (id, tenant_id, name, timezone) values
  ('51000000-0000-4000-c600-00000000000a', '50000000-0000-4000-c600-00000000000a', 'Plant X', 'Asia/Kolkata'),
  ('51000000-0000-4000-c600-00000000000b', '50000000-0000-4000-c600-00000000000b', 'Plant Y', 'Asia/Kolkata'),
  ('51000000-0000-4000-c600-00000000000d', '50000000-0000-4000-c600-00000000000d', 'Plant S', 'Asia/Kolkata'),
  ('51000000-0000-4000-c600-00000000000f', '50000000-0000-4000-c600-00000000000f', 'Plant N', 'America/New_York');
insert into public.machine (id, tenant_id, site_id, code, name) values
  ('53000000-0000-4000-c600-00000000000a', '50000000-0000-4000-c600-00000000000a', '51000000-0000-4000-c600-00000000000a', 'M-1', 'Press 1');
insert into ids values ('mx1', '53000000-0000-4000-c600-00000000000a');

-- Structure and privileges ----------------------------------------------------------
select is((select count(*)::int from app.audit_action where feature = '05'), 9, 'the 9 actions of 05 are registered');
select is((select count(*)::int from pg_class where oid in ('public.shift'::regclass, 'public.assignment_version'::regclass, 'public.assignment_cover'::regclass,
  'public.target_override_version'::regclass) and relrowsecurity and relforcerowsecurity), 4, 'RLS enabled and forced on all four 05 tables');
select col_not_null('public', 'shift', 'tenant_id', 'shift.tenant_id not null');
select col_not_null('public', 'assignment_version', 'tenant_id', 'assignment_version.tenant_id not null');
select col_not_null('public', 'assignment_cover', 'tenant_id', 'assignment_cover.tenant_id not null');
select col_not_null('public', 'target_override_version', 'tenant_id', 'target_override_version.tenant_id not null');
select has_index('public', 'assignment_version', 'assignment_version_lookup_idx', 'plan lookup index exists');
select has_index('public', 'assignment_cover', 'assignment_cover_lookup_idx', 'cover lookup index exists');
select has_index('public', 'target_override_version', 'target_override_lookup_idx', 'override lookup index exists');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('sh_save_shift', 'sh_set_shift_retired')
             and has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute')
             and p.prosecdef and p.proconfig is not null and 'search_path=""' = any (p.proconfig)), 2,
  'both shift RPCs are security definer, empty search_path, executable by authenticated and not by anon');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'app' and p.proname ~ '^(_sh_|shift_window|current_occurrences|sh_)'
             and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')
                  or not p.prosecdef or p.proconfig is null or not ('search_path=""' = any (p.proconfig)))), 0,
  'the 05 app functions are security definer with an empty search_path and not executable by clients');
set local role anon;
select throws_ok($$ select public.sh_save_shift(gen_random_uuid(), null, 'x', '06:00', '14:00') $$, '42501', null, 'anon cannot call sh_save_shift');
reset role;

-- Table rules (direct inserts as postgres) -----------------------------------------------
select throws_ok($$ insert into public.shift (tenant_id, site_id, name, start_time, end_time) values (pg_temp.id('tx'), '51000000-0000-4000-c600-00000000000a', 'Bad', '06:10', '14:00') $$,
  '23514', null, 'start must be on a 15-minute step');
select throws_ok($$ insert into public.shift (tenant_id, site_id, name, start_time, end_time) values (pg_temp.id('tx'), '51000000-0000-4000-c600-00000000000a', 'Bad', '06:00', '14:05') $$,
  '23514', null, 'end must be on a 15-minute step');
select throws_ok($$ insert into public.shift (tenant_id, site_id, name, start_time, end_time) values (pg_temp.id('tx'), '51000000-0000-4000-c600-00000000000a', 'Bad', '06:00:30', '14:00') $$,
  '23514', null, 'seconds are refused');
select throws_ok($$ insert into public.shift (tenant_id, site_id, name, start_time, end_time) values (pg_temp.id('tx'), '51000000-0000-4000-c600-00000000000a', 'Bad', '06:00', '06:00') $$,
  '23514', null, 'end equal to start is refused');
select throws_ok($$ insert into public.shift (tenant_id, site_id, name, start_time, end_time) values (pg_temp.id('tx'), '51000000-0000-4000-c600-00000000000a', 'Bad', '24:00', '06:00') $$,
  '23514', null, '24:00 is not a valid start');
select throws_ok($$ insert into public.shift (tenant_id, site_id, name, start_time, end_time) values (pg_temp.id('tx'), '51000000-0000-4000-c600-00000000000a', ' Pad ', '06:00', '14:00') $$,
  '23514', null, 'the name must be trimmed');
select throws_ok($$ insert into public.shift (tenant_id, site_id, name, start_time, end_time) values (pg_temp.id('tx'), '51000000-0000-4000-c600-00000000000b', 'Cross', '06:00', '14:00') $$,
  '23503', null, 'composite FK: a shift cannot use another tenant''s site');
select lives_ok($$ insert into public.shift (id, tenant_id, site_id, name, start_time, end_time) values ('54000000-0000-4000-c600-00000000000a', pg_temp.id('tx'), '51000000-0000-4000-c600-00000000000a', 'Direct', '23:45', '00:00') $$,
  'an overnight 15-minute shift is valid');
select throws_ok($$ insert into public.shift (tenant_id, site_id, name, start_time, end_time) values (pg_temp.id('tx'), '51000000-0000-4000-c600-00000000000a', 'DIRECT', '06:00', '14:00') $$,
  '23505', null, 'shift name is unique per site, case-insensitive');

update public.shift set retired_at = now() where name = 'Direct';
grant select on ids to authenticated, anon;

-- Occurrence maths (AC-2): fixed shifts in tenant X (Asia/Kolkata, UTC+5:30) and tenant N (America/New_York) ---------------
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time) values
  ('54000000-0000-4000-c600-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c600-00000000000a', 'Morning', '06:00', '14:00'),
  ('54000000-0000-4000-c600-0000000000a2', pg_temp.id('tx'), '51000000-0000-4000-c600-00000000000a', 'Night', '22:00', '06:00'),
  ('54000000-0000-4000-c600-0000000000a3', pg_temp.id('tx'), '51000000-0000-4000-c600-00000000000a', 'Old', '00:00', '12:00'),
  ('54000000-0000-4000-c600-0000000000f1', pg_temp.id('tn'), '51000000-0000-4000-c600-00000000000f', 'Early', '01:00', '05:00');
update public.shift set retired_at = now() where name = 'Old';
insert into ids values ('morning', '54000000-0000-4000-c600-0000000000a1'), ('night', '54000000-0000-4000-c600-0000000000a2'), ('early', '54000000-0000-4000-c600-0000000000f1');
select pg_temp.as_service();
select results_eq($$ select lower(w), upper(w) from (select app.shift_window(pg_temp.id('morning'), date '2026-03-10') as w) x $$, $$ values (timestamptz '2026-03-10 00:30:00+00', timestamptz '2026-03-10 08:30:00+00') $$, 'day shift: 06:00-14:00 IST on 10 Mar is 00:30-08:30 UTC');
select results_eq($$ select lower(w), upper(w) from (select app.shift_window(pg_temp.id('night'), date '2026-03-10') as w) x $$, $$ values (timestamptz '2026-03-10 16:30:00+00', timestamptz '2026-03-11 00:30:00+00') $$, 'overnight shift: 22:00-06:00 IST ends on the next day');
select results_eq($$ select lower(w), upper(w) from (select app.shift_window(pg_temp.id('early'), date '2026-03-08') as w) x $$, $$ values (timestamptz '2026-03-08 06:00:00+00', timestamptz '2026-03-08 09:00:00+00') $$, 'daylight saving: 01:00 EST to 05:00 EDT on the spring-forward day is 3 real hours');
select is(app.shift_window(gen_random_uuid(), date '2026-03-10'), null, 'an unknown shift has no window');
select is(pg_temp.occ('tx', timestamptz '2026-03-10 00:30:00+00'), 'Morning:2026-03-10', 'start minute is in (06:00 IST); the night shift ended at 06:00');
select is(pg_temp.occ('tx', timestamptz '2026-03-10 00:29:59+00'), 'Night:2026-03-09', 'one second before the start: the night shift that started yesterday is still running');
select is(pg_temp.occ('tx', timestamptz '2026-03-10 08:29:59+00'), 'Morning:2026-03-10', 'one second before the end: still running');
select is(pg_temp.occ('tx', timestamptz '2026-03-10 08:30:00+00'), 'none', 'end minute is out (14:00 IST)');
select is(pg_temp.occ('tx', timestamptz '2026-03-10 16:29:59+00'), 'none', 'a second before 22:00 IST: nothing running');
select is(pg_temp.occ('tx', timestamptz '2026-03-10 16:30:00+00'), 'Night:2026-03-10', '22:00 IST: the night shift starts');
select is(pg_temp.occ('tx', timestamptz '2026-03-10 18:29:00+00'), 'Night:2026-03-10', '23:59 IST: the night shift is running');
select is(pg_temp.occ('tx', timestamptz '2026-03-10 18:30:00+00'), 'Night:2026-03-10', 'midnight IST: still the occurrence that started the day before (shift date = start date)');
select is(pg_temp.occ('tx', timestamptz '2026-03-10 20:00:00+00'), 'Night:2026-03-10', '01:30 IST on the next day: the night shift of the previous plant date');
select is(pg_temp.occ('tx', timestamptz '2026-03-11 00:29:59+00'), 'Night:2026-03-10', 'a second before 06:00 IST next morning: still running');
select is(pg_temp.occ('tn', timestamptz '2026-03-08 06:30:00+00'), 'Early:2026-03-08', 'New York: 01:30 EST is inside 01:00-05:00');
select is(pg_temp.occ('tn', timestamptz '2026-03-08 09:00:00+00'), 'none', 'New York: 05:00 EDT is the end (out)');
select is(pg_temp.occ('tx', timestamptz '2026-03-10 02:00:00+00'), 'Morning:2026-03-10', 'a retired shift (Old, 00:00-12:00) is never current');
select results_eq($$ select o.tenant_id, o.shift_id, o.shift_date, lower(o.span), upper(o.span) from app.current_occurrences(timestamptz '2026-03-10 20:00:00+00') o where o.tenant_id = pg_temp.id('tx') $$,
  $$ values (pg_temp.id('tx'), pg_temp.id('night'), date '2026-03-10', timestamptz '2026-03-10 16:30:00+00', timestamptz '2026-03-11 00:30:00+00') $$,
  'current_occurrences returns tenant, shift, shift date and the window');
select pg_temp.as_user('uay');
select is((select count(*)::int from app.current_occurrences(timestamptz '2026-03-10 20:00:00+00')), 0, 'an authenticated caller only gets its own tenant''s occurrences');
select pg_temp.as_user('uax');
select is((select count(*)::int from app.current_occurrences(timestamptz '2026-03-10 20:00:00+00')), 1, 'the own tenant''s caller gets its occurrence');
select is(app.shift_window(pg_temp.id('early'), date '2026-03-08'), null, 'another tenant''s shift has no window for the caller');
select set_config('request.jwt.claims', '', true);
select is((select count(*)::int from app.current_occurrences(timestamptz '2026-03-10 20:00:00+00')), 0, 'no claims at all: no occurrences (no unauthenticated bypass)');
select is(app.shift_window(pg_temp.id('morning'), date '2026-03-10'), null, 'no claims at all: no window');

-- sh_save_shift (AC-1) --------------------------------------------------------------------
select pg_temp.as_user('uax');
select is((pg_temp.err($$ select public.sh_save_shift(gen_random_uuid(), null, '   ', '06:00', '14:00') $$))->>'field', 'name', 'blank name is refused on field name');
select is((pg_temp.err($$ select public.sh_save_shift(gen_random_uuid(), null, repeat('x', 41), '06:00', '14:00') $$))->>'field', 'name', 'a name over 40 characters is refused');
select is((pg_temp.err($$ select public.sh_save_shift(gen_random_uuid(), null, 'A', '6:00', '14:00') $$))->>'field', 'start_time', 'start must be HH:MM');
select is((pg_temp.err($$ select public.sh_save_shift(gen_random_uuid(), null, 'A', '06:10', '14:00') $$))->>'field', 'start_time', 'start must be on a 15-minute step');
select is((pg_temp.err($$ select public.sh_save_shift(gen_random_uuid(), null, 'A', '06:00', '24:00') $$))->>'field', 'end_time', '24:00 is not a valid end');
select is((pg_temp.err($$ select public.sh_save_shift(gen_random_uuid(), null, 'A', '06:00', '14:20') $$))->>'field', 'end_time', 'end must be on a 15-minute step');
select is((pg_temp.err($$ select public.sh_save_shift(gen_random_uuid(), null, 'A', '06:00', null) $$))->>'field', 'end_time', 'a missing end is refused');
select is((pg_temp.err($$ select public.sh_save_shift(gen_random_uuid(), null, 'A', '06:00', '06:00') $$))->>'field', 'end_time', 'end equal to start is refused');
select is((pg_temp.err($$ select public.sh_save_shift(null, null, 'A', '06:00', '14:00') $$))->>'field', 'request_id', 'a null request id is refused');
insert into ids values ('rq_a', gen_random_uuid());
select is((pg_temp.keep('shift_a', public.sh_save_shift(pg_temp.id('rq_a'), null, '  Shift A  ', '08:00', '16:00')))->>'ok', 'true', 'a day shift is created');
select results_eq($$ select name, start_time::text, end_time::text, site_id, retired_at is null from public.shift where id = pg_temp.id('shift_a') $$,
  $$ values ('Shift A'::text, '08:00:00'::text, '16:00:00'::text, '51000000-0000-4000-c600-00000000000a'::uuid, true) $$, 'name trimmed, times stored, site is the tenant''s');
select is(pg_temp.n_audit('shift.created', 'tx'), 1, 'one audit row');
select results_eq($$ select actor_user_id, after->>'name', after->>'start_time', request_id from public.audit_event where action = 'shift.created' and tenant_id = pg_temp.id('tx') $$,
  $$ values (pg_temp.id('uax'), 'Shift A'::text, '08:00:00'::text, pg_temp.id('rq_a')) $$, 'audited with actor, after and request id');
select is((public.sh_save_shift(pg_temp.id('rq_a'), null, '  Shift A  ', '08:00', '16:00'))->>'already', 'true', 'a repeat reports already done');
select is(pg_temp.n_audit('shift.created', 'tx'), 1, 'the repeat writes no second audit row');
select is((select count(*)::int from public.shift where tenant_id = pg_temp.id('tx') and name = 'Shift A'), 1, 'the repeat creates no second shift');
select is((pg_temp.err($$ select public.sh_save_shift(gen_random_uuid(), null, 'shift a', '08:00', '16:00') $$)) - 'message', '{"code":"duplicate","field":"name","sqlstate":"P0001"}'::jsonb, 'a duplicate name (case-insensitive) is refused on field name');
select is((pg_temp.keep('shift_n', public.sh_save_shift(gen_random_uuid(), null, 'Shift N', '22:00', '06:00')))->>'ok', 'true', 'an overnight shift (end before start) is created');
select is((public.sh_save_shift(gen_random_uuid(), pg_temp.id('shift_a'), 'Shift A2', '07:45', '16:15'))->>'ok', 'true', 'name and times can be changed while there are no assignments');
select results_eq($$ select before->>'name', after->>'name', after->>'start_time', after->>'end_time' from public.audit_event where action = 'shift.updated' and tenant_id = pg_temp.id('tx') $$,
  $$ values ('Shift A'::text, 'Shift A2'::text, '07:45:00'::text, '16:15:00'::text) $$, 'update audited with before and after');
select is((pg_temp.err(format($$ select public.sh_save_shift(gen_random_uuid(), %L, 'shift n', '22:00', '06:00') $$, pg_temp.id('shift_a'))))->>'code', 'duplicate', 'renaming onto another shift''s name is refused');
select is((pg_temp.err(format($$ select public.sh_save_shift(gen_random_uuid(), %L, 'Same', '06:00', '06:00') $$, pg_temp.id('shift_a'))))->>'field', 'end_time', 'update validates times too');

-- time lock (AC-1): once the shift has a plan version or a cover its times are frozen, its name is not
insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by)
values (pg_temp.id('tx'), pg_temp.id('shift_a'), pg_temp.id('mx1'), pg_temp.id('supx'), date '2026-03-01', pg_temp.id('uax'));
select pg_temp.as_user('uax');
select is((pg_temp.err(format($$ select public.sh_save_shift(gen_random_uuid(), %L, 'Shift A2', '08:00', '16:15') $$, pg_temp.id('shift_a'))) - 'message'),
  '{"code":"guard","field":"shift_times_locked","sqlstate":"P0001"}'::jsonb, 'times can''t change once the shift has an assignment');
select is((pg_temp.err(format($$ select public.sh_save_shift(gen_random_uuid(), %L, 'Shift A2', '07:45', '17:00') $$, pg_temp.id('shift_a'))))->>'message',
  'Times can''t change once the shift has assignments. Retire it and create a new shift.', 'the lock message says what to do');
select is((public.sh_save_shift(gen_random_uuid(), pg_temp.id('shift_a'), 'Shift A3', '07:45', '16:15'))->>'ok', 'true', 'a rename with unchanged times is still allowed');
insert into public.assignment_cover (tenant_id, shift_id, shift_date, machine_id, supervisor_id, reason, recorded_by)
values (pg_temp.id('tx'), pg_temp.id('shift_n'), date '2026-03-02', pg_temp.id('mx1'), null, 'test', pg_temp.id('uax'));
select is((pg_temp.err(format($$ select public.sh_save_shift(gen_random_uuid(), %L, 'Shift N', '21:45', '06:00') $$, pg_temp.id('shift_n'))))->>'field', 'shift_times_locked', 'a cover also locks the times');

-- retire / reinstate ---------------------------------------------------------------------
select is((public.sh_set_shift_retired(gen_random_uuid(), pg_temp.id('shift_a'), true))->>'changed', 'true', 'a shift is retired');
select is(pg_temp.n_audit('shift.retired', 'tx'), 1, 'retire is audited');
select is((public.sh_set_shift_retired(gen_random_uuid(), pg_temp.id('shift_a'), true))->>'changed', 'false', 'retiring twice is a no-op');
select is(pg_temp.n_audit('shift.retired', 'tx'), 1, 'the no-op writes no audit row');
select is((pg_temp.err(format($$ select public.sh_save_shift(gen_random_uuid(), %L, 'Edit', '07:45', '16:15') $$, pg_temp.id('shift_a'))))->>'field', 'retired', 'a retired shift cannot be edited');
select results_eq($$ select retired_at is not null from public.shift where id = pg_temp.id('shift_a') $$, $$ values (true) $$, 'retired_at is set');
select is((public.sh_set_shift_retired(gen_random_uuid(), pg_temp.id('shift_a'), false))->>'changed', 'true', 'a shift is reinstated');
select is(pg_temp.n_audit('shift.reinstated', 'tx'), 1, 'reinstate is audited');
select is((pg_temp.err(format($$ select public.sh_set_shift_retired(gen_random_uuid(), %L, null) $$, pg_temp.id('shift_a'))))->>'field', 'retired', 'the retire flag is required');
select is(pg_temp.n_audit('shift.updated', 'tx'), 2, 'two updates were audited (the rename, the rename with unchanged times)');

-- No site yet ------------------------------------------------------------------------------
select pg_temp.as_user('uaw');
select is((pg_temp.err($$ select public.sh_save_shift(gen_random_uuid(), null, 'No site', '06:00', '14:00') $$))->>'field', 'site', 'a shift needs a site first');

-- Tenant Y has its own shifts ------------------------------------------------------------------
select pg_temp.as_user('uay');
select is((pg_temp.keep('shift_y', public.sh_save_shift(gen_random_uuid(), null, 'Shift A', '06:00', '14:00')))->>'ok', 'true', 'the same shift name may exist in another tenant');

-- RLS (clients read, never write) ---------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.id('supx'), 'role', 'authenticated')::text, true);
select is((select count(*)::int from public.shift), 6, 'a supervisor reads the shifts of their own tenant (Morning, Night, Old, Direct, Shift A3, Shift N)');
select is((select count(*)::int from public.shift where tenant_id = pg_temp.id('ty')), 0, 'and none of another tenant''s');
select throws_ok($$ insert into public.shift (tenant_id, site_id, name, start_time, end_time) values ('50000000-0000-4000-c600-00000000000a', '51000000-0000-4000-c600-00000000000a', 'Hack', '06:00', '14:00') $$, '42501', null, 'a client cannot insert a shift');
select throws_ok($$ update public.shift set name = 'Hack' $$, '42501', null, 'a client cannot update a shift');
select throws_ok($$ delete from public.shift $$, '42501', null, 'a client cannot delete a shift');
select is((select count(*)::int from public.assignment_version), 0, 'a supervisor reads no plan versions');
select is((select count(*)::int from public.assignment_cover), 0, 'a supervisor reads no covers');
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.id('uax'), 'role', 'authenticated')::text, true);
select is((select count(*)::int from public.assignment_version), 1, 'a Unit Admin reads their tenant''s plan versions');
select is((select count(*)::int from public.assignment_cover), 1, 'and their covers');
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.id('uay'), 'role', 'authenticated')::text, true);
select is((select count(*)::int from public.shift), 1, 'tenant Y sees only its own shift');
select is((select count(*)::int from public.assignment_version) + (select count(*)::int from public.assignment_cover), 0, 'tenant Y sees none of X''s assignments');
reset role;

-- Denials (AC-12) ---------------------------------------------------------------------------
create temp table calls (n text, q text);
insert into calls values
  ('save', $$ select public.sh_save_shift(gen_random_uuid(), null, 'Nope', '06:00', '14:00') $$),
  ('retire', format($$ select public.sh_set_shift_retired(gen_random_uuid(), %L, true) $$, pg_temp.id('morning')));
create function pg_temp.run_all() returns int language plpgsql as $$
declare c record; ok int := 0; r jsonb;
begin
  for c in select * from calls loop
    execute c.q into r;
    if r = '{"ok": false, "code": "not_allowed"}'::jsonb then ok := ok + 1; end if;
  end loop;
  return ok;
end $$;
create temp table before_counts as select (select count(*) from public.shift) s, (select count(*) from public.audit_event where action <> 'access.denied') a;

select pg_temp.as_user('supx');
select is(pg_temp.run_all(), 2, 'a supervisor gets the generic denial from every shift RPC');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('supx') and reason = 'role'
           and actor_role = 'supervisor' and tenant_id = pg_temp.id('tx') and request_id is null and source like 'rpc:sh_%'), 2, 'each supervisor denial is audited (reason role)');
select pg_temp.as_user('freshx');
select is(pg_temp.run_all(), 2, 'a Unit Admin with a temporary password is denied');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('freshx') and reason = 'must_change_password'), 2, 'must-change denials audited');
select pg_temp.as_user('uas');
select is(pg_temp.run_all(), 2, 'a Unit Admin of a suspended tenant is denied');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('uas') and reason = 'inactive'), 2, 'suspended-tenant denials audited');
select pg_temp.as_user('inactx');
select is(pg_temp.run_all(), 2, 'an inactive Unit Admin is denied');
select pg_temp.as_user('nomem');
select is(pg_temp.run_all(), 2, 'a caller with no membership is denied');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('nomem') and reason = 'no_membership' and tenant_id is null), 2, 'no-membership denials audited without a tenant');
select results_eq($$ select (select count(*) from public.shift), (select count(*) from public.audit_event where action <> 'access.denied') $$,
  $$ select s, a from before_counts $$, 'denied callers changed nothing');

-- Cross-tenant ids -----------------------------------------------------------------------------
select pg_temp.as_user('uax');
select is(public.sh_save_shift(gen_random_uuid(), pg_temp.id('shift_y'), 'Hacked', '06:00', '14:00'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'editing another tenant''s shift gives the generic denial');
select is(public.sh_set_shift_retired(gen_random_uuid(), pg_temp.id('shift_y'), true), '{"ok": false, "code": "not_allowed"}'::jsonb, 'retiring another tenant''s shift gives the generic denial');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('uax') and reason = 'cross_tenant' and tenant_id = pg_temp.id('tx')), 2, 'cross-tenant denials are audited under the caller''s tenant');
select is((select name from public.shift where id = pg_temp.id('shift_y')), 'Shift A', 'tenant Y''s shift was not changed');
select is(public.sh_save_shift(gen_random_uuid(), gen_random_uuid(), 'Ghost', '06:00', '14:00'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'an unknown id gives the same generic denial');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('uax') and reason = 'not_found'), 1, 'an unknown id is audited as not_found');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and request_id is not null), 0, 'denials carry no request id');

-- Request id reuse across RPCs is a validation error, never a 500 or a replay
insert into ids values ('rq_x', gen_random_uuid());
select is((public.sh_save_shift(pg_temp.id('rq_x'), null, 'Reuse', '10:00', '12:00'))->>'ok', 'true', 'a shift saved with a fresh request id');
select is((pg_temp.err(format($$ select public.sh_set_shift_retired(%L, %L, true) $$, pg_temp.id('rq_x'), pg_temp.id('shift_a'))))->>'field', 'request_id', 'the same request id on another RPC is a validation error');

-- Called by the real client role (authenticated -> definer function -> forced-RLS tables)
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c600-0000000000a1","role":"authenticated"}', true);
select is((public.sh_save_shift(gen_random_uuid(), null, 'Via client role', '10:15', '12:15'))->>'ok', 'true', 'an authenticated Unit Admin can call sh_save_shift');
select is((select count(*)::int from public.shift where name = 'Via client role'), 1, 'and reads the result back under RLS');
reset role;

select * from finish();
rollback;
