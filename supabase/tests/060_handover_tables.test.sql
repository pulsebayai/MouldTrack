-- 08 step 1 (AC-13 tables, D1, D8): RLS on the six handover tables (Unit Admin reads own tenant only), composite tenant FKs, append-only
-- history, member-same-tenant trigger, check constraints, registry, issue_action's two new types, the backfill and "registration enforces".
-- Self-contained; rolled back. Phones +91 90000 28xxx.
begin;
create extension if not exists pgtap with schema extensions;
select plan(47);

create temp table ids (k text primary key, v uuid);
create function pg_temp.id(k text) returns uuid language sql as $$ select v from ids where k = $1 $$;
create function pg_temp.as_user(k text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where ids.k = $1), 'role', 'authenticated')::text, true) $$;
grant select on ids to authenticated, anon, service_role;

insert into auth.users (id, email, aud, role)
select u, 'tap60-' || n || '@example.test', 'authenticated', 'authenticated' from (values
  ('00000000-0000-4000-c800-0000000000a1'::uuid, 'uax'), ('00000000-0000-4000-c800-0000000000a2', 'sx'), ('00000000-0000-4000-c800-0000000000b1', 'uay'),
  ('00000000-0000-4000-c800-0000000000b2', 'sy'), ('00000000-0000-4000-c800-0000000000f1', 'sa')) t(u, n);
insert into ids values ('uax', '00000000-0000-4000-c800-0000000000a1'), ('sx', '00000000-0000-4000-c800-0000000000a2'), ('uay', '00000000-0000-4000-c800-0000000000b1'),
  ('sy', '00000000-0000-4000-c800-0000000000b2'), ('sa', '00000000-0000-4000-c800-0000000000f1'),
  ('tx', '50000000-0000-4000-c800-00000000000a'), ('ty', '50000000-0000-4000-c800-00000000000b');
insert into public.tenant (id, name, status, timezone) values
  ('50000000-0000-4000-c800-00000000000a', 'tap60 org X', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c800-00000000000b', 'tap60 org Y', 'active', 'Asia/Kolkata');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('50000000-0000-4000-c800-00000000000a', '00000000-0000-4000-c800-0000000000a1', 'unit_admin', 'active', 'UA X', 'UA-X', '+919000028101', false),
  ('50000000-0000-4000-c800-00000000000a', '00000000-0000-4000-c800-0000000000a2', 'supervisor', 'active', 'Sup X', 'S-X', '+919000028102', false),
  ('50000000-0000-4000-c800-00000000000b', '00000000-0000-4000-c800-0000000000b1', 'unit_admin', 'active', 'UA Y', 'UA-Y', '+919000028103', false),
  ('50000000-0000-4000-c800-00000000000b', '00000000-0000-4000-c800-0000000000b2', 'supervisor', 'active', 'Sup Y', 'S-Y', '+919000028104', false);
insert into public.platform_admin (user_id, full_name, phone_e164, status, must_change_password) values
  ('00000000-0000-4000-c800-0000000000f1', 'SA 60', '+919000028105', 'active', false);
insert into public.site (id, tenant_id, name, timezone) values
  ('51000000-0000-4000-c800-00000000000a', pg_temp.id('tx'), 'Plant X', 'Asia/Kolkata'), ('51000000-0000-4000-c800-00000000000b', pg_temp.id('ty'), 'Plant Y', 'Asia/Kolkata');
insert into public.machine (id, tenant_id, site_id, code, name) values
  ('53000000-0000-4000-c800-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c800-00000000000a', 'M-1', 'Press 1'),
  ('53000000-0000-4000-c800-0000000000b1', pg_temp.id('ty'), '51000000-0000-4000-c800-00000000000b', 'Y-1', 'Y press');
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time) values
  ('52000000-0000-4000-c800-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c800-00000000000a', 'Day', '06:00', '14:00'),
  ('52000000-0000-4000-c800-0000000000b1', pg_temp.id('ty'), '51000000-0000-4000-c800-00000000000b', 'Day', '06:00', '14:00');
insert into public.machine_issue (id, tenant_id, machine_id, category_id, priority, description, reported_by, accountable_owner_id)
select '5a000000-0000-4000-c800-0000000000a1', pg_temp.id('tx'), '53000000-0000-4000-c800-0000000000a1', c.id, 'high', 'X issue', pg_temp.id('sx'), pg_temp.id('sx')
  from public.issue_category c where c.tenant_id = pg_temp.id('tx') limit 1;
insert into public.machine_issue (id, tenant_id, machine_id, category_id, priority, description, reported_by, accountable_owner_id)
select '5a000000-0000-4000-c800-0000000000b1', pg_temp.id('ty'), '53000000-0000-4000-c800-0000000000b1', c.id, 'high', 'Y issue', pg_temp.id('sy'), pg_temp.id('sy')
  from public.issue_category c where c.tenant_id = pg_temp.id('ty') limit 1;
insert into ids values ('ix', '5a000000-0000-4000-c800-0000000000a1'), ('iy', '5a000000-0000-4000-c800-0000000000b1'),
  ('shx', '52000000-0000-4000-c800-0000000000a1'), ('shy', '52000000-0000-4000-c800-0000000000b1');

-- Fixture rows in every handover table, for both tenants (as the table owner)
insert into public.handover_setting (tenant_id, overdue_minutes, required) values (pg_temp.id('tx'), 45, true), (pg_temp.id('ty'), 60, true);
insert into public.handover_session (tenant_id, shift_id, shift_date, supervisor_id, handover_start, overdue_minutes) values
  (pg_temp.id('tx'), pg_temp.id('shx'), date '2026-03-10', pg_temp.id('sx'), '2026-03-10 00:30+00', 45),
  (pg_temp.id('ty'), pg_temp.id('shy'), date '2026-03-10', pg_temp.id('sy'), '2026-03-10 00:30+00', 60);
insert into public.issue_acknowledgement (tenant_id, issue_id, shift_id, shift_date, supervisor_id, kind, remark) values
  (pg_temp.id('tx'), pg_temp.id('ix'), pg_temp.id('shx'), date '2026-03-10', pg_temp.id('sx'), 'refused', 'No fixture'),
  (pg_temp.id('ty'), pg_temp.id('iy'), pg_temp.id('shy'), date '2026-03-10', pg_temp.id('sy'), 'acknowledged', null);
insert into public.handover_declaration (tenant_id, shift_id, shift_date, supervisor_id, covered_issue_ids) values
  (pg_temp.id('tx'), pg_temp.id('shx'), date '2026-03-10', pg_temp.id('sx'), array[pg_temp.id('ix')]),
  (pg_temp.id('ty'), pg_temp.id('shy'), date '2026-03-10', pg_temp.id('sy'), '{}');
insert into public.handover_exception (tenant_id, issue_id, shift_id, shift_date, ua_id, reason, owner_id, kept) values
  (pg_temp.id('tx'), pg_temp.id('ix'), pg_temp.id('shx'), date '2026-03-10', pg_temp.id('uax'), 'Keep', pg_temp.id('sx'), true),
  (pg_temp.id('ty'), pg_temp.id('iy'), pg_temp.id('shy'), date '2026-03-10', pg_temp.id('uay'), 'Keep', pg_temp.id('sy'), true);
insert into public.handover_note (tenant_id, issue_id, author_id, shift_id, shift_date, note) values
  (pg_temp.id('tx'), pg_temp.id('ix'), pg_temp.id('sx'), pg_temp.id('shx'), date '2026-03-10', 'Watch the heater'),
  (pg_temp.id('ty'), pg_temp.id('iy'), pg_temp.id('sy'), pg_temp.id('shy'), date '2026-03-10', 'Watch the heater');

-- Registry and shape -----------------------------------------------------------------------------------------------------
select is((select count(*)::int from app.audit_action where feature = '08'), 6, 'registry: 6 actions registered by 08');
select ok((select bool_and(app.is_known_audit_action(a)) from unnest(array['handover.acknowledged', 'handover.refused', 'handover.declared', 'handover.exception',
  'handover.setting_updated', 'handover.note_added']) a), 'and they are the six names');
select is((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
             where c.relname in ('handover_setting', 'handover_session', 'issue_acknowledgement', 'handover_declaration', 'handover_exception', 'handover_note')
               and c.relrowsecurity and c.relforcerowsecurity), 6, 'RLS enabled and forced on all six tables');
select lives_ok($$ insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, status_after)
  values ('50000000-0000-4000-c800-00000000000a', '5a000000-0000-4000-c800-0000000000a1', '00000000-0000-4000-c800-0000000000a2', 'supervisor', 'handover_ack', 'open') $$,
  'issue_action accepts the type handover_ack');
select lives_ok($$ insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, status_after)
  values ('50000000-0000-4000-c800-00000000000a', '5a000000-0000-4000-c800-0000000000a1', '00000000-0000-4000-c800-0000000000a2', 'supervisor', 'handover_refuse', 'open') $$,
  'issue_action accepts the type handover_refuse');
select throws_ok($$ insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, status_after)
  values ('50000000-0000-4000-c800-00000000000a', '5a000000-0000-4000-c800-0000000000a1', '00000000-0000-4000-c800-0000000000a2', 'supervisor', 'bogus', 'open') $$,
  '23514', null, 'and still refuses an unknown type');

-- Isolation --------------------------------------------------------------------------------------------------------------
create function pg_temp.rows_seen() returns text language plpgsql as $$
declare t text; n bigint; out text := '';
begin
  foreach t in array array['handover_setting', 'handover_session', 'issue_acknowledgement', 'handover_declaration', 'handover_exception', 'handover_note'] loop
    execute format('select count(*) from public.%I', t) into n;
    out := out || t || ':' || n || ' ';
  end loop;
  return btrim(out);
end $$;
grant execute on function pg_temp.rows_seen() to authenticated;
set local role authenticated;
select pg_temp.as_user('uax');
select is(pg_temp.rows_seen(), 'handover_setting:1 handover_session:1 issue_acknowledgement:1 handover_declaration:1 handover_exception:1 handover_note:1',
  'a Unit Admin reads exactly their own tenant''s row in every table');
select pg_temp.as_user('uay');
select is(pg_temp.rows_seen(), 'handover_setting:1 handover_session:1 issue_acknowledgement:1 handover_declaration:1 handover_exception:1 handover_note:1', 'and so does the other tenant''s');
select pg_temp.as_user('sx');
select is(pg_temp.rows_seen(), 'handover_setting:0 handover_session:0 issue_acknowledgement:0 handover_declaration:0 handover_exception:0 handover_note:0',
  'a supervisor reads none of the raw tables (functions only)');
select pg_temp.as_user('sa');
select is(pg_temp.rows_seen(), 'handover_setting:0 handover_session:0 issue_acknowledgement:0 handover_declaration:0 handover_exception:0 handover_note:0', 'a Super Admin reads none');
select pg_temp.as_user('uax');
select throws_ok($$ insert into public.handover_note (tenant_id, issue_id, author_id, shift_id, shift_date, note)
  values ('50000000-0000-4000-c800-00000000000a', '5a000000-0000-4000-c800-0000000000a1', '00000000-0000-4000-c800-0000000000a2', '52000000-0000-4000-c800-0000000000a1', '2026-03-10', 'x') $$,
  '42501', null, 'a client cannot insert a note');
select throws_ok($$ insert into public.handover_declaration (tenant_id, shift_id, shift_date, supervisor_id) values
  ('50000000-0000-4000-c800-00000000000a', '52000000-0000-4000-c800-0000000000a1', '2026-03-10', '00000000-0000-4000-c800-0000000000a2') $$, '42501', null, 'nor a declaration');
select throws_ok($$ update public.handover_setting set overdue_minutes = 15 $$, '42501', null, 'nor change the setting through the table');
select throws_ok($$ delete from public.handover_setting $$, '42501', null, 'nor delete it');
reset role;

-- Append-only -------------------------------------------------------------------------------------------------------------
select throws_ok($$ update public.handover_session set overdue_minutes = 30 $$, 'P0001', 'handover_session is append-only', 'handover_session: update refused');
select throws_ok($$ delete from public.handover_session $$, 'P0001', 'handover_session is append-only', 'handover_session: delete refused');
select throws_ok($$ update public.issue_acknowledgement set kind = 'acknowledged' $$, 'P0001', 'issue_acknowledgement is append-only', 'issue_acknowledgement: update refused');
select throws_ok($$ delete from public.issue_acknowledgement $$, 'P0001', 'issue_acknowledgement is append-only', 'issue_acknowledgement: delete refused');
select throws_ok($$ update public.handover_declaration set text_version = 2 $$, 'P0001', 'handover_declaration is append-only', 'handover_declaration: update refused');
select throws_ok($$ delete from public.handover_declaration $$, 'P0001', 'handover_declaration is append-only', 'handover_declaration: delete refused');
select throws_ok($$ update public.handover_exception set kept = false $$, 'P0001', 'handover_exception is append-only', 'handover_exception: update refused');
select throws_ok($$ delete from public.handover_exception $$, 'P0001', 'handover_exception is append-only', 'handover_exception: delete refused');
select throws_ok($$ update public.handover_note set note = 'changed' $$, 'P0001', 'handover_note is append-only', 'handover_note: update refused');
select throws_ok($$ delete from public.handover_note $$, 'P0001', 'handover_note is append-only', 'handover_note: delete refused');
select throws_ok($$ truncate public.handover_note $$, 'P0001', 'handover_note is append-only', 'truncate refused too');
select throws_ok($$ delete from public.handover_setting $$, 'P0001', 'handover_setting is append-only', 'handover_setting: delete refused');
select lives_ok($$ update public.handover_setting set overdue_minutes = 50 where tenant_id = '50000000-0000-4000-c800-00000000000a' $$, 'handover_setting: the owner may update (ho_set_overdue does)');

-- Composite FKs, member trigger, checks ----------------------------------------------------------------------------------------
select throws_ok($$ insert into public.issue_acknowledgement (tenant_id, issue_id, shift_id, shift_date, supervisor_id, kind)
  values ('50000000-0000-4000-c800-00000000000a', '5a000000-0000-4000-c800-0000000000b1', '52000000-0000-4000-c800-0000000000a1', '2026-03-10', '00000000-0000-4000-c800-0000000000a2', 'acknowledged') $$,
  '23503', null, 'an acknowledgement cannot reference another tenant''s issue (composite FK)');
select throws_ok($$ insert into public.handover_declaration (tenant_id, shift_id, shift_date, supervisor_id)
  values ('50000000-0000-4000-c800-00000000000a', '52000000-0000-4000-c800-0000000000b1', '2026-03-10', '00000000-0000-4000-c800-0000000000a2') $$,
  '23503', null, 'a declaration cannot reference another tenant''s shift');
select throws_ok($$ insert into public.handover_note (tenant_id, issue_id, author_id, shift_id, shift_date, note)
  values ('50000000-0000-4000-c800-00000000000a', '5a000000-0000-4000-c800-0000000000a1', '5a000000-0000-4000-c800-0000000000b1', '52000000-0000-4000-c800-0000000000a1', '2026-03-10', 'x') $$,
  '23514', null, 'a note''s author must belong to the tenant');
select throws_ok($$ insert into public.handover_exception (tenant_id, issue_id, shift_id, shift_date, ua_id, reason, owner_id, kept)
  values ('50000000-0000-4000-c800-00000000000a', '5a000000-0000-4000-c800-0000000000a1', '52000000-0000-4000-c800-0000000000a1', '2026-03-11', '00000000-0000-4000-c800-0000000000a1', 'r',
          '00000000-0000-4000-c800-0000000000b2', false) $$, '23514', null, 'an exception''s owner must belong to the tenant');
select throws_ok($$ insert into public.issue_acknowledgement (tenant_id, issue_id, shift_id, shift_date, supervisor_id, kind)
  values ('50000000-0000-4000-c800-00000000000a', '5a000000-0000-4000-c800-0000000000a1', '52000000-0000-4000-c800-0000000000a1', '2026-03-11', '00000000-0000-4000-c800-0000000000a2', 'refused') $$,
  '23514', null, 'a refusal needs a reason');
select throws_ok($$ insert into public.issue_acknowledgement (tenant_id, issue_id, shift_id, shift_date, supervisor_id, kind, remark)
  values ('50000000-0000-4000-c800-00000000000a', '5a000000-0000-4000-c800-0000000000a1', '52000000-0000-4000-c800-0000000000a1', '2026-03-11', '00000000-0000-4000-c800-0000000000a2', 'acknowledged', repeat('x', 201)) $$,
  '23514', null, 'a remark is at most 200 characters');
select throws_ok($$ insert into public.handover_note (tenant_id, issue_id, author_id, shift_id, shift_date, note)
  values ('50000000-0000-4000-c800-00000000000a', '5a000000-0000-4000-c800-0000000000a1', '00000000-0000-4000-c800-0000000000a2', '52000000-0000-4000-c800-0000000000a1', '2026-03-11', repeat('x', 301)) $$,
  '23514', null, 'a note is at most 300 characters');
select throws_ok($$ update public.handover_setting set overdue_minutes = 14 where tenant_id = '50000000-0000-4000-c800-00000000000a' $$, '23514', null, 'overdue minutes: 14 refused');
select throws_ok($$ update public.handover_setting set overdue_minutes = 481 where tenant_id = '50000000-0000-4000-c800-00000000000a' $$, '23514', null, 'overdue minutes: 481 refused');
select lives_ok($$ update public.handover_setting set overdue_minutes = 480 where tenant_id = '50000000-0000-4000-c800-00000000000a' $$, 'overdue minutes: 480 accepted');
select throws_ok($$ insert into public.handover_session (tenant_id, shift_id, shift_date, supervisor_id, handover_start, overdue_minutes)
  values ('50000000-0000-4000-c800-00000000000a', '52000000-0000-4000-c800-0000000000a1', '2026-03-10', '00000000-0000-4000-c800-0000000000a2', '2026-03-10 00:30+00', 45) $$,
  '23505', null, 'one session per supervisor, occurrence and handover start');

-- Enforcement: backfill + registration (D1) -------------------------------------------------------------------------------------
insert into public.tenant (id, name, status, timezone) values ('50000000-0000-4000-c800-00000000000c', 'tap60 org Z (direct insert)', 'active', 'Asia/Kolkata');
select is((select count(*)::int from public.handover_setting where tenant_id = '50000000-0000-4000-c800-00000000000c'), 0, 'a tenant inserted directly has no handover_setting row (not gated)');
select is(app._ho_enforced('50000000-0000-4000-c800-00000000000c'), false, 'and is not enforced');
select ok(app._ho_backfill() >= 1, 'the backfill creates the missing rows');
select is((select required from public.handover_setting where tenant_id = '50000000-0000-4000-c800-00000000000c'), true, 'as required = true');
select is(app._ho_backfill(), 0, 'and is idempotent');
select is(app._ho_enforced('50000000-0000-4000-c800-00000000000c'), true, 'the tenant is enforced after the backfill');
insert into ids select 'reg', (app.pa_tenant_create('00000000-0000-4000-c800-0000000000f1', gen_random_uuid(), 'tap60 registered', null, null) ->> 'tenant_id')::uuid;
select is((select s.required::text || ':' || s.overdue_minutes from public.handover_setting s where s.tenant_id = pg_temp.id('reg')), 'true:60',
  'registration through the Console creates the setting row (required, 60 minutes) in the same transaction');
select is((select count(*)::int from public.handover_setting s join public.tenant t on t.id = s.tenant_id where t.name = 'tap60 registered' and s.required), 1, 'exactly one row, required');
select is(app._ho_enforced(null), false, 'a null tenant is not enforced');

select * from finish();
rollback;
