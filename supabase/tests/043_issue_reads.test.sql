-- 07 step 4 (AC-11, AC-13, AC-14 server side): public.issue_list (visibility matrix supervisor / Unit Admin / Super Admin, filters, paging),
-- public.issue_detail (timeline, ownership history, allowed_actions per role and status), public.issue_alerts (order, recently closed window,
-- Unit Admin only). The list is cross-checked against app.can_see_issue for every user at several moments. Self-contained; rolled back.
-- Clock (D10): tenant X has shift R running now and shift N starting ~3.5 h ahead, built from the current time; reads take explicit moments.
begin;
create extension if not exists pgtap with schema extensions;
select plan(98);

create temp table ids (k text primary key, v uuid);
create function pg_temp.id(k text) returns uuid language sql as $$ select v from ids where k = $1 $$;
create function pg_temp.as_user(k text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where ids.k = $1), 'role', 'authenticated')::text, true) $$;
grant select on ids to authenticated, anon;
create function pg_temp.rpc(u text, q text) returns jsonb language plpgsql as $f$
declare d text; m text; st text; r jsonb;
begin
  perform pg_temp.as_user(u);
  execute q into r;
  return r;
exception when others then
  get stacked diagnostics d = pg_exception_detail, m = message_text, st = returned_sqlstate;
  return coalesce(case when d ~ '^[{]' then d::jsonb end, '{}'::jsonb) || jsonb_build_object('raised', true, 'message', m, 'sqlstate', st);
end $f$;
create function pg_temp.f15(t timestamp) returns text language sql as $$
  select to_char(date_trunc('hour', t) + (extract(minute from t)::int / 15) * interval '15 minutes', 'HH24:MI') $$;
-- ids of the items an issue_list call returns, as a sorted array of issue keys
create function pg_temp.keys(r jsonb) returns text language sql as $$
  select coalesce(string_agg(coalesce((select k from ids where v = (e->>'id')::uuid), '?'), ',' order by (select k from ids where v = (e->>'id')::uuid)), '') from jsonb_array_elements(r->'items') e $$;
create function pg_temp.lst(u text, f jsonb default '{}', pg int default 1, at timestamptz default now()) returns jsonb language plpgsql as $f$
begin return pg_temp.rpc(u, format($q$select public.issue_list(%L::jsonb, %s, %L::timestamptz)$q$, f, pg, at)); end $f$;
create function pg_temp.mk(k text, t text, mach text, prio text, st text, owner text, reporter text, rep_at timestamptz,
                           stopped boolean default false, esc boolean default false, res_by text default null, res_at timestamptz default null, cl_at timestamptz default null) returns void language plpgsql as $f$
declare v uuid;
begin
  insert into public.machine_issue (tenant_id, machine_id, category_id, priority, description, machine_stopped, status, escalated_at, accountable_owner_id, reported_by, reported_at,
                                    resolved_by, resolved_at, resolution_notes, closed_at, closed_by)
  values (pg_temp.id(t), pg_temp.id(mach), (select c.id from public.issue_category c where c.tenant_id = pg_temp.id(t) and c.name = 'Mechanical'), prio, 'issue ' || k, stopped, st,
          case when esc then rep_at + interval '1 minute' end, pg_temp.id(owner), pg_temp.id(reporter), rep_at,
          pg_temp.id(res_by), res_at, case when res_at is not null then 'fixed ' || k end, cl_at, case when cl_at is not null then pg_temp.id(res_by) end)
  returning id into v;
  insert into ids values (k, v);
  insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, status_after, at) values
    (pg_temp.id(t), v, pg_temp.id(reporter), 'supervisor', 'report', 'open', rep_at);
end $f$;

insert into auth.users (id, email, aud, role)
select u, 'tap43-' || n || '@example.test', 'authenticated', 'authenticated' from (values
  ('00000000-0000-4000-c730-0000000000a1'::uuid, 'uax'), ('00000000-0000-4000-c730-0000000000a2', 's1'), ('00000000-0000-4000-c730-0000000000a3', 's2'),
  ('00000000-0000-4000-c730-0000000000a4', 's3'), ('00000000-0000-4000-c730-0000000000a5', 's4'), ('00000000-0000-4000-c730-0000000000a6', 's5'),
  ('00000000-0000-4000-c730-0000000000b1', 'uay'), ('00000000-0000-4000-c730-0000000000b2', 'sy'),
  ('00000000-0000-4000-c730-0000000000c1', 'nomem'), ('00000000-0000-4000-c730-0000000000f1', 'sa'),
  ('00000000-0000-4000-c730-0000000000e1', 'uaw'), ('00000000-0000-4000-c730-0000000000e2', 'sw'), ('00000000-0000-4000-c730-0000000000e3', 'fresh')) t(u, n);
insert into ids values ('uax', '00000000-0000-4000-c730-0000000000a1'), ('s1', '00000000-0000-4000-c730-0000000000a2'), ('s2', '00000000-0000-4000-c730-0000000000a3'),
  ('s3', '00000000-0000-4000-c730-0000000000a4'), ('s4', '00000000-0000-4000-c730-0000000000a5'), ('s5', '00000000-0000-4000-c730-0000000000a6'),
  ('uay', '00000000-0000-4000-c730-0000000000b1'), ('sy', '00000000-0000-4000-c730-0000000000b2'), ('nomem', '00000000-0000-4000-c730-0000000000c1'), ('sa', '00000000-0000-4000-c730-0000000000f1'),
  ('uaw', '00000000-0000-4000-c730-0000000000e1'), ('sw', '00000000-0000-4000-c730-0000000000e2'), ('fresh', '00000000-0000-4000-c730-0000000000e3'),
  ('tx', '50000000-0000-4000-c730-00000000000a'), ('ty', '50000000-0000-4000-c730-00000000000b'), ('tw', '50000000-0000-4000-c730-00000000000e');
insert into public.tenant (id, name, status, timezone) values
  ('50000000-0000-4000-c730-00000000000a', 'tap43 org X', 'active', 'Asia/Kolkata'), ('50000000-0000-4000-c730-00000000000b', 'tap43 org Y', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c730-00000000000e', 'tap43 org W', 'active', 'Asia/Kolkata');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('50000000-0000-4000-c730-00000000000a', '00000000-0000-4000-c730-0000000000a1', 'unit_admin', 'active', 'UA X', 'UA-X', '+919000020761', false),
  ('50000000-0000-4000-c730-00000000000a', '00000000-0000-4000-c730-0000000000a2', 'supervisor', 'active', 'Sup One', 'S1', '+919000020762', false),
  ('50000000-0000-4000-c730-00000000000a', '00000000-0000-4000-c730-0000000000a3', 'supervisor', 'active', 'Sup Two', 'S2', '+919000020763', false),
  ('50000000-0000-4000-c730-00000000000a', '00000000-0000-4000-c730-0000000000a4', 'supervisor', 'active', 'Sup Three', 'S3', '+919000020764', false),
  ('50000000-0000-4000-c730-00000000000a', '00000000-0000-4000-c730-0000000000a5', 'supervisor', 'inactive', 'Sup Gone', 'S4', '+919000020765', false),
  ('50000000-0000-4000-c730-00000000000a', '00000000-0000-4000-c730-0000000000a6', 'supervisor', 'active', 'Sup Five', 'S5', '+919000020766', false),
  ('50000000-0000-4000-c730-00000000000b', '00000000-0000-4000-c730-0000000000b1', 'unit_admin', 'active', 'UA Y', 'UA-Y', '+919000020767', false),
  ('50000000-0000-4000-c730-00000000000b', '00000000-0000-4000-c730-0000000000b2', 'supervisor', 'active', 'Sup Y', 'SY', '+919000020768', false),
  ('50000000-0000-4000-c730-00000000000e', '00000000-0000-4000-c730-0000000000e1', 'unit_admin', 'active', 'UA W', 'UA-W', '+919000020769', false),
  ('50000000-0000-4000-c730-00000000000e', '00000000-0000-4000-c730-0000000000e2', 'supervisor', 'active', 'Sup W', 'SW', '+919000020770', false),
  ('50000000-0000-4000-c730-00000000000e', '00000000-0000-4000-c730-0000000000e3', 'supervisor', 'active', 'Fresh W', 'FW', '+919000020771', true);
insert into public.platform_admin (user_id, full_name, phone_e164, status, must_change_password) values ('00000000-0000-4000-c730-0000000000f1', 'SA 43', '+919000020772', 'active', false);
insert into public.site (id, tenant_id, name, timezone) values
  ('51000000-0000-4000-c730-00000000000a', pg_temp.id('tx'), 'Plant X', 'Asia/Kolkata'), ('51000000-0000-4000-c730-00000000000b', pg_temp.id('ty'), 'Plant Y', 'Asia/Kolkata'),
  ('51000000-0000-4000-c730-00000000000e', pg_temp.id('tw'), 'Plant W', 'Asia/Kolkata');
insert into public.machine (id, tenant_id, site_id, code, name) values
  ('53000000-0000-4000-c730-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c730-00000000000a', 'M-A', 'Press A'),
  ('53000000-0000-4000-c730-0000000000a2', pg_temp.id('tx'), '51000000-0000-4000-c730-00000000000a', 'M-B', 'Press B'),
  ('53000000-0000-4000-c730-0000000000a3', pg_temp.id('tx'), '51000000-0000-4000-c730-00000000000a', 'M-C', 'Press C'),
  ('53000000-0000-4000-c730-0000000000a5', pg_temp.id('tx'), '51000000-0000-4000-c730-00000000000a', 'M-E', 'Press E (unassigned)'),
  ('53000000-0000-4000-c730-0000000000b1', pg_temp.id('ty'), '51000000-0000-4000-c730-00000000000b', 'Y-1', 'Y press'),
  ('53000000-0000-4000-c730-0000000000e1', pg_temp.id('tw'), '51000000-0000-4000-c730-00000000000e', 'W-1', 'W press 1'),
  ('53000000-0000-4000-c730-0000000000e2', pg_temp.id('tw'), '51000000-0000-4000-c730-00000000000e', 'W-2', 'W press 2');
insert into ids values ('mA', '53000000-0000-4000-c730-0000000000a1'), ('mB', '53000000-0000-4000-c730-0000000000a2'), ('mC', '53000000-0000-4000-c730-0000000000a3'),
  ('mE', '53000000-0000-4000-c730-0000000000a5'), ('my', '53000000-0000-4000-c730-0000000000b1'), ('w1', '53000000-0000-4000-c730-0000000000e1'), ('w2', '53000000-0000-4000-c730-0000000000e2');
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time)
select * from (select '54000000-0000-4000-c730-0000000000a1'::uuid, pg_temp.id('tx'), '51000000-0000-4000-c730-00000000000a'::uuid, 'R running',
  pg_temp.f15(l - interval '90 minutes')::time, (pg_temp.f15(l + interval '90 minutes')::time + interval '15 minutes')::time from (select now() at time zone 'Asia/Kolkata' as l) q
  union all select '54000000-0000-4000-c730-0000000000a2'::uuid, pg_temp.id('tx'), '51000000-0000-4000-c730-00000000000a'::uuid, 'N next',
  pg_temp.f15(l + interval '210 minutes')::time, (pg_temp.f15(l + interval '210 minutes')::time + interval '3 hours')::time from (select now() at time zone 'Asia/Kolkata' as l) q) x;
insert into ids values ('R', '54000000-0000-4000-c730-0000000000a1'), ('N', '54000000-0000-4000-c730-0000000000a2');
-- plan: R: A -> s1, B -> s2, C -> s4 (inactive); N: A -> s2, C -> s3; E never assigned
insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by)
select pg_temp.id('tx'), pg_temp.id(sh), pg_temp.id(m), pg_temp.id(sup), app.plant_date(pg_temp.id('tx')) - 30, pg_temp.id('uax')
from (values ('R', 'mA', 's1'), ('R', 'mB', 's2'), ('R', 'mC', 's4'), ('N', 'mA', 's2'), ('N', 'mC', 's3')) v(sh, m, sup);

-- Tenant X issues: i1 on A (reporter s5, owner s3); i2 on B (reporter UA, nobody owns it); i3 on E (s1/s1); i4 High on C resolved 5 h ago by s5 (owner s5);
-- i5 High on A resolved 5 h ago by s3 (owner s3); i6 Low closed on B (owner s2, reporter s2); iY in tenant Y.
select pg_temp.mk('i1', 'tx', 'mA', 'medium', 'open', 's3', 's5', now() - interval '3 hours');
select pg_temp.mk('i2', 'tx', 'mB', 'low', 'open', null, 'uax', now() - interval '2 hours');
select pg_temp.mk('i3', 'tx', 'mE', 'low', 'in_progress', 's1', 's1', now() - interval '1 hour', false, true);
select pg_temp.mk('i4', 'tx', 'mC', 'high', 'resolved', 's5', 's5', now() - interval '8 hours', false, false, 's5', now() - interval '5 hours');
select pg_temp.mk('i5', 'tx', 'mA', 'high', 'resolved', 's3', 's3', now() - interval '9 hours', false, false, 's3', now() - interval '5 hours');
select pg_temp.mk('i6', 'tx', 'mB', 'low', 'closed', 's2', 's2', now() - interval '10 hours', false, false, 's2', now() - interval '9 hours', now() - interval '9 hours');
select pg_temp.mk('iY', 'ty', 'my', 'low', 'open', 'sy', 'sy', now() - interval '1 hour');

-- Visibility matrix at three moments (AC-13) ---------------------------------------------------------------------------------------------
-- now: R runs (A s1, B s2, C inactive).  +4 h: N runs (A s2, C s3).  +7 h: nothing runs; N ended (it started after the resolve of i4/i5).
select is(pg_temp.keys(pg_temp.lst('uax')), 'i1,i2,i3,i4,i5,i6', 'a Unit Admin lists every issue of the tenant');
select is(pg_temp.keys(pg_temp.lst('uay')), 'iY', 'another tenant''s Unit Admin lists only its own');
select is(pg_temp.keys(pg_temp.lst('s1')), 'i1,i3,i5', 's1 (owns A now): issues on A, plus the ones they reported (i3)');
select is(pg_temp.keys(pg_temp.lst('s2')), 'i2,i6', 's2 (owns B now): i2 on B and i6 (owner and reporter)');
select is(pg_temp.keys(pg_temp.lst('s3')), 'i1,i5', 's3: accountable for i1 and i5');
select is(pg_temp.keys(pg_temp.lst('s5')), 'i1,i4', 's5: reported i1, accountable and resolver of i4');
select is(pg_temp.keys(pg_temp.lst('s3', '{}', 1, now() + interval '4 hours')), 'i1,i4,i5', 's3 at +4h (owns C in the running N): i4 on C joins');
select is(pg_temp.keys(pg_temp.lst('s2', '{}', 1, now() + interval '4 hours')), 'i1,i5,i6', 's2 at +4h (owns A in the running N): the issues on A, and i6 (theirs); i2 is on B, which only R covers');
select is(pg_temp.keys(pg_temp.lst('s3', '{}', 1, now() + interval '7 hours')), 'i1,i4,i5', 's3 at +7h: nothing runs, but i4 awaits their verification (N started after the resolve) and i1/i5 are theirs');
select is(pg_temp.keys(pg_temp.lst('s2', '{}', 1, now() + interval '7 hours')), 'i5,i6', 's2 at +7h: i5 awaits their verification (they own A in N); i6 is theirs');
select is(pg_temp.keys(pg_temp.lst('s1', '{}', 1, now() + interval '7 hours')), 'i3,i5', 's1 at +7h: what they reported, and i5 (today''s R started after the resolve, so they may verify it)');
select is(pg_temp.rpc('s5', 'select public.issue_list()')->>'ok', 'true', 'defaults: no filters, page 1');
-- the list and app.can_see_issue agree for every user at every moment (the single source of truth)
create function pg_temp.agree(u text, at timestamptz) returns boolean language plpgsql as $f$
declare l text; c text;
begin
  l := pg_temp.keys(pg_temp.lst(u, '{}', 1, at));
  perform pg_temp.as_user(u);
  select coalesce(string_agg(k, ',' order by k), '') into c from ids join public.machine_issue i on i.id = ids.v where i.tenant_id = (select tenant_id from public.membership where user_id = pg_temp.id(u)) and app.can_see_issue(i.id, pg_temp.id(u), at);
  return l = c;
end $f$;
select ok(pg_temp.agree('uax', now()) and pg_temp.agree('s1', now()) and pg_temp.agree('s2', now()) and pg_temp.agree('s3', now()) and pg_temp.agree('s5', now()) and pg_temp.agree('s4', now()), 'issue_list = can_see_issue for every user now (incl. the inactive supervisor: none)');
select ok(pg_temp.agree('uax', now() + interval '4 hours') and pg_temp.agree('s1', now() + interval '4 hours') and pg_temp.agree('s2', now() + interval '4 hours') and pg_temp.agree('s3', now() + interval '4 hours')
          and pg_temp.agree('s5', now() + interval '4 hours'), 'and at +4 h');
select ok(pg_temp.agree('s1', now() + interval '7 hours') and pg_temp.agree('s2', now() + interval '7 hours') and pg_temp.agree('s3', now() + interval '7 hours') and pg_temp.agree('s5', now() + interval '7 hours'), 'and at +7 h');
select is(pg_temp.lst('s4')->>'code', 'not_allowed', 'an inactive supervisor is denied');
select is(pg_temp.lst('sa')->>'code', 'not_allowed', 'a Super Admin is denied');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and source = 'rpc:issue_list' and actor_role = 'platform_admin' and reason = 'platform_admin'), 1, 'audited as a platform event');
select is(pg_temp.lst('nomem')->>'code', 'not_allowed', 'a stranger is denied');
select is(pg_temp.lst('fresh')->>'code', 'not_allowed', 'a user with a temporary password is denied');
select is(pg_temp.keys(pg_temp.lst('sy')), 'iY', 'another tenant''s supervisor sees only their own issue');

-- Filters and paging (Unit Admin) ---------------------------------------------------------------------------------------------------------
select is(pg_temp.keys(pg_temp.lst('uax', '{"status":"open"}')), 'i1,i2', 'filter: status open');
select is(pg_temp.keys(pg_temp.lst('uax', '{"status":"not_closed"}')), 'i1,i2,i3,i4,i5', 'filter: not closed');
select is(pg_temp.keys(pg_temp.lst('uax', '{"status":"resolved"}')), 'i4,i5', 'filter: resolved');
select is(pg_temp.keys(pg_temp.lst('uax', '{"priority":"high"}')), 'i4,i5', 'filter: priority');
select is(pg_temp.keys(pg_temp.lst('uax', format('{"machine_id":"%s"}', pg_temp.id('mA'))::jsonb)), 'i1,i5', 'filter: machine');
select is(pg_temp.keys(pg_temp.lst('uax', '{"escalated":true}')), 'i3', 'filter: escalated');
select is(pg_temp.keys(pg_temp.lst('uax', '{"needs_owner":true}')), 'i2', 'filter: needs owner');
select is(pg_temp.keys(pg_temp.lst('uax', format('{"category_id":"%s"}', (select id from public.issue_category where tenant_id = pg_temp.id('tx') and name = 'Electrical'))::jsonb)), '', 'filter: another category');
select is(pg_temp.keys(pg_temp.lst('uax', '{"status":"open","priority":"medium"}')), 'i1', 'filters combine');
select is(pg_temp.lst('uax', '{"status":"bogus"}')->>'field', 'status', 'validation: unknown status');
select is(pg_temp.lst('uax', '{"priority":"bogus"}')->>'field', 'priority', 'validation: unknown priority');
select is(pg_temp.lst('uax', '{"machine_id":"nope"}')->>'field', 'filters', 'validation: a malformed id');
select is(pg_temp.lst('uax', '[]')->>'field', 'filters', 'validation: filters must be an object');
select is(pg_temp.keys(pg_temp.lst('s1', '{"status":"in_progress"}')), 'i3', 'a supervisor''s filters apply inside their visibility');
select is((pg_temp.lst('uax')->>'total')::int, 6, 'total counts all matches');
select is((pg_temp.lst('uax', '{}', 0)->>'page')::int, 1, 'page 0 is page 1');
-- 30 more issues in tenant W: paging, ordering
insert into public.machine_issue (tenant_id, machine_id, category_id, priority, description, reported_by, accountable_owner_id, reported_at)
select pg_temp.id('tw'), pg_temp.id('w1'), (select id from public.issue_category where tenant_id = pg_temp.id('tw') and name = 'Mechanical'), 'low', 'paging ' || n,
       pg_temp.id('sw'), pg_temp.id('sw'), now() - n * interval '1 minute'
from generate_series(1, 30) n;
select is((pg_temp.lst('uaw')->>'total')::int, 30, 'tenant W: 30 issues');
select is(jsonb_array_length(pg_temp.lst('uaw')->'items'), 25, 'page 1 holds 25');
select is(jsonb_array_length(pg_temp.lst('uaw', '{}', 2)->'items'), 5, 'page 2 holds the rest');
select is(jsonb_array_length(pg_temp.lst('uaw', '{}', 3)->'items'), 0, 'page 3 is empty');
select is(pg_temp.lst('uaw')->'items'->0->>'description', 'paging 1', 'newest first');
select is(pg_temp.lst('uaw', '{}', 2)->'items'->4->>'description', 'paging 30', 'and the oldest is last');
select is(pg_temp.lst('sw')->>'total', '30', 'the supervisor who owns them sees all 30 (accountable)');

-- Detail ---------------------------------------------------------------------------------------------------------------------------------------------
create function pg_temp.det(u text, k text, at timestamptz default now()) returns jsonb language plpgsql as $f$
begin return pg_temp.rpc(u, format($q$select public.issue_detail(%L, %L::timestamptz)$q$, pg_temp.id(k), at)); end $f$;
create function pg_temp.allowed(u text, k text, at timestamptz default now()) returns text language sql as $$
  select coalesce(string_agg(e, ',' order by e), 'DENIED') from jsonb_array_elements_text(pg_temp.det(u, k, at)->'allowed_actions') e $$;
select is(pg_temp.det('s1', 'i3')->'issue'->>'machine_code', 'M-E', 'detail: the machine');
select is(pg_temp.det('s1', 'i3')->'issue'->>'owner_name', 'Sup One', 'detail: the owner''s name');
select is(pg_temp.det('s1', 'i3')->'issue'->>'status', 'in_progress', 'detail: the status');
select is(pg_temp.det('s1', 'i3')->'issue'->>'escalated', 'true', 'detail: escalated flag');
select is(jsonb_array_length(pg_temp.det('s1', 'i3')->'actions'), 1, 'detail: the timeline has the report');
select is(pg_temp.det('s2', 'i3')->>'code', 'not_allowed', 'a supervisor who cannot see the issue is denied');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and source = 'rpc:issue_detail' and reason = 'not_visible' and tenant_id = pg_temp.id('tx')), 1, 'audited as not_visible');
select is(pg_temp.det('uay', 'i3')->>'code', 'not_allowed', 'another tenant is denied (cross_tenant)');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and source = 'rpc:issue_detail' and reason = 'cross_tenant' and tenant_id = pg_temp.id('ty')), 1, 'audited under the caller''s tenant');
select is(pg_temp.det('sa', 'i3')->>'code', 'not_allowed', 'a Super Admin is denied');
select is(pg_temp.rpc('uax', 'select public.issue_detail(gen_random_uuid())')->>'code', 'not_allowed', 'an unknown id is the same denial');
-- a photo action and an ownership change show up in the timeline
insert into public.issue_action (id, tenant_id, issue_id, actor_id, actor_role, type, status_before, status_after) values
  ('61000000-0000-4000-c730-0000000000a1', pg_temp.id('tx'), pg_temp.id('i3'), pg_temp.id('s1'), 'supervisor', 'photo', 'in_progress', 'in_progress');
insert into public.attachment (tenant_id, entity_type, entity_id, storage_path, mime, size_bytes, sha256, uploaded_by, parent_id, status, ready_at) values
  (pg_temp.id('tx'), 'issue_action', '61000000-0000-4000-c730-0000000000a1', 'tenant/' || pg_temp.id('tx') || '/issue/' || pg_temp.id('i3') || '/p1.png', 'image/png', 10, repeat('d', 64), pg_temp.id('s1'), pg_temp.id('i3'), 'ready', now()),
  (pg_temp.id('tx'), 'issue_action', gen_random_uuid(), 'tenant/' || pg_temp.id('tx') || '/issue/' || pg_temp.id('i3') || '/p2.png', 'image/png', 10, repeat('d', 64), pg_temp.id('s1'), pg_temp.id('i3'), 'pending', null);
insert into public.issue_ownership_history (tenant_id, issue_id, previous_owner, new_owner, source, reason, actor_id) values
  (pg_temp.id('tx'), pg_temp.id('i3'), null, pg_temp.id('s1'), 'report', null, pg_temp.id('s1')), (pg_temp.id('tx'), pg_temp.id('i3'), pg_temp.id('s1'), pg_temp.id('s1'), 'handover', 'later', pg_temp.id('uax'));
select is(pg_temp.det('uax', 'i3')->'actions'->1->>'type', 'photo', 'timeline: the photo action follows the report');
select is(jsonb_array_length(pg_temp.det('uax', 'i3')->'actions'->1->'attachments'), 1, 'the photo action carries its ready attachment (a pending one is hidden)');
select is(pg_temp.det('uax', 'i3')->'actions'->1->'attachments'->0->>'path', 'tenant/' || pg_temp.id('tx') || '/issue/' || pg_temp.id('i3') || '/p1.png', 'with the storage path for a signed URL');
select is(jsonb_array_length(pg_temp.det('uax', 'i3')->'ownership'), 2, 'detail: the ownership history');
select is(pg_temp.det('uax', 'i3')->'ownership'->0->>'new_owner_name', 'Sup One', 'ownership rows carry names');

-- allowed_actions (the client renders what the server allows) -------------------------------------------------------------------------------------------
select is(pg_temp.allowed('s3', 'i1'), 'escalate,note,photo,resolve,set_assignee,start', 'Open, owner: note, photo, start, assignee, escalate, resolve');
select is(pg_temp.allowed('uax', 'i1'), 'note,photo,reassign,resolve,set_assignee,start', 'Open, Unit Admin: no escalate, can reassign');
select is(pg_temp.allowed('s5', 'i1'), 'note,photo', 'Open, the reporter who is not the owner: note and photo only');
select is(pg_temp.allowed('s1', 'i1'), 'note,photo', 'Open, a supervisor who owns the machine now but is not accountable: note and photo only');
select is(pg_temp.allowed('s1', 'i3'), 'note,photo,resolve,set_assignee', 'In progress, escalated, owner: no start, no second escalate');
select is(pg_temp.allowed('uax', 'i3'), 'ack_escalation,note,photo,reassign,resolve,set_assignee', 'In progress, escalated, Unit Admin: can acknowledge');
select is(pg_temp.allowed('s2', 'i3'), 'DENIED', 'a supervisor who cannot see it gets no detail');
select is(pg_temp.allowed('s1', 'i5'), 'note,photo,verify', 'Resolved High: the later-shift owner (s1, R started after the resolve) may verify');
select is(pg_temp.allowed('s3', 'i5'), 'note,photo,set_assignee', 'Resolved High: the resolver (also the owner) may not verify and cannot resolve again');
select is(pg_temp.allowed('uax', 'i5'), 'note,photo,reassign,set_assignee', 'Resolved High: the Unit Admin may not verify while a later-shift supervisor is assigned');
select is(pg_temp.allowed('uax', 'i4'), 'note,photo,reassign,set_assignee', 'i4 (C): N assigns C to s3, so the Unit Admin may not verify');
select is(pg_temp.allowed('s3', 'i4', now() + interval '7 hours'), 'note,photo,verify', 'i4 at +7h: s3 (owns C in N, which started after the resolve) may verify');
select is(pg_temp.allowed('s2', 'i6'), 'note,photo', 'Closed, owner: note and photo only');
select is(pg_temp.allowed('uax', 'i6'), 'note,photo,reopen', 'Closed, Unit Admin: reopen');
select is(pg_temp.allowed('uax', 'i2'), 'note,photo,reassign,resolve,set_assignee,start', 'Needs owner (nobody accountable): the Unit Admin can reassign');
-- rules and RPCs agree: a listed action works, an unlisted one is refused
select is(pg_temp.rpc('uax', format($q$select public.iss_escalate(gen_random_uuid(), %L, 'x')$q$, pg_temp.id('i1')))->>'code', 'not_allowed', 'escalate is not listed for the Unit Admin and the RPC refuses it');
select is(pg_temp.rpc('s5', format($q$select public.iss_start(gen_random_uuid(), %L)$q$, pg_temp.id('i1')))->>'code', 'not_allowed', 'start is not listed for the reporter and the RPC refuses it');
select is(pg_temp.rpc('s3', format($q$select public.iss_escalate(gen_random_uuid(), %L, 'listed')$q$, pg_temp.id('i1')))->>'ok', 'true', 'escalate is listed for the owner and the RPC accepts it');
select is(pg_temp.allowed('s3', 'i1'), 'note,photo,resolve,set_assignee,start', 'after escalating, escalate is no longer listed');
select is(pg_temp.rpc('s1', format($q$select public.iss_verify(gen_random_uuid(), %L, true)$q$, pg_temp.id('i5')))->>'ok', 'true', 'verify is listed for s1 and the RPC accepts it');
select is(pg_temp.allowed('s1', 'i5'), 'note,photo', 'after closing, verify is gone');

-- Alerts (AC-11), tenant W ---------------------------------------------------------------------------------------------------------------------------
select pg_temp.mk('aH2', 'tw', 'w1', 'high', 'in_progress', 'sw', 'sw', now() - interval '6 hours', false, true);
select pg_temp.mk('aC', 'tw', 'w1', 'critical', 'open', 'sw', 'sw', now() - interval '3 hours');
select pg_temp.mk('aS', 'tw', 'w2', 'critical', 'open', null, 'uaw', now() - interval '5 hours', true);
select pg_temp.mk('aH', 'tw', 'w2', 'high', 'open', 'sw', 'sw', now() - interval '1 hour');
select pg_temp.mk('aR', 'tw', 'w2', 'high', 'resolved', 'sw', 'sw', now() - interval '12 hours', false, false, 'sw', now() - interval '2 hours');
select pg_temp.mk('aM', 'tw', 'w1', 'medium', 'open', 'sw', 'sw', now() - interval '1 hour');
select pg_temp.mk('cH', 'tw', 'w1', 'high', 'closed', 'sw', 'sw', now() - interval '3 days', false, false, 'sw', now() - interval '2 days', now() - interval '2 days');
select pg_temp.mk('cOld', 'tw', 'w1', 'critical', 'closed', 'sw', 'sw', now() - interval '12 days', false, false, 'sw', now() - interval '8 days', now() - interval '8 days');
select pg_temp.mk('cLow', 'tw', 'w1', 'low', 'closed', 'sw', 'sw', now() - interval '3 days', false, false, 'sw', now() - interval '1 day', now() - interval '1 day');
create function pg_temp.alerts(u text, at timestamptz default now()) returns jsonb language plpgsql as $f$
begin return pg_temp.rpc(u, format($q$select public.issue_alerts(%L::timestamptz)$q$, at)); end $f$;
create function pg_temp.order_of(r jsonb, part text) returns text language sql as $$
  select coalesce(string_agg((select k from ids where v = (e->>'id')::uuid), ',' order by o), '') from jsonb_array_elements(r->part) with ordinality t(e, o) $$;
select is(pg_temp.order_of(pg_temp.alerts('uaw'), 'alerts'), 'aS,aC,aH,aH2,aR', 'alerts: stopped first, then Critical, then High, newest first within each (resolved-awaiting-verification still alerts)');
select is((pg_temp.alerts('uaw')->>'alert_count')::int, 5, 'alert_count');
select is(pg_temp.order_of(pg_temp.alerts('uaw'), 'recently_closed'), 'cH', 'recently closed: High/Critical closed in the last 7 days (not older, not Low)');
select is(pg_temp.alerts('uaw')->'recently_closed'->0->>'resolution_notes', 'fixed cH', 'with the resolution notes');
select is(pg_temp.alerts('uaw')->'recently_closed'->0->>'resolved_by_name', 'Sup W', 'and who resolved it');
select is(pg_temp.alerts('uaw')->'alerts'->0->>'machine_stopped', 'true', 'the stopped machine is flagged');
select is(pg_temp.alerts('uaw')->'alerts'->0->>'needs_owner', 'true', 'and shows "Needs owner" when nobody is accountable');
select is((pg_temp.alerts('uaw')->'alerts'->0->>'age_minutes')::int, 300, 'age in minutes from the report time');
select is(pg_temp.alerts('uaw')->'alerts'->3->>'escalated', 'true', 'escalation is shown');
select is(pg_temp.order_of(pg_temp.alerts('uaw', now() + interval '4 days'), 'recently_closed'), 'cH', 'at +4 days the close (2 days old now) is 6 days old: still inside the window');
select is(pg_temp.order_of(pg_temp.alerts('uaw', now() + interval '5 days 12 hours'), 'recently_closed'), '', 'and at +5.5 days (7.5 days old) it has fallen out');
select is(pg_temp.alerts('sw')->>'code', 'not_allowed', 'a supervisor is denied');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and source = 'rpc:issue_alerts' and reason = 'role'), 1, 'audited as role');
select is(pg_temp.alerts('sa')->>'code', 'not_allowed', 'a Super Admin is denied');
select is(pg_temp.alerts('nomem')->>'code', 'not_allowed', 'a stranger is denied');
select is(pg_temp.order_of(pg_temp.alerts('uax'), 'alerts'), 'i4', 'tenant X: i4 (High, resolved, awaiting verification) still alerts; i5 was verified above');
select is(pg_temp.order_of(pg_temp.alerts('uay'), 'alerts'), '', 'tenant Y: none of tenant X''s or W''s alerts');
select is(pg_temp.order_of(pg_temp.alerts('uax'), 'recently_closed'), 'i5', 'tenant X: i5 closed (verified) a moment ago shows under recently closed');

select * from finish();
rollback;
