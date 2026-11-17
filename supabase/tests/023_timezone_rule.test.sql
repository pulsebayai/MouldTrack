-- 03 step 11a F4: one time zone rule everywhere (tenant functions, 04's site trigger and pm_save_site, a new tenant trigger). The shape/prefix rule is tested on
-- its own so it is not vacuous on a server whose zone table has no posix/ or right/ names. Self-contained; rolled back. Phones +91 90000 23xxx.
begin;
create extension if not exists pgtap with schema extensions;
select plan(32);

create function pg_temp.err(q text) returns jsonb language plpgsql as $f$
declare d text; m text; st text;
begin
  execute q;
  return jsonb_build_object('raised', false);
exception when others then
  get stacked diagnostics d = pg_exception_detail, m = message_text, st = returned_sqlstate;
  return coalesce(case when d ~ '^[{]' then d::jsonb end, '{}'::jsonb) || jsonb_build_object('message', m, 'sqlstate', st);
end $f$;

-- Shape and prefix (pure) -------------------------------------------------------------------------------------------------------------------------------
select is(app.timezone_shape_ok('Asia/Kolkata'), true, 'shape: Asia/Kolkata');
select is(app.timezone_shape_ok('UTC'), true, 'shape: UTC');
select is(app.timezone_shape_ok('America/Sao_Paulo'), true, 'shape: America/Sao_Paulo');
select is(app.timezone_shape_ok('Etc/GMT+5'), true, 'shape: Etc/GMT+5');
select is(app.timezone_shape_ok('posix/Asia/Kolkata'), false, 'shape: posix/ refused');
select is(app.timezone_shape_ok('right/UTC'), false, 'shape: right/ refused');
select is(app.timezone_shape_ok('POSIX/Asia/Kolkata'), false, 'shape: prefix refused in any case');
select is(app.timezone_shape_ok('Right/Asia/Dubai'), false, 'shape: Right/ refused');
select is(app.timezone_shape_ok(''), false, 'shape: empty refused');
select is(app.timezone_shape_ok(null), false, 'shape: null refused');
select is(app.timezone_shape_ok('Asia/Kolkata; drop table x'), false, 'shape: malformed refused');
select is(app.timezone_shape_ok(' Asia/Kolkata'), false, 'shape: surrounding space refused');
-- Full rule ----------------------------------------------------------------------------------------------------------------------------------------------
select is(app.timezone_ok('Asia/Kolkata'), true, 'rule: a real zone passes');
select is(app.timezone_ok('Mars/Base'), false, 'rule: an unknown zone is refused');
select is(app.timezone_ok('posix/Asia/Kolkata'), false, 'rule: posix/ refused');
select is(app.timezone_ok(null), false, 'rule: null refused');
select is(app._pa_timezone_ok('Asia/Dubai'), true, 'the tenant rule delegates to it (accepts)');
select is(app._pa_timezone_ok('right/UTC'), false, 'the tenant rule delegates to it (refuses)');
select ok(not has_function_privilege('authenticated', 'app.timezone_ok(text)', 'execute') and not has_function_privilege('anon', 'app.timezone_ok(text)', 'execute')
          and not has_function_privilege('authenticated', 'app.timezone_shape_ok(text)', 'execute'), 'the shared rule is not callable by clients');

-- Triggers ------------------------------------------------------------------------------------------------------------------------------------------------
insert into public.tenant (id, name, status) values ('1f000000-0000-4000-bb00-00000000000a', 'tap23 org', 'active');
select is(pg_temp.err($$ insert into public.tenant (name, timezone) values ('tap23 posix', 'posix/Asia/Kolkata') $$) @> '{"sqlstate":"23514"}', true, 'tenant: insert with a posix/ zone -> 23514');
select is(pg_temp.err($$ update public.tenant set timezone = 'right/UTC' where id = '1f000000-0000-4000-bb00-00000000000a' $$) @> '{"sqlstate":"23514"}', true, 'tenant: update to a right/ zone -> 23514');
select is(pg_temp.err($$ update public.tenant set timezone = 'Mars/Base' where id = '1f000000-0000-4000-bb00-00000000000a' $$) @> '{"sqlstate":"23514"}', true, 'tenant: update to an unknown zone -> 23514');
select is(pg_temp.err($$ update public.tenant set timezone = 'Asia/Dubai' where id = '1f000000-0000-4000-bb00-00000000000a' $$)->>'raised', 'false', 'tenant: a valid zone is accepted');
insert into public.site (id, tenant_id, name, timezone) values ('5e000000-0000-4000-bb00-000000000001', '1f000000-0000-4000-bb00-00000000000a', 'tap23 site', 'Asia/Kolkata');
select is(pg_temp.err($$ update public.site set timezone = 'right/UTC' where id = '5e000000-0000-4000-bb00-000000000001' $$) @> '{"sqlstate":"23514"}', true, 'site: update to a right/ zone -> 23514');
select is(pg_temp.err($$ insert into public.site (tenant_id, name, timezone) values ('1f000000-0000-4000-bb00-00000000000a', 'second', 'posix/UTC') $$) @> '{"sqlstate":"23514"}', true, 'site: insert with a posix/ zone -> 23514 (before any uniqueness check matters)');

-- pm_save_site answers validation/timezone, never a 500 -----------------------------------------------------------------------------------------------------
insert into auth.users (id, email, aud, role) values ('00000000-0000-4000-bb00-0000000000b1', 'tap23-ua@example.test', 'authenticated', 'authenticated');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('1f000000-0000-4000-bb00-00000000000a', '00000000-0000-4000-bb00-0000000000b1', 'unit_admin', 'active', 'UA 23', 'UA-23', '+919000023101', false);
select ok((select prosrc from pg_proc where proname = 'pm_save_site' and pronamespace = 'public'::regnamespace) like '%app.timezone_ok(%', 'pm_save_site uses the shared rule');
select ok((select prosrc from pg_proc where proname = 'pm_save_site' and pronamespace = 'public'::regnamespace) not like '%pg_timezone_names%', 'and no longer carries its own zone lookup');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-bb00-0000000000b1","role":"authenticated"}', true);
select is(pg_temp.err($$ select public.pm_save_site(gen_random_uuid(), 'tap23 site', 'posix/Asia/Kolkata') $$) @> '{"code":"validation","field":"timezone","sqlstate":"P0001"}', true, 'pm_save_site: posix/ -> validation/timezone');
select is(pg_temp.err($$ select public.pm_save_site(gen_random_uuid(), 'tap23 site', 'right/UTC') $$) @> '{"code":"validation","field":"timezone","sqlstate":"P0001"}', true, 'pm_save_site: right/ -> validation/timezone');
select is(pg_temp.err($$ select public.pm_save_site(gen_random_uuid(), 'tap23 site', 'Mars/Base') $$) @> '{"code":"validation","field":"timezone","sqlstate":"P0001"}', true, 'pm_save_site: unknown -> validation/timezone');
select is((public.pm_save_site(gen_random_uuid(), 'tap23 site', 'Asia/Dubai'))->>'ok', 'true', 'pm_save_site: a valid zone still saves');
reset role;
select is((select timezone from public.site where id = '5e000000-0000-4000-bb00-000000000001'), 'Asia/Dubai', 'and the site holds it');

select * from finish();
rollback;
