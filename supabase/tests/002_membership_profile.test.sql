-- 02 AC-2, AC-3, AC-9, AC-10 (DB part): membership profile columns, must-change gate, role helper, RLS by role.
-- Self-contained; rolled back. Phones used here come from the throwaway block +91 90000 1xxxx.
begin;
create extension if not exists pgtap with schema extensions;
select plan(33);

-- Fixtures (as postgres) ---------------------------------------------------
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-b000-0000000000a1', 'tap2-ua@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b000-0000000000a2', 'tap2-sup@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b000-0000000000a3', 'tap2-fresh@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b000-0000000000a4', 'tap2-inactive@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b000-0000000000b1', 'tap2-uy@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b000-0000000000d1', 'tap2-susp@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b000-0000000000e1', 'tap2-extra@example.test', 'authenticated', 'authenticated');
insert into public.tenant (id, name, status) values
  ('11000000-0000-4000-b000-00000000000a', 'tap2 org X', 'active'),
  ('11000000-0000-4000-b000-00000000000b', 'tap2 org Y', 'active'),
  ('11000000-0000-4000-b000-00000000000d', 'tap2 org Z', 'suspended');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('11000000-0000-4000-b000-00000000000a', '00000000-0000-4000-b000-0000000000a1', 'unit_admin', 'active',   'Asha UA',   'UA-1',  '+919000012001', false),
  ('11000000-0000-4000-b000-00000000000a', '00000000-0000-4000-b000-0000000000a2', 'supervisor', 'active',   'Ravi Sup',  'SUP-1', '+919000012002', false),
  ('11000000-0000-4000-b000-00000000000a', '00000000-0000-4000-b000-0000000000a3', 'supervisor', 'active',   'Fresh Sup', 'SUP-2', '+919000012003', true),
  ('11000000-0000-4000-b000-00000000000a', '00000000-0000-4000-b000-0000000000a4', 'supervisor', 'inactive', 'Gone Sup',  'SUP-3', '+919000012004', false),
  ('11000000-0000-4000-b000-00000000000b', '00000000-0000-4000-b000-0000000000b1', 'supervisor', 'active',   'Yash Sup',  'SUP-1', '+919000012005', false),
  ('11000000-0000-4000-b000-00000000000d', '00000000-0000-4000-b000-0000000000d1', 'supervisor', 'active',   'Zed Sup',   'SUP-1', '+919000012006', false);

-- Structure and constraints --------------------------------------------------
select has_column('public', 'membership', 'full_name', 'full_name column exists');
select has_column('public', 'membership', 'employee_id', 'employee_id column exists');
select has_column('public', 'membership', 'phone_e164', 'phone_e164 column exists');
select col_not_null('public', 'membership', 'full_name', 'full_name is not null');
select col_not_null('public', 'membership', 'employee_id', 'employee_id is not null');
select col_not_null('public', 'membership', 'phone_e164', 'phone_e164 is not null');
select col_default_is('public', 'membership', 'must_change_password', 'true', 'must_change_password defaults to true');
select col_is_null('public', 'membership', 'temp_password_expires_at', 'temp_password_expires_at is nullable');

select throws_ok(
  $$ insert into public.membership (tenant_id, user_id, role, full_name, employee_id, phone_e164)
     values ('11000000-0000-4000-b000-00000000000a', '00000000-0000-4000-b000-0000000000e1', 'supervisor', 'X', 'E-1', '+915876543210') $$,
  '23514', null, 'phone must be an Indian mobile (starts 6-9)');
select throws_ok(
  $$ insert into public.membership (tenant_id, user_id, role, full_name, employee_id, phone_e164)
     values ('11000000-0000-4000-b000-00000000000a', '00000000-0000-4000-b000-0000000000e1', 'supervisor', 'X', 'E-1', '9876543210') $$,
  '23514', null, 'phone must be stored in +91 E.164 form');
select throws_ok(
  $$ insert into public.membership (tenant_id, user_id, role, full_name, employee_id, phone_e164)
     values ('11000000-0000-4000-b000-00000000000a', '00000000-0000-4000-b000-0000000000e1', 'supervisor', '   ', 'E-1', '+919000012010') $$,
  '23514', null, 'blank full name rejected');
select throws_ok(
  $$ insert into public.membership (tenant_id, user_id, role, full_name, employee_id, phone_e164)
     values ('11000000-0000-4000-b000-00000000000a', '00000000-0000-4000-b000-0000000000e1', 'supervisor', repeat('n', 81), 'E-1', '+919000012010') $$,
  '23514', null, 'full name over 80 chars rejected');
select throws_ok(
  $$ insert into public.membership (tenant_id, user_id, role, full_name, employee_id, phone_e164)
     values ('11000000-0000-4000-b000-00000000000a', '00000000-0000-4000-b000-0000000000e1', 'supervisor', 'X', 'bad id!', '+919000012010') $$,
  '23514', null, 'employee id charset enforced');
select throws_ok(
  $$ insert into public.membership (tenant_id, user_id, role, full_name, employee_id, phone_e164)
     values ('11000000-0000-4000-b000-00000000000a', '00000000-0000-4000-b000-0000000000e1', 'supervisor', 'X', repeat('E', 31), '+919000012010') $$,
  '23514', null, 'employee id over 30 chars rejected');
select throws_ok(
  $$ insert into public.membership (tenant_id, user_id, role, full_name, employee_id, phone_e164)
     values ('11000000-0000-4000-b000-00000000000a', '00000000-0000-4000-b000-0000000000e1', 'supervisor', 'X', 'E-1', '+919000012001') $$,
  '23505', null, 'phone is unique across the platform');
select throws_ok(
  $$ insert into public.membership (tenant_id, user_id, role, full_name, employee_id, phone_e164)
     values ('11000000-0000-4000-b000-00000000000b', '00000000-0000-4000-b000-0000000000e1', 'supervisor', 'X', 'E-1', '+919000012001') $$,
  '23505', null, 'phone is unique even across tenants');
select throws_ok(
  $$ insert into public.membership (tenant_id, user_id, role, full_name, employee_id, phone_e164)
     values ('11000000-0000-4000-b000-00000000000a', '00000000-0000-4000-b000-0000000000e1', 'supervisor', 'X', 'sup-1', '+919000012010') $$,
  '23505', null, 'employee id unique per tenant, case-insensitive');
select lives_ok(
  $$ insert into public.membership (tenant_id, user_id, role, full_name, employee_id, phone_e164)
     values ('11000000-0000-4000-b000-00000000000b', '00000000-0000-4000-b000-0000000000e1', 'supervisor', 'X', 'sup-2', '+919000012010') $$,
  'same employee id may exist in another tenant');

-- Must-change gate (AC-3) ----------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-0000000000a3","role":"authenticated"}', true);
select is(app.current_tenant_id(), null::uuid, 'must-change user: current_tenant_id is null');
select is(app.current_role(), null::public.member_role, 'must-change user: current_role is null');
select is((select count(*)::int from public.tenant), 0, 'must-change user: sees no tenant');
select is((select count(*)::int from public.membership), 1, 'must-change user: still sees own membership (needed to show the change screen)');
reset role;
update public.membership set must_change_password = false where user_id = '00000000-0000-4000-b000-0000000000a3';
set local role authenticated;
select is(app.current_tenant_id(), '11000000-0000-4000-b000-00000000000a'::uuid, 'after the change: current_tenant_id returns the tenant');
reset role;
update public.membership set must_change_password = true where user_id = '00000000-0000-4000-b000-0000000000a3';

-- Role helper: inactive and suspended give null ------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-0000000000a4","role":"authenticated"}', true);
select is(app.current_role(), null::public.member_role, 'inactive member: current_role is null');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-0000000000d1","role":"authenticated"}', true);
select is(app.current_role(), null::public.member_role, 'suspended tenant: current_role is null');

-- Unit Admin ---------------------------------------------------------------
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-0000000000a1","role":"authenticated"}', true);
select is(app.current_role(), 'unit_admin'::public.member_role, 'UA: current_role is unit_admin');
select is((select count(*)::int from public.membership), 4, 'UA sees every membership of their own tenant');
select is((select count(*)::int from public.membership where tenant_id <> '11000000-0000-4000-b000-00000000000a'), 0,
  'UA sees no membership of another tenant');
select is((select count(*)::int from public.membership where user_id = '00000000-0000-4000-b000-0000000000b1'), 0,
  'UA of X cannot read a user of Y by id');
select throws_ok($$ update public.membership set role = 'unit_admin' $$, '42501', null, 'UA cannot update membership directly');

-- Supervisor -----------------------------------------------------------------
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b000-0000000000a2","role":"authenticated"}', true);
select is(app.current_role(), 'supervisor'::public.member_role, 'SUP: current_role is supervisor');
select results_eq($$ select employee_id from public.membership $$, $$ values ('SUP-1'::text) $$, 'SUP reads only their own membership');

-- Anonymous ------------------------------------------------------------------
reset role;
set local role anon;
select throws_ok($$ select * from public.membership $$, '42501', null, 'anon cannot read membership');

select * from finish();
rollback;
