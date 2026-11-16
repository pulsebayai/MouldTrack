-- 04 step 6a R2 + R4 (DB part): the site timezone locks once targets exist; request ids are matched per RPC; site races map to a
-- field error; site.timezone is validated by the database. Self-contained; rolled back.
begin;
create extension if not exists pgtap with schema extensions;
select plan(19);

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
  ('00000000-0000-4000-c300-0000000000a1', 'tap12-a@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-c300-0000000000b1', 'tap12-b@example.test', 'authenticated', 'authenticated');
insert into ids values ('ua', '00000000-0000-4000-c300-0000000000a1'), ('ub', '00000000-0000-4000-c300-0000000000b1'),
  ('ta', '50000000-0000-4000-c300-00000000000a'), ('tb', '50000000-0000-4000-c300-00000000000b');
insert into public.tenant (id, name, status, timezone) values
  ('50000000-0000-4000-c300-00000000000a', 'tap12 org A', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c300-00000000000b', 'tap12 org B', 'active', 'Asia/Kolkata');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('50000000-0000-4000-c300-00000000000a', '00000000-0000-4000-c300-0000000000a1', 'unit_admin', 'active', 'UA A', 'UA-A', '+919000017001', false),
  ('50000000-0000-4000-c300-00000000000b', '00000000-0000-4000-c300-0000000000b1', 'unit_admin', 'active', 'UA B', 'UA-B', '+919000017002', false);

-- R2: timezone lock ---------------------------------------------------------------------------------------------
select pg_temp.as_user('ua');
select is((public.pm_save_site(gen_random_uuid(), 'Plant A', 'Asia/Kolkata'))->>'ok', 'true', 'site created');
select is((public.pm_save_site(gen_random_uuid(), 'Plant A', 'UTC'))->>'ok', 'true', 'the timezone can change while no target exists');
select is((public.pm_save_site(gen_random_uuid(), 'Plant A', 'Asia/Kolkata'))->>'ok', 'true', 'and change back');
select is((pg_temp.keep('m', public.pm_save_machine(gen_random_uuid(), null, 'TZ-1', 'Press', null, null, null, null, null, 'active')))->>'ok', 'true', 'machine added');
select is((pg_temp.keep('p', public.pm_save_product(gen_random_uuid(), null, 'TZ-P', 'Cap', 'pcs')))->>'ok', 'true', 'product added');
select is((public.pm_set_target(gen_random_uuid(), pg_temp.id('m'), pg_temp.id('p'), 500, app.plant_date(pg_temp.id('ta'))))->>'ok', 'true', 'a target now exists');
select is((pg_temp.err($$ select public.pm_save_site(gen_random_uuid(), 'Plant A', 'UTC') $$) - 'raised'),
  '{"code":"guard","field":"timezone_locked","message":"The site timezone can''t change once targets exist","sqlstate":"P0001"}'::jsonb,
  'the timezone change is refused once targets exist (guard timezone_locked)');
select is((select timezone from public.site where tenant_id = pg_temp.id('ta')), 'Asia/Kolkata', 'the timezone is unchanged');
select is((public.pm_save_site(gen_random_uuid(), 'Plant A renamed', 'Asia/Kolkata'))->>'ok', 'true', 'a name edit with the same timezone is still allowed');
select is((select count(*)::int from public.audit_event where action = 'site.updated' and tenant_id = pg_temp.id('ta')), 3, 'the refused change wrote no audit row (3 updates succeeded)');
select pg_temp.as_user('ub');
select is((public.pm_save_site(gen_random_uuid(), 'Plant B', 'Asia/Kolkata'))->>'ok', 'true', 'tenant B site created');
select is((public.pm_save_site(gen_random_uuid(), 'Plant B', 'UTC'))->>'ok', 'true', 'the lock is per tenant: B has no targets, so its timezone can change');

-- R4 item 4: the idempotency lookup also matches the RPC (source) -------------------------------------------------
select pg_temp.as_user('ua');
create temp table rid as select gen_random_uuid() as v;
select is((public.pm_save_line((select v from rid), null, 'Line R'))->>'ok', 'true', 'a line is created with a request id');
select is((public.pm_save_line((select v from rid), null, 'Line R')) ->> 'already', 'true', 'the same request id on the same RPC replays');
select is((pg_temp.err(format($$ select public.pm_save_product(%L, null, 'TZ-P2', 'Other', 'pcs') $$, (select v from rid))))->>'sqlstate', '23505',
  'the same request id on a different RPC is not reported as done (it hits the unique audit key)');
select is((select count(*)::int from public.product where tenant_id = pg_temp.id('ta') and code = 'TZ-P2'), 0, 'and creates nothing');

-- R4 item 5: a lost site race maps to a field error ---------------------------------------------------------------
select is((pg_temp.err($$ select app._pm_dup('site_one_per_tenant') $$) - 'message' - 'raised'), '{"code":"guard","field":"site","sqlstate":"P0001"}'::jsonb,
  'the one-site-per-tenant constraint maps to a guard error on site');
select is(pg_get_functiondef('public.pm_save_site(uuid,text,text)'::regprocedure) ~ 'unique_violation', true, 'pm_save_site handles unique_violation');

-- R4 item 6: the database validates site.timezone ------------------------------------------------------------------
reset role;
select set_config('request.jwt.claims', '', true);
select is((pg_temp.err($$ update public.site set timezone = 'Mars/Base' where tenant_id = '50000000-0000-4000-c300-00000000000b' $$))->>'sqlstate', '23514',
  'an invalid timezone is refused by the database');

select * from finish();
rollback;
