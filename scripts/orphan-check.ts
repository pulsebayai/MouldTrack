/**
 * Fails when hosted DEV has Auth users without a membership or platform_admin row (a leaked half-created user, D4 compensation).
 * The only allowed exception is the `nomember` fixture. Read-only; refuses anything but local/dev.
 */
import { createClient } from '@supabase/supabase-js';
import { assertSafeTarget } from './fixtures-reset';

export const ALLOWED_ORPHAN_EMAILS = ['9000000005@phone.mouldtrack.invalid'];

export function findOrphans(authUsers: { id: string; email: string | null }[], memberIds: Set<string>): string[] {
  return authUsers
    .filter((u) => !memberIds.has(u.id) && !(u.email && ALLOWED_ORPHAN_EMAILS.includes(u.email)))
    .map((u) => u.email ?? `(no email) ${u.id}`);
}

async function main() {
  assertSafeTarget(process.env);
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false, autoRefreshToken: false } });
  const users: { id: string; email: string | null }[] = [];
  for (let page = 1; ; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 });
    if (error) throw error;
    users.push(...data.users.map((u) => ({ id: u.id, email: u.email ?? null })));
    if (data.users.length < 200) break;
  }
  const { data: members, error } = await admin.from('membership').select('user_id');
  if (error) throw error;
  // 03: Platform Super Admins have no membership by design; their platform_admin row is what ties them to an Auth user.
  const { data: admins, error: aErr } = await admin.from('platform_admin').select('user_id');
  if (aErr) throw aErr;
  const orphans = findOrphans(users, new Set([...(members ?? []), ...(admins ?? [])].map((m) => m.user_id as string)));
  if (orphans.length) {
    console.error(`orphan Auth users without a membership (${orphans.length}):\n${orphans.map((o) => `  ${o}`).join('\n')}`);
    process.exit(1);
  }
  console.log(`no orphan Auth users (${users.length} users checked)`);
}

if (require.main === module) {
  main().catch((e) => {
    console.error(`orphan-check failed: ${e instanceof Error ? e.message : String(e)}`);
    process.exit(1);
  });
}
