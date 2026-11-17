-- 03 step 3 (AC-11, AC-12, AC-13, AC-14): a Super Admin reads NO tenant operational rows, 02 write paths deny and audit SAs,
-- every psvc_* wrapper is service-only. The table list is discovered (every public table with a tenant_id column), so a table
-- added by a later feature fails this test until it is covered. Self-contained; rolled back. Phones +91 90000 22xxx.
begin;
create extension if not exists pgtap with schema extensions;
select plan(37);

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-ba00-0000000000a1', 'tap22-sa@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-ba00-0000000000a2', 'tap22-sa-inactive@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-ba00-0000000000a3', 'tap22-sa-must@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-ba00-0000000000b1', 'tap22-ua@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-ba00-0000000000b2', 'tap22-sup@example.test', 'authenticated', 'authenticated');
insert into public.tenant (id, name, status) values ('1f000000-0000-4000-ba00-00000000000a', 'tap22 org X', 'active');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('1f000000-0000-4000-ba00-00000000000a', '00000000-0000-4000-ba00-0000000000b1', 'unit_admin', 'active', 'UA X', 'UA-1', '+919000022101', false),
  ('1f000000-0000-4000-ba00-00000000000a', '00000000-0000-4000-ba00-0000000000b2', 'supervisor', 'active', 'Sup X', 'SUP-1', '+919000022102', false);
insert into public.platform_admin (user_id, full_name, phone_e164, status, must_change_password) values
  ('00000000-0000-4000-ba00-0000000000a1', 'SA', '+919000022001', 'active', false),
  ('00000000-0000-4000-ba00-0000000000a2', 'SA inactive', '+919000022002', 'inactive', false),
  ('00000000-0000-4000-ba00-0000000000a3', 'SA must', '+919000022003', 'active', true);
-- 04's plant tables: one row each, so the boundary test is meaningful for them too (the discovery below picks them up automatically).
insert into public.site (id, tenant_id, name, timezone) values ('5e000000-0000-4000-ba00-000000000001', '1f000000-0000-4000-ba00-00000000000a', 'tap22 site', 'Asia/Kolkata');
insert into public.line (id, tenant_id, site_id, name) values ('5e000000-0000-4000-ba00-000000000002', '1f000000-0000-4000-ba00-00000000000a', '5e000000-0000-4000-ba00-000000000001', 'tap22 line');
insert into public.machine (id, tenant_id, site_id, line_id, code, name) values
  ('5e000000-0000-4000-ba00-000000000003', '1f000000-0000-4000-ba00-00000000000a', '5e000000-0000-4000-ba00-000000000001', '5e000000-0000-4000-ba00-000000000002', 'T22-M1', 'tap22 machine');
insert into public.product (id, tenant_id, code, description) values ('5e000000-0000-4000-ba00-000000000004', '1f000000-0000-4000-ba00-00000000000a', 'T22-P1', 'tap22 product');
insert into public.target_version (tenant_id, machine_id, product_id, effective_from, pieces_per_shift, recorded_by) values
  ('1f000000-0000-4000-ba00-00000000000a', '5e000000-0000-4000-ba00-000000000003', '5e000000-0000-4000-ba00-000000000004', current_date - 2, 100, '00000000-0000-4000-ba00-0000000000b1');
-- 05's shift tables: one row each (rows inserted as the table owner; the RPCs are covered by the discovery below).
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time) values
  ('5e000000-0000-4000-ba00-000000000005', '1f000000-0000-4000-ba00-00000000000a', '5e000000-0000-4000-ba00-000000000001', 'tap22 shift', '06:00', '14:00');
insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by) values
  ('1f000000-0000-4000-ba00-00000000000a', '5e000000-0000-4000-ba00-000000000005', '5e000000-0000-4000-ba00-000000000003', '00000000-0000-4000-ba00-0000000000b2', current_date - 2, '00000000-0000-4000-ba00-0000000000b1');
insert into public.assignment_cover (tenant_id, shift_id, shift_date, machine_id, supervisor_id, reason, recorded_by) values
  ('1f000000-0000-4000-ba00-00000000000a', '5e000000-0000-4000-ba00-000000000005', current_date, '5e000000-0000-4000-ba00-000000000003', null, 'tap22 cover', '00000000-0000-4000-ba00-0000000000b1');
insert into public.target_override_version (tenant_id, machine_id, product_id, shift_id, effective_from, pieces_per_shift, recorded_by) values
  ('1f000000-0000-4000-ba00-00000000000a', '5e000000-0000-4000-ba00-000000000003', '5e000000-0000-4000-ba00-000000000004', '5e000000-0000-4000-ba00-000000000005', current_date - 2, 90, '00000000-0000-4000-ba00-0000000000b1');
-- tenant events, an SA event, and a denial exist, so "0 rows" is meaningful
select app.ua_set_status('00000000-0000-4000-ba00-0000000000b1', gen_random_uuid(), '00000000-0000-4000-ba00-0000000000b2', 'inactive');
select app.ua_set_status('00000000-0000-4000-ba00-0000000000b1', gen_random_uuid(), '00000000-0000-4000-ba00-0000000000b2', 'active');
select app.pa_tenant_update('00000000-0000-4000-ba00-0000000000a1', gen_random_uuid(), '1f000000-0000-4000-ba00-00000000000a', 'tap22 org X', 'Asia/Kolkata', 'active');
select app.pa_tenant_update('00000000-0000-4000-ba00-0000000000a1', gen_random_uuid(), '1f000000-0000-4000-ba00-00000000000a', 'tap22 org X renamed', null, null);

-- Reusable discovery: every public table, view and materialised view that carries tenant_id (tenant itself is the tenant-level fact an SA may read).
create function public.tap22_tenant_tables() returns setof text language sql stable as $$
  select c.relname::text from pg_class c
  join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
  where c.relkind in ('r', 'p', 'v', 'm')
    and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'tenant_id' and a.attnum > 0 and not a.attisdropped)
  order by 1
$$;
-- Rows the caller can read across every tenant-owned relation, as "name:count" pairs with a non-zero count.
create function public.tap22_visible() returns text language plpgsql as $$
declare t text; n bigint; out text := '';
begin
  for t in select * from public.tap22_tenant_tables() loop
    execute format('select count(*) from public.%I', t) into n;
    if n > 0 then out := out || t || ':' || n || ' '; end if;
  end loop;
  return btrim(out);
end $$;
-- Relations the caller reads ZERO rows from (R1: the boundary test is only meaningful when every table has rows to hide).
create function public.tap22_unseen() returns text language plpgsql as $$
declare t text; n bigint; out text := '';
begin
  for t in select * from public.tap22_tenant_tables() loop
    execute format('select count(*) from public.%I', t) into n;
    if n = 0 then out := out || t || ' '; end if;
  end loop;
  return btrim(out);
end $$;
grant execute on function public.tap22_tenant_tables(), public.tap22_visible(), public.tap22_unseen() to authenticated;

select ok((select count(*) from public.tap22_tenant_tables()) >= 2, 'discovery finds the tenant-owned tables (membership, audit_event at least)');
select is((select count(*)::int from public.tap22_tenant_tables() t(name)
           where (select relkind from pg_class where oid = ('public.' || quote_ident(t.name))::regclass) in ('r', 'p')
             and not (select relrowsecurity and relforcerowsecurity from pg_class where oid = ('public.' || quote_ident(t.name))::regclass)), 0,
  'every tenant-owned table has RLS enabled and forced');
select is(public.tap22_unseen(), '', 'R1: every tenant-owned table, view and materialised view has at least one row (empty ones are listed here; add fixtures)');
select ok((select count(*) from public.membership) >= 2 and (select count(*) from public.audit_event) >= 4, 'fixtures: memberships and audit events exist');
select ok((select array_agg(x order by x) from public.tap22_tenant_tables() x) @> array['current_target', 'line', 'machine', 'plant_today', 'product', 'site', 'target_version'],
  'step 8: the automatic check covers 04''s site, line, machine, product, target_version and the views plant_today and current_target');

-- The Unit Admin sees them (control) ----------------------------------------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-ba00-0000000000b1","role":"authenticated"}', true);
select ok(public.tap22_visible() like '%membership:%' and public.tap22_visible() like '%audit_event:%', 'control: a Unit Admin does see membership and audit_event');
select is(public.tap22_unseen(), '', 'R1 control: a Unit Admin sees at least one row in every tenant-owned relation');

-- The Super Admin sees none ----------------------------------------------------------------------------------------------------------------------
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-ba00-0000000000a1","role":"authenticated"}', true);
select is(public.tap22_visible(), '', 'an active SA reads 0 rows from every tenant-owned table');
select is((select count(*)::int from public.membership), 0, 'an SA reads no membership rows');
select is((select count(*)::int from public.audit_event), 0, 'an SA reads no audit_event rows, not even their own through the table');
select is((select count(*)::int from public.platform_admin), 1, 'an SA reads only their own platform_admin row');
select throws_ok($$ insert into public.audit_event (action, source) values ('user.created', 'x') $$, '42501', null, 'an SA cannot write audit_event');
select throws_ok($$ update public.membership set status = 'inactive' $$, '42501', null, 'an SA cannot update membership');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-ba00-0000000000a2","role":"authenticated"}', true);
select is(public.tap22_visible(), '', 'an inactive SA reads 0 rows from every tenant-owned table');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-ba00-0000000000a3","role":"authenticated"}', true);
select is(public.tap22_visible(), '', 'an SA with a temporary password reads 0 rows from every tenant-owned table');
select is((select count(*)::int from public.tenant), 0, 'and no tenants either');
reset role;

-- 02 write paths deny and audit an SA (AC-11) ----------------------------------------------------------------------------------------------------------
select is(app.ua_create_user('00000000-0000-4000-ba00-0000000000a1', gen_random_uuid(), gen_random_uuid(), 'X', 'X-1', '+919000022201', 'supervisor'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'user-admin create denies an SA');
select is(app.ua_set_status('00000000-0000-4000-ba00-0000000000a1', gen_random_uuid(), '00000000-0000-4000-ba00-0000000000b2', 'inactive'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'user-admin set_status denies an SA');
select is(app.ua_reset_password('00000000-0000-4000-ba00-0000000000a1', gen_random_uuid(), '00000000-0000-4000-ba00-0000000000b1'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'user-admin reset denies an SA');
select is((select status::text from public.membership where user_id = '00000000-0000-4000-ba00-0000000000b2'), 'active', 'the denied calls changed nothing');
select results_eq($$ select actor_role, reason, tenant_id is null from public.audit_event where action = 'access.denied' and actor_user_id = '00000000-0000-4000-ba00-0000000000a1' and source = 'edge:user-admin' $$,
  $$ values ('platform_admin'::text, 'platform_admin'::text, true), ('platform_admin'::text, 'platform_admin'::text, true), ('platform_admin'::text, 'platform_admin'::text, true) $$,
  'each is audited with actor role platform_admin (so it shows in the platform audit)');

-- Tenant write RPCs deny and audit an SA (AC-11, F3): DISCOVERED, not listed. Every public function that is security definer, returns jsonb, is executable by
-- `authenticated` and is not a pa_* platform function is a tenant write path (04's pm_*, and whatever later features add). Each is called as the SA with
-- all-null arguments and must return the generic denial; a new one is covered automatically, and its body must go through a shared authorise helper.
create function public.tap22_rpcs() returns table (proname text, args text, src text) language sql stable as $$
  select p.proname::text, (select string_agg('null::' || format_type(t.oid, null), ', ' order by t.o) from unnest(p.proargtypes::oid[]) with ordinality as t(oid, o)), p.prosrc
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef and p.prorettype = 'jsonb'::regtype and has_function_privilege('authenticated', p.oid, 'execute') and p.proname !~ '^pa_'
$$;
create function public.tap22_denied_count() returns int language plpgsql as $$
declare r record; res jsonb; n int := 0;
begin
  for r in select * from public.tap22_rpcs() loop
    execute format('select public.%I(%s)', r.proname, coalesce(r.args, '')) into res;
    if res = '{"ok": false, "code": "not_allowed"}'::jsonb then n := n + 1; end if;
  end loop;
  return n;
end $$;
grant execute on function public.tap22_rpcs(), public.tap22_denied_count() to authenticated;

select ok((select count(*) from public.tap22_rpcs()) >= 9, 'discovery finds the tenant write RPCs (04''s nine pm_* at least)');
select is((select count(*)::int from public.tap22_rpcs() where src not like '%app._pm_authorise(%' and src not like '%app._ua_authorise(%'), 0,
  'every discovered RPC body calls app._pm_authorise( or app._ua_authorise( (the helpers with the Super Admin branch)');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-ba00-0000000000a1","role":"authenticated"}', true);
select is(public.tap22_denied_count(), (select count(*)::int from public.tap22_rpcs()), 'every discovered tenant write RPC denies an SA with all-null arguments');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-ba00-0000000000a2","role":"authenticated"}', true);
select is(public.pm_save_site(gen_random_uuid(), 'SA site', 'Asia/Kolkata'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'an inactive SA is denied by pm_* as well');
reset role;
select results_eq($$ select (select count(*) from public.site where tenant_id = '1f000000-0000-4000-ba00-00000000000a'), (select count(*) from public.line where tenant_id = '1f000000-0000-4000-ba00-00000000000a'),
                          (select count(*) from public.machine where tenant_id = '1f000000-0000-4000-ba00-00000000000a' and retired_at is null),
                          (select count(*) from public.product where tenant_id = '1f000000-0000-4000-ba00-00000000000a' and retired_at is null),
                          (select count(*) from public.target_version where tenant_id = '1f000000-0000-4000-ba00-00000000000a') $$,
  $$ values (1::bigint, 1::bigint, 1::bigint, 1::bigint, 1::bigint) $$, 'the denied calls changed nothing');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = '00000000-0000-4000-ba00-0000000000a1' and actor_role = 'platform_admin'
             and reason = 'platform_admin' and tenant_id is null and source in (select 'rpc:' || proname from public.tap22_rpcs())), (select count(*)::int from public.tap22_rpcs()),
  'each denial is audited with actor role platform_admin and an SA-specific reason (one row per discovered RPC)');
select is((select count(distinct source)::int from public.audit_event where action = 'access.denied' and actor_user_id = '00000000-0000-4000-ba00-0000000000a1' and source in (select 'rpc:' || proname from public.tap22_rpcs())),
  (select count(*)::int from public.tap22_rpcs()), 'and every discovered RPC left its own row');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = '00000000-0000-4000-ba00-0000000000a2' and source = 'rpc:pm_save_site' and actor_role = 'platform_admin'), 1,
  'the inactive SA''s pm_* denial is audited as a platform event too');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-ba00-0000000000a1","role":"authenticated"}', true);
select is((select count(*)::int from public.pa_audit(0) where action = 'access.denied' and source in (select 'rpc:' || proname from public.tap22_rpcs())), (select count(*)::int from public.tap22_rpcs()) + 1,
  'the platform audit lists them: one per discovered RPC plus the inactive SA''s (pa_audit)');
select is((select count(*)::int from public.pa_audit(0) where action = 'access.denied' and source in (select 'rpc:' || proname from public.tap22_rpcs()) and tenant_name is not null), 0, 'and they carry no tenant (an SA has none)');
reset role;
select is(
  (select count(*)::int from public.audit_event where action = 'access.denied' and reason = 'no_membership' and actor_user_id = '00000000-0000-4000-ba00-0000000000a1'), 0,
  'an SA is never mistaken for a user without membership (no no_membership denial)');

-- Visibility of platform actions (AC-12, AC-13) -----------------------------------------------------------------------------------------------------------
select ok((select count(*) from public.audit_event where action = 'tenant.updated' and tenant_id = '1f000000-0000-4000-ba00-00000000000a') = 2, 'fixture: two platform actions on the tenant');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-ba00-0000000000b1","role":"authenticated"}', true);
select is((select count(*)::int from public.audit_event where action = 'tenant.updated'), 2, 'a Unit Admin sees platform actions on their own tenant (AC-13)');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-ba00-0000000000b2","role":"authenticated"}', true);
select is((select count(*)::int from public.audit_event where action = 'tenant.updated'), 0, 'a supervisor does not');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-ba00-0000000000a1","role":"authenticated"}', true);
select ok((select count(*) from public.pa_audit(0) where action = 'access.denied' and actor_name = 'SA') >= 3, 'the platform audit lists the SA''s own denials (AC-12)');
select is((select count(*)::int from public.pa_audit(0) where action = 'user.deactivated'), 0, 'the platform audit never lists tenant users'' own events');
reset role;

select * from finish();
rollback;
