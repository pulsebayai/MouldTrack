// platform: Platform Super Admin actions (03, D4). Authorisation, validation, guards and auditing live in the service-only SQL functions
// (public.psvc_pa_* wrappers); this function verifies the caller, calls Auth where needed, and compensates. Same patterns as user-admin (02).
// Temporary passwords exist only in the create / reset response body: never stored, logged or audited.
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { HttpError, unwrap } from '../_shared/errors.ts';
import { generateTempPassword, phoneToAuthEmail } from '../_shared/identity.ts';
import { callerId, randomBytes, serviceClient } from '../_shared/clients.ts';
import { ALREADY_DONE, BAN_FOREVER, createAuthUser, phoneOf } from '../_shared/auth-users.ts';
import { optionalString, requireString, requireUuid, serveJson } from '../_shared/http.ts';

type Body = Record<string, unknown>;
const GENERIC = { message: 'Something went wrong. Try again.' };

async function tenantCreate(sb: SupabaseClient, actor: string, body: Body) {
  const res = unwrap(await sb.rpc('psvc_pa_tenant_create', {
    p_actor: actor, p_request_id: requireUuid(body, 'request_id'), p_name: requireString(body, 'name'),
    p_timezone: optionalString(body, 'timezone'), p_plan: optionalString(body, 'plan_label'),
  }));
  return res.already ? { tenant_id: res.tenant_id, already: true } : { tenant_id: res.tenant_id };
}

async function tenantUpdate(sb: SupabaseClient, actor: string, body: Body) {
  unwrap(await sb.rpc('psvc_pa_tenant_update', {
    p_actor: actor, p_request_id: requireUuid(body, 'request_id'), p_tenant: requireUuid(body, 'tenant_id'),
    p_name: optionalString(body, 'name'), p_timezone: optionalString(body, 'timezone'), p_plan: optionalString(body, 'plan_label'),
  }));
  return { ok: true };
}

// Suspension is organisational, not a credential issue: sessions are NOT ended (spec AC-6). Access stops because RLS and every
// write function check the tenant status on the next request.
async function tenantSetStatus(sb: SupabaseClient, actor: string, body: Body) {
  const res = unwrap(await sb.rpc('psvc_pa_tenant_set_status', {
    p_actor: actor, p_request_id: requireUuid(body, 'request_id'), p_tenant: requireUuid(body, 'tenant_id'),
    p_status: requireString(body, 'status'), p_reason: optionalString(body, 'reason'),
  }));
  return { ok: true, status: res.status };
}

async function uaCreate(sb: SupabaseClient, actor: string, body: Body) {
  const args = {
    p_actor: actor, p_request_id: requireUuid(body, 'request_id'), p_tenant: requireUuid(body, 'tenant_id'),
    p_full_name: requireString(body, 'full_name'), p_employee_id: requireString(body, 'employee_id'), p_phone: phoneOf(body, true)!,
  };
  const check = unwrap(await sb.rpc('psvc_pa_ua_check_create', args));
  if (check.already) return { user_id: check.user_id, already: true, message: ALREADY_DONE };

  const tempPassword = generateTempPassword(randomBytes);
  let userId: string;
  try {
    userId = await createAuthUser(sb, phoneToAuthEmail(args.p_phone), tempPassword);
  } catch (e) {
    if (e instanceof HttpError && e.status === 409) {
      // A double submit of this very request may have won meanwhile.
      const again = unwrap(await sb.rpc('psvc_pa_ua_check_create', args));
      if (again.already) return { user_id: again.user_id, already: true, message: ALREADY_DONE };
    }
    throw e;
  }
  let result: Record<string, unknown>;
  try {
    result = unwrap(await sb.rpc('psvc_pa_ua_create', { ...args, p_user_id: userId }));
  } catch (e) {
    const { error } = await sb.auth.admin.deleteUser(userId);
    if (error) console.error('compensation_failed orphan_auth_user', userId);
    throw e;
  }
  if (result.already) {
    await sb.auth.admin.deleteUser(userId);
    return { user_id: result.user_id, already: true, message: ALREADY_DONE };
  }
  return { user_id: userId, temp_password: tempPassword };
}

async function resetPassword(sb: SupabaseClient, actor: string, body: Body, rpc: 'psvc_pa_ua_reset_password' | 'psvc_pa_sa_reset_password') {
  const userId = requireUuid(body, 'user_id');
  const res = unwrap(await sb.rpc(rpc, { p_actor: actor, p_request_id: requireUuid(body, 'request_id'), p_user_id: userId }));
  if (res.already) return { already: true, message: ALREADY_DONE };
  const tempPassword = generateTempPassword(randomBytes);
  const { error } = await sb.auth.admin.updateUserById(userId, { password: tempPassword });
  if (error) {
    // Flagged must-change with the old password still valid; the Super Admin can retry (a fresh request id after a 5xx).
    console.error('auth_reset_failed', error.code ?? 'unknown');
    throw new HttpError(500, GENERIC);
  }
  return { temp_password: tempPassword };
}

async function saCreate(sb: SupabaseClient, actor: string, body: Body) {
  const args = {
    p_actor: actor, p_request_id: requireUuid(body, 'request_id'),
    p_full_name: requireString(body, 'full_name'), p_phone: phoneOf(body, true)!,
  };
  const check = unwrap(await sb.rpc('psvc_pa_sa_check_create', args));
  if (check.already) return { user_id: check.user_id, already: true, message: ALREADY_DONE };

  const tempPassword = generateTempPassword(randomBytes);
  let userId: string;
  try {
    userId = await createAuthUser(sb, phoneToAuthEmail(args.p_phone), tempPassword);
  } catch (e) {
    if (e instanceof HttpError && e.status === 409) {
      const again = unwrap(await sb.rpc('psvc_pa_sa_check_create', args));
      if (again.already) return { user_id: again.user_id, already: true, message: ALREADY_DONE };
    }
    throw e;
  }
  let result: Record<string, unknown>;
  try {
    result = unwrap(await sb.rpc('psvc_pa_sa_create', { ...args, p_user_id: userId }));
  } catch (e) {
    const { error } = await sb.auth.admin.deleteUser(userId);
    if (error) console.error('compensation_failed orphan_auth_user', userId);
    throw e;
  }
  if (result.already) {
    await sb.auth.admin.deleteUser(userId);
    return { user_id: result.user_id, already: true, message: ALREADY_DONE };
  }
  return { user_id: userId, temp_password: tempPassword };
}

async function saSetStatus(sb: SupabaseClient, actor: string, body: Body) {
  const requestId = requireUuid(body, 'request_id');
  const userId = requireUuid(body, 'user_id');
  const status = requireString(body, 'status');
  const res = unwrap(await sb.rpc('psvc_pa_sa_set_status', { p_actor: actor, p_request_id: requestId, p_user_id: userId, p_status: status }));
  // A replay re-applies the Auth state that matches the current status (the first attempt may have failed on Auth).
  const target = res.already ? String(res.status) : status;
  const { error } = await sb.auth.admin.updateUserById(userId, { ban_duration: target === 'inactive' ? BAN_FOREVER : 'none' });
  if (error) {
    console.error('auth_ban_failed', error.code ?? 'unknown');
    if (res.changed === true) {
      const rev = await sb.rpc('psvc_pa_sa_set_status', {
        p_actor: actor, p_request_id: crypto.randomUUID(), p_user_id: userId,
        p_status: status === 'inactive' ? 'active' : 'inactive', p_reason: 'compensation',
      });
      if (rev.error || (rev.data as { ok?: boolean } | null)?.ok === false) console.error('compensation_failed status_not_reverted', userId);
    }
    throw new HttpError(500, GENERIC);
  }
  return { ok: true };
}

serveJson(async (req, body) => {
  const sb = serviceClient();
  const actor = await callerId(req, sb);
  // Authorise before anything is validated (N-2): a Unit Admin or Supervisor always gets the same generic 403 and an audited denial,
  // whatever they send, and never learns which fields or actions exist.
  unwrap(await sb.rpc('psvc_pa_authorise', { p_actor: actor }));
  switch (body.action) {
    case 'tenant_create': return await tenantCreate(sb, actor, body);
    case 'tenant_update': return await tenantUpdate(sb, actor, body);
    case 'tenant_set_status': return await tenantSetStatus(sb, actor, body);
    case 'ua_create': return await uaCreate(sb, actor, body);
    case 'ua_reset_password': return await resetPassword(sb, actor, body, 'psvc_pa_ua_reset_password');
    case 'sa_create': return await saCreate(sb, actor, body);
    case 'sa_set_status': return await saSetStatus(sb, actor, body);
    case 'sa_reset_password': return await resetPassword(sb, actor, body, 'psvc_pa_sa_reset_password');
    default: throw new HttpError(400, { field: 'action', message: 'Unknown action' });
  }
});

