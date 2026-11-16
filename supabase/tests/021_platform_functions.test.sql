-- 03 step 2 (AC-3..9, 12, 14, D2): service-only platform functions. Denials are COMMITTED + RETURNED; validation / duplicate / guard RAISE P0001.
-- Self-contained; rolled back. Phones from the throwaway block +91 90000 21xxx.
begin;
create extension if not exists pgtap with schema extensions;
select plan(153);

create function pg_temp.err(q text) returns jsonb language plpgsql as $f$
declare d text; m text; st text;
begin
  execute q;
  return jsonb_build_object('raised', false);
exception when others then
  get stacked diagnostics d = pg_exception_detail, m = message_text, st = returned_sqlstate;
  return coalesce(nullif(d, '')::jsonb, '{}'::jsonb) || jsonb_build_object('message', m, 'sqlstate', st);
end $f$;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-b900-0000000000a1', 'tap21-sa1@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b900-0000000000a2', 'tap21-sa2@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b900-0000000000a3', 'tap21-sa-inactive@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b900-0000000000a4', 'tap21-sa-must@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b900-0000000000b1', 'tap21-ua@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b900-0000000000b2', 'tap21-sup@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b900-0000000000b3', 'tap21-ua-inactive@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b900-0000000000e1', 'tap21-new1@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b900-0000000000e2', 'tap21-new2@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b900-0000000000e3', 'tap21-new3@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b900-0000000000e4', 'tap21-new4@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b900-0000000000e5', 'tap21-new5@example.test', 'authenticated', 'authenticated');
insert into public.tenant (id, name, status) values
  ('19000000-0000-4000-b900-00000000000a', 'tap21 org X', 'active');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('19000000-0000-4000-b900-00000000000a', '00000000-0000-4000-b900-0000000000b1', 'unit_admin', 'active', 'UA X', 'UA-1', '+919000021101', false),
  ('19000000-0000-4000-b900-00000000000a', '00000000-0000-4000-b900-0000000000b2', 'supervisor', 'active', 'Sup X', 'SUP-1', '+919000021102', false),
  ('19000000-0000-4000-b900-00000000000a', '00000000-0000-4000-b900-0000000000b3', 'unit_admin', 'inactive', 'UA Gone', 'UA-2', '+919000021103', false);
insert into public.platform_admin (user_id, full_name, phone_e164, status, must_change_password) values
  ('00000000-0000-4000-b900-0000000000a1', 'SA One', '+919000021001', 'active', false),
  ('00000000-0000-4000-b900-0000000000a2', 'SA Two', '+919000021002', 'active', false),
  ('00000000-0000-4000-b900-0000000000a3', 'SA Inactive', '+919000021003', 'inactive', false),
  ('00000000-0000-4000-b900-0000000000a4', 'SA Must', '+919000021004', 'active', true);

-- Privileges --------------------------------------------------------------------------------------------------------------------------------
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname ~ '^psvc_' and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0,
  'no psvc_* wrapper is executable by anon or authenticated');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname ~ '^psvc_' and not has_function_privilege('service_role', p.oid, 'execute')), 0, 'service_role can execute every psvc_* wrapper');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'app' and p.proname ~ '^(pa_|_pa_)' and (not p.prosecdef or p.proconfig is null or not ('search_path=""' = any (p.proconfig)))), 0,
  'every pa_* function is security definer with an empty search_path');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname ~ '^svc_'), 8, '02''s svc_* wrapper count is untouched');
set local role authenticated;
select throws_ok($$ select app.pa_tenant_create('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), 'x', null, null) $$, '42501', null, 'authenticated cannot call pa_tenant_create');
select throws_ok($$ select public.psvc_pa_tenant_create('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), 'x', null, null) $$, '42501', null, 'authenticated cannot call a psvc wrapper');
reset role;

-- Tenant create ---------------------------------------------------------------------------------------------------------------------------------
select is((app.pa_tenant_create('00000000-0000-4000-b900-0000000000a1', '1a000000-0000-4000-b900-000000000001', '  Acme Moulds  ', null, null))->>'ok', 'true', 'create: succeeds with defaults');
select results_eq($$ select name, timezone, plan_label::text, status::text, suspended_reason from public.tenant where lower(name) = 'acme moulds' $$,
  $$ values ('Acme Moulds'::text, 'Asia/Kolkata'::text, 'trial'::text, 'active'::text, null::text) $$, 'create: name trimmed, Asia/Kolkata, trial, active');
select results_eq($$ select action, actor_user_id, actor_role, entity_type, before is null, after->>'name', after->>'plan_label', source, request_id, tenant_id = entity_id
                     from public.audit_event where action = 'tenant.created' $$,
  $$ values ('tenant.created'::text, '00000000-0000-4000-b900-0000000000a1'::uuid, 'platform_admin'::text, 'tenant'::text, true, 'Acme Moulds'::text, 'trial'::text, 'edge:platform'::text, '1a000000-0000-4000-b900-000000000001'::uuid, true) $$,
  'create: one audit row under the new tenant, actor role platform_admin');
select results_eq($$ select (r->>'ok')::boolean, (r->>'already')::boolean from (select app.pa_tenant_create('00000000-0000-4000-b900-0000000000a1', '1a000000-0000-4000-b900-000000000001', 'Acme Moulds', null, null) r) s $$,
  $$ values (true, true) $$, 'create: a repeated request id reports already done');
select is((select count(*)::int from public.tenant where lower(name) = 'acme moulds'), 1, 'create: a retry creates no second tenant');
select is((select count(*)::int from public.audit_event where action = 'tenant.created'), 1, 'create: a retry writes no second audit row');
select is((app.pa_tenant_create('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), 'Zone Co', 'America/New_York', 'active'))->>'ok', 'true', 'create: explicit timezone and plan');
select is(pg_temp.err($$ select app.pa_tenant_create('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), 'ACME MOULDS', null, null) $$) @> '{"code":"duplicate","field":"name","sqlstate":"P0001"}', true, 'create: duplicate name (any case) -> duplicate/name');
select is(pg_temp.err($$ select app.pa_tenant_create('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), '   ', null, null) $$) @> '{"code":"validation","field":"name"}', true, 'create: blank name -> validation/name');
select is(pg_temp.err($$ select app.pa_tenant_create('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), repeat('n', 81), null, null) $$) @> '{"code":"validation","field":"name"}', true, 'create: name over 80 -> validation/name');
select is(pg_temp.err($$ select app.pa_tenant_create('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), 'Bad Zone', 'Mars/Base', null) $$) @> '{"code":"validation","field":"timezone"}', true, 'create: unknown timezone -> validation/timezone');
select is(pg_temp.err($$ select app.pa_tenant_create('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), 'Bad Plan', null, 'gold') $$) @> '{"code":"validation","field":"plan_label"}', true, 'create: unknown plan -> validation/plan_label');
select is((select count(*)::int from public.tenant where name in ('ACME MOULDS', 'Bad Zone', 'Bad Plan')), 0, 'create: refused inputs leave no tenant');

-- Tenant update ---------------------------------------------------------------------------------------------------------------------------------
select is((app.pa_tenant_update('00000000-0000-4000-b900-0000000000a1', '1a000000-0000-4000-b900-000000000002', '19000000-0000-4000-b900-00000000000a', 'tap21 org X2', 'Asia/Dubai', 'active'))->>'ok', 'true', 'update: succeeds');
select results_eq($$ select before->>'name', after->>'name', before->>'timezone', after->>'timezone', before->>'plan_label', after->>'plan_label', tenant_id from public.audit_event where action = 'tenant.updated' $$,
  $$ values ('tap21 org X'::text, 'tap21 org X2'::text, 'Asia/Kolkata'::text, 'Asia/Dubai'::text, 'trial'::text, 'active'::text, '19000000-0000-4000-b900-00000000000a'::uuid) $$, 'update: audit row holds before and after, under the tenant');
select is((app.pa_tenant_update('00000000-0000-4000-b900-0000000000a1', '1a000000-0000-4000-b900-000000000002', '19000000-0000-4000-b900-00000000000a', 'tap21 org X2', 'Asia/Dubai', 'active'))->>'already', 'true', 'update: retry reports already done');
select is((select count(*)::int from public.audit_event where action = 'tenant.updated'), 1, 'update: retry writes no second audit row');
select is((app.pa_tenant_update('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), '19000000-0000-4000-b900-00000000000a', null, null, 'trial'))->>'ok', 'true', 'update: a single field can change');
select is((select name from public.tenant where id = '19000000-0000-4000-b900-00000000000a'), 'tap21 org X2', 'update: omitted fields are untouched');
select is(pg_temp.err($$ select app.pa_tenant_update('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), '19000000-0000-4000-b900-00000000000a', 'zone co', null, null) $$) @> '{"code":"duplicate","field":"name"}', true, 'update: name of another tenant -> duplicate');
select is((app.pa_tenant_update('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), '19000000-0000-4000-b900-00000000000a', 'TAP21 ORG X2', null, null))->>'ok', 'true', 'update: re-casing the own name is not a duplicate');
select is(pg_temp.err($$ select app.pa_tenant_update('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), gen_random_uuid(), 'x', null, null) $$) @> '{"code":"guard","field":"not_found"}', true, 'update: unknown tenant -> guard/not_found');

-- Suspend / activate ----------------------------------------------------------------------------------------------------------------------------
select is(pg_temp.err($$ select app.pa_tenant_set_status('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), '19000000-0000-4000-b900-00000000000a', 'suspended', '  ') $$) @> '{"code":"validation","field":"reason"}', true, 'suspend: a reason is required');
select is(pg_temp.err($$ select app.pa_tenant_set_status('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), '19000000-0000-4000-b900-00000000000a', 'suspended', repeat('r', 201)) $$) @> '{"code":"validation","field":"reason"}', true, 'suspend: reason over 200 refused');
select is(pg_temp.err($$ select app.pa_tenant_set_status('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), '19000000-0000-4000-b900-00000000000a', 'frozen', 'x') $$) @> '{"code":"validation","field":"status"}', true, 'status must be active or suspended');
select is((app.pa_tenant_set_status('00000000-0000-4000-b900-0000000000a1', '1a000000-0000-4000-b900-000000000003', '19000000-0000-4000-b900-00000000000a', 'suspended', 'Unpaid invoice'))->>'changed', 'true', 'suspend: succeeds');
select results_eq($$ select status::text, suspended_reason from public.tenant where id = '19000000-0000-4000-b900-00000000000a' $$, $$ values ('suspended'::text, 'Unpaid invoice'::text) $$, 'suspend: status and reason stored');
select results_eq($$ select reason, before->>'status', after->>'status', tenant_id from public.audit_event where action = 'tenant.suspended' $$,
  $$ values ('Unpaid invoice'::text, 'active'::text, 'suspended'::text, '19000000-0000-4000-b900-00000000000a'::uuid) $$, 'suspend: audit row with reason under the tenant');
select is((app.pa_tenant_set_status('00000000-0000-4000-b900-0000000000a1', '1a000000-0000-4000-b900-000000000003', '19000000-0000-4000-b900-00000000000a', 'suspended', 'Unpaid invoice'))->>'status', 'suspended', 'suspend: retry returns the current status');
select is((app.pa_tenant_set_status('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), '19000000-0000-4000-b900-00000000000a', 'suspended', 'Again'))->>'changed', 'false', 'suspend: an already suspended tenant reports no change');
select is((select count(*)::int from public.audit_event where action = 'tenant.suspended'), 1, 'suspend: retries and no-ops write no extra audit rows');
select is((select app.current_tenant_id() from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b900-0000000000b1"}', true)) s), null, 'suspend: the tenant''s users lose their tenant at once');
select is((app.pa_tenant_set_status('00000000-0000-4000-b900-0000000000a1', '1a000000-0000-4000-b900-000000000004', '19000000-0000-4000-b900-00000000000a', 'active', null))->>'changed', 'true', 'activate: succeeds without a reason');
select results_eq($$ select status::text, suspended_reason from public.tenant where id = '19000000-0000-4000-b900-00000000000a' $$, $$ values ('active'::text, null::text) $$, 'activate: reason cleared');
select is((select count(*)::int from public.audit_event where action = 'tenant.activated' and tenant_id = '19000000-0000-4000-b900-00000000000a'), 1, 'activate: one audit row');
select is((select app.current_tenant_id() from (select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b900-0000000000b1"}', true)) s), '19000000-0000-4000-b900-00000000000a'::uuid, 'activate: access is restored');

-- Denials (D13) -----------------------------------------------------------------------------------------------------------------------------------
select is(app.pa_tenant_create('00000000-0000-4000-b900-0000000000b1', gen_random_uuid(), 'Evil Co', null, null), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a Unit Admin is denied');
select is(app.pa_tenant_set_status('00000000-0000-4000-b900-0000000000b2', gen_random_uuid(), '19000000-0000-4000-b900-00000000000a', 'suspended', 'x'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a supervisor is denied');
select is(app.pa_tenant_create('00000000-0000-4000-b900-0000000000a3', gen_random_uuid(), 'Evil Co', null, null), '{"ok": false, "code": "not_allowed"}'::jsonb, 'an inactive SA is denied');
select is(app.pa_tenant_create('00000000-0000-4000-b900-0000000000a4', gen_random_uuid(), 'Evil Co', null, null), '{"ok": false, "code": "not_allowed"}'::jsonb, 'an SA with a temporary password is denied');
select is(app.pa_tenant_create('00000000-0000-4000-b900-0000000000ff', gen_random_uuid(), 'Evil Co', null, null), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a caller with no identity is denied');
select is((select count(*)::int from public.tenant where name = 'Evil Co'), 0, 'denied creates make nothing');
select bag_eq($$ select actor_user_id, actor_role, reason, tenant_id from public.audit_event where action = 'access.denied' and source = 'edge:platform' $$,
  $$ values ('00000000-0000-4000-b900-0000000000b1'::uuid, 'unit_admin'::text, 'not_platform_admin'::text, '19000000-0000-4000-b900-00000000000a'::uuid),
            ('00000000-0000-4000-b900-0000000000b2'::uuid, 'supervisor'::text, 'not_platform_admin'::text, '19000000-0000-4000-b900-00000000000a'::uuid),
            ('00000000-0000-4000-b900-0000000000a3'::uuid, 'platform_admin'::text, 'inactive'::text, null::uuid),
            ('00000000-0000-4000-b900-0000000000a4'::uuid, 'platform_admin'::text, 'must_change_password'::text, null::uuid),
            ('00000000-0000-4000-b900-0000000000ff'::uuid, null::text, 'not_platform_admin'::text, null::uuid) $$,
  'each denial is audited: tenant users under their tenant, SAs with role platform_admin');

-- Create Unit Admin -----------------------------------------------------------------------------------------------------------------------------
select is((app.pa_ua_check_create('00000000-0000-4000-b900-0000000000a1', '1b000000-0000-4000-b900-000000000001', '19000000-0000-4000-b900-00000000000a', 'First UA', 'F-1', '+919000021201'))->>'ok', 'true', 'ua check_create: valid input passes');
select is((select count(*)::int from public.membership where phone_e164 = '+919000021201'), 0, 'ua check_create writes nothing');
select is((app.pa_ua_create('00000000-0000-4000-b900-0000000000a1', '1b000000-0000-4000-b900-000000000001', '19000000-0000-4000-b900-00000000000a', '00000000-0000-4000-b900-0000000000e1', ' First UA ', 'F-1', '+919000021201'))->>'user_id', '00000000-0000-4000-b900-0000000000e1', 'ua create: returns the user id');
select results_eq($$ select role::text, status::text, must_change_password, created_by, tenant_id, full_name from public.membership where user_id = '00000000-0000-4000-b900-0000000000e1' $$,
  $$ values ('unit_admin'::text, 'active'::text, true, '00000000-0000-4000-b900-0000000000a1'::uuid, '19000000-0000-4000-b900-00000000000a'::uuid, 'First UA'::text) $$, 'ua create: an active Unit Admin of that tenant who must change the password');
select ok((select temp_password_expires_at > now() + interval '23 hours' from public.membership where user_id = '00000000-0000-4000-b900-0000000000e1'), 'ua create: 24 hour expiry');
select results_eq($$ select action, tenant_id, actor_role, after->>'phone', after->>'role' from public.audit_event where action = 'user.created' and actor_user_id = '00000000-0000-4000-b900-0000000000a1' $$,
  $$ values ('user.created'::text, '19000000-0000-4000-b900-00000000000a'::uuid, 'platform_admin'::text, '+91******1201'::text, 'unit_admin'::text) $$, 'ua create: audit under the tenant, actor role platform_admin, masked phone');
select is((app.pa_ua_create('00000000-0000-4000-b900-0000000000a1', '1b000000-0000-4000-b900-000000000001', '19000000-0000-4000-b900-00000000000a', '00000000-0000-4000-b900-0000000000e2', 'First UA', 'F-1', '+919000021201'))->>'user_id', '00000000-0000-4000-b900-0000000000e1', 'ua create: retry returns the first outcome');
select is((select count(*)::int from public.audit_event where action = 'user.created' and actor_user_id = '00000000-0000-4000-b900-0000000000a1'), 1, 'ua create: retry writes no second audit row');
select is(pg_temp.err($$ select app.pa_ua_create('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), '19000000-0000-4000-b900-00000000000a', '00000000-0000-4000-b900-0000000000e2', 'Dup', 'F-2', '+919000021101') $$) @> '{"code":"duplicate","field":"phone"}', true, 'ua create: a member phone -> duplicate/phone');
select is(pg_temp.err($$ select app.pa_ua_create('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), '19000000-0000-4000-b900-00000000000a', '00000000-0000-4000-b900-0000000000e2', 'Dup', 'F-2', '+919000021002') $$) @> '{"code":"duplicate","field":"phone"}', true, 'ua create: an SA phone -> duplicate/phone');
select is(pg_temp.err($$ select app.pa_ua_create('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), '19000000-0000-4000-b900-00000000000a', '00000000-0000-4000-b900-0000000000e2', 'Dup', 'f-1', '+919000021202') $$) @> '{"code":"duplicate","field":"employee_id"}', true, 'ua create: employee id (any case) -> duplicate/employee_id');
select is(pg_temp.err($$ select app.pa_ua_create('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), '19000000-0000-4000-b900-00000000000a', '00000000-0000-4000-b900-0000000000e2', '', 'F-2', '+919000021202') $$) @> '{"code":"validation","field":"full_name"}', true, 'ua create: blank name -> validation');
select is(pg_temp.err($$ select app.pa_ua_create('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), '19000000-0000-4000-b900-00000000000a', '00000000-0000-4000-b900-0000000000e2', 'X', 'F-2', '+915000021202') $$) @> '{"code":"validation","field":"phone"}', true, 'ua create: bad phone -> validation');
select is(pg_temp.err($$ select app.pa_ua_create('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), gen_random_uuid(), '00000000-0000-4000-b900-0000000000e2', 'X', 'F-2', '+919000021202') $$) @> '{"code":"guard","field":"not_found"}', true, 'ua create: unknown tenant -> guard/not_found');
select is(app.pa_ua_create('00000000-0000-4000-b900-0000000000b1', gen_random_uuid(), '19000000-0000-4000-b900-00000000000a', '00000000-0000-4000-b900-0000000000e2', 'X', 'F-2', '+919000021202'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'ua create: a tenant UA is denied');

-- Reset Unit Admin password ------------------------------------------------------------------------------------------------------------------------
insert into auth.sessions (id, user_id) values ('51000000-0000-4000-b900-000000000001', '00000000-0000-4000-b900-0000000000b1');
select is((app.pa_ua_reset_password('00000000-0000-4000-b900-0000000000a1', '1c000000-0000-4000-b900-000000000001', '00000000-0000-4000-b900-0000000000b1'))->>'ok', 'true', 'ua reset: succeeds for a Unit Admin');
select results_eq($$ select must_change_password, temp_password_expires_at > now() + interval '23 hours' from public.membership where user_id = '00000000-0000-4000-b900-0000000000b1' $$, $$ values (true, true) $$, 'ua reset: must change password with a fresh 24h expiry');
select is((select count(*)::int from auth.sessions where user_id = '00000000-0000-4000-b900-0000000000b1'), 0, 'ua reset: sessions ended');
select is((select count(*)::int from public.audit_event where action = 'user.password_reset' and entity_id = '00000000-0000-4000-b900-0000000000b1' and tenant_id = '19000000-0000-4000-b900-00000000000a' and actor_role = 'platform_admin'), 1, 'ua reset: audit under the tenant');
select is((app.pa_ua_reset_password('00000000-0000-4000-b900-0000000000a1', '1c000000-0000-4000-b900-000000000001', '00000000-0000-4000-b900-0000000000b1'))->>'already', 'true', 'ua reset: retry reports already done');
select is(app.pa_ua_reset_password('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b900-0000000000b2'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'ua reset: a supervisor is refused');
select results_eq($$ select reason, tenant_id, actor_role from public.audit_event where action = 'access.denied' and entity_id = '00000000-0000-4000-b900-0000000000b2' $$,
  $$ values ('target_not_unit_admin'::text, '19000000-0000-4000-b900-00000000000a'::uuid, 'platform_admin'::text) $$, 'ua reset: the refusal is audited under the tenant');
select is((select must_change_password from public.membership where user_id = '00000000-0000-4000-b900-0000000000b2'), false, 'ua reset: the supervisor was not changed');
select is(app.pa_ua_reset_password('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), gen_random_uuid()), '{"ok": false, "code": "not_allowed"}'::jsonb, 'ua reset: an unknown user is refused identically');
select is(pg_temp.err($$ select app.pa_ua_reset_password('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b900-0000000000b3') $$) @> '{"code":"guard","field":"inactive"}', true, 'ua reset: an inactive Unit Admin must be reactivated first');
select is(app.pa_ua_reset_password('00000000-0000-4000-b900-0000000000b1', gen_random_uuid(), '00000000-0000-4000-b900-0000000000b1'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'ua reset: a tenant UA cannot use it');

-- Super Admins -------------------------------------------------------------------------------------------------------------------------------------------
select is((app.pa_sa_check_create('00000000-0000-4000-b900-0000000000a1', '1d000000-0000-4000-b900-000000000001', 'SA Three', '+919000021301'))->>'ok', 'true', 'sa check_create passes');
select is((app.pa_sa_create('00000000-0000-4000-b900-0000000000a1', '1d000000-0000-4000-b900-000000000001', '00000000-0000-4000-b900-0000000000e3', ' SA Three ', '+919000021301'))->>'user_id', '00000000-0000-4000-b900-0000000000e3', 'sa create: returns the user id');
select results_eq($$ select full_name, status::text, must_change_password, created_by from public.platform_admin where user_id = '00000000-0000-4000-b900-0000000000e3' $$,
  $$ values ('SA Three'::text, 'active'::text, true, '00000000-0000-4000-b900-0000000000a1'::uuid) $$, 'sa create: active, must change password, created_by set');
select results_eq($$ select action, tenant_id is null, actor_role, after->>'phone' from public.audit_event where action = 'platform_admin.created' and entity_id = '00000000-0000-4000-b900-0000000000e3' $$,
  $$ values ('platform_admin.created'::text, true, 'platform_admin'::text, '+91******1301'::text) $$, 'sa create: audit with null tenant and a masked phone');
select is((app.pa_sa_create('00000000-0000-4000-b900-0000000000a1', '1d000000-0000-4000-b900-000000000001', gen_random_uuid(), 'SA Three', '+919000021301'))->>'already', 'true', 'sa create: retry reports already done');
select is(pg_temp.err($$ select app.pa_sa_create('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), gen_random_uuid(), 'Dup', '+919000021101') $$) @> '{"code":"duplicate","field":"phone"}', true, 'sa create: a member phone -> duplicate/phone');
select is(pg_temp.err($$ select app.pa_sa_create('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), gen_random_uuid(), 'Dup', '+919000021001') $$) @> '{"code":"duplicate","field":"phone"}', true, 'sa create: an SA phone -> duplicate/phone');
select is(pg_temp.err($$ select app.pa_sa_create('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), gen_random_uuid(), '', '+919000021302') $$) @> '{"code":"validation","field":"full_name"}', true, 'sa create: blank name -> validation');
select is(app.pa_sa_create('00000000-0000-4000-b900-0000000000b1', gen_random_uuid(), gen_random_uuid(), 'X', '+919000021302'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'sa create: a tenant UA is denied');

select is(pg_temp.err($$ select app.pa_sa_set_status('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b900-0000000000a1', 'inactive') $$) @> '{"code":"guard","field":"self"}', true, 'sa status: an SA cannot deactivate themself');
select is(pg_temp.err($$ select app.pa_sa_set_status('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b900-0000000000a1', 'frozen') $$) @> '{"code":"validation","field":"status"}', true, 'sa status: unknown status -> validation');
select is(pg_temp.err($$ select app.pa_sa_set_status('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), gen_random_uuid(), 'inactive') $$) @> '{"code":"guard","field":"not_found"}', true, 'sa status: unknown Super Admin -> guard/not_found');
insert into auth.sessions (id, user_id) values ('51000000-0000-4000-b900-000000000002', '00000000-0000-4000-b900-0000000000a2');
select is((app.pa_sa_set_status('00000000-0000-4000-b900-0000000000a1', '1d000000-0000-4000-b900-000000000002', '00000000-0000-4000-b900-0000000000a2', 'inactive'))->>'changed', 'true', 'sa status: deactivate another SA');
select is((select count(*)::int from auth.sessions where user_id = '00000000-0000-4000-b900-0000000000a2'), 0, 'sa status: deactivation ends their sessions');
select is((select count(*)::int from public.audit_event where action = 'platform_admin.deactivated' and entity_id = '00000000-0000-4000-b900-0000000000a2' and tenant_id is null), 1, 'sa status: one audit row, null tenant');
select is((app.pa_sa_set_status('00000000-0000-4000-b900-0000000000a1', '1d000000-0000-4000-b900-000000000002', '00000000-0000-4000-b900-0000000000a2', 'inactive'))->>'status', 'inactive', 'sa status: retry returns the current status');
select is(app.pa_tenant_create('00000000-0000-4000-b900-0000000000a2', gen_random_uuid(), 'Late Co', null, null), '{"ok": false, "code": "not_allowed"}'::jsonb, 'sa status: the deactivated SA is denied at once');
select is(app.pa_sa_set_status('00000000-0000-4000-b900-0000000000a2', gen_random_uuid(), '00000000-0000-4000-b900-0000000000a1', 'inactive'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'sa status: an inactive SA cannot deactivate others');
select is(app.pa_sa_set_status('00000000-0000-4000-b900-0000000000a4', gen_random_uuid(), '00000000-0000-4000-b900-0000000000a1', 'inactive'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'sa status: an SA with a temporary password cannot deactivate others');
select is((app.pa_sa_set_status('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b900-0000000000a2', 'active'))->>'changed', 'true', 'sa status: reactivate');
select is((select count(*)::int from public.audit_event where action = 'platform_admin.reactivated' and entity_id = '00000000-0000-4000-b900-0000000000a2'), 1, 'sa status: reactivation audited');
select is((app.pa_sa_set_status('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b900-0000000000a3', 'inactive'))->>'changed', 'false', 'sa status: an already inactive SA reports no change');
-- Only two SAs can act (a1, a2). a2 deactivates a1; a2 is then the last active actor and cannot deactivate themself.
select is((app.pa_sa_set_status('00000000-0000-4000-b900-0000000000a2', gen_random_uuid(), '00000000-0000-4000-b900-0000000000a1', 'inactive'))->>'ok', 'true', 'sa status: a2 deactivates a1');
select is(pg_temp.err($$ select app.pa_sa_set_status('00000000-0000-4000-b900-0000000000a2', gen_random_uuid(), '00000000-0000-4000-b900-0000000000a2', 'inactive') $$) @> '{"code":"guard","field":"self"}', true, 'sa status: the last acting SA cannot deactivate themself');
select is(app.pa_sa_set_status('00000000-0000-4000-b900-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b900-0000000000a2', 'inactive'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'sa status: the deactivated a1 cannot remove a2 either');
select is((select count(*)::int from public.platform_admin where status = 'active' and must_change_password = false), 1, 'sa status: exactly one usable active SA remains');
-- last_admin guard fires when the only other active SA is the target (deactivate while the caller is the sole active one is impossible, so
-- reactivate a1 then check the guard text via a direct row state: a2 active, a1 target active, no third active)
update public.platform_admin set status = 'inactive' where user_id in ('00000000-0000-4000-b900-0000000000a4', '00000000-0000-4000-b900-0000000000e3');
select is(pg_temp.err($$ select app.pa_sa_set_status('00000000-0000-4000-b900-0000000000a2', gen_random_uuid(), '00000000-0000-4000-b900-0000000000a2', 'inactive') $$) @> '{"code":"guard"}', true, 'sa status: the sole active SA is protected');

-- SA password reset ---------------------------------------------------------------------------------------------------------------------------------------
update public.platform_admin set status = 'active', must_change_password = false where user_id = '00000000-0000-4000-b900-0000000000a1';
insert into auth.sessions (id, user_id) values ('51000000-0000-4000-b900-000000000003', '00000000-0000-4000-b900-0000000000a1');
select is(pg_temp.err($$ select app.pa_sa_reset_password('00000000-0000-4000-b900-0000000000a2', gen_random_uuid(), '00000000-0000-4000-b900-0000000000a2') $$) @> '{"code":"guard","field":"self"}', true, 'sa reset: an SA cannot reset themself');
select is((app.pa_sa_reset_password('00000000-0000-4000-b900-0000000000a2', '1e000000-0000-4000-b900-000000000001', '00000000-0000-4000-b900-0000000000a1'))->>'ok', 'true', 'sa reset: succeeds');
select results_eq($$ select must_change_password, temp_password_expires_at > now() + interval '23 hours' from public.platform_admin where user_id = '00000000-0000-4000-b900-0000000000a1' $$, $$ values (true, true) $$, 'sa reset: must change password with a 24h expiry');
select is((select count(*)::int from auth.sessions where user_id = '00000000-0000-4000-b900-0000000000a1'), 0, 'sa reset: sessions ended');
select is((select count(*)::int from public.audit_event where action = 'platform_admin.password_reset' and entity_id = '00000000-0000-4000-b900-0000000000a1' and tenant_id is null), 1, 'sa reset: one audit row');
select is((app.pa_sa_reset_password('00000000-0000-4000-b900-0000000000a2', '1e000000-0000-4000-b900-000000000001', '00000000-0000-4000-b900-0000000000a1'))->>'already', 'true', 'sa reset: retry reports already done');
select is(pg_temp.err($$ select app.pa_sa_reset_password('00000000-0000-4000-b900-0000000000a2', gen_random_uuid(), '00000000-0000-4000-b900-0000000000a3') $$) @> '{"code":"guard","field":"inactive"}', true, 'sa reset: an inactive SA must be reactivated first');
select is(pg_temp.err($$ select app.pa_sa_reset_password('00000000-0000-4000-b900-0000000000a2', gen_random_uuid(), gen_random_uuid()) $$) @> '{"code":"guard","field":"not_found"}', true, 'sa reset: unknown Super Admin');
select is(app.pa_sa_reset_password('00000000-0000-4000-b900-0000000000b1', gen_random_uuid(), '00000000-0000-4000-b900-0000000000a2'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'sa reset: a tenant UA is denied');

-- Setup -----------------------------------------------------------------------------------------------------------------------------------------------------
select is(app.pa_setup_check(), '{"ok": false, "code": "setup_closed"}'::jsonb, 'setup: refused while any SA exists');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and reason = 'setup_closed' and source = 'edge:platform-setup' and actor_user_id is null and tenant_id is null), 1, 'setup: the refusal is audited');
select app.pa_setup_check();
select is((select count(*)::int from public.audit_event where reason = 'setup_closed'), 1, 'setup: refusals are throttled to one audit row per minute');
select is(app.pa_setup_first('00000000-0000-4000-b900-0000000000e4', 'Late Setup', '+919000021401'), '{"ok": false, "code": "setup_closed"}'::jsonb, 'setup_first: refused while any SA exists');
select is((select count(*)::int from public.platform_admin where phone_e164 = '+919000021401'), 0, 'setup_first: nothing created when refused');
delete from public.platform_admin;
select is(app.pa_setup_check(), '{"ok": true}'::jsonb, 'setup: open when no SA exists');
select is(pg_temp.err($$ select app.pa_setup_first('00000000-0000-4000-b900-0000000000e4', '', '+919000021401') $$) @> '{"code":"validation","field":"full_name"}', true, 'setup_first: validates the name');
select is(pg_temp.err($$ select app.pa_setup_first('00000000-0000-4000-b900-0000000000e4', 'First Admin', '+919000021101') $$) @> '{"code":"duplicate","field":"phone"}', true, 'setup_first: refuses a phone that a member holds');
select is((app.pa_setup_first('00000000-0000-4000-b900-0000000000e4', ' First Admin ', '+919000021401'))->>'ok', 'true', 'setup_first: creates the first SA');
select results_eq($$ select full_name, status::text, must_change_password, created_by is null from public.platform_admin $$, $$ values ('First Admin'::text, 'active'::text, true, true) $$, 'setup_first: active, must change password');
select results_eq($$ select action, source, actor_user_id is null, after->>'phone', entity_id from public.audit_event where action = 'platform_admin.created' and source = 'edge:platform-setup' $$,
  $$ values ('platform_admin.created'::text, 'edge:platform-setup'::text, true, '+91******1401'::text, '00000000-0000-4000-b900-0000000000e4'::uuid) $$, 'setup_first: audited with source edge:platform-setup and a masked phone');
select is(app.pa_setup_first('00000000-0000-4000-b900-0000000000e5', 'Second', '+919000021402'), '{"ok": false, "code": "setup_closed"}'::jsonb, 'setup_first: a second call is refused');

-- Own password change (D5) ---------------------------------------------------------------------------------------------------------------------------------
update public.platform_admin set temp_password_expires_at = now() + interval '1 hour' where user_id = '00000000-0000-4000-b900-0000000000e4';
select is((app.pa_password_changed('00000000-0000-4000-b900-0000000000e4', null, true))->>'ok', 'true', 'password: the check passes');
select is((select must_change_password from public.platform_admin), true, 'password: the check changes nothing');
insert into auth.sessions (id, user_id) values ('51000000-0000-4000-b900-000000000004', '00000000-0000-4000-b900-0000000000e4'), ('51000000-0000-4000-b900-000000000005', '00000000-0000-4000-b900-0000000000e4');
select is((app.pa_password_changed('00000000-0000-4000-b900-0000000000e4', '51000000-0000-4000-b900-000000000004'))->>'ok', 'true', 'password: change succeeds');
select results_eq($$ select must_change_password, temp_password_expires_at is null from public.platform_admin $$, $$ values (false, true) $$, 'password: flag and expiry cleared');
select is((select array_agg(id::text) from auth.sessions where user_id = '00000000-0000-4000-b900-0000000000e4'), array['51000000-0000-4000-b900-000000000004'], 'password: only the caller''s session survives');
select is((select count(*)::int from public.audit_event where action = 'platform_admin.password_changed' and actor_user_id = '00000000-0000-4000-b900-0000000000e4' and source = 'edge:account'), 1, 'password: one audit row');
update public.platform_admin set must_change_password = true, temp_password_expires_at = now() - interval '1 minute';
select is(app.pa_password_changed('00000000-0000-4000-b900-0000000000e4'), '{"ok": false, "code": "expired"}'::jsonb, 'password: an expired temporary password is refused');
update public.platform_admin set status = 'inactive';
select is(app.pa_password_changed('00000000-0000-4000-b900-0000000000e4'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'password: an inactive SA is refused');
select is(app.pa_password_changed('00000000-0000-4000-b900-0000000000b1'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'password: a non-SA is refused');

-- Read functions (D6) ----------------------------------------------------------------------------------------------------------------------------------------
update public.platform_admin set status = 'active', must_change_password = false;
insert into public.platform_admin (user_id, full_name, phone_e164, status, must_change_password) values ('00000000-0000-4000-b900-0000000000a2', 'SA Two', '+919000021002', 'active', false);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b900-0000000000e4","role":"authenticated"}', true);
select ok((select count(*) from public.pa_tenant_summaries()) >= 3, 'summaries: an SA sees the tenants');
select results_eq($$ select name, status, plan_label, active_users, active_unit_admins from public.pa_tenant_summaries('org x2') $$,
  $$ values ('TAP21 ORG X2'::text, 'active'::text, 'trial'::text, 3, 2) $$, 'summaries: search by name with user counts (inactive members not counted)');
select is((select count(*)::int from public.pa_tenant_summaries(null, 'suspended')), 0, 'summaries: status filter');
select is((select count(*)::int from public.pa_tenant_summaries(null, null, 'active')), 1, 'summaries: plan filter');
select is((select count(*)::int from public.pa_tenant_summaries('%')), 0, 'summaries: LIKE wildcards in the search are literal');
select is((select count(*)::int from public.pa_tenant_summaries(null, null, null, 5)), 0, 'summaries: a page past the end is empty');
select is((select max(total_count)::int from public.pa_tenant_summaries()), (select count(*)::int from public.tenant), 'summaries: total_count is the full match count');
select results_eq($$ select full_name, phone_masked, status, must_change_password from public.pa_tenant_unit_admins('19000000-0000-4000-b900-00000000000a') order by full_name $$,
  $$ values ('First UA'::text, '+91******1201'::text, 'active'::text, true), ('UA Gone'::text, '+91******1103'::text, 'inactive'::text, false), ('UA X'::text, '+91******1101'::text, 'active'::text, true) $$,
  'unit admins: only Unit Admins, masked phones, status and the must-change flag');
select is((select count(*)::int from public.pa_tenant_unit_admins('19000000-0000-4000-b900-00000000000a') where full_name = 'Sup X'), 0, 'unit admins: supervisors are never listed');
select is((select count(*)::int from public.pa_super_admins()), 2, 'super admins: lists the platform admins');
select is((select count(*)::int from public.pa_super_admins() where is_self), 1, 'super admins: marks the caller');
select ok((select count(*) from public.pa_audit(0)) > 0, 'audit: an SA sees platform events');
select is((select count(*)::int from public.pa_audit(0) where action = 'access.denied' and reason = 'not_platform_admin'), 0, 'audit: denials of tenant users are not platform events');
select ok((select bool_and(source in ('edge:platform', 'edge:platform-setup', 'edge:account') ) from public.pa_audit(0)), 'audit: only platform sources');
select is((select count(*)::int from public.pa_audit(0) where tenant_id is not null and tenant_name is null), 0, 'audit: tenant names are resolved');
select is((select count(*)::int from public.pa_audit(0)), (select least(50, count(*))::int from public.pa_audit(0)), 'audit: pages hold at most 50');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b900-0000000000b1","role":"authenticated"}', true);
select is((select count(*)::int from public.pa_tenant_summaries()), 0, 'summaries: a tenant UA gets nothing');
select is((select count(*)::int from public.pa_tenant_unit_admins('19000000-0000-4000-b900-00000000000a')), 0, 'unit admins: a tenant UA gets nothing');
select is((select count(*)::int from public.pa_audit(0)), 0, 'audit: a tenant UA gets nothing');
select is((select count(*)::int from public.pa_super_admins()), 0, 'super admins: a tenant UA gets nothing');
reset role;
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = '00000000-0000-4000-b900-0000000000b1' and reason = 'not_platform_admin' and source like 'rpc:pa_%'), 4, 'read denials are audited under the caller''s tenant');

select * from finish();
rollback;
