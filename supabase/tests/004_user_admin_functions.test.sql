-- 02 AC-1,2,5,6,7,8,9,10,12 (DB part), D13: service-only user-admin functions.
-- Denials (not_allowed / expired) are COMMITTED + RETURNED as {ok:false, code}; validation/duplicate/guard RAISE P0001 with detail JSON.
-- Self-contained; rolled back. Phones come from the throwaway block +91 90000 14xxx.
begin;
create extension if not exists pgtap with schema extensions;
select plan(95);

-- helper: run a statement, return {code, field, message, sqlstate} of the error it raises (or {raised:false})
create function pg_temp.err(q text) returns jsonb language plpgsql as $f$
declare d text; m text; st text;
begin
  execute q;
  return jsonb_build_object('raised', false);
exception when others then
  get stacked diagnostics d = pg_exception_detail, m = message_text, st = returned_sqlstate;
  return coalesce(nullif(d, '')::jsonb, '{}'::jsonb) || jsonb_build_object('message', m, 'sqlstate', st);
end $f$;

-- Fixtures (as postgres) ---------------------------------------------------
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-b200-0000000000a1', 'tap4-ua1@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b200-0000000000a2', 'tap4-ua2@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b200-0000000000a3', 'tap4-sup1@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b200-0000000000a4', 'tap4-fresh@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b200-0000000000a5', 'tap4-inact@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b200-0000000000b1', 'tap4-uy@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b200-0000000000d1', 'tap4-zua@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b200-0000000000c1', 'tap4-nomember@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b200-0000000000e1', 'tap4-new1@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b200-0000000000e2', 'tap4-new2@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b200-0000000000e3', 'tap4-new3@example.test', 'authenticated', 'authenticated');
insert into public.tenant (id, name, status) values
  ('16000000-0000-4000-b200-00000000000a', 'tap4 org X', 'active'),
  ('16000000-0000-4000-b200-00000000000b', 'tap4 org Y', 'active'),
  ('16000000-0000-4000-b200-00000000000d', 'tap4 org Z', 'suspended');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password, temp_password_expires_at) values
  ('16000000-0000-4000-b200-00000000000a', '00000000-0000-4000-b200-0000000000a1', 'unit_admin', 'active', 'Asha UA', 'UA-1', '+919000014001', false, null),
  ('16000000-0000-4000-b200-00000000000a', '00000000-0000-4000-b200-0000000000a2', 'unit_admin', 'active', 'Bina UA', 'UA-2', '+919000014002', false, null),
  ('16000000-0000-4000-b200-00000000000a', '00000000-0000-4000-b200-0000000000a3', 'supervisor', 'active', 'Ravi Sup', 'SUP-1', '+919000014003', false, null),
  ('16000000-0000-4000-b200-00000000000a', '00000000-0000-4000-b200-0000000000a4', 'supervisor', 'active', 'Fresh Sup', 'SUP-2', '+919000014004', true, now() + interval '20 hours'),
  ('16000000-0000-4000-b200-00000000000a', '00000000-0000-4000-b200-0000000000a5', 'unit_admin', 'inactive', 'Gone UA', 'UA-3', '+919000014005', false, null),
  ('16000000-0000-4000-b200-00000000000b', '00000000-0000-4000-b200-0000000000b1', 'unit_admin', 'active', 'Yash UA', 'UA-1', '+919000014006', false, null),
  ('16000000-0000-4000-b200-00000000000d', '00000000-0000-4000-b200-0000000000d1', 'unit_admin', 'active', 'Zed UA', 'UA-1', '+919000014007', false, null);

-- Privileges -------------------------------------------------------------------
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'app' and p.proname not in ('current_tenant_id', 'current_role')
             and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0,
  'no app function except the two RLS helpers is executable by anon or authenticated');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'app' and p.proname ~ '^(ua_|account_|audit_denied)' and not has_function_privilege('service_role', p.oid, 'execute')), 0,
  'service_role can execute every ua_*, account_* and audit_denied function');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'app' and p.proname ~ '^(ua_|account_|audit_denied|_ua_)' and (not p.prosecdef or p.proconfig is null or not ('search_path=""' = any (p.proconfig)))), 0,
  'every service function is security definer with an empty search_path');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname ~ '^svc_' and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0,
  'no public.svc_* wrapper is executable by anon or authenticated');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname ~ '^svc_' and not has_function_privilege('service_role', p.oid, 'execute')), 0,
  'service_role can execute every public.svc_* wrapper');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname ~ '^svc_'), 8,
  'there are 8 svc_* wrappers (one per Edge Function entry point)');
set local role service_role;
select is((public.svc_ua_set_status('00000000-0000-4000-b200-0000000000a1', '17000000-0000-4000-b200-000000000009', '00000000-0000-4000-b200-0000000000a3', 'active'))->>'ok', 'true',
  'service_role can call a wrapper (end to end through app.ua_set_status)');
reset role;
set local role authenticated;
select throws_ok($$ select public.svc_ua_set_status('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000a3', 'inactive') $$, '42501', null, 'authenticated cannot call a wrapper');
select throws_ok($$ select app.ua_set_status('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000a3', 'inactive') $$, '42501', null, 'authenticated cannot call ua_set_status');
reset role;
set local role anon;
select throws_ok($$ select app.audit_denied('00000000-0000-4000-b200-0000000000a1', '16000000-0000-4000-b200-00000000000a', 'unit_admin', 'role', null, null, 'x') $$, '42501', null, 'anon cannot call audit_denied');
reset role;

-- Create: success --------------------------------------------------------------------
select is((app.ua_check_create('00000000-0000-4000-b200-0000000000a1', '17000000-0000-4000-b200-000000000001', 'New One', 'N-1', '+919000014101', 'supervisor'))->>'ok', 'true', 'check_create: valid input passes');
select is((select count(*)::int from public.membership where phone_e164 = '+919000014101'), 0, 'check_create writes nothing');
select is((app.ua_create_user('00000000-0000-4000-b200-0000000000a1', '17000000-0000-4000-b200-000000000001', '00000000-0000-4000-b200-0000000000e1', '  New One  ', 'N-1', '+919000014101', 'supervisor'))->>'user_id', '00000000-0000-4000-b200-0000000000e1', 'create: returns the user id');
select results_eq($$ select full_name, role::text, status::text, must_change_password, created_by, tenant_id
                     from public.membership where user_id = '00000000-0000-4000-b200-0000000000e1' $$,
  $$ values ('New One'::text, 'supervisor'::text, 'active'::text, true, '00000000-0000-4000-b200-0000000000a1'::uuid, '16000000-0000-4000-b200-00000000000a'::uuid) $$,
  'create: membership is active in the actor''s tenant, name trimmed, must change password, created_by set');
select ok((select temp_password_expires_at > now() + interval '23 hours' and temp_password_expires_at <= now() + interval '24 hours'
           from public.membership where user_id = '00000000-0000-4000-b200-0000000000e1'), 'create: temporary password expires in 24 hours');
select results_eq($$ select action, tenant_id, actor_user_id, actor_role, entity_id, before is null, after->>'phone', after->>'role', request_id
                     from public.audit_event where action = 'user.created' and actor_user_id = '00000000-0000-4000-b200-0000000000a1' $$,
  $$ values ('user.created'::text, '16000000-0000-4000-b200-00000000000a'::uuid, '00000000-0000-4000-b200-0000000000a1'::uuid, 'unit_admin'::text, '00000000-0000-4000-b200-0000000000e1'::uuid, true, '+91******4101'::text, 'supervisor'::text, '17000000-0000-4000-b200-000000000001'::uuid) $$,
  'create: exactly one audit row with masked phone');
select is((select count(*)::int from public.audit_event where after::text like '%9000014101%'), 0, 'create: the full phone never reaches audit_event');

-- Create: idempotency ----------------------------------------------------------------
select results_eq($$ select (r->>'ok')::boolean, (r->>'already')::boolean, r->>'user_id'
                     from (select app.ua_check_create('00000000-0000-4000-b200-0000000000a1', '17000000-0000-4000-b200-000000000001', 'New One', 'N-1', '+919000014101', 'supervisor') r) s $$,
  $$ values (true, true, '00000000-0000-4000-b200-0000000000e1'::text) $$, 'check_create with a used request id reports already done');
select is((app.ua_create_user('00000000-0000-4000-b200-0000000000a1', '17000000-0000-4000-b200-000000000001', '00000000-0000-4000-b200-0000000000e2', 'New One', 'N-1', '+919000014101', 'supervisor'))->>'user_id', '00000000-0000-4000-b200-0000000000e1', 'create: retry returns the first outcome');
select is((select count(*)::int from public.audit_event where action = 'user.created' and actor_user_id = '00000000-0000-4000-b200-0000000000a1'), 1, 'create: retry writes no second audit row');

-- Create: validation and duplicates (raise) ---------------------------------------------
select is(pg_temp.err($$ select app.ua_create_user('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000e2', '   ', 'N-2', '+919000014102', 'supervisor') $$)
          @> '{"code":"validation","field":"full_name","sqlstate":"P0001"}', true, 'blank name -> validation/full_name');
select is(pg_temp.err($$ select app.ua_create_user('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000e2', repeat('n', 81), 'N-2', '+919000014102', 'supervisor') $$)
          @> '{"code":"validation","field":"full_name"}', true, 'name over 80 chars -> validation/full_name');
select is(pg_temp.err($$ select app.ua_create_user('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000e2', 'Ok', 'bad id!', '+919000014102', 'supervisor') $$)
          @> '{"code":"validation","field":"employee_id"}', true, 'bad employee id -> validation/employee_id');
select is(pg_temp.err($$ select app.ua_create_user('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000e2', 'Ok', 'N-2', '+915000014102', 'supervisor') $$)
          @> '{"code":"validation","field":"phone"}', true, 'bad phone -> validation/phone');
select is(pg_temp.err($$ select app.ua_create_user('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000e2', 'Ok', 'N-2', '+919000014102', 'maintenance') $$)
          @> '{"code":"validation","field":"role"}', true, 'role maintenance -> validation/role');
select is(pg_temp.err($$ select app.ua_create_user('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000e2', 'Ok', 'N-2', '+919000014006', 'supervisor') $$)
          @> '{"code":"duplicate","field":"phone","message":"This phone number is already registered"}', true,
  'phone used by another tenant -> duplicate/phone with the neutral message');
select is(pg_temp.err($$ select app.ua_create_user('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000e2', 'Ok', 'n-1', '+919000014102', 'supervisor') $$)
          @> '{"code":"duplicate","field":"employee_id"}', true, 'employee id differing only by case -> duplicate/employee_id');
select is(pg_temp.err($$ select app.ua_check_create('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), 'Ok', 'ua-1', '+919000014102', 'supervisor') $$)
          @> '{"code":"duplicate","field":"employee_id"}', true, 'check_create sees the same duplicate');
select is((select count(*)::int from public.membership where tenant_id = '16000000-0000-4000-b200-00000000000a'), 6, 'failed creates leave no rows behind');

-- Denials: returned + committed audit (D13) ------------------------------------------------
select is(app.ua_create_user('00000000-0000-4000-b200-0000000000a3', gen_random_uuid(), '00000000-0000-4000-b200-0000000000e2', 'Ok', 'N-2', '+919000014102', 'supervisor'),
          '{"ok": false, "code": "not_allowed"}'::jsonb, 'SUP actor: create returns not_allowed');
select is(app.ua_check_create('00000000-0000-4000-b200-0000000000a3', gen_random_uuid(), 'Ok', 'N-2', '+919000014102', 'supervisor'),
          '{"ok": false, "code": "not_allowed"}'::jsonb, 'SUP actor: check_create returns not_allowed');
select is((select count(*)::int from public.membership where phone_e164 = '+919000014102'), 0, 'SUP actor: nothing created');
select results_eq($$ select tenant_id, actor_user_id, actor_role, reason, request_id is null from public.audit_event
                     where action = 'access.denied' and actor_user_id = '00000000-0000-4000-b200-0000000000a3' $$,
  $$ values ('16000000-0000-4000-b200-00000000000a'::uuid, '00000000-0000-4000-b200-0000000000a3'::uuid, 'supervisor'::text, 'role'::text, true),
            ('16000000-0000-4000-b200-00000000000a'::uuid, '00000000-0000-4000-b200-0000000000a3'::uuid, 'supervisor'::text, 'role'::text, true) $$,
  'SUP actor: each denial committed an access.denied (role) under the actor''s tenant, request id null');
select is(app.ua_update_user('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000b1', 'Hacked', null, null, null),
          '{"ok": false, "code": "not_allowed"}'::jsonb, 'cross-tenant update returns not_allowed');
select is(app.ua_set_status('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000b1', 'inactive'),
          '{"ok": false, "code": "not_allowed"}'::jsonb, 'cross-tenant set_status returns not_allowed');
select is(app.ua_reset_password('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000b1'),
          '{"ok": false, "code": "not_allowed"}'::jsonb, 'cross-tenant reset returns not_allowed');
select results_eq($$ select tenant_id, entity_id, reason from public.audit_event
                     where action = 'access.denied' and actor_user_id = '00000000-0000-4000-b200-0000000000a1' and reason = 'cross_tenant' $$,
  $$ values ('16000000-0000-4000-b200-00000000000a'::uuid, '00000000-0000-4000-b200-0000000000b1'::uuid, 'cross_tenant'::text), ('16000000-0000-4000-b200-00000000000a'::uuid, '00000000-0000-4000-b200-0000000000b1'::uuid, 'cross_tenant'::text), ('16000000-0000-4000-b200-00000000000a'::uuid, '00000000-0000-4000-b200-0000000000b1'::uuid, 'cross_tenant'::text) $$,
  'cross-tenant attempts are audited under the actor''s tenant (X), never Y');
select is((select membership.full_name from public.membership where user_id = '00000000-0000-4000-b200-0000000000b1'), 'Yash UA', 'cross-tenant update changed nothing');
select is(app.ua_set_status('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), gen_random_uuid(), 'inactive'),
          '{"ok": false, "code": "not_allowed"}'::jsonb, 'unknown target gives the identical denial (no existence leak)');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and reason = 'not_found' and actor_user_id = '00000000-0000-4000-b200-0000000000a1'), 1,
  'unknown target is audited with its own reason');
select is(app.ua_set_status('00000000-0000-4000-b200-0000000000a5', gen_random_uuid(), '00000000-0000-4000-b200-0000000000a3', 'inactive'),
          '{"ok": false, "code": "not_allowed"}'::jsonb, 'inactive UA is denied (AC-12)');
select is(app.ua_set_status('00000000-0000-4000-b200-0000000000d1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000d1', 'inactive'),
          '{"ok": false, "code": "not_allowed"}'::jsonb, 'UA of a suspended tenant is denied (AC-12)');
select is((select tenant_id from public.audit_event where action = 'access.denied' and actor_user_id = '00000000-0000-4000-b200-0000000000d1'), '16000000-0000-4000-b200-00000000000d'::uuid,
  'suspended-tenant denial is recorded under that tenant');
select is(app.ua_create_user('00000000-0000-4000-b200-0000000000a4', gen_random_uuid(), '00000000-0000-4000-b200-0000000000e2', 'Ok', 'N-2', '+919000014102', 'supervisor'),
          '{"ok": false, "code": "not_allowed"}'::jsonb, 'must-change user is denied');
select is((select reason from public.audit_event where action = 'access.denied' and actor_user_id = '00000000-0000-4000-b200-0000000000a4'), 'must_change_password',
  'must-change denial has its own reason');
select is(app.ua_create_user('00000000-0000-4000-b200-0000000000c1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000e2', 'Ok', 'N-2', '+919000014102', 'supervisor'),
          '{"ok": false, "code": "not_allowed"}'::jsonb, 'caller without membership is denied');
select results_eq($$ select tenant_id is null, reason from public.audit_event where action = 'access.denied' and actor_user_id = '00000000-0000-4000-b200-0000000000c1' $$,
  $$ values (true, 'no_membership'::text) $$, 'no-membership denial is recorded with a null tenant');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and request_id is not null), 0,
  'denied events never carry a request id');
select lives_ok($$ select app.audit_denied('00000000-0000-4000-b200-0000000000a1', '16000000-0000-4000-b200-00000000000a', 'unit_admin', 'manual', 'user', null, 'edge:user-admin') $$, 'audit_denied can be called directly');

-- Update ---------------------------------------------------------------------------------
select is((app.ua_check_update('00000000-0000-4000-b200-0000000000a1', '17000000-0000-4000-b200-000000000002', '00000000-0000-4000-b200-0000000000a3', 'Ravi Kumar', null, '+919000014103', null))->>'ok', 'true', 'check_update: valid input passes');
select is((app.ua_check_update('00000000-0000-4000-b200-0000000000a1', '17000000-0000-4000-b200-000000000002', '00000000-0000-4000-b200-0000000000a3', 'Ravi Kumar', null, '+919000014111', null))->>'current_phone', '+919000014003', 'check_update returns the current phone');
select is((app.ua_check_update('00000000-0000-4000-b200-0000000000a1', '17000000-0000-4000-b200-000000000002', '00000000-0000-4000-b200-0000000000a3', null, null, '+919000014111', null))->>'phone_changed', 'true', 'check_update reports a phone change');
select is((app.ua_update_user('00000000-0000-4000-b200-0000000000a1', '17000000-0000-4000-b200-000000000002', '00000000-0000-4000-b200-0000000000a3', 'Ravi Kumar', 'SUP-1B', '+919000014111', null))->>'ok', 'true', 'update: succeeds');
select results_eq($$ select full_name, employee_id, phone_e164, role::text from public.membership where user_id = '00000000-0000-4000-b200-0000000000a3' $$,
  $$ values ('Ravi Kumar'::text, 'SUP-1B'::text, '+919000014111'::text, 'supervisor'::text) $$, 'update: fields changed, role untouched');
select results_eq($$ select before->>'full_name', after->>'full_name', before->>'phone', after->>'phone', before->>'employee_id', after->>'employee_id', tenant_id, request_id
                     from public.audit_event where action = 'user.updated' and actor_user_id = '00000000-0000-4000-b200-0000000000a1' $$,
  $$ values ('Ravi Sup'::text, 'Ravi Kumar'::text, '+91******4003'::text, '+91******4111'::text, 'SUP-1'::text, 'SUP-1B'::text, '16000000-0000-4000-b200-00000000000a'::uuid, '17000000-0000-4000-b200-000000000002'::uuid) $$,
  'update: one audit row with before/after and masked phones');
select is(app.ua_update_user('00000000-0000-4000-b200-0000000000a1', '17000000-0000-4000-b200-000000000002', '00000000-0000-4000-b200-0000000000a3', 'Ravi Kumar', 'SUP-1B', '+919000014111', null), '{"ok": true, "already": true, "user_id": "00000000-0000-4000-b200-0000000000a3"}'::jsonb,
  'update: retry returns the first outcome');
select is((select count(*)::int from public.audit_event where action = 'user.updated'), 1, 'update: retry writes no second audit row');
select is(pg_temp.err($$ select app.ua_update_user('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000a3', null, null, '+919000014001', null) $$)
          @> '{"code":"duplicate","field":"phone"}', true, 'update to a phone in use -> duplicate/phone');
select is(pg_temp.err($$ select app.ua_update_user('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000a3', null, 'ua-2', null, null) $$)
          @> '{"code":"duplicate","field":"employee_id"}', true, 'update to an employee id in use -> duplicate/employee_id');
select is((app.ua_update_user('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000a3', null, 'sup-1b', null, null))->>'ok', 'true', 'update: re-casing the own employee id is not a duplicate');
select is(pg_temp.err($$ select app.ua_update_user('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000a3', null, null, null, 'maintenance') $$)
          @> '{"code":"validation","field":"role"}', true, 'update: invalid role -> validation/role');
select is(pg_temp.err($$ select app.ua_update_user('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000a1', null, null, null, 'supervisor') $$)
          @> '{"code":"guard","field":"self"}', true, 'a UA cannot demote themself');
select is((app.ua_update_user('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000a1', 'Asha Rao', null, null, 'unit_admin'))->>'ok', 'true', 'a UA can edit their own name and keep their role');

-- Mutual demotion: the second UA is no longer a UA, so the tenant keeps one (AC-8) -----------
select is((app.ua_update_user('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000a2', null, null, null, 'supervisor'))->>'ok', 'true', 'UA1 demotes UA2');
select is(app.ua_update_user('00000000-0000-4000-b200-0000000000a2', gen_random_uuid(), '00000000-0000-4000-b200-0000000000a1', null, null, null, 'supervisor'), '{"ok": false, "code": "not_allowed"}'::jsonb,
  'UA2 (now a supervisor) cannot demote UA1 back');
select is((select count(*)::int from public.membership where tenant_id = '16000000-0000-4000-b200-00000000000a' and role = 'unit_admin' and status = 'active'), 1,
  'the tenant still has exactly one active Unit Admin');

-- Set status ---------------------------------------------------------------------------------
select is(pg_temp.err($$ select app.ua_set_status('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000a1', 'inactive') $$)
          @> '{"code":"guard","field":"self"}', true, 'a UA cannot deactivate themself');
select is(pg_temp.err($$ select app.ua_set_status('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000a3', 'frozen') $$)
          @> '{"code":"validation","field":"status"}', true, 'unknown status -> validation/status');
select is((app.ua_set_status('00000000-0000-4000-b200-0000000000a1', '17000000-0000-4000-b200-000000000003', '00000000-0000-4000-b200-0000000000a3', 'inactive'))->>'ok', 'true', 'deactivate succeeds');
select is((select status::text from public.membership where user_id = '00000000-0000-4000-b200-0000000000a3'), 'inactive', 'deactivate: membership is inactive');
select is((select count(*)::int from public.audit_event where action = 'user.deactivated' and entity_id = '00000000-0000-4000-b200-0000000000a3' and tenant_id = '16000000-0000-4000-b200-00000000000a'), 1, 'deactivate: one audit row');
select is((app.ua_set_status('00000000-0000-4000-b200-0000000000a1', '17000000-0000-4000-b200-000000000003', '00000000-0000-4000-b200-0000000000a3', 'inactive'))->>'ok', 'true', 'deactivate: retry with the same request id succeeds');
select is((app.ua_set_status('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000a3', 'inactive'))->>'changed', 'false', 'deactivate: an already inactive user reports no change');
select is((select count(*)::int from public.audit_event where action = 'user.deactivated'), 1, 'deactivate: no extra audit rows for retries or no-ops');
select is((app.ua_set_status('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000a3', 'active'))->>'ok', 'true', 'reactivate succeeds');
select results_eq($$ select status::text, must_change_password from public.membership where user_id = '00000000-0000-4000-b200-0000000000a3' $$,
  $$ values ('active'::text, false) $$, 'reactivate: back to active, password state untouched');
select is((select count(*)::int from public.audit_event where action = 'user.reactivated' and entity_id = '00000000-0000-4000-b200-0000000000a3'), 1, 'reactivate: one audit row');

-- Reset password -----------------------------------------------------------------------------
select is(pg_temp.err($$ select app.ua_reset_password('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000a1') $$)
          @> '{"code":"guard","field":"self"}', true, 'a UA cannot reset themself');
select is((app.ua_reset_password('00000000-0000-4000-b200-0000000000a1', '17000000-0000-4000-b200-000000000004', '00000000-0000-4000-b200-0000000000a3'))->>'ok', 'true', 'reset succeeds');
select results_eq($$ select must_change_password, temp_password_expires_at > now() + interval '23 hours' from public.membership where user_id = '00000000-0000-4000-b200-0000000000a3' $$,
  $$ values (true, true) $$, 'reset: must change password again with a fresh 24h expiry');
select is((select count(*)::int from public.audit_event where action = 'user.password_reset' and entity_id = '00000000-0000-4000-b200-0000000000a3' and request_id = '17000000-0000-4000-b200-000000000004'), 1, 'reset: one audit row');
select is(app.ua_reset_password('00000000-0000-4000-b200-0000000000a1', '17000000-0000-4000-b200-000000000004', '00000000-0000-4000-b200-0000000000a3'), '{"ok": true, "already": true, "user_id": "00000000-0000-4000-b200-0000000000a3"}'::jsonb, 'reset: retry reports already done');
select is((select count(*)::int from public.audit_event where action = 'user.password_reset'), 1, 'reset: retry writes no second audit row');
select is((app.ua_set_status('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000a4', 'inactive'))->>'ok', 'true', 'fixture: deactivate FRESH');
select is(pg_temp.err($$ select app.ua_reset_password('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000a4') $$)
          @> '{"code":"guard","field":"inactive"}', true, 'reset of an inactive user is refused');
select is((app.ua_set_status('00000000-0000-4000-b200-0000000000a1', gen_random_uuid(), '00000000-0000-4000-b200-0000000000a4', 'active'))->>'ok', 'true', 'fixture: reactivate FRESH');

-- Account: own password change ---------------------------------------------------------------
select is((app.account_password_changed('00000000-0000-4000-b200-0000000000a4'))->>'ok', 'true', 'first password change succeeds');
select results_eq($$ select must_change_password, temp_password_expires_at is null from public.membership where user_id = '00000000-0000-4000-b200-0000000000a4' $$,
  $$ values (false, true) $$, 'change: flag and expiry cleared');
select results_eq($$ select tenant_id, actor_user_id, entity_id, source from public.audit_event where action = 'user.password_changed' and actor_user_id = '00000000-0000-4000-b200-0000000000a4' $$,
  $$ values ('16000000-0000-4000-b200-00000000000a'::uuid, '00000000-0000-4000-b200-0000000000a4'::uuid, '00000000-0000-4000-b200-0000000000a4'::uuid, 'edge:account'::text) $$, 'change: one audit row by the user on themself');
select is((app.account_password_changed('00000000-0000-4000-b200-0000000000a4'))->>'ok', 'true', 'self-service change for a normal user succeeds');
update public.membership set must_change_password = true, temp_password_expires_at = now() - interval '1 minute' where user_id = '00000000-0000-4000-b200-0000000000e1';
select is(app.account_password_changed('00000000-0000-4000-b200-0000000000e1'), '{"ok": false, "code": "expired"}'::jsonb, 'expired temporary password is refused');
select results_eq($$ select must_change_password from public.membership where user_id = '00000000-0000-4000-b200-0000000000e1' $$, $$ values (true) $$, 'expired: flag stays set');
select results_eq($$ select action, reason from public.audit_event where actor_user_id = '00000000-0000-4000-b200-0000000000e1' and action <> 'user.created' $$,
  $$ values ('access.denied'::text, 'temp_password_expired'::text) $$, 'expired: only access.denied (temp_password_expired) is written');
select is(app.account_password_changed('00000000-0000-4000-b200-0000000000c1'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'no membership: not_allowed');
select is(app.account_password_changed('00000000-0000-4000-b200-0000000000a5'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'inactive user: not_allowed');

select * from finish();
rollback;
