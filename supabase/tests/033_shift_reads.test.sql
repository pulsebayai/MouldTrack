-- 05 AC-9..AC-12 (DB part, reads): public.shift_board (Unit Admin only; owners, sources, unassigned, inactive supervisors) and public.my_shift
-- (the caller's own machines; running vs next within 36 h; cover in/out; isolation), plus RLS: a supervisor has no select on the planning tables.
-- Self-contained; rolled back. my_shift takes explicit moments (IST) built from today's plant date.
begin;
create extension if not exists pgtap with schema extensions;
select plan(107);

create temp table ids (k text primary key, v uuid);
create function pg_temp.id(k text) returns uuid language sql as $$ select v from ids where k = $1 $$;
create function pg_temp.as_user(k text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where ids.k = $1), 'role', 'authenticated')::text, true) $$;
create function pg_temp.n_audit(a text, t text) returns int language sql as $$
  select count(*)::int from public.audit_event where action = a and tenant_id = pg_temp.id(t) $$;

-- Fixtures (as postgres) ---------------------------------------------------
insert into auth.users (id, email, aud, role)
select u, 'tap33-' || n || '@example.test', 'authenticated', 'authenticated' from (values
  ('00000000-0000-4000-c630-0000000000a1'::uuid, 'uax'), ('00000000-0000-4000-c630-0000000000a2', 's1'), ('00000000-0000-4000-c630-0000000000a3', 's2'),
  ('00000000-0000-4000-c630-0000000000a4', 's3'), ('00000000-0000-4000-c630-0000000000a5', 'sinact'), ('00000000-0000-4000-c630-0000000000a6', 'freshx'),
  ('00000000-0000-4000-c630-0000000000a7', 'sfresh'), ('00000000-0000-4000-c630-0000000000b1', 'uay'), ('00000000-0000-4000-c630-0000000000b2', 'sy'),
  ('00000000-0000-4000-c630-0000000000d1', 'uas'), ('00000000-0000-4000-c630-0000000000d2', 'ssus'), ('00000000-0000-4000-c630-0000000000c1', 'nomem'),
  ('00000000-0000-4000-c630-0000000000e1', 'uaz'), ('00000000-0000-4000-c630-0000000000e2', 'sz')) t(u, n);
insert into ids values ('uax', '00000000-0000-4000-c630-0000000000a1'), ('s1', '00000000-0000-4000-c630-0000000000a2'), ('s2', '00000000-0000-4000-c630-0000000000a3'),
  ('s3', '00000000-0000-4000-c630-0000000000a4'), ('sinact', '00000000-0000-4000-c630-0000000000a5'), ('freshx', '00000000-0000-4000-c630-0000000000a6'),
  ('sfresh', '00000000-0000-4000-c630-0000000000a7'), ('uay', '00000000-0000-4000-c630-0000000000b1'), ('sy', '00000000-0000-4000-c630-0000000000b2'),
  ('uas', '00000000-0000-4000-c630-0000000000d1'), ('ssus', '00000000-0000-4000-c630-0000000000d2'), ('nomem', '00000000-0000-4000-c630-0000000000c1'),
  ('uaz', '00000000-0000-4000-c630-0000000000e1'), ('sz', '00000000-0000-4000-c630-0000000000e2'),
  ('tx', '50000000-0000-4000-c630-00000000000a'), ('ty', '50000000-0000-4000-c630-00000000000b'), ('ts', '50000000-0000-4000-c630-00000000000d'),
  ('tz', '50000000-0000-4000-c630-00000000000e');
insert into public.tenant (id, name, status, timezone) values
  ('50000000-0000-4000-c630-00000000000a', 'tap33 org X', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c630-00000000000b', 'tap33 org Y', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c630-00000000000d', 'tap33 org S', 'suspended', 'Asia/Kolkata'),
  ('50000000-0000-4000-c630-00000000000e', 'tap33 org Z (no shifts)', 'active', 'Asia/Kolkata');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('50000000-0000-4000-c630-00000000000a', '00000000-0000-4000-c630-0000000000a1', 'unit_admin', 'active', 'UA X', 'UA-X', '+919000020301', false),
  ('50000000-0000-4000-c630-00000000000a', '00000000-0000-4000-c630-0000000000a2', 'supervisor', 'active', 'Sup One', 'S1', '+919000020302', false),
  ('50000000-0000-4000-c630-00000000000a', '00000000-0000-4000-c630-0000000000a3', 'supervisor', 'active', 'Sup Two', 'S2', '+919000020303', false),
  ('50000000-0000-4000-c630-00000000000a', '00000000-0000-4000-c630-0000000000a4', 'supervisor', 'active', 'Sup Three', 'S3', '+919000020304', false),
  ('50000000-0000-4000-c630-00000000000a', '00000000-0000-4000-c630-0000000000a5', 'supervisor', 'inactive', 'Sup Gone', 'S4', '+919000020305', false),
  ('50000000-0000-4000-c630-00000000000a', '00000000-0000-4000-c630-0000000000a6', 'unit_admin', 'active', 'Fresh X', 'FR-X', '+919000020306', true),
  ('50000000-0000-4000-c630-00000000000a', '00000000-0000-4000-c630-0000000000a7', 'supervisor', 'active', 'Sup Fresh', 'S5', '+919000020307', true),
  ('50000000-0000-4000-c630-00000000000b', '00000000-0000-4000-c630-0000000000b1', 'unit_admin', 'active', 'UA Y', 'UA-Y', '+919000020308', false),
  ('50000000-0000-4000-c630-00000000000b', '00000000-0000-4000-c630-0000000000b2', 'supervisor', 'active', 'Sup Y', 'SY', '+919000020309', false),
  ('50000000-0000-4000-c630-00000000000d', '00000000-0000-4000-c630-0000000000d1', 'unit_admin', 'active', 'UA S', 'UA-S', '+919000020310', false),
  ('50000000-0000-4000-c630-00000000000d', '00000000-0000-4000-c630-0000000000d2', 'supervisor', 'active', 'Sup S', 'SS', '+919000020311', false),
  ('50000000-0000-4000-c630-00000000000e', '00000000-0000-4000-c630-0000000000e1', 'unit_admin', 'active', 'UA Z', 'UA-Z', '+919000020312', false),
  ('50000000-0000-4000-c630-00000000000e', '00000000-0000-4000-c630-0000000000e2', 'supervisor', 'active', 'Sup Z', 'SZ', '+919000020313', false);
insert into public.site (id, tenant_id, name, timezone) values
  ('51000000-0000-4000-c630-00000000000a', pg_temp.id('tx'), 'Plant X', 'Asia/Kolkata'),
  ('51000000-0000-4000-c630-00000000000b', pg_temp.id('ty'), 'Plant Y', 'Asia/Kolkata'),
  ('51000000-0000-4000-c630-00000000000e', pg_temp.id('tz'), 'Plant Z', 'Asia/Kolkata');
insert into public.line (id, tenant_id, site_id, name) values ('52000000-0000-4000-c630-00000000000a', pg_temp.id('tx'), '51000000-0000-4000-c630-00000000000a', 'Line 1');
insert into public.machine (id, tenant_id, site_id, line_id, code, name, retired_at) values
  ('53000000-0000-4000-c630-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c630-00000000000a', '52000000-0000-4000-c630-00000000000a', 'M-1', 'Press 1', null),
  ('53000000-0000-4000-c630-0000000000a2', pg_temp.id('tx'), '51000000-0000-4000-c630-00000000000a', '52000000-0000-4000-c630-00000000000a', 'M-2', 'Press 2', null),
  ('53000000-0000-4000-c630-0000000000a3', pg_temp.id('tx'), '51000000-0000-4000-c630-00000000000a', null, 'M-3', 'Press 3', null),
  ('53000000-0000-4000-c630-0000000000a4', pg_temp.id('tx'), '51000000-0000-4000-c630-00000000000a', null, 'M-4', 'Retired press', now()),
  ('53000000-0000-4000-c630-0000000000a5', pg_temp.id('tx'), '51000000-0000-4000-c630-00000000000a', null, 'M-5', 'Press 5', null),
  ('53000000-0000-4000-c630-0000000000b1', pg_temp.id('ty'), '51000000-0000-4000-c630-00000000000b', null, 'Y-1', 'Y press', null);
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time, retired_at) values
  ('54000000-0000-4000-c630-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c630-00000000000a', 'Day', '06:00', '14:00', null),
  ('54000000-0000-4000-c630-0000000000a2', pg_temp.id('tx'), '51000000-0000-4000-c630-00000000000a', 'Night', '22:00', '06:00', null),
  ('54000000-0000-4000-c630-0000000000a3', pg_temp.id('tx'), '51000000-0000-4000-c630-00000000000a', 'Old', '00:00', '23:45', now()),
  ('54000000-0000-4000-c630-0000000000b1', pg_temp.id('ty'), '51000000-0000-4000-c630-00000000000b', 'Y shift', '06:00', '14:00', null);
insert into ids values ('m1', '53000000-0000-4000-c630-0000000000a1'), ('m2', '53000000-0000-4000-c630-0000000000a2'), ('m3', '53000000-0000-4000-c630-0000000000a3'),
  ('m4', '53000000-0000-4000-c630-0000000000a4'), ('m5', '53000000-0000-4000-c630-0000000000a5'), ('my', '53000000-0000-4000-c630-0000000000b1'),
  ('day', '54000000-0000-4000-c630-0000000000a1'), ('night', '54000000-0000-4000-c630-0000000000a2'), ('old', '54000000-0000-4000-c630-0000000000a3'),
  ('shifty', '54000000-0000-4000-c630-0000000000b1');
grant select on ids to authenticated, anon;
create temp table today as select app.plant_date(pg_temp.id('tx')) as d;
grant select on today to authenticated, anon;
-- plan rows written directly (the RPCs refuse past dates): Day m1,m2 -> s1, m3 -> inactive supervisor, m4 (retired) -> s1; Night m1,m5 -> s2; Old (retired) m1 -> s1
insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by)
select pg_temp.id('tx'), pg_temp.id(sh), pg_temp.id(m), pg_temp.id(sup), (select d - 30 from today), pg_temp.id('uax')
from (values ('day', 'm1', 's1'), ('day', 'm2', 's1'), ('day', 'm3', 'sinact'), ('day', 'm4', 's1'), ('night', 'm1', 's2'), ('night', 'm5', 's2'), ('old', 'm1', 's1')) v(sh, m, sup);
-- an IST moment: day offset + HH:MM[:SS]
create function pg_temp.at(off int, t text) returns timestamptz language sql as $$ select ((select d + $1 from today) + $2::time) at time zone 'Asia/Kolkata' $$;
-- my_shift as a user at a moment, summarised as "state:shift:day offset:machine codes"
create function pg_temp.my(u text, off int, t text) returns jsonb language plpgsql as $$
begin
  perform pg_temp.as_user(u);
  return public.my_shift(pg_temp.at(off, t));
end $$;
create function pg_temp.sum(j jsonb) returns text language sql as $$
  select (j->>'state') || ':' || coalesce((select string_agg((o->'shift'->>'name') || ':' || ((o->>'shift_date')::date - (select d from today))::text || ':'
         || coalesce((select string_agg(e->>'code', ',' order by e->>'code') from jsonb_array_elements(o->'machines') e), '-'), '|' order by (o->>'starts_at')::timestamptz, o->'shift'->>'name')
         from jsonb_array_elements(j->'occurrences') o), '-:-:-') $$;
create function pg_temp.board(sh text, off int default 0) returns jsonb language sql as $$ select public.shift_board(pg_temp.id($1), (select d + $2 from today)) $$;
create function pg_temp.brow(b jsonb, code text) returns jsonb language sql as $$ select e from jsonb_array_elements(b->'machines') e where e->>'code' = $2 $$;

-- Privileges ----------------------------------------------------------------------
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('shift_board', 'my_shift')
             and has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute')
             and p.prosecdef and p.proconfig is not null and 'search_path=""' = any (p.proconfig)), 2,
  'both read RPCs are security definer, empty search_path, executable by authenticated and not by anon');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'app' and p.proname = '_sh_read_authorise'
             and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0, 'the read helper is not executable by clients');
set local role anon;
select throws_ok($$ select public.my_shift() $$, '42501', null, 'anon cannot call my_shift');
select throws_ok($$ select public.shift_board(gen_random_uuid()) $$, '42501', null, 'anon cannot call shift_board');
reset role;

-- Shift board (AC-9) ----------------------------------------------------------------------------
select pg_temp.as_user('uax');
create temp table b0 as select pg_temp.board('day', 0) as b;
select is((select b->>'ok' from b0), 'true', 'the board is returned to a Unit Admin');
select is((select jsonb_array_length(b->'machines') from b0), 4, 'it lists every non-retired machine (the retired one is left out)');
select is((select string_agg(e->>'code', ',' order by e->>'code') from b0, jsonb_array_elements(b->'machines') e), 'M-1,M-2,M-3,M-5', 'M-1, M-2, M-3 and M-5');
select is((select b->'shift'->>'name' || ' ' || (b->'shift'->>'start_time') || '-' || (b->'shift'->>'end_time') from b0), 'Day 06:00-14:00', 'the shift is described with HH:MM times');
select is((select (b->>'shift_date')::date from b0), (select d from today), 'the date defaults to today''s plant date');
-- R2: without a date the board shows the current occurrence of the shift, else its next one (computed here independently of the function)
create function pg_temp.cur_or_next(sh text) returns date language sql as $$
  select min(x.d) from (select ((select d from today) + g) as d from generate_series(-1, 1) g) x
   where upper(app.shift_window(pg_temp.id($1), x.d)) > now() $$;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
create temp table dflt as select pg_temp.cur_or_next('day') as dday, pg_temp.cur_or_next('night') as dnight;
select pg_temp.as_user('uax');
select is((select (public.shift_board(pg_temp.id('day')))->>'shift_date' from b0), (select dday::text from dflt), 'R2: a null date means the current or next occurrence of the shift (Day)');
select is((select (public.shift_board(pg_temp.id('night'), null))->>'shift_date'), (select dnight::text from dflt), 'R2: for the overnight shift too (it may be the one that started yesterday)');
select ok((select upper(app.shift_window(pg_temp.id('day'), dday)) > now() and upper(app.shift_window(pg_temp.id('day'), dday - 1)) <= now() from dflt), 'R2: it is the first occurrence that has not ended');
select is((select (public.shift_board(pg_temp.id('day'), (select d - 3 from today)))->>'shift_date'), (select (d - 3)::text from today), 'R2: an explicit date is honoured, even a past one');
select results_eq($$ select (b->>'starts_at')::timestamptz, (b->>'ends_at')::timestamptz from b0 $$,
  $$ select lower(app.shift_window(pg_temp.id('day'), (select d from today))), upper(app.shift_window(pg_temp.id('day'), (select d from today))) $$, 'it carries the occurrence window');
select is((select pg_temp.brow(b, 'M-1')->>'owner_name' from b0), 'Sup One', 'M-1 is owned by Sup One');
select is((select pg_temp.brow(b, 'M-1')->>'source' from b0), 'plan', 'from the plan');
select is((select pg_temp.brow(b, 'M-1')->>'line' from b0), 'Line 1', 'with its line');
select is((select pg_temp.brow(b, 'M-3')->>'line' from b0), null, 'a machine without a line has none');
select is((select pg_temp.brow(b, 'M-5')->>'source' from b0), 'none', 'M-5 has no owner');
select is((select pg_temp.brow(b, 'M-5')->'owner_id' from b0), 'null'::jsonb, 'its owner id is null');
select is((select (b->>'unassigned_count')::int from b0), 1, 'one machine is unassigned this shift');
select is((select (pg_temp.brow(b, 'M-3')->>'owner_inactive')::boolean from b0), true, 'AC-6: an inactive supervisor is flagged');
select is((select (pg_temp.brow(b, 'M-3')->>'source') from b0), 'plan', 'AC-6: and the machine is still counted as assigned');
select is((select (pg_temp.brow(b, 'M-1')->>'owner_inactive')::boolean from b0), false, 'an active supervisor is not flagged');
select is((select pg_temp.board('day', -31)->>'unassigned_count'), '4', 'before the plan starts every machine is unassigned');
select is((select pg_temp.board('night', 0)->>'unassigned_count'), '2', 'the board is per shift (Night: M-2 and M-3 have no owner)');
select is((select pg_temp.brow(pg_temp.board('night', 0), 'M-1')->>'owner_name'), 'Sup Two', 'Night M-1 belongs to Sup Two');
-- covers
select public.sh_cover(gen_random_uuid(), pg_temp.id('day'), (select d + 1 from today), array[pg_temp.id('m2'), pg_temp.id('m1')], pg_temp.id('s2'), 'Sup One on leave');
select public.sh_cover(gen_random_uuid(), pg_temp.id('day'), (select d + 1 from today), array[pg_temp.id('m1')], null, 'Machine moved to Night only');
create temp table b1 as select pg_temp.board('day', 1) as b;
select is((select pg_temp.brow(b, 'M-2')->>'owner_name' || ':' || (pg_temp.brow(b, 'M-2')->>'source') || ':' || (pg_temp.brow(b, 'M-2')->>'reason') from b1), 'Sup Two:cover:Sup One on leave', 'a cover shows its owner, source and reason');
select is((select pg_temp.brow(b, 'M-1')->>'source' || ':' || (pg_temp.brow(b, 'M-1')->'owner_id')::text from b1), 'cover:null', 'a cover to unassigned: source cover, no owner');
select is((select (b->>'unassigned_count')::int from b1), 2, 'a machine covered to unassigned counts as unassigned (with M-5)');
select is((select pg_temp.brow(pg_temp.board('day', 2), 'M-2')->>'owner_name'), 'Sup One', 'the cover applies to its date only');
-- the board and app.machine_owner agree for every machine and date
select is((select count(*)::int from (select c, e.d from (values ('m1'), ('m2'), ('m3'), ('m5')) c(c), (values (0), (1), (2), (-31)) e(d)) x
           where ((pg_temp.brow(pg_temp.board('day', x.d), (select code from public.machine where id = pg_temp.id(x.c)))->>'owner_id')::uuid)
                 is distinct from app.machine_owner(pg_temp.id(x.c), pg_temp.id('day'), (select d + x.d from today))), 0,
  'the board agrees with app.machine_owner for every machine and date');
select is((pg_temp.board('old', 0))->'shift'->>'retired', 'true', 'a retired shift can still be viewed');
-- no writes
select is((select count(*)::int from public.audit_event where tenant_id = pg_temp.id('tx') and action not in ('assignment.covered')), 0, 'reading the board writes nothing');
-- denials
create temp table before_counts as select (select count(*) from public.assignment_version) v, (select count(*) from public.assignment_cover) c;
select pg_temp.as_user('s1');
select is(public.shift_board(pg_temp.id('day')), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a supervisor gets the generic denial');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('s1') and reason = 'role' and tenant_id = pg_temp.id('tx')
           and source = 'rpc:shift_board' and request_id is null), 1, 'and it is audited (reason role)');
select pg_temp.as_user('freshx');
select is(public.shift_board(pg_temp.id('day')), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a Unit Admin with a temporary password is denied');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('freshx') and reason = 'must_change_password'), 1, 'audited as must_change_password');
select pg_temp.as_user('uas');
select is(public.shift_board(gen_random_uuid()), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a Unit Admin of a suspended tenant is denied');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('uas') and reason = 'inactive'), 1, 'audited as inactive');
select pg_temp.as_user('nomem');
select is(public.shift_board(pg_temp.id('day')), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a caller with no membership is denied');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('nomem') and reason = 'no_membership' and tenant_id is null), 1, 'audited without a tenant');
select pg_temp.as_user('uay');
select is(public.shift_board(pg_temp.id('day')), '{"ok": false, "code": "not_allowed"}'::jsonb, 'another tenant''s Unit Admin asking for X''s shift is denied');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('uay') and reason = 'cross_tenant' and tenant_id = pg_temp.id('ty')), 1, 'audited as cross_tenant under the caller''s tenant');
select is(public.shift_board(gen_random_uuid()), '{"ok": false, "code": "not_allowed"}'::jsonb, 'an unknown shift id is the same generic denial');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('uay') and reason = 'not_found'), 1, 'audited as not_found');
select is((select (pg_temp.board('shifty', 0))->>'unassigned_count'), '1', 'tenant Y sees only its own machine on its own shift');
select results_eq($$ select (select count(*) from public.assignment_version), (select count(*) from public.assignment_cover) $$, $$ select v, c from before_counts $$, 'denied reads changed nothing');

-- My shift (AC-10, AC-11) ------------------------------------------------------------------------------
-- state:shift:day offset:machines
select is(pg_temp.sum(pg_temp.my('s1', 0, '07:00')), 'running:Day:0:M-1,M-2', 'a supervisor sees the running shift and only their machines (the retired M-4 and the inactive owner''s M-3 are not theirs)');
select results_eq($$ select e->>'code', e->>'name', e->>'line' from jsonb_array_elements((pg_temp.my('s1', 0, '07:00'))->'occurrences'->0->'machines') e order by 1 $$,
  $$ values ('M-1'::text, 'Press 1'::text, 'Line 1'::text), ('M-2', 'Press 2', 'Line 1') $$, 'each machine carries code, name and line');
select results_eq($$ select (j->'shift'->>'start_time'), (j->'shift'->>'end_time'), (j->>'starts_at')::timestamptz, (j->>'ends_at')::timestamptz from (select pg_temp.my('s1', 0, '07:00')->'occurrences'->0 j) x $$,
  $$ values ('06:00'::text, '14:00'::text, pg_temp.at(0, '06:00'), pg_temp.at(0, '14:00')) $$, 'the window is given as HH:MM and as instants');
select is(pg_temp.sum(pg_temp.my('s1', 0, '06:00')), 'running:Day:0:M-1,M-2', 'the start minute is inside');
select is(pg_temp.sum(pg_temp.my('s1', 0, '13:59:59')), 'running:Day:0:M-1,M-2', 'one second before the end is inside');
select is(pg_temp.sum(pg_temp.my('s1', 0, '14:00')), 'none:-:-:-', 'the end minute is outside; tomorrow''s Day was covered away from Sup One and the day after is beyond 36 hours');
select is(pg_temp.sum(pg_temp.my('s1', 0, '05:00')), 'next:Day:0:M-1,M-2', 'before the shift today: next is today''s occurrence');
select is(pg_temp.sum(pg_temp.my('s1', 0, '23:00')), 'next:Day:2:M-1,M-2', 'in the evening: tomorrow''s Day is covered away, so the day after is next (Old is retired and never shown)');
select is(pg_temp.my('s1', 0, '07:00')->>'state', 'running', 'a retired shift never wins over the running one');
-- overnight
select is(pg_temp.sum(pg_temp.my('s2', 0, '07:00')), 'next:Night:0:M-1,M-5', 'Sup Two at 07:00: the Night shift that ended at 06:00 is gone, tonight''s is next');
select is(pg_temp.sum(pg_temp.my('s2', 0, '23:00')), 'running:Night:0:M-1,M-5', 'at 23:00 the Night shift is running');
select is(pg_temp.sum(pg_temp.my('s2', 1, '01:00')), 'running:Night:0:M-1,M-5', 'at 01:00 the next day it is still the occurrence that started yesterday');
select is(pg_temp.sum(pg_temp.my('s2', 1, '05:59:59')), 'running:Night:0:M-1,M-5', 'one second before 06:00: still running');
select is(pg_temp.sum(pg_temp.my('s2', 1, '06:00')), 'running:Day:1:M-2', 'at 06:00 the Night shift ended; the Day shift begins and Sup Two covers M-2 (cover in)');
select is(pg_temp.sum(pg_temp.my('s2', 1, '14:30')), 'next:Night:1:M-1,M-5', 'after the Day shift: tonight''s Night is next');
-- nothing assigned / no shifts
select is(pg_temp.sum(pg_temp.my('s3', 0, '07:00')), 'none:-:-:-', 'a supervisor with nothing assigned');
select is(pg_temp.my('sz', 0, '07:00')->>'state', 'no_shifts', 'a tenant without shifts');
select is(pg_temp.my('sy', 0, '07:00')->>'state', 'none', 'another tenant''s supervisor sees nothing of tenant X');
select is(pg_temp.my('uax', 0, '07:00')->>'state', 'none', 'a Unit Admin who owns no machines gets state none');
-- plans that start later and the 36-hour horizon
insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by)
values (pg_temp.id('tx'), pg_temp.id('day'), pg_temp.id('m5'), pg_temp.id('s3'), (select d + 4 from today), pg_temp.id('uax'));
select is(pg_temp.my('s3', 2, '07:00')->>'state', 'none', 'a plan that starts 47 hours away is beyond the 36-hour horizon');
select is(pg_temp.sum(pg_temp.my('s3', 3, '07:00')), 'next:Day:4:M-5', 'the same plan 23 hours away is the next shift');
select is(pg_temp.sum(pg_temp.my('s3', 4, '07:00')), 'running:Day:4:M-5', 'and running on its day');
-- cover in and out (AC-4, AC-10): Day tomorrow, M-1 -> unassigned, M-2 -> Sup Two (from the two covers above)
select is(pg_temp.my('s1', 1, '07:00')->>'state', 'next', 'tomorrow''s Day: Sup One owns nothing, so the next occurrence they own is shown (the day after)');
select is(pg_temp.sum(pg_temp.my('s1', 1, '07:00')), 'next:Day:2:M-1,M-2', 'and it is the day after tomorrow with both machines back on the plan');
select is(pg_temp.sum(pg_temp.my('s2', 1, '07:00')), 'running:Day:1:M-2', 'Sup Two covers M-2 tomorrow: it appears for them (M-1 went to unassigned)');
select is(pg_temp.sum(pg_temp.my('s2', 0, '07:00')), 'next:Night:0:M-1,M-5', 'and the cover does not leak into today');
-- retired machine and retired shift never appear
select is((select count(*)::int from jsonb_array_elements((pg_temp.my('s1', 0, '07:00'))->'occurrences'->0->'machines') e where e->>'code' = 'M-4'), 0, 'a retired machine never appears');
-- denials
create temp table calls (n text, q text);
select pg_temp.as_user('freshx');
select is(public.my_shift(), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a user with a temporary password is denied');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('freshx') and reason = 'must_change_password' and source = 'rpc:my_shift'), 1, 'and it is audited');
select pg_temp.as_user('sfresh');
select is(public.my_shift(), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a supervisor with a temporary password is denied');
select pg_temp.as_user('ssus');
select is(public.my_shift(), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a supervisor of a suspended tenant is denied');
select pg_temp.as_user('sinact');
select is(public.my_shift(), '{"ok": false, "code": "not_allowed"}'::jsonb, 'an inactive supervisor is denied');
select pg_temp.as_user('nomem');
select is(public.my_shift(), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a caller with no membership is denied');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and source = 'rpc:my_shift'), 5, 'five denials audited in all');

-- RLS: a supervisor cannot read the planning tables, only shifts (AC-11) --------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.id('s1'), 'role', 'authenticated')::text, true);
select is((select count(*)::int from public.assignment_version), 0, 'a supervisor reads no plan versions');
select is((select count(*)::int from public.assignment_cover), 0, 'a supervisor reads no covers');
select is((select count(*)::int from public.target_override_version), 0, 'a supervisor reads no target overrides');
select is((select count(*)::int from public.shift), 3, 'a supervisor reads the tenant''s shifts');
select is(pg_temp.sum(public.my_shift(pg_temp.at(0, '07:00'))), 'running:Day:0:M-1,M-2', 'and my_shift works under the client role');
select is(public.shift_board(pg_temp.id('day')), '{"ok": false, "code": "not_allowed"}'::jsonb, 'shift_board under the client role: a supervisor is denied');
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.id('uax'), 'role', 'authenticated')::text, true);
select is((select count(*)::int from public.assignment_version), 8, 'a Unit Admin reads the tenant''s plan versions');
select is((pg_temp.board('day', 0))->>'ok', 'true', 'and the board under the client role');
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.id('uay'), 'role', 'authenticated')::text, true);
select is((select count(*)::int from public.assignment_version) + (select count(*)::int from public.assignment_cover), 0, 'tenant Y''s Unit Admin reads none of X''s planning rows');
reset role;

-- R5: the board also carries the plan owner (ignoring covers) where an assignment made now would start, and the plan changes scheduled after it ----------
select pg_temp.as_user('uax');
create temp table b1b as select pg_temp.board('day', 1) as b;
select is((select (b->>'plan_date')::date from b1b), (select d + 1 from today), 'R5: plan_date is the board date when that occurrence has not started');
select is((select pg_temp.brow(b, 'M-1')->>'plan_owner_name' || ':' || (pg_temp.brow(b, 'M-1')->'owner_id')::text from b1b), 'Sup One:null', 'R5: M-1 is covered to nobody tomorrow, but the plan owner is still Sup One (who loses it)');
select is((select pg_temp.brow(b, 'M-5')->'plan_owner_id' from b1b), 'null'::jsonb, 'R5: a machine without a plan has no plan owner');
select is((select pg_temp.brow(b, 'M-5')->'later_dates' from b1b), to_jsonb(array[(select (d + 4)::text from today)]), 'R5: later_dates lists the plan changes already scheduled after plan_date');
select is((select pg_temp.brow(b, 'M-1')->'later_dates' from b1b), '[]'::jsonb, 'R5: and is empty when there are none');
select is((select (pg_temp.board('day', 0)->>'plan_date')::date), (select case when lower(app.shift_window(pg_temp.id('day'), d)) > now() then d else d + 1 end from today), 'R5: for today''s board it is today when Day has not started, else tomorrow');
select is((select (pg_temp.board('day', -31)->>'plan_date')::date), (select case when lower(app.shift_window(pg_temp.id('day'), d)) > now() then d else d + 1 end from today), 'R5: for a past date it is the first occurrence that has not started');

-- R3 + R8-9: every running occurrence the caller owns machines in; one set-based query over 300 machines ------------------------------------------------
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time) values
  ('54000000-0000-4000-c630-0000000000e1', pg_temp.id('tz'), '51000000-0000-4000-c630-00000000000e', 'Zone A', '06:00', '14:00'),
  ('54000000-0000-4000-c630-0000000000e2', pg_temp.id('tz'), '51000000-0000-4000-c630-00000000000e', 'Zone B', '10:00', '18:00');
insert into ids values ('za', '54000000-0000-4000-c630-0000000000e1'), ('zb', '54000000-0000-4000-c630-0000000000e2');
insert into public.machine (tenant_id, site_id, code, name)
select pg_temp.id('tz'), '51000000-0000-4000-c630-00000000000e', 'Z-' || lpad(n::text, 3, '0'), 'Zone press ' || n from generate_series(1, 300) n;
insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by)
select pg_temp.id('tz'), pg_temp.id('za'), m.id, pg_temp.id('sz'), (select d - 30 from today), pg_temp.id('uaz') from public.machine m where m.tenant_id = pg_temp.id('tz');
insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by)
select pg_temp.id('tz'), pg_temp.id('zb'), m.id, pg_temp.id('sz'), (select d - 30 from today), pg_temp.id('uaz') from public.machine m where m.tenant_id = pg_temp.id('tz') and m.code in ('Z-001', 'Z-002');
-- on Zone B today: Z-001 is covered away, Z-003 is covered in
insert into public.assignment_cover (tenant_id, shift_id, shift_date, machine_id, supervisor_id, reason, recorded_by)
select pg_temp.id('tz'), pg_temp.id('zb'), (select d from today), m.id, case m.code when 'Z-003' then pg_temp.id('sz') end, 'test', pg_temp.id('uaz')
  from public.machine m where m.tenant_id = pg_temp.id('tz') and m.code in ('Z-001', 'Z-003');
create function pg_temp.zsum(t text, off int default 0) returns text language sql as $$
  select (j->>'state') || ':' || coalesce((select string_agg((o->'shift'->>'name') || ':' || ((o->>'shift_date')::date - (select d from today))::text || ':' || jsonb_array_length(o->'machines'), '|'
         order by (o->>'starts_at')::timestamptz) from jsonb_array_elements(j->'occurrences') o), '-')
  from (select pg_temp.my('sz', off, t) as j) x $$;
select is(pg_temp.zsum('12:00'), 'running:Zone A:0:300|Zone B:0:2', 'R3: two overlapping running occurrences are both returned (300 machines, and Zone B with the cover in and the cover out applied)');
select is((select string_agg(e->>'code', ',' order by e->>'code') from jsonb_array_elements((pg_temp.my('sz', 0, '12:00'))->'occurrences'->1->'machines') e), 'Z-002,Z-003', 'R3: Zone B holds Z-002 (plan) and Z-003 (cover in), not Z-001 (cover out)');
select is(pg_temp.zsum('15:00'), 'running:Zone B:0:2', 'R3: once Zone A has ended only the running one is returned');
select is(pg_temp.zsum('19:00'), 'next:Zone A:1:300', 'R3: with nothing running, only the next occurrence: Zone A tomorrow, not also Zone B');
select is(pg_temp.zsum('09:00'), 'running:Zone A:0:300', 'R3: Zone B has not started, so it is not listed next to the running one');
select is(pg_temp.zsum('05:00'), 'next:Zone A:0:300', 'R3: before both, the earliest next');
select is((select count(*)::int from public.machine where tenant_id = pg_temp.id('tz')), 300, 'R8-9: the tenant has 300 machines and my_shift answered above in one query (no timing assertion)');
-- the inline owner resolution of my_shift and app.machine_owner agree
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select is((select count(*)::int from public.machine m where m.tenant_id = pg_temp.id('tz') and app.machine_owner(m.id, pg_temp.id('za'), (select d from today)) = pg_temp.id('sz')), 300, 'R8-9: app.machine_owner agrees on Zone A');
select is((select string_agg(m.code, ',' order by m.code) from public.machine m where m.tenant_id = pg_temp.id('tz') and app.machine_owner(m.id, pg_temp.id('zb'), (select d from today)) = pg_temp.id('sz')), 'Z-002,Z-003', 'R8-9: and on Zone B (cover in and out)');

select * from finish();
rollback;
