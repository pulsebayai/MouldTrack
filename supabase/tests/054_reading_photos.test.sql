-- 06 step 6 (D6): photos on readings through 07's attachment model: rd_attachment_begin / rd_attachment_commit, entity type `production_reading`,
-- Storage visibility (owner of the machine in that occurrence, Unit Admins; nobody else, no Super Admin), cover moves visibility, limits, replay, audit,
-- the additive redefinition of app_policy.can_see_attachment keeping 07's issue branch. Self-contained; rolled back. Objects are metadata-only rows.
begin;
create extension if not exists pgtap with schema extensions;
select plan(48);

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
create function pg_temp.keep(k text, r jsonb) returns jsonb language plpgsql as $f$
begin
  if (r->>'ok')::boolean then insert into ids values (k, (r->>'id')::uuid) on conflict on constraint ids_pkey do update set v = excluded.v; end if;
  return r;
end $f$;
create function pg_temp.path(k text) returns text language sql as $$ select storage_path from public.attachment where id = pg_temp.id(k) $$;
create function pg_temp.sha() returns text language sql as $$ select repeat('cd', 32) $$;
create function pg_temp.try(u text, q text) returns text language plpgsql as $f$
begin
  perform pg_temp.as_user(u);
  set local role authenticated;
  execute q;
  reset role;
  return 'ok';
exception when others then
  reset role;
  return sqlstate;
end $f$;
create function pg_temp.seen(u text) returns int language plpgsql as $f$
declare n int;
begin
  perform pg_temp.as_user(u);
  set local role authenticated;
  select count(*)::int into n from storage.objects where bucket_id = 'attachments';
  reset role;
  return n;
end $f$;
create function pg_temp.png(k text, size int default 100) returns void language sql as $$
  insert into storage.objects (bucket_id, name, metadata) values ('attachments', pg_temp.path(k), jsonb_build_object('size', size, 'mimetype', 'image/png')) $$;
create function pg_temp.begin_(u text, rd text, req uuid default gen_random_uuid()) returns jsonb language sql as $$
  select pg_temp.rpc(u, format($q$select public.rd_attachment_begin(%L, %L, 'image/png', 100, pg_temp.sha())$q$, req, pg_temp.id(rd))) $$;
create function pg_temp.commit_(u text, att text, req uuid default gen_random_uuid()) returns jsonb language sql as $$
  select pg_temp.rpc(u, format($q$select public.rd_attachment_commit(%L, %L)$q$, req, pg_temp.id(att))) $$;

insert into auth.users (id, email, aud, role)
select u, 'tap54-' || n || '@example.test', 'authenticated', 'authenticated' from (values
  ('00000000-0000-4000-c654-0000000000a1'::uuid, 'uax'), ('00000000-0000-4000-c654-0000000000a2', 's1'), ('00000000-0000-4000-c654-0000000000a3', 's2'),
  ('00000000-0000-4000-c654-0000000000b1', 'uay'), ('00000000-0000-4000-c654-0000000000b2', 'sy'), ('00000000-0000-4000-c654-0000000000f1', 'sa')) t(u, n);
insert into ids values ('uax', '00000000-0000-4000-c654-0000000000a1'), ('s1', '00000000-0000-4000-c654-0000000000a2'), ('s2', '00000000-0000-4000-c654-0000000000a3'),
  ('uay', '00000000-0000-4000-c654-0000000000b1'), ('sy', '00000000-0000-4000-c654-0000000000b2'), ('sa', '00000000-0000-4000-c654-0000000000f1'),
  ('tx', '50000000-0000-4000-c654-00000000000a'), ('ty', '50000000-0000-4000-c654-00000000000b');
insert into public.tenant (id, name, status, timezone) values
  ('50000000-0000-4000-c654-00000000000a', 'tap54 org X', 'active', 'Asia/Kolkata'), ('50000000-0000-4000-c654-00000000000b', 'tap54 org Y', 'active', 'Asia/Kolkata');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('50000000-0000-4000-c654-00000000000a', '00000000-0000-4000-c654-0000000000a1', 'unit_admin', 'active', 'UA X', 'UA-X', '+919000025401', false),
  ('50000000-0000-4000-c654-00000000000a', '00000000-0000-4000-c654-0000000000a2', 'supervisor', 'active', 'Sup One', 'S1', '+919000025402', false),
  ('50000000-0000-4000-c654-00000000000a', '00000000-0000-4000-c654-0000000000a3', 'supervisor', 'active', 'Sup Two', 'S2', '+919000025403', false),
  ('50000000-0000-4000-c654-00000000000b', '00000000-0000-4000-c654-0000000000b1', 'unit_admin', 'active', 'UA Y', 'UA-Y', '+919000025404', false),
  ('50000000-0000-4000-c654-00000000000b', '00000000-0000-4000-c654-0000000000b2', 'supervisor', 'active', 'Sup Y', 'SY', '+919000025405', false);
insert into public.platform_admin (user_id, full_name, phone_e164, status, must_change_password) values ('00000000-0000-4000-c654-0000000000f1', 'SA 54', '+919000025406', 'active', false);
insert into public.site (id, tenant_id, name, timezone) values
  ('51000000-0000-4000-c654-00000000000a', pg_temp.id('tx'), 'Plant X', 'Asia/Kolkata'), ('51000000-0000-4000-c654-00000000000b', pg_temp.id('ty'), 'Plant Y', 'Asia/Kolkata');
insert into public.machine (id, tenant_id, site_id, code, name) values
  ('53000000-0000-4000-c654-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c654-00000000000a', 'M1', 'Press 1'),
  ('53000000-0000-4000-c654-0000000000a2', pg_temp.id('tx'), '51000000-0000-4000-c654-00000000000a', 'M2', 'Press 2'),
  ('53000000-0000-4000-c654-0000000000b1', pg_temp.id('ty'), '51000000-0000-4000-c654-00000000000b', 'Y1', 'Y press');
insert into public.product (id, tenant_id, code, description) values
  ('54000000-0000-4000-c654-0000000000a1', pg_temp.id('tx'), 'P-1', 'Part 1'), ('54000000-0000-4000-c654-0000000000b1', pg_temp.id('ty'), 'P-Y', 'Part Y');
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time) values
  ('55000000-0000-4000-c654-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c654-00000000000a', 'Day', '06:00', '14:00'),
  ('55000000-0000-4000-c654-0000000000b1', pg_temp.id('ty'), '51000000-0000-4000-c654-00000000000b', 'Y shift', '06:00', '14:00');
insert into ids values ('m1', '53000000-0000-4000-c654-0000000000a1'), ('m2', '53000000-0000-4000-c654-0000000000a2'), ('my', '53000000-0000-4000-c654-0000000000b1'),
  ('p1', '54000000-0000-4000-c654-0000000000a1'), ('py', '54000000-0000-4000-c654-0000000000b1'), ('day', '55000000-0000-4000-c654-0000000000a1'), ('shy', '55000000-0000-4000-c654-0000000000b1');
insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by) values
  (pg_temp.id('tx'), pg_temp.id('day'), pg_temp.id('m1'), pg_temp.id('s1'), date '2026-01-01', pg_temp.id('uax')),
  (pg_temp.id('ty'), pg_temp.id('shy'), pg_temp.id('my'), pg_temp.id('sy'), date '2026-01-01', pg_temp.id('uay'));
-- readings: r1 (M1, owned by s1), r2 (M2, unassigned), ry (tenant Y); on a fixed past date (the photo RPCs do not depend on the clock)
insert into public.production_reading (id, tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, late, recorded_by) values
  ('56000000-0000-4000-c654-0000000000a1', pg_temp.id('tx'), pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-10', 'opening', pg_temp.id('p1'), 10, false, pg_temp.id('s1')),
  ('56000000-0000-4000-c654-0000000000a2', pg_temp.id('tx'), pg_temp.id('m2'), pg_temp.id('day'), date '2026-03-10', 'opening', pg_temp.id('p1'), 20, false, pg_temp.id('uax')),
  ('56000000-0000-4000-c654-0000000000b1', pg_temp.id('ty'), pg_temp.id('my'), pg_temp.id('shy'), date '2026-03-10', 'opening', pg_temp.id('py'), 30, false, pg_temp.id('sy'));
insert into ids values ('r1', '56000000-0000-4000-c654-0000000000a1'), ('r2', '56000000-0000-4000-c654-0000000000a2'), ('ry', '56000000-0000-4000-c654-0000000000b1');

-- Contract ---------------------------------------------------------------------------------------------------------------------------------------------------
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname in ('rd_attachment_begin', 'rd_attachment_commit')
            and has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute')), 2, 'both photo RPCs are executable by authenticated and not by anon');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = '_rd_can_see_reading'
            and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))), 0, 'the visibility helper in app is not executable by clients');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app_policy'), 2, 'app_policy still holds exactly the two policy helpers (no new client-executable helper)');
select is((select count(*)::int from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'attachments_%'), 2, 'and still two policies on storage.objects');

-- begin ----------------------------------------------------------------------------------------------------------------------------------------------------------
select is(pg_temp.begin_('s1', 'r1', null)->>'field', 'request_id', 'a request id is required');
select is(pg_temp.rpc('s1', format($q$select public.rd_attachment_begin(gen_random_uuid(), %L, 'image/gif', 100, pg_temp.sha())$q$, pg_temp.id('r1')))->>'field', 'mime', 'validation: only JPEG, PNG, WebP');
select is(pg_temp.rpc('s1', format($q$select public.rd_attachment_begin(gen_random_uuid(), %L, 'image/png', 5242881, pg_temp.sha())$q$, pg_temp.id('r1')))->>'field', 'size', 'validation: over 5 MB');
select is(pg_temp.rpc('s1', format($q$select public.rd_attachment_begin(gen_random_uuid(), %L, 'image/png', 100, 'xyz')$q$, pg_temp.id('r1')))->>'field', 'sha256', 'validation: checksum');
select is(pg_temp.begin_('s2', 'r1')->>'code', 'not_allowed', 'a supervisor who does not own the machine is denied');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and source = 'rpc:rd_attachment_begin' and reason = 'not_owner'), 1, 'audited as not_owner');
select is(pg_temp.begin_('s1', 'r2')->>'code', 'not_allowed', 'a supervisor cannot attach to a reading of an unassigned machine');
select is(pg_temp.begin_('uay', 'r1')->>'code', 'not_allowed', 'another tenant is denied');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and source = 'rpc:rd_attachment_begin' and reason = 'cross_tenant'), 1, 'audited as cross_tenant');
select is(pg_temp.begin_('sa', 'r1')->>'code', 'not_allowed', 'a Super Admin is denied');
select is(pg_temp.rpc('s1', 'select public.rd_attachment_begin(gen_random_uuid(), gen_random_uuid(), ''image/png'', 100, pg_temp.sha())')->>'code', 'not_allowed', 'an unknown reading is the same denial');
select set_config('t.req', gen_random_uuid()::text, true);
select is(pg_temp.keep('a1', pg_temp.begin_('s1', 'r1', current_setting('t.req')::uuid))->>'status', 'pending', 'the owner begins an upload');
select is(pg_temp.path('a1'), 'tenant/' || pg_temp.id('tx') || '/reading/' || pg_temp.id('r1') || '/' || pg_temp.id('a1') || '.png', 'the path is tenant/<tenant>/reading/<reading>/<attachment>.<ext>');
select ok((select status = 'pending' and entity_type = 'production_reading' and entity_id = pg_temp.id('r1') and parent_id = pg_temp.id('r1') and uploaded_by = pg_temp.id('s1')
           from public.attachment where id = pg_temp.id('a1')), 'the pending row records type, reading and uploader');
select is(pg_temp.begin_('s1', 'r1', current_setting('t.req')::uuid)->>'id', pg_temp.id('a1')::text, 'a retried begin returns the same attachment');
select is(pg_temp.begin_('s1', 'r1', current_setting('t.req')::uuid)->>'already', 'true', 'flagged as already');
select is((select count(*)::int from public.attachment where parent_id = pg_temp.id('r1')), 1, 'and creates no second row');
select is(pg_temp.keep('a2', pg_temp.begin_('uax', 'r2'))->>'ok', 'true', 'a Unit Admin can begin for any reading of the tenant');

-- Storage before commit ---------------------------------------------------------------------------------------------------------------------------------------
select is(pg_temp.try('s1', format($q$insert into storage.objects (bucket_id, name, metadata) values ('attachments', %L, '{"size":100,"mimetype":"image/png"}')$q$, pg_temp.path('a1'))), 'ok', 'the uploader writes the path of their own pending photo');
select is(pg_temp.seen('s1'), 1, 'and sees their pending object');
select is(pg_temp.seen('uax'), 0, 'a Unit Admin does not see someone else''s pending object');

-- commit -----------------------------------------------------------------------------------------------------------------------------------------------------------
select is(pg_temp.commit_('uax', 'a2')->>'field', 'not_uploaded', 'guard: no object in Storage yet');
select is(pg_temp.commit_('s2', 'a1')->>'code', 'not_allowed', 'only the uploader commits');
select is(pg_temp.commit_('uay', 'a1')->>'code', 'not_allowed', 'another tenant is denied');
select is(pg_temp.commit_('sa', 'a1')->>'code', 'not_allowed', 'a Super Admin is denied');
select pg_temp.png('a2', 999);
select is(pg_temp.commit_('uax', 'a2')->>'field', 'mismatch', 'guard: the object size differs from the declared size');
select set_config('t.req2', gen_random_uuid()::text, true);
select is(pg_temp.commit_('s1', 'a1', current_setting('t.req2')::uuid)->>'ok', 'true', 'commit succeeds when the object matches');
select ok((select status = 'ready' and ready_at is not null from public.attachment where id = pg_temp.id('a1')), 'the attachment is ready');
select is((select count(*)::int from public.audit_event where action = 'attachment.added' and entity_id = pg_temp.id('a1') and request_id = current_setting('t.req2')::uuid), 1, 'attachment.added is audited');
select is(pg_temp.commit_('s1', 'a1', current_setting('t.req2')::uuid)->>'already', 'true', 'a replayed commit is a no-op');
select is(pg_temp.commit_('s1', 'a1')->>'field', 'already_ready', 'a second commit of the same photo is refused');

-- Storage after commit (visibility follows the machine's owner in that occurrence) -------------------------------------------------------------------
select is(pg_temp.seen('s1'), 1, 'the owner sees the ready photo');
select is(pg_temp.seen('uax'), 2, 'a Unit Admin sees it (plus their own pending upload a2)');
select is(pg_temp.seen('s2'), 0, 'another supervisor does not');
select is(pg_temp.seen('uay'), 0, 'another tenant''s Unit Admin does not');
select is(pg_temp.seen('sy'), 0, 'another tenant''s supervisor does not');
select is(pg_temp.seen('sa'), 0, 'a Super Admin reads 0 objects (although the object exists)');
insert into public.assignment_cover (tenant_id, shift_id, shift_date, machine_id, supervisor_id, reason, recorded_by) values
  (pg_temp.id('tx'), pg_temp.id('day'), date '2026-03-10', pg_temp.id('m1'), pg_temp.id('s2'), 'sick', pg_temp.id('uax'));
select is(pg_temp.seen('s2') || '/' || pg_temp.seen('s1'), '1/0', 'a cover moves the visibility: the covering supervisor sees the photo, the planned owner no longer does');
-- limits
select pg_temp.keep('a3', pg_temp.begin_('s2', 'r1'));
select pg_temp.png('a3'); select pg_temp.commit_('s2', 'a3');
select pg_temp.keep('a4', pg_temp.begin_('s2', 'r1'));
select pg_temp.png('a4'); select pg_temp.commit_('s2', 'a4');
select is(pg_temp.begin_('s2', 'r1')->>'field', 'photo_limit', 'a reading holds at most 3 photos');

-- N-7: only a current reading takes photos; the cap of 3 is re-checked at commit
insert into public.production_reading (id, tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, late, recorded_by) values
  ('56000000-0000-4000-c654-0000000000c1', pg_temp.id('tx'), pg_temp.id('m2'), pg_temp.id('day'), date '2026-03-11', 'opening', pg_temp.id('p1'), 1, false, pg_temp.id('uax')),
  ('56000000-0000-4000-c654-0000000000d1', pg_temp.id('tx'), pg_temp.id('m2'), pg_temp.id('day'), date '2026-03-12', 'opening', pg_temp.id('p1'), 1, false, pg_temp.id('uax'));
insert into public.production_reading (id, tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, late, recorded_by, supersedes_id, correction_reason) values
  ('56000000-0000-4000-c654-0000000000c2', pg_temp.id('tx'), pg_temp.id('m2'), pg_temp.id('day'), date '2026-03-11', 'opening', pg_temp.id('p1'), 2, false, pg_temp.id('uax'),
   '56000000-0000-4000-c654-0000000000c1', 'fix');
insert into ids values ('rold', '56000000-0000-4000-c654-0000000000c1'), ('rnew', '56000000-0000-4000-c654-0000000000c2'), ('rcap', '56000000-0000-4000-c654-0000000000d1');
select is(pg_temp.begin_('uax', 'rold')->>'field', 'not_current', 'N-7: a superseded reading takes no photo');
select is(pg_temp.begin_('uax', 'rnew')->>'ok', 'true', 'N-7: its current correction does');
select pg_temp.keep('x1', pg_temp.begin_('uax', 'rcap')); select pg_temp.keep('x2', pg_temp.begin_('uax', 'rcap')); select pg_temp.keep('x3', pg_temp.begin_('uax', 'rcap'));
select pg_temp.png('x1'); select pg_temp.png('x2'); select pg_temp.png('x3');
select pg_temp.commit_('uax', 'x1'); select pg_temp.commit_('uax', 'x2');
select pg_temp.keep('x4', pg_temp.begin_('uax', 'rcap'));
select pg_temp.png('x4');
select is(pg_temp.commit_('uax', 'x3')->>'ok', 'true', 'N-7: the third photo commits');
select is(pg_temp.commit_('uax', 'x4')->>'field', 'photo_limit', 'N-7: a fourth, begun while only two were ready, is refused at commit');

select pg_temp.as_user('uax');
select is(jsonb_array_length(app.reading_detail_at(pg_temp.id('m1'), pg_temp.id('day'), date '2026-03-10', now()) -> 'photos'), 3, 'reading_detail lists the ready photos of the occurrence''s readings (a1, a3, a4)');

select * from finish();
rollback;
