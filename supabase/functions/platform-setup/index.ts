// platform-setup: the one-time creation of the first Platform Super Admin (03, D4, AC-2). The only unauthenticated write path.
// Refuses once any Super Admin exists (audited, SQL), needs the secret PLATFORM_SETUP_TOKEN in the x-setup-token header (constant-time
// compare), and answers with the temporary password exactly once. Neither the token nor the password is ever logged or stored.
import { HttpError } from '../_shared/errors.ts';
import { generateTempPassword, phoneToAuthEmail } from '../_shared/identity.ts';
import { randomBytes, serviceClient } from '../_shared/clients.ts';
import { createAuthUser, phoneOf } from '../_shared/auth-users.ts';
import { requireString, serveJson } from '../_shared/http.ts';
import { setupTokenConfigured, setupTokenMatches } from '../_shared/setup-token.ts';

const REFUSED = { code: 'not_allowed', message: 'Not allowed' };
const CLOSED = { code: 'setup_closed', message: 'Not allowed' };

function refusal(data: unknown): HttpError {
  return new HttpError(403, (data as { code?: string } | null)?.code === 'setup_closed' ? CLOSED : REFUSED);
}

serveJson(async (req, body) => {
  const expected = Deno.env.get('PLATFORM_SETUP_TOKEN');
  // No secret configured (every environment except while setup is pending): refuse without touching the database.
  if (!setupTokenConfigured(expected)) throw new HttpError(403, REFUSED);

  const sb = serviceClient();
  // Closed already? Refuse with or without a token; the SQL function audits the refusal (throttled).
  const check = await sb.rpc('psvc_pa_setup_check');
  if (check.error) {
    console.error('setup_check_failed', check.error.code ?? 'unknown');
    throw new HttpError(500, { message: 'Something went wrong. Try again.' });
  }
  if ((check.data as { ok?: boolean } | null)?.ok !== true) throw refusal(check.data);

  if (!setupTokenMatches(expected, req.headers.get('x-setup-token'))) throw new HttpError(403, REFUSED);

  const fullName = requireString(body, 'full_name');
  const phone = phoneOf(body, true)!;
  const tempPassword = generateTempPassword(randomBytes);
  const userId = await createAuthUser(sb, phoneToAuthEmail(phone), tempPassword);

  const res = await sb.rpc('psvc_pa_setup_first', { p_user_id: userId, p_full_name: fullName, p_phone: phone });
  if (res.error || (res.data as { ok?: boolean } | null)?.ok !== true) {
    // Compensation: nothing may stay behind in Auth when the database refused.
    const { error: delError } = await sb.auth.admin.deleteUser(userId);
    if (delError) console.error('compensation_failed orphan_auth_user', userId);
    if (res.error) {
      let detail: { code?: string; field?: string } = {};
      try {
        detail = res.error.details ? JSON.parse(res.error.details) : {};
      } catch {
        detail = {};
      }
      if (detail.code === 'validation') throw new HttpError(400, { field: detail.field, message: res.error.message });
      if (detail.code === 'duplicate') throw new HttpError(409, { field: detail.field, message: res.error.message });
      console.error('setup_first_failed', res.error.code ?? 'unknown');
      throw new HttpError(500, { message: 'Something went wrong. Try again.' });
    }
    throw refusal(res.data);
  }
  return { user_id: userId, temp_password: tempPassword };
});
