-- 04 step 6a R1: pm_end_target means end. Ending at E also cancels every later scheduled non-null change (one null version at E and
-- one at each cancelled date, one audit row listing the cancelled dates). Refused (no_target) only when the pair has no current and
-- no future non-null version. Self-contained; rolled back.
begin;
create extension if not exists pgtap with schema extensions;
select plan(29);

create temp table ids (k text primary key, v uuid);
create function pg_temp.id(k text) returns uuid language sql as $$ select v from ids where k = $1 $$;
create function pg_temp.as_user(k text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where ids.k = $1), 'role', 'authenticated')::text, true) $$;
create function pg_temp.keep(k text, r jsonb) returns jsonb language plpgsql as $$ begin insert into ids values (k, (r->>'id')::uuid); return r; end $$;
create function pg_temp.err(q text) returns jsonb language plpgsql as $f$
declare d text; m text; st text;
begin
  execute q;
  return jsonb_build_object('raised', false);
exception when others then
  get stacked diagnostics d = pg_exception_detail, m = message_text, st = returned_sqlstate;
  return coalesce(case when d ~ '^[{]' then d::jsonb end, '{}'::jsonb) || jsonb_build_object('message', m, 'sqlstate', st);
end $f$;

insert into auth.users (id, email, aud, role) values ('00000000-0000-4000-c500-0000000000a1', 'tap14-a@example.test', 'authenticated', 'authenticated');
insert into ids values ('ua', '00000000-0000-4000-c500-0000000000a1'), ('ta', '50000000-0000-4000-c500-00000000000a');
insert into public.tenant (id, name, status, timezone) values ('50000000-0000-4000-c500-00000000000a', 'tap14 org A', 'active', 'Asia/Kolkata');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('50000000-0000-4000-c500-00000000000a', '00000000-0000-4000-c500-0000000000a1', 'unit_admin', 'active', 'UA A', 'UA-A', '+919000019001', false);

select pg_temp.as_user('ua');
select public.pm_save_site(gen_random_uuid(), 'Plant A', 'Asia/Kolkata');
select pg_temp.keep('p', public.pm_save_product(gen_random_uuid(), null, 'E-P', 'Cap', 'pcs'));
select pg_temp.keep('m1', public.pm_save_machine(gen_random_uuid(), null, 'E-1', 'One', null, null, null, null, null, 'active'));
select pg_temp.keep('m2', public.pm_save_machine(gen_random_uuid(), null, 'E-2', 'Two', null, null, null, null, null, 'active'));
select pg_temp.keep('m3', public.pm_save_machine(gen_random_uuid(), null, 'E-3', 'Three', null, null, null, null, null, 'active'));
select pg_temp.keep('m4', public.pm_save_machine(gen_random_uuid(), null, 'E-4', 'Four', null, null, null, null, null, 'active'));
select pg_temp.keep('m5', public.pm_save_machine(gen_random_uuid(), null, 'E-5', 'Five', null, null, null, null, null, 'active'));
select pg_temp.keep('m6', public.pm_save_machine(gen_random_uuid(), null, 'E-6', 'Six', null, null, null, null, null, 'active'));
create temp table today as select app.plant_date(pg_temp.id('ta')) as d;
create function pg_temp.tf(m text, off int) returns integer language sql as $$ select app.target_for(pg_temp.id($1), pg_temp.id('p'), (select d + $2 from today)) $$;
create function pg_temp.set_t(m text, pieces int, off int) returns jsonb language sql as
  $$ select public.pm_set_target(gen_random_uuid(), pg_temp.id($1), pg_temp.id('p'), $2, (select d + $3 from today)) $$;
create function pg_temp.end_t(m text, off int) returns jsonb language sql as
  $$ select public.pm_end_target(gen_random_uuid(), pg_temp.id($1), pg_temp.id('p'), (select d + $2 from today)) $$;
create function pg_temp.nver(m text) returns int language sql as $$ select count(*)::int from public.target_version where machine_id = pg_temp.id($1) $$;
select pg_temp.set_t('m1', 1000, 0), pg_temp.set_t('m1', 1300, 10);
select pg_temp.set_t('m2', 500, 3);
select pg_temp.set_t('m4', 100, 0);
select pg_temp.set_t('m5', 100, 0), pg_temp.set_t('m5', 200, 4), pg_temp.set_t('m5', 300, 8);
select pg_temp.set_t('m6', 100, 0), pg_temp.set_t('m6', 200, 6);

-- A. end today with a change scheduled later: the later change is cancelled too
create temp table a1 as select pg_temp.end_t('m1', 0) as r;
select is((select r->>'ok' from a1), 'true', 'A: end today succeeds');
select is(pg_temp.tf('m1', 0), null, 'A: no target today');
select is(pg_temp.tf('m1', 9), null, 'A: none the day before the scheduled change');
select is(pg_temp.tf('m1', 10), null, 'A: the scheduled change is cancelled (no target on its date)');
select is(pg_temp.tf('m1', 60), null, 'A: and none afterwards');
select is(pg_temp.nver('m1'), 4, 'A: two original versions + a null at the end date + a null at the cancelled date');
select is((select count(*)::int from public.audit_event where action = 'target.ended' and entity_id = (select (r->>'id')::uuid from a1)), 1, 'A: exactly one target.ended audit row');
select is((select after->'cancelled_dates' from public.audit_event where action = 'target.ended' and entity_id = (select (r->>'id')::uuid from a1)),
  to_jsonb(array[(select (d + 10)::text from today)]), 'A: the audit row lists the cancelled date');
select is((select r->'cancelled' from a1), to_jsonb(array[(select (d + 10)::text from today)]), 'A: the response lists the cancelled date');

-- B. only a future target exists: ending today is allowed and cancels it
select is((pg_temp.end_t('m2', 0))->>'ok', 'true', 'B: ending when only a future target exists is allowed');
select is(pg_temp.tf('m2', 3), null, 'B: the future target is cancelled');
select is(pg_temp.nver('m2'), 3, 'B: the original + null at the end date + null at the cancelled date');

-- C. re-set after an end works
select is((pg_temp.set_t('m2', 700, 5))->>'ok', 'true', 'C: a new target can be set after the end');
select is(pg_temp.tf('m2', 4), null, 'C: still none before the new start');
select is(pg_temp.tf('m2', 5), 700, 'C: the new target applies from its start');

-- D. nothing to end
select is((pg_temp.err(format($$ select public.pm_end_target(gen_random_uuid(), %L, %L, %L) $$, pg_temp.id('m3'), pg_temp.id('p'), (select d from today))) )->>'field', 'no_target', 'D: a pair that was never set is refused (no_target)');
select is((pg_temp.end_t('m4', 0))->>'ok', 'true', 'D: a current target can be ended');
select is((pg_temp.err(format($$ select public.pm_end_target(gen_random_uuid(), %L, %L, %L) $$, pg_temp.id('m4'), pg_temp.id('p'), (select d from today))) )->>'field', 'no_target', 'D: ending again with nothing current or scheduled is refused');
select is(pg_temp.nver('m4'), 2, 'D: the refused call wrote nothing');

-- E. several scheduled changes after the end date
create temp table e1 as select pg_temp.end_t('m5', 2) as r;
select is(pg_temp.tf('m5', 1), 100, 'E: the target still applies the day before the end');
select is(pg_temp.tf('m5', 2), null, 'E: none from the end date');
select is(pg_temp.tf('m5', 4), null, 'E: the first later change is cancelled');
select is(pg_temp.tf('m5', 8), null, 'E: the second later change is cancelled');
select is((select r->'cancelled' from e1), to_jsonb(array[(select (d + 4)::text from today), (select (d + 8)::text from today)]), 'E: both cancelled dates are listed in order');
select is(pg_temp.nver('m5'), 6, 'E: three originals + the end + two cancellations');

-- F. a scheduled end is not "cancelled" again; only later non-null changes are
select pg_temp.end_t('m6', 3);
select pg_temp.set_t('m6', 250, 7);
create temp table f1 as select pg_temp.end_t('m6', 1) as r;
select is((select r->'cancelled' from f1), to_jsonb(array[(select (d + 7)::text from today)]), 'F: only the later non-null change is cancelled (the earlier scheduled end stays as it is)');

-- G. replay
create temp table g_rid as select gen_random_uuid() as v;
select pg_temp.set_t('m3', 900, 0);
select is((select (public.pm_end_target((select v from g_rid), pg_temp.id('m3'), pg_temp.id('p'), (select d from today)))->>'ok'), 'true', 'G: end with a request id');
select is((select (public.pm_end_target((select v from g_rid), pg_temp.id('m3'), pg_temp.id('p'), (select d from today)))->>'already'), 'true', 'G: the same request id is a replay');
select is(pg_temp.nver('m3'), 2, 'G: the replay wrote nothing');

select * from finish();
rollback;
