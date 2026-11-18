-- 08 step 3 (AC-2..AC-8, AC-10, AC-13, D3, D5, D6): ho_acknowledge / ho_refuse / ho_declare / ho_add_note / ho_exception / ho_set_overdue and the
-- rd_opening gate. Windows (30 min before the start .. end + 12 h; notes start .. end + 2 h), who may act (owner, other supervisor, Unit Admin,
-- inactive, temporary password, Super Admin, stranger, cross-tenant ids), idempotency, ownership transfer (source handover), escalation on refusal,
-- exception owner / keep, the opening gate (enforced / unenforced / Unit Admin on behalf / stale declaration after a cover), audit.
-- Self-contained; rolled back. Every case builds its shift relative to now() on the 15-minute grid (write RPCs use now(); no clock override).
begin;
create extension if not exists pgtap with schema extensions;
select plan(136);

create temp table ids (k text primary key, v uuid);
create temp table dates (k text primary key, d date);
create function pg_temp.id(k text) returns uuid language sql as $$ select v from ids where k = $1 $$;
create function pg_temp.d(k text) returns date language sql as $$ select d from dates where k = $1 $$;
create function pg_temp.rq(n int) returns uuid language sql as $$ select ('a1000000-0000-4000-c802-' || lpad(n::text, 12, '0'))::uuid $$;
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
create function pg_temp.n_audit(a text) returns int language sql as $$ select count(*)::int from public.audit_event where action = a and tenant_id = pg_temp.id('tx') $$;
create function pg_temp.n_denied(src text, why text) returns int language sql as $$
  select count(*)::int from public.audit_event where action = 'access.denied' and source = src and reason = why $$;
create function pg_temp.f15(ts timestamptz) returns timestamptz language sql immutable as $$ select to_timestamp(floor(extract(epoch from ts) / 900) * 900) $$;
-- A shift starting off_min minutes from the current 15-minute mark and lasting `hours` (key sh_<k>, date <k>) in tenant `ten`'s site.
create function pg_temp.mk_shift(k text, off_min int, hours int, ten text default 'tx') returns void language plpgsql as $$
declare
  v_start timestamptz := pg_temp.f15(now()) + make_interval(mins => off_min);
  v_s uuid := gen_random_uuid();
begin
  insert into public.shift (id, tenant_id, site_id, name, start_time, end_time)
  values (v_s, pg_temp.id(ten), pg_temp.id('site_' || ten), 'S-' || k, (v_start at time zone 'Asia/Kolkata')::time, ((v_start + make_interval(hours => hours)) at time zone 'Asia/Kolkata')::time);
  insert into ids values ('sh_' || k, v_s);
  insert into dates values (k, (v_start at time zone 'Asia/Kolkata')::date);
end $$;
-- A machine (key m_<mk>) planned for sup (null = unassigned) on shift key <sk>.
create function pg_temp.mk_machine(mk text, sk text, sup text, ten text default 'tx') returns void language plpgsql as $$
declare v_m uuid := gen_random_uuid();
begin
  insert into public.machine (id, tenant_id, site_id, code, name) values (v_m, pg_temp.id(ten), pg_temp.id('site_' || ten), 'C-' || mk, 'Case ' || mk);
  insert into ids values ('m_' || mk, v_m);
  if sup is not null then
    insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by)
    values (pg_temp.id(ten), pg_temp.id('sh_' || sk), v_m, pg_temp.id(sup), date '2026-01-01', pg_temp.id(case ten when 'tx' then 'uax' when 'tu' then 'uau' else 'uay' end));
  end if;
end $$;
create function pg_temp.mk(k text, off_min int, hours int, sup text, ten text default 'tx') returns void language plpgsql as $$
begin perform pg_temp.mk_shift(k, off_min, hours, ten); perform pg_temp.mk_machine(k, k, sup, ten); end $$;
-- An issue (key) on machine <mk>, owned by `own`, reported `age` ago, in a status.
create function pg_temp.mk_issue(k text, mk text, own text, age interval default interval '1 day', st text default 'open', esc boolean default false, ten text default 'tx') returns void language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into public.machine_issue (id, tenant_id, machine_id, category_id, priority, description, reported_by, accountable_owner_id, reported_at, status, escalated_at,
                                    resolved_at, resolved_by, closed_at, closed_by)
  select v, pg_temp.id(ten), pg_temp.id('m_' || mk), c.id, 'high', 'Issue ' || k, pg_temp.id(own), pg_temp.id(own), now() - age, st, case when esc then now() - interval '1 hour' end,
         case when st in ('resolved', 'closed') then now() - interval '2 hours' end, case when st in ('resolved', 'closed') then pg_temp.id(own) end,
         case when st = 'closed' then now() - interval '1 hour' end, case when st = 'closed' then pg_temp.id(own) end
    from public.issue_category c where c.tenant_id = pg_temp.id(ten) limit 1;
  insert into ids values (k, v);
  insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, status_after, at) values (pg_temp.id(ten), v, pg_temp.id(own), 'supervisor', 'report', 'open', now() - age);
end $$;
create function pg_temp.owner_of(i text) returns uuid language sql as $$ select accountable_owner_id from public.machine_issue where id = pg_temp.id(i) $$;

-- Fixtures (as postgres) ------------------------------------------------------------------------------------------------------------
insert into auth.users (id, email, aud, role)
select u, 'tap62-' || n || '@example.test', 'authenticated', 'authenticated' from (values
  ('00000000-0000-4000-c802-0000000000a1'::uuid, 'uax'), ('00000000-0000-4000-c802-0000000000a2', 's1'), ('00000000-0000-4000-c802-0000000000a3', 's2'),
  ('00000000-0000-4000-c802-0000000000a4', 'sinact'), ('00000000-0000-4000-c802-0000000000a5', 'sfresh'), ('00000000-0000-4000-c802-0000000000b1', 'uay'),
  ('00000000-0000-4000-c802-0000000000b2', 'sy'), ('00000000-0000-4000-c802-0000000000d1', 'uau'), ('00000000-0000-4000-c802-0000000000d2', 'su'),
  ('00000000-0000-4000-c802-0000000000c1', 'nomem'), ('00000000-0000-4000-c802-0000000000f1', 'sa')) t(u, n);
insert into ids values ('uax', '00000000-0000-4000-c802-0000000000a1'), ('s1', '00000000-0000-4000-c802-0000000000a2'), ('s2', '00000000-0000-4000-c802-0000000000a3'),
  ('sinact', '00000000-0000-4000-c802-0000000000a4'), ('sfresh', '00000000-0000-4000-c802-0000000000a5'), ('uay', '00000000-0000-4000-c802-0000000000b1'),
  ('sy', '00000000-0000-4000-c802-0000000000b2'), ('uau', '00000000-0000-4000-c802-0000000000d1'), ('su', '00000000-0000-4000-c802-0000000000d2'),
  ('nomem', '00000000-0000-4000-c802-0000000000c1'), ('sa', '00000000-0000-4000-c802-0000000000f1'),
  ('tx', '50000000-0000-4000-c802-00000000000a'), ('ty', '50000000-0000-4000-c802-00000000000b'), ('tu', '50000000-0000-4000-c802-00000000000d');
insert into public.tenant (id, name, status, timezone) values
  ('50000000-0000-4000-c802-00000000000a', 'tap62 org X', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c802-00000000000b', 'tap62 org Y', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c802-00000000000d', 'tap62 org U (not enforced)', 'active', 'Asia/Kolkata');
insert into public.handover_setting (tenant_id, required) values (pg_temp.id('tx'), true), (pg_temp.id('ty'), true); -- U has no row: not gated (D1)
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('50000000-0000-4000-c802-00000000000a', '00000000-0000-4000-c802-0000000000a1', 'unit_admin', 'active', 'UA X', 'UA-X', '+919000028301', false),
  ('50000000-0000-4000-c802-00000000000a', '00000000-0000-4000-c802-0000000000a2', 'supervisor', 'active', 'Sup One', 'S1', '+919000028302', false),
  ('50000000-0000-4000-c802-00000000000a', '00000000-0000-4000-c802-0000000000a3', 'supervisor', 'active', 'Sup Two', 'S2', '+919000028303', false),
  ('50000000-0000-4000-c802-00000000000a', '00000000-0000-4000-c802-0000000000a4', 'supervisor', 'inactive', 'Sup Gone', 'S3', '+919000028304', false),
  ('50000000-0000-4000-c802-00000000000a', '00000000-0000-4000-c802-0000000000a5', 'supervisor', 'active', 'Sup Fresh', 'S4', '+919000028305', true),
  ('50000000-0000-4000-c802-00000000000b', '00000000-0000-4000-c802-0000000000b1', 'unit_admin', 'active', 'UA Y', 'UA-Y', '+919000028306', false),
  ('50000000-0000-4000-c802-00000000000b', '00000000-0000-4000-c802-0000000000b2', 'supervisor', 'active', 'Sup Y', 'SY', '+919000028307', false),
  ('50000000-0000-4000-c802-00000000000d', '00000000-0000-4000-c802-0000000000d1', 'unit_admin', 'active', 'UA U', 'UA-U', '+919000028308', false),
  ('50000000-0000-4000-c802-00000000000d', '00000000-0000-4000-c802-0000000000d2', 'supervisor', 'active', 'Sup U', 'SU', '+919000028309', false);
insert into public.platform_admin (user_id, full_name, phone_e164, status, must_change_password) values ('00000000-0000-4000-c802-0000000000f1', 'SA 62', '+919000028310', 'active', false);
insert into public.site (id, tenant_id, name, timezone) values
  ('51000000-0000-4000-c802-00000000000a', pg_temp.id('tx'), 'Plant X', 'Asia/Kolkata'), ('51000000-0000-4000-c802-00000000000b', pg_temp.id('ty'), 'Plant Y', 'Asia/Kolkata'),
  ('51000000-0000-4000-c802-00000000000d', pg_temp.id('tu'), 'Plant U', 'Asia/Kolkata');
insert into ids values ('site_tx', '51000000-0000-4000-c802-00000000000a'), ('site_ty', '51000000-0000-4000-c802-00000000000b'), ('site_tu', '51000000-0000-4000-c802-00000000000d');
insert into public.product (id, tenant_id, code, description) values
  ('54000000-0000-4000-c802-0000000000a1', pg_temp.id('tx'), 'P-1', 'Part 1'), ('54000000-0000-4000-c802-0000000000d1', pg_temp.id('tu'), 'U-P', 'U part');
insert into ids values ('p1', '54000000-0000-4000-c802-0000000000a1'), ('pu', '54000000-0000-4000-c802-0000000000d1');
grant select on ids, dates to authenticated, anon;

-- Case 'a': running shift, s1's machine, issues inherited from s2 (the previous owner)
select pg_temp.mk('a', -30, 8, 's1');
select pg_temp.mk_issue('iA', 'a', 's2');
select pg_temp.mk_issue('iB', 'a', 's1');
select pg_temp.mk_issue('iC', 'a', 's2');
select pg_temp.mk_issue('iD', 'a', 's2', interval '1 day', 'open', true);
select pg_temp.mk_issue('iE', 'a', 's2', interval '1 day', 'resolved');
select pg_temp.mk_issue('iF', 'a', 's2', interval '1 minute');
select pg_temp.mk_issue('iG', 'a', 's2', interval '1 day', 'closed');
select pg_temp.mk('b', -30, 8, 's1');               -- no issues
select pg_temp.mk('c', -30, 8, 's1');               -- the opening gate
select pg_temp.mk('cu', -30, 8, 'su', 'tu');        -- not enforced tenant
select pg_temp.mk('ua', -30, 8, 's1');              -- Unit Admin on behalf
select pg_temp.mk('d', -30, 8, 's1');               -- exception cases
select pg_temp.mk_issue('xA', 'd', 's2'); select pg_temp.mk_issue('xB', 'd', 's2'); select pg_temp.mk_issue('xC', 'd', 's1'); select pg_temp.mk_issue('xD', 'd', 's2'); select pg_temp.mk_issue('xE', 'd', 's2');
select pg_temp.mk('n', -30, 8, 's1');               -- notes
select pg_temp.mk_issue('nA', 'n', 's1'); select pg_temp.mk_issue('nB', 'n', 's1', interval '1 day', 'resolved'); select pg_temp.mk_issue('nC', 'n', 's1', interval '1 day', 'closed');
select pg_temp.mk('pre60', 60, 8, 's1'); select pg_temp.mk_issue('wP60', 'pre60', 's2');
select pg_temp.mk('pre20', 15, 8, 's1'); select pg_temp.mk_issue('wP20', 'pre20', 's2');
select pg_temp.mk('old13', -840, 1, 's1'); select pg_temp.mk_issue('wO13', 'old13', 's2', interval '2 days');
select pg_temp.mk('old11', -720, 1, 's1'); select pg_temp.mk_issue('wO11', 'old11', 's2', interval '2 days');
select pg_temp.mk('end1', -120, 1, 's1'); select pg_temp.mk_issue('nE1', 'end1', 's1');
select pg_temp.mk('end3', -240, 1, 's1'); select pg_temp.mk_issue('nE3', 'end3', 's1');
select pg_temp.mk('fut', 30, 8, 's1'); select pg_temp.mk_issue('nF', 'fut', 's1');
select pg_temp.mk('y', -30, 8, 'sy', 'ty'); select pg_temp.mk_issue('yI', 'y', 'sy', interval '1 day', 'open', false, 'ty');
-- cover case: shift started 45 min ago with two machines; s2 planned on cv2 (issue yC on cv1 owned by s1's machine, covered to s2 later)
select pg_temp.mk_shift('cv', -45, 8);
select pg_temp.mk_machine('cv1', 'cv', 's1'); select pg_temp.mk_machine('cv2', 'cv', 's2');
select pg_temp.mk_issue('cvA', 'cv1', 's1');

-- Acknowledge (AC-2) -----------------------------------------------------------------------------------------------------------
select pg_temp.as_user('s1');
select is(public.ho_acknowledge(pg_temp.rq(1), pg_temp.id('iA'), pg_temp.id('sh_a'), pg_temp.d('a'), '  Taking it  ') ->> 'ok', 'true', 'the owner of the machine acknowledges an inherited issue');
select is((select kind || ':' || remark from public.issue_acknowledgement where request_id = pg_temp.rq(1)), 'acknowledged:Taking it', 'an acknowledgement row with the trimmed remark');
select is(pg_temp.owner_of('iA'), pg_temp.id('s1'), 'the supervisor is now the accountable owner');
select is((select previous_owner || '>' || new_owner || ':' || source from public.issue_ownership_history where issue_id = pg_temp.id('iA') and source = 'handover'),
  pg_temp.id('s2')::text || '>' || pg_temp.id('s1')::text || ':handover', 'a 07 ownership-history row with source handover');
select is((select notes from public.issue_action where issue_id = pg_temp.id('iA') and type = 'handover_ack'), 'Acknowledged at handover: Taking it', 'an issue action "Acknowledged at handover"');
select is(pg_temp.n_audit('handover.acknowledged'), 1, 'audited handover.acknowledged');
select is(public.ho_acknowledge(pg_temp.rq(1), pg_temp.id('iA'), pg_temp.id('sh_a'), pg_temp.d('a'), 'Taking it') ->> 'already', 'true', 'a replay returns the first outcome');
select is((select count(*)::int from public.issue_acknowledgement where issue_id = pg_temp.id('iA')), 1, 'and writes nothing more');
select is(public.ho_acknowledge(pg_temp.rq(1), pg_temp.id('iB'), pg_temp.id('sh_a'), pg_temp.d('a')) ->> 'already', 'true', 'the same RPC with the same request id is a replay even with other arguments: nothing is written for iB');
select is(pg_temp.err($$ select public.ho_refuse(pg_temp.rq(1), pg_temp.id('iC'), pg_temp.id('sh_a'), pg_temp.d('a'), 'x') $$) ->> 'field', 'request_id', 'a request id of another RPC is refused too');
select is(public.ho_acknowledge(pg_temp.rq(2), pg_temp.id('iB'), pg_temp.id('sh_a'), pg_temp.d('a')) ->> 'owner_changed', 'false', 'an issue the supervisor already owns: acknowledged, no ownership change');
select is((select count(*)::int from public.issue_ownership_history where issue_id = pg_temp.id('iB') and source = 'handover'), 0, 'and no ownership-history row');
select is((select remark is null from public.issue_acknowledgement where request_id = pg_temp.rq(2)), true, 'the remark is optional');
select is(pg_temp.err($$ select public.ho_acknowledge(pg_temp.rq(3), pg_temp.id('iA'), pg_temp.id('sh_a'), pg_temp.d('a')) $$) ->> 'field', 'already_recorded', 'a second answer for the same issue is refused');
select is(pg_temp.err($$ select public.ho_acknowledge(pg_temp.rq(4), pg_temp.id('iF'), pg_temp.id('sh_a'), pg_temp.d('a')) $$) ->> 'field', 'not_required', 'an issue reported during the occurrence is not on the checklist');
select is(pg_temp.err($$ select public.ho_acknowledge(pg_temp.rq(5), pg_temp.id('iG'), pg_temp.id('sh_a'), pg_temp.d('a')) $$) ->> 'field', 'not_required', 'a closed issue is not on the checklist');
select is(pg_temp.err($$ select public.ho_acknowledge(pg_temp.rq(6), pg_temp.id('iC'), pg_temp.id('sh_a'), pg_temp.d('a'), repeat('x', 201)) $$) ->> 'field', 'remark', 'a remark is at most 200 characters');
select is(pg_temp.err($$ select public.ho_acknowledge(pg_temp.rq(7), pg_temp.id('iC'), pg_temp.id('sh_a'), null) $$) ->> 'field', 'shift_date', 'the date is required');

-- Refuse (AC-3) ---------------------------------------------------------------------------------------------------------------
select is(public.ho_refuse(pg_temp.rq(10), pg_temp.id('iC'), pg_temp.id('sh_a'), pg_temp.d('a'), '  Machine not mine  ') ->> 'escalated', 'true', 'a refusal escalates the issue');
select is((select kind || ':' || remark from public.issue_acknowledgement where request_id = pg_temp.rq(10)), 'refused:Machine not mine', 'a refusal row with the reason');
select is((select escalated_at is not null from public.machine_issue where id = pg_temp.id('iC')), true, 'the issue is escalated');
select is(pg_temp.owner_of('iC'), pg_temp.id('s2'), 'and the owner is unchanged');
select is((select string_agg(type, ',' order by type) from public.issue_action where issue_id = pg_temp.id('iC') and type in ('handover_refuse', 'escalate')), 'escalate,handover_refuse', 'both actions are appended');
select is(pg_temp.n_audit('handover.refused'), 1, 'audited handover.refused');
select is(public.ho_refuse(pg_temp.rq(11), pg_temp.id('iD'), pg_temp.id('sh_a'), pg_temp.d('a'), 'Already escalated') ->> 'escalated', 'false', 'an already escalated issue is not escalated twice');
select is((select count(*)::int from public.issue_action where issue_id = pg_temp.id('iD') and type = 'escalate'), 0, 'no second escalate action');
select is(public.ho_refuse(pg_temp.rq(12), pg_temp.id('iE'), pg_temp.id('sh_a'), pg_temp.d('a'), 'Fix not verified') ->> 'escalated', 'false', 'a fix awaiting verification can be refused without escalating');
select is(pg_temp.err($$ select public.ho_refuse(pg_temp.rq(13), pg_temp.id('iF'), pg_temp.id('sh_a'), pg_temp.d('a'), 'x') $$) ->> 'field', 'not_required', 'refusing an issue not on the checklist is refused');
select is(pg_temp.err($$ select public.ho_refuse(pg_temp.rq(14), pg_temp.id('iA'), pg_temp.id('sh_a'), pg_temp.d('a'), 'x') $$) ->> 'field', 'already_recorded', 'refusing after acknowledging is refused');
select is(pg_temp.err($$ select public.ho_refuse(pg_temp.rq(15), pg_temp.id('iG'), pg_temp.id('sh_a'), pg_temp.d('a'), '   ') $$) ->> 'field', 'reason', 'a reason is required');
select is(pg_temp.err($$ select public.ho_refuse(pg_temp.rq(16), pg_temp.id('iG'), pg_temp.id('sh_a'), pg_temp.d('a'), repeat('x', 201)) $$) ->> 'field', 'reason', 'a reason is at most 200 characters');

-- Declaration (AC-4, AC-5) -----------------------------------------------------------------------------------------------------
select is(app._ho_declared_at(pg_temp.id('s1'), pg_temp.id('sh_a'), pg_temp.d('a'), now()), false, 'not declared yet');
select is(public.ho_declare(pg_temp.rq(20), pg_temp.id('sh_a'), pg_temp.d('a')) ->> 'ok', 'true', 'when every issue is answered (acknowledged or refused) the supervisor declares: a refusal does not block');
select is((select cardinality(covered_issue_ids) from public.handover_declaration where request_id = pg_temp.rq(20)), 5, 'the declaration covers the five inherited issues (iA..iE)');
select is((select text_version from public.handover_declaration where request_id = pg_temp.rq(20)), 1, 'text version 1');
select is(pg_temp.n_audit('handover.declared'), 1, 'audited handover.declared');
select is(public.ho_declare(pg_temp.rq(20), pg_temp.id('sh_a'), pg_temp.d('a')) ->> 'already', 'true', 'a replay returns the first outcome');
select is(pg_temp.err($$ select public.ho_declare(pg_temp.rq(21), pg_temp.id('sh_a'), pg_temp.d('a')) $$) ->> 'field', 'already_declared', 'one declaration per supervisor and occurrence');
select is(public.ho_declare(pg_temp.rq(22), pg_temp.id('sh_b'), pg_temp.d('b')) ->> 'issues', '0', 'no inherited issues: the declaration is a single tap');
select is(app._ho_declared_at(pg_temp.id('s1'), pg_temp.id('sh_b'), pg_temp.d('b'), now()), true, 'and counts');

select pg_temp.mk('p', -30, 8, 's1'); select pg_temp.mk_issue('pA', 'p', 's2'); select pg_temp.mk_issue('pB', 'p', 's2');
select is(pg_temp.err($$ select public.ho_declare(pg_temp.rq(23), pg_temp.id('sh_p'), pg_temp.d('p')) $$) ->> 'field', 'items_pending', 'declaring with issues unanswered is refused');
select is(pg_temp.err($$ select public.ho_declare(pg_temp.rq(23), pg_temp.id('sh_p'), pg_temp.d('p')) $$) -> 'pending', '2'::jsonb, 'and says how many are pending');
select public.ho_acknowledge(pg_temp.rq(24), pg_temp.id('pA'), pg_temp.id('sh_p'), pg_temp.d('p'));
select is(pg_temp.err($$ select public.ho_declare(pg_temp.rq(25), pg_temp.id('sh_p'), pg_temp.d('p')) $$) -> 'pending', '1'::jsonb, 'one acknowledged: one still pending');

-- The rd_opening gate (AC-5, D6) -----------------------------------------------------------------------------------------------
select is(pg_temp.err($$ select public.rd_opening(pg_temp.rq(30), pg_temp.id('m_c'), pg_temp.id('sh_c'), pg_temp.d('c'), pg_temp.id('p1'), 100) $$) ->> 'field', 'handover_pending', 'AC-5: a supervisor cannot record the opening before declaring');
select is(pg_temp.err($$ select public.rd_opening(pg_temp.rq(30), pg_temp.id('m_c'), pg_temp.id('sh_c'), pg_temp.d('c'), pg_temp.id('p1'), 100) $$) ->> 'message', 'Complete your handover checklist first', 'with the message the screen shows');
select is((select count(*)::int from public.production_reading where machine_id = pg_temp.id('m_c')), 0, 'and no reading was written');
select public.ho_declare(pg_temp.rq(31), pg_temp.id('sh_c'), pg_temp.d('c'));
select is(public.rd_opening(pg_temp.rq(32), pg_temp.id('m_c'), pg_temp.id('sh_c'), pg_temp.d('c'), pg_temp.id('p1'), 100) ->> 'ok', 'true', 'after the declaration the opening is accepted');
select is(public.rd_opening(pg_temp.rq(33), pg_temp.id('m_a'), pg_temp.id('sh_a'), pg_temp.d('a'), pg_temp.id('p1'), 100) ->> 'ok', 'true', 'and for an occurrence declared with refusals');
select pg_temp.as_user('uax');
select is(public.rd_opening(pg_temp.rq(34), pg_temp.id('m_ua'), pg_temp.id('sh_ua'), pg_temp.d('ua'), pg_temp.id('p1'), 100) ->> 'entered_by_ua', 'true', 'a Unit Admin entering on the supervisor''s behalf is not blocked');
select pg_temp.as_user('su');
select is(public.rd_opening(pg_temp.rq(35), pg_temp.id('m_cu'), pg_temp.id('sh_cu'), pg_temp.d('cu'), pg_temp.id('pu'), 100) ->> 'ok', 'true', 'a tenant without an enforcement row (D1) is not gated');
select pg_temp.as_user('s1');
-- AC-6: a cover after the start makes an earlier declaration stale
insert into public.handover_declaration (tenant_id, shift_id, shift_date, supervisor_id, covered_issue_ids, at) values
  (pg_temp.id('tx'), pg_temp.id('sh_cv'), pg_temp.d('cv'), pg_temp.id('s2'), '{}', now() - interval '20 minutes');
select pg_temp.mk_machine('cv3', 'cv', 's1'); select pg_temp.mk_issue('cvB', 'cv3', 's1');
insert into public.assignment_cover (tenant_id, shift_id, shift_date, machine_id, supervisor_id, reason, recorded_by) values
  (pg_temp.id('tx'), pg_temp.id('sh_cv'), pg_temp.d('cv'), pg_temp.id('m_cv3'), pg_temp.id('s2'), 'Sup One on leave', pg_temp.id('uax'));
select pg_temp.as_user('s2');
select is(app._ho_declared_at(pg_temp.id('s2'), pg_temp.id('sh_cv'), pg_temp.d('cv'), now()), false, 'AC-6: the cover recorded after the start makes the earlier declaration stale');
select is(pg_temp.err($$ select public.rd_opening(pg_temp.rq(36), pg_temp.id('m_cv2'), pg_temp.id('sh_cv'), pg_temp.d('cv'), pg_temp.id('p1'), 100) $$) ->> 'field', 'handover_pending', 'so the opening is blocked again');
select is(pg_temp.err($$ select public.ho_declare(pg_temp.rq(37), pg_temp.id('sh_cv'), pg_temp.d('cv')) $$) ->> 'field', 'items_pending', 'the machine received by cover brings its issue: acknowledge first');
select is(public.ho_acknowledge(pg_temp.rq(38), pg_temp.id('cvB'), pg_temp.id('sh_cv'), pg_temp.d('cv')) ->> 'owner_changed', 'true', 'acknowledging it makes s2 accountable');
select is(public.ho_declare(pg_temp.rq(39), pg_temp.id('sh_cv'), pg_temp.d('cv')) ->> 'issues', '1', 'and a new declaration covers it');
select is((select count(*)::int from public.handover_declaration where supervisor_id = pg_temp.id('s2') and shift_id = pg_temp.id('sh_cv')), 2, 'the earlier declaration stays in history');
select is(public.rd_opening(pg_temp.rq(40), pg_temp.id('m_cv2'), pg_temp.id('sh_cv'), pg_temp.d('cv'), pg_temp.id('p1'), 100) ->> 'ok', 'true', 'and the opening is allowed again');

-- Windows (D3) ------------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('s1');
select is(pg_temp.err($$ select public.ho_acknowledge(pg_temp.rq(50), pg_temp.id('wP60'), pg_temp.id('sh_pre60'), pg_temp.d('pre60')) $$) ->> 'field', 'window_not_open', 'acknowledge: not 60 minutes before the start');
select is(public.ho_acknowledge(pg_temp.rq(51), pg_temp.id('wP20'), pg_temp.id('sh_pre20'), pg_temp.d('pre20')) ->> 'ok', 'true', 'acknowledge: up to 15 minutes before the start is inside the 30-minute window');
select is(public.ho_declare(pg_temp.rq(52), pg_temp.id('sh_pre20'), pg_temp.d('pre20')) ->> 'ok', 'true', 'declare: before the start counts');
select is(app._ho_declared_at(pg_temp.id('s1'), pg_temp.id('sh_pre20'), pg_temp.d('pre20'), now()), true, 'and is declared for the occurrence');
select is(pg_temp.err($$ select public.ho_declare(pg_temp.rq(53), pg_temp.id('sh_pre60'), pg_temp.d('pre60')) $$) ->> 'field', 'window_not_open', 'declare: not 60 minutes before the start');
select is(pg_temp.err($$ select public.ho_acknowledge(pg_temp.rq(54), pg_temp.id('wO13'), pg_temp.id('sh_old13'), pg_temp.d('old13')) $$) ->> 'field', 'window_closed', 'acknowledge: 13 hours after the end is closed');
select is(public.ho_acknowledge(pg_temp.rq(55), pg_temp.id('wO11'), pg_temp.id('sh_old11'), pg_temp.d('old11')) ->> 'ok', 'true', 'acknowledge: 11 hours after the end is still allowed (late)');
select is(public.ho_declare(pg_temp.rq(56), pg_temp.id('sh_old11'), pg_temp.d('old11')) ->> 'ok', 'true', 'declare: late declaring is accepted until end + 12 h');

-- Notes (AC-10) -----------------------------------------------------------------------------------------------------------------
select is(public.ho_add_note(pg_temp.rq(60), pg_temp.id('nA'), pg_temp.id('sh_n'), pg_temp.d('n'), '  Heater 2 is hot  ') ->> 'ok', 'true', 'the owner adds an outgoing note to an unresolved issue');
select is((select note from public.handover_note where request_id = pg_temp.rq(60)), 'Heater 2 is hot', 'trimmed');
select is(pg_temp.n_audit('handover.note_added'), 1, 'audited handover.note_added');
select is(public.ho_add_note(pg_temp.rq(60), pg_temp.id('nA'), pg_temp.id('sh_n'), pg_temp.d('n'), 'Heater 2 is hot') ->> 'already', 'true', 'a replay returns the first outcome');
select is(public.ho_add_note(pg_temp.rq(61), pg_temp.id('nA'), pg_temp.id('sh_n'), pg_temp.d('n'), 'Second note') ->> 'ok', 'true', 'notes are appended (the latest is shown)');
select is((select count(*)::int from public.handover_note where issue_id = pg_temp.id('nA')), 2, 'both are kept');
select is(pg_temp.err($$ select public.ho_add_note(pg_temp.rq(62), pg_temp.id('nB'), pg_temp.id('sh_n'), pg_temp.d('n'), 'x') $$) ->> 'field', 'invalid_status', 'not on a resolved issue');
select is(pg_temp.err($$ select public.ho_add_note(pg_temp.rq(63), pg_temp.id('nC'), pg_temp.id('sh_n'), pg_temp.d('n'), 'x') $$) ->> 'field', 'invalid_status', 'nor on a closed one');
select is(pg_temp.err($$ select public.ho_add_note(pg_temp.rq(64), pg_temp.id('nA'), pg_temp.id('sh_n'), pg_temp.d('n'), repeat('x', 301)) $$) ->> 'field', 'note', 'a note is at most 300 characters');
select is(pg_temp.err($$ select public.ho_add_note(pg_temp.rq(65), pg_temp.id('nA'), pg_temp.id('sh_n'), pg_temp.d('n'), '  ') $$) ->> 'field', 'note', 'and not empty');
select is(public.ho_add_note(pg_temp.rq(66), pg_temp.id('nE1'), pg_temp.id('sh_end1'), pg_temp.d('end1'), 'Late note') ->> 'ok', 'true', 'a note one hour after the end is inside the 2-hour window');
select is(pg_temp.err($$ select public.ho_add_note(pg_temp.rq(67), pg_temp.id('nE3'), pg_temp.id('sh_end3'), pg_temp.d('end3'), 'Too late') $$) ->> 'field', 'window_closed', 'but not 3 hours after the end');
select is(pg_temp.err($$ select public.ho_add_note(pg_temp.rq(68), pg_temp.id('nF'), pg_temp.id('sh_fut'), pg_temp.d('fut'), 'Too early') $$) ->> 'field', 'window_not_open', 'nor before the shift has started');
select pg_temp.as_user('s2');
select is(public.ho_add_note(pg_temp.rq(69), pg_temp.id('nA'), pg_temp.id('sh_n'), pg_temp.d('n'), 'Not mine') ->> 'code', 'not_allowed', 'another supervisor cannot add a note on a machine they do not own');
select is(pg_temp.n_denied('rpc:ho_add_note', 'not_owner'), 1, 'and it is audited');

-- Exception (AC-7) ----------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('s1');
select public.ho_refuse(pg_temp.rq(70), pg_temp.id('xA'), pg_temp.id('sh_d'), pg_temp.d('d'), 'Refuse A');
select public.ho_refuse(pg_temp.rq(71), pg_temp.id('xB'), pg_temp.id('sh_d'), pg_temp.d('d'), 'Refuse B');
select public.ho_refuse(pg_temp.rq(72), pg_temp.id('xC'), pg_temp.id('sh_d'), pg_temp.d('d'), 'Refuse C (own issue)');
select public.ho_refuse(pg_temp.rq(73), pg_temp.id('xD'), pg_temp.id('sh_d'), pg_temp.d('d'), 'Refuse D');
select is((select count(*)::int from app.handover_items_at(pg_temp.id('s1'), pg_temp.id('sh_d'), pg_temp.d('d'), now()) where exception_pending), 4, 'four refusals are exception pending');
select pg_temp.as_user('s2');
select is(public.ho_exception(pg_temp.rq(80), pg_temp.id('xA'), pg_temp.id('sh_d'), pg_temp.d('d'), 'x', pg_temp.id('s2')) ->> 'code', 'not_allowed', 'a supervisor cannot record an exception');
select is(pg_temp.n_denied('rpc:ho_exception', 'role'), 1, 'audited as a role denial');
select pg_temp.as_user('uax');
select is(public.ho_exception(pg_temp.rq(81), pg_temp.id('xA'), pg_temp.id('sh_d'), pg_temp.d('d'), '  Needs Sup Two  ', pg_temp.id('s2')) ->> 'kept', 'true', 'owner = the current accountable owner: kept');
select is((select kept::text || ':' || reason from public.handover_exception where request_id = pg_temp.rq(81)), 'true:Needs Sup Two', 'the exception row records reason and kept');
select is((select count(*)::int from public.issue_ownership_history where issue_id = pg_temp.id('xA') and source = 'reassign'), 0, 'keeping writes no ownership row');
select is(public.ho_exception(pg_temp.rq(82), pg_temp.id('xB'), pg_temp.id('sh_d'), pg_temp.d('d'), 'Give it to Sup One', pg_temp.id('s1')) ->> 'kept', 'false', 'another active supervisor: reassigned');
select is(pg_temp.owner_of('xB'), pg_temp.id('s1'), 'the owner changed');
select is((select source || ':' || reason from public.issue_ownership_history where issue_id = pg_temp.id('xB') and source = 'reassign'), 'reassign:Give it to Sup One', '07 ownership history, source reassign');
select is((select escalated_at is null from public.machine_issue where id = pg_temp.id('xB')), true, 'the reassignment clears the escalation (07)');
select is((select count(*)::int from public.issue_action where issue_id = pg_temp.id('xB') and type = 'reassign'), 1, 'and appends a reassign action');
select is(pg_temp.n_audit('handover.exception'), 2, 'audited handover.exception');
select is((select count(*)::int from app.handover_items_at(pg_temp.id('s1'), pg_temp.id('sh_d'), pg_temp.d('d'), now()) where exception_pending), 2, 'two exceptions recorded: two still pending');
select is(public.ho_exception(pg_temp.rq(81), pg_temp.id('xA'), pg_temp.id('sh_d'), pg_temp.d('d'), 'Needs Sup Two', pg_temp.id('s2')) ->> 'already', 'true', 'a replay returns the first outcome');
select is(pg_temp.err($$ select public.ho_exception(pg_temp.rq(83), pg_temp.id('xA'), pg_temp.id('sh_d'), pg_temp.d('d'), 'Again', pg_temp.id('s2')) $$) ->> 'field', 'no_pending_exception', 'a second exception for the same refusal is refused');
select is(pg_temp.err($$ select public.ho_exception(pg_temp.rq(84), pg_temp.id('xE'), pg_temp.id('sh_d'), pg_temp.d('d'), 'No refusal', pg_temp.id('s2')) $$) ->> 'field', 'no_pending_exception', 'an issue nobody refused has nothing to except');
select is(pg_temp.err($$ select public.ho_exception(pg_temp.rq(85), pg_temp.id('xC'), pg_temp.id('sh_d'), pg_temp.d('d'), '  ', pg_temp.id('s1')) $$) ->> 'field', 'reason', 'a reason is required');
select is(pg_temp.err($$ select public.ho_exception(pg_temp.rq(86), pg_temp.id('xC'), pg_temp.id('sh_d'), pg_temp.d('d'), 'x', null) $$) ->> 'field', 'owner', 'the owner is required');
select is(pg_temp.err($$ select public.ho_exception(pg_temp.rq(87), pg_temp.id('xC'), pg_temp.id('sh_d'), pg_temp.d('d'), 'x', pg_temp.id('uax')) $$) ->> 'field', 'owner', 'the owner must be a supervisor');
select is(pg_temp.err($$ select public.ho_exception(pg_temp.rq(88), pg_temp.id('xC'), pg_temp.id('sh_d'), pg_temp.d('d'), 'x', pg_temp.id('sinact')) $$) ->> 'field', 'owner', 'an inactive supervisor is refused');
select is(public.ho_exception(pg_temp.rq(89), pg_temp.id('xC'), pg_temp.id('sh_d'), pg_temp.d('d'), 'x', pg_temp.id('sy')) ->> 'code', 'not_allowed', 'an owner from another tenant is a denial');
select is(public.ho_exception(pg_temp.rq(90), pg_temp.id('xC'), pg_temp.id('sh_d'), pg_temp.d('d'), 'Own issue stays', pg_temp.id('s1')) ->> 'kept', 'true', 'keep works for a supervisor''s own issue');
update public.machine_issue set status = 'closed', closed_at = now(), closed_by = pg_temp.id('uax'), resolved_at = now(), resolved_by = pg_temp.id('uax') where id = pg_temp.id('xD');
select is(pg_temp.err($$ select public.ho_exception(pg_temp.rq(91), pg_temp.id('xD'), pg_temp.id('sh_d'), pg_temp.d('d'), 'x', pg_temp.id('s2')) $$) ->> 'field', 'invalid_status', 'a closed issue cannot be reassigned');

-- Overdue setting (AC-8) --------------------------------------------------------------------------------------------------------
select is(public.ho_set_overdue(pg_temp.rq(100), 45) ->> 'overdue_minutes', '45', 'a Unit Admin sets the overdue minutes');
select is((select overdue_minutes from public.handover_setting where tenant_id = pg_temp.id('tx')), 45, 'stored');
select is((select required from public.handover_setting where tenant_id = pg_temp.id('tx')), true, 'enforcement is unchanged');
select is(pg_temp.n_audit('handover.setting_updated'), 1, 'audited handover.setting_updated');
select is(public.ho_set_overdue(pg_temp.rq(100), 45) ->> 'already', 'true', 'a replay returns the first outcome');
select is(pg_temp.err($$ select public.ho_set_overdue(pg_temp.rq(101), 14) $$) ->> 'field', 'minutes', '14 is refused');
select is(pg_temp.err($$ select public.ho_set_overdue(pg_temp.rq(101), 481) $$) ->> 'field', 'minutes', '481 is refused');
select is(pg_temp.err($$ select public.ho_set_overdue(pg_temp.rq(101), null) $$) ->> 'field', 'minutes', 'null is refused');
select is(public.ho_set_overdue(pg_temp.rq(102), 480) ->> 'ok', 'true', '480 is accepted');
select is(public.ho_set_overdue(pg_temp.rq(103), 15) ->> 'ok', 'true', '15 is accepted');
select pg_temp.as_user('uau');
select is(public.ho_set_overdue(pg_temp.rq(104), 30) ->> 'ok', 'true', 'a tenant without a row gets one');
select is((select required::text || ':' || overdue_minutes from public.handover_setting where tenant_id = pg_temp.id('tu')), 'false:30', 'which does not switch enforcement on');
select is(app._ho_enforced(pg_temp.id('tu')), false, 'the tenant stays unenforced');
select pg_temp.as_user('s1');
select is(public.ho_set_overdue(pg_temp.rq(105), 30) ->> 'code', 'not_allowed', 'a supervisor cannot set it');

-- Who may act (AC-13) ---------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('s2');
select is(public.ho_acknowledge(pg_temp.rq(110), pg_temp.id('iB'), pg_temp.id('sh_a'), pg_temp.d('a')) ->> 'code', 'not_allowed', 'another supervisor (not the owner of the machine) cannot acknowledge');
select is(public.ho_refuse(pg_temp.rq(111), pg_temp.id('iB'), pg_temp.id('sh_a'), pg_temp.d('a'), 'x') ->> 'code', 'not_allowed', 'nor refuse');
select is(public.ho_declare(pg_temp.rq(112), pg_temp.id('sh_a'), pg_temp.d('a')) ->> 'code', 'not_allowed', 'nor declare an occurrence where they own nothing');
select is(pg_temp.n_denied('rpc:ho_acknowledge', 'not_owner') + pg_temp.n_denied('rpc:ho_refuse', 'not_owner') + pg_temp.n_denied('rpc:ho_declare', 'not_owner'), 3, 'each is audited as not_owner');
select pg_temp.as_user('uax');
select is(public.ho_acknowledge(pg_temp.rq(113), pg_temp.id('iB'), pg_temp.id('sh_a'), pg_temp.d('a')) ->> 'code', 'not_allowed', 'a Unit Admin cannot acknowledge for a supervisor');
select is(public.ho_declare(pg_temp.rq(114), pg_temp.id('sh_a'), pg_temp.d('a')) ->> 'code', 'not_allowed', 'nor declare');
select is(public.ho_add_note(pg_temp.rq(115), pg_temp.id('nA'), pg_temp.id('sh_n'), pg_temp.d('n'), 'x') ->> 'code', 'not_allowed', 'nor add a note');
select is(pg_temp.n_denied('rpc:ho_acknowledge', 'role') + pg_temp.n_denied('rpc:ho_declare', 'role') + pg_temp.n_denied('rpc:ho_add_note', 'role'), 3, 'audited as role denials');
select pg_temp.as_user('sinact');
select is(public.ho_acknowledge(pg_temp.rq(116), pg_temp.id('iB'), pg_temp.id('sh_a'), pg_temp.d('a')) ->> 'code', 'not_allowed', 'an inactive supervisor is denied');
select pg_temp.as_user('sfresh');
select is(public.ho_declare(pg_temp.rq(117), pg_temp.id('sh_a'), pg_temp.d('a')) ->> 'code', 'not_allowed', 'a supervisor with a temporary password is denied');
select is(pg_temp.n_denied('rpc:ho_acknowledge', 'inactive') + pg_temp.n_denied('rpc:ho_declare', 'must_change_password'), 2, 'both audited with their reasons');
select pg_temp.as_user('sa');
select is(public.ho_acknowledge(pg_temp.rq(118), pg_temp.id('iB'), pg_temp.id('sh_a'), pg_temp.d('a')) ->> 'code', 'not_allowed', 'a Super Admin is denied');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and source = 'rpc:ho_acknowledge' and reason = 'platform_admin' and actor_role = 'platform_admin'), 1, 'as a platform event');
select pg_temp.as_user('nomem');
select is(public.ho_set_overdue(pg_temp.rq(119), 30) ->> 'code', 'not_allowed', 'a user without a membership is denied');
select pg_temp.as_user('sy');
select is(public.ho_acknowledge(pg_temp.rq(120), pg_temp.id('iB'), pg_temp.id('sh_y'), pg_temp.d('y')) ->> 'code', 'not_allowed', 'another tenant''s supervisor with this tenant''s issue id: denied');
select is(public.ho_acknowledge(pg_temp.rq(121), pg_temp.id('yI'), pg_temp.id('sh_a'), pg_temp.d('a')) ->> 'code', 'not_allowed', 'their own issue with this tenant''s shift: denied');
select is(public.ho_declare(pg_temp.rq(122), pg_temp.id('sh_a'), pg_temp.d('a')) ->> 'code', 'not_allowed', 'a foreign shift id is denied');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and actor_user_id = pg_temp.id('sy') and reason in ('cross_tenant', 'not_found')), 3, 'the cross-tenant attempts are audited');
select is((select count(*)::int from public.issue_acknowledgement where issue_id = pg_temp.id('iB')), 1, 'and nothing was written by any denied call');

select * from finish();
rollback;
