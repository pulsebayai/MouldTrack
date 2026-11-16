-- 04 step 6a R3: app.target_for has no unauthenticated bypass. The tenant check is skipped only for the service role; no claims,
-- anon and another tenant's JWT all get null. Self-contained; rolled back.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

create temp table ids (k text primary key, v uuid);
create function pg_temp.id(k text) returns uuid language sql as $$ select v from ids where k = $1 $$;
create function pg_temp.as_user(k text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where ids.k = $1), 'role', 'authenticated')::text, true) $$;
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

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-c400-0000000000a1', 'tap13-a@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-c400-0000000000b1', 'tap13-b@example.test', 'authenticated', 'authenticated');
insert into ids values ('ua', '00000000-0000-4000-c400-0000000000a1'), ('ub', '00000000-0000-4000-c400-0000000000b1'),
  ('ta', '50000000-0000-4000-c400-00000000000a'), ('tb', '50000000-0000-4000-c400-00000000000b');
insert into public.tenant (id, name, status, timezone) values
  ('50000000-0000-4000-c400-00000000000a', 'tap13 org A', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c400-00000000000b', 'tap13 org B', 'active', 'Asia/Kolkata');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('50000000-0000-4000-c400-00000000000a', '00000000-0000-4000-c400-0000000000a1', 'unit_admin', 'active', 'UA A', 'UA-A', '+919000018001', false),
  ('50000000-0000-4000-c400-00000000000b', '00000000-0000-4000-c400-0000000000b1', 'unit_admin', 'active', 'UA B', 'UA-B', '+919000018002', false);

select pg_temp.as_user('ua');
select public.pm_save_site(gen_random_uuid(), 'Plant A', 'Asia/Kolkata');
select pg_temp.keep('m', public.pm_save_machine(gen_random_uuid(), null, 'R3-1', 'Press', null, null, null, null, null, 'active'));
select pg_temp.keep('p', public.pm_save_product(gen_random_uuid(), null, 'R3-P', 'Cap', 'pcs'));
select public.pm_set_target(gen_random_uuid(), pg_temp.id('m'), pg_temp.id('p'), 640, app.plant_date(pg_temp.id('ta')));

-- a test-only definer wrapper stands in for a server-side caller; clients cannot execute app.target_for directly
create function public.tap13_target(m uuid, p uuid, d date) returns integer language sql security definer set search_path = '' as $$ select app.target_for(m, p, d) $$;
grant execute on function public.tap13_target(uuid, uuid, date) to anon, authenticated;
create temp table today as select app.plant_date(pg_temp.id('ta')) as d;
grant select on today, ids to anon, authenticated;

select set_config('request.jwt.claims', '', true);
select is(public.tap13_target(pg_temp.id('m'), pg_temp.id('p'), (select d from today)), null, 'no claims at all: null (the old uid-is-null bypass is gone)');
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select is(public.tap13_target(pg_temp.id('m'), pg_temp.id('p'), (select d from today)), null, 'anon claims: null');
set local role anon;
select is(public.tap13_target(pg_temp.id('m'), pg_temp.id('p'), (select d from today)), null, 'the anon database role: null');
reset role;
select pg_temp.as_user('ub');
select is(public.tap13_target(pg_temp.id('m'), pg_temp.id('p'), (select d from today)), null, 'another tenant''s authenticated user: null');
select pg_temp.as_user('ua');
select is(public.tap13_target(pg_temp.id('m'), pg_temp.id('p'), (select d from today)), 640, 'the own tenant''s authenticated user: the target');
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select is(public.tap13_target(pg_temp.id('m'), pg_temp.id('p'), (select d from today)), 640, 'the service role: the target (no tenant check)');
select set_config('request.jwt.claims', '{"role":"service_role","sub":"00000000-0000-4000-c400-0000000000b1"}', true);
select is(public.tap13_target(pg_temp.id('m'), pg_temp.id('p'), (select d from today)), 640, 'the service role stays unrestricted even with a sub claim');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'target_for'
           and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0, 'clients still cannot execute app.target_for directly');

select * from finish();
rollback;
