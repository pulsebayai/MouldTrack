-- 02 review fixes (plan step 12a). A separate migration because 20261116000000 is already applied to hosted dev.
--  R1 session revocation · R2 status audit reason + current status on replays · R5 account pre-check · R8 lock mode and policies.

-- R1. Removes a user's refresh-token sessions (all, or all but one) in the caller's transaction. Service-only.
create function app._revoke_sessions(p_user uuid, p_keep_session uuid default null)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from auth.sessions s
  where s.user_id = p_user and (p_keep_session is null or s.id <> p_keep_session)
$$;

-- R2. The audit helper gains an optional reason; the old 7-argument signature goes away so calls stay unambiguous.
drop function app._ua_audit(uuid, uuid, text, uuid, jsonb, jsonb, uuid);
create function app._ua_audit(
  p_actor uuid, p_tenant uuid, p_action text, p_entity uuid, p_before jsonb, p_after jsonb, p_request uuid, p_reason text default null
) returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.audit_event (tenant_id, actor_user_id, actor_role, action, entity_type, entity_id, before, after, reason, source, request_id)
  values (p_tenant, p_actor, 'unit_admin', p_action, 'user', p_entity, p_before, p_after, p_reason, 'edge:user-admin', p_request)
$$;

-- R8. Row lock that still blocks a concurrent status/role change of the tenant but not foreign-key checks.
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

-- R1 + R2. Deactivation revokes the target's sessions; p_reason marks compensating changes; a replay reports the current status.
drop function public.svc_ua_set_status(uuid, uuid, uuid, text);
drop function app.ua_set_status(uuid, uuid, uuid, text);
create function app.ua_set_status(p_actor uuid, p_request_id uuid, p_user_id uuid, p_status text, p_reason text default null)
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
    return jsonb_build_object('ok', true, 'already', true, 'user_id', v_done,
      'status', (select m.status from public.membership m where m.user_id = v_done));
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
    return jsonb_build_object('ok', true, 'changed', false, 'user_id', p_user_id, 'status', cur.status);
  end if;

  update public.membership m set status = p_status::public.membership_status, updated_at = now()
  where m.user_id = p_user_id returning * into upd;
  if p_status = 'inactive' then
    perform app._revoke_sessions(p_user_id);
  end if;
  perform app._ua_audit(p_actor, v_tenant,
    case when p_status = 'inactive' then 'user.deactivated' else 'user.reactivated' end,
    p_user_id, app._ua_snapshot(cur), app._ua_snapshot(upd), p_request_id, p_reason);
  return jsonb_build_object('ok', true, 'changed', true, 'user_id', p_user_id, 'status', upd.status);
end
$$;

create function public.svc_ua_set_status(p_actor uuid, p_request_id uuid, p_user_id uuid, p_status text, p_reason text default null)
returns jsonb language sql security invoker set search_path = ''
as $$ select app.ua_set_status(p_actor, p_request_id, p_user_id, p_status, p_reason) $$;

-- R1. A reset ends every session of the target.
create or replace function app.ua_reset_password(p_actor uuid, p_request_id uuid, p_user_id uuid)
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
  perform app._revoke_sessions(p_user_id);
  perform app._ua_audit(p_actor, v_tenant, 'user.password_reset', p_user_id, null, null, p_request_id);
  return jsonb_build_object('ok', true, 'user_id', p_user_id);
end
$$;

-- R5. No-write pre-check for the account function: refuses (and audits, D13) before Auth is touched.
create function app.account_check(p_user_id uuid)
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
  return jsonb_build_object('ok', true);
end
$$;

-- R1. Changing the password ends every other session; p_keep_session is the caller's own (JWT session_id claim).
drop function public.svc_account_password_changed(uuid);
drop function app.account_password_changed(uuid);
-- p_check_only = true is the no-write pre-check mode (no extra wrapper: the 004 test pins the wrapper count).
create function app.account_password_changed(p_user_id uuid, p_keep_session uuid default null, p_check_only boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_check jsonb;
  v_tenant uuid;
  v_role text;
begin
  v_check := app.account_check(p_user_id);
  if not (v_check->>'ok')::boolean or p_check_only then return v_check; end if;

  select m.tenant_id, m.role::text into v_tenant, v_role from public.membership m where m.user_id = p_user_id;
  update public.membership m
  set must_change_password = false, temp_password_expires_at = null, updated_at = now()
  where m.user_id = p_user_id;
  perform app._revoke_sessions(p_user_id, p_keep_session);
  insert into public.audit_event (tenant_id, actor_user_id, actor_role, action, entity_type, entity_id, source)
  values (v_tenant, p_user_id, v_role, 'user.password_changed', 'user', p_user_id, 'edge:account');
  return jsonb_build_object('ok', true);
end
$$;

create function public.svc_account_password_changed(p_user_id uuid, p_keep_session uuid default null, p_check_only boolean default false)
returns jsonb language sql security invoker set search_path = ''
as $$ select app.account_password_changed(p_user_id, p_keep_session, p_check_only) $$;

-- R8. RLS helpers evaluated once per statement instead of once per row.
drop policy tenant_select_own on public.tenant;
create policy tenant_select_own on public.tenant
  for select to authenticated
  using (id = (select app.current_tenant_id()));

drop policy membership_select on public.membership;
create policy membership_select on public.membership
  for select to authenticated
  using (
    user_id = (select auth.uid())
    or (tenant_id = (select app.current_tenant_id()) and (select app."current_role"()) = 'unit_admin')
  );

drop policy audit_event_select_ua on public.audit_event;
create policy audit_event_select_ua on public.audit_event
  for select to authenticated
  using (tenant_id = (select app.current_tenant_id()) and (select app."current_role"()) = 'unit_admin');

-- Service role only for everything added here.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname = 'app' and p.proname in ('_revoke_sessions', 'account_check', 'account_password_changed', 'ua_set_status', '_ua_audit'))
       or (n.nspname = 'public' and p.proname in ('svc_account_password_changed', 'svc_ua_set_status'))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
