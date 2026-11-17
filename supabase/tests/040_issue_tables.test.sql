-- 07 step 1 (AC-3, AC-10, AC-12, AC-13 DB part, tables): RLS on the five issue tables, composite tenant FKs, append-only history, attachment guard,
-- stopped -> critical, starter categories (existing tenants + new-tenant trigger), category uniqueness, registry. Self-contained; rolled back.
begin;
create extension if not exists pgtap with schema extensions;
select plan(54);

create temp table ids (k text primary key, v uuid);
create function pg_temp.id(k text) returns uuid language sql as $$ select v from ids where k = $1 $$;
create function pg_temp.as_user(k text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where ids.k = $1), 'role', 'authenticated')::text, true) $$;
grant select on ids to authenticated, anon, service_role;

insert into auth.users (id, email, aud, role)
select u, 'tap40-' || n || '@example.test', 'authenticated', 'authenticated' from (values
  ('00000000-0000-4000-c700-0000000000a1'::uuid, 'uax'), ('00000000-0000-4000-c700-0000000000a2', 'sx'), ('00000000-0000-4000-c700-0000000000b1', 'uay'),
  ('00000000-0000-4000-c700-0000000000b2', 'sy'), ('00000000-0000-4000-c700-0000000000f1', 'sa')) t(u, n);
insert into ids values ('uax', '00000000-0000-4000-c700-0000000000a1'), ('sx', '00000000-0000-4000-c700-0000000000a2'), ('uay', '00000000-0000-4000-c700-0000000000b1'),
  ('sy', '00000000-0000-4000-c700-0000000000b2'), ('sa', '00000000-0000-4000-c700-0000000000f1'),
  ('tx', '50000000-0000-4000-c700-00000000000a'), ('ty', '50000000-0000-4000-c700-00000000000b');
-- a tenant that exists before any category is seeded by the trigger is simulated by deleting its categories then re-running the seed
insert into public.tenant (id, name, status, timezone) values
  ('50000000-0000-4000-c700-00000000000a', 'tap40 org X', 'active', 'Asia/Kolkata'),
  ('50000000-0000-4000-c700-00000000000b', 'tap40 org Y', 'active', 'Asia/Kolkata');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('50000000-0000-4000-c700-00000000000a', '00000000-0000-4000-c700-0000000000a1', 'unit_admin', 'active', 'UA X', 'UA-X', '+919000020701', false),
  ('50000000-0000-4000-c700-00000000000a', '00000000-0000-4000-c700-0000000000a2', 'supervisor', 'active', 'Sup X', 'S-X', '+919000020702', false),
  ('50000000-0000-4000-c700-00000000000b', '00000000-0000-4000-c700-0000000000b1', 'unit_admin', 'active', 'UA Y', 'UA-Y', '+919000020703', false),
  ('50000000-0000-4000-c700-00000000000b', '00000000-0000-4000-c700-0000000000b2', 'supervisor', 'active', 'Sup Y', 'S-Y', '+919000020704', false);
insert into public.platform_admin (user_id, full_name, phone_e164, status, must_change_password) values
  ('00000000-0000-4000-c700-0000000000f1', 'SA 40', '+919000020705', 'active', false);
insert into public.site (id, tenant_id, name, timezone) values
  ('51000000-0000-4000-c700-00000000000a', pg_temp.id('tx'), 'Plant X', 'Asia/Kolkata'), ('51000000-0000-4000-c700-00000000000b', pg_temp.id('ty'), 'Plant Y', 'Asia/Kolkata');
insert into public.machine (id, tenant_id, site_id, code, name) values
  ('53000000-0000-4000-c700-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c700-00000000000a', 'M-1', 'Press 1'),
  ('53000000-0000-4000-c700-0000000000b1', pg_temp.id('ty'), '51000000-0000-4000-c700-00000000000b', 'Y-1', 'Y press');
insert into ids values ('mx', '53000000-0000-4000-c700-0000000000a1'), ('my', '53000000-0000-4000-c700-0000000000b1');

-- Registry and starter categories ---------------------------------------------------------------------------------------
select is((select count(*)::int from app.audit_action where feature = '07'), 16, 'registry: 16 actions registered by 07');
select ok((select bool_and(app.is_known_audit_action(a)) from unnest(array['issue.reported', 'issue.noted', 'issue.started', 'issue.assignee_set', 'issue.escalated',
  'issue.escalation_acknowledged', 'issue.reassigned', 'issue.resolved', 'issue.verified', 'issue.verification_rejected', 'issue.reopened',
  'issue_category.created', 'issue_category.updated', 'issue_category.retired', 'issue_category.reinstated', 'attachment.added']) a), 'every issue action is known');
select is((select string_agg(name, ',' order by sort) from public.issue_category where tenant_id = pg_temp.id('tx')),
  'Mechanical,Electrical,Mould/Tool,Material,Quality,Safety,Other', 'a new tenant gets the starter categories by trigger');
select is((select count(*)::int from public.issue_category where tenant_id = pg_temp.id('ty')), 7, 'every new tenant gets seven');
delete from public.issue_category where tenant_id = pg_temp.id('ty');
select app.issue_seed_categories(pg_temp.id('ty'));
select is((select count(*)::int from public.issue_category where tenant_id = pg_temp.id('ty')), 7, 'the backfill function seeds an existing tenant');
select app.issue_seed_categories(pg_temp.id('ty'));
select is((select count(*)::int from public.issue_category where tenant_id = pg_temp.id('ty')), 7, 'and is idempotent');
insert into ids select 'cx', id from public.issue_category where tenant_id = pg_temp.id('tx') and name = 'Mechanical';
insert into ids select 'cy', id from public.issue_category where tenant_id = pg_temp.id('ty') and name = 'Mechanical';

-- Category rules ------------------------------------------------------------------------------------------------------------
select throws_ok($$ insert into public.issue_category (tenant_id, name) values (pg_temp.id('tx'), 'mechanical') $$, '23505', null, 'category names are unique per tenant, case-insensitively');
select lives_ok($$ insert into public.issue_category (tenant_id, name) values (pg_temp.id('ty'), 'Hydraulics') $$, 'a custom category can be added');
select lives_ok($$ insert into public.issue_category (tenant_id, name) select pg_temp.id('tx'), 'Hydraulics' $$, 'the same name in another tenant is fine');
select throws_ok($$ insert into public.issue_category (tenant_id, name) values (pg_temp.id('tx'), '') $$, '23514', null, 'an empty name is refused');
select throws_ok($$ insert into public.issue_category (tenant_id, name) values (pg_temp.id('tx'), repeat('x', 41)) $$, '23514', null, 'a name over 40 characters is refused');
select throws_ok($$ insert into public.issue_category (tenant_id, name) values (pg_temp.id('tx'), ' padded ') $$, '23514', null, 'an untrimmed name is refused');

-- Issues ----------------------------------------------------------------------------------------------------------------------
insert into public.machine_issue (id, tenant_id, machine_id, category_id, priority, description, machine_stopped, reported_by, accountable_owner_id) values
  ('60000000-0000-4000-c700-0000000000a1', pg_temp.id('tx'), pg_temp.id('mx'), pg_temp.id('cx'), 'critical', 'Hydraulic leak', true, pg_temp.id('sx'), pg_temp.id('sx')),
  ('60000000-0000-4000-c700-0000000000b1', pg_temp.id('ty'), pg_temp.id('my'), pg_temp.id('cy'), 'low', 'Noise', false, pg_temp.id('sy'), pg_temp.id('sy'));
insert into ids values ('ix', '60000000-0000-4000-c700-0000000000a1'), ('iy', '60000000-0000-4000-c700-0000000000b1');
select is((select status from public.machine_issue where id = pg_temp.id('ix')), 'open', 'an issue starts Open');
select throws_ok($$ insert into public.machine_issue (tenant_id, machine_id, category_id, priority, description, machine_stopped, reported_by)
  values (pg_temp.id('tx'), pg_temp.id('mx'), pg_temp.id('cx'), 'high', 'x', true, pg_temp.id('sx')) $$, '23514', null, 'a stopped machine must be Critical (table check)');
select throws_ok($$ insert into public.machine_issue (tenant_id, machine_id, category_id, priority, description, reported_by)
  values (pg_temp.id('tx'), pg_temp.id('mx'), pg_temp.id('cx'), 'urgent', 'x', pg_temp.id('sx')) $$, '23514', null, 'an unknown priority is refused');
select throws_ok($$ insert into public.machine_issue (tenant_id, machine_id, category_id, priority, description, reported_by)
  values (pg_temp.id('tx'), pg_temp.id('mx'), pg_temp.id('cx'), 'low', '', pg_temp.id('sx')) $$, '23514', null, 'an empty description is refused');
select throws_ok($$ insert into public.machine_issue (tenant_id, machine_id, category_id, priority, description, reported_by)
  values (pg_temp.id('tx'), pg_temp.id('mx'), pg_temp.id('cx'), 'low', repeat('x', 1001), pg_temp.id('sx')) $$, '23514', null, 'a description over 1000 characters is refused');
select throws_ok($$ insert into public.machine_issue (tenant_id, machine_id, category_id, priority, description, reported_by, status)
  values (pg_temp.id('tx'), pg_temp.id('mx'), pg_temp.id('cx'), 'low', 'x', pg_temp.id('sx'), 'closed') $$, '23514', null, 'closed requires closed_at (resolution time is always computable)');
select throws_ok($$ insert into public.machine_issue (tenant_id, machine_id, category_id, priority, description, reported_by, status, closed_at)
  values (pg_temp.id('tx'), pg_temp.id('mx'), pg_temp.id('cx'), 'low', 'x', pg_temp.id('sx'), 'closed', now()) $$, '23514', null, 'closed also requires resolved_at and resolved_by');
select throws_ok($$ insert into public.machine_issue (tenant_id, machine_id, category_id, priority, description, reported_by, closed_at)
  values (pg_temp.id('tx'), pg_temp.id('mx'), pg_temp.id('cx'), 'low', 'x', pg_temp.id('sx'), now()) $$, '23514', null, 'closed_at on a non-closed issue is refused');
select throws_ok($$ insert into public.machine_issue (tenant_id, machine_id, category_id, priority, description, reported_by)
  values (pg_temp.id('tx'), pg_temp.id('my'), pg_temp.id('cx'), 'low', 'x', pg_temp.id('sx')) $$, '23503', null, 'composite FK: another tenant''s machine is refused');
select throws_ok($$ insert into public.machine_issue (tenant_id, machine_id, category_id, priority, description, reported_by)
  values (pg_temp.id('tx'), pg_temp.id('mx'), pg_temp.id('cy'), 'low', 'x', pg_temp.id('sx')) $$, '23503', null, 'composite FK: another tenant''s category is refused');
select throws_ok($$ insert into public.machine_issue (tenant_id, machine_id, category_id, priority, description, reported_by)
  values (pg_temp.id('tx'), pg_temp.id('mx'), pg_temp.id('cx'), 'low', 'x', pg_temp.id('sy')) $$, '23514', null, 'a reporter from another tenant is refused (trigger)');
select throws_ok($$ insert into public.machine_issue (tenant_id, machine_id, category_id, priority, description, reported_by, accountable_owner_id)
  values (pg_temp.id('tx'), pg_temp.id('mx'), pg_temp.id('cx'), 'low', 'x', pg_temp.id('sx'), pg_temp.id('sy')) $$, '23514', null, 'an owner from another tenant is refused (trigger)');

-- Actions and ownership history: append-only, composite FK ----------------------------------------------------------------------
insert into public.issue_action (id, tenant_id, issue_id, actor_id, actor_role, type, notes, status_after) values
  ('61000000-0000-4000-c700-0000000000a1', pg_temp.id('tx'), pg_temp.id('ix'), pg_temp.id('sx'), 'supervisor', 'note', 'first note', 'open'),
  ('61000000-0000-4000-c700-0000000000b1', pg_temp.id('ty'), pg_temp.id('iy'), pg_temp.id('sy'), 'supervisor', 'note', 'y note', 'open');
insert into public.issue_ownership_history (id, tenant_id, issue_id, previous_owner, new_owner, source, actor_id) values
  ('62000000-0000-4000-c700-0000000000a1', pg_temp.id('tx'), pg_temp.id('ix'), null, pg_temp.id('sx'), 'report', pg_temp.id('sx')),
  ('62000000-0000-4000-c700-0000000000b1', pg_temp.id('ty'), pg_temp.id('iy'), null, pg_temp.id('sy'), 'report', pg_temp.id('sy'));
select throws_ok($$ insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type) values (pg_temp.id('tx'), pg_temp.id('iy'), pg_temp.id('sx'), 'supervisor', 'note') $$,
  '23503', null, 'composite FK: an action on another tenant''s issue is refused');
select throws_ok($$ insert into public.issue_ownership_history (tenant_id, issue_id, new_owner, source, actor_id) values (pg_temp.id('tx'), pg_temp.id('iy'), pg_temp.id('sx'), 'report', pg_temp.id('sx')) $$,
  '23503', null, 'composite FK: ownership history on another tenant''s issue is refused');
select throws_ok($$ insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type) values (pg_temp.id('tx'), pg_temp.id('ix'), pg_temp.id('sx'), 'supervisor', 'delete') $$,
  '23514', null, 'an unknown action type is refused');
select throws_ok($$ insert into public.issue_ownership_history (tenant_id, issue_id, new_owner, source, actor_id) values (pg_temp.id('tx'), pg_temp.id('ix'), pg_temp.id('sx'), 'magic', pg_temp.id('sx')) $$,
  '23514', null, 'an unknown ownership source is refused');
select throws_ok($$ update public.issue_action set notes = 'edited' $$, 'P0001', 'issue_action is append-only', 'issue_action cannot be updated (even by the owner)');
select throws_ok($$ delete from public.issue_action $$, 'P0001', 'issue_action is append-only', 'issue_action cannot be deleted');
select throws_ok($$ truncate public.issue_action $$, 'P0001', 'issue_action is append-only', 'issue_action cannot be truncated');
select throws_ok($$ update public.issue_ownership_history set reason = 'x' $$, 'P0001', 'issue_ownership_history is append-only', 'ownership history cannot be updated');
select throws_ok($$ delete from public.issue_ownership_history $$, 'P0001', 'issue_ownership_history is append-only', 'ownership history cannot be deleted');
select throws_ok($$ truncate public.issue_ownership_history $$, 'P0001', 'issue_ownership_history is append-only', 'ownership history cannot be truncated');

-- Attachment guard ---------------------------------------------------------------------------------------------------------------
insert into public.attachment (id, tenant_id, entity_type, entity_id, storage_path, mime, size_bytes, sha256, uploaded_by) values
  ('63000000-0000-4000-c700-0000000000a1', pg_temp.id('tx'), 'issue_action', '61000000-0000-4000-c700-0000000000a1',
   'tenant/50000000-0000-4000-c700-00000000000a/issue/60000000-0000-4000-c700-0000000000a1/63000000-0000-4000-c700-0000000000a1.png', 'image/png', 100, repeat('a', 64), pg_temp.id('sx')),
  ('63000000-0000-4000-c700-0000000000b1', pg_temp.id('ty'), 'issue_action', '61000000-0000-4000-c700-0000000000b1',
   'tenant/50000000-0000-4000-c700-00000000000b/issue/60000000-0000-4000-c700-0000000000b1/63000000-0000-4000-c700-0000000000b1.png', 'image/png', 100, repeat('b', 64), pg_temp.id('sy'));
select throws_ok($$ insert into public.attachment (tenant_id, entity_type, entity_id, storage_path, mime, size_bytes, sha256, uploaded_by)
  values (pg_temp.id('tx'), 'issue_action', gen_random_uuid(), 'tenant/50000000-0000-4000-c700-00000000000b/x.png', 'image/png', 1, repeat('a', 64), pg_temp.id('sx')) $$, '23514', null, 'a path outside the tenant prefix is refused');
select throws_ok($$ insert into public.attachment (tenant_id, entity_type, entity_id, storage_path, mime, size_bytes, sha256, uploaded_by)
  values (pg_temp.id('tx'), 'issue_action', gen_random_uuid(), 'tenant/50000000-0000-4000-c700-00000000000a/x.gif', 'image/gif', 1, repeat('a', 64), pg_temp.id('sx')) $$, '23514', null, 'only JPEG, PNG and WebP');
select throws_ok($$ insert into public.attachment (tenant_id, entity_type, entity_id, storage_path, mime, size_bytes, sha256, uploaded_by)
  values (pg_temp.id('tx'), 'issue_action', gen_random_uuid(), 'tenant/50000000-0000-4000-c700-00000000000a/x.png', 'image/png', 5242881, repeat('a', 64), pg_temp.id('sx')) $$, '23514', null, 'over 5 MB is refused');
select throws_ok($$ insert into public.attachment (tenant_id, entity_type, entity_id, storage_path, mime, size_bytes, sha256, uploaded_by)
  values (pg_temp.id('tx'), 'issue_action', gen_random_uuid(), 'tenant/50000000-0000-4000-c700-00000000000a/x.png', 'image/png', 1, 'nothex', pg_temp.id('sx')) $$, '23514', null, 'the checksum must be a SHA-256 hex digest');
select throws_ok($$ update public.attachment set size_bytes = 5 where id = '63000000-0000-4000-c700-0000000000a1' $$, 'P0001', null, 'a pending attachment cannot change other columns');
select throws_ok($$ update public.attachment set status = 'ready' where id = '63000000-0000-4000-c700-0000000000a1' $$, '23514', null, 'ready requires ready_at (check)');
select lives_ok($$ update public.attachment set status = 'ready', ready_at = now() where id = '63000000-0000-4000-c700-0000000000a1' $$, 'pending to ready is the one allowed change');
select throws_ok($$ update public.attachment set status = 'pending', ready_at = null where id = '63000000-0000-4000-c700-0000000000a1' $$, 'P0001', null, 'ready cannot go back to pending');
select throws_ok($$ update public.attachment set ready_at = now() where id = '63000000-0000-4000-c700-0000000000a1' $$, 'P0001', null, 'a ready attachment cannot change at all');
select throws_ok($$ delete from public.attachment $$, 'P0001', 'attachment is append-only', 'attachments cannot be deleted');

-- RLS ---------------------------------------------------------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('uax');
select is((select count(*)::int from public.issue_category), 8, 'UA X reads its tenant''s categories (7 + 1)');
select is((select count(*)::int from public.machine_issue), 1, 'UA X reads only its tenant''s issue');
select is((select count(*)::int from public.issue_action) + (select count(*)::int from public.issue_ownership_history) + (select count(*)::int from public.attachment), 3, 'UA X reads its action, ownership row and attachment, nothing of Y');
select throws_ok($$ update public.machine_issue set status = 'closed' $$, '42501', null, 'a client cannot update an issue');
select throws_ok($$ insert into public.issue_category (tenant_id, name) values (pg_temp.id('tx'), 'Own') $$, '42501', null, 'a client cannot insert a category');
select pg_temp.as_user('sx');
select is((select count(*)::int from public.issue_category), 8, 'a supervisor reads categories');
select is((select count(*)::int from public.machine_issue) + (select count(*)::int from public.issue_action) + (select count(*)::int from public.issue_ownership_history) + (select count(*)::int from public.attachment), 0,
  'a supervisor has no direct select on the issue tables (reads go through issue_list/issue_detail)');
select pg_temp.as_user('sa');
select is((select count(*)::int from public.issue_category) + (select count(*)::int from public.machine_issue) + (select count(*)::int from public.issue_action)
          + (select count(*)::int from public.issue_ownership_history) + (select count(*)::int from public.attachment), 0, 'a Super Admin reads nothing from the five tables');
reset role;
set local role anon;
select throws_ok($$ select count(*) from public.machine_issue $$, '42501', null, 'anon has no access');
reset role;
set local role service_role;
select throws_ok($$ update public.machine_issue set status = 'open' $$, '42501', null, 'service_role cannot update issues either');
reset role;

select * from finish();
rollback;
