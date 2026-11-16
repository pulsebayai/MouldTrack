/**
 * Idempotently (re)creates the e2e fixture tenants, users and memberships on a HOSTED DEV project
 * (or local). Refuses to run anywhere else. Uses the service-role key; never logs secrets.
 *
 * Identities (02-tenancy-and-roles, D2/D3): sign-in is by phone. Canonical fixtures use the phone block
 * +91 90000 00001-00099 and a non-deliverable Auth address `<10 digits>@phone.mouldtrack.invalid`. Throwaway users
 * created by tests use +91 90000 10000-99999; this script deletes them (and anything else living in a fixture
 * tenant that is not canonical) so every run starts clean.
 *
 * Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, E2E_FIXTURE_PASSWORD, APP_ENV (local|development),
 *      DEV_SUPABASE_PROJECT_REF (required for hosted).
 */
import { createClient } from '@supabase/supabase-js';

export type Fixture = {
  key: string;
  phone: string;
  email: string;
  name: string;
  employeeId: string;
  tenant: string | null;
  role?: 'unit_admin' | 'supervisor';
  mustChange?: boolean;
};

export const TENANTS: { name: string; status: 'active' | 'suspended' }[] = [
  { name: 'e2e org A', status: 'active' },
  { name: 'e2e org B', status: 'active' },
  { name: 'e2e org S', status: 'suspended' },
  { name: 'e2e org U', status: 'active' },
];

const AUTH_DOMAIN = 'phone.mouldtrack.invalid';
const fx = (key: string, phone: string, name: string, employeeId: string, tenant: string | null, role?: Fixture['role'], mustChange = false): Fixture => ({
  key, phone, email: `${phone.slice(3)}@${AUTH_DOMAIN}`, name, employeeId, tenant, role, mustChange,
});

export const USERS: Fixture[] = [
  fx('adminA', '+919000000001', 'Fixture Admin A', 'FX-A1', 'e2e org A', 'unit_admin'),
  fx('supA', '+919000000002', 'Fixture Supervisor A', 'FX-A2', 'e2e org A', 'supervisor'),
  fx('supB', '+919000000003', 'Fixture Supervisor B', 'FX-B2', 'e2e org B', 'supervisor'),
  fx('suspended', '+919000000004', 'Fixture Suspended S', 'FX-S2', 'e2e org S', 'supervisor'),
  fx('noMember', '+919000000005', 'Fixture No Member', 'FX-NONE', null),
  fx('u1', '+919000000006', 'Fixture Admin U1', 'FX-U1', 'e2e org U', 'unit_admin'),
  fx('u2', '+919000000007', 'Fixture Admin U2', 'FX-U2', 'e2e org U', 'unit_admin'),
  fx('u3', '+919000000008', 'Fixture Supervisor U3', 'FX-U3', 'e2e org U', 'supervisor'),
  fx('u4', '+919000000009', 'Fixture Fresh U4', 'FX-U4', 'e2e org U', 'supervisor', true),
];

/** Fixtures created by 01 (email sign-in); removed on reset. */
export const LEGACY_EMAILS = [
  'e2e-admin-a@example.test',
  'e2e-sup-a@example.test',
  'e2e-sup-b@example.test',
  'e2e-nomember@example.test',
  'e2e-suspended-s@example.test',
];

export const isCanonicalPhone = (phone: string): boolean => /^\+9190000000(0[1-9]|[1-9][0-9])$/.test(phone);
export const isFixtureAuthEmail = (email: string): boolean => /^90000000(0[1-9]|[1-9][0-9])@phone\.mouldtrack\.invalid$/.test(email);
export const isThrowawayAuthEmail = (email: string): boolean => /^90000[1-9][0-9]{4}@phone\.mouldtrack\.invalid$/.test(email);

export function assertSafeTarget(env: Record<string, string | undefined>, users: Fixture[] = USERS): void {
  const url = env.SUPABASE_URL ?? '';
  const appEnv = env.APP_ENV ?? '';
  if (!['local', 'development'].includes(appEnv)) throw new Error(`Refusing: APP_ENV must be local or development (got "${appEnv}")`);
  const isLocal = /^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?\/?$/.test(url);
  const ref = env.DEV_SUPABASE_PROJECT_REF ?? '';
  const isDev = !!ref && url.replace(/\/$/, '') === `https://${ref}.supabase.co`;
  if (!isLocal && !isDev) throw new Error('Refusing: SUPABASE_URL is neither local nor the configured dev project');
  if (!users.every((u) => u.email.endsWith(`@${AUTH_DOMAIN}`))) throw new Error('Refusing: fixture email must use the reserved .invalid domain');
  if (!users.every((u) => isCanonicalPhone(u.phone))) throw new Error('Refusing: fixture phone outside the canonical block +91 90000 00001-00099');
  if (!users.every((u) => u.email === `${u.phone.slice(3)}@${AUTH_DOMAIN}`)) throw new Error('Refusing: fixture email does not match its phone');
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

  const existing = new Map<string, string>();
  for (let page = 1; ; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 });
    if (error) throw error;
    for (const u of data.users) if (u.email) existing.set(u.email, u.id);
    if (data.users.length < 200) break;
  }

  // Clean-up: legacy email fixtures, throwaway users from earlier test runs, and any non-canonical member of a fixture tenant.
  const canonicalEmails = new Set(USERS.map((u) => u.email));
  const doomed = new Set<string>();
  for (const [email, id] of existing) {
    if (LEGACY_EMAILS.includes(email) || isThrowawayAuthEmail(email)) doomed.add(id);
  }
  const { data: members, error: memErr } = await admin.from('membership').select('user_id').in('tenant_id', [...tenantIds.values()]);
  if (memErr) throw memErr;
  const canonicalIds = new Set([...canonicalEmails].map((e) => existing.get(e)).filter((x): x is string => !!x));
  for (const m of members ?? []) if (!canonicalIds.has(m.user_id)) doomed.add(m.user_id);
  for (const id of doomed) {
    const { error } = await admin.auth.admin.deleteUser(id); // membership cascades; audit events are kept
    if (error) throw error;
  }

  // Canonical users: reuse, reset password + unban + confirm; never create duplicates.
  for (const f of USERS) {
    let id = existing.get(f.email);
    if (id && !doomed.has(id)) {
      const { error } = await admin.auth.admin.updateUserById(id, { password, email_confirm: true, ban_duration: 'none' });
      if (error) throw error;
    } else {
      const { data, error } = await admin.auth.admin.createUser({ email: f.email, password, email_confirm: true });
      if (error) throw error;
      id = data.user.id;
    }
    // Membership: exactly the fixture's profile, or none.
    const { error: delErr } = await admin.from('membership').delete().eq('user_id', id);
    if (delErr) throw delErr;
    if (f.tenant) {
      const { error: insErr } = await admin.from('membership').insert({
        user_id: id,
        tenant_id: tenantIds.get(f.tenant)!,
        role: f.role!,
        status: 'active',
        full_name: f.name,
        employee_id: f.employeeId,
        phone_e164: f.phone,
        must_change_password: !!f.mustChange,
        temp_password_expires_at: f.mustChange ? new Date(Date.now() + 7 * 24 * 3600_000).toISOString() : null,
      });
      if (insErr) throw insErr;
    }
  }
  console.log(`fixtures reset: ${TENANTS.length} tenants, ${USERS.length} users, ${doomed.size} stale users removed`);
}

if (require.main === module) {
  main().catch((e) => {
    console.error(`fixtures-reset failed: ${e instanceof Error ? e.message : String(e)}`);
    process.exit(1);
  });
}
