-- 08 step 8b (S1, S2): the overdue snapshot is taken at the supervisor's first interaction of ANY kind (declare, acknowledge, refuse, the rd_opening
-- gate), not only when the checklist is read, so a later change of the setting cannot rewrite compliance; and a no-op cover (to the machine's
-- current owner) does not make the declaration stale for rd_opening. Self-contained; rolled back. Phones +91 90000 28400-28409.
begin;
create extension if not exists pgtap with schema extensions;
select plan(22);

create temp table ids (k text primary key, v uuid);
create temp table dates (k text primary key, d date);
create function pg_temp.id(k text) returns uuid language sql as $$ select v from ids where k = $1 $$;
create function pg_temp.d(k text) returns date language sql as $$ select d from dates where k = $1 $$;
create function pg_temp.rq(n int) returns uuid language sql as $$ select ('a1000000-0000-4000-c804-' || lpad(n::text, 12, '0'))::uuid $$;
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


insert into auth.users (id, email, aud, role)
select u, 'tap64-' || n || '@example.test', 'authenticated', 'authenticated' from (values
  ('00000000-0000-4000-c804-0000000000a1'::uuid, 'uax'), ('00000000-0000-4000-c804-0000000000a2', 's1'), ('00000000-0000-4000-c804-0000000000a3', 's2')) t(u, n);
insert into ids values ('uax', '00000000-0000-4000-c804-0000000000a1'), ('s1', '00000000-0000-4000-c804-0000000000a2'), ('s2', '00000000-0000-4000-c804-0000000000a3'),
  ('tx', '50000000-0000-4000-c804-00000000000a');
insert into public.tenant (id, name, status, timezone) values ('50000000-0000-4000-c804-00000000000a', 'tap64 org X', 'active', 'Asia/Kolkata');
insert into public.handover_setting (tenant_id, required, overdue_minutes) values (pg_temp.id('tx'), true, 60);
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('50000000-0000-4000-c804-00000000000a', '00000000-0000-4000-c804-0000000000a1', 'unit_admin', 'active', 'UA X', 'UA-X', '+919000028401', false),
  ('50000000-0000-4000-c804-00000000000a', '00000000-0000-4000-c804-0000000000a2', 'supervisor', 'active', 'Sup One', 'S1', '+919000028402', false),
  ('50000000-0000-4000-c804-00000000000a', '00000000-0000-4000-c804-0000000000a3', 'supervisor', 'active', 'Sup Two', 'S2', '+919000028403', false);
insert into public.site (id, tenant_id, name, timezone) values ('51000000-0000-4000-c804-00000000000a', pg_temp.id('tx'), 'Plant X', 'Asia/Kolkata');
insert into ids values ('site_tx', '51000000-0000-4000-c804-00000000000a');
insert into public.product (id, tenant_id, code, description) values ('54000000-0000-4000-c804-0000000000a1', pg_temp.id('tx'), 'P-1', 'Part 1');
insert into ids values ('p1', '54000000-0000-4000-c804-0000000000a1');
grant select on ids, dates to authenticated, anon;
create function pg_temp.sessions(k text) returns text language sql as $$
  select coalesce(string_agg(overdue_minutes::text, ',' order by handover_start), '-') from public.handover_session where shift_id = pg_temp.id('sh_' || k) $$;
create function pg_temp.comp(k text) returns text language sql as $$
  select coalesce((select c.reason || '/' || c.compliant::text from app.handover_compliance_at(pg_temp.id('tx'), pg_temp.d(k), pg_temp.d(k), now()) c where c.shift_id = pg_temp.id('sh_' || k)), '-') $$;

-- Shifts that started 5 h ago and ended 4 h ago (so the 60-minute deadline has long passed and compliance counts them).
select pg_temp.mk('d1', -300, 1, 's1');                                     -- declare, no checklist read, no issues
select pg_temp.mk('a1', -300, 1, 's1'); select pg_temp.mk_issue('iA', 'a1', 's2');   -- acknowledge
select pg_temp.mk('r1', -300, 1, 's1'); select pg_temp.mk_issue('iR', 'r1', 's2');   -- refuse
select pg_temp.mk('g1', -300, 1, 's1');                                     -- rd_opening gate with a declaration inserted directly
select pg_temp.mk('z1', -300, 1, 's1');                                     -- no interaction at all
insert into public.handover_declaration (tenant_id, shift_id, shift_date, supervisor_id, covered_issue_ids, at)
values (pg_temp.id('tx'), pg_temp.id('sh_g1'), pg_temp.d('g1'), pg_temp.id('s1'), '{}', now() - interval '3 hours');

select pg_temp.as_user('s1');
select is(pg_temp.sessions('d1'), '-', 'S1: no session before any interaction');
select is(public.ho_declare(pg_temp.rq(1), pg_temp.id('sh_d1'), pg_temp.d('d1')) ->> 'ok', 'true', 'S1: s1 declares without ever reading the checklist');
select is(pg_temp.sessions('d1'), '60', 'S1: the declare froze the overdue minutes (60)');
select is(public.ho_acknowledge(pg_temp.rq(2), pg_temp.id('iA'), pg_temp.id('sh_a1'), pg_temp.d('a1')) ->> 'ok', 'true', 'S1: s1 acknowledges without reading the checklist');
select is(pg_temp.sessions('a1'), '60', 'S1: the acknowledgement froze the overdue minutes');
select is(public.ho_refuse(pg_temp.rq(3), pg_temp.id('iR'), pg_temp.id('sh_r1'), pg_temp.d('r1'), 'Not mine') ->> 'ok', 'true', 'S1: s1 refuses without reading the checklist');
select is(pg_temp.sessions('r1'), '60', 'S1: the refusal froze the overdue minutes');
select is(pg_temp.sessions('g1'), '-', 'S1: a declaration row alone (legacy) has no session');
select is(public.rd_opening(pg_temp.rq(4), pg_temp.id('m_g1'), pg_temp.id('sh_g1'), pg_temp.d('g1'), pg_temp.id('p1'), 100) ->> 'ok', 'true', 'S1: the opening is accepted (declared)');
select is(pg_temp.sessions('g1'), '60', 'S1: the rd_opening gate path froze the overdue minutes');
select is(public.ho_declare(pg_temp.rq(1), pg_temp.id('sh_d1'), pg_temp.d('d1')) ->> 'already', 'true', 'a replay of the declare returns the first outcome');
select is(pg_temp.sessions('d1'), '60', 'and writes no second session');
select is(pg_temp.comp('d1'), 'late/false', 'S1: declared 4 h after the start against 60 minutes: late');

-- the owner relaxes the setting afterwards
select pg_temp.as_user('uax');
select is(public.ho_set_overdue(pg_temp.rq(5), 480) ->> 'ok', 'true', 'the Unit Admin raises the overdue minutes to 480');
select is(pg_temp.comp('d1'), 'late/false', 'S1: compliance is unchanged (the first interaction froze 60)');
select is(pg_temp.comp('a1'), 'late/false', 'S1: also for the acknowledged occurrence');
select is(pg_temp.sessions('r1'), '60', 'S1: the session still holds 60');
select is(pg_temp.sessions('z1'), '-', 'an occurrence with no interaction has no session (it is no_declaration whatever the minutes)');
select is(pg_temp.comp('z1'), 'no_declaration/false', 'and reads as no declaration');

-- S2: a cover to the machine's current owner keeps the declaration valid for rd_opening
select pg_temp.as_user('s1');
select pg_temp.mk('c1', -45, 8, 's1');
select is(public.ho_declare(pg_temp.rq(6), pg_temp.id('sh_c1'), pg_temp.d('c1')) ->> 'ok', 'true', 'S2: s1 declares on a running shift');
insert into public.assignment_cover (tenant_id, shift_id, shift_date, machine_id, supervisor_id, reason, recorded_by) values
  (pg_temp.id('tx'), pg_temp.id('sh_c1'), pg_temp.d('c1'), pg_temp.id('m_c1'), pg_temp.id('s1'), 'Confirmed', pg_temp.id('uax'));
select is(app._ho_declared_at(pg_temp.id('s1'), pg_temp.id('sh_c1'), pg_temp.d('c1'), now()), true, 'S2: a cover to the current owner keeps the declaration valid');
select is(public.rd_opening(pg_temp.rq(7), pg_temp.id('m_c1'), pg_temp.id('sh_c1'), pg_temp.d('c1'), pg_temp.id('p1'), 100) ->> 'ok', 'true', 'S2: and rd_opening is still allowed');

select * from finish();
rollback;
