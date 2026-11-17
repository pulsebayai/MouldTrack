-- 04 AC-1..4, AC-7, AC-11 (DB part), FR-3/FR-4: plant master tables, RLS, append-only targets, target_for, plant_date, current_target.
-- Self-contained; rolled back. Tenant/user ids use the 04xxxxxx block.
begin;
create extension if not exists pgtap with schema extensions;
select plan(82);

-- Fixtures (as postgres) ---------------------------------------------------
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-c100-0000000000a1', 'tap10-uax@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-c100-0000000000a2', 'tap10-supx@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-c100-0000000000b1', 'tap10-uay@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-c100-0000000000c1', 'tap10-nomember@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-c100-0000000000a3', 'tap10-fresh@example.test', 'authenticated', 'authenticated');
insert into public.tenant (id, name, status, timezone) values
  ('40000000-0000-4000-c100-00000000000a', 'tap10 org X', 'active', 'Asia/Kolkata'),
  ('40000000-0000-4000-c100-00000000000b', 'tap10 org Y', 'active', 'Asia/Kolkata');
insert into public.membership (tenant_id, user_id, role, full_name, employee_id, phone_e164, must_change_password) values
  ('40000000-0000-4000-c100-00000000000a', '00000000-0000-4000-c100-0000000000a1', 'unit_admin', 'UA X', 'UA-X', '+919000015001', false),
  ('40000000-0000-4000-c100-00000000000a', '00000000-0000-4000-c100-0000000000a2', 'supervisor', 'SUP X', 'SUP-X', '+919000015002', false),
  ('40000000-0000-4000-c100-00000000000b', '00000000-0000-4000-c100-0000000000b1', 'unit_admin', 'UA Y', 'UA-Y', '+919000015003', false),
  ('40000000-0000-4000-c100-00000000000a', '00000000-0000-4000-c100-0000000000a3', 'supervisor', 'Fresh X', 'FR-X', '+919000015004', true);

insert into public.site (id, tenant_id, name, timezone) values
  ('41000000-0000-4000-c100-00000000000a', '40000000-0000-4000-c100-00000000000a', 'Plant X', 'Asia/Kolkata'),
  ('41000000-0000-4000-c100-00000000000b', '40000000-0000-4000-c100-00000000000b', 'Plant Y', 'Asia/Kolkata');
insert into public.line (id, tenant_id, site_id, name) values
  ('42000000-0000-4000-c100-00000000000a', '40000000-0000-4000-c100-00000000000a', '41000000-0000-4000-c100-00000000000a', 'Line 1'),
  ('42000000-0000-4000-c100-00000000000b', '40000000-0000-4000-c100-00000000000b', '41000000-0000-4000-c100-00000000000b', 'Line Y');
insert into public.machine (id, tenant_id, site_id, line_id, code, name) values
  ('43000000-0000-4000-c100-00000000000a', '40000000-0000-4000-c100-00000000000a', '41000000-0000-4000-c100-00000000000a', '42000000-0000-4000-c100-00000000000a', 'M-1', 'Press 1'),
  ('43000000-0000-4000-c100-00000000000b', '40000000-0000-4000-c100-00000000000b', '41000000-0000-4000-c100-00000000000b', null, 'M-1', 'Press Y1');
insert into public.product (id, tenant_id, code, description) values
  ('44000000-0000-4000-c100-00000000000a', '40000000-0000-4000-c100-00000000000a', 'P-1', 'Cap 28mm'),
  ('44000000-0000-4000-c100-00000000000b', '40000000-0000-4000-c100-00000000000b', 'P-1', 'Cap Y');
insert into public.target_version (id, tenant_id, machine_id, product_id, effective_from, pieces_per_shift, recorded_by) values
  ('45000000-0000-4000-c100-00000000000a', '40000000-0000-4000-c100-00000000000a', '43000000-0000-4000-c100-00000000000a', '44000000-0000-4000-c100-00000000000a', date '2026-01-01', 1000, '00000000-0000-4000-c100-0000000000a1'),
  ('45000000-0000-4000-c100-00000000000b', '40000000-0000-4000-c100-00000000000b', '43000000-0000-4000-c100-00000000000b', '44000000-0000-4000-c100-00000000000b', date '2026-01-01', 500, '00000000-0000-4000-c100-0000000000b1');

-- Structure ----------------------------------------------------------------
select is((select count(*)::int from pg_class where oid in ('public.site'::regclass, 'public.line'::regclass, 'public.machine'::regclass,
  'public.product'::regclass, 'public.target_version'::regclass) and relrowsecurity and relforcerowsecurity), 5, 'RLS enabled and forced on all five tables');
select col_not_null('public', 'site', 'tenant_id', 'site.tenant_id not null');
select col_not_null('public', 'line', 'tenant_id', 'line.tenant_id not null');
select col_not_null('public', 'machine', 'tenant_id', 'machine.tenant_id not null');
select col_not_null('public', 'product', 'tenant_id', 'product.tenant_id not null');
select col_not_null('public', 'target_version', 'tenant_id', 'target_version.tenant_id not null');
select has_index('public', 'target_version', 'target_version_lookup_idx', 'target_for lookup index exists');

-- Integrity ------------------------------------------------------------------
select throws_ok($$ insert into public.site (tenant_id, name, timezone) values ('40000000-0000-4000-c100-00000000000a', 'Second', 'Asia/Kolkata') $$,
  '23505', null, 'one site per tenant');
select throws_ok($$ insert into public.line (tenant_id, site_id, name) values ('40000000-0000-4000-c100-00000000000a', '41000000-0000-4000-c100-00000000000a', 'LINE 1') $$,
  '23505', null, 'line name unique per site, case-insensitive');
select lives_ok($$ insert into public.line (tenant_id, site_id, name, archived_at) values ('40000000-0000-4000-c100-00000000000a', '41000000-0000-4000-c100-00000000000a', 'Line 1', now()) $$,
  'an archived line does not block reusing its name');
select throws_ok($$ insert into public.line (tenant_id, site_id, name) values ('40000000-0000-4000-c100-00000000000a', '41000000-0000-4000-c100-00000000000b', 'Cross') $$,
  '23503', null, 'composite FK: a line cannot reference another tenant''s site');
select throws_ok($$ insert into public.machine (tenant_id, site_id, code, name) values ('40000000-0000-4000-c100-00000000000a', '41000000-0000-4000-c100-00000000000a', 'm-1', 'Dup') $$,
  '23505', null, 'machine code unique per tenant, case-insensitive');
select lives_ok($$ insert into public.machine (tenant_id, site_id, code, name) values ('40000000-0000-4000-c100-00000000000b', '41000000-0000-4000-c100-00000000000b', 'M-2', 'Other tenant same code ok') $$,
  'the same code may exist in another tenant');
select throws_ok($$ insert into public.machine (tenant_id, site_id, line_id, code, name) values ('40000000-0000-4000-c100-00000000000a', '41000000-0000-4000-c100-00000000000a', '42000000-0000-4000-c100-00000000000b', 'M-9', 'X') $$,
  '23503', null, 'composite FK: a machine cannot use another tenant''s line');
select throws_ok($$ insert into public.machine (tenant_id, site_id, code, name) values ('40000000-0000-4000-c100-00000000000a', '41000000-0000-4000-c100-00000000000b', 'M-8', 'X') $$,
  '23503', null, 'composite FK: a machine cannot use another tenant''s site');
select throws_ok($$ insert into public.machine (tenant_id, site_id, code, name) values ('40000000-0000-4000-c100-00000000000a', '41000000-0000-4000-c100-00000000000a', 'bad code!', 'X') $$,
  '23514', null, 'machine code format');
select throws_ok($$ insert into public.machine (tenant_id, site_id, code, name, status) values ('40000000-0000-4000-c100-00000000000a', '41000000-0000-4000-c100-00000000000a', 'M-7', 'X', 'retired') $$,
  '23514', null, 'machine status is active or under_maintenance only');
select throws_ok($$ insert into public.product (tenant_id, code, description) values ('40000000-0000-4000-c100-00000000000a', 'p-1', 'Dup') $$,
  '23505', null, 'product code unique per tenant, case-insensitive');
select is((select uom from public.product where id = '44000000-0000-4000-c100-00000000000a'), 'pcs', 'unit of measure defaults to pcs');
select throws_ok($$ insert into public.target_version (tenant_id, machine_id, product_id, effective_from, pieces_per_shift, recorded_by)
  values ('40000000-0000-4000-c100-00000000000a', '43000000-0000-4000-c100-00000000000b', '44000000-0000-4000-c100-00000000000a', date '2026-02-01', 10, '00000000-0000-4000-c100-0000000000a1') $$,
  '23503', null, 'composite FK: a target cannot use another tenant''s machine');
select throws_ok($$ insert into public.target_version (tenant_id, machine_id, product_id, effective_from, pieces_per_shift, recorded_by)
  values ('40000000-0000-4000-c100-00000000000a', '43000000-0000-4000-c100-00000000000a', '44000000-0000-4000-c100-00000000000b', date '2026-02-01', 10, '00000000-0000-4000-c100-0000000000a1') $$,
  '23503', null, 'composite FK: a target cannot use another tenant''s product');
select throws_ok($$ insert into public.target_version (tenant_id, machine_id, product_id, effective_from, pieces_per_shift, recorded_by)
  values ('40000000-0000-4000-c100-00000000000a', '43000000-0000-4000-c100-00000000000a', '44000000-0000-4000-c100-00000000000a', date '2026-02-01', 0, '00000000-0000-4000-c100-0000000000a1') $$,
  '23514', null, 'pieces must be at least 1');
select throws_ok($$ insert into public.target_version (tenant_id, machine_id, product_id, effective_from, pieces_per_shift, recorded_by)
  values ('40000000-0000-4000-c100-00000000000a', '43000000-0000-4000-c100-00000000000a', '44000000-0000-4000-c100-00000000000a', date '2026-02-01', 1000001, '00000000-0000-4000-c100-0000000000a1') $$,
  '23514', null, 'pieces must be at most 1 000 000');
select lives_ok($$ insert into public.target_version (tenant_id, machine_id, product_id, effective_from, pieces_per_shift, recorded_by)
  values ('40000000-0000-4000-c100-00000000000a', '43000000-0000-4000-c100-00000000000a', '44000000-0000-4000-c100-00000000000a', date '2099-01-01', null, '00000000-0000-4000-c100-0000000000a1') $$,
  'null pieces records an ended version');

-- RLS: UA of X ---------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c100-0000000000a1","role":"authenticated"}', true);
select is((select count(*)::int from public.site), 1, 'UA X sees one site');
select is((select name from public.site), 'Plant X', 'UA X sees only site X');
select is((select count(*)::int from public.line where tenant_id <> '40000000-0000-4000-c100-00000000000a'), 0, 'UA X sees no line of Y');
select is((select count(*)::int from public.machine where tenant_id <> '40000000-0000-4000-c100-00000000000a'), 0, 'UA X sees no machine of Y');
select is((select count(*)::int from public.product where tenant_id <> '40000000-0000-4000-c100-00000000000a'), 0, 'UA X sees no product of Y');
select is((select count(*)::int from public.target_version where tenant_id <> '40000000-0000-4000-c100-00000000000a'), 0, 'UA X sees no target of Y');
select is((select count(*)::int from public.machine), 1, 'UA X sees own machine');
select throws_ok($$ insert into public.machine (tenant_id, site_id, code, name) values ('40000000-0000-4000-c100-00000000000a', '41000000-0000-4000-c100-00000000000a', 'M-EVIL', 'Evil') $$,
  '42501', null, 'UA cannot insert a machine directly');
select throws_ok($$ update public.machine set name = 'x' $$, '42501', null, 'UA cannot update a machine directly');
select throws_ok($$ delete from public.product $$, '42501', null, 'UA cannot delete a product directly');
select throws_ok($$ insert into public.site (tenant_id, name, timezone) values ('40000000-0000-4000-c100-00000000000a', 'x', 'UTC') $$, '42501', null, 'UA cannot insert a site directly');
select throws_ok($$ update public.line set name = 'x' $$, '42501', null, 'UA cannot update a line directly');
select throws_ok($$ insert into public.target_version (tenant_id, machine_id, product_id, effective_from, pieces_per_shift, recorded_by)
  values ('40000000-0000-4000-c100-00000000000a', '43000000-0000-4000-c100-00000000000a', '44000000-0000-4000-c100-00000000000a', date '2030-01-01', 5, '00000000-0000-4000-c100-0000000000a1') $$,
  '42501', null, 'UA cannot insert a target directly');

-- RLS: SUP of X reads, cannot write ---------------------------------------------
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c100-0000000000a2","role":"authenticated"}', true);
select is((select count(*)::int from public.site), 1, 'SUP X reads the site');
select is((select count(*)::int from public.line where tenant_id = '40000000-0000-4000-c100-00000000000a'), 2, 'SUP X reads lines');
select is((select count(*)::int from public.target_version), 2, 'SUP X reads target versions of X only');
select throws_ok($$ update public.product set description = 'x' $$, '42501', null, 'SUP cannot update a product');

-- RLS: UA of Y ------------------------------------------------------------------
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c100-0000000000b1","role":"authenticated"}', true);
select is((select name from public.site), 'Plant Y', 'UA Y sees only site Y');
select is((select count(*)::int from public.product where id = '44000000-0000-4000-c100-00000000000a'), 0, 'UA Y cannot see product of X');
select is((select count(*)::int from public.target_version where machine_id = '43000000-0000-4000-c100-00000000000a'), 0, 'UA Y cannot see targets of X');

-- Must-change-password and no-membership users see nothing ----------------------
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c100-0000000000a3","role":"authenticated"}', true);
select is((select count(*)::int from public.machine), 0, 'a user with a temporary password sees no machines');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c100-0000000000c1","role":"authenticated"}', true);
select is((select count(*)::int from public.site) + (select count(*)::int from public.target_version), 0, 'a caller with no membership sees nothing');

-- Anonymous --------------------------------------------------------------------
reset role;
set local role anon;
select throws_ok($$ select * from public.machine $$, '42501', null, 'anon cannot read machine');
select throws_ok($$ select * from public.target_version $$, '42501', null, 'anon cannot read target_version');
select throws_ok($$ select * from public.current_target $$, '42501', null, 'anon cannot read current_target');
reset role;

-- Append-only target_version ------------------------------------------------------
set local role service_role;
select lives_ok($$ select count(*) from public.target_version $$, 'service_role can read target_version');
select throws_ok($$ update public.target_version set pieces_per_shift = 1 $$, '42501', null, 'service_role cannot update target_version');
select throws_ok($$ delete from public.target_version $$, '42501', null, 'service_role cannot delete target_version');
select throws_ok($$ truncate public.target_version $$, '42501', null, 'service_role cannot truncate target_version');
reset role;
select throws_ok($$ update public.target_version set pieces_per_shift = 1 $$, 'P0001', 'target_version is append-only', 'trigger blocks UPDATE even for the owner');
select throws_ok($$ delete from public.target_version $$, 'P0001', 'target_version is append-only', 'trigger blocks DELETE even for the owner');
select throws_ok($$ truncate public.target_version $$, 'P0001', 'target_version is append-only', 'trigger blocks TRUNCATE even for the owner');

-- Privileges on helper functions --------------------------------------------------
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'app' and p.proname in ('plant_date', 'plant_date_at', 'target_for', 'target_version_append_only')
             and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0,
  'plant helpers are not executable by anon or authenticated');

-- plant_date -----------------------------------------------------------------------
select is(app.plant_date('40000000-0000-4000-c100-00000000000a'), (now() at time zone 'Asia/Kolkata')::date, 'plant_date uses the site timezone');
update public.site set timezone = 'Pacific/Kiritimati' where tenant_id = '40000000-0000-4000-c100-00000000000a'; -- UTC+14
select is(app.plant_date('40000000-0000-4000-c100-00000000000a'), (now() at time zone 'Pacific/Kiritimati')::date, 'plant_date follows a changed site timezone');
update public.site set timezone = 'Asia/Kolkata' where tenant_id = '40000000-0000-4000-c100-00000000000a';
insert into public.tenant (id, name, status, timezone) values ('40000000-0000-4000-c100-00000000000c', 'tap10 no site', 'active', 'Asia/Tokyo');
select is(app.plant_date('40000000-0000-4000-c100-00000000000c'), (now() at time zone 'Asia/Tokyo')::date, 'without a site, plant_date falls back to the tenant timezone');
-- 23:30 IST is still the previous UTC date; 00:30 IST is already the next one in IST while UTC is behind.
select is((timestamptz '2026-11-17 18:00:00+00' at time zone 'Asia/Kolkata')::date, date '2026-11-17', 'sanity: 23:30 IST on the 17th (18:00 UTC) is the 17th');
select is((timestamptz '2026-11-17 19:00:00+00' at time zone 'Asia/Kolkata')::date, date '2026-11-18', 'sanity: 00:30 IST on the 18th (19:00 UTC on the 17th) is the 18th, UTC is still the 17th');
select is(app.plant_date_at('40000000-0000-4000-c100-00000000000a', timestamptz '2026-11-17 18:00:00+00'), date '2026-11-17', 'plant_date_at: 23:30 IST belongs to the 17th');
select is(app.plant_date_at('40000000-0000-4000-c100-00000000000a', timestamptz '2026-11-17 19:00:00+00'), date '2026-11-18', 'plant_date_at: 00:30 IST belongs to the 18th although UTC says the 17th');

-- target_for (AC-7) -----------------------------------------------------------------
select set_config('request.jwt.claims', '{"role":"service_role"}', true); -- called server-side as the service role (D11; no-claims callers get null, see 013)
-- pair M2/P2 in tenant X for the cases; machine/product created here
insert into public.machine (id, tenant_id, site_id, code, name) values ('43000000-0000-4000-c100-0000000000a2', '40000000-0000-4000-c100-00000000000a', '41000000-0000-4000-c100-00000000000a', 'M-2', 'Press 2');
insert into public.product (id, tenant_id, code, description) values ('44000000-0000-4000-c100-0000000000a2', '40000000-0000-4000-c100-00000000000a', 'P-2', 'Cap 38mm');
select is(app.target_for('43000000-0000-4000-c100-0000000000a2', '44000000-0000-4000-c100-0000000000a2', date '2026-06-01'), null, 'no versions: null');
insert into public.target_version (tenant_id, machine_id, product_id, effective_from, pieces_per_shift, recorded_by) values
  ('40000000-0000-4000-c100-00000000000a', '43000000-0000-4000-c100-0000000000a2', '44000000-0000-4000-c100-0000000000a2', date '2026-06-10', 1000, '00000000-0000-4000-c100-0000000000a1');
select is(app.target_for('43000000-0000-4000-c100-0000000000a2', '44000000-0000-4000-c100-0000000000a2', date '2026-06-09'), null, 'one version: the day before it starts is null');
select is(app.target_for('43000000-0000-4000-c100-0000000000a2', '44000000-0000-4000-c100-0000000000a2', date '2026-06-10'), 1000, 'one version: applies from its first day');
select is(app.target_for('43000000-0000-4000-c100-0000000000a2', '44000000-0000-4000-c100-0000000000a2', date '2030-01-01'), 1000, 'one version: applies until a later one');
insert into public.target_version (tenant_id, machine_id, product_id, effective_from, pieces_per_shift, recorded_by) values
  ('40000000-0000-4000-c100-00000000000a', '43000000-0000-4000-c100-0000000000a2', '44000000-0000-4000-c100-0000000000a2', date '2026-07-01', 1200, '00000000-0000-4000-c100-0000000000a1');
select is(app.target_for('43000000-0000-4000-c100-0000000000a2', '44000000-0000-4000-c100-0000000000a2', date '2026-06-30'), 1000, 'change on day D: D-1 is the old target');
select is(app.target_for('43000000-0000-4000-c100-0000000000a2', '44000000-0000-4000-c100-0000000000a2', date '2026-07-01'), 1200, 'change on day D: D is the new target');
insert into public.target_version (tenant_id, machine_id, product_id, effective_from, pieces_per_shift, recorded_by) values
  ('40000000-0000-4000-c100-00000000000a', '43000000-0000-4000-c100-0000000000a2', '44000000-0000-4000-c100-0000000000a2', date '2026-08-01', null, '00000000-0000-4000-c100-0000000000a1');
select is(app.target_for('43000000-0000-4000-c100-0000000000a2', '44000000-0000-4000-c100-0000000000a2', date '2026-07-31'), 1200, 'end: the day before the end date still has a target');
select is(app.target_for('43000000-0000-4000-c100-0000000000a2', '44000000-0000-4000-c100-0000000000a2', date '2026-08-01'), null, 'end: from the end date there is no target');
insert into public.target_version (tenant_id, machine_id, product_id, effective_from, pieces_per_shift, recorded_by) values
  ('40000000-0000-4000-c100-00000000000a', '43000000-0000-4000-c100-0000000000a2', '44000000-0000-4000-c100-0000000000a2', date '2026-09-01', 900, '00000000-0000-4000-c100-0000000000a1');
select is(app.target_for('43000000-0000-4000-c100-0000000000a2', '44000000-0000-4000-c100-0000000000a2', date '2026-08-31'), null, 're-set after end: still none before the new start');
select is(app.target_for('43000000-0000-4000-c100-0000000000a2', '44000000-0000-4000-c100-0000000000a2', date '2026-09-01'), 900, 're-set after end: applies from the new start');
insert into public.target_version (tenant_id, machine_id, product_id, effective_from, pieces_per_shift, recorded_by) values
  ('40000000-0000-4000-c100-00000000000a', '43000000-0000-4000-c100-0000000000a2', '44000000-0000-4000-c100-0000000000a2', date '2026-09-01', 950, '00000000-0000-4000-c100-0000000000a1');
select is(app.target_for('43000000-0000-4000-c100-0000000000a2', '44000000-0000-4000-c100-0000000000a2', date '2026-09-01'), 950, 'same-day correction: the latest recorded wins (even inside one transaction)');
-- tenant check when called under a user's JWT
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c100-0000000000b1","role":"authenticated"}', true);
select is(app.target_for('43000000-0000-4000-c100-0000000000a2', '44000000-0000-4000-c100-0000000000a2', date '2026-09-01'), null, 'target_for under another tenant''s JWT returns null');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c100-0000000000a1","role":"authenticated"}', true);
select is(app.target_for('43000000-0000-4000-c100-0000000000a2', '44000000-0000-4000-c100-0000000000a2', date '2026-09-01'), 950, 'target_for under the own tenant''s JWT returns the target');
select set_config('request.jwt.claims', '', true);

-- current_target and plant_today views -------------------------------------------------
-- fresh pair M3/P3 so today's date is controlled
insert into public.machine (id, tenant_id, site_id, code, name) values ('43000000-0000-4000-c100-0000000000a3', '40000000-0000-4000-c100-00000000000a', '41000000-0000-4000-c100-00000000000a', 'M-3', 'Press 3');
insert into public.target_version (tenant_id, machine_id, product_id, effective_from, pieces_per_shift, recorded_by) values
  ('40000000-0000-4000-c100-00000000000a', '43000000-0000-4000-c100-0000000000a3', '44000000-0000-4000-c100-0000000000a2', app.plant_date('40000000-0000-4000-c100-00000000000a') - 5, 700, '00000000-0000-4000-c100-0000000000a1'),
  ('40000000-0000-4000-c100-00000000000a', '43000000-0000-4000-c100-0000000000a3', '44000000-0000-4000-c100-0000000000a2', app.plant_date('40000000-0000-4000-c100-00000000000a') + 5, 800, '00000000-0000-4000-c100-0000000000a1');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c100-0000000000a2","role":"authenticated"}', true);
select is((select pieces_per_shift from public.current_target where machine_id = '43000000-0000-4000-c100-0000000000a3'), 700, 'current_target shows today''s target, not a future one');
select is((select count(*)::int from public.current_target where machine_id = '43000000-0000-4000-c100-0000000000a2'), 1, 'current_target has one row per pair');
select is((select count(*)::int from public.current_target where machine_id = '43000000-0000-4000-c100-00000000000b'), 0, 'current_target is tenant scoped');
select is((select plant_date from public.plant_today), (now() at time zone 'Asia/Kolkata')::date, 'plant_today shows the site''s plant date');
reset role;
insert into public.target_version (tenant_id, machine_id, product_id, effective_from, pieces_per_shift, recorded_by) values
  ('40000000-0000-4000-c100-00000000000a', '43000000-0000-4000-c100-0000000000a3', '44000000-0000-4000-c100-0000000000a2', app.plant_date('40000000-0000-4000-c100-00000000000a'), null, '00000000-0000-4000-c100-0000000000a1');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c100-0000000000a2","role":"authenticated"}', true);
select is((select count(*)::int from public.current_target where machine_id = '43000000-0000-4000-c100-0000000000a3'), 0, 'current_target hides a pair whose target ended');
reset role;

select * from finish();
rollback;
