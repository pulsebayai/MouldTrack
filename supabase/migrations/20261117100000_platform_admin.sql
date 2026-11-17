-- 03-tenant-console (architecture lock + split schema lock: tenant columns, platform_admin, phone_claim).
-- Steps 1-3 of the plan write into this single file.

-- 1. Tenant columns -------------------------------------------------------------------------------------------------------------------------
create type public.plan_label as enum ('trial', 'active');
alter table public.tenant
  add column plan_label public.plan_label not null default 'trial',
  add column updated_at timestamptz not null default now(),
  add column suspended_reason text,
  add constraint tenant_name_length check (length(name) <= 80),
  add constraint tenant_suspended_reason_length check (suspended_reason is null or length(suspended_reason) between 1 and 200);
create unique index tenant_name_lower_key on public.tenant (lower(name));

-- 2. Platform Super Admin identity (separate from membership) ----------------------------------------------------------------------------------
create table public.platform_admin (
  user_id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null,
  phone_e164 text not null,
  status public.membership_status not null default 'active',
  must_change_password boolean not null default true,
  temp_password_expires_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint platform_admin_full_name_check check (length(full_name) between 1 and 80 and full_name = btrim(full_name)),
  constraint platform_admin_phone_e164_check check (phone_e164 ~ '^\+91[6-9][0-9]{9}$')
);
alter table public.platform_admin enable row level security;
alter table public.platform_admin force row level security;
create policy platform_admin_select_own on public.platform_admin
  for select to authenticated
  using (user_id = (select auth.uid()));
revoke all on public.platform_admin from public, anon, authenticated, service_role;
grant select on public.platform_admin to authenticated;
grant select, insert, update, delete on public.platform_admin to service_role; -- clients never write; the service-only SQL functions and fixture tooling do

-- 3. phone_claim: one phone per person across membership and platform_admin ---------------------------------------------------------------------
create table app.phone_claim (
  phone_e164 text not null,
  user_id uuid not null,
  kind text not null check (kind in ('membership', 'platform_admin')),
  constraint phone_claim_phone_e164_key primary key (phone_e164),
  constraint phone_claim_user_id_key unique (user_id)
);
revoke all on app.phone_claim from public, anon, authenticated;

insert into app.phone_claim (phone_e164, user_id, kind)
select m.phone_e164, m.user_id, 'membership' from public.membership m;

create function app.phone_claim_sync()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind text := case tg_table_name when 'membership' then 'membership' else 'platform_admin' end;
begin
  if tg_op = 'INSERT' then
    insert into app.phone_claim (phone_e164, user_id, kind) values (new.phone_e164, new.user_id, v_kind);
    return new;
  elsif tg_op = 'UPDATE' then
    if new.phone_e164 is distinct from old.phone_e164 then
      update app.phone_claim c set phone_e164 = new.phone_e164 where c.user_id = new.user_id and c.kind = v_kind;
    end if;
    return new;
  else
    delete from app.phone_claim c where c.user_id = old.user_id and c.kind = v_kind;
    return old;
  end if;
end
$$;
revoke all on function app.phone_claim_sync() from public, anon, authenticated;

create trigger membership_phone_claim after insert or update of phone_e164 or delete on public.membership
  for each row execute function app.phone_claim_sync();
create trigger platform_admin_phone_claim after insert or update of phone_e164 or delete on public.platform_admin
  for each row execute function app.phone_claim_sync();

-- 02's duplicate check now sees every phone, including Super Admins' (same message, no existence leak).
create or replace function app._ua_dupcheck(p_tenant uuid, p_emp text, p_phone text, p_exclude uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_phone is not null and exists (
    select 1 from app.phone_claim c where c.phone_e164 = p_phone and c.user_id is distinct from p_exclude
  ) then
    perform app._ua_fail('duplicate', 'This phone number is already registered', 'phone');
  end if;
  if p_emp is not null and exists (
    select 1 from public.membership m
    where m.tenant_id = p_tenant and lower(m.employee_id) = lower(p_emp) and m.user_id is distinct from p_exclude
  ) then
    perform app._ua_fail('duplicate', 'This employee ID is already in use', 'employee_id');
  end if;
end
$$;

-- 4. Gate helper (not executable by clients: only security-definer functions use it) ---------------------------------------------------------------
create function app.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.platform_admin pa
    where pa.user_id = auth.uid() and pa.status = 'active' and pa.must_change_password = false
  )
$$;
revoke all on function app.is_platform_admin() from public, anon, authenticated;
grant execute on function app.is_platform_admin() to service_role;

-- A Super Admin reads tenant rows (tenant-level facts only). The check is inlined: 02's test 004 forbids any client-executable app function
-- besides the two RLS helpers. platform_admin's own-row policy lets the sub-select see exactly the caller's row.
create policy tenant_select_platform_admin on public.tenant
  for select to authenticated
  using (exists (
    select 1 from public.platform_admin pa
    where pa.user_id = (select auth.uid()) and pa.status = 'active' and pa.must_change_password = false
  ));

-- 5. Audit action registry (PR #6) ----------------------------------------------------------------------------------------------------------------
insert into app.audit_action (action, feature) values
  ('tenant.created', '03'), ('tenant.updated', '03'), ('tenant.suspended', '03'), ('tenant.activated', '03'),
  ('platform_admin.created', '03'), ('platform_admin.deactivated', '03'), ('platform_admin.reactivated', '03'),
  ('platform_admin.password_reset', '03'), ('platform_admin.password_changed', '03');

-- 6. Platform functions (step 2, D2). Same shape as 02's ua_*: service-only, denials COMMITTED + RETURNED as {ok:false, code},
-- validation / duplicate / guard errors RAISE P0001 with detail {code, field}. Reached through public.psvc_* wrappers.

-- Serialises every platform write (low volume), then authorises the actor as an active Super Admin with a normal password.
create function app._pa_authorise(p_actor uuid, p_source text default 'edge:platform')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.platform_admin;
  m record;
  v_reason text;
  v_role text;
  v_tenant uuid;
begin
  perform pg_advisory_xact_lock(hashtext('app.platform_admin'));
  select * into a from public.platform_admin pa where pa.user_id = p_actor;
  if not found then
    select mm.tenant_id, mm.role::text as role into m from public.membership mm where mm.user_id = p_actor;
    v_reason := 'not_platform_admin';
    v_tenant := m.tenant_id;
    v_role := m.role;
  elsif a.status <> 'active' then
    v_reason := 'inactive';
    v_role := 'platform_admin';
  elsif a.must_change_password then
    v_reason := 'must_change_password';
    v_role := 'platform_admin';
  end if;
  if v_reason is not null then
    perform app.audit_denied(p_actor, v_tenant, v_role, v_reason, null, null, p_source);
    return jsonb_build_object('ok', false, 'code', 'not_allowed');
  end if;
  return jsonb_build_object('ok', true);
end
$$;

-- Idempotency lookup scoped to the action(s) the calling function records (like 04's per-RPC source): the same request id on a different action is not a replay.
create function app._pa_done(p_actor uuid, p_request uuid, p_actions text[])
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select e.entity_id from public.audit_event e
  where p_request is not null and e.actor_user_id = p_actor and e.request_id = p_request and e.action = any (p_actions)
$$;

create function app._pa_audit(
  p_actor uuid, p_tenant uuid, p_action text, p_entity_type text, p_entity uuid,
  p_before jsonb, p_after jsonb, p_request uuid, p_reason text default null, p_source text default 'edge:platform'
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_constraint text;
begin
  insert into public.audit_event (tenant_id, actor_user_id, actor_role, action, entity_type, entity_id, before, after, reason, source, request_id)
  values (p_tenant, p_actor, 'platform_admin', p_action, p_entity_type, p_entity, p_before, p_after, p_reason, p_source, p_request);
exception when unique_violation then
  -- The same request id already recorded by this actor for another action: a clear validation error, not a 500 (nothing else was written).
  get stacked diagnostics v_constraint = constraint_name;
  if v_constraint = 'audit_event_actor_request_key' then
    perform app._ua_fail('validation', 'This request id was already used for another action', 'request_id');
  end if;
  raise;
end
$$;

create function app._pa_tenant_snapshot(t public.tenant)
returns jsonb
language sql
immutable
security definer
set search_path = ''
as $$ select jsonb_build_object('name', t.name, 'timezone', t.timezone, 'plan_label', t.plan_label, 'status', t.status) $$;

create function app._pa_sa_snapshot(a public.platform_admin)
returns jsonb
language sql
immutable
security definer
set search_path = ''
as $$
  select jsonb_build_object('full_name', a.full_name, 'phone', left(a.phone_e164, 3) || '******' || right(a.phone_e164, 4), 'status', a.status)
$$;

-- One tenant time zone rule (N-7): a real zone in pg_timezone_names that Postgres accepts for `at time zone` (04's pm_save_site rule), minus the
-- posix/ and right/ aliases, which are not IANA identifiers a browser or a user would recognise. Any zone on the client list (src/lib/timezones.ts) passes.
create function app._pa_timezone_ok(p_tz text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_tz is null or p_tz !~ '^([A-Za-z_]+(/[A-Za-z0-9_+-]+)+|UTC)$' or p_tz ~* '^(posix|right)/' then
    return false;
  end if;
  if not exists (select 1 from pg_catalog.pg_timezone_names n where n.name = p_tz) then
    return false;
  end if;
  begin
    perform now() at time zone p_tz;
  exception when others then
    return false;
  end;
  return true;
end
$$;

create function app._pa_validate_tenant(p_name text, p_tz text, p_plan text, p_required boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (p_required or p_name is not null) and (p_name is null or length(p_name) not between 1 and 80) then
    perform app._ua_fail('validation', 'Enter a name of 1 to 80 characters', 'name');
  end if;
  if (p_required or p_tz is not null) and (p_tz is null or not app._pa_timezone_ok(p_tz)) then
    perform app._ua_fail('validation', 'Choose a valid time zone', 'timezone');
  end if;
  if (p_required or p_plan is not null) and (p_plan is null or p_plan not in ('trial', 'active')) then
    perform app._ua_fail('validation', 'Plan must be Trial or Active', 'plan_label');
  end if;
end
$$;

create function app._pa_name_taken(p_name text, p_exclude uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$ select exists (select 1 from public.tenant t where lower(t.name) = lower(p_name) and t.id is distinct from p_exclude) $$;

-- Tenants ----------------------------------------------------------------------------------------------------------------------------------------
create function app.pa_tenant_create(p_actor uuid, p_request_id uuid, p_name text, p_timezone text, p_plan text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth jsonb;
  v_done uuid;
  v_name text := btrim(p_name);
  v_tz text := coalesce(nullif(btrim(p_timezone), ''), 'Asia/Kolkata');
  v_plan text := coalesce(nullif(btrim(p_plan), ''), 'trial');
  t public.tenant;
begin
  v_auth := app._pa_authorise(p_actor);
  if not (v_auth->>'ok')::boolean then return v_auth; end if;
  v_done := app._pa_done(p_actor, p_request_id, array['tenant.created']);
  if v_done is not null then
    return jsonb_build_object('ok', true, 'already', true, 'tenant_id', v_done);
  end if;
  perform app._pa_validate_tenant(v_name, v_tz, v_plan, true);
  if app._pa_name_taken(v_name, null) then
    perform app._ua_fail('duplicate', 'A tenant with this name already exists', 'name');
  end if;
  begin
    insert into public.tenant (name, timezone, plan_label, status) values (v_name, v_tz, v_plan::public.plan_label, 'active') returning * into t;
  exception when unique_violation then
    perform app._ua_fail('duplicate', 'A tenant with this name already exists', 'name');
  end;
  perform app._pa_audit(p_actor, t.id, 'tenant.created', 'tenant', t.id, null, app._pa_tenant_snapshot(t), p_request_id);
  return jsonb_build_object('ok', true, 'tenant_id', t.id);
end
$$;

create function app.pa_tenant_update(p_actor uuid, p_request_id uuid, p_tenant uuid, p_name text, p_timezone text, p_plan text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth jsonb;
  v_done uuid;
  v_name text := btrim(p_name);
  v_tz text := nullif(btrim(p_timezone), '');
  v_plan text := nullif(btrim(p_plan), '');
  cur public.tenant;
  upd public.tenant;
begin
  v_auth := app._pa_authorise(p_actor);
  if not (v_auth->>'ok')::boolean then return v_auth; end if;
  v_done := app._pa_done(p_actor, p_request_id, array['tenant.updated']);
  if v_done is not null then
    return jsonb_build_object('ok', true, 'already', true, 'tenant_id', v_done);
  end if;
  select * into cur from public.tenant t where t.id = p_tenant for no key update;
  if not found then
    perform app._ua_fail('guard', 'Tenant not found', 'not_found');
  end if;
  perform app._pa_validate_tenant(v_name, v_tz, v_plan, false);
  if v_name is not null and app._pa_name_taken(v_name, p_tenant) then
    perform app._ua_fail('duplicate', 'A tenant with this name already exists', 'name');
  end if;
  -- A save that changes nothing writes nothing: no update, no audit row (N-6).
  if v_name is not distinct from cur.name or v_name is null then
    if (v_tz is null or v_tz = cur.timezone) and (v_plan is null or v_plan = cur.plan_label::text) then
      return jsonb_build_object('ok', true, 'tenant_id', p_tenant, 'changed', false);
    end if;
  end if;
  begin
    update public.tenant t
    set name = coalesce(v_name, t.name), timezone = coalesce(v_tz, t.timezone),
        plan_label = coalesce(v_plan::public.plan_label, t.plan_label), updated_at = now()
    where t.id = p_tenant returning * into upd;
  exception when unique_violation then
    perform app._ua_fail('duplicate', 'A tenant with this name already exists', 'name');
  end;
  perform app._pa_audit(p_actor, p_tenant, 'tenant.updated', 'tenant', p_tenant, app._pa_tenant_snapshot(cur), app._pa_tenant_snapshot(upd), p_request_id);
  return jsonb_build_object('ok', true, 'tenant_id', p_tenant);
end
$$;

create function app.pa_tenant_set_status(p_actor uuid, p_request_id uuid, p_tenant uuid, p_status text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth jsonb;
  v_done uuid;
  v_reason text := nullif(btrim(p_reason), '');
  cur public.tenant;
  upd public.tenant;
begin
  v_auth := app._pa_authorise(p_actor);
  if not (v_auth->>'ok')::boolean then return v_auth; end if;
  v_done := app._pa_done(p_actor, p_request_id, array['tenant.suspended', 'tenant.activated']);
  if v_done is not null then
    return jsonb_build_object('ok', true, 'already', true, 'tenant_id', v_done,
      'status', (select t.status from public.tenant t where t.id = v_done));
  end if;
  if p_status is null or p_status not in ('active', 'suspended') then
    perform app._ua_fail('validation', 'Status must be active or suspended', 'status');
  end if;
  if p_status = 'suspended' and v_reason is null then
    perform app._ua_fail('validation', 'Give a reason of 1 to 200 characters', 'reason');
  end if;
  if v_reason is not null and length(v_reason) > 200 then
    perform app._ua_fail('validation', 'Give a reason of 1 to 200 characters', 'reason');
  end if;
  select * into cur from public.tenant t where t.id = p_tenant for no key update;
  if not found then
    perform app._ua_fail('guard', 'Tenant not found', 'not_found');
  end if;
  if cur.status::text = p_status then
    return jsonb_build_object('ok', true, 'changed', false, 'tenant_id', p_tenant, 'status', cur.status);
  end if;
  update public.tenant t
  set status = p_status::public.tenant_status,
      suspended_reason = case when p_status = 'suspended' then v_reason else null end,
      updated_at = now()
  where t.id = p_tenant returning * into upd;
  perform app._pa_audit(p_actor, p_tenant,
    case when p_status = 'suspended' then 'tenant.suspended' else 'tenant.activated' end,
    'tenant', p_tenant, app._pa_tenant_snapshot(cur), app._pa_tenant_snapshot(upd), p_request_id, v_reason);
  return jsonb_build_object('ok', true, 'changed', true, 'tenant_id', p_tenant, 'status', upd.status);
end
$$;

-- Unit Admins of a tenant (create / reset only) ------------------------------------------------------------------------------------------------------
create function app.pa_ua_check_create(p_actor uuid, p_request_id uuid, p_tenant uuid, p_full_name text, p_employee_id text, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth jsonb;
  v_done uuid;
  v_name text := btrim(p_full_name);
  v_emp text := btrim(p_employee_id);
begin
  v_auth := app._pa_authorise(p_actor);
  if not (v_auth->>'ok')::boolean then return v_auth; end if;
  v_done := app._pa_done(p_actor, p_request_id, array['user.created']);
  if v_done is not null then
    return jsonb_build_object('ok', true, 'already', true, 'user_id', v_done);
  end if;
  perform 1 from public.tenant t where t.id = p_tenant for no key update;
  if not found then
    perform app._ua_fail('guard', 'Tenant not found', 'not_found');
  end if;
  perform app._ua_validate(v_name, v_emp, p_phone, 'unit_admin', true);
  perform app._ua_dupcheck(p_tenant, v_emp, p_phone, null);
  return jsonb_build_object('ok', true);
end
$$;

create function app.pa_ua_create(p_actor uuid, p_request_id uuid, p_tenant uuid, p_user_id uuid, p_full_name text, p_employee_id text, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth jsonb;
  v_done uuid;
  v_name text := btrim(p_full_name);
  v_emp text := btrim(p_employee_id);
  v_constraint text;
  m public.membership;
begin
  v_auth := app._pa_authorise(p_actor);
  if not (v_auth->>'ok')::boolean then return v_auth; end if;
  v_done := app._pa_done(p_actor, p_request_id, array['user.created']);
  if v_done is not null then
    return jsonb_build_object('ok', true, 'already', true, 'user_id', v_done);
  end if;
  perform 1 from public.tenant t where t.id = p_tenant for no key update;
  if not found then
    perform app._ua_fail('guard', 'Tenant not found', 'not_found');
  end if;
  perform app._ua_validate(v_name, v_emp, p_phone, 'unit_admin', true);
  perform app._ua_dupcheck(p_tenant, v_emp, p_phone, null);
  begin
    insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164,
                                   must_change_password, temp_password_expires_at, created_by)
    values (p_tenant, p_user_id, 'unit_admin', 'active', v_name, v_emp, p_phone, true, now() + interval '24 hours', p_actor)
    returning * into m;
  exception when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint in ('membership_phone_e164_key', 'phone_claim_phone_e164_key') then
      perform app._ua_fail('duplicate', 'This phone number is already registered', 'phone');
    elsif v_constraint = 'membership_tenant_employee_id_key' then
      perform app._ua_fail('duplicate', 'This employee ID is already in use', 'employee_id');
    end if;
    raise;
  end;
  perform app._pa_audit(p_actor, p_tenant, 'user.created', 'user', p_user_id, null, app._ua_snapshot(m), p_request_id);
  return jsonb_build_object('ok', true, 'user_id', p_user_id);
end
$$;

-- Only a tenant's Unit Admin can be reset from the console; anything else is denied and audited (AC-9).
create function app.pa_ua_reset_password(p_actor uuid, p_request_id uuid, p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth jsonb;
  v_done uuid;
  cur public.membership;
  v_reason text;
begin
  v_auth := app._pa_authorise(p_actor);
  if not (v_auth->>'ok')::boolean then return v_auth; end if;
  select * into cur from public.membership m where m.user_id = p_user_id;
  if not found then
    v_reason := 'not_found';
  elsif cur.role <> 'unit_admin' then
    v_reason := 'target_not_unit_admin';
  end if;
  if v_reason is not null then
    perform app.audit_denied(p_actor, cur.tenant_id, 'platform_admin', v_reason, 'user', p_user_id, 'edge:platform');
    return jsonb_build_object('ok', false, 'code', 'not_allowed');
  end if;
  v_done := app._pa_done(p_actor, p_request_id, array['user.password_reset']);
  if v_done is not null then
    return jsonb_build_object('ok', true, 'already', true, 'user_id', v_done);
  end if;
  if cur.status <> 'active' then
    perform app._ua_fail('guard', 'Reactivate this user before resetting the password', 'inactive');
  end if;
  update public.membership m
  set must_change_password = true, temp_password_expires_at = now() + interval '24 hours', updated_at = now()
  where m.user_id = p_user_id;
  perform app._revoke_sessions(p_user_id);
  perform app._pa_audit(p_actor, cur.tenant_id, 'user.password_reset', 'user', p_user_id, null, null, p_request_id);
  return jsonb_build_object('ok', true, 'user_id', p_user_id);
end
$$;

-- Super Admins -----------------------------------------------------------------------------------------------------------------------------------------
create function app._pa_validate_sa(p_name text, p_phone text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_name is null or length(p_name) not between 1 and 80 then
    perform app._ua_fail('validation', 'Enter a name of 1 to 80 characters', 'full_name');
  end if;
  if p_phone is null or p_phone !~ '^\+91[6-9][0-9]{9}$' then
    perform app._ua_fail('validation', 'Enter a valid 10-digit Indian mobile number', 'phone');
  end if;
end
$$;

create function app.pa_sa_check_create(p_actor uuid, p_request_id uuid, p_full_name text, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth jsonb;
  v_done uuid;
  v_name text := btrim(p_full_name);
begin
  v_auth := app._pa_authorise(p_actor);
  if not (v_auth->>'ok')::boolean then return v_auth; end if;
  v_done := app._pa_done(p_actor, p_request_id, array['platform_admin.created']);
  if v_done is not null then
    return jsonb_build_object('ok', true, 'already', true, 'user_id', v_done);
  end if;
  perform app._pa_validate_sa(v_name, p_phone);
  perform app._ua_dupcheck(null, null, p_phone, null);
  return jsonb_build_object('ok', true);
end
$$;

create function app.pa_sa_create(p_actor uuid, p_request_id uuid, p_user_id uuid, p_full_name text, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth jsonb;
  v_done uuid;
  v_name text := btrim(p_full_name);
  a public.platform_admin;
begin
  v_auth := app._pa_authorise(p_actor);
  if not (v_auth->>'ok')::boolean then return v_auth; end if;
  v_done := app._pa_done(p_actor, p_request_id, array['platform_admin.created']);
  if v_done is not null then
    return jsonb_build_object('ok', true, 'already', true, 'user_id', v_done);
  end if;
  perform app._pa_validate_sa(v_name, p_phone);
  perform app._ua_dupcheck(null, null, p_phone, null);
  begin
    insert into public.platform_admin (user_id, full_name, phone_e164, status, must_change_password, temp_password_expires_at, created_by)
    values (p_user_id, v_name, p_phone, 'active', true, now() + interval '24 hours', p_actor)
    returning * into a;
  exception when unique_violation then
    perform app._ua_fail('duplicate', 'This phone number is already registered', 'phone');
  end;
  perform app._pa_audit(p_actor, null, 'platform_admin.created', 'platform_admin', p_user_id, null, app._pa_sa_snapshot(a), p_request_id);
  return jsonb_build_object('ok', true, 'user_id', p_user_id);
end
$$;

create function app.pa_sa_set_status(p_actor uuid, p_request_id uuid, p_user_id uuid, p_status text, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth jsonb;
  v_done uuid;
  cur public.platform_admin;
  upd public.platform_admin;
begin
  v_auth := app._pa_authorise(p_actor);
  if not (v_auth->>'ok')::boolean then return v_auth; end if;
  v_done := app._pa_done(p_actor, p_request_id, array['platform_admin.deactivated', 'platform_admin.reactivated']);
  if v_done is not null then
    return jsonb_build_object('ok', true, 'already', true, 'user_id', v_done,
      'status', (select pa.status from public.platform_admin pa where pa.user_id = v_done));
  end if;
  if p_status is null or p_status not in ('active', 'inactive') then
    perform app._ua_fail('validation', 'Status must be active or inactive', 'status');
  end if;
  select * into cur from public.platform_admin pa where pa.user_id = p_user_id;
  if not found then
    perform app._ua_fail('guard', 'Super Admin not found', 'not_found');
  end if;
  if p_status = 'inactive' then
    if p_user_id = p_actor then
      perform app._ua_fail('guard', 'You cannot do this to your own account', 'self');
    end if;
    if cur.status = 'active' and not exists (
      select 1 from public.platform_admin pa where pa.status = 'active' and pa.user_id <> p_user_id
    ) then
      perform app._ua_fail('guard', 'The platform must keep at least one active Super Admin', 'last_admin');
    end if;
  end if;
  if cur.status::text = p_status then
    return jsonb_build_object('ok', true, 'changed', false, 'user_id', p_user_id, 'status', cur.status);
  end if;
  update public.platform_admin pa set status = p_status::public.membership_status, updated_at = now()
  where pa.user_id = p_user_id returning * into upd;
  if p_status = 'inactive' then
    perform app._revoke_sessions(p_user_id);
  end if;
  perform app._pa_audit(p_actor, null,
    case when p_status = 'inactive' then 'platform_admin.deactivated' else 'platform_admin.reactivated' end,
    'platform_admin', p_user_id, app._pa_sa_snapshot(cur), app._pa_sa_snapshot(upd), p_request_id, p_reason);
  return jsonb_build_object('ok', true, 'changed', true, 'user_id', p_user_id, 'status', upd.status);
end
$$;

create function app.pa_sa_reset_password(p_actor uuid, p_request_id uuid, p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth jsonb;
  v_done uuid;
  cur public.platform_admin;
begin
  v_auth := app._pa_authorise(p_actor);
  if not (v_auth->>'ok')::boolean then return v_auth; end if;
  v_done := app._pa_done(p_actor, p_request_id, array['platform_admin.password_reset']);
  if v_done is not null then
    return jsonb_build_object('ok', true, 'already', true, 'user_id', v_done);
  end if;
  if p_user_id = p_actor then
    perform app._ua_fail('guard', 'You cannot do this to your own account', 'self');
  end if;
  select * into cur from public.platform_admin pa where pa.user_id = p_user_id;
  if not found then
    perform app._ua_fail('guard', 'Super Admin not found', 'not_found');
  end if;
  if cur.status <> 'active' then
    perform app._ua_fail('guard', 'Reactivate this user before resetting the password', 'inactive');
  end if;
  update public.platform_admin pa
  set must_change_password = true, temp_password_expires_at = now() + interval '24 hours', updated_at = now()
  where pa.user_id = p_user_id;
  perform app._revoke_sessions(p_user_id);
  perform app._pa_audit(p_actor, null, 'platform_admin.password_reset', 'platform_admin', p_user_id, null, null, p_request_id);
  return jsonb_build_object('ok', true, 'user_id', p_user_id);
end
$$;

-- One-time setup (D4): refuses once any Super Admin exists. A denial is committed + returned; the audit row is throttled to one
-- per minute because the endpoint is public (anyone can call it after setup closed).
create function app.pa_setup_check()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reissue uuid;
begin
  perform pg_advisory_xact_lock(hashtext('app.platform_setup'));
  if exists (select 1 from public.platform_admin) then
    -- F2 (no lock-out): while the ONLY Super Admin is the one setup created, still on its temporary password and that password has expired,
    -- nobody has ever signed in, so setup offers a re-issue for that account. After any completed password change, or once a second
    -- Super Admin exists (console-created), setup is closed for good.
    select pa.user_id into v_reissue
    from public.platform_admin pa
    where (select count(*) from public.platform_admin) = 1
      and pa.must_change_password
      and pa.temp_password_expires_at is not null and pa.temp_password_expires_at < now()
      and exists (select 1 from public.audit_event e
                  where e.action = 'platform_admin.created' and e.source = 'edge:platform-setup' and e.entity_id = pa.user_id);
    if v_reissue is not null then
      return jsonb_build_object('ok', true, 'reissue', true, 'user_id', v_reissue);
    end if;
    if not exists (
      select 1 from public.audit_event e
      where e.action = 'access.denied' and e.reason = 'setup_closed' and e.occurred_at > now() - interval '1 minute'
    ) then
      perform app.audit_denied(null, null, null, 'setup_closed', 'platform_admin', null, 'edge:platform-setup');
    end if;
    return jsonb_build_object('ok', false, 'code', 'setup_closed');
  end if;
  return jsonb_build_object('ok', true);
end
$$;

-- A wrong setup token while setup is open (R2): refused and audited, throttled like the closed-state refusal.
create function app.pa_setup_bad_token()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtext('app.platform_setup'));
  if not exists (
    select 1 from public.audit_event e
    where e.action = 'access.denied' and e.reason = 'setup_bad_token' and e.occurred_at > now() - interval '1 minute'
  ) then
    perform app.audit_denied(null, null, null, 'setup_bad_token', 'platform_admin', null, 'edge:platform-setup');
  end if;
  return jsonb_build_object('ok', false, 'code', 'not_allowed');
end
$$;

-- Serves the one-per-minute throttle lookups (N-3): without it every public refusal scans recent audit rows.
create index audit_event_setup_refusals_idx on public.audit_event (occurred_at)
  where reason in ('setup_closed', 'setup_bad_token');

create function app.pa_setup_first(p_user_id uuid, p_full_name text, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_check jsonb;
  v_name text := btrim(p_full_name);
  a public.platform_admin;
begin
  v_check := app.pa_setup_check();
  if not (v_check->>'ok')::boolean then return v_check; end if;
  if v_check ? 'reissue' then
    -- F2: the caller (Edge Function) passes the account the check offered; anything else is not a re-issue. Name and phone are not changed.
    if p_user_id is distinct from (v_check->>'user_id')::uuid then
      return jsonb_build_object('ok', false, 'code', 'not_allowed');
    end if;
    update public.platform_admin pa
    set must_change_password = true, temp_password_expires_at = now() + interval '24 hours', updated_at = now()
    where pa.user_id = p_user_id;
    perform app._revoke_sessions(p_user_id);
    insert into public.audit_event (tenant_id, actor_user_id, actor_role, action, entity_type, entity_id, source)
    values (null, null, null, 'platform_admin.password_reset', 'platform_admin', p_user_id, 'edge:platform-setup');
    return jsonb_build_object('ok', true, 'user_id', p_user_id, 'reissued', true);
  end if;
  perform app._pa_validate_sa(v_name, p_phone);
  perform app._ua_dupcheck(null, null, p_phone, null);
  begin
    insert into public.platform_admin (user_id, full_name, phone_e164, status, must_change_password, temp_password_expires_at)
    values (p_user_id, v_name, p_phone, 'active', true, now() + interval '24 hours')
    returning * into a;
  exception when unique_violation then
    perform app._ua_fail('duplicate', 'This phone number is already registered', 'phone');
  end;
  insert into public.audit_event (tenant_id, actor_user_id, actor_role, action, entity_type, entity_id, after, source)
  values (null, null, null, 'platform_admin.created', 'platform_admin', p_user_id, app._pa_sa_snapshot(a), 'edge:platform-setup');
  return jsonb_build_object('ok', true, 'user_id', p_user_id);
end
$$;

-- Own password change for a Super Admin (D5, mirrors 02's account_check / account_password_changed) --------------------------------------------------
create function app.pa_password_changed(p_user_id uuid, p_keep_session uuid default null, p_check_only boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.platform_admin;
begin
  select * into a from public.platform_admin pa where pa.user_id = p_user_id;
  if not found then
    perform app.audit_denied(p_user_id, null, null, 'no_platform_admin', 'user', p_user_id, 'edge:account');
    return jsonb_build_object('ok', false, 'code', 'not_allowed');
  end if;
  if a.status <> 'active' then
    perform app.audit_denied(p_user_id, null, 'platform_admin', 'inactive', 'user', p_user_id, 'edge:account');
    return jsonb_build_object('ok', false, 'code', 'not_allowed');
  end if;
  if a.must_change_password and a.temp_password_expires_at is not null and a.temp_password_expires_at < now() then
    perform app.audit_denied(p_user_id, null, 'platform_admin', 'temp_password_expired', 'user', p_user_id, 'edge:account');
    return jsonb_build_object('ok', false, 'code', 'expired');
  end if;
  if p_check_only then return jsonb_build_object('ok', true); end if;
  update public.platform_admin pa
  set must_change_password = false, temp_password_expires_at = null, updated_at = now()
  where pa.user_id = p_user_id;
  perform app._revoke_sessions(p_user_id, p_keep_session);
  insert into public.audit_event (tenant_id, actor_user_id, actor_role, action, entity_type, entity_id, source)
  values (null, p_user_id, 'platform_admin', 'platform_admin.password_changed', 'platform_admin', p_user_id, 'edge:account');
  return jsonb_build_object('ok', true);
end
$$;

-- 7. Wrappers (service_role only; psvc_ so 02's pinned "8 svc_* wrappers" stays true) ---------------------------------------------------------------------
create function public.psvc_pa_tenant_create(p_actor uuid, p_request_id uuid, p_name text, p_timezone text, p_plan text)
returns jsonb language sql security invoker set search_path = ''
as $$ select app.pa_tenant_create(p_actor, p_request_id, p_name, p_timezone, p_plan) $$;
create function public.psvc_pa_tenant_update(p_actor uuid, p_request_id uuid, p_tenant uuid, p_name text, p_timezone text, p_plan text)
returns jsonb language sql security invoker set search_path = ''
as $$ select app.pa_tenant_update(p_actor, p_request_id, p_tenant, p_name, p_timezone, p_plan) $$;
create function public.psvc_pa_tenant_set_status(p_actor uuid, p_request_id uuid, p_tenant uuid, p_status text, p_reason text)
returns jsonb language sql security invoker set search_path = ''
as $$ select app.pa_tenant_set_status(p_actor, p_request_id, p_tenant, p_status, p_reason) $$;
create function public.psvc_pa_ua_check_create(p_actor uuid, p_request_id uuid, p_tenant uuid, p_full_name text, p_employee_id text, p_phone text)
returns jsonb language sql security invoker set search_path = ''
as $$ select app.pa_ua_check_create(p_actor, p_request_id, p_tenant, p_full_name, p_employee_id, p_phone) $$;
create function public.psvc_pa_ua_create(p_actor uuid, p_request_id uuid, p_tenant uuid, p_user_id uuid, p_full_name text, p_employee_id text, p_phone text)
returns jsonb language sql security invoker set search_path = ''
as $$ select app.pa_ua_create(p_actor, p_request_id, p_tenant, p_user_id, p_full_name, p_employee_id, p_phone) $$;
create function public.psvc_pa_ua_reset_password(p_actor uuid, p_request_id uuid, p_user_id uuid)
returns jsonb language sql security invoker set search_path = ''
as $$ select app.pa_ua_reset_password(p_actor, p_request_id, p_user_id) $$;
create function public.psvc_pa_sa_check_create(p_actor uuid, p_request_id uuid, p_full_name text, p_phone text)
returns jsonb language sql security invoker set search_path = ''
as $$ select app.pa_sa_check_create(p_actor, p_request_id, p_full_name, p_phone) $$;
create function public.psvc_pa_sa_create(p_actor uuid, p_request_id uuid, p_user_id uuid, p_full_name text, p_phone text)
returns jsonb language sql security invoker set search_path = ''
as $$ select app.pa_sa_create(p_actor, p_request_id, p_user_id, p_full_name, p_phone) $$;
create function public.psvc_pa_sa_set_status(p_actor uuid, p_request_id uuid, p_user_id uuid, p_status text, p_reason text default null)
returns jsonb language sql security invoker set search_path = ''
as $$ select app.pa_sa_set_status(p_actor, p_request_id, p_user_id, p_status, p_reason) $$;
create function public.psvc_pa_sa_reset_password(p_actor uuid, p_request_id uuid, p_user_id uuid)
returns jsonb language sql security invoker set search_path = ''
as $$ select app.pa_sa_reset_password(p_actor, p_request_id, p_user_id) $$;
create function public.psvc_pa_authorise(p_actor uuid)
returns jsonb language sql security invoker set search_path = ''
as $$ select app._pa_authorise(p_actor) $$;
create function public.psvc_pa_setup_check()
returns jsonb language sql security invoker set search_path = ''
as $$ select app.pa_setup_check() $$;
create function public.psvc_pa_setup_bad_token()
returns jsonb language sql security invoker set search_path = ''
as $$ select app.pa_setup_bad_token() $$;
create function public.psvc_pa_setup_first(p_user_id uuid, p_full_name text, p_phone text)
returns jsonb language sql security invoker set search_path = ''
as $$ select app.pa_setup_first(p_user_id, p_full_name, p_phone) $$;
create function public.psvc_pa_password_changed(p_user_id uuid, p_keep_session uuid default null, p_check_only boolean default false)
returns jsonb language sql security invoker set search_path = ''
as $$ select app.pa_password_changed(p_user_id, p_keep_session, p_check_only) $$;

-- 8. Read functions for the console (D6): the only new client entry points. Security definer, Super Admin only; anyone else gets an
-- empty result and a committed access.denied. SAs have no RLS access to memberships or audit events, so these expose only what AC-10 / AC-12 allow.
create function app._pa_read_guard(p_source text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  m record;
  a public.platform_admin;
  v_role text;
  v_reason text;
begin
  if app.is_platform_admin() then return true; end if;
  if auth.uid() is null then return false; end if;
  select mm.tenant_id, mm.role::text as role into m from public.membership mm where mm.user_id = auth.uid();
  v_role := m.role;
  v_reason := 'not_platform_admin';
  select * into a from public.platform_admin pa where pa.user_id = auth.uid();
  if found then
    -- A Super Admin who is not currently allowed in: same reasons as the write path (N-8).
    v_role := 'platform_admin';
    v_reason := case when a.status <> 'active' then 'inactive' else 'must_change_password' end;
  end if;
  perform app.audit_denied(auth.uid(), m.tenant_id, v_role, v_reason, null, null, p_source);
  return false;
end
$$;

create function public.pa_tenant_summaries(p_search text default null, p_status text default null, p_plan text default null, p_page integer default 0)
returns table (id uuid, name text, status text, plan_label text, timezone text, created_at timestamptz,
               active_users integer, active_unit_admins integer, total_count bigint)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_term text := nullif(btrim(p_search), '');
begin
  if not app._pa_read_guard('rpc:pa_tenant_summaries') then return; end if;
  if v_term is not null then
    v_term := '%' || replace(replace(replace(v_term, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;
  return query
  select t.id, t.name, t.status::text, t.plan_label::text, t.timezone, t.created_at,
         (select count(*)::int from public.membership m where m.tenant_id = t.id and m.status = 'active'),
         (select count(*)::int from public.membership m where m.tenant_id = t.id and m.status = 'active' and m.role = 'unit_admin'),
         count(*) over ()
  from public.tenant t
  where (v_term is null or t.name ilike v_term)
    and (nullif(p_status, '') is null or t.status::text = p_status)
    and (nullif(p_plan, '') is null or t.plan_label::text = p_plan)
  order by lower(t.name), t.id
  offset greatest(coalesce(p_page, 0), 0) * 25 limit 25;
end
$$;

create function public.pa_tenant_unit_admins(p_tenant uuid)
returns table (user_id uuid, full_name text, phone_masked text, status text, must_change_password boolean)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not app._pa_read_guard('rpc:pa_tenant_unit_admins') then return; end if;
  return query
  select m.user_id, m.full_name, left(m.phone_e164, 3) || '******' || right(m.phone_e164, 4), m.status::text, m.must_change_password
  from public.membership m
  where m.tenant_id = p_tenant and m.role = 'unit_admin'
  order by lower(m.full_name), m.user_id;
end
$$;

create function public.pa_super_admins()
returns table (user_id uuid, full_name text, phone_masked text, status text, must_change_password boolean, is_self boolean)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not app._pa_read_guard('rpc:pa_super_admins') then return; end if;
  return query
  select pa.user_id, pa.full_name, left(pa.phone_e164, 3) || '******' || right(pa.phone_e164, 4), pa.status::text,
         pa.must_change_password, pa.user_id = auth.uid()
  from public.platform_admin pa
  order by lower(pa.full_name), pa.user_id;
end
$$;

-- Platform audit: events whose actor is a Super Admin (incl. their denials) and setup events. Tenant users' own events are not shown.
create function public.pa_audit(p_page integer default 0)
returns table (id uuid, occurred_at timestamptz, action text, actor_name text, tenant_id uuid, tenant_name text,
               entity_type text, reason text, source text, total_count bigint)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not app._pa_read_guard('rpc:pa_audit') then return; end if;
  return query
  select e.id, e.occurred_at, e.action, pa.full_name, e.tenant_id, t.name, e.entity_type, e.reason, e.source, count(*) over ()
  from public.audit_event e
  left join public.platform_admin pa on pa.user_id = e.actor_user_id
  left join public.tenant t on t.id = e.tenant_id
  where e.actor_role = 'platform_admin' or e.source = 'edge:platform-setup'
  order by e.occurred_at desc, e.id
  offset greatest(coalesce(p_page, 0), 0) * 50 limit 50;
end
$$;

-- 10. 02's authorisation denies a Super Admin (no membership) and now records the denial with actor role platform_admin, so it appears in the
-- platform audit (AC-11, AC-12). Everything else is 02's R8 definition unchanged. Later features' write paths (pm_*) copy this branch.
create or replace function app._ua_authorise(p_actor uuid, p_target uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
  a record;
  v_reason text;
  v_role text;
  v_target_tenant uuid;
begin
  select m.tenant_id into v_tenant from public.membership m where m.user_id = p_actor;
  if v_tenant is not null then
    perform 1 from public.tenant t where t.id = v_tenant for no key update;
  end if;

  select m.tenant_id, m.role, m.status, m.must_change_password, t.status as tenant_status
    into a
    from public.membership m join public.tenant t on t.id = m.tenant_id
    where m.user_id = p_actor;
  v_role := a.role::text;

  if not found then
    if exists (select 1 from public.platform_admin pa where pa.user_id = p_actor) then
      v_reason := 'platform_admin';
      v_role := 'platform_admin';
    else
      v_reason := 'no_membership';
    end if;
  elsif a.status <> 'active' or a.tenant_status <> 'active' then
    v_reason := 'inactive';
  elsif a.must_change_password then
    v_reason := 'must_change_password';
  elsif a.role <> 'unit_admin' then
    v_reason := 'role';
  elsif p_target is not null then
    select m.tenant_id into v_target_tenant from public.membership m where m.user_id = p_target;
    if not found then
      v_reason := 'not_found';
    elsif v_target_tenant <> a.tenant_id then
      v_reason := 'cross_tenant';
    end if;
  end if;

  if v_reason is not null then
    perform app.audit_denied(p_actor, v_tenant, v_role, v_reason,
      case when p_target is not null then 'user' end, p_target, 'edge:user-admin');
    return jsonb_build_object('ok', false, 'code', 'not_allowed');
  end if;
  return jsonb_build_object('ok', true, 'tenant_id', a.tenant_id);
end
$$;

-- 9. Privileges ---------------------------------------------------------------------------------------------------------------------------------------------
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname = 'app' and p.proname ~ '^(pa_|_pa_)')
       or (n.nspname = 'public' and p.proname ~ '^psvc_')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('pa_tenant_summaries', 'pa_tenant_unit_admins', 'pa_super_admins', 'pa_audit')
  loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated, service_role', f.sig);
  end loop;
end $$;

-- 11. 02's duplicate-phone handlers also map the phone_claim constraint (N-1). membership.phone_e164 is now claimed in app.phone_claim by a
-- trigger, so a race between two creates of the same phone surfaces as phone_claim_phone_e164_key, not membership_phone_e164_key. The two
-- bodies are patched in place (only that comparison changes) so 02's source stays the single copy of the logic.
do $$
declare
  f text;
  def text;
begin
  foreach f in array array['app.ua_create_user', 'app.ua_update_user'] loop
    select pg_get_functiondef(p.oid) into def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = split_part(f, '.', 2);
    if position('if v_constraint = ''membership_phone_e164_key'' then' in def) = 0 then
      raise exception 'expected duplicate-phone handler not found in %', f;
    end if;
    execute replace(def, 'if v_constraint = ''membership_phone_e164_key'' then',
                         'if v_constraint in (''membership_phone_e164_key'', ''phone_claim_phone_e164_key'') then');
  end loop;
end $$;

-- 12. 04's pm_* authorisation denies a Super Admin with an SA-specific reason (step 8). Same branch as _ua_authorise (section 10): a caller with no
-- membership but an own platform_admin row is denied with reason and actor role `platform_admin`, so the denial reaches the platform audit (pa_audit)
-- instead of looking like a stray no_membership. Everything else is 04's definition unchanged (04's pgTAP 010-014 pass unchanged).
-- Serialises per tenant (row lock first, so authorisation sees committed state), then authorises the caller as a Unit Admin.
-- Returns {ok:true, tenant_id, actor, role[, done]} (done = entity of an already-recorded request) or the generic denial.
create or replace function app._pm_authorise(p_request_id uuid, p_source text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_tenant uuid;
  a record;
  v_reason text;
  v_role text;
  v_done uuid;
begin
  select m.tenant_id into v_tenant from public.membership m where m.user_id = v_actor;
  if v_tenant is not null then
    perform 1 from public.tenant t where t.id = v_tenant for no key update;
  end if;

  select m.tenant_id, m.role, m.status, m.must_change_password, t.status as tenant_status
    into a
    from public.membership m join public.tenant t on t.id = m.tenant_id
    where m.user_id = v_actor;
  v_role := a.role::text;

  if not found then
    if exists (select 1 from public.platform_admin pa where pa.user_id = v_actor) then
      v_reason := 'platform_admin';
      v_role := 'platform_admin';
    else
      v_reason := 'no_membership';
    end if;
  elsif a.status <> 'active' or a.tenant_status <> 'active' then
    v_reason := 'inactive';
  elsif a.must_change_password then
    v_reason := 'must_change_password';
  elsif a.role <> 'unit_admin' then
    v_reason := 'role';
  end if;

  if v_reason is not null then
    perform app.audit_denied(v_actor, v_tenant, v_role, v_reason, null, null, p_source);
    return jsonb_build_object('ok', false, 'code', 'not_allowed');
  end if;

  if p_request_id is null then
    perform app._pm_fail('validation', 'A request id is required', 'request_id');
  end if;
  -- Idempotency: a request id already recorded by this actor for THIS RPC (source) is a replay and returns the first outcome.
  -- The same id on a different RPC is not a replay: it falls through and trips the unique (actor, request_id) audit key.
  select e.entity_id into v_done from public.audit_event e where e.actor_user_id = v_actor and e.request_id = p_request_id and e.source = p_source;
  return jsonb_build_object('ok', true, 'tenant_id', a.tenant_id, 'actor', v_actor, 'role', a.role, 'done', v_done);
end
$$;

-- 13. One time zone rule everywhere (F4). app.timezone_ok is the single rule: the shape and prefix check (no posix/ or right/ aliases, which are not IANA
-- identifiers a user or browser would recognise), then a real name in pg_timezone_names that Postgres accepts for `at time zone`. The shape part is its own
-- pure function so it can be tested on a server whose zone table lacks the posix/ and right/ names. Used by the tenant rule (_pa_timezone_ok), by 04's
-- site trigger and pm_save_site (which then answers validation/timezone instead of failing with a 500) and by a new trigger on tenant.timezone.
create function app.timezone_shape_ok(p_tz text)
returns boolean
language sql
immutable
set search_path = ''
as $$ select p_tz is not null and p_tz ~ '^([A-Za-z_]+(/[A-Za-z0-9_+-]+)+|UTC)$' and p_tz !~* '^(posix|right)/' $$;

create function app.timezone_ok(p_tz text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not app.timezone_shape_ok(p_tz) then
    return false;
  end if;
  if not exists (select 1 from pg_catalog.pg_timezone_names n where n.name = p_tz) then
    return false;
  end if;
  begin
    perform now() at time zone p_tz;
  exception when others then
    return false;
  end;
  return true;
end
$$;

create or replace function app._pa_timezone_ok(p_tz text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$ select app.timezone_ok(p_tz) $$;

-- Existing rows must already satisfy the rule (the new triggers would otherwise refuse their next update). Fixtures and the pilot data never use these aliases.
do $$
begin
  if exists (select 1 from public.site s where s.timezone ~* '^(posix|right)/') or exists (select 1 from public.tenant t where t.timezone ~* '^(posix|right)/') then
    raise exception 'a site or tenant already uses a posix/ or right/ time zone; fix the data before applying this migration';
  end if;
end $$;

create or replace function app.site_timezone_valid()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not app.timezone_ok(new.timezone) then
    raise exception 'Unknown time zone %', new.timezone using errcode = '23514';
  end if;
  return new;
end
$$;

create function app.tenant_timezone_valid()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not app.timezone_ok(new.timezone) then
    raise exception 'Unknown time zone %', new.timezone using errcode = '23514';
  end if;
  return new;
end
$$;
create trigger tenant_timezone_valid before insert or update of timezone on public.tenant
  for each row execute function app.tenant_timezone_valid();

-- pm_save_site (04) validates with its own two checks; patch them in place to the shared rule so 04's source stays the single copy of the function.
do $$
declare
  def text;
  old_block constant text := E'  begin\n    perform now() at time zone v_tz;\n  exception when others then\n    perform app._pm_fail(''validation'', ''Choose a valid time zone'', ''timezone'');\n  end;\n  if not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = v_tz) then\n    perform app._pm_fail(''validation'', ''Choose a valid time zone'', ''timezone'');\n  end if;\n';
  new_block constant text := E'  if not app.timezone_ok(v_tz) then\n    perform app._pm_fail(''validation'', ''Choose a valid time zone'', ''timezone'');\n  end if;\n';
begin
  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'pm_save_site';
  if position(old_block in def) = 0 then
    raise exception 'expected time zone checks not found in public.pm_save_site';
  end if;
  execute replace(def, old_block, new_block);
end $$;

revoke all on function app.timezone_shape_ok(text), app.timezone_ok(text), app.tenant_timezone_valid() from public, anon, authenticated;
grant execute on function app.timezone_shape_ok(text), app.timezone_ok(text), app.tenant_timezone_valid() to service_role;

-- 14. The platform audit list reads platform events newest first (F5 N-8): a partial index with the same predicate as pa_audit.
create index audit_event_platform_idx on public.audit_event (occurred_at desc, id)
  where actor_role = 'platform_admin' or source = 'edge:platform-setup';
