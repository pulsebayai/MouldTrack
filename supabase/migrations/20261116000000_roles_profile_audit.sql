-- 02-tenancy-and-roles (schema lock 02): membership profile, must-change-password gate, role helper,
-- role-aware RLS, append-only audit_event. Steps 2-3 of the plan write into this single file.

-- 1. Membership profile columns --------------------------------------------------------------
alter table public.membership
  add column full_name text,
  add column employee_id text,
  add column phone_e164 text,
  add column must_change_password boolean not null default false,
  add column temp_password_expires_at timestamptz,
  add column created_by uuid,
  add column updated_at timestamptz not null default now();

-- Backfill existing rows (dev fixtures only) with placeholders, then constrain.
with numbered as (
  select id, row_number() over (order by created_at, id) as rn from public.membership
)
update public.membership m
set full_name = 'Fixture',
    employee_id = 'FX-' || left(m.id::text, 8),
    phone_e164 = '+9190000' || lpad(n.rn::text, 5, '0'),
    must_change_password = false
from numbered n
where n.id = m.id;

alter table public.membership
  alter column full_name set not null,
  alter column employee_id set not null,
  alter column phone_e164 set not null,
  alter column must_change_password set default true;

alter table public.membership
  add constraint membership_full_name_check check (length(full_name) between 1 and 80 and full_name = btrim(full_name)),
  add constraint membership_employee_id_check check (employee_id ~ '^[A-Za-z0-9_/-]{1,30}$'),
  add constraint membership_phone_e164_check check (phone_e164 ~ '^\+91[6-9][0-9]{9}$'),
  add constraint membership_phone_e164_key unique (phone_e164);
create unique index membership_tenant_employee_id_key on public.membership (tenant_id, lower(employee_id));

-- 2. Helpers: the must-change gate lives here, so every RLS policy built on them inherits it ---
create or replace function app.current_tenant_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.tenant_id
  from public.membership m
  join public.tenant t on t.id = m.tenant_id
  where m.user_id = auth.uid()
    and m.status = 'active'
    and m.must_change_password = false
    and t.status = 'active'
  limit 1
$$;

create function app."current_role"()
returns public.member_role
language sql
stable
security definer
set search_path = ''
as $$
  select m.role
  from public.membership m
  join public.tenant t on t.id = m.tenant_id
  where m.user_id = auth.uid()
    and m.status = 'active'
    and m.must_change_password = false
    and t.status = 'active'
  limit 1
$$;
revoke all on function app."current_role"() from public, anon;
grant execute on function app."current_role"() to authenticated;

-- 3. Membership RLS: own row, or every row of the tenant for its Unit Admin ----------------------
drop policy membership_select_own on public.membership;
create policy membership_select on public.membership
  for select to authenticated
  using (
    user_id = (select auth.uid())
    or (tenant_id = app.current_tenant_id() and app."current_role"() = 'unit_admin')
  );

-- 4. Audit events (tenant-owned, append-only) ---------------------------------------------------
create table public.audit_event (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references public.tenant (id) on delete restrict, -- null only for denials by callers with no tenant
  actor_user_id uuid,
  actor_role text,
  action text not null check (action in (
    'user.created', 'user.updated', 'user.deactivated', 'user.reactivated',
    'user.password_reset', 'user.password_changed', 'access.denied'
  )),
  entity_type text,
  entity_id uuid,
  before jsonb,
  after jsonb,
  reason text,
  source text not null,
  request_id uuid,
  occurred_at timestamptz not null default now()
);
create unique index audit_event_actor_request_key on public.audit_event (actor_user_id, request_id)
  where request_id is not null;
create index audit_event_tenant_occurred_idx on public.audit_event (tenant_id, occurred_at desc);

alter table public.audit_event enable row level security;
alter table public.audit_event force row level security;

create policy audit_event_select_ua on public.audit_event
  for select to authenticated
  using (tenant_id = app.current_tenant_id() and app."current_role"() = 'unit_admin');

-- Privileges: clients read only; service role may append, never change or remove.
revoke all on public.audit_event from public, anon, authenticated, service_role;
grant select on public.audit_event to authenticated;
grant select, insert on public.audit_event to service_role;

-- Second layer: blocks UPDATE/DELETE/TRUNCATE even for roles that hold the privilege (owner, superuser paths).
create function app.audit_event_append_only()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'audit_event is append-only' using errcode = 'P0001';
end
$$;
revoke all on function app.audit_event_append_only() from public, anon, authenticated;
create trigger audit_event_no_update_delete
  before update or delete on public.audit_event
  for each row execute function app.audit_event_append_only();
create trigger audit_event_no_truncate
  before truncate on public.audit_event
  for each statement execute function app.audit_event_append_only();

-- 5. Service-only user-admin functions (step 3, D13) ----------------------------------------------
-- Callers: Edge Functions with the service role only. Authorisation failures (not_allowed) and an expired
-- temporary password (expired) COMMIT an access.denied row and RETURN {ok:false, code}. Validation, duplicate
-- and guard failures RAISE P0001 with detail {code, field?}. Success returns {ok:true, ...}.
grant usage on schema app to service_role;

create function app.audit_denied(
  p_actor uuid, p_tenant uuid, p_role text, p_reason text, p_entity_type text, p_entity_id uuid, p_source text
) returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.audit_event (tenant_id, actor_user_id, actor_role, action, entity_type, entity_id, reason, source)
  values (p_tenant, p_actor, p_role, 'access.denied', p_entity_type, p_entity_id, p_reason, p_source)
$$;

create function app._ua_fail(p_code text, p_message text, p_field text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception '%', p_message
    using errcode = 'P0001', detail = jsonb_strip_nulls(jsonb_build_object('code', p_code, 'field', p_field))::text;
end
$$;

-- Serialises per tenant (row lock first, so authorisation sees the committed state), then authorises the actor
-- and, when given, the target. Denials are audited under the actor's tenant (null when they have none).
create function app._ua_authorise(p_actor uuid, p_target uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
  a record;
  v_reason text;
  v_target_tenant uuid;
begin
  select m.tenant_id into v_tenant from public.membership m where m.user_id = p_actor;
  if v_tenant is not null then
    perform 1 from public.tenant t where t.id = v_tenant for update;
  end if;

  select m.tenant_id, m.role, m.status, m.must_change_password, t.status as tenant_status
    into a
    from public.membership m join public.tenant t on t.id = m.tenant_id
    where m.user_id = p_actor;

  if not found then
    v_reason := 'no_membership';
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
    perform app.audit_denied(p_actor, v_tenant, a.role::text, v_reason,
      case when p_target is not null then 'user' end, p_target, 'edge:user-admin');
    return jsonb_build_object('ok', false, 'code', 'not_allowed');
  end if;
  return jsonb_build_object('ok', true, 'tenant_id', a.tenant_id);
end
$$;

-- Validates the fields that are present (all of them when p_required). Inputs are already trimmed.
create function app._ua_validate(p_name text, p_emp text, p_phone text, p_role text, p_required boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (p_required or p_name is not null) and (p_name is null or length(p_name) not between 1 and 80) then
    perform app._ua_fail('validation', 'Enter a name of 1 to 80 characters', 'full_name');
  end if;
  if (p_required or p_emp is not null) and (p_emp is null or p_emp !~ '^[A-Za-z0-9_/-]{1,30}$') then
    perform app._ua_fail('validation', 'Employee ID: 1 to 30 letters, digits, - _ or /', 'employee_id');
  end if;
  if (p_required or p_phone is not null) and (p_phone is null or p_phone !~ '^\+91[6-9][0-9]{9}$') then
    perform app._ua_fail('validation', 'Enter a valid 10-digit Indian mobile number', 'phone');
  end if;
  if (p_required or p_role is not null) and (p_role is null or p_role not in ('unit_admin', 'supervisor')) then
    perform app._ua_fail('validation', 'Choose Unit Admin or Supervisor', 'role');
  end if;
end
$$;

create function app._ua_dupcheck(p_tenant uuid, p_emp text, p_phone text, p_exclude uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_phone is not null and exists (
    select 1 from public.membership m where m.phone_e164 = p_phone and m.user_id is distinct from p_exclude
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

-- Entity of an already-recorded request by this actor, else null (idempotency, FR-5).
create function app._ua_done(p_actor uuid, p_request uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select e.entity_id from public.audit_event e
  where p_request is not null and e.actor_user_id = p_actor and e.request_id = p_request
$$;

create function app._ua_snapshot(m public.membership)
returns jsonb
language sql
immutable
security definer
set search_path = ''
as $$
  select jsonb_build_object('full_name', m.full_name, 'employee_id', m.employee_id,
    'phone', left(m.phone_e164, 3) || '******' || right(m.phone_e164, 4),
    'role', m.role, 'status', m.status)
$$;

create function app._ua_audit(
  p_actor uuid, p_tenant uuid, p_action text, p_entity uuid, p_before jsonb, p_after jsonb, p_request uuid
) returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.audit_event (tenant_id, actor_user_id, actor_role, action, entity_type, entity_id, before, after, source, request_id)
  values (p_tenant, p_actor, 'unit_admin', p_action, 'user', p_entity, p_before, p_after, 'edge:user-admin', p_request)
$$;

-- Another active Unit Admin besides p_exclude exists in the tenant (last-admin guard).
create function app._ua_has_other_admin(p_tenant uuid, p_exclude uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.membership m
    where m.tenant_id = p_tenant and m.role = 'unit_admin' and m.status = 'active' and m.user_id <> p_exclude
  )
$$;

-- No-write pre-check used before the Auth admin call (D4).
create function app.ua_check_create(p_actor uuid, p_request_id uuid, p_full_name text, p_employee_id text, p_phone text, p_role text)
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
  v_auth := app._ua_authorise(p_actor);
  if not (v_auth->>'ok')::boolean then return v_auth; end if;
  v_done := app._ua_done(p_actor, p_request_id);
  if v_done is not null then
    return jsonb_build_object('ok', true, 'already', true, 'user_id', v_done);
  end if;
  perform app._ua_validate(v_name, v_emp, p_phone, p_role, true);
  perform app._ua_dupcheck((v_auth->>'tenant_id')::uuid, v_emp, p_phone, null);
  return jsonb_build_object('ok', true);
end
$$;

create function app.ua_create_user(
  p_actor uuid, p_request_id uuid, p_user_id uuid, p_full_name text, p_employee_id text, p_phone text, p_role text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth jsonb;
  v_tenant uuid;
  v_done uuid;
  v_name text := btrim(p_full_name);
  v_emp text := btrim(p_employee_id);
  m public.membership;
  v_constraint text;
begin
  v_auth := app._ua_authorise(p_actor);
  if not (v_auth->>'ok')::boolean then return v_auth; end if;
  v_tenant := (v_auth->>'tenant_id')::uuid;
  v_done := app._ua_done(p_actor, p_request_id);
  if v_done is not null then
    return jsonb_build_object('ok', true, 'already', true, 'user_id', v_done);
  end if;
  perform app._ua_validate(v_name, v_emp, p_phone, p_role, true);
  perform app._ua_dupcheck(v_tenant, v_emp, p_phone, null);

  begin
    insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164,
                                   must_change_password, temp_password_expires_at, created_by)
    values (v_tenant, p_user_id, p_role::public.member_role, 'active', v_name, v_emp, p_phone,
            true, now() + interval '24 hours', p_actor)
    returning * into m;
  exception when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'membership_phone_e164_key' then
      perform app._ua_fail('duplicate', 'This phone number is already registered', 'phone');
    elsif v_constraint = 'membership_tenant_employee_id_key' then
      perform app._ua_fail('duplicate', 'This employee ID is already in use', 'employee_id');
    end if;
    raise;
  end;

  perform app._ua_audit(p_actor, v_tenant, 'user.created', p_user_id, null, app._ua_snapshot(m), p_request_id);
  return jsonb_build_object('ok', true, 'user_id', p_user_id);
end
$$;

-- No-write pre-check for an update; returns the current phone so the caller can restore the Auth email on failure.
create function app.ua_check_update(
  p_actor uuid, p_request_id uuid, p_user_id uuid, p_full_name text, p_employee_id text, p_phone text, p_role text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth jsonb;
  v_done uuid;
  v_name text := btrim(p_full_name);
  v_emp text := btrim(p_employee_id);
  cur public.membership;
begin
  v_auth := app._ua_authorise(p_actor, p_user_id);
  if not (v_auth->>'ok')::boolean then return v_auth; end if;
  v_done := app._ua_done(p_actor, p_request_id);
  if v_done is not null then
    return jsonb_build_object('ok', true, 'already', true, 'user_id', v_done);
  end if;
  perform app._ua_validate(v_name, v_emp, p_phone, p_role, false);
  select * into cur from public.membership m where m.user_id = p_user_id;
  if p_role is not null and p_role <> 'unit_admin' and cur.role = 'unit_admin' then
    if p_user_id = p_actor then
      perform app._ua_fail('guard', 'You cannot do this to your own account', 'self');
    elsif cur.status = 'active' and not app._ua_has_other_admin(cur.tenant_id, p_user_id) then
      perform app._ua_fail('guard', 'A unit must keep at least one active Unit Admin', 'last_admin');
    end if;
  end if;
  perform app._ua_dupcheck(cur.tenant_id, v_emp, p_phone, p_user_id);
  return jsonb_build_object('ok', true, 'current_phone', cur.phone_e164,
    'phone_changed', p_phone is not null and p_phone <> cur.phone_e164);
end
$$;

create function app.ua_update_user(
  p_actor uuid, p_request_id uuid, p_user_id uuid, p_full_name text, p_employee_id text, p_phone text, p_role text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth jsonb;
  v_tenant uuid;
  v_done uuid;
  v_name text := btrim(p_full_name);
  v_emp text := btrim(p_employee_id);
  cur public.membership;
  upd public.membership;
  v_constraint text;
begin
  v_auth := app._ua_authorise(p_actor, p_user_id);
  if not (v_auth->>'ok')::boolean then return v_auth; end if;
  v_tenant := (v_auth->>'tenant_id')::uuid;
  v_done := app._ua_done(p_actor, p_request_id);
  if v_done is not null then
    return jsonb_build_object('ok', true, 'already', true, 'user_id', v_done);
  end if;
  perform app._ua_validate(v_name, v_emp, p_phone, p_role, false);
  select * into cur from public.membership m where m.user_id = p_user_id;
  if p_role is not null and p_role <> 'unit_admin' and cur.role = 'unit_admin' then
    if p_user_id = p_actor then
      perform app._ua_fail('guard', 'You cannot do this to your own account', 'self');
    elsif cur.status = 'active' and not app._ua_has_other_admin(v_tenant, p_user_id) then
      perform app._ua_fail('guard', 'A unit must keep at least one active Unit Admin', 'last_admin');
    end if;
  end if;
  perform app._ua_dupcheck(v_tenant, v_emp, p_phone, p_user_id);

  begin
    update public.membership m
    set full_name = coalesce(v_name, m.full_name),
        employee_id = coalesce(v_emp, m.employee_id),
        phone_e164 = coalesce(p_phone, m.phone_e164),
        role = coalesce(p_role::public.member_role, m.role),
        updated_at = now()
    where m.user_id = p_user_id
    returning * into upd;
  exception when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'membership_phone_e164_key' then
      perform app._ua_fail('duplicate', 'This phone number is already registered', 'phone');
    elsif v_constraint = 'membership_tenant_employee_id_key' then
      perform app._ua_fail('duplicate', 'This employee ID is already in use', 'employee_id');
    end if;
    raise;
  end;

  perform app._ua_audit(p_actor, v_tenant, 'user.updated', p_user_id, app._ua_snapshot(cur), app._ua_snapshot(upd), p_request_id);
  return jsonb_build_object('ok', true, 'user_id', p_user_id, 'phone_changed', upd.phone_e164 <> cur.phone_e164);
end
$$;

create function app.ua_set_status(p_actor uuid, p_request_id uuid, p_user_id uuid, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth jsonb;
  v_tenant uuid;
  v_done uuid;
  cur public.membership;
  upd public.membership;
begin
  v_auth := app._ua_authorise(p_actor, p_user_id);
  if not (v_auth->>'ok')::boolean then return v_auth; end if;
  v_tenant := (v_auth->>'tenant_id')::uuid;
  v_done := app._ua_done(p_actor, p_request_id);
  if v_done is not null then
    return jsonb_build_object('ok', true, 'already', true, 'user_id', v_done);
  end if;
  if p_status is null or p_status not in ('active', 'inactive') then
    perform app._ua_fail('validation', 'Status must be active or inactive', 'status');
  end if;
  select * into cur from public.membership m where m.user_id = p_user_id;
  if p_status = 'inactive' then
    if p_user_id = p_actor then
      perform app._ua_fail('guard', 'You cannot do this to your own account', 'self');
    end if;
    if cur.status = 'active' and cur.role = 'unit_admin' and not app._ua_has_other_admin(v_tenant, p_user_id) then
      perform app._ua_fail('guard', 'A unit must keep at least one active Unit Admin', 'last_admin');
    end if;
  end if;
  if cur.status::text = p_status then
    return jsonb_build_object('ok', true, 'changed', false, 'user_id', p_user_id);
  end if;

  update public.membership m set status = p_status::public.membership_status, updated_at = now()
  where m.user_id = p_user_id returning * into upd;
  perform app._ua_audit(p_actor, v_tenant,
    case when p_status = 'inactive' then 'user.deactivated' else 'user.reactivated' end,
    p_user_id, app._ua_snapshot(cur), app._ua_snapshot(upd), p_request_id);
  return jsonb_build_object('ok', true, 'changed', true, 'user_id', p_user_id);
end
$$;

create function app.ua_reset_password(p_actor uuid, p_request_id uuid, p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth jsonb;
  v_tenant uuid;
  v_done uuid;
  cur public.membership;
begin
  v_auth := app._ua_authorise(p_actor, p_user_id);
  if not (v_auth->>'ok')::boolean then return v_auth; end if;
  v_tenant := (v_auth->>'tenant_id')::uuid;
  v_done := app._ua_done(p_actor, p_request_id);
  if v_done is not null then
    return jsonb_build_object('ok', true, 'already', true, 'user_id', v_done);
  end if;
  if p_user_id = p_actor then
    perform app._ua_fail('guard', 'You cannot do this to your own account', 'self');
  end if;
  select * into cur from public.membership m where m.user_id = p_user_id;
  if cur.status <> 'active' then
    perform app._ua_fail('guard', 'Reactivate this user before resetting the password', 'inactive');
  end if;

  update public.membership m
  set must_change_password = true, temp_password_expires_at = now() + interval '24 hours', updated_at = now()
  where m.user_id = p_user_id;
  perform app._ua_audit(p_actor, v_tenant, 'user.password_reset', p_user_id, null, null, p_request_id);
  return jsonb_build_object('ok', true, 'user_id', p_user_id);
end
$$;

-- Called by the account function after the Auth password was updated. The caller is the user themself.
create function app.account_password_changed(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a record;
begin
  select m.tenant_id, m.role, m.status, m.must_change_password, m.temp_password_expires_at, t.status as tenant_status
    into a
    from public.membership m join public.tenant t on t.id = m.tenant_id
    where m.user_id = p_user_id;

  if not found then
    perform app.audit_denied(p_user_id, null, null, 'no_membership', 'user', p_user_id, 'edge:account');
    return jsonb_build_object('ok', false, 'code', 'not_allowed');
  end if;
  if a.status <> 'active' or a.tenant_status <> 'active' then
    perform app.audit_denied(p_user_id, a.tenant_id, a.role::text, 'inactive', 'user', p_user_id, 'edge:account');
    return jsonb_build_object('ok', false, 'code', 'not_allowed');
  end if;
  if a.must_change_password and a.temp_password_expires_at is not null and a.temp_password_expires_at < now() then
    perform app.audit_denied(p_user_id, a.tenant_id, a.role::text, 'temp_password_expired', 'user', p_user_id, 'edge:account');
    return jsonb_build_object('ok', false, 'code', 'expired');
  end if;

  update public.membership m
  set must_change_password = false, temp_password_expires_at = null, updated_at = now()
  where m.user_id = p_user_id;
  insert into public.audit_event (tenant_id, actor_user_id, actor_role, action, entity_type, entity_id, source)
  values (a.tenant_id, p_user_id, a.role::text, 'user.password_changed', 'user', p_user_id, 'edge:account');
  return jsonb_build_object('ok', true);
end
$$;

-- Service role only.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname ~ '^(_ua_|ua_|account_|audit_denied)'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
