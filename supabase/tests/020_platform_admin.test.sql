-- 03 step 1 (AC-1, AC-11 part): platform_admin identity, phone_claim uniqueness across membership and platform_admin,
-- is_platform_admin() gate, tenant columns, SA select on tenant only. Self-contained; rolled back.
-- Phones from the throwaway block +91 90000 20xxx.
begin;
create extension if not exists pgtap with schema extensions;
select plan(41);

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-b800-0000000000a1', 'tap20-sa1@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b800-0000000000a2', 'tap20-sa2-inactive@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b800-0000000000a3', 'tap20-sa3-must@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b800-0000000000b1', 'tap20-ua@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b800-0000000000b2', 'tap20-sup@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b800-0000000000c1', 'tap20-sa4@example.test', 'authenticated', 'authenticated');
insert into public.tenant (id, name, status) values
  ('18000000-0000-4000-b800-00000000000a', 'tap20 org X', 'active'),
  ('18000000-0000-4000-b800-00000000000b', 'tap20 org Y', 'suspended');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('18000000-0000-4000-b800-00000000000a', '00000000-0000-4000-b800-0000000000b1', 'unit_admin', 'active', 'UA X', 'UA-1', '+919000020101', false),
  ('18000000-0000-4000-b800-00000000000a', '00000000-0000-4000-b800-0000000000b2', 'supervisor', 'active', 'Sup X', 'SUP-1', '+919000020102', false);
insert into public.platform_admin (user_id, full_name, phone_e164, status, must_change_password) values
  ('00000000-0000-4000-b800-0000000000a1', 'SA One', '+919000020001', 'active', false),
  ('00000000-0000-4000-b800-0000000000a2', 'SA Inactive', '+919000020002', 'inactive', false),
  ('00000000-0000-4000-b800-0000000000a3', 'SA Must Change', '+919000020003', 'active', true);

-- Structure ----------------------------------------------------------------------------------------------------------------
select ok((select relrowsecurity and relforcerowsecurity from pg_class where oid = 'public.platform_admin'::regclass), 'RLS enabled and forced on platform_admin');
select is((select plan_label::text from public.tenant where id = '18000000-0000-4000-b800-00000000000a'), 'trial', 'tenant.plan_label defaults to trial');
select col_not_null('public', 'tenant', 'updated_at', 'tenant.updated_at exists and is not null');
select col_is_null('public', 'tenant', 'suspended_reason', 'tenant.suspended_reason is nullable');
select throws_ok($$ insert into public.tenant (name) values ('TAP20 ORG x') $$, '23505', null, 'tenant name is unique case-insensitively');
select throws_ok($$ insert into public.tenant (name, plan_label) values ('tap20 bad plan', 'gold') $$, '22P02', null, 'plan_label accepts only trial or active');
select lives_ok($$ insert into public.tenant (name, plan_label) values ('tap20 active plan', 'active') $$, 'plan_label active is accepted');
select is((select count(*)::int from app.audit_action where feature = '03'), 9, 'the nine 03 audit actions are registered');
select throws_ok($$ insert into public.platform_admin (user_id, full_name, phone_e164) values ('00000000-0000-4000-b800-0000000000c1', 'Bad Phone', '+915000020009') $$, '23514', null, 'platform_admin phone must be an Indian mobile in E.164');

-- phone_claim ---------------------------------------------------------------------------------------------------------------
select is((select count(*)::int from public.membership m left join app.phone_claim c on c.user_id = m.user_id and c.phone_e164 = m.phone_e164 and c.kind = 'membership' where c.user_id is null), 0,
  'every membership has a phone claim (backfill + trigger)');
select is((select count(*)::int from app.phone_claim where kind = 'platform_admin'), 3, 'every platform_admin has a phone claim');
select throws_ok($$ insert into public.platform_admin (user_id, full_name, phone_e164) values ('00000000-0000-4000-b800-0000000000c1', 'Clash', '+919000020101') $$, '23505', null,
  'an SA cannot take a phone that a member already has');
select throws_ok($$ insert into public.membership (tenant_id, user_id, role, full_name, employee_id, phone_e164, must_change_password)
                    values ('18000000-0000-4000-b800-00000000000a', '00000000-0000-4000-b800-0000000000c1', 'supervisor', 'Clash', 'CL-1', '+919000020001', false) $$, '23505', null,
  'a member cannot take a phone that an SA already has');
select is((select count(*)::int from public.platform_admin where user_id = '00000000-0000-4000-b800-0000000000c1'), 0, 'a refused SA insert leaves nothing behind');
select lives_ok($$ update public.membership set phone_e164 = '+919000020111' where user_id = '00000000-0000-4000-b800-0000000000b2' $$, 'a member can change phone');
select is((select phone_e164 from app.phone_claim where user_id = '00000000-0000-4000-b800-0000000000b2'), '+919000020111', 'the claim follows a membership phone change');
select throws_ok($$ update public.platform_admin set phone_e164 = '+919000020111' where user_id = '00000000-0000-4000-b800-0000000000a1' $$, '23505', null,
  'an SA cannot change to a phone that a member holds');
select lives_ok($$ update public.platform_admin set phone_e164 = '+919000020011' where user_id = '00000000-0000-4000-b800-0000000000a1' $$, 'an SA can change phone');
select is((select phone_e164 from app.phone_claim where user_id = '00000000-0000-4000-b800-0000000000a1'), '+919000020011', 'the claim follows an SA phone change');
select throws_ok($$ update public.membership set phone_e164 = '+919000020011' where user_id = '00000000-0000-4000-b800-0000000000b2' $$, '23505', null,
  'a member cannot change to the new SA phone');
delete from public.membership where user_id = '00000000-0000-4000-b800-0000000000b2';
select is((select count(*)::int from app.phone_claim where user_id = '00000000-0000-4000-b800-0000000000b2'), 0, 'deleting a membership releases its claim');
select lives_ok($$ insert into public.platform_admin (user_id, full_name, phone_e164) values ('00000000-0000-4000-b800-0000000000c1', 'Reuse', '+919000020111') $$, 'a released phone can be used by an SA');
delete from auth.users where id = '00000000-0000-4000-b800-0000000000c1';
select is((select count(*)::int from app.phone_claim where phone_e164 = '+919000020111'), 0, 'deleting the Auth user releases the SA claim');

-- 02 duplicate check sees SA phones ---------------------------------------------------------------------------------------------
select throws_ok($$ select app.ua_check_create('00000000-0000-4000-b800-0000000000b1', gen_random_uuid(), 'New', 'N-1', '+919000020011', 'supervisor') $$, 'P0001', 'This phone number is already registered',
  '02 check_create refuses a phone that belongs to an SA');
select throws_ok($$ select app.ua_update_user('00000000-0000-4000-b800-0000000000b1', gen_random_uuid(), '00000000-0000-4000-b800-0000000000b1', null, null, '+919000020003', null) $$, 'P0001', 'This phone number is already registered',
  '02 update refuses a phone that belongs to an SA');

-- platform_admin visibility -------------------------------------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b800-0000000000a1","role":"authenticated"}', true);
select is((select count(*)::int from public.platform_admin), 1, 'an SA sees only their own platform_admin row');
select ok((select count(*) from public.tenant) >= 3, 'an active SA reads the tenants (including suspended ones)');
select throws_ok($$ update public.tenant set name = 'x' $$, '42501', null, 'an SA cannot update tenant');
select throws_ok($$ insert into public.tenant (name) values ('evil') $$, '42501', null, 'an SA cannot insert tenant');
select throws_ok($$ update public.platform_admin set full_name = 'x' $$, '42501', null, 'an SA cannot update platform_admin directly');
select throws_ok($$ select * from app.phone_claim $$, '42501', null, 'authenticated cannot read phone_claim');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b800-0000000000a2","role":"authenticated"}', true);
select is((select count(*)::int from public.tenant), 0, 'an inactive SA reads no tenants');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b800-0000000000a3","role":"authenticated"}', true);
select is((select count(*)::int from public.tenant), 0, 'an SA with a temporary password reads no tenants');
select is((select count(*)::int from public.platform_admin), 1, 'but still reads their own row (the client needs it to route to change-password)');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b800-0000000000b1","role":"authenticated"}', true);
select is((select count(*)::int from public.platform_admin), 0, 'a tenant user sees no platform_admin rows');
select is((select count(*)::int from public.tenant), 1, 'a tenant user still sees only their own tenant');
reset role;

-- is_platform_admin ---------------------------------------------------------------------------------------------------------------------
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b800-0000000000a1","role":"authenticated"}', true);
select is(app.is_platform_admin(), true, 'is_platform_admin: active SA');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b800-0000000000a2","role":"authenticated"}', true);
select is(app.is_platform_admin(), false, 'is_platform_admin: inactive SA');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b800-0000000000a3","role":"authenticated"}', true);
select is(app.is_platform_admin(), false, 'is_platform_admin: must-change SA');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b800-0000000000b1","role":"authenticated"}', true);
select is(app.is_platform_admin(), false, 'is_platform_admin: tenant user');
select ok(not has_function_privilege('authenticated', 'app.is_platform_admin()', 'execute') and not has_function_privilege('anon', 'app.is_platform_admin()', 'execute'), 'is_platform_admin is not executable by clients');

select * from finish();
rollback;
