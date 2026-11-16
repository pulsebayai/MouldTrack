-- 04 AC-1..12 (DB part): the pm_* write RPCs. Success + exactly one audit row, validation/duplicate/guard codes with field,
-- audited denials (role, must-change, suspended tenant, no membership, inactive, cross-tenant, unknown id), idempotency, no backdating.
-- Self-contained; rolled back. Everything runs as postgres with the caller's JWT claims set (the RPCs are security definer and key on auth.uid()).
begin;
create extension if not exists pgtap with schema extensions;
select plan(148);

create temp table ids (k text primary key, v uuid);
create function pg_temp.id(k text) returns uuid language sql as $$ select v from ids where k = $1 $$;
create function pg_temp.as_user(k text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where ids.k = $1), 'role', 'authenticated')::text, true) $$;
create function pg_temp.keep(k text, r jsonb) returns jsonb language plpgsql as $$ begin insert into ids values (k, (r->>'id')::uuid); return r; end $$;
-- {code, field, message, machines, raised}: the error a statement raises
create function pg_temp.err(q text) returns jsonb language plpgsql as $f$
declare d text; m text; st text;
begin
  execute q;
  return jsonb_build_object('raised', false);
exception when others then
  get stacked diagnostics d = pg_exception_detail, m = message_text, st = returned_sqlstate;
  return coalesce(nullif(d, '')::jsonb, '{}'::jsonb) || jsonb_build_object('message', m, 'sqlstate', st);
end $f$;
create function pg_temp.n_audit(a text) returns int language sql as $$ select count(*)::int from public.audit_event where action = a $$;

-- Fixtures (as postgres) ---------------------------------------------------
insert into auth.users (id, email, aud, role)
select u, 'tap11-' || n || '@example.test', 'authenticated', 'authenticated' from (values
  ('00000000-0000-4000-c200-0000000000a1'::uuid, 'uax'), ('00000000-0000-4000-c200-0000000000a2', 'supx'), ('00000000-0000-4000-c200-0000000000a3', 'freshx'),
  ('00000000-0000-4000-c200-0000000000a4', 'inactx'), ('00000000-0000-4000-c200-0000000000b1', 'uay'), ('00000000-0000-4000-c200-0000000000d1', 'uas'),
  ('00000000-0000-4000-c200-0000000000c1', 'nomem'), ('00000000-0000-4000-c200-0000000000e1', 'uaw')) t(u, n);
insert into ids values ('uax', '00000000-0000-4000-c200-0000000000a1'), ('supx', '00000000-0000-4000-c200-0000000000a2'), ('freshx', '00000000-0000-4000-c200-0000000000a3'),
  ('inactx', '00000000-0000-4000-c200-0000000000a4'), ('uay', '00000000-0000-4000-c200-0000000000b1'), ('uas', '00000000-0000-4000-c200-0000000000d1'),
  ('nomem', '00000000-0000-4000-c200-0000000000c1'), ('uaw', '00000000-0000-4000-c200-0000000000e1'),
  ('tx', '50000000-0000-4000-c200-00000000000a'), ('ty', '50000000-0000-4000-c200-00000000000b'), ('ts', '50000000-0000-4000-c200-00000000000d'), ('tw', '50000000-0000-4000-c200-00000000000e');
insert into public.tenant (id, name, status, timezone) values
  ('50000000-0000-4000-c200-00000000000a', 'tap11 org X', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c200-00000000000b', 'tap11 org Y', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c200-00000000000d', 'tap11 org S', 'suspended', 'Asia/Kolkata'),
  ('50000000-0000-4000-c200-00000000000e', 'tap11 org W (no site)', 'active', 'Asia/Kolkata');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('50000000-0000-4000-c200-00000000000a', '00000000-0000-4000-c200-0000000000a1', 'unit_admin', 'active', 'UA X', 'UA-X', '+919000016001', false),
  ('50000000-0000-4000-c200-00000000000a', '00000000-0000-4000-c200-0000000000a2', 'supervisor', 'active', 'SUP X', 'SUP-X', '+919000016002', false),
  ('50000000-0000-4000-c200-00000000000a', '00000000-0000-4000-c200-0000000000a3', 'unit_admin', 'active', 'Fresh X', 'FR-X', '+919000016003', true),
  ('50000000-0000-4000-c200-00000000000a', '00000000-0000-4000-c200-0000000000a4', 'unit_admin', 'inactive', 'Gone X', 'GO-X', '+919000016004', false),
  ('50000000-0000-4000-c200-00000000000b', '00000000-0000-4000-c200-0000000000b1', 'unit_admin', 'active', 'UA Y', 'UA-Y', '+919000016005', false),
  ('50000000-0000-4000-c200-00000000000d', '00000000-0000-4000-c200-0000000000d1', 'unit_admin', 'active', 'UA S', 'UA-S', '+919000016006', false),
  ('50000000-0000-4000-c200-00000000000e', '00000000-0000-4000-c200-0000000000e1', 'unit_admin', 'active', 'UA W', 'UA-W', '+919000016007', false);

-- Privileges ---------------------------------------------------------------------
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname ~ '^pm_'), 9, 'there are nine pm_* RPCs');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname ~ '^pm_'
           and has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute')), 9, 'every pm_* RPC is executable by authenticated and not by anon');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname ~ '^pm_'
           and (not p.prosecdef or p.proconfig is null or not ('search_path=""' = any (p.proconfig)))), 0, 'every pm_* RPC is security definer with an empty search_path');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname ~ '^_pm_'
           and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')
                or not p.prosecdef or p.proconfig is null or not ('search_path=""' = any (p.proconfig)))), 0,
  'the _pm_ helpers are security definer with an empty search_path and not executable by clients');
select is((select count(*)::int from app.audit_action where feature = '04'), 15, 'the 15 actions of 04 are registered');
set local role anon;
select throws_ok($$ select public.pm_save_site(gen_random_uuid(), 'x', 'UTC') $$, '42501', null, 'anon cannot call pm_save_site');
reset role;

-- Site (AC-1) ------------------------------------------------------------------------
select pg_temp.as_user('uax');
select is((pg_temp.err($$ select public.pm_save_site(gen_random_uuid(), '   ', null) $$))->>'field', 'name', 'site: blank name is refused on field name');
select is((pg_temp.err($$ select public.pm_save_site(gen_random_uuid(), 'Plant X', 'Mars/Base') $$))->>'field', 'timezone', 'site: unknown timezone is refused on field timezone');
select is((pg_temp.err($$ select public.pm_save_site(null, 'Plant X', null) $$))->>'field', 'request_id', 'a null request id is refused');
insert into ids values ('rq_site', gen_random_uuid());
select is((pg_temp.keep('site_x', public.pm_save_site(pg_temp.id('rq_site'), '  Plant X  ', null)))->>'ok', 'true', 'site: created');
select results_eq($$ select name, timezone, tenant_id from public.site where tenant_id = pg_temp.id('tx') $$, $$ values ('Plant X'::text, 'Asia/Kolkata'::text, '50000000-0000-4000-c200-00000000000a'::uuid) $$,
  'site: name trimmed and timezone defaults to the tenant''s');
select is(pg_temp.n_audit('site.created'), 1, 'site: one audit row');
select is((public.pm_save_site(pg_temp.id('rq_site'), '  Plant X  ', null))->>'already', 'true', 'site: a repeat reports already done');
select is(pg_temp.n_audit('site.created'), 1, 'site: the repeat writes no second audit row');
select is((select count(*)::int from public.site where tenant_id = pg_temp.id('tx')), 1, 'site: the repeat creates no second site');
select is((public.pm_save_site(gen_random_uuid(), 'Plant X2', 'Asia/Tokyo'))->>'id', pg_temp.id('site_x')::text, 'site: saving again updates the one site (a second is impossible)');
select results_eq($$ select before->>'name', after->>'name', after->>'timezone' from public.audit_event where action = 'site.updated' $$,
  $$ values ('Plant X'::text, 'Plant X2'::text, 'Asia/Tokyo'::text) $$, 'site: update audited with before and after');
select pg_temp.as_user('uax');
select is(public.pm_save_site(gen_random_uuid(), 'Plant X', 'Asia/Kolkata') is not null, true, 'site: timezone can be changed back');
select pg_temp.as_user('uay');
select is((public.pm_save_site(gen_random_uuid(), 'Plant Y', 'Asia/Kolkata'))->>'ok', 'true', 'site: tenant Y creates its own');
select is((select count(*)::int from public.site where name = 'Plant X'), 1, 'site: tenant Y''s save does not touch tenant X''s site');

-- Lines (AC-2) -------------------------------------------------------------------------
select pg_temp.as_user('uax');
select is((pg_temp.keep('line_a', public.pm_save_line(gen_random_uuid(), null, '  Line A  ')))->>'ok', 'true', 'line: created');
select is(pg_temp.n_audit('line.created'), 1, 'line: one audit row');
select is((select name from public.line where id = pg_temp.id('line_a')), 'Line A', 'line: name trimmed');
select is((pg_temp.err($$ select public.pm_save_line(gen_random_uuid(), null, 'line a') $$)) - 'message', '{"code":"duplicate","field":"name","sqlstate":"P0001"}'::jsonb, 'line: duplicate name (case-insensitive) is refused on field name');
select is((pg_temp.err($$ select public.pm_save_line(gen_random_uuid(), null, '') $$))->>'field', 'name', 'line: blank name refused');
select is((pg_temp.err($$ select public.pm_save_line(gen_random_uuid(), null, repeat('x', 61)) $$))->>'field', 'name', 'line: name over 60 characters refused');
select is((pg_temp.keep('line_b', public.pm_save_line(gen_random_uuid(), null, 'Line B')))->>'ok', 'true', 'line: second line created');
select is((public.pm_save_line(gen_random_uuid(), pg_temp.id('line_b'), 'Line B2'))->>'ok', 'true', 'line: renamed');
select results_eq($$ select before->>'name', after->>'name' from public.audit_event where action = 'line.updated' $$, $$ values ('Line B'::text, 'Line B2'::text) $$, 'line: rename audited with before/after');
select is((pg_temp.err(format($$ select public.pm_save_line(gen_random_uuid(), %L, 'line a') $$, pg_temp.id('line_b'))))->>'code', 'duplicate', 'line: renaming onto an existing name is refused');
-- a machine on line A blocks archiving
select is((pg_temp.keep('m1', public.pm_save_machine(gen_random_uuid(), null, 'M-1', 'Press 1', 'AT-1', 'Haitian', 'MA-900', 'Ke-2000', pg_temp.id('line_a'), 'active')))->>'ok', 'true', 'machine: created on line A');
select is((pg_temp.err(format($$ select public.pm_archive_line(gen_random_uuid(), %L) $$, pg_temp.id('line_a')))) - 'message',
  '{"code":"guard","field":"line","machines":["M-1"],"sqlstate":"P0001"}'::jsonb, 'line: archive blocked while a non-retired machine uses it (lists the machine)');
select is((public.pm_set_machine_retired(gen_random_uuid(), pg_temp.id('m1'), true))->>'ok', 'true', 'machine: retired');
select is((public.pm_archive_line(gen_random_uuid(), pg_temp.id('line_a')))->>'changed', 'true', 'line: archived once its machines are retired');
select is(pg_temp.n_audit('line.archived'), 1, 'line: archive audited once');
select is((public.pm_archive_line(gen_random_uuid(), pg_temp.id('line_a')))->>'changed', 'false', 'line: archiving again is a no-op');
select is(pg_temp.n_audit('line.archived'), 1, 'line: the no-op writes no audit row');
select is((pg_temp.err(format($$ select public.pm_save_line(gen_random_uuid(), %L, 'Renamed') $$, pg_temp.id('line_a'))))->>'field', 'archived', 'line: an archived line cannot be renamed');
select is((public.pm_save_line(gen_random_uuid(), null, 'Line A'))->>'ok', 'true', 'line: an archived line''s name can be reused');
-- reinstating the retired machine whose line was archived clears its line
select is((public.pm_set_machine_retired(gen_random_uuid(), pg_temp.id('m1'), false))->>'changed', 'true', 'machine: reinstated');
select is((select line_id from public.machine where id = pg_temp.id('m1')), null, 'machine: reinstating clears an archived line');
select pg_temp.as_user('uaw');
select is((pg_temp.err($$ select public.pm_save_line(gen_random_uuid(), null, 'No site yet') $$))->>'field', 'site', 'line: needs a site first');
select is((pg_temp.err($$ select public.pm_save_machine(gen_random_uuid(), null, 'M-W', 'Press', null, null, null, null, null, 'active') $$))->>'field', 'site', 'machine: needs a site first');

-- Machines (AC-3) ----------------------------------------------------------------------
select pg_temp.as_user('uax');
select results_eq($$ select code, name, asset_tag, make, model, controller, status, tenant_id from public.machine where id = pg_temp.id('m1') $$,
  $$ values ('M-1'::text, 'Press 1'::text, 'AT-1'::text, 'Haitian'::text, 'MA-900'::text, 'Ke-2000'::text, 'active'::text, '50000000-0000-4000-c200-00000000000a'::uuid) $$, 'machine: all fields stored');
select is(pg_temp.n_audit('machine.created'), 1, 'machine: one create audit row');
select is((pg_temp.keep('m2', public.pm_save_machine(gen_random_uuid(), null, 'm-2', 'Press 2', '  ', '', null, null, null, 'under_maintenance')))->>'ok', 'true', 'machine: second created, lower-case code, under maintenance');
select results_eq($$ select asset_tag, make, status from public.machine where id = pg_temp.id('m2') $$, $$ values (null::text, null::text, 'under_maintenance'::text) $$, 'machine: blank optional fields are stored as null');
select is((pg_temp.err($$ select public.pm_save_machine(gen_random_uuid(), null, 'M-2', 'Dup', null, null, null, null, null, 'active') $$))->>'code', 'duplicate', 'machine: duplicate code (case-insensitive) refused');
select is((pg_temp.err($$ select public.pm_save_machine(gen_random_uuid(), null, 'M-2', 'Dup', null, null, null, null, null, 'active') $$))->>'field', 'code', 'machine: duplicate is reported on field code');
select is((pg_temp.err($$ select public.pm_save_machine(gen_random_uuid(), null, 'bad code', 'X', null, null, null, null, null, 'active') $$))->>'field', 'code', 'machine: invalid code refused');
select is((pg_temp.err($$ select public.pm_save_machine(gen_random_uuid(), null, repeat('A', 21), 'X', null, null, null, null, null, 'active') $$))->>'field', 'code', 'machine: code over 20 characters refused');
select is((pg_temp.err($$ select public.pm_save_machine(gen_random_uuid(), null, 'M-3', '', null, null, null, null, null, 'active') $$))->>'field', 'name', 'machine: blank name refused');
select is((pg_temp.err($$ select public.pm_save_machine(gen_random_uuid(), null, 'M-3', 'X', null, repeat('m', 81), null, null, null, 'active') $$))->>'field', 'make', 'machine: make over 80 characters refused');
select is((pg_temp.err($$ select public.pm_save_machine(gen_random_uuid(), null, 'M-3', 'X', null, null, null, null, null, 'retired') $$))->>'field', 'status', 'machine: status retired is not a form value');
select is((pg_temp.err(format($$ select public.pm_save_machine(gen_random_uuid(), null, 'M-3', 'X', null, null, null, null, %L, 'active') $$, (select id from public.line where archived_at is not null))))->>'field', 'line_id', 'machine: an archived line is refused');
select is((public.pm_save_machine(gen_random_uuid(), pg_temp.id('m2'), 'M-2', 'Press 2b', 'AT-2', null, null, null, pg_temp.id('line_b'), 'active'))->>'ok', 'true', 'machine: updated');
select results_eq($$ select name, asset_tag, line_id, status from public.machine where id = pg_temp.id('m2') $$,
  $$ values ('Press 2b'::text, 'AT-2'::text, (select id from public.line where name = 'Line B2'), 'active'::text) $$, 'machine: update stored');
select results_eq($$ select before->>'name', after->>'name', after->>'status' from public.audit_event where action = 'machine.updated' $$,
  $$ values ('Press 2'::text, 'Press 2b'::text, 'active'::text) $$, 'machine: update audited with before/after');
select is((pg_temp.err(format($$ select public.pm_save_machine(gen_random_uuid(), %L, 'M-1', 'Clash', null, null, null, null, null, 'active') $$, pg_temp.id('m2'))))->>'code', 'duplicate', 'machine: renaming the code onto another machine is refused');
insert into ids values ('rq_m3', gen_random_uuid());
select is((pg_temp.keep('m3', public.pm_save_machine(pg_temp.id('rq_m3'), null, 'M-3', 'Press 3', null, null, null, null, null, 'active')))->>'ok', 'true', 'machine: third created');
select is((public.pm_save_machine(pg_temp.id('rq_m3'), null, 'M-3', 'Press 3', null, null, null, null, null, 'active'))->>'already', 'true', 'machine: a repeat reports already done');
select is((select count(*)::int from public.machine where code = 'M-3'), 1, 'machine: the repeat creates no second row');
select is((public.pm_set_machine_retired(gen_random_uuid(), pg_temp.id('m3'), true))->>'changed', 'true', 'machine: retire');
select is(pg_temp.n_audit('machine.retired'), 2, 'machine: retire audited (M-1 earlier, M-3 now)');
select is((public.pm_set_machine_retired(gen_random_uuid(), pg_temp.id('m3'), true))->>'changed', 'false', 'machine: retiring twice is a no-op');
select is(pg_temp.n_audit('machine.retired'), 2, 'machine: the no-op writes no audit row');
select is((pg_temp.err(format($$ select public.pm_save_machine(gen_random_uuid(), %L, 'M-3', 'Edit', null, null, null, null, null, 'active') $$, pg_temp.id('m3'))))->>'field', 'retired', 'machine: a retired machine cannot be edited');
select is((public.pm_set_machine_retired(gen_random_uuid(), pg_temp.id('m3'), false))->>'changed', 'true', 'machine: reinstated');
select is(pg_temp.n_audit('machine.reinstated'), 2, 'machine: reinstate audited (M-1 earlier, M-3 now)');
select is((pg_temp.err(format($$ select public.pm_set_machine_retired(gen_random_uuid(), %L, null) $$, pg_temp.id('m3'))))->>'field', 'retired', 'machine: retire flag required');

-- Products (AC-4) ------------------------------------------------------------------------
select is((pg_temp.keep('p1', public.pm_save_product(gen_random_uuid(), null, 'P-1', 'Cap 28mm', null)))->>'ok', 'true', 'product: created');
select results_eq($$ select code, description, uom from public.product where id = pg_temp.id('p1') $$, $$ values ('P-1'::text, 'Cap 28mm'::text, 'pcs'::text) $$, 'product: unit of measure defaults to pcs');
select is(pg_temp.n_audit('product.created'), 1, 'product: one create audit row');
select is((pg_temp.err($$ select public.pm_save_product(gen_random_uuid(), null, 'p-1', 'Dup', 'pcs') $$))->>'code', 'duplicate', 'product: duplicate code (case-insensitive) refused');
select is((pg_temp.err($$ select public.pm_save_product(gen_random_uuid(), null, 'bad code', 'X', 'pcs') $$))->>'field', 'code', 'product: invalid code refused');
select is((pg_temp.err($$ select public.pm_save_product(gen_random_uuid(), null, 'P-9', '', 'pcs') $$))->>'field', 'description', 'product: blank description refused');
select is((pg_temp.err($$ select public.pm_save_product(gen_random_uuid(), null, 'P-9', 'X', 'abcdefghijk') $$))->>'field', 'uom', 'product: unit over 10 characters refused');
select is((pg_temp.keep('p2', public.pm_save_product(gen_random_uuid(), null, 'P-2', 'Bottle 1L', 'kg')))->>'ok', 'true', 'product: second created');
select is((public.pm_save_product(gen_random_uuid(), pg_temp.id('p2'), 'P-2', 'Bottle 1.5L', 'pcs'))->>'ok', 'true', 'product: updated');
select results_eq($$ select before->>'description', after->>'description' from public.audit_event where action = 'product.updated' $$, $$ values ('Bottle 1L'::text, 'Bottle 1.5L'::text) $$, 'product: update audited with before/after');

-- Targets (AC-5..8) ------------------------------------------------------------------------
create temp table today as select app.plant_date('50000000-0000-4000-c200-00000000000a') as d;
select is((select d from today), (now() at time zone 'Asia/Kolkata')::date, 'the plant date of tenant X is the IST date');
select is((pg_temp.err(format($$ select public.pm_set_target(gen_random_uuid(), %L, %L, 1000, %L) $$, pg_temp.id('m1'), pg_temp.id('p1'), (select d - 1 from today))))->>'field', 'effective_from', 'target: backdating refused on field effective_from');
select is((pg_temp.err(format($$ select public.pm_set_target(gen_random_uuid(), %L, %L, 1000, %L) $$, pg_temp.id('m1'), pg_temp.id('p1'), (select d - 1 from today))))->>'message', 'Targets can''t start in the past', 'target: backdating message');
select is((pg_temp.err(format($$ select public.pm_set_target(gen_random_uuid(), %L, %L, 0, %L) $$, pg_temp.id('m1'), pg_temp.id('p1'), (select d from today))))->>'field', 'pieces', 'target: 0 pieces refused');
select is((pg_temp.err(format($$ select public.pm_set_target(gen_random_uuid(), %L, %L, 1000001, %L) $$, pg_temp.id('m1'), pg_temp.id('p1'), (select d from today))))->>'field', 'pieces', 'target: over 1 000 000 refused');
select is((pg_temp.err(format($$ select public.pm_set_target(gen_random_uuid(), %L, %L, null, %L) $$, pg_temp.id('m1'), pg_temp.id('p1'), (select d from today))))->>'field', 'pieces', 'target: null pieces refused');
select is((pg_temp.err(format($$ select public.pm_set_target(gen_random_uuid(), %L, %L, 1000, null) $$, pg_temp.id('m1'), pg_temp.id('p1'))))->>'field', 'effective_from', 'target: missing date refused');
insert into ids values ('rq_t1', gen_random_uuid());
select is((pg_temp.keep('t1', public.pm_set_target(pg_temp.id('rq_t1'), pg_temp.id('m1'), pg_temp.id('p1'), 1000, (select d from today))))->>'ok', 'true', 'target: set effective today');
select is(app.target_for(pg_temp.id('m1'), pg_temp.id('p1'), (select d from today)), 1000, 'target: in force today');
select results_eq($$ select recorded_by, pieces_per_shift, request_id from public.target_version where id = pg_temp.id('t1') $$,
  $$ values (pg_temp.id('uax'), 1000, pg_temp.id('rq_t1')) $$, 'target: recorded by the caller with the request id');
select results_eq($$ select (before->>'pieces_per_shift') is null, after->>'pieces_per_shift', after->>'machine_code', after->>'product_code' from public.audit_event where action = 'target.set' $$,
  $$ values (true, '1000'::text, 'M-1'::text, 'P-1'::text) $$, 'target: set audited with before (none) and after');
select is((public.pm_set_target(pg_temp.id('rq_t1'), pg_temp.id('m1'), pg_temp.id('p1'), 1000, (select d from today)))->>'already', 'true', 'target: a repeat reports already done');
select is((select count(*)::int from public.target_version where machine_id = pg_temp.id('m1')), 1, 'target: the repeat records no second version');
select is(pg_temp.n_audit('target.set'), 1, 'target: the repeat writes no second audit row');
select is((pg_temp.keep('t2', public.pm_set_target(gen_random_uuid(), pg_temp.id('m1'), pg_temp.id('p1'), 1300, (select d + 10 from today))))->>'ok', 'true', 'target: change scheduled 10 days ahead');
select is(app.target_for(pg_temp.id('m1'), pg_temp.id('p1'), (select d + 9 from today)), 1000, 'target: the old target applies the day before the change');
select is(app.target_for(pg_temp.id('m1'), pg_temp.id('p1'), (select d + 10 from today)), 1300, 'target: the new target applies from the change date');
select is((select (before->>'pieces_per_shift')::int from public.audit_event where entity_id = pg_temp.id('t2')), 1000, 'target: the audit before shows the target in force on that date');
select is((public.pm_set_target(gen_random_uuid(), pg_temp.id('m1'), pg_temp.id('p1'), 1100, (select d from today)))->>'ok', 'true', 'target: same-day correction accepted');
select is(app.target_for(pg_temp.id('m1'), pg_temp.id('p1'), (select d from today)), 1100, 'target: the correction wins for that day');
select is((select count(*)::int from public.target_version where machine_id = pg_temp.id('m1')), 3, 'target: history keeps every version');
-- retired machine / product cannot get a target
select is((public.pm_set_machine_retired(gen_random_uuid(), pg_temp.id('m3'), true))->>'ok', 'true', 'machine M-3 retired for the guard test');
select is((pg_temp.err(format($$ select public.pm_set_target(gen_random_uuid(), %L, %L, 500, %L) $$, pg_temp.id('m3'), pg_temp.id('p1'), (select d from today))))->>'field', 'machine_id', 'target: retired machine refused');
select is((pg_temp.keep('p3', public.pm_save_product(gen_random_uuid(), null, 'P-3', 'Lid', 'pcs')))->>'ok', 'true', 'product P-3 created');
select is((public.pm_set_product_retired(gen_random_uuid(), pg_temp.id('p3'), true))->>'changed', 'true', 'product without targets can be retired');
select is(pg_temp.n_audit('product.retired'), 1, 'product: retire audited');
select is((pg_temp.err(format($$ select public.pm_set_target(gen_random_uuid(), %L, %L, 500, %L) $$, pg_temp.id('m2'), pg_temp.id('p3'), (select d from today))))->>'field', 'product_id', 'target: retired product refused');
select is((pg_temp.err(format($$ select public.pm_save_product(gen_random_uuid(), %L, 'P-3', 'Edit', 'pcs') $$, pg_temp.id('p3'))))->>'field', 'retired', 'product: a retired product cannot be edited');
select is((public.pm_set_product_retired(gen_random_uuid(), pg_temp.id('p3'), false))->>'changed', 'true', 'product: reinstated');
select is(pg_temp.n_audit('product.reinstated'), 1, 'product: reinstate audited');
-- retire guard: current or future targets block the product
select is((pg_temp.err(format($$ select public.pm_set_product_retired(gen_random_uuid(), %L, true) $$, pg_temp.id('p1'))) - 'message'),
  '{"code":"guard","field":"product","machines":["M-1"],"sqlstate":"P0001"}'::jsonb, 'product: retire blocked by a current target (lists machine codes)');
select is((pg_temp.keep('t3', public.pm_set_target(gen_random_uuid(), pg_temp.id('m2'), pg_temp.id('p3'), 400, (select d + 3 from today))))->>'ok', 'true', 'future-only target set on M-2 / P-3');
select is((pg_temp.err(format($$ select public.pm_set_product_retired(gen_random_uuid(), %L, true) $$, pg_temp.id('p3'))))->'machines', '["M-2"]'::jsonb, 'product: retire blocked by a future-only target');
-- end target
select is((pg_temp.err(format($$ select public.pm_end_target(gen_random_uuid(), %L, %L, %L) $$, pg_temp.id('m1'), pg_temp.id('p1'), (select d - 1 from today))))->>'field', 'effective_from', 'end: a past date is refused');
select is((pg_temp.err(format($$ select public.pm_end_target(gen_random_uuid(), %L, %L, %L) $$, pg_temp.id('m2'), pg_temp.id('p1'), (select d from today))))->>'field', 'no_target', 'end: no target in force is refused (guard no_target)');
select is((pg_temp.err(format($$ select public.pm_end_target(gen_random_uuid(), %L, %L, %L) $$, pg_temp.id('m2'), pg_temp.id('p3'), (select d from today))))->>'field', 'no_target', 'end: a target that only starts later is not in force today');
select is((pg_temp.keep('t4', public.pm_end_target(gen_random_uuid(), pg_temp.id('m2'), pg_temp.id('p3'), (select d + 3 from today))))->>'ok', 'true', 'end: ends the future target from its own start date');
select is(app.target_for(pg_temp.id('m2'), pg_temp.id('p3'), (select d + 3 from today)), null, 'end: no target from the end date');
select results_eq($$ select (before->>'pieces_per_shift')::int, (after->>'pieces_per_shift') is null from public.audit_event where action = 'target.ended' $$, $$ values (400, true) $$, 'end: audited with before and after');
select is((public.pm_set_product_retired(gen_random_uuid(), pg_temp.id('p3'), true))->>'changed', 'true', 'product: retire allowed once every target is ended');
create temp table e20 as select public.pm_end_target(gen_random_uuid(), pg_temp.id('m1'), pg_temp.id('p1'), (select d + 20 from today)) as r; -- own statement: a stable function must see the committed-in-transaction row
select is((e20.r->>'ok') || ':' || coalesce(app.target_for(pg_temp.id('m1'), pg_temp.id('p1'), (select d + 20 from today))::text, 'none'), 'true:none', 'end: ends M-1 / P-1 20 days ahead (ok, and no target from that day)') from e20;
select is(app.target_for(pg_temp.id('m1'), pg_temp.id('p1'), (select d + 19 from today)), 1300, 'end: still in force the day before');
select is((pg_temp.err(format($$ select public.pm_set_product_retired(gen_random_uuid(), %L, true) $$, pg_temp.id('p1'))))->>'code', 'guard', 'product: still blocked while the target is in force until its end date');
-- ending works for retired machines too
select is((public.pm_set_machine_retired(gen_random_uuid(), pg_temp.id('m1'), true))->>'ok', 'true', 'machine M-1 retired with an open target');
create temp table e5 as select public.pm_end_target(gen_random_uuid(), pg_temp.id('m1'), pg_temp.id('p1'), (select d + 5 from today)) as r; -- own statement: a stable function must see the committed-in-transaction row
select is((e5.r->>'ok') || ':' || coalesce(app.target_for(pg_temp.id('m1'), pg_temp.id('p1'), (select d + 5 from today))::text, 'none'), 'true:none', 'end: allowed for a retired machine (ok, and no target from that day)') from e5;

-- Denials (AC-10, AC-11) ----------------------------------------------------------------------
create temp table calls (n text, q text);
insert into calls values
  ('site', $$ select public.pm_save_site(gen_random_uuid(), 'Nope', 'UTC') $$),
  ('line', $$ select public.pm_save_line(gen_random_uuid(), null, 'Nope') $$),
  ('archive', format($$ select public.pm_archive_line(gen_random_uuid(), %L) $$, (select id from public.line where name = 'Line B2'))),
  ('machine', $$ select public.pm_save_machine(gen_random_uuid(), null, 'NOPE', 'Nope', null, null, null, null, null, 'active') $$),
  ('retire_m', format($$ select public.pm_set_machine_retired(gen_random_uuid(), %L, true) $$, (select id from public.machine where code = 'M-2'))),
  ('product', $$ select public.pm_save_product(gen_random_uuid(), null, 'NOPE', 'Nope', 'pcs') $$),
  ('retire_p', format($$ select public.pm_set_product_retired(gen_random_uuid(), %L, true) $$, (select id from public.product where code = 'P-2'))),
  ('set_t', format($$ select public.pm_set_target(gen_random_uuid(), %L, %L, 5, current_date + 30) $$, (select id from public.machine where code = 'M-2'), (select id from public.product where code = 'P-2'))),
  ('end_t', format($$ select public.pm_end_target(gen_random_uuid(), %L, %L, current_date + 30) $$, (select id from public.machine where code = 'M-2'), (select id from public.product where code = 'P-2')));
create function pg_temp.run_all() returns int language plpgsql as $$
declare c record; ok int := 0; r jsonb;
begin
  for c in select * from calls loop
    execute c.q into r;
    if r = '{"ok": false, "code": "not_allowed"}'::jsonb then ok := ok + 1; end if;
  end loop;
  return ok;
end $$;
create temp table before_counts as select (select count(*) from public.machine) m, (select count(*) from public.product) p, (select count(*) from public.line) l,
  (select count(*) from public.target_version) t, (select count(*) from public.site) s, (select count(*) from public.audit_event where action <> 'access.denied') a;

select pg_temp.as_user('supx');
select is(pg_temp.run_all(), 9, 'a supervisor gets the generic denial from every write RPC');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('supx') and reason = 'role'
           and actor_role = 'supervisor' and tenant_id = pg_temp.id('tx') and request_id is null and source like 'rpc:pm_%'), 9, 'each supervisor denial is audited (reason role)');
select pg_temp.as_user('freshx');
select is(pg_temp.run_all(), 9, 'a Unit Admin with a temporary password is denied everywhere');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('freshx') and reason = 'must_change_password'), 9, 'must-change denials audited');
select pg_temp.as_user('uas');
select is(pg_temp.run_all(), 9, 'a Unit Admin of a suspended tenant is denied everywhere');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('uas') and reason = 'inactive'), 9, 'suspended-tenant denials audited');
select pg_temp.as_user('inactx');
select is(pg_temp.run_all(), 9, 'an inactive Unit Admin is denied everywhere');
select pg_temp.as_user('nomem');
select is(pg_temp.run_all(), 9, 'a caller with no membership is denied everywhere');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('nomem') and reason = 'no_membership' and tenant_id is null), 9, 'no-membership denials audited without a tenant');
select results_eq($$ select (select count(*) from public.machine), (select count(*) from public.product), (select count(*) from public.line),
  (select count(*) from public.target_version), (select count(*) from public.site), (select count(*) from public.audit_event where action <> 'access.denied') $$,
  $$ select m, p, l, t, s, a from before_counts $$, 'denied callers changed nothing');

-- Cross-tenant ids (AC-11): another tenant's ids and unknown ids give the same generic denial, audited under the caller's tenant
select pg_temp.as_user('uay');
select is((pg_temp.keep('ym', public.pm_save_machine(gen_random_uuid(), null, 'Y-1', 'Y press', null, null, null, null, null, 'active')))->>'ok', 'true', 'tenant Y has a machine');
select is((pg_temp.keep('yp', public.pm_save_product(gen_random_uuid(), null, 'Y-P', 'Y product', 'pcs')))->>'ok', 'true', 'tenant Y has a product');
select is((pg_temp.keep('yl', public.pm_save_line(gen_random_uuid(), null, 'Y line')))->>'ok', 'true', 'tenant Y has a line');
select pg_temp.as_user('uax');
create temp table x_calls (n text, q text);
insert into x_calls
select n, q from (values
  ('line_rename', format($$ select public.pm_save_line(gen_random_uuid(), %L, 'Hacked') $$, pg_temp.id('yl'))),
  ('line_archive', format($$ select public.pm_archive_line(gen_random_uuid(), %L) $$, pg_temp.id('yl'))),
  ('machine_update', format($$ select public.pm_save_machine(gen_random_uuid(), %L, 'Y-1', 'Hacked', null, null, null, null, null, 'active') $$, pg_temp.id('ym'))),
  ('machine_line', format($$ select public.pm_save_machine(gen_random_uuid(), null, 'X-NEW', 'New', null, null, null, null, %L, 'active') $$, pg_temp.id('yl'))),
  ('machine_retire', format($$ select public.pm_set_machine_retired(gen_random_uuid(), %L, true) $$, pg_temp.id('ym'))),
  ('product_update', format($$ select public.pm_save_product(gen_random_uuid(), %L, 'Y-P', 'Hacked', 'pcs') $$, pg_temp.id('yp'))),
  ('product_retire', format($$ select public.pm_set_product_retired(gen_random_uuid(), %L, true) $$, pg_temp.id('yp'))),
  ('target_machine', format($$ select public.pm_set_target(gen_random_uuid(), %L, %L, 5, %L) $$, pg_temp.id('ym'), pg_temp.id('p1'), (select d from today))),
  ('target_product', format($$ select public.pm_set_target(gen_random_uuid(), %L, %L, 5, %L) $$, pg_temp.id('m1'), pg_temp.id('yp'), (select d from today))),
  ('end_target', format($$ select public.pm_end_target(gen_random_uuid(), %L, %L, %L) $$, pg_temp.id('ym'), pg_temp.id('yp'), (select d from today)))
) t(n, q);
create function pg_temp.run_x() returns int language plpgsql as $$
declare c record; ok int := 0; r jsonb;
begin
  for c in select * from x_calls loop
    execute c.q into r;
    if r = '{"ok": false, "code": "not_allowed"}'::jsonb then ok := ok + 1; end if;
  end loop;
  return ok;
end $$;
select is(pg_temp.run_x(), 10, 'every RPC given another tenant''s id returns the generic denial');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('uax') and reason = 'cross_tenant' and tenant_id = pg_temp.id('tx')), 10, 'cross-tenant denials are audited under the caller''s tenant');
select is((select name from public.machine where id = pg_temp.id('ym')), 'Y press', 'tenant Y''s machine was not changed');
select is((select count(*)::int from public.target_version where machine_id = pg_temp.id('ym')), 0, 'no target was written for tenant Y''s machine');
select is(public.pm_save_machine(gen_random_uuid(), gen_random_uuid(), 'Z-1', 'Ghost', null, null, null, null, null, 'active'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'an unknown id returns the same generic denial');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('uax') and reason = 'not_found'), 1, 'an unknown id is audited as not_found');

-- No access.denied row ever carries a request id (a denial is not a recorded request) and audit rows hold no raw personal data
select is((select count(*)::int from public.audit_event where action = 'access.denied' and request_id is not null), 0, 'denials carry no request id');
select is((select count(*)::int from public.audit_event where tenant_id in (pg_temp.id('tx'), pg_temp.id('ty')) and action not like 'access.%' and actor_user_id is null), 0, 'every success audit row names its actor');

-- Called by the real client role (the whole privilege chain: authenticated -> definer function -> forced-RLS tables)
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c200-0000000000a1","role":"authenticated"}', true);
select is((public.pm_save_line(gen_random_uuid(), null, 'Line via client role'))->>'ok', 'true', 'an authenticated Unit Admin can call a pm_* RPC');
select is((select count(*)::int from public.line where name = 'Line via client role'), 1, 'and reads the result back under RLS');
reset role;

select * from finish();
rollback;
