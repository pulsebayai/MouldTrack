-- 07 step 3 (AC-12, AC-13, SA Storage boundary): bucket settings, the two-phase upload RPCs (iss_attachment_begin / iss_attachment_commit) and the
-- policies on storage.objects (insert only the path of the caller's own pending attachment, select only what the caller may see, no update/delete),
-- "a Super Admin reads 0 objects", cross-tenant refusal. Self-contained; rolled back. Objects are tiny rows (metadata only), no bytes.
begin;
create extension if not exists pgtap with schema extensions;
select plan(72);

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
  if (r->>'ok')::boolean then
    insert into ids values (k, (r->>'id')::uuid) on conflict on constraint ids_pkey do update set v = excluded.v;
    insert into ids values (k || '_action', (r->>'action_id')::uuid) on conflict on constraint ids_pkey do update set v = excluded.v;
  end if;
  return r;
end $f$;
create function pg_temp.path(k text) returns text language sql as $$ select storage_path from public.attachment where id = pg_temp.id(k) $$;
-- A statement run as a user with RLS active; "ok" when it raises nothing, else the SQLSTATE
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
create function pg_temp.sha() returns text language sql as $$ select repeat('ab', 32) $$;

insert into auth.users (id, email, aud, role)
select u, 'tap42-' || n || '@example.test', 'authenticated', 'authenticated' from (values
  ('00000000-0000-4000-c720-0000000000a1'::uuid, 'uax'), ('00000000-0000-4000-c720-0000000000a2', 's1'), ('00000000-0000-4000-c720-0000000000a3', 's2'),
  ('00000000-0000-4000-c720-0000000000b1', 'uay'), ('00000000-0000-4000-c720-0000000000b2', 'sy'), ('00000000-0000-4000-c720-0000000000f1', 'sa')) t(u, n);
insert into ids values ('uax', '00000000-0000-4000-c720-0000000000a1'), ('s1', '00000000-0000-4000-c720-0000000000a2'), ('s2', '00000000-0000-4000-c720-0000000000a3'),
  ('uay', '00000000-0000-4000-c720-0000000000b1'), ('sy', '00000000-0000-4000-c720-0000000000b2'), ('sa', '00000000-0000-4000-c720-0000000000f1'),
  ('tx', '50000000-0000-4000-c720-00000000000a'), ('ty', '50000000-0000-4000-c720-00000000000b');
insert into public.tenant (id, name, status, timezone) values
  ('50000000-0000-4000-c720-00000000000a', 'tap42 org X', 'active', 'Asia/Kolkata'), ('50000000-0000-4000-c720-00000000000b', 'tap42 org Y', 'active', 'Asia/Kolkata');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('50000000-0000-4000-c720-00000000000a', '00000000-0000-4000-c720-0000000000a1', 'unit_admin', 'active', 'UA X', 'UA-X', '+919000020741', false),
  ('50000000-0000-4000-c720-00000000000a', '00000000-0000-4000-c720-0000000000a2', 'supervisor', 'active', 'Sup One', 'S1', '+919000020742', false),
  ('50000000-0000-4000-c720-00000000000a', '00000000-0000-4000-c720-0000000000a3', 'supervisor', 'active', 'Sup Two', 'S2', '+919000020743', false),
  ('50000000-0000-4000-c720-00000000000b', '00000000-0000-4000-c720-0000000000b1', 'unit_admin', 'active', 'UA Y', 'UA-Y', '+919000020744', false),
  ('50000000-0000-4000-c720-00000000000b', '00000000-0000-4000-c720-0000000000b2', 'supervisor', 'active', 'Sup Y', 'SY', '+919000020745', false);
insert into public.platform_admin (user_id, full_name, phone_e164, status, must_change_password) values ('00000000-0000-4000-c720-0000000000f1', 'SA 42', '+919000020746', 'active', false);
insert into public.site (id, tenant_id, name, timezone) values
  ('51000000-0000-4000-c720-00000000000a', pg_temp.id('tx'), 'Plant X', 'Asia/Kolkata'), ('51000000-0000-4000-c720-00000000000b', pg_temp.id('ty'), 'Plant Y', 'Asia/Kolkata');
insert into public.machine (id, tenant_id, site_id, code, name) values
  ('53000000-0000-4000-c720-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c720-00000000000a', 'M-A', 'Press A'),
  ('53000000-0000-4000-c720-0000000000b1', pg_temp.id('ty'), '51000000-0000-4000-c720-00000000000b', 'Y-1', 'Y press');
-- Issues, written directly: iX owned and reported by s1 (s2 has no relation); iY in tenant Y.
insert into public.machine_issue (id, tenant_id, machine_id, category_id, priority, description, reported_by, accountable_owner_id)
select '60000000-0000-4000-c720-0000000000a1'::uuid, pg_temp.id('tx'), '53000000-0000-4000-c720-0000000000a1'::uuid,
       (select id from public.issue_category where tenant_id = pg_temp.id('tx') and name = 'Mechanical'), 'low', 'tap42 issue X', pg_temp.id('s1'), pg_temp.id('s1')
union all select '60000000-0000-4000-c720-0000000000b1', pg_temp.id('ty'), '53000000-0000-4000-c720-0000000000b1',
       (select id from public.issue_category where tenant_id = pg_temp.id('ty') and name = 'Mechanical'), 'low', 'tap42 issue Y', pg_temp.id('sy'), pg_temp.id('sy');
insert into ids values ('iX', '60000000-0000-4000-c720-0000000000a1'), ('iY', '60000000-0000-4000-c720-0000000000b1');

-- Bucket ---------------------------------------------------------------------------------------------------------------------------
select is((select public from storage.buckets where id = 'attachments'), false, 'the bucket is private');
select is((select file_size_limit from storage.buckets where id = 'attachments'), 5242880::bigint, 'the bucket limits files to 5 MB');
select is((select allowed_mime_types from storage.buckets where id = 'attachments'), array['image/jpeg', 'image/png', 'image/webp'], 'the bucket allows JPEG, PNG and WebP only');
select is((select count(*)::int from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'attachments_%'), 2, 'two policies on storage.objects: insert and select');
select is((select count(*)::int from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'attachments_%' and cmd in ('UPDATE', 'DELETE', 'ALL')), 0, 'no update, delete or catch-all policy');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app_policy' and (not p.prosecdef or p.proconfig is null or not ('search_path=""' = any (p.proconfig)))), 0,
  'the policy helpers are security definer with an empty search_path');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app_policy' and has_function_privilege('anon', p.oid, 'execute')), 0, 'anon cannot execute the policy helpers');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app_policy' and has_function_privilege('authenticated', p.oid, 'execute')), 2, 'authenticated can (policies run as the caller)');

-- begin: validation and authorisation --------------------------------------------------------------------------------------------------
select is(pg_temp.rpc('s1', format($q$select public.iss_attachment_begin(gen_random_uuid(), %L, 'image/gif', 100, pg_temp.sha())$q$, pg_temp.id('iX')))->>'field', 'mime', 'validation: only JPEG, PNG, WebP');
select is(pg_temp.rpc('s1', format($q$select public.iss_attachment_begin(gen_random_uuid(), %L, 'image/png', 0, pg_temp.sha())$q$, pg_temp.id('iX')))->>'field', 'size', 'validation: size 0');
select is(pg_temp.rpc('s1', format($q$select public.iss_attachment_begin(gen_random_uuid(), %L, 'image/png', 5242881, pg_temp.sha())$q$, pg_temp.id('iX')))->>'field', 'size', 'validation: over 5 MB');
select is(pg_temp.rpc('s1', format($q$select public.iss_attachment_begin(gen_random_uuid(), %L, 'image/png', 5242880, 'xyz')$q$, pg_temp.id('iX')))->>'field', 'sha256', 'validation: checksum');
select is(pg_temp.rpc('s1', format($q$select public.iss_attachment_begin(null, %L, 'image/png', 100, pg_temp.sha())$q$, pg_temp.id('iX')))->>'field', 'request_id', 'a request id is required');
select is(pg_temp.rpc('s2', format($q$select public.iss_attachment_begin(gen_random_uuid(), %L, 'image/png', 100, pg_temp.sha())$q$, pg_temp.id('iX')))->>'code', 'not_allowed', 'a supervisor who cannot see the issue is denied');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and source = 'rpc:iss_attachment_begin' and reason = 'not_visible'), 1, 'audited as not_visible');
select is(pg_temp.rpc('uay', format($q$select public.iss_attachment_begin(gen_random_uuid(), %L, 'image/png', 100, pg_temp.sha())$q$, pg_temp.id('iX')))->>'code', 'not_allowed', 'another tenant is denied');
select is(pg_temp.rpc('sa', format($q$select public.iss_attachment_begin(gen_random_uuid(), %L, 'image/png', 100, pg_temp.sha())$q$, pg_temp.id('iX')))->>'code', 'not_allowed', 'a Super Admin is denied');
select set_config('t.req', gen_random_uuid()::text, true);
select is(pg_temp.keep('a1', pg_temp.rpc('s1', format($q$select public.iss_attachment_begin(%L, %L, 'image/png', 100, pg_temp.sha())$q$, current_setting('t.req'), pg_temp.id('iX'))))->>'status', 'pending', 'the owner begins an upload');
select is(pg_temp.path('a1'), 'tenant/' || pg_temp.id('tx') || '/issue/' || pg_temp.id('iX') || '/' || pg_temp.id('a1') || '.png', 'the path is tenant/<tenant>/issue/<issue>/<attachment>.<ext>');
select ok((select status = 'pending' and entity_type = 'issue_action' and parent_id = pg_temp.id('iX') and uploaded_by = pg_temp.id('s1') and size_bytes = 100 and mime = 'image/png' and sha256 = pg_temp.sha()
           from public.attachment where id = pg_temp.id('a1')), 'a pending row records type, size, checksum, uploader and issue');
select is(pg_temp.rpc('s1', format($q$select public.iss_attachment_begin(%L, %L, 'image/png', 100, pg_temp.sha())$q$, current_setting('t.req'), pg_temp.id('iX')))->>'id', pg_temp.id('a1')::text, 'a retried begin returns the same attachment');
select is((select count(*)::int from public.attachment where parent_id = pg_temp.id('iX')), 1, 'and creates no second row');
select is(pg_temp.rpc('s1', format($q$select public.iss_attachment_begin(%L, gen_random_uuid(), 'image/png', 100, pg_temp.sha())$q$, current_setting('t.req')))->>'code', 'not_allowed', 'the same id on another (unknown) issue is a denial');
select is(pg_temp.rpc('uax', format($q$select public.iss_attachment_begin(gen_random_uuid(), %L, 'image/jpeg', 200, pg_temp.sha())$q$, pg_temp.id('iX')))->>'ok', 'true', 'a Unit Admin can begin too');
select is((select path from (select substring(storage_path from '\.([a-z]+)$') as path from public.attachment where uploaded_by = pg_temp.id('uax')) q), 'jpg', 'JPEG gets .jpg');

-- Storage INSERT policy -------------------------------------------------------------------------------------------------------------------------
select is(pg_temp.try('s1', format($q$insert into storage.objects (bucket_id, name, metadata) values ('attachments', %L, '{"size":100,"mimetype":"image/png"}')$q$, pg_temp.path('a1'))), 'ok', 'the uploader can write the path of their own pending attachment');
select is(pg_temp.try('s1', format($q$insert into storage.objects (bucket_id, name, metadata) values ('attachments', 'tenant/%s/issue/%s/%s.png', '{}')$q$, pg_temp.id('tx'), pg_temp.id('iX'), gen_random_uuid())), '42501', 'a path without a pending attachment is refused');
select is(pg_temp.try('s1', format($q$insert into storage.objects (bucket_id, name, metadata) values ('attachments', 'tenant/%s/issue/%s/x.png', '{}')$q$, pg_temp.id('ty'), pg_temp.id('iY'))), '42501', 'another tenant''s prefix is refused');
select is(pg_temp.try('s1', format($q$insert into storage.objects (bucket_id, name, metadata) values ('attachments', %L, '{}')$q$, pg_temp.path('a1') || 'x')), '42501', 'a path that only starts like the pending one is refused');
select pg_temp.keep('a2', pg_temp.rpc('s1', format($q$select public.iss_attachment_begin(gen_random_uuid(), %L, 'image/png', 100, pg_temp.sha())$q$, pg_temp.id('iX'))));
select is(pg_temp.try('uax', format($q$insert into storage.objects (bucket_id, name, metadata) values ('attachments', %L, '{}')$q$, pg_temp.path('a2'))), '42501', 'another user cannot write the uploader''s pending path');
select is(pg_temp.try('sy', format($q$insert into storage.objects (bucket_id, name, metadata) values ('attachments', %L, '{}')$q$, pg_temp.path('a2'))), '42501', 'another tenant''s user cannot either');
select is(pg_temp.try('sa', format($q$insert into storage.objects (bucket_id, name, metadata) values ('attachments', %L, '{}')$q$, pg_temp.path('a2'))), '42501', 'a Super Admin cannot write');
-- an expired pending row (older than 10 minutes), written directly
insert into public.attachment (id, tenant_id, entity_type, entity_id, storage_path, mime, size_bytes, sha256, uploaded_by, parent_id, created_at) values
  ('63000000-0000-4000-c720-0000000000e1', pg_temp.id('tx'), 'issue_action', gen_random_uuid(),
   'tenant/' || pg_temp.id('tx') || '/issue/' || pg_temp.id('iX') || '/63000000-0000-4000-c720-0000000000e1.png', 'image/png', 100, pg_temp.sha(), pg_temp.id('s1'), pg_temp.id('iX'), now() - interval '11 minutes'),
  ('63000000-0000-4000-c720-0000000000e2', pg_temp.id('tx'), 'issue_action', gen_random_uuid(),
   'tenant/' || pg_temp.id('tx') || '/issue/' || pg_temp.id('iX') || '/63000000-0000-4000-c720-0000000000e2.png', 'image/png', 100, pg_temp.sha(), pg_temp.id('s1'), pg_temp.id('iX'), now() - interval '2 hours');
insert into ids values ('aOld', '63000000-0000-4000-c720-0000000000e1'), ('aOlder', '63000000-0000-4000-c720-0000000000e2');
select is(pg_temp.try('s1', format($q$insert into storage.objects (bucket_id, name, metadata) values ('attachments', %L, '{}')$q$, pg_temp.path('aOld'))), '42501', 'a pending attachment older than 10 minutes can no longer be uploaded to');

-- Storage SELECT policy (before commit) ------------------------------------------------------------------------------------------------------------
select is(pg_temp.seen('s1'), 1, 'the uploader sees their own pending object');
select is(pg_temp.seen('s2'), 0, 'another supervisor does not');
select is(pg_temp.seen('uax'), 0, 'a Unit Admin does not see a pending object either');

-- commit ----------------------------------------------------------------------------------------------------------------------------------------------
select is(pg_temp.rpc('s1', format($q$select public.iss_attachment_commit(gen_random_uuid(), %L)$q$, pg_temp.id('a2')))->>'field', 'not_uploaded', 'guard: no object in Storage yet');
select pg_temp.png('a2', 999);
select is(pg_temp.rpc('s1', format($q$select public.iss_attachment_commit(gen_random_uuid(), %L)$q$, pg_temp.id('a2')))->>'field', 'mismatch', 'guard: the object size differs from the declared size');
select is(pg_temp.rpc('s1', format($q$select public.iss_attachment_commit(gen_random_uuid(), %L)$q$, pg_temp.id('aOlder')))->>'field', 'expired', 'guard: a pending attachment older than 1 hour has expired');
select is(pg_temp.rpc('s2', format($q$select public.iss_attachment_commit(gen_random_uuid(), %L)$q$, pg_temp.id('a1')))->>'code', 'not_allowed', 'only the uploader commits');
select is((select count(*)::int from public.audit_event where action = 'access.denied' and source = 'rpc:iss_attachment_commit' and reason = 'not_uploader'), 1, 'audited as not_uploader');
select is(pg_temp.rpc('uay', format($q$select public.iss_attachment_commit(gen_random_uuid(), %L)$q$, pg_temp.id('a1')))->>'code', 'not_allowed', 'another tenant is denied');
select is(pg_temp.rpc('sa', format($q$select public.iss_attachment_commit(gen_random_uuid(), %L)$q$, pg_temp.id('a1')))->>'code', 'not_allowed', 'a Super Admin is denied');
select is(pg_temp.rpc('s1', format($q$select public.iss_attachment_commit(gen_random_uuid(), %L)$q$, gen_random_uuid()))->>'code', 'not_allowed', 'an unknown attachment is the same denial');
select is(pg_temp.rpc('s1', 'select public.iss_attachment_commit(null, null)')->>'field', 'request_id', 'a request id is required');
select set_config('t.req', gen_random_uuid()::text, true);
select is(pg_temp.rpc('s1', format($q$select public.iss_attachment_commit(%L, %L)$q$, current_setting('t.req'), pg_temp.id('a1')))->>'ok', 'true', 'commit succeeds when the object matches');
select ok((select status = 'ready' and ready_at is not null from public.attachment where id = pg_temp.id('a1')), 'the attachment is ready');
select is((select type || ':' || actor_id::text from public.issue_action where id = pg_temp.id('a1_action')), 'photo:' || pg_temp.id('s1'), 'a photo action with the announced id was appended');
select is((select count(*)::int from public.audit_event where action = 'attachment.added' and entity_id = pg_temp.id('a1') and request_id = current_setting('t.req')::uuid), 1, 'attachment.added is audited');
select is(pg_temp.rpc('s1', format($q$select public.iss_attachment_commit(%L, %L)$q$, current_setting('t.req'), pg_temp.id('a1')))->>'already', 'true', 'a replayed commit is a no-op');
select is(pg_temp.rpc('s1', format($q$select public.iss_attachment_commit(gen_random_uuid(), %L)$q$, pg_temp.id('a1')))->>'field', 'already_ready', 'a second commit of the same photo is refused');
select is((select count(*)::int from public.issue_action where issue_id = pg_temp.id('iX') and type = 'photo'), 1, 'one photo action');

-- Storage SELECT policy (after commit) --------------------------------------------------------------------------------------------------------------
select pg_temp.png('aOld', 100); -- an object nobody may see (its attachment is pending and expired)
select is(pg_temp.seen('s1'), 3, 'the owner sees the ready photo, and their own pending objects');
select is(pg_temp.seen('uax'), 1, 'a Unit Admin sees the ready photo (it belongs to an issue of the tenant)');
select is(pg_temp.seen('s2'), 0, 'a supervisor with no relation to the issue sees nothing');
select is(pg_temp.seen('uay'), 0, 'another tenant''s Unit Admin sees nothing');
select is(pg_temp.seen('sy'), 0, 'another tenant''s supervisor sees nothing');
select is(pg_temp.seen('sa'), 0, 'a Super Admin reads 0 objects (although objects exist)');
select ok((select count(*) from storage.objects where bucket_id = 'attachments') >= 3, 'control: the objects exist (read as the table owner)');
update public.machine_issue set accountable_owner_id = pg_temp.id('s2') where id = pg_temp.id('iX');
select is(pg_temp.seen('s2'), 1, 'a supervisor who becomes accountable sees the photo (visibility follows the issue)');
-- A tenant-Y photo is invisible to tenant X and vice versa
select pg_temp.keep('b1', pg_temp.rpc('sy', format($q$select public.iss_attachment_begin(gen_random_uuid(), %L, 'image/png', 100, pg_temp.sha())$q$, pg_temp.id('iY'))));
select pg_temp.png('b1');
select pg_temp.rpc('sy', format($q$select public.iss_attachment_commit(gen_random_uuid(), %L)$q$, pg_temp.id('b1')));
select is(pg_temp.seen('sy'), 1, 'tenant Y''s supervisor sees their own photo');
select is(pg_temp.seen('uax'), 1, 'and tenant X''s Unit Admin still only sees tenant X''s');

-- No update, no delete -------------------------------------------------------------------------------------------------------------------------------
select is(pg_temp.try('uax', format($q$with u as (update storage.objects set name = name || 'x' where bucket_id = 'attachments' returning 1) select 1 / (case when count(*) = 0 then 1 else 0 end) from u$q$)), 'ok', 'a client update changes no row (no UPDATE policy)');
select is(pg_temp.try('uax', $q$with d as (delete from storage.objects where bucket_id = 'attachments' returning 1) select 1 / (case when count(*) = 0 then 1 else 0 end) from d$q$), 'ok', 'a client delete removes no row (no DELETE policy)');
select is(pg_temp.try('s1', $q$with d as (delete from storage.objects where bucket_id = 'attachments' returning 1) select 1 / (case when count(*) = 0 then 1 else 0 end) from d$q$), 'ok', 'not even the uploader can delete');
select ok((select count(*) from storage.objects where bucket_id = 'attachments') >= 4 and not exists (select 1 from storage.objects where name like '%x'), 'control: nothing was changed or removed');

-- Table-level guards ------------------------------------------------------------------------------------------------------------------------------------
select is(pg_temp.try('uax', format($q$update public.attachment set status = 'ready', ready_at = now() where id = %L$q$, pg_temp.id('aOlder'))), '42501', 'a client cannot change attachment rows');
select is(pg_temp.try('s1', format($q$insert into public.attachment (tenant_id, entity_type, entity_id, storage_path, mime, size_bytes, sha256, uploaded_by) values (%L, 'issue_action', gen_random_uuid(), 'x', 'image/png', 1, pg_temp.sha(), %L)$q$, pg_temp.id('tx'), pg_temp.id('s1'))), '42501', 'a client cannot insert attachment rows');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname in ('iss_attachment_begin', 'iss_attachment_commit')
           and has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute') and p.prosecdef and 'search_path=""' = any (p.proconfig)), 2,
  'both RPCs are security definer, empty search_path, executable by authenticated and not by anon');

-- Limits ----------------------------------------------------------------------------------------------------------------------------------------------------
select pg_temp.rpc('s1', format($q$select public.iss_attachment_begin(gen_random_uuid(), %L, 'image/webp', 10, pg_temp.sha())$q$, pg_temp.id('iX')));
select pg_temp.rpc('s1', format($q$select public.iss_attachment_begin(gen_random_uuid(), %L, 'image/webp', 10, pg_temp.sha())$q$, pg_temp.id('iX')));
select pg_temp.rpc('s1', format($q$select public.iss_attachment_begin(gen_random_uuid(), %L, 'image/webp', 10, pg_temp.sha())$q$, pg_temp.id('iX')));
select pg_temp.rpc('s1', format($q$select public.iss_attachment_begin(gen_random_uuid(), %L, 'image/webp', 10, pg_temp.sha())$q$, pg_temp.id('iX')));
select is(pg_temp.rpc('s1', format($q$select public.iss_attachment_begin(gen_random_uuid(), %L, 'image/webp', 10, pg_temp.sha())$q$, pg_temp.id('iX')))->>'field', 'too_many_pending', 'guard: at most 5 pending uploads per issue and user');
select is(pg_temp.rpc('uax', format($q$select public.iss_attachment_begin(gen_random_uuid(), %L, 'image/webp', 10, pg_temp.sha())$q$, pg_temp.id('iX')))->>'ok', 'true', 'the limit is per user');
insert into public.attachment (tenant_id, entity_type, entity_id, storage_path, mime, size_bytes, sha256, uploaded_by, parent_id, status, ready_at)
select pg_temp.id('tx'), 'issue_action', gen_random_uuid(), 'tenant/' || pg_temp.id('tx') || '/issue/' || pg_temp.id('iX') || '/fill' || n || '.png', 'image/png', 1, pg_temp.sha(), pg_temp.id('s1'), pg_temp.id('iX'), 'ready', now()
from generate_series(1, 30) n;
select is(pg_temp.rpc('uax', format($q$select public.iss_attachment_begin(gen_random_uuid(), %L, 'image/png', 10, pg_temp.sha())$q$, pg_temp.id('iX')))->>'field', 'photo_limit', 'guard: at most 30 photos per issue');

select * from finish();
rollback;
