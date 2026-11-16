// account: a signed-in user changes their own password (D5). Expiry of a temporary password is checked first
// (AC-4), the current password is verified with a throwaway session, then Auth is updated and the flag cleared.
import { HttpError, unwrap } from '../_shared/errors.ts';
import { passwordPolicy } from '../_shared/identity.ts';
import { anonClient, callerId, serviceClient, sessionIdOf } from '../_shared/clients.ts';
import { requireString, serveJson } from '../_shared/http.ts';

serveJson(async (req, body) => {
  if (body.action !== 'change_password') throw new HttpError(400, { field: 'action', message: 'Unknown action' });
  const current = requireString(body, 'current_password');
  const next = requireString(body, 'new_password');

  const sb = serviceClient();
  const userId = await callerId(req, sb);

  // No-write pre-check in the database: refuses (and audits, D13) an inactive member, a suspended tenant or an expired
  // temporary password before Auth is touched.
  unwrap(await sb.rpc('svc_account_password_changed', { p_user_id: userId, p_keep_session: null, p_check_only: true }));

  const { data: authUser, error: uErr } = await sb.auth.admin.getUserById(userId);
  if (uErr || !authUser.user?.email) throw new HttpError(500, { message: 'Something went wrong. Try again.' });

  // Verify the current password with a throwaway session (never persisted, signed out locally right after).
  const anon = anonClient();
  const { error: signInError } = await anon.auth.signInWithPassword({ email: authUser.user.email, password: current });
  if (signInError) throw new HttpError(403, { field: 'current_password', message: 'Current password is incorrect' });
  await anon.auth.signOut({ scope: 'local' });

  const policy = passwordPolicy(next, current);
  if (!policy.ok) throw new HttpError(400, { field: 'new_password', message: policy.message });

  const { error: updError } = await sb.auth.admin.updateUserById(userId, { password: next });
  if (updError) {
    if (updError.code === 'weak_password') throw new HttpError(400, { field: 'new_password', message: 'Choose a stronger password' });
    console.error('auth_password_update_failed', updError.code ?? 'unknown');
    throw new HttpError(500, { message: 'Something went wrong. Try again.' });
  }

  // Ends every other session of the user (the caller's own, from the verified JWT, and its refresh token survive).
  unwrap(await sb.rpc('svc_account_password_changed', { p_user_id: userId, p_keep_session: sessionIdOf(req) }));
  return { ok: true };
});
