-- 05 AC-7, AC-8, AC-12 (DB part, targets): sh_set_target_override / sh_end_target_override, app.override_for and app.effective_target
-- (override > base target > null), the tenant rule (only the service role skips it), append-only history, audited denials, idempotency.
-- Self-contained; rolled back. Dates are offsets from today's plant date.
begin;
create extension if not exists pgtap with schema extensions;
select plan(97);

create temp table ids (k text primary key, v uuid);
create function pg_temp.id(k text) returns uuid language sql as $$ select v from ids where k = $1 $$;
create function pg_temp.as_user(k text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where ids.k = $1), 'role', 'authenticated')::text, true) $$;
create function pg_temp.err(q text) returns jsonb language plpgsql as $f$
declare d text; m text; st text;
begin
  execute q;
  return jsonb_build_object('raised', false);
exception when others then
  get stacked diagnostics d = pg_exception_detail, m = message_text, st = returned_sqlstate;
  return coalesce(case when d ~ '^[{]' then d::jsonb end, '{}'::jsonb) || jsonb_build_object('message', m, 'sqlstate', st);
end $f$;
create function pg_temp.n_audit(a text, t text) returns int language sql as $$
  select count(*)::int from public.audit_event where action = a and tenant_id = pg_temp.id(t) $$;

-- Fixtures (as postgres) ---------------------------------------------------
insert into auth.users (id, email, aud, role)
select u, 'tap32-' || n || '@example.test', 'authenticated', 'authenticated' from (values
  ('00000000-0000-4000-c620-0000000000a1'::uuid, 'uax'), ('00000000-0000-4000-c620-0000000000a2', 'supx'), ('00000000-0000-4000-c620-0000000000a3', 'freshx'),
  ('00000000-0000-4000-c620-0000000000a4', 'inactx'), ('00000000-0000-4000-c620-0000000000b1', 'uay'), ('00000000-0000-4000-c620-0000000000d1', 'uas'),
  ('00000000-0000-4000-c620-0000000000c1', 'nomem')) t(u, n);
insert into ids values ('uax', '00000000-0000-4000-c620-0000000000a1'), ('supx', '00000000-0000-4000-c620-0000000000a2'), ('freshx', '00000000-0000-4000-c620-0000000000a3'),
  ('inactx', '00000000-0000-4000-c620-0000000000a4'), ('uay', '00000000-0000-4000-c620-0000000000b1'), ('uas', '00000000-0000-4000-c620-0000000000d1'),
  ('nomem', '00000000-0000-4000-c620-0000000000c1'), ('tx', '50000000-0000-4000-c620-00000000000a'), ('ty', '50000000-0000-4000-c620-00000000000b'),
  ('ts', '50000000-0000-4000-c620-00000000000d');
insert into public.tenant (id, name, status, timezone) values
  ('50000000-0000-4000-c620-00000000000a', 'tap32 org X', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c620-00000000000b', 'tap32 org Y', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c620-00000000000d', 'tap32 org S', 'suspended', 'Asia/Kolkata');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('50000000-0000-4000-c620-00000000000a', '00000000-0000-4000-c620-0000000000a1', 'unit_admin', 'active', 'UA X', 'UA-X', '+919000020201', false),
  ('50000000-0000-4000-c620-00000000000a', '00000000-0000-4000-c620-0000000000a2', 'supervisor', 'active', 'SUP X', 'SUP-X', '+919000020202', false),
  ('50000000-0000-4000-c620-00000000000a', '00000000-0000-4000-c620-0000000000a3', 'unit_admin', 'active', 'Fresh X', 'FR-X', '+919000020203', true),
  ('50000000-0000-4000-c620-00000000000a', '00000000-0000-4000-c620-0000000000a4', 'unit_admin', 'inactive', 'Gone X', 'GO-X', '+919000020204', false),
  ('50000000-0000-4000-c620-00000000000b', '00000000-0000-4000-c620-0000000000b1', 'unit_admin', 'active', 'UA Y', 'UA-Y', '+919000020205', false),
  ('50000000-0000-4000-c620-00000000000d', '00000000-0000-4000-c620-0000000000d1', 'unit_admin', 'active', 'UA S', 'UA-S', '+919000020206', false);
insert into public.site (id, tenant_id, name, timezone) values
  ('51000000-0000-4000-c620-00000000000a', pg_temp.id('tx'), 'Plant X', 'Asia/Kolkata'),
  ('51000000-0000-4000-c620-00000000000b', pg_temp.id('ty'), 'Plant Y', 'Asia/Kolkata');
insert into public.machine (id, tenant_id, site_id, code, name, retired_at) values
  ('53000000-0000-4000-c620-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c620-00000000000a', 'M-1', 'Press 1', null),
  ('53000000-0000-4000-c620-0000000000a2', pg_temp.id('tx'), '51000000-0000-4000-c620-00000000000a', 'M-2', 'Press 2', null),
  ('53000000-0000-4000-c620-0000000000a3', pg_temp.id('tx'), '51000000-0000-4000-c620-00000000000a', 'M-3', 'Retired press', now()),
  ('53000000-0000-4000-c620-0000000000b1', pg_temp.id('ty'), '51000000-0000-4000-c620-00000000000b', 'Y-1', 'Y press', null);
insert into public.product (id, tenant_id, code, description, retired_at) values
  ('55000000-0000-4000-c620-0000000000a1', pg_temp.id('tx'), 'P-1', 'Cap', null),
  ('55000000-0000-4000-c620-0000000000a2', pg_temp.id('tx'), 'P-2', 'Lid', null),
  ('55000000-0000-4000-c620-0000000000a3', pg_temp.id('tx'), 'P-3', 'Old', now()),
  ('55000000-0000-4000-c620-0000000000b1', pg_temp.id('ty'), 'Y-P', 'Y cap', null);
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time, retired_at) values
  ('54000000-0000-4000-c620-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c620-00000000000a', 'Day', '06:00', '14:00', null),
  ('54000000-0000-4000-c620-0000000000a2', pg_temp.id('tx'), '51000000-0000-4000-c620-00000000000a', 'Night', '22:00', '06:00', null),
  ('54000000-0000-4000-c620-0000000000a3', pg_temp.id('tx'), '51000000-0000-4000-c620-00000000000a', 'Gone', '10:00', '12:00', now()),
  ('54000000-0000-4000-c620-0000000000b1', pg_temp.id('ty'), '51000000-0000-4000-c620-00000000000b', 'Y shift', '06:00', '14:00', null);
insert into ids values ('m1', '53000000-0000-4000-c620-0000000000a1'), ('m2', '53000000-0000-4000-c620-0000000000a2'), ('m3', '53000000-0000-4000-c620-0000000000a3'),
  ('my', '53000000-0000-4000-c620-0000000000b1'), ('p1', '55000000-0000-4000-c620-0000000000a1'), ('p2', '55000000-0000-4000-c620-0000000000a2'),
  ('p3', '55000000-0000-4000-c620-0000000000a3'), ('py', '55000000-0000-4000-c620-0000000000b1'), ('day', '54000000-0000-4000-c620-0000000000a1'),
  ('night', '54000000-0000-4000-c620-0000000000a2'), ('gone', '54000000-0000-4000-c620-0000000000a3'), ('shifty', '54000000-0000-4000-c620-0000000000b1');
grant select on ids to authenticated, anon;
create temp table today as select app.plant_date(pg_temp.id('tx')) as d;
grant select on today to authenticated, anon;
create function pg_temp.eff(m text, p text, sh text, off int) returns integer language sql as $$
  select app.effective_target(pg_temp.id($1), pg_temp.id($2), pg_temp.id($3), (select d + $4 from today)) $$;
create function pg_temp.ov(m text, p text, sh text, off int) returns integer language sql as $$
  select app.override_for(pg_temp.id($1), pg_temp.id($2), pg_temp.id($3), (select d + $4 from today)) $$;
create function pg_temp.set_o(m text, p text, sh text, pieces int, off int) returns jsonb language sql as $$
  select public.sh_set_target_override(gen_random_uuid(), pg_temp.id($1), pg_temp.id($2), pg_temp.id($3), $4, (select d + $5 from today)) $$;
create function pg_temp.end_o(m text, p text, sh text, off int) returns jsonb language sql as $$
  select public.sh_end_target_override(gen_random_uuid(), pg_temp.id($1), pg_temp.id($2), pg_temp.id($3), (select d + $4 from today)) $$;
create function pg_temp.nv(m text, p text, sh text) returns int language sql as $$
  select count(*)::int from public.target_override_version where machine_id = pg_temp.id($1) and product_id = pg_temp.id($2) and shift_id = pg_temp.id($3) $$;

-- Privileges ----------------------------------------------------------------------
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('sh_set_target_override', 'sh_end_target_override')
             and has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute')
             and p.prosecdef and p.proconfig is not null and 'search_path=""' = any (p.proconfig)), 2,
  'both override RPCs are security definer, empty search_path, executable by authenticated and not by anon');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'app' and p.proname in ('override_for', 'effective_target')
             and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')
                  or not p.prosecdef or p.proconfig is null or not ('search_path=""' = any (p.proconfig)))), 0,
  'override_for and effective_target are security definer with an empty search_path and not executable by clients');

-- Set (AC-7) -----------------------------------------------------------------------------
select pg_temp.as_user('uax');
select is(pg_temp.eff('m1', 'p1', 'night', 0), null, 'AC-8: no override and no base target: null');
select public.pm_set_target(gen_random_uuid(), pg_temp.id('m1'), pg_temp.id('p1'), 1000, (select d from today));
select is(pg_temp.eff('m1', 'p1', 'night', 0), 1000, 'AC-8: no override: the base target applies');
select is((pg_temp.err(format($$ select public.sh_set_target_override(gen_random_uuid(), %L, %L, %L, 800, %L) $$, pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('night'), (select d - 1 from today))))->>'field', 'effective_from', 'backdating is refused on field effective_from');
select is((pg_temp.err(format($$ select public.sh_set_target_override(gen_random_uuid(), %L, %L, %L, 800, %L) $$, pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('night'), (select d - 1 from today))))->>'message', 'Targets can''t start in the past', 'backdating message');
select is((pg_temp.err(format($$ select public.sh_set_target_override(gen_random_uuid(), %L, %L, %L, 0, %L) $$, pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('night'), (select d from today))))->>'field', 'pieces', '0 pieces is refused');
select is((pg_temp.err(format($$ select public.sh_set_target_override(gen_random_uuid(), %L, %L, %L, 1000001, %L) $$, pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('night'), (select d from today))))->>'field', 'pieces', 'over 1 000 000 is refused');
select is((pg_temp.err(format($$ select public.sh_set_target_override(gen_random_uuid(), %L, %L, %L, null, %L) $$, pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('night'), (select d from today))))->>'field', 'pieces', 'null pieces is refused');
select is((pg_temp.err(format($$ select public.sh_set_target_override(gen_random_uuid(), %L, %L, %L, 800, null) $$, pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('night'))))->>'field', 'effective_from', 'a missing date is refused');
select is((pg_temp.err(format($$ select public.sh_set_target_override(null, %L, %L, %L, 800, %L) $$, pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('night'), (select d from today))))->>'field', 'request_id', 'a null request id is refused');
insert into ids values ('rq_o1', gen_random_uuid());
select is((public.sh_set_target_override(pg_temp.id('rq_o1'), pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('night'), 800, (select d + 2 from today)))->>'ok', 'true', 'an override is set 2 days ahead');
select results_eq($$ select recorded_by, pieces_per_shift, request_id, effective_from from public.target_override_version where machine_id = pg_temp.id('m1') $$,
  $$ values (pg_temp.id('uax'), 800, pg_temp.id('rq_o1'), (select d + 2 from today)) $$, 'recorded by the caller with the request id');
select results_eq($$ select (before->>'pieces_per_shift') is null, after->>'pieces_per_shift', after->>'machine_code', after->>'product_code', after->>'shift'
  from public.audit_event where action = 'target_override.set' and tenant_id = pg_temp.id('tx') $$,
  $$ values (true, '800'::text, 'M-1'::text, 'P-1'::text, 'Night'::text) $$, 'audited with before (none), machine, product and shift');
select is((public.sh_set_target_override(pg_temp.id('rq_o1'), pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('night'), 800, (select d + 2 from today)))->>'already', 'true', 'a repeat reports already done');
select is(pg_temp.nv('m1', 'p1', 'night'), 1, 'the repeat records no second version');
select is(pg_temp.n_audit('target_override.set', 'tx'), 1, 'the repeat writes no second audit row');
select is(pg_temp.eff('m1', 'p1', 'night', 1), 1000, 'AC-8: the base target applies before the override starts');
select is(pg_temp.eff('m1', 'p1', 'night', 2), 800, 'AC-8: the override applies from its date');
select is(pg_temp.eff('m1', 'p1', 'day', 2), 1000, 'AC-8: other shifts keep the base target');
select is(pg_temp.eff('m1', 'p2', 'night', 2), null, 'AC-8: another product has neither');
select is(pg_temp.eff('m2', 'p1', 'night', 2), null, 'AC-8: another machine has neither');
select is(pg_temp.ov('m1', 'p1', 'night', 1), null, 'override_for is null before the start');
-- a change scheduled later and a same-day correction
select is((pg_temp.set_o('m1', 'p1', 'night', 700, 12))->>'ok', 'true', 'a later change is scheduled');
select is(pg_temp.eff('m1', 'p1', 'night', 11), 800, 'the earlier override applies the day before the change');
select is(pg_temp.eff('m1', 'p1', 'night', 12), 700, 'the later override applies from its date');
select is((pg_temp.set_o('m1', 'p1', 'night', 850, 2))->>'ok', 'true', 'a same-day correction is accepted');
select is(pg_temp.eff('m1', 'p1', 'night', 2), 850, 'the correction wins for that day');
select is(pg_temp.nv('m1', 'p1', 'night'), 3, 'history keeps every version');
select is((select (before->>'pieces_per_shift')::int from public.audit_event where action = 'target_override.set' and tenant_id = pg_temp.id('tx') and (after->>'pieces_per_shift')::int = 850), 800, 'the audit before shows the override in force on that date');
-- override without a base target
select is((pg_temp.set_o('m2', 'p1', 'day', 500, 1))->>'ok', 'true', 'an override can exist without a base target');
select is(pg_temp.eff('m2', 'p1', 'day', 1), 500, 'AC-8: and is the effective target');
-- retired machine / product / shift
select is((pg_temp.err(format($$ select public.sh_set_target_override(gen_random_uuid(), %L, %L, %L, 5, %L) $$, pg_temp.id('m3'), pg_temp.id('p1'), pg_temp.id('day'), (select d from today))))->>'field', 'machine_id', 'a retired machine is refused');
select is((pg_temp.err(format($$ select public.sh_set_target_override(gen_random_uuid(), %L, %L, %L, 5, %L) $$, pg_temp.id('m1'), pg_temp.id('p3'), pg_temp.id('day'), (select d from today))))->>'field', 'product_id', 'a retired product is refused');
select is((pg_temp.err(format($$ select public.sh_set_target_override(gen_random_uuid(), %L, %L, %L, 5, %L) $$, pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('gone'), (select d from today))))->>'field', 'shift_id', 'a retired shift is refused');

-- End (AC-7) ------------------------------------------------------------------------------
select is((pg_temp.err(format($$ select public.sh_end_target_override(gen_random_uuid(), %L, %L, %L, %L) $$, pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('night'), (select d - 1 from today))))->>'field', 'effective_from', 'end: a past date is refused');
select is((pg_temp.err(format($$ select public.sh_end_target_override(gen_random_uuid(), %L, %L, %L, %L) $$, pg_temp.id('m1'), pg_temp.id('p2'), pg_temp.id('night'), (select d + 1 from today))))->>'field', 'no_override', 'end: nothing to end is refused (guard no_override)');
-- Night overrides now: d+2 -> 850 (corrected), d+12 -> 700. Ending at d+5 ends the override and cancels the scheduled one.
insert into ids values ('rq_e1', gen_random_uuid());
create temp table e5 as select public.sh_end_target_override(pg_temp.id('rq_e1'), pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('night'), (select d + 5 from today)) as r;
select is((select r->>'ok' from e5) || ':' || (select (r->'cancelled')::text from e5), 'true:' || to_jsonb(array[(select (d + 12)::text from today)])::text, 'end: ok, and the later scheduled override is cancelled');
select is(pg_temp.eff('m1', 'p1', 'night', 4), 850, 'end: still in force the day before');
select is(pg_temp.eff('m1', 'p1', 'night', 5), 1000, 'end: the base target applies again from the end date');
select is(pg_temp.eff('m1', 'p1', 'night', 12), 1000, 'end: the cancelled override never applies');
select is(pg_temp.eff('m1', 'p1', 'night', 90), 1000, 'end: and none afterwards');
select is(pg_temp.ov('m1', 'p1', 'night', 5), null, 'end: override_for is null from the end date');
select is(pg_temp.nv('m1', 'p1', 'night'), 5, 'end: three versions + a null at the end date + a null at the cancelled date');
select is(pg_temp.n_audit('target_override.ended', 'tx'), 1, 'end: exactly one audit row');
select results_eq($$ select (before->>'pieces_per_shift')::int, (after->>'pieces_per_shift') is null, after->'cancelled_dates', after->>'shift' from public.audit_event where action = 'target_override.ended' and tenant_id = pg_temp.id('tx') $$,
  $$ select 850, true, to_jsonb(array[(select (d + 12)::text from today)]), 'Night'::text $$, 'end: audited with before, after and the cancelled dates');
select is((public.sh_end_target_override(pg_temp.id('rq_e1'), pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('night'), (select d + 5 from today)))->>'already', 'true', 'end: a repeat reports already done');
select is(pg_temp.nv('m1', 'p1', 'night'), 5, 'end: the repeat records no versions');
select is((pg_temp.err(format($$ select public.sh_end_target_override(gen_random_uuid(), %L, %L, %L, %L) $$, pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('night'), (select d + 6 from today))))->>'field', 'no_override', 'end: nothing in force and nothing scheduled is refused');
-- an override that only starts later can be ended today (cancelling it)
select is((pg_temp.set_o('m1', 'p1', 'night', 600, 30))->>'ok', 'true', 'a future-only override is set');
create temp table e20 as select pg_temp.end_o('m1', 'p1', 'night', 20) as r;
select is((select r->>'ok' from e20) || ':' || (select (r->'cancelled')::text from e20), 'true:' || to_jsonb(array[(select (d + 30)::text from today)])::text, 'end: a future-only override can be ended and is cancelled');
select is(pg_temp.eff('m1', 'p1', 'night', 30), 1000, 'end: the cancelled future override never applies');
-- ending works for retired machines
select is((public.pm_set_machine_retired(gen_random_uuid(), pg_temp.id('m2'), true))->>'ok', 'true', 'M-2 is retired');
select is((pg_temp.end_o('m2', 'p1', 'day', 3))->>'ok', 'true', 'end: allowed for a retired machine');
select is(pg_temp.eff('m2', 'p1', 'day', 3), null, 'end: no override and no base target any more');

-- Isolation of the base target and overrides between tenants ---------------------------------------
select pg_temp.as_user('uay');
select is(pg_temp.eff('m1', 'p1', 'night', 4), null, 'another tenant''s caller gets null from effective_target');
select is(pg_temp.ov('m1', 'p1', 'night', 4), null, 'and null from override_for');
select set_config('request.jwt.claims', '', true);
select is(pg_temp.eff('m1', 'p1', 'night', 4), null, 'no claims at all: null (no unauthenticated bypass)');
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select is(pg_temp.eff('m1', 'p1', 'night', 4), null, 'anon claims: null');
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select is(pg_temp.eff('m1', 'p1', 'night', 4), 850, 'the service role gets the override');
select is(pg_temp.eff('m1', 'p1', 'night', 5), 1000, 'and the base target once the override has ended');
select is(pg_temp.eff('m1', 'p1', 'day', 4), 1000, 'and the base target for a shift without an override');

-- Append-only history ------------------------------------------------------------------------------
select throws_ok($$ update public.target_override_version set pieces_per_shift = 1 $$, 'P0001', 'target_override_version is append-only', 'overrides cannot be updated (owner)');
select throws_ok($$ delete from public.target_override_version $$, 'P0001', 'target_override_version is append-only', 'overrides cannot be deleted (owner)');
select throws_ok($$ truncate public.target_override_version $$, 'P0001', 'target_override_version is append-only', 'overrides cannot be truncated (owner)');
set local role service_role;
select throws_ok($$ update public.target_override_version set pieces_per_shift = 1 $$, '42501', null, 'the service role has no update');
select throws_ok($$ delete from public.target_override_version $$, '42501', null, 'the service role has no delete');
reset role;
select throws_ok($$ insert into public.target_override_version (tenant_id, machine_id, product_id, shift_id, effective_from, pieces_per_shift, recorded_by)
  values (pg_temp.id('tx'), pg_temp.id('my'), pg_temp.id('p1'), pg_temp.id('day'), current_date, 10, pg_temp.id('uax')) $$, '23503', null, 'composite FK: an override cannot use another tenant''s machine');
select throws_ok($$ insert into public.target_override_version (tenant_id, machine_id, product_id, shift_id, effective_from, pieces_per_shift, recorded_by)
  values (pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('py'), pg_temp.id('day'), current_date, 10, pg_temp.id('uax')) $$, '23503', null, 'composite FK: an override cannot use another tenant''s product');
select throws_ok($$ insert into public.target_override_version (tenant_id, machine_id, product_id, shift_id, effective_from, pieces_per_shift, recorded_by)
  values (pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('shifty'), current_date, 10, pg_temp.id('uax')) $$, '23503', null, 'composite FK: an override cannot use another tenant''s shift');
select throws_ok($$ insert into public.target_override_version (tenant_id, machine_id, product_id, shift_id, effective_from, pieces_per_shift, recorded_by)
  values (pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('day'), current_date, 0, pg_temp.id('uax')) $$, '23514', null, 'pieces must be 1 to 1 000 000');

-- Denials (AC-12) ---------------------------------------------------------------------------
create temp table calls (n text, q text);
insert into calls values
  ('set', format($$ select public.sh_set_target_override(gen_random_uuid(), %L, %L, %L, 5, current_date + 60) $$, pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('day'))),
  ('end', format($$ select public.sh_end_target_override(gen_random_uuid(), %L, %L, %L, current_date + 60) $$, pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('day')));
create function pg_temp.run_all() returns int language plpgsql as $$
declare c record; ok int := 0; r jsonb;
begin
  for c in select * from calls loop
    execute c.q into r;
    if r = '{"ok": false, "code": "not_allowed"}'::jsonb then ok := ok + 1; end if;
  end loop;
  return ok;
end $$;
create temp table before_counts as select (select count(*) from public.target_override_version) o, (select count(*) from public.audit_event where action <> 'access.denied') a;
select pg_temp.as_user('supx');
select is(pg_temp.run_all(), 2, 'a supervisor gets the generic denial from both override RPCs');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('supx') and reason = 'role'
           and tenant_id = pg_temp.id('tx') and request_id is null and source like 'rpc:sh_%'), 2, 'each supervisor denial is audited (reason role)');
select pg_temp.as_user('freshx');
select is(pg_temp.run_all(), 2, 'a Unit Admin with a temporary password is denied');
select pg_temp.as_user('uas');
select is(pg_temp.run_all(), 2, 'a Unit Admin of a suspended tenant is denied');
select pg_temp.as_user('inactx');
select is(pg_temp.run_all(), 2, 'an inactive Unit Admin is denied');
select pg_temp.as_user('nomem');
select is(pg_temp.run_all(), 2, 'a caller with no membership is denied');
select results_eq($$ select (select count(*) from public.target_override_version), (select count(*) from public.audit_event where action <> 'access.denied') $$,
  $$ select o, a from before_counts $$, 'denied callers changed nothing');
-- Cross-tenant ids
select pg_temp.as_user('uax');
select is(public.sh_set_target_override(gen_random_uuid(), pg_temp.id('my'), pg_temp.id('p1'), pg_temp.id('day'), 5, (select d + 60 from today)), '{"ok": false, "code": "not_allowed"}'::jsonb, 'another tenant''s machine: generic denial');
select is(public.sh_set_target_override(gen_random_uuid(), pg_temp.id('m1'), pg_temp.id('py'), pg_temp.id('day'), 5, (select d + 60 from today)), '{"ok": false, "code": "not_allowed"}'::jsonb, 'another tenant''s product: generic denial');
select is(public.sh_set_target_override(gen_random_uuid(), pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('shifty'), 5, (select d + 60 from today)), '{"ok": false, "code": "not_allowed"}'::jsonb, 'another tenant''s shift: generic denial');
select is(public.sh_end_target_override(gen_random_uuid(), pg_temp.id('my'), pg_temp.id('py'), pg_temp.id('shifty'), (select d + 60 from today)), '{"ok": false, "code": "not_allowed"}'::jsonb, 'ending with another tenant''s ids: generic denial');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('uax') and reason = 'cross_tenant' and tenant_id = pg_temp.id('tx')), 4, 'cross-tenant denials are audited under the caller''s tenant');
select is(public.sh_set_target_override(gen_random_uuid(), pg_temp.id('m1'), pg_temp.id('p1'), gen_random_uuid(), 5, (select d + 60 from today)), '{"ok": false, "code": "not_allowed"}'::jsonb, 'an unknown shift id: the same generic denial');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('uax') and reason = 'not_found'), 1, 'audited as not_found');
select results_eq($$ select (select count(*) from public.target_override_version), (select count(*) from public.audit_event where action <> 'access.denied') $$,
  $$ select o, a from before_counts $$, 'cross-tenant attempts changed nothing');
select is((pg_temp.set_o('m1', 'p2', 'day', 111, 1))->>'ok', 'true', 'an override on another product, to be ended with a reused request id');
select is((pg_temp.err(format($$ select public.sh_end_target_override(%L, %L, %L, %L, %L) $$, pg_temp.id('rq_o1'), pg_temp.id('m1'), pg_temp.id('p2'), pg_temp.id('day'), (select d + 1 from today))))->>'field', 'request_id', 'the same request id on another RPC is a validation error');

-- Called by the real client role --------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c620-0000000000a1","role":"authenticated"}', true);
select is((pg_temp.set_o('m1', 'p2', 'day', 321, 40))->>'ok', 'true', 'an authenticated Unit Admin can call sh_set_target_override');
select is((select count(*)::int from public.target_override_version where pieces_per_shift = 321), 1, 'and reads the result back under RLS');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c620-0000000000a2","role":"authenticated"}', true);
select is((select count(*)::int from public.target_override_version), 0, 'a supervisor reads no overrides');
reset role;

-- R1: an override never rewrites a started occurrence (set or end); it starts at the first one that hasn't
select pg_temp.as_user('uax');
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time) values
  ('54000000-0000-4000-c620-0000000000a9', pg_temp.id('tx'), '51000000-0000-4000-c620-00000000000a', 'Running now',
   date_trunc('hour', (now() at time zone 'Asia/Kolkata') - interval '1 hour')::time, date_trunc('hour', (now() at time zone 'Asia/Kolkata') + interval '2 hours')::time);
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time) values
  ('54000000-0000-4000-c620-0000000000aa', pg_temp.id('tx'), '51000000-0000-4000-c620-00000000000a', 'Early', '00:00', '00:15');
-- owner-approved 2026-11-19 (test-reliability): the 'runnow' occurrence starts on the plant date of (now - 1 h), not always today; between 00:00 and 01:00 IST that is the previous date. Same assertions.
insert into ids values ('runnow', '54000000-0000-4000-c620-0000000000a9'), ('early', '54000000-0000-4000-c620-0000000000aa');
select is((pg_temp.err(format($$ select public.sh_set_target_override(gen_random_uuid(), %L, %L, %L, 5, %L) $$, pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('runnow'), ((now() at time zone 'Asia/Kolkata') - interval '1 hour')::date)) - 'message'),
  '{"code":"guard","field":"occurrence_started","sqlstate":"P0001"}'::jsonb, 'R1: an override from the date of a running occurrence is refused');
select is((pg_temp.err(format($$ select public.sh_set_target_override(gen_random_uuid(), %L, %L, %L, 5, %L) $$, pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('runnow'), ((now() at time zone 'Asia/Kolkata') - interval '1 hour')::date)))->>'message',
  'This shift has already started — use Cover for this shift', 'R1: the message points to Cover');
select is((public.sh_set_target_override(gen_random_uuid(), pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('runnow'), 5, (select d + 1 from today)))->>'ok', 'true', 'R1: from the next occurrence it is fine');
select is((pg_temp.err(format($$ select public.sh_end_target_override(gen_random_uuid(), %L, %L, %L, %L) $$, pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('runnow'), ((now() at time zone 'Asia/Kolkata') - interval '1 hour')::date)))->>'field',
  'occurrence_started', 'R1: ending from the date of a running occurrence is refused too');
select is((public.sh_end_target_override(gen_random_uuid(), pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('runnow'), (select d + 3 from today)))->>'ok', 'true', 'R1: ending from a later date is fine');
select case when (now() at time zone 'Asia/Kolkata')::time >= time '00:15' then
  is((pg_temp.err(format($$ select public.sh_set_target_override(gen_random_uuid(), %L, %L, %L, 5, %L) $$, pg_temp.id('m1'), pg_temp.id('p1'), pg_temp.id('early'), (select d from today))))->>'field',
     'occurrence_started', 'R1: and for an occurrence that ended today')
  else pass('R1 skipped: the Early shift is still running in the first 15 minutes of the plant day') end;

select * from finish();
rollback;
