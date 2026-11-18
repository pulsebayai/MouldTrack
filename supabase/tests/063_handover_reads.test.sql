-- 08 step 4 (AC-1, AC-9, AC-12, AC-13, D7 + NFR): handover_checklist (contents, order, bounds, session snapshot written once, windows, verify section),
-- handover_alerts (exceptions pending oldest first, overdue acknowledgements, bounded 50 + totals), app.handover_compliance (compliant, late declaration,
-- no declaration, refusal without exception, refusal with exception, closed-before-deadline drops out, unassigned excluded, overdue count, snapshotted
-- overdue minutes, cover time as the deadline start, not-ended excluded), the public reads take no client time, denials, and the timing NFRs on a
-- seeded volume. Explicit moments on fixed past dates (IST). Self-contained; rolled back. Phones +91 90000 28xxx.
begin;
create extension if not exists pgtap with schema extensions;
select plan(103);

create temp table ids (k text primary key, v uuid);
create function pg_temp.id(k text) returns uuid language sql as $$ select v from ids where k = $1 $$;
create function pg_temp.as_user(k text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where ids.k = $1), 'role', 'authenticated')::text, true) $$;
create function pg_temp.ts(dd date, hhmm text) returns timestamptz language sql as $$ select (dd + hhmm::time) at time zone 'Asia/Kolkata' $$;
create function pg_temp.err(q text) returns jsonb language plpgsql as $f$
declare d text; m text; st text;
begin
  execute q;
  return jsonb_build_object('raised', false);
exception when others then
  get stacked diagnostics d = pg_exception_detail, m = message_text, st = returned_sqlstate;
  return coalesce(case when d ~ '^[{]' then d::jsonb end, '{}'::jsonb) || jsonb_build_object('message', m, 'sqlstate', st);
end $f$;
create function pg_temp.d10() returns date language sql as $$ select date '2026-03-10' $$;

insert into auth.users (id, email, aud, role)
select u, 'tap63-' || n || '@example.test', 'authenticated', 'authenticated' from (values
  ('00000000-0000-4000-c803-0000000000a1'::uuid, 'uax'), ('00000000-0000-4000-c803-0000000000a2', 's1'), ('00000000-0000-4000-c803-0000000000a3', 's2'),
  ('00000000-0000-4000-c803-0000000000a4', 's3'), ('00000000-0000-4000-c803-0000000000a5', 's4'), ('00000000-0000-4000-c803-0000000000a6', 's5'),
  ('00000000-0000-4000-c803-0000000000a7', 's6'), ('00000000-0000-4000-c803-0000000000a8', 's7'), ('00000000-0000-4000-c803-0000000000b1', 'uay'),
  ('00000000-0000-4000-c803-0000000000b2', 'sy'), ('00000000-0000-4000-c803-0000000000f1', 'sa')) t(u, n);
insert into ids values ('uax', '00000000-0000-4000-c803-0000000000a1'), ('s1', '00000000-0000-4000-c803-0000000000a2'), ('s2', '00000000-0000-4000-c803-0000000000a3'),
  ('s3', '00000000-0000-4000-c803-0000000000a4'), ('s4', '00000000-0000-4000-c803-0000000000a5'), ('s5', '00000000-0000-4000-c803-0000000000a6'),
  ('s6', '00000000-0000-4000-c803-0000000000a7'), ('s7', '00000000-0000-4000-c803-0000000000a8'), ('uay', '00000000-0000-4000-c803-0000000000b1'),
  ('sy', '00000000-0000-4000-c803-0000000000b2'), ('sa', '00000000-0000-4000-c803-0000000000f1'),
  ('tx', '50000000-0000-4000-c803-00000000000a'), ('ty', '50000000-0000-4000-c803-00000000000b');
insert into public.tenant (id, name, status, timezone) values
  ('50000000-0000-4000-c803-00000000000a', 'tap63 org X', 'active', 'Asia/Kolkata'), ('50000000-0000-4000-c803-00000000000b', 'tap63 org Y', 'active', 'Asia/Kolkata');
insert into public.handover_setting (tenant_id, overdue_minutes, required) values (pg_temp.id('tx'), 60, true), (pg_temp.id('ty'), 60, true);
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password)
select '50000000-0000-4000-c803-00000000000a', u, r::public.member_role, 'active', n, e, p, false from (values
  ('00000000-0000-4000-c803-0000000000a1'::uuid, 'unit_admin', 'UA X', 'UA-X', '+919000028401'), ('00000000-0000-4000-c803-0000000000a2', 'supervisor', 'Sup One', 'S1', '+919000028402'),
  ('00000000-0000-4000-c803-0000000000a3', 'supervisor', 'Sup Two', 'S2', '+919000028403'), ('00000000-0000-4000-c803-0000000000a4', 'supervisor', 'Sup Three', 'S3', '+919000028404'),
  ('00000000-0000-4000-c803-0000000000a5', 'supervisor', 'Sup Four', 'S4', '+919000028405'), ('00000000-0000-4000-c803-0000000000a6', 'supervisor', 'Sup Five', 'S5', '+919000028406'),
  ('00000000-0000-4000-c803-0000000000a7', 'supervisor', 'Sup Six', 'S6', '+919000028407'), ('00000000-0000-4000-c803-0000000000a8', 'supervisor', 'Sup Seven', 'S7', '+919000028408')) v(u, r, n, e, p);
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('50000000-0000-4000-c803-00000000000b', '00000000-0000-4000-c803-0000000000b1', 'unit_admin', 'active', 'UA Y', 'UA-Y', '+919000028409', false),
  ('50000000-0000-4000-c803-00000000000b', '00000000-0000-4000-c803-0000000000b2', 'supervisor', 'active', 'Sup Y', 'SY', '+919000028410', false);
insert into public.platform_admin (user_id, full_name, phone_e164, status, must_change_password) values ('00000000-0000-4000-c803-0000000000f1', 'SA 63', '+919000028411', 'active', false);
insert into public.site (id, tenant_id, name, timezone) values
  ('51000000-0000-4000-c803-00000000000a', pg_temp.id('tx'), 'Plant X', 'Asia/Kolkata'), ('51000000-0000-4000-c803-00000000000b', pg_temp.id('ty'), 'Plant Y', 'Asia/Kolkata');
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time) values
  ('52000000-0000-4000-c803-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c803-00000000000a', 'Day', '06:00', '14:00'),
  ('52000000-0000-4000-c803-0000000000a2', pg_temp.id('tx'), '51000000-0000-4000-c803-00000000000a', 'Eve', '14:00', '22:00'),
  ('52000000-0000-4000-c803-0000000000a3', pg_temp.id('tx'), '51000000-0000-4000-c803-00000000000a', 'Night', '22:00', '06:00');
insert into ids values ('day', '52000000-0000-4000-c803-0000000000a1'), ('eve', '52000000-0000-4000-c803-0000000000a2'), ('night', '52000000-0000-4000-c803-0000000000a3');
create function pg_temp.mm(k text, code text, sh text, sup text, eff date default date '2026-01-01') returns void language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into public.machine (id, tenant_id, site_id, code, name) values (v, pg_temp.id('tx'), pg_temp.id('site_x'), code, 'Press ' || code);
  insert into ids values (k, v);
  if sup is not null then
    insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by) values (pg_temp.id('tx'), pg_temp.id(sh), v, pg_temp.id(sup), eff, pg_temp.id('uax'));
  end if;
end $$;
insert into ids values ('site_x', '51000000-0000-4000-c803-00000000000a');
select pg_temp.mm('m1', 'M-1', 'day', 's1'); select pg_temp.mm('m2', 'M-2', 'day', 's2'); select pg_temp.mm('m3', 'M-3', 'day', 's3'); select pg_temp.mm('m4', 'M-4', 'day', 's4');
select pg_temp.mm('m5', 'M-5', 'day', 's5'); select pg_temp.mm('m6', 'M-6', 'day', 's6'); select pg_temp.mm('m7', 'M-7', 'day', null); select pg_temp.mm('m9', 'M-9', 'day', 's1');
select pg_temp.mm('m8', 'M-8', 'eve', 's1', date '2026-03-11'); -- Eve 03-10 has no planned owner; the cover below gives it to s2
create function pg_temp.mi(k text, mach text, rep timestamptz, st text default 'open', closed_at timestamptz default null, pri text default 'high') returns void language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into public.machine_issue (id, tenant_id, machine_id, category_id, priority, description, reported_by, accountable_owner_id, reported_at, status, resolved_at, resolved_by, closed_at, closed_by)
  select v, pg_temp.id('tx'), pg_temp.id(mach), c.id, pri, 'Issue ' || k, pg_temp.id('s7'), pg_temp.id('s7'), rep, st,
         case when st in ('resolved', 'closed') then coalesce(closed_at, pg_temp.ts(date '2026-03-09', '20:00')) end, case when st in ('resolved', 'closed') then pg_temp.id('s2') end,
         closed_at, case when closed_at is not null then pg_temp.id('uax') end
    from public.issue_category c where c.tenant_id = pg_temp.id('tx') limit 1;
  insert into ids values (k, v);
  insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, status_after, at) values (pg_temp.id('tx'), v, pg_temp.id('s7'), 'supervisor', 'report', 'open', rep);
  if st = 'resolved' then
    insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, status_before, status_after, at) values (pg_temp.id('tx'), v, pg_temp.id('s2'), 'supervisor', 'resolve', 'open', 'resolved', pg_temp.ts(date '2026-03-09', '20:00'));
  end if;
  if closed_at is not null then
    insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, status_before, status_after, at) values (pg_temp.id('tx'), v, pg_temp.id('uax'), 'unit_admin', 'verify_confirm', 'resolved', 'closed', closed_at);
  end if;
end $$;
select pg_temp.mi('i1', 'm1', pg_temp.ts(date '2026-03-09', '10:00')); select pg_temp.mi('i1b', 'm1', pg_temp.ts(date '2026-03-09', '11:00'));
select pg_temp.mi('i10', 'm1', pg_temp.ts(date '2026-03-09', '08:00'), 'resolved');
select pg_temp.mi('i9', 'm9', pg_temp.ts(date '2026-03-08', '10:00'));
select pg_temp.mi('i2', 'm2', pg_temp.ts(date '2026-03-09', '10:00')); select pg_temp.mi('i2b', 'm2', pg_temp.ts(date '2026-03-09', '11:00'));
select pg_temp.mi('i3', 'm3', pg_temp.ts(date '2026-03-09', '10:00')); select pg_temp.mi('i3b', 'm3', pg_temp.ts(date '2026-03-09', '11:00'));
select pg_temp.mi('i4', 'm4', pg_temp.ts(date '2026-03-09', '10:00')); select pg_temp.mi('i5', 'm5', pg_temp.ts(date '2026-03-09', '10:00'));
select pg_temp.mi('i6', 'm6', pg_temp.ts(date '2026-03-09', '10:00'), 'closed', pg_temp.ts(date '2026-03-10', '06:40'));
select pg_temp.mi('i7', 'm7', pg_temp.ts(date '2026-03-09', '10:00'));
select pg_temp.mi('i8', 'm8', pg_temp.ts(date '2026-03-10', '09:00'));
-- answers (Day 2026-03-10)
create function pg_temp.ack(iss text, sup text, shft text, kind text, at_ts timestamptz) returns void language sql as $$
  insert into public.issue_acknowledgement (tenant_id, issue_id, shift_id, shift_date, supervisor_id, kind, remark, at)
  values (pg_temp.id('tx'), pg_temp.id(iss), pg_temp.id(shft), date '2026-03-10', pg_temp.id(sup), kind, case when kind = 'refused' then 'No' end, at_ts) $$;
create function pg_temp.decl(sup text, shft text, at_ts timestamptz) returns void language sql as $$
  insert into public.handover_declaration (tenant_id, shift_id, shift_date, supervisor_id, covered_issue_ids, at) values (pg_temp.id('tx'), pg_temp.id(shft), date '2026-03-10', pg_temp.id(sup), '{}', at_ts) $$;
create function pg_temp.comp(sup text, shft text, p_at timestamptz default null) returns jsonb language sql as $$
  select to_jsonb(c) from app.handover_compliance_at(pg_temp.id('tx'), date '2026-03-10', date '2026-03-10', coalesce(p_at, pg_temp.ts(date '2026-03-11', '00:00'))) c
   where c.supervisor_id = pg_temp.id(sup) and c.shift_id = pg_temp.id(shft) $$;

-- Checklist (AC-1) ------------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('s1');
select is(jsonb_array_length(app.handover_checklist_at(pg_temp.ts(pg_temp.d10(), '05:20')) -> 'occurrences'), 0, 'more than 30 minutes before the start there is no checklist');
select is((select count(*)::int from public.handover_session), 0, 'and no session row');
select is(jsonb_array_length(app.handover_checklist_at(pg_temp.ts(pg_temp.d10(), '05:35')) -> 'occurrences'), 1, '25 minutes before the start the checklist is there');
select is((select count(*)::int from public.handover_session where supervisor_id = pg_temp.id('s1')), 1, 'the first read writes the session snapshot');
select is((select overdue_minutes::text || '@' || (handover_start = pg_temp.ts(pg_temp.d10(), '06:00'))::text from public.handover_session where supervisor_id = pg_temp.id('s1')), '60@true', 'with the overdue minutes in force and the window start');
select app.handover_checklist_at(pg_temp.ts(pg_temp.d10(), '06:10'));
select is((select count(*)::int from public.handover_session where supervisor_id = pg_temp.id('s1')), 1, 'a second read writes nothing more (once per supervisor, occurrence and handover start)');
create temp table c1 as select app.handover_checklist_at(pg_temp.ts(pg_temp.d10(), '06:10')) as j;
select is(c1.j ->> 'ok', 'true', 'ok') from c1;
select is((select jsonb_array_length(j -> 'occurrences') from c1), 1, 'one occurrence (Day): the night shift ended at 06:00 with nothing to declare for s1');
select is((select j -> 'occurrences' -> 0 -> 'shift' ->> 'name' from c1), 'Day', 'the Day shift');
select is((select (j -> 'occurrences' -> 0 ->> 'running')::boolean from c1), true, 'running');
select is((select string_agg(m ->> 'code', ',' order by ord) from c1, jsonb_array_elements(j -> 'occurrences' -> 0 -> 'machines') with ordinality t(m, ord)), 'M-1,M-9', 'the machines are ordered by code');
select is((select string_agg(it ->> 'description', ',' order by ord) from c1, jsonb_array_elements(j -> 'occurrences' -> 0 -> 'machines' -> 0 -> 'items') with ordinality t(it, ord)), 'Issue i10,Issue i1,Issue i1b', 'M-1''s issues are ordered by reported time (the resolved fix first)');
select is((select string_agg(it ->> 'description', ',') from c1, jsonb_array_elements(j -> 'occurrences' -> 0 -> 'machines' -> 1 -> 'items') t(it)), 'Issue i9', 'M-9 has its issue');
select is((select j -> 'occurrences' -> 0 ->> 'pending_count' from c1), '4', 'four issues to answer');
select is((select j -> 'occurrences' -> 0 -> 'allowed_actions' from c1), '[]'::jsonb, 'declare is not offered while issues are pending');
select is((select (j -> 'occurrences' -> 0 ->> 'declared')::boolean from c1), false, 'not declared');
select is((select j -> 'occurrences' -> 0 -> 'machines' -> 0 -> 'items' -> 1 ->> 'state' from c1), 'pending', 'each item carries its state');
select is((select j -> 'occurrences' -> 0 -> 'machines' -> 0 -> 'items' -> 1 -> 'allowed_actions' from c1), '["acknowledge", "refuse", "add_note"]'::jsonb, 'and the actions the server allows (acknowledge, refuse, and a note while the shift runs)');
select is((select j -> 'occurrences' -> 0 -> 'machines' -> 0 -> 'items' -> 0 -> 'allowed_actions' from c1), '["acknowledge", "refuse"]'::jsonb, 'a resolved fix has no note action');
select is((select (it ->> 'priority') || ',' || (it ->> 'previous_owner_name') || ',' || (it ->> 'escalated') || ',' || (it ->> 'machine_code')
            from c1, jsonb_array_elements(j -> 'occurrences' -> 0 -> 'machines' -> 0 -> 'items') t(it) where it ->> 'description' = 'Issue i1'), 'high,Sup Seven,false,M-1', 'priority, previous owner, escalation flag and machine are on the card');
select is((select it ->> 'reported_at' is not null from c1, jsonb_array_elements(j -> 'occurrences' -> 0 -> 'machines' -> 0 -> 'items') t(it) where it ->> 'description' = 'Issue i1'), true, 'and the reported time');
select is((select (j -> 'occurrences' ->> 0 is not null and (j -> 'occurrences' -> 0 ->> 'deadline')::timestamptz = pg_temp.ts(pg_temp.d10(), '07:00')) from c1), true, 'the deadline is the handover start + 60 minutes');
-- notes and last actions
insert into public.handover_note (tenant_id, issue_id, author_id, shift_id, shift_date, note, at) values
  (pg_temp.id('tx'), pg_temp.id('i1'), pg_temp.id('s7'), pg_temp.id('night'), date '2026-03-09', 'First note', pg_temp.ts(date '2026-03-09', '23:00')),
  (pg_temp.id('tx'), pg_temp.id('i1'), pg_temp.id('s7'), pg_temp.id('night'), date '2026-03-09', 'Latest note', pg_temp.ts(date '2026-03-10', '02:00'));
insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, notes, status_before, status_after, at)
select pg_temp.id('tx'), pg_temp.id('i1'), pg_temp.id('s7'), 'supervisor', 'note', 'Action ' || n, 'open', 'open', pg_temp.ts(date '2026-03-09', '12:00') + make_interval(mins => n) from generate_series(1, 5) n;
create temp table c2 as select app.handover_checklist_at(pg_temp.ts(pg_temp.d10(), '06:10')) as j;
select is((select it -> 'note' ->> 'note' from c2, jsonb_array_elements(j -> 'occurrences' -> 0 -> 'machines' -> 0 -> 'items') t(it) where it ->> 'description' = 'Issue i1'), 'Latest note', 'the latest outgoing note is shown');
select is((select it -> 'note' ->> 'author_name' from c2, jsonb_array_elements(j -> 'occurrences' -> 0 -> 'machines' -> 0 -> 'items') t(it) where it ->> 'description' = 'Issue i1'), 'Sup Seven', 'with its author');
select is((select it -> 'note' from c2, jsonb_array_elements(j -> 'occurrences' -> 0 -> 'machines' -> 0 -> 'items') t(it) where it ->> 'description' = 'Issue i1b'), 'null'::jsonb, 'an issue without a note has none');
select is((select jsonb_array_length(it -> 'last_actions') from c2, jsonb_array_elements(j -> 'occurrences' -> 0 -> 'machines' -> 0 -> 'items') t(it) where it ->> 'description' = 'Issue i1'), 3, 'at most the last 3 actions');
select is((select it -> 'last_actions' -> 0 ->> 'notes' from c2, jsonb_array_elements(j -> 'occurrences' -> 0 -> 'machines' -> 0 -> 'items') t(it) where it ->> 'description' = 'Issue i1'), 'Action 5', 'newest first');
-- verify section
select is((select jsonb_array_length(j -> 'verify') from c2), 1, '"Verify this fix": the resolved High issue s1 can verify (owner of the machine in an occurrence started after the resolve)');
select is((select j -> 'verify' -> 0 ->> 'description' from c2), 'Issue i10', 'it is the resolved fix');
select pg_temp.as_user('s2');
select is((select jsonb_array_length(app.handover_checklist_at(pg_temp.ts(pg_temp.d10(), '06:10')) -> 'verify')), 0, 'the resolver cannot verify it (not in their verify section)');
-- answers and declaring
select pg_temp.as_user('s1');
select pg_temp.ack('i1', 's1', 'day', 'acknowledged', pg_temp.ts(pg_temp.d10(), '06:20')); select pg_temp.ack('i1b', 's1', 'day', 'acknowledged', pg_temp.ts(pg_temp.d10(), '06:21'));
select pg_temp.ack('i10', 's1', 'day', 'acknowledged', pg_temp.ts(pg_temp.d10(), '06:22')); select pg_temp.ack('i9', 's1', 'day', 'acknowledged', pg_temp.ts(pg_temp.d10(), '06:23'));
select is((app.handover_checklist_at(pg_temp.ts(pg_temp.d10(), '06:24')) -> 'occurrences' -> 0 -> 'allowed_actions'), '["declare"]'::jsonb, 'when everything is answered the server offers the declaration');
select is((app.handover_checklist_at(pg_temp.ts(pg_temp.d10(), '06:24')) -> 'occurrences' -> 0 ->> 'pending_count'), '0', 'no pending');
select pg_temp.decl('s1', 'day', pg_temp.ts(pg_temp.d10(), '06:25'));
select is((app.handover_checklist_at(pg_temp.ts(pg_temp.d10(), '07:00')) -> 'occurrences' -> 0 ->> 'declared'), 'true', 'declared');
select is((app.handover_checklist_at(pg_temp.ts(pg_temp.d10(), '07:00')) -> 'occurrences' -> 0 ->> 'declared_at')::timestamptz, pg_temp.ts(pg_temp.d10(), '06:25'), 'with the declaration time');
select is(jsonb_array_length(app.handover_checklist_at(pg_temp.ts(pg_temp.d10(), '15:00')) -> 'occurrences'), 0, 'after the end a declared occurrence is gone');
select pg_temp.as_user('s4');
select is(jsonb_array_length(app.handover_checklist_at(pg_temp.ts(pg_temp.d10(), '15:00')) -> 'occurrences'), 1, 'an undeclared occurrence stays after the end (a late supervisor can still declare, D3)');
select is(jsonb_array_length(app.handover_checklist_at(pg_temp.ts(date '2026-03-11', '02:30')) -> 'occurrences'), 0, 'but not more than 12 hours after the end');
-- the other supervisors and roles
select is((app.handover_checklist_at(pg_temp.ts(pg_temp.d10(), '06:10')) -> 'occurrences' -> 0 -> 'machines' -> 0 ->> 'code'), 'M-4', 'a supervisor sees only their own machines');
select pg_temp.as_user('s7');
select is(jsonb_array_length(app.handover_checklist_at(pg_temp.ts(pg_temp.d10(), '06:10')) -> 'occurrences'), 0, 'a supervisor with no machine has an empty checklist');
select pg_temp.as_user('uax');
select is(app.handover_checklist_at(pg_temp.ts(pg_temp.d10(), '06:10')) ->> 'code', 'not_allowed', 'a Unit Admin has no checklist (denied)');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and source = 'rpc:handover_checklist' and reason = 'role'), 1, 'audited as a role denial');
select pg_temp.as_user('sy');
select is(jsonb_array_length(app.handover_checklist_at(pg_temp.ts(pg_temp.d10(), '06:10')) -> 'occurrences'), 0, 'another tenant''s supervisor sees nothing of this tenant');
select pg_temp.as_user('sa');
select is(app.handover_checklist_at(pg_temp.ts(pg_temp.d10(), '06:10')) ->> 'code', 'not_allowed', 'a Super Admin is denied');

-- Cover on the Eve shift: two sessions (AC-6, AC-8) -----------------------------------------------------------------------------------------------
insert into public.assignment_cover (tenant_id, shift_id, shift_date, machine_id, supervisor_id, reason, recorded_by, recorded_at) values
  (pg_temp.id('tx'), pg_temp.id('eve'), pg_temp.d10(), pg_temp.id('m8'), pg_temp.id('s2'), 'Sup One on leave', pg_temp.id('uax'), pg_temp.ts(pg_temp.d10(), '15:00'));
select pg_temp.as_user('s2');
create function pg_temp.eve(p_at timestamptz) returns jsonb language sql as $$ select o from jsonb_array_elements(app.handover_checklist_at(p_at) -> 'occurrences') o where o -> 'shift' ->> 'name' = 'Eve' $$;
select is((pg_temp.eve(pg_temp.ts(pg_temp.d10(), '15:10')) -> 'machines' -> 0 -> 'items' -> 0 ->> 'description'), 'Issue i8', 'the machine received by cover brings its issue');
select is((select count(*)::int from public.handover_session where supervisor_id = pg_temp.id('s2') and shift_id = pg_temp.id('eve')), 2, 'two sessions: the window start and the cover time');
select is((pg_temp.eve(pg_temp.ts(pg_temp.d10(), '15:10')) ->> 'deadline')::timestamptz, pg_temp.ts(pg_temp.d10(), '16:00'), 'the deadline counts from the cover time');

-- Compliance (AC-12) ----------------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('uax');
select pg_temp.ack('i2', 's2', 'day', 'acknowledged', pg_temp.ts(pg_temp.d10(), '06:30')); select pg_temp.ack('i2b', 's2', 'day', 'acknowledged', pg_temp.ts(pg_temp.d10(), '08:05'));
select pg_temp.decl('s2', 'day', pg_temp.ts(pg_temp.d10(), '08:05'));
select pg_temp.ack('i3', 's3', 'day', 'acknowledged', pg_temp.ts(pg_temp.d10(), '06:10'));
select pg_temp.ack('i4', 's4', 'day', 'refused', pg_temp.ts(pg_temp.d10(), '06:15')); select pg_temp.decl('s4', 'day', pg_temp.ts(pg_temp.d10(), '06:20'));
select pg_temp.ack('i5', 's5', 'day', 'refused', pg_temp.ts(pg_temp.d10(), '06:16')); select pg_temp.decl('s5', 'day', pg_temp.ts(pg_temp.d10(), '06:20'));
insert into public.handover_exception (tenant_id, issue_id, shift_id, shift_date, ua_id, reason, owner_id, kept, at) values
  (pg_temp.id('tx'), pg_temp.id('i5'), pg_temp.id('day'), pg_temp.d10(), pg_temp.id('uax'), 'Keep with Sup Seven', pg_temp.id('s7'), true, pg_temp.ts(pg_temp.d10(), '09:00'));
select pg_temp.decl('s6', 'day', pg_temp.ts(pg_temp.d10(), '06:30'));
select is((pg_temp.comp('s1', 'day') ->> 'compliant')::boolean, true, 'compliant: every issue acknowledged and the declaration made before the deadline');
select is(pg_temp.comp('s1', 'day') ->> 'issues' || '/' || (pg_temp.comp('s1', 'day') ->> 'answered_in_time') || '/' || (pg_temp.comp('s1', 'day') ->> 'overdue_acks'), '4/4/0', 'four issues, four in time, none overdue');
select is(pg_temp.comp('s1', 'day') ->> 'reason', null, 'no reason when compliant');
select is((pg_temp.comp('s2', 'day') ->> 'compliant')::boolean, false, 'not compliant: declared after the deadline');
select is(pg_temp.comp('s2', 'day') ->> 'reason', 'late', 'reason late');
select is((pg_temp.comp('s2', 'day') ->> 'overdue_acks')::int, 1, 'one overdue acknowledgement (answered at 08:05, deadline 07:00)');
select is((pg_temp.comp('s3', 'day') ->> 'compliant')::boolean, false, 'not compliant: no declaration');
select is(pg_temp.comp('s3', 'day') ->> 'reason', 'no_declaration', 'reason no_declaration');
select is((pg_temp.comp('s3', 'day') ->> 'overdue_acks')::int, 1, 'and the unanswered issue counts as overdue');
select is(pg_temp.comp('s4', 'day') ->> 'reason', 'exception_missing', 'a refusal with no exception recorded: exception_missing');
select is((pg_temp.comp('s4', 'day') ->> 'refused_without_exception')::int, 1, 'counted');
select is((pg_temp.comp('s5', 'day') ->> 'compliant')::boolean, true, 'a refusal with an exception recorded (even later) is compliant');
select is((pg_temp.comp('s6', 'day') ->> 'compliant')::boolean, true, 'an issue closed before its deadline without an answer drops out');
select is((pg_temp.comp('s6', 'day') ->> 'issues')::int, 0, 'the dropped issue is not counted');
select is((select count(*)::int from app.handover_compliance_at(pg_temp.id('tx'), pg_temp.d10(), pg_temp.d10(), pg_temp.ts(date '2026-03-11', '00:00')) where shift_id = pg_temp.id('day')), 6, 'one row per supervisor with machines in the occurrence (s1..s6)');
select is((select count(*)::int from app.handover_compliance_at(pg_temp.id('tx'), pg_temp.d10(), pg_temp.d10(), pg_temp.ts(pg_temp.d10(), '12:00'))), 0, 'occurrences that have not ended are not counted');
select is((select count(*)::int from app.handover_compliance_at(pg_temp.id('tx'), pg_temp.d10(), pg_temp.d10(), pg_temp.ts(date '2026-03-11', '00:00')) c where c.supervisor_id = pg_temp.id('s7')), 0, 'the unassigned machine (M-7) and the previous owner count for nobody');
-- the overdue minutes snapshotted when the checklist opened keep deciding the deadline after the setting changes (AC-8)
update public.handover_setting set overdue_minutes = 15 where tenant_id = pg_temp.id('tx');
select is((pg_temp.comp('s1', 'day') ->> 'deadline')::timestamptz, pg_temp.ts(pg_temp.d10(), '07:00'), 'a changed setting (15) does not move the deadline of an occurrence whose checklist was already opened (snapshot 60)');
select is((pg_temp.comp('s1', 'day') ->> 'compliant')::boolean, true, 'so s1 stays compliant');
select is(pg_temp.comp('s5', 'day') ->> 'reason', 'late', 'while a supervisor who never opened the checklist is judged by the current setting (declared 06:20, deadline 06:15)');
update public.handover_setting set overdue_minutes = 60 where tenant_id = pg_temp.id('tx');
-- cover time: s2's Eve (cover 15:00, deadline 16:00): the 14:30 declaration is stale
select pg_temp.decl('s2', 'eve', pg_temp.ts(pg_temp.d10(), '14:30'));
select pg_temp.ack('i8', 's2', 'eve', 'acknowledged', pg_temp.ts(pg_temp.d10(), '15:20'));
select is(pg_temp.comp('s2', 'eve') ->> 'reason', 'no_declaration', 'AC-6: a declaration made before the cover time does not count');
select pg_temp.decl('s2', 'eve', pg_temp.ts(pg_temp.d10(), '15:30'));
select is((pg_temp.comp('s2', 'eve') ->> 'compliant')::boolean, true, 'declared again after the cover, before cover time + 60 minutes: compliant');
select is((pg_temp.comp('s2', 'eve') ->> 'deadline')::timestamptz, pg_temp.ts(pg_temp.d10(), '16:00'), 'with the deadline counted from the cover time');
select is((select count(*)::int from app.handover_compliance_at(pg_temp.id('tx'), pg_temp.d10(), pg_temp.d10(), pg_temp.ts(date '2026-03-11', '00:00')) c where c.shift_id = pg_temp.id('eve') and c.supervisor_id = pg_temp.id('s1')), 0, 'the planned supervisor who lost the machine to the cover has no Eve row');
select throws_ok($$ select * from app.handover_compliance_at('50000000-0000-4000-c803-00000000000a', date '2026-03-12', date '2026-03-10', now()) $$, 'P0001', null, 'a reversed range is refused');
select throws_ok($$ select * from app.handover_compliance_at('50000000-0000-4000-c803-00000000000a', date '2026-01-01', date '2026-06-01', now()) $$, 'P0001', null, 'and a range over 93 days');
select is((select count(*)::int from app.handover_compliance_at(pg_temp.id('ty'), pg_temp.d10(), pg_temp.d10(), pg_temp.ts(date '2026-03-11', '00:00'))), 0, 'another tenant''s compliance contains none of this tenant''s rows');

-- Alerts (AC-9) ----------------------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('uax');
create temp table a1 as select app.handover_alerts_at(pg_temp.ts(pg_temp.d10(), '08:00')) as j;
select is((select j ->> 'ok' from a1), 'true', 'a Unit Admin reads the handover alerts');
select is((select j ->> 'exceptions_total' from a1), '2', 'two refusals wait for an exception at 08:00 (i4, i5: s5''s exception comes at 09:00)');
select is((select string_agg(e ->> 'description', ',' order by ord) from a1, jsonb_array_elements(j -> 'exceptions') with ordinality t(e, ord) where e ->> 'description' in ('Issue i4', 'Issue i5')), 'Issue i4,Issue i5', 'oldest first (a tie is ordered by id)');
select is((select e ->> 'supervisor_name' || ',' || (e ->> 'machine_code') || ',' || (e ->> 'reason') from a1, jsonb_array_elements(j -> 'exceptions') t(e) where e ->> 'description' = 'Issue i4'), 'Sup Four,M-4,No', 'each shows who refused, the machine and the reason');
select is((select j ->> 'overdue_total' from a1), '2', 'two overdue acknowledgements at 08:00 (i2b and i3b)');
select is((select string_agg(e ->> 'description', ',' order by e ->> 'description') from a1, jsonb_array_elements(j -> 'overdue') t(e)), 'Issue i2b,Issue i3b', 'they are the unanswered ones');
select is((select (e ->> 'minutes_overdue')::int from a1, jsonb_array_elements(j -> 'overdue') t(e) where e ->> 'description' = 'Issue i3b'), 60, 'minutes overdue = 08:00 - 07:00');
select is((select e ->> 'supervisor_name' from a1, jsonb_array_elements(j -> 'overdue') t(e) where e ->> 'description' = 'Issue i3b'), 'Sup Three', 'with the supervisor');
select is((select j ->> 'alert_count' from a1), '4', 'alert_count = exceptions + overdue');
select is((select (app.handover_alerts_at(pg_temp.ts(pg_temp.d10(), '09:30')) ->> 'exceptions_total')), '1', 'at 09:30 the recorded exception has cleared i5');
select is((select (app.handover_alerts_at(pg_temp.ts(pg_temp.d10(), '06:30')) ->> 'overdue_total')), '0', 'before the deadlines nothing is overdue');
select is((select (app.handover_alerts_at(pg_temp.ts(date '2026-03-11', '04:00')) ->> 'overdue_total')), '0', 'more than 12 hours after the end the item belongs to the compliance report, not the alerts');
select pg_temp.as_user('s1');
select is(app.handover_alerts_at(pg_temp.ts(pg_temp.d10(), '08:00')) ->> 'code', 'not_allowed', 'a supervisor cannot read the alerts');
select pg_temp.as_user('uay');
select is((app.handover_alerts_at(pg_temp.ts(pg_temp.d10(), '08:00')) ->> 'alert_count'), '0', 'another tenant''s Unit Admin sees none of them');
select pg_temp.as_user('sa');
select is(app.handover_alerts_at(pg_temp.ts(pg_temp.d10(), '08:00')) ->> 'code', 'not_allowed', 'a Super Admin is denied');
-- bounded
reset role;
insert into public.issue_acknowledgement (tenant_id, issue_id, shift_id, shift_date, supervisor_id, kind, remark, at)
select pg_temp.id('tx'), pg_temp.id('i2'), pg_temp.id('day'), date '2026-03-10' - n, pg_temp.id('s2'), 'refused', 'bulk', pg_temp.ts(date '2026-03-10', '07:00') - make_interval(hours => n) from generate_series(1, 60) n;
select pg_temp.as_user('uax');
select is((select jsonb_array_length(app.handover_alerts_at(pg_temp.ts(pg_temp.d10(), '08:00')) -> 'exceptions')), 50, 'the exception list is bounded to 50');
select ok((select (app.handover_alerts_at(pg_temp.ts(pg_temp.d10(), '08:00')) ->> 'exceptions_total')::int) >= 62, 'with the true total alongside');

-- Public reads: no client time, generic denial for strangers ---------------------------------------------------------------------------------------
select is(pg_get_function_arguments('public.handover_checklist()'::regprocedure), '', 'public.handover_checklist takes no arguments (no client time)');
select is(pg_get_function_arguments('public.handover_alerts()'::regprocedure), '', 'public.handover_alerts takes no arguments (no client time)');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname in ('handover_checklist', 'handover_alerts') and p.pronargs > 0), 0, 'no overload with arguments');
select is(has_function_privilege('anon', 'public.handover_checklist()', 'execute'), false, 'anon cannot execute them');
select is(has_function_privilege('authenticated', 'app.handover_checklist_at(timestamptz)', 'execute'), false, 'nor can a client execute the _at bodies');
select is(has_function_privilege('authenticated', 'app.handover_compliance(uuid, date, date)', 'execute'), false, 'nor the compliance function (app-only)');
select pg_temp.as_user('sa');
select is(public.handover_checklist() ->> 'code', 'not_allowed', 'the public checklist denies a Super Admin');
select is(public.handover_alerts() ->> 'code', 'not_allowed', 'and so does the alerts read');
select pg_temp.as_user('s1');
select is(public.handover_checklist() ->> 'ok', 'true', 'a supervisor reads the checklist with no arguments');
select pg_temp.as_user('uax');
select is(public.handover_alerts() ->> 'ok', 'true', 'a Unit Admin reads the alerts with no arguments');

-- NFR timing on a seeded volume (explicit moment, 300 machines) -----------------------------------------------------------------------------------
reset role;
insert into public.tenant (id, name, status, timezone) values ('50000000-0000-4000-c803-0000000000c0', 'tap63 volume', 'active', 'Asia/Kolkata');
insert into public.handover_setting (tenant_id, required) values ('50000000-0000-4000-c803-0000000000c0', true);
insert into auth.users (id, email, aud, role) select ('00000000-0000-4000-c803-0000000001' || lpad(n::text, 2, '0'))::uuid, 'tap63-v' || n || '@example.test', 'authenticated', 'authenticated' from generate_series(0, 10) n;
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password)
select '50000000-0000-4000-c803-0000000000c0', ('00000000-0000-4000-c803-0000000001' || lpad(n::text, 2, '0'))::uuid, (case when n = 0 then 'unit_admin' else 'supervisor' end)::public.member_role, 'active', 'Vol ' || n, 'V' || n, '+9190000284' || lpad((20 + n)::text, 2, '0'), false from generate_series(0, 10) n;
insert into public.site (id, tenant_id, name, timezone) values ('51000000-0000-4000-c803-0000000000c0', '50000000-0000-4000-c803-0000000000c0', 'Plant V', 'Asia/Kolkata');
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time) values ('52000000-0000-4000-c803-0000000000c0', '50000000-0000-4000-c803-0000000000c0', '51000000-0000-4000-c803-0000000000c0', 'Day', '06:00', '14:00');
insert into public.machine (id, tenant_id, site_id, code, name)
select ('53000000-0000-4000-c803-000000000' || lpad(n::text, 3, '0'))::uuid, '50000000-0000-4000-c803-0000000000c0', '51000000-0000-4000-c803-0000000000c0', 'V-' || n, 'Vol ' || n from generate_series(1, 300) n;
insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by)
select '50000000-0000-4000-c803-0000000000c0', '52000000-0000-4000-c803-0000000000c0', ('53000000-0000-4000-c803-000000000' || lpad(n::text, 3, '0'))::uuid,
       ('00000000-0000-4000-c803-0000000001' || lpad((1 + n % 10)::text, 2, '0'))::uuid, date '2026-01-01', '00000000-0000-4000-c803-000000000100' from generate_series(1, 300) n;
insert into public.machine_issue (tenant_id, machine_id, category_id, priority, description, reported_by, accountable_owner_id, reported_at)
select '50000000-0000-4000-c803-0000000000c0', ('53000000-0000-4000-c803-000000000' || lpad(n::text, 3, '0'))::uuid, c.id, 'medium', 'Vol issue ' || n,
       '00000000-0000-4000-c803-000000000101', '00000000-0000-4000-c803-000000000101', pg_temp.ts(date '2026-03-09', '10:00')
  from generate_series(1, 200) n cross join lateral (select id from public.issue_category where tenant_id = '50000000-0000-4000-c803-0000000000c0' limit 1) c;
create temp table timing (k text, ms numeric);
grant all on timing to authenticated;
create function pg_temp.time_it(k text, q text) returns void language plpgsql as $$
declare t0 timestamptz := clock_timestamp();
begin execute q; insert into timing values (k, extract(epoch from clock_timestamp() - t0) * 1000); end $$;
select pg_temp.as_user('uax');
create temp table vu as select '00000000-0000-4000-c803-000000000100'::uuid as ua;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c803-000000000100","role":"authenticated"}', true);
select pg_temp.time_it('alerts', $$ select app.handover_alerts_at('2026-03-10 08:00+05:30') $$);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-c803-000000000102","role":"authenticated"}', true);
select pg_temp.time_it('checklist', $$ select app.handover_checklist_at('2026-03-10 06:10+05:30') $$);
select is((select jsonb_array_length(app.handover_checklist_at('2026-03-10 06:10+05:30' ) -> 'occurrences' -> 0 -> 'machines' -> 0 -> 'items')), 1, 'volume: the supervisor has issues on their machines');
select ok((select ms from timing where k = 'checklist') <= 500, 'NFR: a checklist with 20 issues in 500 ms or less (measured ' || (select round(ms)::text from timing where k = 'checklist') || ' ms)');
select ok((select ms from timing where k = 'alerts') <= 500, 'NFR: handover_alerts for 300 machines in 500 ms or less (measured ' || (select round(ms)::text from timing where k = 'alerts') || ' ms)');

select * from finish();
rollback;
