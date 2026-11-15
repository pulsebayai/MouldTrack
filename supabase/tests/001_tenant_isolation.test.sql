-- AC-4 (DB part), AC-6: tenant isolation for tenant + membership.
-- Self-contained: creates its own fixtures inside the transaction, rolled back at the end.
begin;
create extension if not exists pgtap with schema extensions;
select plan(18);

-- Fixtures (as postgres) ---------------------------------------------------
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-a000-0000000000a1', 'tap-a@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-a000-0000000000b1', 'tap-b@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-a000-0000000000c1', 'tap-nomember@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-a000-0000000000d1', 'tap-suspended@example.test', 'authenticated', 'authenticated');
insert into public.tenant (id, name, status) values
  ('10000000-0000-4000-a000-00000000000a', 'tap org A', 'active'),
  ('10000000-0000-4000-a000-00000000000b', 'tap org B', 'active'),
  ('10000000-0000-4000-a000-00000000000d', 'tap org S', 'suspended');
insert into public.membership (tenant_id, user_id, role) values
  ('10000000-0000-4000-a000-00000000000a', '00000000-0000-4000-a000-0000000000a1', 'unit_admin'),
  ('10000000-0000-4000-a000-00000000000b', '00000000-0000-4000-a000-0000000000b1', 'supervisor'),
  ('10000000-0000-4000-a000-00000000000d', '00000000-0000-4000-a000-0000000000d1', 'supervisor');

-- Structure ------------------------------------------------------------------
select ok((select relrowsecurity and relforcerowsecurity from pg_class where oid = 'public.tenant'::regclass),
  'RLS enabled and forced on tenant');
select ok((select relrowsecurity and relforcerowsecurity from pg_class where oid = 'public.membership'::regclass),
  'RLS enabled and forced on membership');
select throws_ok(
  $$ insert into public.membership (tenant_id, user_id, role)
     values ('10000000-0000-4000-a000-00000000000b', '00000000-0000-4000-a000-0000000000a1', 'supervisor') $$,
  '23505', null, 'a user can belong to only one tenant (unique user_id)');

-- User A ---------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000000a1","role":"authenticated"}', true);
select is(app.current_tenant_id(), '10000000-0000-4000-a000-00000000000a'::uuid, 'A: current_tenant_id is A');
select results_eq($$ select name from public.tenant $$, $$ values ('tap org A'::text) $$, 'A sees only tenant A');
select is((select count(*)::int from public.membership), 1, 'A sees exactly one membership');
select is((select count(*)::int from public.membership where user_id <> '00000000-0000-4000-a000-0000000000a1'), 0,
  'A sees no other user''s membership');
select throws_ok($$ insert into public.tenant (name) values ('evil') $$, '42501', null, 'A cannot insert tenant');
select throws_ok($$ update public.tenant set name = 'x' $$, '42501', null, 'A cannot update tenant');
select throws_ok($$ delete from public.membership $$, '42501', null, 'A cannot delete membership');
select throws_ok(
  $$ insert into public.membership (tenant_id, user_id, role)
     values ('10000000-0000-4000-a000-00000000000a', '00000000-0000-4000-a000-0000000000c1', 'unit_admin') $$,
  '42501', null, 'A cannot insert membership');

-- User B ---------------------------------------------------------------------
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000000b1","role":"authenticated"}', true);
select results_eq($$ select name from public.tenant $$, $$ values ('tap org B'::text) $$, 'B sees only tenant B');
select is((select count(*)::int from public.tenant where id = '10000000-0000-4000-a000-00000000000a'), 0, 'B cannot see tenant A');

-- No membership --------------------------------------------------------------
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000000c1","role":"authenticated"}', true);
select is(app.current_tenant_id(), null::uuid, 'no membership: current_tenant_id is null');
select is((select count(*)::int from public.tenant), 0, 'no membership: sees no tenant');

-- Suspended tenant -----------------------------------------------------------
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-a000-0000000000d1","role":"authenticated"}', true);
select is(app.current_tenant_id(), null::uuid, 'suspended tenant: current_tenant_id is null');
select is((select count(*)::int from public.tenant), 0, 'suspended tenant: sees no tenant');

-- Anonymous ------------------------------------------------------------------
reset role;
set local role anon;
select throws_ok($$ select * from public.tenant $$, '42501', null, 'anon cannot read tenant');

select * from finish();
rollback;
