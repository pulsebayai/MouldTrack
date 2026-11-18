-- 06 AC-3..AC-8, AC-15 (DB part), D2, D5, D6: rd_opening / rd_closing / rd_correct. Windows (30 minutes before the start .. the end for an opening, the
-- opening .. 12 h after the end for a closing, a long shift for the correction window), the Late flag at the 30-minute boundary, one current reading per
-- kind, corrections (supervisor window, Unit Admin any time, the earliest submission's Late flag), who may record (owner, cover, Unit Admin, other
-- supervisor, unassigned, inactive, temporary password, suspended tenant, Super Admin), idempotency, isolation, audit.
-- Self-contained; rolled back. Every case builds its own shift relative to now() (D12: the write RPCs use now(); no clock override) on the 15-minute grid
-- shift times live on, so the tests do not depend on the time of day.
begin;
create extension if not exists pgtap with schema extensions;
select plan(151);

create temp table ids (k text primary key, v uuid);
create temp table dates (k text primary key, d date);
create function pg_temp.id(k text) returns uuid language sql as $$ select v from ids where k = $1 $$;
create function pg_temp.d(k text) returns date language sql as $$ select d from dates where k = $1 $$;
create function pg_temp.rq(n int) returns uuid language sql as $$ select ('a1000000-0000-4000-c651-' || lpad(n::text, 12, '0'))::uuid $$;
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
create function pg_temp.n_audit(a text) returns int language sql as $$
  select count(*)::int from public.audit_event where action = a and tenant_id = pg_temp.id('tx') $$;
create function pg_temp.n_denied(src text, why text) returns int language sql as $$
  select count(*)::int from public.audit_event where action = 'access.denied' and source = src and reason = why $$;
create function pg_temp.f15(ts timestamptz) returns timestamptz language sql immutable as $$ select to_timestamp(floor(extract(epoch from ts) / 900) * 900) $$;
-- A machine + a shift starting off_min minutes from the current 15-minute mark and lasting `hours`, owned by sup (null = unassigned).
create function pg_temp.mk(k text, off_min int, hours int, sup text, ret boolean default false) returns void language plpgsql as $$
declare
  v_start timestamptz := pg_temp.f15(now()) + make_interval(mins => off_min);
  v_m uuid := gen_random_uuid();
  v_s uuid := gen_random_uuid();
begin
  insert into public.machine (id, tenant_id, site_id, code, name, retired_at)
  values (v_m, pg_temp.id('tx'), '51000000-0000-4000-c651-00000000000a', 'C-' || k, 'Case ' || k, case when ret then now() end);
  insert into public.shift (id, tenant_id, site_id, name, start_time, end_time)
  values (v_s, pg_temp.id('tx'), '51000000-0000-4000-c651-00000000000a', 'S-' || k, (v_start at time zone 'Asia/Kolkata')::time,
          ((v_start + make_interval(hours => hours)) at time zone 'Asia/Kolkata')::time);
  insert into ids values ('m_' || k, v_m), ('sh_' || k, v_s);
  insert into dates values (k, (v_start at time zone 'Asia/Kolkata')::date);
  if sup is not null then
    insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by)
    values (pg_temp.id('tx'), v_s, v_m, pg_temp.id(sup), date '2026-01-01', pg_temp.id('uax'));
  end if;
end $$;
-- Readings inserted as the owner (fixtures: they bypass the windows so a case can start from any state).
create function pg_temp.put_open(k text, counter bigint, by text default 's1', late boolean default false, dd date default null, prod text default 'p1') returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into public.production_reading (id, tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, late, recorded_by)
  values (v, pg_temp.id('tx'), pg_temp.id('m_' || k), pg_temp.id('sh_' || k), coalesce(dd, pg_temp.d(k)), 'opening', pg_temp.id(prod), counter, late, pg_temp.id(by));
  return v;
end $$;
create function pg_temp.put_close(k text, counter bigint, good int, reject int, by text default 's1', late boolean default false, dd date default null) returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into public.production_reading (id, tenant_id, machine_id, shift_id, shift_date, kind, counter_value, good, reject, late, recorded_by)
  values (v, pg_temp.id('tx'), pg_temp.id('m_' || k), pg_temp.id('sh_' || k), coalesce(dd, pg_temp.d(k)), 'closing', counter, good, reject, late, pg_temp.id(by));
  return v;
end $$;
create function pg_temp.n_summ(k text) returns int language sql as $$
  select count(*)::int from public.production_summary where machine_id = pg_temp.id('m_' || k) and shift_date = pg_temp.d(k) $$;

-- Fixtures (as postgres) ---------------------------------------------------
insert into auth.users (id, email, aud, role)
select u, 'tap51-' || n || '@example.test', 'authenticated', 'authenticated' from (values
  ('00000000-0000-4000-c651-0000000000a1'::uuid, 'uax'), ('00000000-0000-4000-c651-0000000000a2', 's1'), ('00000000-0000-4000-c651-0000000000a3', 's2'),
  ('00000000-0000-4000-c651-0000000000a4', 'sinact'), ('00000000-0000-4000-c651-0000000000a5', 'sfresh'), ('00000000-0000-4000-c651-0000000000b1', 'uay'),
  ('00000000-0000-4000-c651-0000000000b2', 'sy'), ('00000000-0000-4000-c651-0000000000d1', 'uas'), ('00000000-0000-4000-c651-0000000000c1', 'nomem'),
  ('00000000-0000-4000-c651-0000000000f1', 'sa')) t(u, n);
insert into ids values ('uax', '00000000-0000-4000-c651-0000000000a1'), ('s1', '00000000-0000-4000-c651-0000000000a2'), ('s2', '00000000-0000-4000-c651-0000000000a3'),
  ('sinact', '00000000-0000-4000-c651-0000000000a4'), ('sfresh', '00000000-0000-4000-c651-0000000000a5'), ('uay', '00000000-0000-4000-c651-0000000000b1'),
  ('sy', '00000000-0000-4000-c651-0000000000b2'), ('uas', '00000000-0000-4000-c651-0000000000d1'), ('nomem', '00000000-0000-4000-c651-0000000000c1'),
  ('sa', '00000000-0000-4000-c651-0000000000f1'),
  ('tx', '50000000-0000-4000-c651-00000000000a'), ('ty', '50000000-0000-4000-c651-00000000000b'), ('ts', '50000000-0000-4000-c651-00000000000d');
insert into public.tenant (id, name, status, timezone) values
  ('50000000-0000-4000-c651-00000000000a', 'tap51 org X', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c651-00000000000b', 'tap51 org Y', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c651-00000000000d', 'tap51 org S', 'suspended', 'Asia/Kolkata');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('50000000-0000-4000-c651-00000000000a', '00000000-0000-4000-c651-0000000000a1', 'unit_admin', 'active', 'UA X', 'UA-X', '+919000026101', false),
  ('50000000-0000-4000-c651-00000000000a', '00000000-0000-4000-c651-0000000000a2', 'supervisor', 'active', 'Sup One', 'S1', '+919000026102', false),
  ('50000000-0000-4000-c651-00000000000a', '00000000-0000-4000-c651-0000000000a3', 'supervisor', 'active', 'Sup Two', 'S2', '+919000026103', false),
  ('50000000-0000-4000-c651-00000000000a', '00000000-0000-4000-c651-0000000000a4', 'supervisor', 'inactive', 'Sup Gone', 'S3', '+919000026104', false),
  ('50000000-0000-4000-c651-00000000000a', '00000000-0000-4000-c651-0000000000a5', 'supervisor', 'active', 'Sup Fresh', 'S4', '+919000026105', true),
  ('50000000-0000-4000-c651-00000000000b', '00000000-0000-4000-c651-0000000000b1', 'unit_admin', 'active', 'UA Y', 'UA-Y', '+919000026106', false),
  ('50000000-0000-4000-c651-00000000000b', '00000000-0000-4000-c651-0000000000b2', 'supervisor', 'active', 'Sup Y', 'SY', '+919000026107', false),
  ('50000000-0000-4000-c651-00000000000d', '00000000-0000-4000-c651-0000000000d1', 'unit_admin', 'active', 'UA S', 'UA-S', '+919000026108', false);
insert into public.platform_admin (user_id, full_name, phone_e164, status, must_change_password) values
  ('00000000-0000-4000-c651-0000000000f1', 'SA 51', '+919000026109', 'active', false);
insert into public.site (id, tenant_id, name, timezone) values
  ('51000000-0000-4000-c651-00000000000a', pg_temp.id('tx'), 'Plant X', 'Asia/Kolkata'),
  ('51000000-0000-4000-c651-00000000000b', pg_temp.id('ty'), 'Plant Y', 'Asia/Kolkata');
insert into public.product (id, tenant_id, code, description, retired_at) values
  ('54000000-0000-4000-c651-0000000000a1', pg_temp.id('tx'), 'P-1', 'Part 1', null),
  ('54000000-0000-4000-c651-0000000000a2', pg_temp.id('tx'), 'P-2', 'Part 2', null),
  ('54000000-0000-4000-c651-0000000000a3', pg_temp.id('tx'), 'P-3', 'Retired part', now()),
  ('54000000-0000-4000-c651-0000000000b1', pg_temp.id('ty'), 'Y-P', 'Y part', null);
insert into ids values ('p1', '54000000-0000-4000-c651-0000000000a1'), ('p2', '54000000-0000-4000-c651-0000000000a2'), ('pret', '54000000-0000-4000-c651-0000000000a3'),
  ('py', '54000000-0000-4000-c651-0000000000b1');
grant select on ids, dates to authenticated, anon;

select pg_temp.mk('run', 0, 8, 's1');
select pg_temp.mk('late', -45, 8, 's1');
select pg_temp.mk('pre', 15, 8, 's1');
select pg_temp.mk('early', 45, 8, 's1');
select pg_temp.mk('ended', -180, 2, 's1');
select pg_temp.mk('ontime', -120, 2, 's1');
select pg_temp.mk('expired', -900, 2, 's1');
select pg_temp.mk('noopen', 0, 8, 's1');
select pg_temp.mk('unasg', 0, 8, null);
select pg_temp.mk('cover', 0, 8, 's1');
select pg_temp.mk('uncov', 0, 8, 's1');
select pg_temp.mk('ret', 0, 8, 's1', true);
select pg_temp.mk('val', 0, 8, 's1');
select pg_temp.mk('corr', -180, 8, 's1');
select pg_temp.mk('long', -60, 20, 's1');
select pg_temp.mk('oth', 0, 8, 's1');
select pg_temp.mk('lateopen', -180, 2, 's1');
select pg_temp.mk('lateopen2', -180, 2, 's1');
select pg_temp.mk('nearend', -450, 8, 's1');
select pg_temp.mk('retc', -30, 8, 's1', true);
select pg_temp.mk('retsh', -30, 8, 's1');
select pg_temp.mk('retcorr', -30, 8, 's1');
insert into public.assignment_cover (tenant_id, shift_id, shift_date, machine_id, supervisor_id, reason, recorded_by) values
  (pg_temp.id('tx'), pg_temp.id('sh_cover'), pg_temp.d('cover'), pg_temp.id('m_cover'), pg_temp.id('s2'), 'sick', pg_temp.id('uax')),
  (pg_temp.id('tx'), pg_temp.id('sh_uncov'), pg_temp.d('uncov'), pg_temp.id('m_uncov'), null, 'nobody', pg_temp.id('uax'));
insert into public.machine (id, tenant_id, site_id, code, name) values ('53000000-0000-4000-c651-0000000000b1', pg_temp.id('ty'), '51000000-0000-4000-c651-00000000000b', 'Y-1', 'Y press');
insert into ids values ('my', '53000000-0000-4000-c651-0000000000b1');

-- The Late boundary (D5): strictly more than 30 minutes after the boundary -------------------------------------------------------------------------------
select is(app._rd_is_late(timestamptz '2026-03-02 06:00+05:30', timestamptz '2026-03-02 06:30:00+05:30'), false, 'exactly 30 minutes after the boundary is not late');
select is(app._rd_is_late(timestamptz '2026-03-02 06:00+05:30', timestamptz '2026-03-02 06:30:01+05:30'), true, 'one second more is late');
select is(app._rd_is_late(timestamptz '2026-03-02 06:00+05:30', timestamptz '2026-03-02 06:29:59+05:30'), false, 'one second less is not');
select is(app._rd_is_late(timestamptz '2026-03-02 06:00+05:30', timestamptz '2026-03-02 05:00+05:30'), false, 'before the boundary is not late');

-- Opening (AC-3, AC-5, D5) --------------------------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('s1');
select is(pg_temp.keep('o_run', public.rd_opening(pg_temp.rq(1), pg_temp.id('m_run'), pg_temp.id('sh_run'), pg_temp.d('run'), pg_temp.id('p1'), 1000, '  first  ')) ->> 'ok', 'true', 'the owner records the opening of a running occurrence');
select results_eq($$ select kind, product_id, counter_value, remarks, late, entered_by_ua, recorded_by, supersedes_id, good, reject from public.production_reading where id = pg_temp.id('o_run') $$,
  $$ values ('opening'::text, pg_temp.id('p1'), 1000::bigint, 'first'::text, false, false, pg_temp.id('s1'), null::uuid, null::int, null::int) $$, 'it is stored (trimmed remarks, on time, not entered by a Unit Admin)');
select is(pg_temp.n_audit('reading.opening'), 1, 'one reading.opening audit row');
select results_eq($$ select after ->> 'machine_code', (after ->> 'counter')::int, (after ->> 'late')::boolean from public.audit_event where action = 'reading.opening' and entity_id = pg_temp.id('o_run') $$,
  $$ values ('C-run'::text, 1000, false) $$, 'with the machine code, counter and late flag');
select is(public.rd_opening(pg_temp.rq(1), pg_temp.id('m_run'), pg_temp.id('sh_run'), pg_temp.d('run'), pg_temp.id('p1'), 1000, 'first') ->> 'already', 'true', 'a replay returns the first outcome');
select is((select count(*)::int from public.production_reading where machine_id = pg_temp.id('m_run')), 1, 'and records nothing more');
select is(pg_temp.err($$ select public.rd_opening(pg_temp.rq(2), pg_temp.id('m_run'), pg_temp.id('sh_run'), pg_temp.d('run'), pg_temp.id('p2'), 5) $$) ->> 'field', 'already_recorded', 'a second opening for the occurrence is refused (use a correction)');
select is(pg_temp.err($$ select public.rd_closing(pg_temp.rq(1), pg_temp.id('m_run'), pg_temp.id('sh_run'), pg_temp.d('run'), 1100, 90, 5) $$) ->> 'field', 'request_id', 'a request id used by another RPC is a validation error');
select is((select count(*)::int from public.production_reading where machine_id = pg_temp.id('m_run') and kind = 'closing'), 0, 'and nothing was recorded by it');

select is(public.rd_opening(pg_temp.rq(3), pg_temp.id('m_late'), pg_temp.id('sh_late'), pg_temp.d('late'), pg_temp.id('p1'), 10) ->> 'late', 'true', 'an opening more than 30 minutes after the shift start is accepted and flagged Late');
select is((select late from public.production_reading where machine_id = pg_temp.id('m_late')), true, 'the flag is stored with the reading');
select is(public.rd_opening(pg_temp.rq(4), pg_temp.id('m_pre'), pg_temp.id('sh_pre'), pg_temp.d('pre'), pg_temp.id('p1'), 1000000000000) ->> 'late', 'false', 'an opening up to 30 minutes before the start is allowed (and not late); the counter may be 10^12');
select is(pg_temp.err($$ select public.rd_opening(pg_temp.rq(5), pg_temp.id('m_early'), pg_temp.id('sh_early'), pg_temp.d('early'), pg_temp.id('p1'), 1) $$) ->> 'field', 'window_not_open', 'earlier than that it is refused');
select is(pg_temp.err($$ select public.rd_opening(pg_temp.rq(6), pg_temp.id('m_expired'), pg_temp.id('sh_expired'), pg_temp.d('expired'), pg_temp.id('p1'), 1) $$) ->> 'field', 'window_closed', 'more than 12 hours after the occurrence ended an opening is refused (R4)');
select pg_temp.as_user('uax');
select is(pg_temp.err($$ select public.rd_opening(pg_temp.rq(7), pg_temp.id('m_expired'), pg_temp.id('sh_expired'), pg_temp.d('expired'), pg_temp.id('p1'), 1) $$) ->> 'field', 'window_closed', 'also for a Unit Admin');
select is(pg_temp.err($$ select public.rd_opening(pg_temp.rq(8), pg_temp.id('m_early'), pg_temp.id('sh_early'), pg_temp.d('early'), pg_temp.id('p1'), 1) $$) ->> 'field', 'window_not_open', 'and too early');

-- Validation -------------------------------------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('s1');
select is(pg_temp.err($$ select public.rd_opening(pg_temp.rq(10), pg_temp.id('m_val'), pg_temp.id('sh_val'), pg_temp.d('val'), pg_temp.id('p1'), -1) $$) ->> 'field', 'counter', 'a negative counter is refused');
select is(pg_temp.err($$ select public.rd_opening(pg_temp.rq(10), pg_temp.id('m_val'), pg_temp.id('sh_val'), pg_temp.d('val'), pg_temp.id('p1'), null) $$) ->> 'field', 'counter', 'a missing counter too');
select is(pg_temp.err($$ select public.rd_opening(pg_temp.rq(10), pg_temp.id('m_val'), pg_temp.id('sh_val'), pg_temp.d('val'), pg_temp.id('p1'), 1000000000001) $$) ->> 'field', 'counter', 'and one above 10^12');
select is(pg_temp.err($$ select public.rd_opening(pg_temp.rq(10), pg_temp.id('m_val'), pg_temp.id('sh_val'), pg_temp.d('val'), pg_temp.id('p1'), 1, repeat('x', 501)) $$) ->> 'field', 'remarks', 'remarks are capped at 500 characters');
select is(pg_temp.err($$ select public.rd_opening(pg_temp.rq(10), pg_temp.id('m_val'), pg_temp.id('sh_val'), null, pg_temp.id('p1'), 1) $$) ->> 'field', 'shift_date', 'the shift date is required');
select is(pg_temp.err($$ select public.rd_opening(null, pg_temp.id('m_val'), pg_temp.id('sh_val'), pg_temp.d('val'), pg_temp.id('p1'), 1) $$) ->> 'field', 'request_id', 'and a request id');
select is(pg_temp.err($$ select public.rd_opening(pg_temp.rq(10), pg_temp.id('m_val'), pg_temp.id('sh_val'), pg_temp.d('val'), pg_temp.id('pret'), 1) $$) ->> 'field', 'product_id', 'a retired product is refused');
select is(pg_temp.err($$ select public.rd_opening(pg_temp.rq(10), pg_temp.id('m_ret'), pg_temp.id('sh_ret'), pg_temp.d('ret'), pg_temp.id('p1'), 1) $$) ->> 'field', 'machine_retired', 'a retired machine is refused');
select is((select count(*)::int from public.production_reading where machine_id in (pg_temp.id('m_val'), pg_temp.id('m_ret'))), 0, 'none of the refused calls recorded anything');

-- Who (AC-7, AC-8) ----------------------------------------------------------------------------------------------------------------------------------------
select is(public.rd_opening(pg_temp.rq(20), pg_temp.id('m_unasg'), pg_temp.id('sh_unasg'), pg_temp.d('unasg'), pg_temp.id('p1'), 5), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a supervisor cannot record for an unassigned machine');
select is(public.rd_opening(pg_temp.rq(21), pg_temp.id('m_uncov'), pg_temp.id('sh_uncov'), pg_temp.d('uncov'), pg_temp.id('p1'), 5), '{"ok": false, "code": "not_allowed"}'::jsonb, 'nor once the occurrence''s cover names nobody');
select pg_temp.as_user('s2');
select is(public.rd_opening(pg_temp.rq(22), pg_temp.id('m_oth'), pg_temp.id('sh_oth'), pg_temp.d('oth'), pg_temp.id('p1'), 5), '{"ok": false, "code": "not_allowed"}'::jsonb, 'another supervisor cannot record for a machine they do not own');
select is(pg_temp.keep('o_cover', public.rd_opening(pg_temp.rq(23), pg_temp.id('m_cover'), pg_temp.id('sh_cover'), pg_temp.d('cover'), pg_temp.id('p1'), 77)) ->> 'ok', 'true', 'the supervisor named by the occurrence''s cover can');
select pg_temp.as_user('s1');
select is(public.rd_opening(pg_temp.rq(24), pg_temp.id('m_cover'), pg_temp.id('sh_cover'), pg_temp.d('cover'), pg_temp.id('p1'), 5), '{"ok": false, "code": "not_allowed"}'::jsonb, 'and the planned owner, replaced by the cover, cannot');
select is(pg_temp.n_denied('rpc:rd_opening', 'not_owner'), 4, 'each of those four is audited as not_owner');
select pg_temp.as_user('uax');
select is(pg_temp.keep('o_unasg', public.rd_opening(pg_temp.rq(25), pg_temp.id('m_unasg'), pg_temp.id('sh_unasg'), pg_temp.d('unasg'), pg_temp.id('p1'), 5, 'for the supervisor')) ->> 'entered_by_ua', 'true', 'a Unit Admin can record for an unassigned machine, labelled Entered by Unit Admin');
select results_eq($$ select entered_by_ua, recorded_by, late from public.production_reading where id = pg_temp.id('o_unasg') $$, $$ values (true, pg_temp.id('uax'), false) $$, 'the label and the recorder are stored');
select is(public.rd_opening(pg_temp.rq(26), pg_temp.id('m_oth'), pg_temp.id('sh_oth'), pg_temp.d('oth'), pg_temp.id('p1'), 9) ->> 'entered_by_ua', 'true', 'a Unit Admin can record on behalf of an assigned supervisor too');
select pg_temp.as_user('sinact');
select is(public.rd_opening(pg_temp.rq(27), pg_temp.id('m_val'), pg_temp.id('sh_val'), pg_temp.d('val'), pg_temp.id('p1'), 5), '{"ok": false, "code": "not_allowed"}'::jsonb, 'an inactive user is denied');
select pg_temp.as_user('sfresh');
select is(public.rd_opening(pg_temp.rq(28), pg_temp.id('m_val'), pg_temp.id('sh_val'), pg_temp.d('val'), pg_temp.id('p1'), 5), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a user with a temporary password is denied');
select pg_temp.as_user('uas');
select is(public.rd_opening(pg_temp.rq(29), pg_temp.id('m_val'), pg_temp.id('sh_val'), pg_temp.d('val'), pg_temp.id('p1'), 5), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a user of a suspended tenant is denied');
select pg_temp.as_user('nomem');
select is(public.rd_opening(pg_temp.rq(30), pg_temp.id('m_val'), pg_temp.id('sh_val'), pg_temp.d('val'), pg_temp.id('p1'), 5), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a user without membership is denied');
select pg_temp.as_user('sa');
select is(public.rd_opening(pg_temp.rq(31), pg_temp.id('m_val'), pg_temp.id('sh_val'), pg_temp.d('val'), pg_temp.id('p1'), 5), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a Super Admin is denied');
select pg_temp.as_user('sy');
select is(public.rd_opening(pg_temp.rq(32), pg_temp.id('m_val'), pg_temp.id('sh_val'), pg_temp.d('val'), pg_temp.id('p1'), 5), '{"ok": false, "code": "not_allowed"}'::jsonb, 'another tenant''s supervisor is denied (cross tenant machine)');
select pg_temp.as_user('uay');
select is(public.rd_opening(pg_temp.rq(33), pg_temp.id('m_val'), pg_temp.id('sh_val'), pg_temp.d('val'), pg_temp.id('p1'), 5), '{"ok": false, "code": "not_allowed"}'::jsonb, 'and another tenant''s Unit Admin');
select is(public.rd_opening(pg_temp.rq(34), gen_random_uuid(), pg_temp.id('sh_val'), pg_temp.d('val'), pg_temp.id('p1'), 5), '{"ok": false, "code": "not_allowed"}'::jsonb, 'an unknown machine looks the same');
select pg_temp.as_user('uax');
select is(public.rd_opening(pg_temp.rq(35), pg_temp.id('m_val'), pg_temp.id('sh_val'), pg_temp.d('val'), pg_temp.id('py'), 5), '{"ok": false, "code": "not_allowed"}'::jsonb, 'another tenant''s product is denied');
select is(public.rd_opening(pg_temp.rq(36), pg_temp.id('my'), pg_temp.id('sh_val'), pg_temp.d('val'), pg_temp.id('p1'), 5), '{"ok": false, "code": "not_allowed"}'::jsonb, 'and another tenant''s machine, for a Unit Admin');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and source = 'rpc:rd_opening' and reason in ('inactive', 'must_change_password', 'no_membership', 'platform_admin', 'cross_tenant', 'not_found')), 10,
  'the other denials are audited with their reason (inactive x2, temporary password, no membership, Super Admin, cross tenant x4, unknown)');
select is((select count(*)::int from public.production_reading where machine_id in (pg_temp.id('m_val'), pg_temp.id('m_ret'))), 0, 'no denied call recorded anything');

-- Closing (AC-4, AC-5, D5) ---------------------------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('s1');
select is(pg_temp.err($$ select public.rd_closing(pg_temp.rq(40), pg_temp.id('m_noopen'), pg_temp.id('sh_noopen'), pg_temp.d('noopen'), 5, 1, 1) $$) ->> 'field', 'no_opening', 'a closing needs an opening first');
select is(pg_temp.keep('c_run', public.rd_closing(pg_temp.rq(41), pg_temp.id('m_run'), pg_temp.id('sh_run'), pg_temp.d('run'), 1250, 240, 5, 'done')) ->> 'ok', 'true', 'the owner records the closing (allowed from the opening on, before the shift ends)');
select results_eq($$ select kind, product_id, counter_value, good, reject, remarks, late, entered_by_ua, recorded_by from public.production_reading where id = pg_temp.id('c_run') $$,
  $$ values ('closing'::text, null::uuid, 1250::bigint, 240, 5, 'done'::text, false, false, pg_temp.id('s1')) $$, 'it is stored');
select is(pg_temp.n_audit('reading.closing'), 1, 'one reading.closing audit row');
select is(pg_temp.n_summ('run'), 1, 'the closing appended one production summary');
select results_eq($$ select calc_version, product_id, counter_unit, cavities, opening_counter, closing_counter, movement_units, movement_pieces, unaccounted, target, attainment_pct, rollover, needs_review, over_reported, late_opening, late_closing, entered_by_ua
                      from public.production_summary where machine_id = pg_temp.id('m_run') $$,
  $$ values (1, pg_temp.id('p1'), 'pieces'::text, 1, 1000::bigint, 1250::bigint, 250::bigint, 250::bigint, 5::bigint, null::int, null::numeric, false, false, false, false, false, false) $$, 'with the movement, unaccounted pieces and no target');
select is(public.rd_closing(pg_temp.rq(41), pg_temp.id('m_run'), pg_temp.id('sh_run'), pg_temp.d('run'), 1250, 240, 5, 'done') ->> 'already', 'true', 'a replay returns the first outcome');
select is(pg_temp.n_summ('run'), 1, 'and appends no second summary');
select is(pg_temp.err($$ select public.rd_closing(pg_temp.rq(42), pg_temp.id('m_run'), pg_temp.id('sh_run'), pg_temp.d('run'), 1300, 1, 1) $$) ->> 'field', 'already_recorded', 'a second closing is refused (use a correction)');

select pg_temp.put_open('ended', 100);
select is(public.rd_closing(pg_temp.rq(43), pg_temp.id('m_ended'), pg_temp.id('sh_ended'), pg_temp.d('ended'), 200, 90, 5) ->> 'late', 'true', 'a closing more than 30 minutes after the shift end is accepted and flagged Late');
select results_eq($$ select late_opening, late_closing from public.production_summary where machine_id = pg_temp.id('m_ended') $$, $$ values (false, true) $$, 'the summary carries both flags');
select pg_temp.put_open('ontime', 100);
select is(public.rd_closing(pg_temp.rq(44), pg_temp.id('m_ontime'), pg_temp.id('sh_ontime'), pg_temp.d('ontime'), 200, 90, 5) ->> 'late', 'false', 'a closing right at the shift end is on time');
select pg_temp.put_open('expired', 100);
select is(pg_temp.err($$ select public.rd_closing(pg_temp.rq(45), pg_temp.id('m_expired'), pg_temp.id('sh_expired'), pg_temp.d('expired'), 200, 90, 5) $$) ->> 'field', 'window_closed', 'a closing more than 12 hours after the shift end is refused');
select pg_temp.as_user('uax');
select is(pg_temp.err($$ select public.rd_closing(pg_temp.rq(46), pg_temp.id('m_expired'), pg_temp.id('sh_expired'), pg_temp.d('expired'), 200, 90, 5) $$) ->> 'field', 'window_closed', 'also for a Unit Admin');
select pg_temp.as_user('s1');
select pg_temp.put_open('val', 10);
select is(pg_temp.err($$ select public.rd_closing(pg_temp.rq(47), pg_temp.id('m_val'), pg_temp.id('sh_val'), pg_temp.d('val'), 20, -1, 1) $$) ->> 'field', 'good', 'a negative good quantity is refused');
select is(pg_temp.err($$ select public.rd_closing(pg_temp.rq(47), pg_temp.id('m_val'), pg_temp.id('sh_val'), pg_temp.d('val'), 20, 1, null) $$) ->> 'field', 'reject', 'a missing reject quantity too');
select is(pg_temp.err($$ select public.rd_closing(pg_temp.rq(47), pg_temp.id('m_val'), pg_temp.id('sh_val'), pg_temp.d('val'), null, 1, 1) $$) ->> 'field', 'counter', 'a missing counter');
select is(pg_temp.err($$ select public.rd_closing(pg_temp.rq(47), pg_temp.id('m_val'), pg_temp.id('sh_val'), pg_temp.d('val'), 20, 10000001, 1) $$) ->> 'field', 'good', 'good is capped at 10,000,000');
select is(pg_temp.err($$ select public.rd_closing(pg_temp.rq(47), pg_temp.id('m_val'), pg_temp.id('sh_val'), pg_temp.d('val'), 20, 1, 1, repeat('x', 501)) $$) ->> 'field', 'remarks', 'remarks are capped at 500 characters');
select pg_temp.as_user('s2');
select is(public.rd_closing(pg_temp.rq(48), pg_temp.id('m_val'), pg_temp.id('sh_val'), pg_temp.d('val'), 20, 1, 1), '{"ok": false, "code": "not_allowed"}'::jsonb, 'another supervisor cannot close');
select pg_temp.as_user('s1');
select is(public.rd_closing(pg_temp.rq(49), pg_temp.id('m_cover'), pg_temp.id('sh_cover'), pg_temp.d('cover'), 90, 1, 1), '{"ok": false, "code": "not_allowed"}'::jsonb, 'the replaced owner cannot close');
select is(pg_temp.n_denied('rpc:rd_closing', 'not_owner'), 2, 'both are audited as not_owner');
select is((select count(*)::int from public.production_reading where machine_id = pg_temp.id('m_val') and kind = 'closing'), 0, 'no refused closing recorded anything');
select pg_temp.as_user('s2');
select is(pg_temp.keep('c_cover', public.rd_closing(pg_temp.rq(50), pg_temp.id('m_cover'), pg_temp.id('sh_cover'), pg_temp.d('cover'), 90, 7, 1)) ->> 'ok', 'true', 'the covering supervisor can close what they opened');
select pg_temp.as_user('uax');
select is(public.rd_closing(pg_temp.rq(51), pg_temp.id('m_unasg'), pg_temp.id('sh_unasg'), pg_temp.d('unasg'), 55, 40, 5) ->> 'entered_by_ua', 'true', 'a Unit Admin closes an unassigned machine, labelled');
select results_eq($$ select entered_by_ua, late_opening from public.production_summary where machine_id = pg_temp.id('m_unasg') $$, $$ values (true, false) $$, 'and the summary says Entered by Unit Admin');

-- Corrections (AC-6) ----------------------------------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('s1');
select is(pg_temp.keep('o_late2', public.rd_correct(pg_temp.rq(60), pg_temp.id('o_run'), 1010, pg_temp.id('p2'), null, null, 'checked', 'typed 1000 instead of 1010')) ->> 'ok', 'true', 'the owner corrects an opening before the next occurrence starts');
select results_eq($$ select supersedes_id, correction_reason, counter_value, product_id, kind, late, entered_by_ua from public.production_reading where id = pg_temp.id('o_late2') $$,
  $$ values (pg_temp.id('o_run'), 'typed 1000 instead of 1010'::text, 1010::bigint, pg_temp.id('p2'), 'opening'::text, false, false) $$, 'the correction supersedes the reading and carries the reason');
select results_eq($$ select counter_value, product_id from public.production_reading where id = pg_temp.id('o_run') $$, $$ values (1000::bigint, pg_temp.id('p1')) $$, 'the corrected reading stays unchanged in history');
select is((select id from app._rd_current(pg_temp.id('m_run'), pg_temp.id('sh_run'), pg_temp.d('run'), 'opening')), pg_temp.id('o_late2'), 'the correction is now the current opening');
select is(pg_temp.n_summ('run'), 2, 'a closing exists, so the correction appended a second summary');
select results_eq($$ select opening_counter, movement_units, product_id from public.production_summary where machine_id = pg_temp.id('m_run') order by recorded_at desc, id limit 1 $$,
  $$ values (1010::bigint, 240::bigint, pg_temp.id('p2')) $$, 'the latest summary uses the corrected opening');
select results_eq($$ select opening_counter, movement_units from public.production_summary where machine_id = pg_temp.id('m_run') order by recorded_at, id limit 1 $$,
  $$ values (1000::bigint, 250::bigint) $$, 'and the first summary is still there unchanged (versioned)');
select results_eq($$ select (before ->> 'counter')::int, (after ->> 'counter')::int, after ->> 'reason' from public.audit_event where action = 'reading.corrected' and entity_id = pg_temp.id('o_late2') $$,
  $$ values (1000, 1010, 'typed 1000 instead of 1010'::text) $$, 'the audit row carries before, after and the reason');
select is(public.rd_correct(pg_temp.rq(60), pg_temp.id('o_run'), 1010, pg_temp.id('p2'), null, null, 'checked', 'typed 1000 instead of 1010') ->> 'already', 'true', 'a replay returns the first outcome');
select is(pg_temp.err($$ select public.rd_correct(pg_temp.rq(61), pg_temp.id('o_run'), 1011, pg_temp.id('p2'), null, null, null, 'again') $$) ->> 'field', 'not_current', 'a reading that was already corrected cannot be corrected again');
select is(pg_temp.keep('o_run3', public.rd_correct(pg_temp.rq(62), pg_temp.id('o_late2'), 1012, pg_temp.id('p1'), null, null, null, 'second fix')) ->> 'ok', 'true', 'the latest one can');
select is((select count(*)::int from public.production_reading where machine_id = pg_temp.id('m_run') and kind = 'opening'), 3, 'history keeps all three openings');
select is(pg_temp.keep('c_run2', public.rd_correct(pg_temp.rq(63), pg_temp.id('c_run'), 1260, null, 250, 3, 'recount', 'recounted the crates')) ->> 'ok', 'true', 'a closing can be corrected');
select is(pg_temp.n_summ('run'), 4, 'each correction appends a summary');
select results_eq($$ select closing_counter, good, reject, opening_counter from public.production_summary where machine_id = pg_temp.id('m_run') order by recorded_at desc, id limit 1 $$,
  $$ values (1260::bigint, 250, 3, 1012::bigint) $$, 'the latest summary combines the corrected closing with the corrected opening');
select is(pg_temp.n_audit('reading.corrected'), 3, 'three reading.corrected audit rows so far');
-- validation
select is(pg_temp.err($$ select public.rd_correct(pg_temp.rq(64), pg_temp.id('o_run3'), 1, pg_temp.id('p1'), null, null, null, '   ') $$) ->> 'field', 'reason', 'a blank reason is refused');
select is(pg_temp.err($$ select public.rd_correct(pg_temp.rq(64), pg_temp.id('o_run3'), 1, pg_temp.id('p1'), null, null, null, null) $$) ->> 'field', 'reason', 'a missing reason too');
select is(pg_temp.err($$ select public.rd_correct(pg_temp.rq(64), pg_temp.id('o_run3'), 1, pg_temp.id('p1'), null, null, null, repeat('x', 201)) $$) ->> 'field', 'reason', 'and one over 200 characters');
select is(pg_temp.err($$ select public.rd_correct(pg_temp.rq(64), pg_temp.id('o_run3'), null, pg_temp.id('p1'), null, null, null, 'r') $$) ->> 'field', 'counter', 'a correction needs a counter');
select is(pg_temp.err($$ select public.rd_correct(pg_temp.rq(64), pg_temp.id('o_run3'), 1, pg_temp.id('p1'), 5, null, null, 'r') $$) ->> 'field', 'good', 'an opening correction takes no good quantity');
select is(pg_temp.err($$ select public.rd_correct(pg_temp.rq(64), pg_temp.id('o_run3'), 1, pg_temp.id('pret'), null, null, null, 'r') $$) ->> 'field', 'product_id', 'a retired product is refused');
select is(public.rd_correct(pg_temp.rq(64), pg_temp.id('o_run3'), 1, pg_temp.id('py'), null, null, null, 'r'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'another tenant''s product is denied');
select is(pg_temp.err($$ select public.rd_correct(pg_temp.rq(64), pg_temp.id('c_run2'), 1, pg_temp.id('p1'), 1, 1, null, 'r') $$) ->> 'field', 'product_id', 'a closing correction takes no product');
select is(pg_temp.err($$ select public.rd_correct(pg_temp.rq(64), pg_temp.id('c_run2'), 1, null, null, 1, null, 'r') $$) ->> 'field', 'good', 'and needs good');
select is(pg_temp.err($$ select public.rd_correct(null, pg_temp.id('c_run2'), 1, null, 1, 1, null, 'r') $$) ->> 'field', 'request_id', 'and a request id');
select is(pg_temp.err($$ select public.rd_correct(pg_temp.rq(41), pg_temp.id('c_run2'), 1, null, 1, 1, null, 'r') $$) ->> 'field', 'request_id', 'a request id used by another RPC is a validation error');
select is(pg_temp.n_audit('reading.corrected'), 3, 'none of the refused corrections was recorded');

-- The Late flag belongs to the occurrence's earliest submission
select is((select late from public.production_reading where machine_id = pg_temp.id('m_late')), true, 'precondition: the late occurrence''s opening is Late');
select is(public.rd_correct(pg_temp.rq(65), (select id from public.production_reading where machine_id = pg_temp.id('m_late')), 11, pg_temp.id('p1'), null, null, null, 'typo') ->> 'late', 'true', 'correcting a late reading keeps the Late flag');
select pg_temp.put_open('corr', 500);
select pg_temp.put_close('corr', 800, 290, 5);
select is(app._rd_compute_summary(pg_temp.id('tx'), pg_temp.id('s1'), pg_temp.id('m_corr'), pg_temp.id('sh_corr'), pg_temp.d('corr'), null) is not null, true, 'fixture: a summary for the on-time pair that is now three hours old');
select is(public.rd_correct(pg_temp.rq(66), (select id from app._rd_current(pg_temp.id('m_corr'), pg_temp.id('sh_corr'), pg_temp.d('corr'), 'opening')), 510, pg_temp.id('p1'), null, null, null, 'typo') ->> 'late', 'false',
  'correcting an on-time reading long after the boundary does not make it late');
select results_eq($$ select late_opening, late_closing from public.production_summary where machine_id = pg_temp.id('m_corr') order by recorded_at desc, id limit 1 $$, $$ values (false, false) $$, 'and the summary shows both on time');
select is(pg_temp.n_summ('late'), 0, 'a correction with no closing yet appends no summary');

-- The supervisor's correction window ends when the next occurrence of the shift starts; a Unit Admin may correct at any time (AC-6)
select pg_temp.put_open('long', 100, 's1', false, pg_temp.d('long') - 1);
select pg_temp.put_close('long', 200, 90, 5, 's1', false, pg_temp.d('long') - 1);
select pg_temp.put_open('long', 300);
select is(pg_temp.err($$ select public.rd_correct(pg_temp.rq(70), (select id from app._rd_current(pg_temp.id('m_long'), pg_temp.id('sh_long'), pg_temp.d('long') - 1, 'closing')), 210, null, 91, 5, null, 'late fix') $$) ->> 'field',
  'correction_window_closed', 'the owner cannot correct yesterday''s occurrence once today''s has started');
select is(pg_temp.n_audit('reading.corrected'), 5, 'and nothing was recorded (the five earlier corrections are the only ones)');
select is(pg_temp.keep('o_long', public.rd_correct(pg_temp.rq(71), (select id from app._rd_current(pg_temp.id('m_long'), pg_temp.id('sh_long'), pg_temp.d('long'), 'opening')), 310, pg_temp.id('p1'), null, null, null, 'fix')) ->> 'ok', 'true',
  'the owner can correct the occurrence that is running (the next one has not started)');
select pg_temp.as_user('uax');
select is(public.rd_correct(pg_temp.rq(72), (select id from app._rd_current(pg_temp.id('m_long'), pg_temp.id('sh_long'), pg_temp.d('long') - 1, 'closing')), 210, null, 91, 5, null, 'late fix') ->> 'entered_by_ua', 'true',
  'a Unit Admin can, and the correction is labelled Entered by Unit Admin');
select is((select count(*)::int from public.production_summary where machine_id = pg_temp.id('m_long') and shift_date = pg_temp.d('long') - 1), 1, 'a summary was appended for the corrected occurrence');
select results_eq($$ select good, entered_by_ua from public.production_summary where machine_id = pg_temp.id('m_long') and shift_date = pg_temp.d('long') - 1 $$, $$ values (91, true) $$, 'with the corrected quantity and the label');

-- Other users cannot correct
select pg_temp.as_user('s2');
select is(public.rd_correct(pg_temp.rq(73), pg_temp.id('o_long'), 1, pg_temp.id('p1'), null, null, null, 'x'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'another supervisor cannot correct');
select is(public.rd_correct(pg_temp.rq(74), gen_random_uuid(), 1, pg_temp.id('p1'), null, null, null, 'x'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'an unknown reading is denied');
select is(pg_temp.n_denied('rpc:rd_correct', 'not_owner'), 1, 'the other supervisor is audited as not_owner');
select is(pg_temp.n_denied('rpc:rd_correct', 'not_found'), 1, 'and the unknown id as not_found');
select pg_temp.as_user('uay');
select is(public.rd_correct(pg_temp.rq(75), pg_temp.id('o_long'), 1, pg_temp.id('p1'), null, null, null, 'x'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'another tenant''s Unit Admin is denied');
select is(pg_temp.n_denied('rpc:rd_correct', 'cross_tenant'), 2, 'audited as cross_tenant (this one and the foreign product earlier)');
select pg_temp.as_user('sa');
select is(public.rd_correct(null, null, null, null, null, null, null, null), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a Super Admin is denied');
select is(public.rd_closing(null, null, null, null, null, null, null, null), '{"ok": false, "code": "not_allowed"}'::jsonb, 'also on closing');
select is(public.rd_opening(null, null, null, null, null, null, null), '{"ok": false, "code": "not_allowed"}'::jsonb, 'and opening');
select pg_temp.as_user('sinact');
select is(public.rd_correct(pg_temp.rq(76), pg_temp.id('o_long'), 1, pg_temp.id('p1'), null, null, null, 'x'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'an inactive user cannot correct');
select pg_temp.as_user('sfresh');
select is(public.rd_correct(pg_temp.rq(77), pg_temp.id('o_long'), 1, pg_temp.id('p1'), null, null, null, 'x'), '{"ok": false, "code": "not_allowed"}'::jsonb, 'nor one with a temporary password');
select pg_temp.as_user('uas');
select is(public.rd_closing(pg_temp.rq(78), pg_temp.id('m_long'), pg_temp.id('sh_long'), pg_temp.d('long'), 1, 1, 1), '{"ok": false, "code": "not_allowed"}'::jsonb, 'a suspended tenant''s Unit Admin cannot close');

-- 8a review fixes: R4 late opening, R5 early closing, R8 nits ---------------------------------------------------------------------------------------------
select pg_temp.as_user('s1');
select is(public.rd_opening(pg_temp.rq(201), pg_temp.id('m_lateopen'), pg_temp.id('sh_lateopen'), pg_temp.d('lateopen'), pg_temp.id('p1'), 10) ->> 'late', 'true',
  'R4: an opening after the shift ended (within 12 hours) is accepted and flagged Late');
select is(pg_temp.err($$ select public.rd_opening(pg_temp.rq(202), pg_temp.id('m_expired'), pg_temp.id('sh_expired'), pg_temp.d('expired'), pg_temp.id('p1'), 1) $$) ->> 'message', 'The opening window (12 hours after the shift) has passed',
  'R4: the refusal message names the 12-hour window');
select is(pg_temp.err($$ select public.rd_closing(pg_temp.rq(203), pg_temp.id('m_noopen'), pg_temp.id('sh_noopen'), pg_temp.d('noopen'), 5, 1, 1) $$) ->> 'field', 'no_opening', 'R4: a closing still needs an opening');
select pg_temp.as_user('uax');
select results_eq($$ select (r ->> 'late')::boolean, (r ->> 'entered_by_ua')::boolean from (select public.rd_opening(pg_temp.rq(204), pg_temp.id('m_lateopen2'), pg_temp.id('sh_lateopen2'), pg_temp.d('lateopen2'), pg_temp.id('p1'), 10) as r) q $$,
  $$ values (true, true) $$, 'R4: a Unit Admin may also record a late opening (entered by a Unit Admin, Late)');
select is(app.reading_state_at(now()) ->> 'ok', 'true', 'R4: the read still answers');

-- R5: early closing
select is((select early from public.production_reading where id = pg_temp.id('c_run')), true, 'R5: the closing of a running shift (more than 30 minutes before its end) is stored as Early');
select is((select early_closing from public.production_summary where machine_id = pg_temp.id('m_run') order by recorded_at, id limit 1), true, 'R5: the summary carries early_closing');
select is((select late from public.production_reading where id = pg_temp.id('c_run')), false, 'R5: Early is not Late');
select is((select early from app._rd_current(pg_temp.id('m_run'), pg_temp.id('sh_run'), pg_temp.d('run'), 'closing') ) , true, 'R5: a correction carries the Early flag of the occurrence');
select is((select early from public.production_reading where kind = 'opening' and machine_id = pg_temp.id('m_run') limit 1), false, 'R5: an opening is never Early');
select pg_temp.put_open('nearend', 10);
select is(public.rd_closing(pg_temp.rq(205), pg_temp.id('m_nearend'), pg_temp.id('sh_nearend'), pg_temp.d('nearend'), 20, 9, 1) ->> 'early', 'false', 'R5: a closing within 30 minutes before the end is not Early');
select is((select early_closing from public.production_summary where machine_id = pg_temp.id('m_nearend')), false, 'and its summary is not flagged');
select is((select (after ->> 'early')::boolean from public.audit_event where action = 'reading.closing' and entity_id = pg_temp.id('c_run')), true, 'R5: the audit row carries the early flag');

-- R8 N-5: a missing product is a validation error, not a denial
select set_config('t.nf', pg_temp.n_denied('rpc:rd_opening', 'not_found')::text, true);
select is(pg_temp.err($$ select public.rd_opening(pg_temp.rq(206), pg_temp.id('m_val'), pg_temp.id('sh_val'), pg_temp.d('val'), null, 5) $$) ->> 'field', 'product_id', 'N-5: opening without a product is a validation error');
select is(pg_temp.n_denied('rpc:rd_opening', 'not_found'), current_setting('t.nf')::int, 'and is not audited as a denial');
-- R8 N-6: retired machine / shift in closing and correction
select pg_temp.put_open('retc', 10);
select is(pg_temp.err($$ select public.rd_closing(pg_temp.rq(207), pg_temp.id('m_retc'), pg_temp.id('sh_retc'), pg_temp.d('retc'), 20, 1, 1) $$) ->> 'field', 'machine_retired', 'N-6: a retired machine cannot be closed');
select pg_temp.put_open('retsh', 10);
update public.shift set retired_at = now() where id = pg_temp.id('sh_retsh');
select is(pg_temp.err($$ select public.rd_closing(pg_temp.rq(208), pg_temp.id('m_retsh'), pg_temp.id('sh_retsh'), pg_temp.d('retsh'), 20, 1, 1) $$) ->> 'field', 'shift_retired', 'N-6: a retired shift cannot be closed');
select set_config('t.o_retc', (select id::text from public.production_reading where machine_id = pg_temp.id('m_retc') and kind = 'opening'), true);
select is(pg_temp.err(format($q$ select public.rd_correct(pg_temp.rq(209), %L, 11, pg_temp.id('p1'), null, null, null, 'fix') $q$, current_setting('t.o_retc'))) ->> 'field', 'machine_retired', 'N-6: nor corrected');
select pg_temp.put_open('retcorr', 10);
select is(pg_temp.err(format($q$ select public.rd_correct(pg_temp.rq(210), %L, 11, null, null, null, null, 'fix') $q$, (select id::text from public.production_reading where machine_id = pg_temp.id('m_retcorr') and kind = 'opening'))) ->> 'field', 'product_id',
  'N-5: correcting an opening without a product is a validation error');

-- Append-only: the RPCs never changed or removed a reading
select is((select count(*)::int from public.production_reading where id in (pg_temp.id('o_run'), pg_temp.id('c_run')) and counter_value in (1000, 1250)), 2, 'the first readings are unchanged after all the corrections');
select is((select count(*)::int from public.production_reading where supersedes_id is not null), 7, 'seven corrections exist in total (3 on run, 1 late, 1 corr, 2 long)');

-- Privileges
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('rd_opening', 'rd_closing', 'rd_correct') and has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute')), 3,
  'the three reading RPCs are executable by authenticated and not by anon');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname ~ '^(_rd_|rd_)' and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))), 0,
  'no helper in app is executable by clients');

select * from finish();
rollback;
