/**
 * Idempotently (re)creates the e2e fixture tenants, users and memberships on a HOSTED DEV project
 * (or local). Refuses to run anywhere else. Uses the service-role key; never logs secrets.
 *
 * Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, E2E_FIXTURE_PASSWORD, APP_ENV (local|development),
 *      DEV_SUPABASE_PROJECT_REF (required for hosted).
 */
import { createClient } from '@supabase/supabase-js';

type Fixture = { email: string; tenant: string | null; role?: 'unit_admin' | 'supervisor' };

export const TENANTS: { name: string; status: 'active' | 'suspended' }[] = [
  { name: 'e2e org A', status: 'active' },
  { name: 'e2e org B', status: 'active' },
  { name: 'e2e org S', status: 'suspended' },
];

export const USERS: Fixture[] = [
  { email: 'e2e-admin-a@example.test', tenant: 'e2e org A', role: 'unit_admin' },
  { email: 'e2e-sup-a@example.test', tenant: 'e2e org A', role: 'supervisor' },
  { email: 'e2e-sup-b@example.test', tenant: 'e2e org B', role: 'supervisor' },
  { email: 'e2e-nomember@example.test', tenant: null },
  { email: 'e2e-suspended-s@example.test', tenant: 'e2e org S', role: 'supervisor' },
];

export function assertSafeTarget(env: Record<string, string | undefined>): void {
  const url = env.SUPABASE_URL ?? '';
  const appEnv = env.APP_ENV ?? '';
  if (!['local', 'development'].includes(appEnv)) throw new Error(`Refusing: APP_ENV must be local or development (got "${appEnv}")`);
  const isLocal = /^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?\/?$/.test(url);
  const ref = env.DEV_SUPABASE_PROJECT_REF ?? '';
  const isDev = !!ref && url.replace(/\/$/, '') === `https://${ref}.supabase.co`;
  if (!isLocal && !isDev) throw new Error('Refusing: SUPABASE_URL is neither local nor the configured dev project');
  if (!USERS.every((u) => u.email.endsWith('@example.test'))) throw new Error('Refusing: fixture emails must use @example.test');
}

async function main() {
  assertSafeTarget(process.env);
  const password = process.env.E2E_FIXTURE_PASSWORD;
  if (!password || password.length < 16) throw new Error('E2E_FIXTURE_PASSWORD missing or shorter than 16 chars');
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Tenants (matched by name; fixture names are reserved for e2e).
  const tenantIds = new Map<string, string>();
  for (const t of TENANTS) {
    const { data: found, error } = await admin.from('tenant').select('id').eq('name', t.name).maybeSingle();
    if (error) throw error;
    if (found) {
      const { error: upErr } = await admin.from('tenant').update({ status: t.status }).eq('id', found.id);
      if (upErr) throw upErr;
      tenantIds.set(t.name, found.id);
    } else {
      const { data: created, error: insErr } = await admin.from('tenant').insert(t).select('id').single();
      if (insErr) throw insErr;
      tenantIds.set(t.name, created.id);
    }
  }

  // Users: reuse, reset password + confirm; never create duplicates.
  const existing = new Map<string, string>();
  for (let page = 1; ; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 });
    if (error) throw error;
    for (const u of data.users) if (u.email) existing.set(u.email, u.id);
    if (data.users.length < 200) break;
  }
  for (const f of USERS) {
    let id = existing.get(f.email);
    if (id) {
      const { error } = await admin.auth.admin.updateUserById(id, { password, email_confirm: true });
      if (error) throw error;
    } else {
      const { data, error } = await admin.auth.admin.createUser({ email: f.email, password, email_confirm: true });
      if (error) throw error;
      id = data.user.id;
    }
    // Membership: exactly the fixture's tenant/role, or none.
    const { error: delErr } = await admin.from('membership').delete().eq('user_id', id);
    if (delErr) throw delErr;
    if (f.tenant) {
      const { error: insErr } = await admin
        .from('membership')
        .insert({ user_id: id, tenant_id: tenantIds.get(f.tenant)!, role: f.role!, status: 'active' });
      if (insErr) throw insErr;
    }
  }
  console.log(`fixtures reset: ${TENANTS.length} tenants, ${USERS.length} users`);
}

if (require.main === module) {
  main().catch((e) => {
    console.error(`fixtures-reset failed: ${e instanceof Error ? e.message : String(e)}`);
    process.exit(1);
  });
}
