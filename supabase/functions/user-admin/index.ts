// user-admin: Unit Admin account management (02-tenancy-and-roles, D4). All authorisation, validation, guards and
// auditing live in the service-only SQL functions; this function verifies the caller, calls Auth, and compensates.
// Temporary passwords exist only in the create / reset_password response body: never stored, logged or audited.
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { HttpError, unwrap } from '../_shared/errors.ts';
import { generateTempPassword, normalisePhone, phoneToAuthEmail } from '../_shared/identity.ts';
import { callerId, randomBytes, serviceClient } from '../_shared/clients.ts';
import { optionalString, requireString, requireUuid, serveJson } from '../_shared/http.ts';

const ALREADY_DONE = 'Already done — reset the password if it was lost';
const PHONE_TAKEN = 'This phone number is already registered';
const BAN_FOREVER = '876000h'; // ~100 years; lifted with 'none'

function phoneOf(body: Record<string, unknown>, required: boolean): string | null {
  const raw = required ? requireString(body, 'phone') : optionalString(body, 'phone');
  if (raw === null) return null;
  const n = normalisePhone(raw);
  if (!n.ok) throw new HttpError(400, { field: 'phone', message: n.message });
  return n.e164;
}

function isEmailTaken(error: { code?: string; message?: string }): boolean {
  return error.code === 'email_exists' || /already (been )?registered|already exists/i.test(error.message ?? '');
}

async function create(sb: SupabaseClient, actor: string, body: Record<string, unknown>) {
  const requestId = requireUuid(body, 'request_id');
  const fullName = requireString(body, 'full_name');
  const employeeId = requireString(body, 'employee_id');
  const phone = phoneOf(body, true)!;
  const role = requireString(body, 'role');

  const check = unwrap(await sb.rpc('svc_ua_check_create', {
    p_actor: actor, p_request_id: requestId, p_full_name: fullName, p_employee_id: employeeId, p_phone: phone, p_role: role,
  }));
  if (check.already) return { user_id: check.user_id, already: true, message: ALREADY_DONE };

  const tempPassword = generateTempPassword(randomBytes);
  const { data: created, error: authError } = await sb.auth.admin.createUser({
    email: phoneToAuthEmail(phone), password: tempPassword, email_confirm: true,
  });
  if (authError || !created.user) {
    if (authError && isEmailTaken(authError)) throw new HttpError(409, { field: 'phone', message: PHONE_TAKEN });
    console.error('auth_create_failed', authError?.code ?? 'unknown');
    throw new HttpError(500, { message: 'Something went wrong. Try again.' });
  }
  const userId = created.user.id;

  let result: Record<string, unknown>;
  try {
    result = unwrap(await sb.rpc('svc_ua_create_user', {
      p_actor: actor, p_request_id: requestId, p_user_id: userId,
      p_full_name: fullName, p_employee_id: employeeId, p_phone: phone, p_role: role,
    }));
  } catch (e) {
    // Compensation: the database refused, so no Auth user may be left behind.
    const { error: delError } = await sb.auth.admin.deleteUser(userId);
    if (delError) console.error('compensation_failed orphan_auth_user', userId);
    throw e;
  }
  if (result.already) {
    // A concurrent duplicate of this request won; discard the user created here.
    await sb.auth.admin.deleteUser(userId);
    return { user_id: result.user_id, already: true, message: ALREADY_DONE };
  }
  return { user_id: userId, temp_password: tempPassword };
}

async function update(sb: SupabaseClient, actor: string, body: Record<string, unknown>) {
  const requestId = requireUuid(body, 'request_id');
  const userId = requireUuid(body, 'user_id');
  const args = {
    p_actor: actor, p_request_id: requestId, p_user_id: userId,
    p_full_name: optionalString(body, 'full_name'), p_employee_id: optionalString(body, 'employee_id'),
    p_phone: phoneOf(body, false), p_role: optionalString(body, 'role'),
  };

  const check = unwrap(await sb.rpc('svc_ua_check_update', args));
  if (check.already) return { ok: true };

  const phoneChanged = check.phone_changed === true;
  if (phoneChanged) {
    const { error } = await sb.auth.admin.updateUserById(userId, { email: phoneToAuthEmail(args.p_phone!), email_confirm: true });
    if (error) {
      if (isEmailTaken(error)) throw new HttpError(409, { field: 'phone', message: PHONE_TAKEN });
      console.error('auth_update_failed', error.code ?? 'unknown');
      throw new HttpError(500, { message: 'Something went wrong. Try again.' });
    }
  }
  try {
    unwrap(await sb.rpc('svc_ua_update_user', args));
  } catch (e) {
    if (phoneChanged) {
      const { error } = await sb.auth.admin.updateUserById(userId, {
        email: phoneToAuthEmail(String(check.current_phone)), email_confirm: true,
      });
      if (error) console.error('compensation_failed email_not_restored', userId);
    }
    throw e;
  }
  return { ok: true };
}

async function setStatus(sb: SupabaseClient, actor: string, body: Record<string, unknown>) {
  const requestId = requireUuid(body, 'request_id');
  const userId = requireUuid(body, 'user_id');
  const status = requireString(body, 'status');

  const res = unwrap(await sb.rpc('svc_ua_set_status', { p_actor: actor, p_request_id: requestId, p_user_id: userId, p_status: status }));
  if (res.already) return { ok: true }; // the first attempt already applied the Auth ban state

  const { error } = await sb.auth.admin.updateUserById(userId, { ban_duration: status === 'inactive' ? BAN_FOREVER : 'none' });
  if (error) {
    console.error('auth_ban_failed', error.code ?? 'unknown');
    if (res.changed === true) {
      // Revert the database change so membership and Auth agree.
      await sb.rpc('svc_ua_set_status', {
        p_actor: actor, p_request_id: crypto.randomUUID(), p_user_id: userId, p_status: status === 'inactive' ? 'active' : 'inactive',
      });
    }
    throw new HttpError(500, { message: 'Something went wrong. Try again.' });
  }
  return { ok: true };
}

async function resetPassword(sb: SupabaseClient, actor: string, body: Record<string, unknown>) {
  const requestId = requireUuid(body, 'request_id');
  const userId = requireUuid(body, 'user_id');

  const res = unwrap(await sb.rpc('svc_ua_reset_password', { p_actor: actor, p_request_id: requestId, p_user_id: userId }));
  if (res.already) return { already: true, message: ALREADY_DONE };

  const tempPassword = generateTempPassword(randomBytes);
  const { error } = await sb.auth.admin.updateUserById(userId, { password: tempPassword });
  if (error) {
    // The user is flagged must-change but their old password still works; the Unit Admin can retry.
    console.error('auth_reset_failed', error.code ?? 'unknown');
    throw new HttpError(500, { message: 'Something went wrong. Try again.' });
  }
  return { temp_password: tempPassword };
}

serveJson(async (req, body) => {
  const sb = serviceClient();
  const actor = await callerId(req, sb);
  switch (body.action) {
    case 'create': return await create(sb, actor, body);
    case 'update': return await update(sb, actor, body);
    case 'set_status': return await setStatus(sb, actor, body);
    case 'reset_password': return await resetPassword(sb, actor, body);
    default: throw new HttpError(400, { field: 'action', message: 'Unknown action' });
  }
});
