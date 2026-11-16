-- 02 AC-9, AC-10, AC-11 (DB part): audit_event is tenant-scoped, readable by the tenant's Unit Admin only,
-- never writable by clients, and append-only for every role including service_role.
begin;
create extension if not exists pgtap with schema extensions;
select plan(23);

-- Fixtures (as postgres) ---------------------------------------------------
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-b100-0000000000a1', 'tap3-ua@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b100-0000000000a2', 'tap3-sup@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b100-0000000000b1', 'tap3-uyb@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-b100-0000000000c1', 'tap3-nomember@example.test', 'authenticated', 'authenticated');
insert into public.tenant (id, name, status) values
  ('12000000-0000-4000-b100-00000000000a', 'tap3 org X', 'active'),
  ('12000000-0000-4000-b100-00000000000b', 'tap3 org Y', 'active');
insert into public.membership (tenant_id, user_id, role, full_name, employee_id, phone_e164, must_change_password) values
  ('12000000-0000-4000-b100-00000000000a', '00000000-0000-4000-b100-0000000000a1', 'unit_admin', 'UA X', 'UA-X', '+919000013001', false),
  ('12000000-0000-4000-b100-00000000000a', '00000000-0000-4000-b100-0000000000a2', 'supervisor', 'SUP X', 'SUP-X', '+919000013002', false),
  ('12000000-0000-4000-b100-00000000000b', '00000000-0000-4000-b100-0000000000b1', 'unit_admin', 'UA Y', 'UA-Y', '+919000013003', false);
insert into public.audit_event (id, tenant_id, actor_user_id, actor_role, action, entity_type, entity_id, source, request_id) values
  ('13000000-0000-4000-b100-000000000001', '12000000-0000-4000-b100-00000000000a', '00000000-0000-4000-b100-0000000000a1', 'unit_admin',
   'user.created', 'membership', '00000000-0000-4000-b100-0000000000a2', 'edge:user-admin', '14000000-0000-4000-b100-000000000001'),
  ('13000000-0000-4000-b100-000000000002', '12000000-0000-4000-b100-00000000000b', '00000000-0000-4000-b100-0000000000b1', 'unit_admin',
   'user.created', 'membership', '00000000-0000-4000-b100-0000000000b1', 'edge:user-admin', null),
  ('13000000-0000-4000-b100-000000000003', null, '00000000-0000-4000-b100-0000000000c1', null,
   'access.denied', null, null, 'edge:user-admin', null);

-- Structure --------------------------------------------------------------------
select ok((select relrowsecurity and relforcerowsecurity from pg_class where oid = 'public.audit_event'::regclass),
  'RLS enabled and forced on audit_event');
select col_not_null('public', 'audit_event', 'action', 'action is not null');
select col_not_null('public', 'audit_event', 'source', 'source is not null');
select col_is_null('public', 'audit_event', 'tenant_id', 'tenant_id nullable (denials by callers with no tenant)');
select throws_ok(
  $$ insert into public.audit_event (tenant_id, action, source) values ('12000000-0000-4000-b100-00000000000a', 'user.exploded', 'rpc:test') $$,
  '23514', null, 'unknown action rejected');
select throws_ok(
  $$ insert into public.audit_event (tenant_id, actor_user_id, action, source, request_id)
     values ('12000000-0000-4000-b100-00000000000a', '00000000-0000-4000-b100-0000000000a1', 'user.updated', 'edge:user-admin', '14000000-0000-4000-b100-000000000001') $$,
  '23505', null, 'same actor + request id cannot be recorded twice');

-- Unit Admin of X ---------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b100-0000000000a1","role":"authenticated"}', true);
select results_eq($$ select id from public.audit_event $$,
  $$ values ('13000000-0000-4000-b100-000000000001'::uuid) $$, 'UA reads only their tenant''s events');
select is((select count(*)::int from public.audit_event where tenant_id is null), 0, 'UA does not read events with no tenant');
select throws_ok($$ insert into public.audit_event (tenant_id, action, source) values ('12000000-0000-4000-b100-00000000000a', 'user.created', 'x') $$,
  '42501', null, 'authenticated cannot insert audit_event');
select throws_ok($$ update public.audit_event set reason = 'x' $$, '42501', null, 'authenticated cannot update audit_event');
select throws_ok($$ delete from public.audit_event $$, '42501', null, 'authenticated cannot delete audit_event');
select throws_ok($$ truncate public.audit_event $$, '42501', null, 'authenticated cannot truncate audit_event');

-- Supervisor of X --------------------------------------------------------------
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b100-0000000000a2","role":"authenticated"}', true);
select is((select count(*)::int from public.audit_event), 0, 'SUP reads no audit events');

-- Unit Admin of Y ---------------------------------------------------------------
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b100-0000000000b1","role":"authenticated"}', true);
select results_eq($$ select id from public.audit_event $$,
  $$ values ('13000000-0000-4000-b100-000000000002'::uuid) $$, 'UA of Y reads only Y events, never X');

-- No membership -----------------------------------------------------------------
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-b100-0000000000c1","role":"authenticated"}', true);
select is((select count(*)::int from public.audit_event), 0, 'caller with no tenant reads no audit events (not even their own denial)');

-- Anonymous ---------------------------------------------------------------------
reset role;
set local role anon;
select throws_ok($$ select * from public.audit_event $$, '42501', null, 'anon cannot read audit_event');
select throws_ok($$ insert into public.audit_event (action, source) values ('access.denied', 'x') $$, '42501', null, 'anon cannot insert audit_event');

-- Service role: may append, may not change or remove (privileges revoked) -----------
reset role;
set local role service_role;
select lives_ok($$ insert into public.audit_event (tenant_id, action, source) values ('12000000-0000-4000-b100-00000000000a', 'user.updated', 'rpc:test') $$,
  'service_role can append audit events');
select throws_ok($$ update public.audit_event set reason = 'tamper' $$, '42501', null, 'service_role cannot update audit_event (privilege revoked)');
select throws_ok($$ delete from public.audit_event $$, '42501', null, 'service_role cannot delete audit_event (privilege revoked)');

-- Trigger is the second layer: blocks even a role that holds the privilege (table owner) -
reset role;
select throws_ok($$ update public.audit_event set reason = 'tamper' $$, 'P0001', 'audit_event is append-only', 'trigger blocks UPDATE even for the owner');
select throws_ok($$ delete from public.audit_event $$, 'P0001', 'audit_event is append-only', 'trigger blocks DELETE even for the owner');
select throws_ok($$ truncate public.audit_event $$, 'P0001', 'audit_event is append-only', 'trigger blocks TRUNCATE even for the owner');

select * from finish();
rollback;
