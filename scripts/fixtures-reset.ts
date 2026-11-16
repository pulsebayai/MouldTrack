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
import { createClient, type SupabaseClient } from '@supabase/supabase-js';

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

// 04-plant-masters (D8): the fixture plant. Org U is mutated by e2e (own site, lines, machines, products and targets);
// A and B hold one machine and one product each for read-only isolation checks. Must match supabase/seed.sql.
export type PlantFixture = {
  tenant: string;
  site: string;
  lines: string[];
  machines: { code: string; name: string; line?: string }[];
  products: { code: string; description: string }[];
  targets: { machine: string; product: string; pieces: number }[];
};
export const PLANT: PlantFixture[] = [
  {
    tenant: 'e2e org A', site: 'Fixture Plant A', lines: [],
    machines: [{ code: 'FX-MA1', name: 'Fixture Machine A1' }],
    products: [{ code: 'FX-PA1', description: 'Fixture Product A1' }],
    targets: [{ machine: 'FX-MA1', product: 'FX-PA1', pieces: 1000 }],
  },
  {
    tenant: 'e2e org B', site: 'Fixture Plant B', lines: [],
    machines: [{ code: 'FX-MB1', name: 'Fixture Machine B1' }],
    products: [{ code: 'FX-PB1', description: 'Fixture Product B1' }],
    targets: [{ machine: 'FX-MB1', product: 'FX-PB1', pieces: 500 }],
  },
  {
    tenant: 'e2e org U', site: 'Fixture Plant U', lines: ['Fixture Line 1', 'Fixture Line 2'],
    machines: [
      { code: 'FX-MU1', name: 'Fixture Machine U1', line: 'Fixture Line 1' },
      { code: 'FX-MU2', name: 'Fixture Machine U2', line: 'Fixture Line 2' },
      { code: 'FX-MU3', name: 'Fixture Machine U3' },
    ],
    products: [
      { code: 'FX-PU1', description: 'Fixture Product U1' },
      { code: 'FX-PU2', description: 'Fixture Product U2' },
      { code: 'FX-PU3', description: 'Fixture Product U3' },
    ],
    targets: [
      { machine: 'FX-MU1', product: 'FX-PU1', pieces: 1200 },
      { machine: 'FX-MU2', product: 'FX-PU2', pieces: 800 },
    ], // FX-MU3 deliberately has no target ("No target set")
  },
];
/** Rows created by e2e tests carry this code/name prefix; fixtures-reset removes (or retires) them. */
export const isThrowawayPlantName = (name: string): boolean => /^E2E-[A-Za-z0-9]{3,16}$/.test(name);
const FIXTURE_TARGET_FROM = '2026-01-01';

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

/** 03: plan label per fixture tenant (default trial). */
export const TENANT_PLANS: Record<string, 'trial' | 'active'> = { 'e2e org A': 'active', 'e2e org U': 'active' };

/** 03: Platform Super Admins (not tenant members). Canonical block, same safety rules as USERS. */
export const SUPER_ADMINS: Fixture[] = [
  fx('sa1', '+919000000090', 'Fixture Super Admin 1', '', null),
  fx('sa2', '+919000000091', 'Fixture Super Admin 2', '', null),
];

/** Tenants created by 03's tests are named with this prefix; reset suspends them (tenants are never deleted). */
export const TEST_TENANT_PREFIX = 'e2e t3 ';

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

type Admin = SupabaseClient;
const must = <T>(r: { data: T; error: { message: string } | null }): T => {
  if (r.error) throw new Error(r.error.message);
  return r.data;
};

/** The fixture site exists with its fixture name and time zone (an e2e run may have renamed it; targets never touch it). Returns its id. */
export async function ensureFixtureSite(admin: Admin, tenantId: string, fx: Pick<PlantFixture, 'site'>): Promise<string> {
  const want = { name: fx.site, timezone: 'Asia/Kolkata' };
  const site = must(await admin.from('site').select('id, name, timezone').eq('tenant_id', tenantId).maybeSingle());
  if (!site) return must(await admin.from('site').insert({ tenant_id: tenantId, ...want }).select('id').single())!.id as string;
  if (site.name !== want.name || site.timezone !== want.timezone) must(await admin.from('site').update(want).eq('id', site.id).select('id'));
  return site.id as string;
}

/**
 * Plant fixtures (04, D8). target_version is append-only, so targets are only ever inserted (and only when the pair has none);
 * throwaway machines/products that already have targets are retired instead of deleted. Dev accumulates a few retired rows per run (accepted).
 */
async function resetPlant(admin: Admin, tenantIds: Map<string, string>) {
  for (const fx of PLANT) {
    const tenantId = tenantIds.get(fx.tenant)!;
    const siteId = await ensureFixtureSite(admin, tenantId, fx);

    const lineIds = new Map<string, string>();
    for (const name of fx.lines) {
      let line = must(await admin.from('line').select('id').eq('site_id', siteId).eq('name', name).is('archived_at', null).maybeSingle());
      if (!line) line = must(await admin.from('line').insert({ tenant_id: tenantId, site_id: siteId, name }).select('id').single());
      lineIds.set(name, line!.id as string);
    }
    const machineIds = new Map<string, string>();
    for (const m of fx.machines) {
      const row = { tenant_id: tenantId, site_id: siteId, code: m.code, name: m.name, line_id: m.line ? lineIds.get(m.line)! : null, status: 'active', retired_at: null };
      const found = must(await admin.from('machine').select('id').eq('tenant_id', tenantId).eq('code', m.code).maybeSingle());
      if (found) must(await admin.from('machine').update(row).eq('id', found.id).select('id'));
      machineIds.set(m.code, found ? (found.id as string) : (must(await admin.from('machine').insert(row).select('id').single())!.id as string));
    }
    const productIds = new Map<string, string>();
    for (const p of fx.products) {
      const row = { tenant_id: tenantId, code: p.code, description: p.description, uom: 'pcs', retired_at: null };
      const found = must(await admin.from('product').select('id').eq('tenant_id', tenantId).eq('code', p.code).maybeSingle());
      if (found) must(await admin.from('product').update(row).eq('id', found.id).select('id'));
      productIds.set(p.code, found ? (found.id as string) : (must(await admin.from('product').insert(row).select('id').single())!.id as string));
    }
    // Targets: only inserted for a pair that has no history at all (history is append-only and never touched).
    const { data: anyUa } = await admin.from('membership').select('user_id').eq('tenant_id', tenantId).eq('role', 'unit_admin').limit(1);
    const recordedBy = anyUa?.[0]?.user_id as string | undefined;
    for (const t of fx.targets) {
      const machineId = machineIds.get(t.machine)!;
      const productId = productIds.get(t.product)!;
      const existing = must(await admin.from('target_version').select('id').eq('machine_id', machineId).eq('product_id', productId).limit(1));
      if (existing && existing.length > 0) continue;
      must(await admin.from('target_version').insert({
        tenant_id: tenantId, machine_id: machineId, product_id: productId, effective_from: FIXTURE_TARGET_FROM,
        pieces_per_shift: t.pieces, recorded_by: recordedBy ?? '00000000-0000-0000-0000-000000000000',
      }).select('id'));
    }

    // Throwaway rows from e2e runs: delete when nothing references them, otherwise retire / archive.
    const stale = must(await admin.from('machine').select('id, code, retired_at').eq('tenant_id', tenantId).like('code', 'E2E-%'));
    for (const m of stale ?? []) {
      if (!isThrowawayPlantName(m.code as string)) continue;
      const used = must(await admin.from('target_version').select('id').eq('machine_id', m.id).limit(1));
      if (used && used.length > 0) {
        if (!m.retired_at) must(await admin.from('machine').update({ retired_at: new Date().toISOString() }).eq('id', m.id).select('id'));
      } else must(await admin.from('machine').delete().eq('id', m.id).select('id'));
    }
    const staleP = must(await admin.from('product').select('id, code, retired_at').eq('tenant_id', tenantId).like('code', 'E2E-%'));
    for (const p of staleP ?? []) {
      if (!isThrowawayPlantName(p.code as string)) continue;
      const used = must(await admin.from('target_version').select('id').eq('product_id', p.id).limit(1));
      if (used && used.length > 0) {
        if (!p.retired_at) must(await admin.from('product').update({ retired_at: new Date().toISOString() }).eq('id', p.id).select('id'));
      } else must(await admin.from('product').delete().eq('id', p.id).select('id'));
    }
    const staleL = must(await admin.from('line').select('id, name, archived_at').eq('tenant_id', tenantId).like('name', 'E2E-%'));
    for (const l of staleL ?? []) {
      if (!isThrowawayPlantName(l.name as string)) continue;
      const used = must(await admin.from('machine').select('id').eq('line_id', l.id).limit(1));
      if (used && used.length > 0) {
        if (!l.archived_at) must(await admin.from('line').update({ archived_at: new Date().toISOString() }).eq('id', l.id).select('id'));
      } else must(await admin.from('line').delete().eq('id', l.id).select('id'));
    }
  }
}

async function main() {
  assertSafeTarget(process.env, [...USERS, ...SUPER_ADMINS]);
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

  for (const [name, plan] of Object.entries(TENANT_PLANS)) {
    const { error } = await admin.from('tenant').update({ plan_label: plan }).eq('id', tenantIds.get(name)!);
    if (error) throw error;
  }
  // Tenants registered by earlier test runs stay (never deleted) but are suspended so they cost nothing.
  const { error: susErr } = await admin.from('tenant')
    .update({ status: 'suspended', suspended_reason: 'fixture cleanup' })
    .like('name', `${TEST_TENANT_PREFIX}%`).eq('status', 'active');
  if (susErr) throw susErr;

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
  await resetPlant(admin, tenantIds);
  // Super Admins: reuse the Auth user, reset password + unban, and put the platform_admin row in its canonical state.
  for (const f of SUPER_ADMINS) {
    let id = existing.get(f.email);
    if (id) {
      const { error } = await admin.auth.admin.updateUserById(id, { password, email_confirm: true, ban_duration: 'none' });
      if (error) throw error;
    } else {
      const { data, error } = await admin.auth.admin.createUser({ email: f.email, password, email_confirm: true });
      if (error) throw error;
      id = data.user.id;
    }
    const { error: delErr } = await admin.from('membership').delete().eq('user_id', id);
    if (delErr) throw delErr;
    const { error: upErr } = await admin.from('platform_admin').upsert(
      { user_id: id, full_name: f.name, phone_e164: f.phone, status: 'active', must_change_password: false, temp_password_expires_at: null },
      { onConflict: 'user_id' },
    );
    if (upErr) throw upErr;
  }
  console.log(`fixtures reset: ${TENANTS.length} tenants, ${USERS.length} users, ${SUPER_ADMINS.length} super admins, ${doomed.size} stale users removed`);
}

if (require.main === module) {
  main().catch((e) => {
    console.error(`fixtures-reset failed: ${e instanceof Error ? e.message : String(e)}`);
    process.exit(1);
  });
}
