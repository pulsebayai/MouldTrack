/**
 * Hosted DEV consistency between memberships and Auth (R7, D4 compensation proof). Read-only; refuses anything but local/dev.
 *  - every membership's Auth email = phoneToAuthEmail(phone_e164)
 *  - every inactive membership's Auth user is banned, every active one is not
 * Output names user ids only (no phones, emails or names).
 */
import { createClient } from '@supabase/supabase-js';
import { phoneToAuthEmail } from '../supabase/functions/_shared/identity';
import { assertSafeTarget } from './fixtures-reset';

type Member = { user_id: string; phone_e164: string; status: 'active' | 'inactive' };
type AuthUser = { id: string; email: string | null; banned_until: string | null };

export function findInconsistencies(members: Member[], authUsers: AuthUser[], now: Date = new Date()): string[] {
  const byId = new Map(authUsers.map((u) => [u.id, u]));
  const out: string[] = [];
  for (const m of members) {
    const u = byId.get(m.user_id);
    if (!u) {
      out.push(`${m.user_id}: membership has no Auth user`);
      continue;
    }
    if (u.email !== phoneToAuthEmail(m.phone_e164)) out.push(`${m.user_id}: auth email does not match the membership phone`);
    const banned = !!u.banned_until && new Date(u.banned_until).getTime() > now.getTime();
    if (m.status === 'inactive' && !banned) out.push(`${m.user_id}: inactive member is not banned in Auth`);
    if (m.status === 'active' && banned) out.push(`${m.user_id}: active member is banned in Auth`);
  }
  return out;
}

async function main() {
  assertSafeTarget(process.env);
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false, autoRefreshToken: false } });
  const users: AuthUser[] = [];
  for (let page = 1; ; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 });
    if (error) throw error;
    users.push(...data.users.map((u) => ({ id: u.id, email: u.email ?? null, banned_until: (u as { banned_until?: string | null }).banned_until ?? null })));
    if (data.users.length < 200) break;
  }
  const { data: members, error } = await admin.from('membership').select('user_id, phone_e164, status');
  if (error) throw error;
  // 03: Super Admins follow the same rules (email = phone, inactive banned, active not banned).
  const { data: admins, error: aErr } = await admin.from('platform_admin').select('user_id, phone_e164, status');
  if (aErr) throw aErr;
  const bad = findInconsistencies([...(members ?? []), ...(admins ?? [])] as Member[], users);
  if (bad.length) {
    console.error(`membership / Auth inconsistencies (${bad.length}):\n${bad.map((b) => `  ${b}`).join('\n')}`);
    process.exit(1);
  }
  console.log(`memberships and Auth agree (${members?.length ?? 0} memberships checked)`);
}

if (require.main === module) {
  main().catch((e) => {
    console.error(`consistency-check failed: ${e instanceof Error ? e.message : String(e)}`);
    process.exit(1);
  });
}
