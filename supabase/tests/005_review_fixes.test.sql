-- 02 review fixes R1 (session revocation), R2 (compensation reason, already status), R5 (account_check), R8 (policies unchanged).
-- Self-contained; rolled back. Phones from the throwaway block +91 90000 15xxx.
begin;
create extension if not exists pgtap with schema extensions;
select plan(30);

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-b500-0000000000a1', 'tap5-ua@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b500-0000000000a2', 'tap5-sup@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b500-0000000000a3', 'tap5-other@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b500-0000000000a4', 'tap5-expired@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b500-0000000000a5', 'tap5-inactive@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b500-0000000000b1', 'tap5-susp@example.test', 'authenticated', 'authenticated');
insert into public.tenant (id, name, status) values
  ('16000000-0000-4000-b500-00000000000a', 'tap5 org X', 'active'),
  ('16000000-0000-4000-b500-00000000000b', 'tap5 org S', 'suspended');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password, temp_password_expires_at) values
  ('16000000-0000-4000-b500-00000000000a', '00000000-0000-4000-b500-0000000000a1', 'unit_admin', 'active', 'UA', 'UA-1', '+919000015001', false, null),
  ('16000000-0000-4000-b500-00000000000a', '00000000-0000-4000-b500-0000000000a2', 'supervisor', 'active', 'Sup', 'SUP-1', '+919000015002', false, null),
  ('16000000-0000-4000-b500-00000000000a', '00000000-0000-4000-b500-0000000000a3', 'supervisor', 'active', 'Other', 'SUP-2', '+919000015003', false, null),
  ('16000000-0000-4000-b500-00000000000a', '00000000-0000-4000-b500-0000000000a4', 'supervisor', 'active', 'Expired', 'SUP-3', '+919000015004', true, now() - interval '1 hour'),
  ('16000000-0000-4000-b500-00000000000a', '00000000-0000-4000-b500-0000000000a5', 'supervisor', 'inactive', 'Inactive', 'SUP-4', '+919000015005', false, null),
  ('16000000-0000-4000-b500-00000000000b', '00000000-0000-4000-b500-0000000000b1', 'supervisor', 'active', 'Susp', 'SUP-5', '+919000015006', false, null);

-- sessions: two for SUP (s1 is "this" session), one for OTHER
insert into auth.sessions (id, user_id) values
  ('51000000-0000-4000-b500-000000000001', '00000000-0000-4000-b500-0000000000a2'),
  ('51000000-0000-4000-b500-000000000002', '00000000-0000-4000-b500-0000000000a2'),
  ('51000000-0000-4000-b500-000000000003', '00000000-0000-4000-b500-0000000000a3');

-- R1 ------------------------------------------------------------------------------------------------------------------
select ok(not has_function_privilege('anon', 'app._revoke_sessions(uuid, uuid)', 'execute')
      and not has_function_privilege('authenticated', 'app._revoke_sessions(uuid, uuid)', 'execute')
      and has_function_privilege('service_role', 'app._revoke_sessions(uuid, uuid)', 'execute'), '_revoke_sessions is service-only');

select app._revoke_sessions('00000000-0000-4000-b500-0000000000a2', '51000000-0000-4000-b500-000000000001');
select is((select count(*)::int from auth.sessions where user_id = '00000000-0000-4000-b500-0000000000a2'), 1, 'revoke keeps only the kept session');
select is((select id from auth.sessions where user_id = '00000000-0000-4000-b500-0000000000a2'), '51000000-0000-4000-b500-000000000001'::uuid, 'the kept session is the one passed in');
select is((select count(*)::int from auth.sessions where user_id = '00000000-0000-4000-b500-0000000000a3'), 1, 'another user''s session is untouched');
select app._revoke_sessions('00000000-0000-4000-b500-0000000000a2');
select is((select count(*)::int from auth.sessions where user_id = '00000000-0000-4000-b500-0000000000a2'), 0, 'with no kept session all are removed');

-- deactivate removes the target's sessions, reactivate adds nothing and removes nothing
insert into auth.sessions (id, user_id) values ('51000000-0000-4000-b500-000000000004', '00000000-0000-4000-b500-0000000000a2');
select is((app.ua_set_status('00000000-0000-4000-b500-0000000000a1', '71000000-0000-4000-b500-000000000001', '00000000-0000-4000-b500-0000000000a2', 'inactive', null))->>'changed', 'true', 'deactivate succeeds');
select is((select count(*)::int from auth.sessions where user_id = '00000000-0000-4000-b500-0000000000a2'), 0, 'deactivate deletes the user''s sessions');
select is((select count(*)::int from auth.sessions where user_id = '00000000-0000-4000-b500-0000000000a3'), 1, 'deactivate leaves other users'' sessions');
insert into auth.sessions (id, user_id) values ('51000000-0000-4000-b500-000000000005', '00000000-0000-4000-b500-0000000000a3');
select app.ua_set_status('00000000-0000-4000-b500-0000000000a1', '71000000-0000-4000-b500-000000000002', '00000000-0000-4000-b500-0000000000a2', 'active', null);
select is((select count(*)::int from auth.sessions where user_id = '00000000-0000-4000-b500-0000000000a3'), 2, 'reactivate removes no sessions');

-- reset removes every session of the target
select is((app.ua_reset_password('00000000-0000-4000-b500-0000000000a1', '71000000-0000-4000-b500-000000000003', '00000000-0000-4000-b500-0000000000a3'))->>'ok', 'true', 'reset succeeds');
select is((select count(*)::int from auth.sessions where user_id = '00000000-0000-4000-b500-0000000000a3'), 0, 'reset deletes every session of the target');

-- account_password_changed keeps only the caller's session (a reset user changes their password)
update public.membership set must_change_password = true, temp_password_expires_at = now() + interval '1 hour' where user_id = '00000000-0000-4000-b500-0000000000a3';
insert into auth.sessions (id, user_id) values
  ('51000000-0000-4000-b500-000000000006', '00000000-0000-4000-b500-0000000000a3'),
  ('51000000-0000-4000-b500-000000000007', '00000000-0000-4000-b500-0000000000a3');
select is((app.account_password_changed('00000000-0000-4000-b500-0000000000a3', '51000000-0000-4000-b500-000000000006'))->>'ok', 'true', 'password change succeeds');
select is((select array_agg(id::text) from auth.sessions where user_id = '00000000-0000-4000-b500-0000000000a3'), array['51000000-0000-4000-b500-000000000006'], 'only the caller''s session survives a password change');

-- denied paths revoke nothing
insert into auth.sessions (id, user_id) values ('51000000-0000-4000-b500-000000000008', '00000000-0000-4000-b500-0000000000a4');
select is((app.account_password_changed('00000000-0000-4000-b500-0000000000a4', null))->>'code', 'expired', 'expired temporary password is refused');
select is((select count(*)::int from auth.sessions where user_id = '00000000-0000-4000-b500-0000000000a4'), 1, 'a refused change revokes nothing');

-- R2: compensation reason ----------------------------------------------------------------------------------------------
select app.ua_set_status('00000000-0000-4000-b500-0000000000a1', '71000000-0000-4000-b500-000000000004', '00000000-0000-4000-b500-0000000000a2', 'inactive', 'compensation');
select is((select reason from public.audit_event where request_id = '71000000-0000-4000-b500-000000000004'), 'compensation', 'a compensating status change is audited with reason = compensation');
select is((app.ua_set_status('00000000-0000-4000-b500-0000000000a1', '71000000-0000-4000-b500-000000000004', '00000000-0000-4000-b500-0000000000a2', 'inactive', 'compensation'))->>'status', 'inactive', 'an already-applied request returns the current status so the function can re-sync Auth');
select is((select reason from public.audit_event where request_id = '71000000-0000-4000-b500-000000000002'), null, 'normal status changes carry no reason');

-- R5: account_check -------------------------------------------------------------------------------------------------------
select is((app.account_check('00000000-0000-4000-b500-0000000000a1'))->>'ok', 'true', 'active user passes the check');
select is((select count(*)::int from public.audit_event where actor_user_id = '00000000-0000-4000-b500-0000000000a1' and action = 'access.denied'), 0, 'a pass writes nothing');
select is((app.account_check('00000000-0000-4000-b500-0000000000a5'))->>'code', 'not_allowed', 'inactive member is refused');
select is((select reason from public.audit_event where actor_user_id = '00000000-0000-4000-b500-0000000000a5' and action = 'access.denied'), 'inactive', 'the refusal is audited as inactive');
select is((app.account_check('00000000-0000-4000-b500-0000000000b1'))->>'code', 'not_allowed', 'a suspended tenant is refused');
select is((app.account_check('00000000-0000-4000-b500-0000000000a4'))->>'code', 'expired', 'expired temporary password is refused');
select is((app.account_check('00000000-0000-4000-b500-0000000000c9'))->>'code', 'not_allowed', 'a user with no membership is refused');
select is((app.account_password_changed('00000000-0000-4000-b500-0000000000a5', null, true))->>'code', 'not_allowed', 'check-only mode refuses an inactive member without writing a password change');
select is((app.account_password_changed('00000000-0000-4000-b500-0000000000a1', null, true))->>'ok', 'true', 'check-only mode passes an active member');
select is((select count(*)::int from public.audit_event where action = 'user.password_changed' and entity_id = '00000000-0000-4000-b500-0000000000a1'), 0, 'check-only mode changes and audits nothing');
select ok(not has_function_privilege('authenticated', 'public.svc_account_password_changed(uuid, uuid, boolean)', 'execute') and has_function_privilege('service_role', 'public.svc_account_password_changed(uuid, uuid, boolean)', 'execute'), 'the account wrapper is service-only');

-- R8: policies use the cached-subselect form ---------------------------------------------------------------------------------
select ok((select bool_and(qual like '%SELECT app.current_tenant_id()%' or qual like '%( SELECT app.current_tenant_id()%' or qual like '%(SELECT app.current_tenant_id()%')
          from pg_policies where schemaname = 'public' and policyname in ('tenant_select_own', 'membership_select', 'audit_event_select_ua')), 'tenant policies wrap current_tenant_id() in a subselect');

select * from finish();
rollback;
