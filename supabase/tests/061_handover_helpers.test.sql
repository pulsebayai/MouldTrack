-- 08 step 2 (AC-1, AC-6, AC-11, D2-D4): the inherited set (app.handover_items_at), the declared test (app._ho_declared_at) and the set-based owner
-- resolution (app._ho_owners) pinned to 05's app.machine_owner / app.shift_window. Driven with explicit moments on fixed past dates (IST):
-- day shift 06:00-14:00, night shift 22:00-06:00 (overnight), a cover recorded mid-shift, carry-forward across day / overnight / cover, issues
-- reported before / during the occurrence, closed and resolved issues. Self-contained; rolled back. Phones +91 90000 28xxx.
begin;
create extension if not exists pgtap with schema extensions;
select plan(51);

create temp table ids (k text primary key, v uuid);
create function pg_temp.id(k text) returns uuid language sql as $$ select v from ids where k = $1 $$;
create function pg_temp.as_user(k text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where ids.k = $1), 'role', 'authenticated')::text, true) $$;
create function pg_temp.ts(dd date, hhmm text) returns timestamptz language sql as $$ select (dd + hhmm::time) at time zone 'Asia/Kolkata' $$;
-- the issues (by key) of a supervisor's checklist in an occurrence at a moment, e.g. 'i1,i2'
create function pg_temp.items(sup text, shft text, dd date, p_at timestamptz) returns text language sql as $$
  select coalesce(string_agg(k.k, ',' order by k.k), '-')
  from app.handover_items_at(pg_temp.id(sup), pg_temp.id(shft), dd, p_at) i join ids k on k.v = i.issue_id $$;
create function pg_temp.item(sup text, shft text, dd date, p_at timestamptz, iss text) returns jsonb language sql as $$
  select to_jsonb(i) from app.handover_items_at(pg_temp.id(sup), pg_temp.id(shft), dd, p_at) i where i.issue_id = pg_temp.id(iss) $$;

insert into auth.users (id, email, aud, role)
select u, 'tap61-' || n || '@example.test', 'authenticated', 'authenticated' from (values
  ('00000000-0000-4000-c801-0000000000a1'::uuid, 'uax'), ('00000000-0000-4000-c801-0000000000a2', 's1'), ('00000000-0000-4000-c801-0000000000a3', 's2'),
  ('00000000-0000-4000-c801-0000000000a4', 's3')) t(u, n);
insert into ids values ('uax', '00000000-0000-4000-c801-0000000000a1'), ('s1', '00000000-0000-4000-c801-0000000000a2'), ('s2', '00000000-0000-4000-c801-0000000000a3'),
  ('s3', '00000000-0000-4000-c801-0000000000a4'), ('tx', '50000000-0000-4000-c801-00000000000a');
insert into public.tenant (id, name, status, timezone) values ('50000000-0000-4000-c801-00000000000a', 'tap61 org X', 'active', 'Asia/Kolkata');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('50000000-0000-4000-c801-00000000000a', '00000000-0000-4000-c801-0000000000a1', 'unit_admin', 'active', 'UA X', 'UA-X', '+919000028201', false),
  ('50000000-0000-4000-c801-00000000000a', '00000000-0000-4000-c801-0000000000a2', 'supervisor', 'active', 'Sup One', 'S1', '+919000028202', false),
  ('50000000-0000-4000-c801-00000000000a', '00000000-0000-4000-c801-0000000000a3', 'supervisor', 'active', 'Sup Two', 'S2', '+919000028203', false),
  ('50000000-0000-4000-c801-00000000000a', '00000000-0000-4000-c801-0000000000a4', 'supervisor', 'active', 'Sup Three', 'S3', '+919000028204', false);
insert into public.site (id, tenant_id, name, timezone) values ('51000000-0000-4000-c801-00000000000a', pg_temp.id('tx'), 'Plant X', 'Asia/Kolkata');
insert into public.machine (id, tenant_id, site_id, code, name, retired_at) values
  ('53000000-0000-4000-c801-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c801-00000000000a', 'M-1', 'Press 1', null),
  ('53000000-0000-4000-c801-0000000000a2', pg_temp.id('tx'), '51000000-0000-4000-c801-00000000000a', 'M-2', 'Press 2', null),
  ('53000000-0000-4000-c801-0000000000a3', pg_temp.id('tx'), '51000000-0000-4000-c801-00000000000a', 'M-3', 'Press 3', null),
  ('53000000-0000-4000-c801-0000000000a4', pg_temp.id('tx'), '51000000-0000-4000-c801-00000000000a', 'M-4', 'Press 4 (retired)', '2026-03-01 00:00+00');
insert into ids values ('m1', '53000000-0000-4000-c801-0000000000a1'), ('m2', '53000000-0000-4000-c801-0000000000a2'), ('m3', '53000000-0000-4000-c801-0000000000a3'),
  ('m4', '53000000-0000-4000-c801-0000000000a4');
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time) values
  ('52000000-0000-4000-c801-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c801-00000000000a', 'Day', '06:00', '14:00'),
  ('52000000-0000-4000-c801-0000000000a2', pg_temp.id('tx'), '51000000-0000-4000-c801-00000000000a', 'Night', '22:00', '06:00');
insert into ids values ('day', '52000000-0000-4000-c801-0000000000a1'), ('night', '52000000-0000-4000-c801-0000000000a2');
-- plan: Day: M1 s1, M2 s1, M3 s2, M4 s1 (retired); Night: M1 s2, M2 s2 (M3 unassigned)
insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by)
select pg_temp.id('tx'), pg_temp.id(x.sh), pg_temp.id(x.m), pg_temp.id(x.s), date '2026-01-01', pg_temp.id('uax')
  from (values ('day', 'm1', 's1'), ('day', 'm2', 's1'), ('day', 'm3', 's2'), ('day', 'm4', 's1'), ('night', 'm1', 's2'), ('night', 'm2', 's2')) x(sh, m, s);
-- covers on Day 2026-03-12: M2 -> s2 recorded 08:00 (after the start: since = 08:00); M1 -> s3 recorded 2026-03-11 20:00 (before the start: no since)
insert into public.assignment_cover (tenant_id, shift_id, shift_date, machine_id, supervisor_id, reason, recorded_by, recorded_at) values
  (pg_temp.id('tx'), pg_temp.id('day'), date '2026-03-12', pg_temp.id('m2'), pg_temp.id('s2'), 'Sup One called away', pg_temp.id('uax'), pg_temp.ts(date '2026-03-12', '08:00')),
  (pg_temp.id('tx'), pg_temp.id('day'), date '2026-03-12', pg_temp.id('m1'), pg_temp.id('s3'), 'Planned cover', pg_temp.id('uax'), pg_temp.ts(date '2026-03-11', '20:00'));

create function pg_temp.mk_issue(k text, mach text, rep timestamptz, st text, closed_at timestamptz default null) returns void language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into public.machine_issue (id, tenant_id, machine_id, category_id, priority, description, reported_by, accountable_owner_id, reported_at, status, resolved_at, resolved_by, closed_at, closed_by)
  select v, pg_temp.id('tx'), pg_temp.id(mach), c.id, 'high', 'Issue ' || k, pg_temp.id('s1'), pg_temp.id('s1'), rep, st,
         case when st in ('resolved', 'closed') then coalesce(closed_at, rep + interval '1 hour') end, case when st in ('resolved', 'closed') then pg_temp.id('s2') end,
         closed_at, case when closed_at is not null then pg_temp.id('uax') end
    from public.issue_category c where c.tenant_id = pg_temp.id('tx') limit 1;
  insert into ids values (k, v);
  insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, status_after, at) values (pg_temp.id('tx'), v, pg_temp.id('s1'), 'supervisor', 'report', 'open', rep);
  if st = 'resolved' then
    insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, status_before, status_after, at) values (pg_temp.id('tx'), v, pg_temp.id('s2'), 'supervisor', 'resolve', 'open', 'resolved', rep + interval '1 hour');
  end if;
  if closed_at is not null then
    insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, status_before, status_after, at) values (pg_temp.id('tx'), v, pg_temp.id('uax'), 'unit_admin', 'verify_confirm', 'resolved', 'closed', closed_at);
  end if;
end $$;
select pg_temp.mk_issue('i1', 'm1', pg_temp.ts(date '2026-03-09', '10:00'), 'closed', pg_temp.ts(date '2026-03-12', '03:00'));
select pg_temp.mk_issue('i2', 'm1', pg_temp.ts(date '2026-03-10', '07:00'), 'open');
select pg_temp.mk_issue('i3', 'm2', pg_temp.ts(date '2026-03-10', '12:00'), 'open');
select pg_temp.mk_issue('i4', 'm3', pg_temp.ts(date '2026-03-09', '09:00'), 'resolved');
select pg_temp.mk_issue('i5', 'm3', pg_temp.ts(date '2026-03-08', '09:00'), 'closed', pg_temp.ts(date '2026-03-08', '15:00'));
select pg_temp.mk_issue('i6', 'm4', pg_temp.ts(date '2026-03-08', '10:00'), 'open');
select pg_temp.mk_issue('i7', 'm2', pg_temp.ts(date '2026-03-12', '09:30'), 'open');
select pg_temp.as_user('uax');

-- Inherited set (AC-1, D4) ---------------------------------------------------------------------------------------------------
select is(pg_temp.items('s1', 'day', date '2026-03-10', pg_temp.ts(date '2026-03-10', '05:45')), 'i1', 'Day 03-10 s1 before the start (30-minute window): the issue reported the day before');
select is(pg_temp.items('s1', 'day', date '2026-03-10', pg_temp.ts(date '2026-03-10', '12:00')), 'i1', 'an issue reported DURING the occurrence (i2 at 07:00) is not inherited');
select is(pg_temp.items('s2', 'night', date '2026-03-10', pg_temp.ts(date '2026-03-10', '22:10')), 'i1,i2,i3', 'Night 03-10 s2 inherits everything unresolved on M1 and M2, including the issues reported during the day');
select is(pg_temp.items('s1', 'day', date '2026-03-11', pg_temp.ts(date '2026-03-11', '06:10')), 'i1,i2,i3', 'Day 03-11 s1: carry-forward across the overnight shift (i1, i2, i3 still unresolved)');
select is(pg_temp.items('s2', 'day', date '2026-03-11', pg_temp.ts(date '2026-03-11', '06:10')), 'i4', 'a resolved-awaiting-verification issue is inherited (i4); a closed one (i5) is not');
select is(pg_temp.items('s3', 'day', date '2026-03-11', pg_temp.ts(date '2026-03-11', '06:10')), '-', 'a supervisor with no machine in the occurrence has nothing');
select is(pg_temp.items('s2', 'night', date '2026-03-11', pg_temp.ts(date '2026-03-12', '02:00')), 'i1,i2,i3', 'Night 03-11 at 02:00: i1 is still open at that moment');
select is(pg_temp.items('s2', 'night', date '2026-03-11', pg_temp.ts(date '2026-03-12', '03:30')), 'i2,i3', 'and drops out once it is closed (03:00): status is read as of the moment');
select is(pg_temp.items('s1', 'day', date '2026-03-12', pg_temp.ts(date '2026-03-12', '06:10')), 'i3', 'Day 03-12 s1 at 06:10: M1 went to s3 by an earlier cover; the cover recorded at 08:00 does not exist yet, so s1 still owns M2');
select is(pg_temp.items('s1', 'day', date '2026-03-12', pg_temp.ts(date '2026-03-12', '08:30')), '-', 'at 08:30 s1 has neither M2 (cover to s2) nor M1 (cover to s3, recorded earlier); M4 is retired');
select is(pg_temp.items('s3', 'day', date '2026-03-12', pg_temp.ts(date '2026-03-12', '06:10')), 'i2', 'a cover recorded BEFORE the start gives s3 M1''s issue from the start (i1 closed)');
select is(pg_temp.items('s2', 'day', date '2026-03-12', pg_temp.ts(date '2026-03-12', '08:30')), 'i3,i4', 'AC-6: the machine s2 receives by the 08:00 cover brings its inherited issues (i3) into the checklist; i7 (reported 09:30) is later');
select is(pg_temp.items('s2', 'day', date '2026-03-12', pg_temp.ts(date '2026-03-12', '06:10')), 'i4', 'before the cover is recorded s2 has only M3''s issue');
select is(pg_temp.items('s2', 'day', date '2026-03-12', pg_temp.ts(date '2026-03-12', '10:00')), 'i3,i4', 'an issue reported after the cover time (i7 at 09:30) is not inherited');
select is((pg_temp.item('s2', 'day', date '2026-03-12', pg_temp.ts(date '2026-03-12', '08:30'), 'i3') ->> 'since')::timestamptz, pg_temp.ts(date '2026-03-12', '08:00'), 'AC-6: the cover time is the handover start for i3 (since)');
select is((pg_temp.item('s2', 'day', date '2026-03-12', pg_temp.ts(date '2026-03-12', '08:30'), 'i4') ->> 'since'), null, 'and there is no since for a machine owned from the start');
select is((pg_temp.item('s3', 'day', date '2026-03-12', pg_temp.ts(date '2026-03-12', '06:10'), 'i2') ->> 'since'), null, 'a cover recorded before the occurrence started leaves since null');
select is((pg_temp.item('s2', 'day', date '2026-03-11', pg_temp.ts(date '2026-03-11', '06:10'), 'i4') ->> 'status'), 'resolved', 'the item carries the issue status at that moment');
select is(pg_temp.items('s1', 'day', date '2026-03-12', pg_temp.ts(date '2026-03-12', '06:10')) like '%i6%', false, 'a retired machine''s issues are not on anyone''s checklist (i6)');

-- Acknowledgement state (rows inserted as the owner) ------------------------------------------------------------------------------------------
select is((pg_temp.item('s1', 'day', date '2026-03-10', pg_temp.ts(date '2026-03-10', '07:00'), 'i1') ->> 'state'), 'pending', 'no acknowledgement: pending');
insert into public.issue_acknowledgement (tenant_id, issue_id, shift_id, shift_date, supervisor_id, kind, remark, at) values
  (pg_temp.id('tx'), pg_temp.id('i1'), pg_temp.id('day'), date '2026-03-10', pg_temp.id('s1'), 'acknowledged', null, pg_temp.ts(date '2026-03-10', '05:50'));
select is((pg_temp.item('s1', 'day', date '2026-03-10', pg_temp.ts(date '2026-03-10', '07:00'), 'i1') ->> 'state'), 'acknowledged', 'an acknowledgement made in the 30-minute window before the start counts');
select is((pg_temp.item('s1', 'day', date '2026-03-10', pg_temp.ts(date '2026-03-10', '05:00'), 'i1') ->> 'state'), 'pending', 'but not before the moment it was made (as of 05:00 it was not there yet)');
insert into public.issue_acknowledgement (tenant_id, issue_id, shift_id, shift_date, supervisor_id, kind, remark, at) values
  (pg_temp.id('tx'), pg_temp.id('i3'), pg_temp.id('day'), date '2026-03-11', pg_temp.id('s1'), 'refused', 'Not on my machine list', pg_temp.ts(date '2026-03-11', '06:05'));
select is((pg_temp.item('s1', 'day', date '2026-03-11', pg_temp.ts(date '2026-03-11', '07:00'), 'i3') ->> 'state') || ',' || (pg_temp.item('s1', 'day', date '2026-03-11', pg_temp.ts(date '2026-03-11', '07:00'), 'i3') ->> 'exception_pending'),
  'refused,true', 'a refusal without an exception is exception pending');
insert into public.handover_exception (tenant_id, issue_id, shift_id, shift_date, ua_id, reason, owner_id, kept, at) values
  (pg_temp.id('tx'), pg_temp.id('i3'), pg_temp.id('day'), date '2026-03-11', pg_temp.id('uax'), 'Keep it', pg_temp.id('s1'), true, pg_temp.ts(date '2026-03-11', '06:30'));
select is((pg_temp.item('s1', 'day', date '2026-03-11', pg_temp.ts(date '2026-03-11', '07:00'), 'i3') ->> 'exception_pending')::boolean, false, 'an exception recorded afterwards clears it');
select is((pg_temp.item('s1', 'day', date '2026-03-11', pg_temp.ts(date '2026-03-11', '06:20'), 'i3') ->> 'exception_pending')::boolean, true, 'as of before the exception it was still pending');
select is((pg_temp.item('s1', 'day', date '2026-03-12', pg_temp.ts(date '2026-03-12', '06:10'), 'i3') ->> 'state'), 'pending', 'an acknowledgement of one occurrence does not carry to the next (carry-forward asks again)');
-- a stale acknowledgement (made before a cover gave the machine to the supervisor) does not count
insert into public.issue_acknowledgement (tenant_id, issue_id, shift_id, shift_date, supervisor_id, kind, remark, at) values
  (pg_temp.id('tx'), pg_temp.id('i3'), pg_temp.id('day'), date '2026-03-12', pg_temp.id('s2'), 'acknowledged', null, pg_temp.ts(date '2026-03-12', '07:00'));
select is((pg_temp.item('s2', 'day', date '2026-03-12', pg_temp.ts(date '2026-03-12', '09:00'), 'i3') ->> 'state'), 'pending', 'AC-6: an acknowledgement made before the cover time is stale; the supervisor acknowledges again');
insert into public.issue_acknowledgement (tenant_id, issue_id, shift_id, shift_date, supervisor_id, kind, remark, at) values
  (pg_temp.id('tx'), pg_temp.id('i3'), pg_temp.id('day'), date '2026-03-12', pg_temp.id('s2'), 'acknowledged', null, pg_temp.ts(date '2026-03-12', '08:10'));
select is((pg_temp.item('s2', 'day', date '2026-03-12', pg_temp.ts(date '2026-03-12', '09:00'), 'i3') ->> 'state'), 'acknowledged', 'and one made after the cover time counts');

-- Declared (D2) ---------------------------------------------------------------------------------------------------------------------------
select is(app._ho_declared_at(pg_temp.id('s1'), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-10', '12:00')), false, 'no declaration: not declared');
insert into public.handover_declaration (tenant_id, shift_id, shift_date, supervisor_id, covered_issue_ids, at) values
  (pg_temp.id('tx'), pg_temp.id('day'), date '2026-03-10', pg_temp.id('s1'), array[pg_temp.id('i1')], pg_temp.ts(date '2026-03-10', '05:55'));
select is(app._ho_declared_at(pg_temp.id('s1'), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-10', '12:00')), true, 'a declaration made in the 30 minutes before the start counts');
select is(app._ho_declared_at(pg_temp.id('s1'), pg_temp.id('day'), date '2026-03-10', pg_temp.ts(date '2026-03-10', '05:00')), false, 'but not as of a moment before it was made');
select is(app._ho_declared_at(pg_temp.id('s1'), pg_temp.id('day'), date '2026-03-11', pg_temp.ts(date '2026-03-11', '12:00')), false, 'a declaration belongs to one occurrence');
select is(app._ho_declared_at(pg_temp.id('s2'), pg_temp.id('night'), date '2026-03-10', pg_temp.ts(date '2026-03-11', '01:00')), false, 'another supervisor''s declaration does not count');
insert into public.handover_declaration (tenant_id, shift_id, shift_date, supervisor_id, covered_issue_ids, at) values
  (pg_temp.id('tx'), pg_temp.id('day'), date '2026-03-12', pg_temp.id('s2'), array[pg_temp.id('i4')], pg_temp.ts(date '2026-03-12', '06:20'));
select is(app._ho_declared_at(pg_temp.id('s2'), pg_temp.id('day'), date '2026-03-12', pg_temp.ts(date '2026-03-12', '07:00')), true, 'AC-6: declared before the cover');
select is(app._ho_declared_at(pg_temp.id('s2'), pg_temp.id('day'), date '2026-03-12', pg_temp.ts(date '2026-03-12', '09:00')), false, 'AC-6: the cover (08:00) makes the earlier declaration stale: s2 must declare again');
insert into public.handover_declaration (tenant_id, shift_id, shift_date, supervisor_id, covered_issue_ids, at) values
  (pg_temp.id('tx'), pg_temp.id('day'), date '2026-03-12', pg_temp.id('s2'), array[pg_temp.id('i3'), pg_temp.id('i4')], pg_temp.ts(date '2026-03-12', '08:20'));
select is(app._ho_declared_at(pg_temp.id('s2'), pg_temp.id('day'), date '2026-03-12', pg_temp.ts(date '2026-03-12', '09:00')), true, 'and the new declaration counts; the earlier one stays in history');
select is((select count(*)::int from public.handover_declaration where supervisor_id = pg_temp.id('s2') and shift_date = date '2026-03-12'), 2, 'both declarations are kept');

-- The set-based owner resolution equals 05's (pin) ---------------------------------------------------------------------------------------
create temp table pins as
  select o.*, app.machine_owner(o.machine_id, o.shift_id, o.shift_date) as owner05, app.shift_window(o.shift_id, o.shift_date) as w05
  from app._ho_owners(pg_temp.id('tx'), date '2026-03-08', date '2026-03-13') o;
select ok((select count(*) from pins) >= 20, 'the owner resolution returns the assigned machine-occurrences over the range');
select is((select count(*)::int from pins where supervisor_id is distinct from owner05), 0, 'pin: every owner equals app.machine_owner');
select is((select count(*)::int from pins where tstzrange(w_start, w_end, '[)') is distinct from w05), 0, 'pin: every window equals app.shift_window (overnight included)');
select is((select count(*)::int from pins where supervisor_id is null), 0, 'unassigned machine-occurrences (Night M3) are not returned');
select is((select count(*)::int from pins where machine_id = pg_temp.id('m3') and shift_id = pg_temp.id('night')), 0, 'Night M3 is unassigned');
select is((select count(*)::int from pins where machine_id = pg_temp.id('m4') and shift_date >= date '2026-03-02'), 0, 'a machine retired before the occurrence is excluded');
select is((select count(*)::int from pins where since is not null), 1, 'only the mid-shift cover (08:00) has a since');
select is((select handover_start from pins where machine_id = pg_temp.id('m2') and shift_date = date '2026-03-12' and shift_id = pg_temp.id('day')), pg_temp.ts(date '2026-03-12', '08:00'), 'handover start = the cover time');
select is((select handover_start from pins where machine_id = pg_temp.id('m1') and shift_date = date '2026-03-12' and shift_id = pg_temp.id('day')), pg_temp.ts(date '2026-03-12', '06:00'), 'handover start = the shift start otherwise');
select is((select w_end from pins where shift_id = pg_temp.id('night') and shift_date = date '2026-03-10' limit 1), pg_temp.ts(date '2026-03-11', '06:00'), 'the overnight occurrence ends the next morning');
select is(pg_temp.items('s2', 'night', date '2026-03-10', pg_temp.ts(date '2026-03-10', '22:10')), 'i1,i2,i3', 'the helper is repeatable (same answer twice)');
select throws_ok($$ select * from app._ho_owners('50000000-0000-4000-c801-00000000000a', date '2026-03-01', date '2026-06-30') $$, 'P0001', null, 'the date range is bounded (at most 93 days)');
select is(app._ho_declared_at(null, null, null, now()), false, 'null arguments are not declared');
select is((select count(*)::int from app.handover_items_at(pg_temp.id('s1'), pg_temp.id('day'), date '2026-03-10', now())), 0, 'asked with the current moment the history rows (inserted with past timestamps) simply do not match: no error');

select * from finish();
rollback;
