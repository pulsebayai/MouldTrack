/**
 * Idempotently (re)creates the e2e fixture tenants, users and memberships on the HOSTED DEV or STAGING project
 * (or local). Refuses to run anywhere else, and always refuses the prod project. Uses the service-role key; never logs secrets.
 *
 * Identities (02-tenancy-and-roles, D2/D3): sign-in is by phone. Canonical fixtures use the phone block
 * +91 90000 00001-00099 and a non-deliverable Auth address `<10 digits>@phone.mouldtrack.invalid`. Throwaway users
 * created by tests use +91 90000 10000-99999; this script deletes them (and anything else living in a fixture
 * tenant that is not canonical) so every run starts clean.
 *
 * Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, E2E_FIXTURE_PASSWORD, APP_ENV (local|development|staging),
 *      DEV_SUPABASE_PROJECT_REF / STAGING_SUPABASE_PROJECT_REF (required for that hosted target); PROD_SUPABASE_PROJECT_REF is always refused.
 */
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { closeAsUnitAdmin } from './close-throwaway-issues';

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
  { name: 'e2e org H', status: 'active' }, // 08: the handover fixture tenant, enforced (handover_setting.required = true)
];

/** 08 (D1): fixture tenants where the rd_opening gate applies. Tenants inserted directly are otherwise not gated; mirrors supabase/seed.sql. */
export const HANDOVER_ENFORCED = ['e2e org H'];
export const HANDOVER_OVERDUE_MINUTES = 60;

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
  {
    // 08: org H holds two machines, owned by two supervisors on both shifts, with one open issue on each machine reported by the other supervisor,
    // so each supervisor always has an inherited issue to answer (the e2e and Maestro handover flows).
    tenant: 'e2e org H', site: 'Fixture Plant H', lines: [],
    machines: [{ code: 'FX-MH1', name: 'Fixture Machine H1' }, { code: 'FX-MH2', name: 'Fixture Machine H2' }],
    products: [{ code: 'FX-PH1', description: 'Fixture Product H1' }],
    targets: [{ machine: 'FX-MH1', product: 'FX-PH1', pieces: 900 }, { machine: 'FX-MH2', product: 'FX-PH1', pieces: 700 }],
  },
];
// 05-shifts-and-assignments (D12): fixture shifts and the recurring plan. Must match supabase/seed.sql (a Jest test checks this file against it).
// Org A: two shifts that together cover all 24 hours, so the supervisor fixture (supA) always has a running occurrence (Android/web "My shift").
// Org U: Morning and Night; supervisor U3 owns two machines on both. Org B has none. Plan versions start on a fixed past date.
export type ShiftFixture = {
  id: string;
  tenant: string;
  name: string;
  start: string; // HH:MM, site time zone
  end: string;
  assignments: { machine: string; supervisor: string }[]; // supervisor = USERS key
};
export const SHIFTS: ShiftFixture[] = [
  { id: '54000000-0000-4000-a000-0000000000a1', tenant: 'e2e org A', name: 'Fixture Shift A1', start: '00:00', end: '12:00', assignments: [{ machine: 'FX-MA1', supervisor: 'supA' }] },
  { id: '54000000-0000-4000-a000-0000000000a2', tenant: 'e2e org A', name: 'Fixture Shift A2', start: '12:00', end: '00:00', assignments: [{ machine: 'FX-MA1', supervisor: 'supA' }] },
  {
    id: '54000000-0000-4000-a000-0000000000e1', tenant: 'e2e org U', name: 'Fixture Morning', start: '06:00', end: '14:00',
    assignments: [{ machine: 'FX-MU1', supervisor: 'u3' }, { machine: 'FX-MU2', supervisor: 'u3' }],
  },
  {
    id: '54000000-0000-4000-a000-0000000000e2', tenant: 'e2e org U', name: 'Fixture Night', start: '22:00', end: '06:00',
    assignments: [{ machine: 'FX-MU1', supervisor: 'u3' }, { machine: 'FX-MU2', supervisor: 'u3' }],
  },
  // 08: org H, like org A, covers all 24 hours, so each supervisor always has a running occurrence (and a handover checklist). h2 owns FX-MH1, h3 owns FX-MH2.
  { id: '54000000-0000-4000-a000-0000000000f1', tenant: 'e2e org H', name: 'Fixture Shift H1', start: '00:00', end: '12:00', assignments: [{ machine: 'FX-MH1', supervisor: 'h2' }, { machine: 'FX-MH2', supervisor: 'h3' }] },
  { id: '54000000-0000-4000-a000-0000000000f2', tenant: 'e2e org H', name: 'Fixture Shift H2', start: '12:00', end: '00:00', assignments: [{ machine: 'FX-MH1', supervisor: 'h2' }, { machine: 'FX-MH2', supervisor: 'h3' }] },
];
export const FIXTURE_PLAN_FROM = '2026-01-01';
export const FIXTURE_COVER_REASON = 'Fixture reset';

export type PlanRow = { id: string; effective_from: string; supervisor_id: string | null; recorded_at: string };
export type CoverRow = { id: string; shift_date: string; supervisor_id: string | null; recorded_at: string };
const cmpDesc = (a: string, b: string): number => (a === b ? 0 : a < b ? 1 : -1);
const newest = <T extends { id: string; recorded_at: string }>(rows: T[], key: (r: T) => string): T | undefined =>
  [...rows].sort((a, b) => cmpDesc(key(a), key(b)) || cmpDesc(a.recorded_at, b.recorded_at) || cmpDesc(a.id, b.id))[0];

/**
 * The plan versions to APPEND so that, from FIXTURE_PLAN_FROM (and for every date an e2e run scheduled a change), the fixture supervisor
 * owns the machine again. History is append-only: nothing is deleted. Returns the effective dates to append at (sorted).
 */
export function planCorrections(rows: PlanRow[], supervisorId: string, today: string): string[] {
  const dates = new Set<string>([FIXTURE_PLAN_FROM, today]);
  for (const r of rows) if (r.effective_from > today) dates.add(r.effective_from);
  const out: string[] = [];
  for (const d of [...dates].sort()) {
    const winner = newest(rows.filter((r) => r.effective_from <= d), (r) => r.effective_from);
    if (!winner || winner.supervisor_id !== supervisorId) out.push(d);
  }
  return out;
}

/** Shift dates (from yesterday on, so a running overnight occurrence counts) whose latest cover names someone else than the fixture supervisor. */
export function coverCorrections(rows: CoverRow[], supervisorId: string, yesterday: string): string[] {
  const dates = new Set(rows.filter((r) => r.shift_date >= yesterday).map((r) => r.shift_date));
  const out: string[] = [];
  for (const d of [...dates].sort()) {
    const winner = newest(rows.filter((r) => r.shift_date === d), () => '');
    if (winner && winner.supervisor_id !== supervisorId) out.push(d);
  }
  return out;
}

// 07-issue-lifecycle (D12): fixture issues. Org U: a stopped-machine Critical (open), a High awaiting verification on the never-assigned FX-MU3
// (so a Unit Admin may verify it), and a closed Low. Org A: one open issue for supA. They are READ-ONLY for e2e (history is append-only and
// service_role has no UPDATE on machine_issue): tests create their own issues. Must match supabase/seed.sql (a Jest test checks it).
export type IssueFixture = {
  id: string;
  tenant: string;
  machine: string;
  priority: 'low' | 'medium' | 'high' | 'critical';
  status: 'open' | 'resolved' | 'closed';
  stopped: boolean;
  reporter: string; // USERS key; also the accountable owner (and the resolver when resolved/closed)
  description: string;
  reportedAt: string;
  resolvedAt?: string;
  resolution?: string;
};
export const ISSUES: IssueFixture[] = [
  { id: '60000000-0000-4000-a000-0000000000e1', tenant: 'e2e org U', machine: 'FX-MU1', priority: 'critical', status: 'open', stopped: true, reporter: 'u3',
    description: 'Fixture issue: hydraulic pump failed, machine stopped', reportedAt: '2026-01-02T08:00:00Z' },
  { id: '60000000-0000-4000-a000-0000000000e2', tenant: 'e2e org U', machine: 'FX-MU3', priority: 'high', status: 'resolved', stopped: false, reporter: 'u3',
    description: 'Fixture issue: mould cooling line leaking', reportedAt: '2026-01-02T08:30:00Z', resolvedAt: '2026-01-02T10:00:00Z', resolution: 'Fixture resolution: line re-sealed' },
  { id: '60000000-0000-4000-a000-0000000000e3', tenant: 'e2e org U', machine: 'FX-MU2', priority: 'low', status: 'closed', stopped: false, reporter: 'u3',
    description: 'Fixture issue: guard door sticks', reportedAt: '2026-01-02T09:00:00Z', resolvedAt: '2026-01-02T11:00:00Z', resolution: 'Fixture resolution: hinge oiled' },
  { id: '60000000-0000-4000-a000-0000000000a1', tenant: 'e2e org A', machine: 'FX-MA1', priority: 'medium', status: 'open', stopped: false, reporter: 'supA',
    description: 'Fixture issue: oil mist near the nozzle', reportedAt: '2026-01-02T08:00:00Z' },
  // 08: each is open on a machine one supervisor owns and was reported by the other, so it is inherited by the machine's owner at every handover.
  { id: '60000000-0000-4000-a000-0000000000f1', tenant: 'e2e org H', machine: 'FX-MH1', priority: 'high', status: 'open', stopped: false, reporter: 'h3',
    description: 'Fixture issue: spindle vibration on H1', reportedAt: '2026-01-02T08:00:00Z' },
  { id: '60000000-0000-4000-a000-0000000000f2', tenant: 'e2e org H', machine: 'FX-MH2', priority: 'medium', status: 'open', stopped: false, reporter: 'h2',
    description: 'Fixture issue: coolant drip on H2', reportedAt: '2026-01-02T08:30:00Z' },
];

/** Rows created by e2e tests carry this code/name prefix; fixtures-reset removes (or retires) them. */
export const isThrowawayPlantName = (name: string): boolean => /^E2E-[A-Za-z0-9]{3,16}$/.test(name);
const FIXTURE_TARGET_FROM = '2026-01-01';

// 06-shift-readings (D11): counter settings, cavities and two past occurrences (Morning shift, fixed date) with the summary numbers pinned by
// pgTAP 052. Inserted only when missing (readings and summaries are append-only). Must match supabase/seed.sql.
export const READINGS_DATE = '2026-11-10';
export const READINGS = {
  tenant: 'e2e org U',
  shiftId: '54000000-0000-4000-a000-0000000000e1',
  machines: [
    { code: 'FX-MU1', unit: 'shots' as const, max: null as number | null, cavities: { product: 'FX-PU1', count: 4 } },
    { code: 'FX-MU2', unit: 'pieces' as const, max: 999999, cavities: null as { product: string; count: number } | null },
  ],
  occurrences: [
    { machine: 'FX-MU1', product: 'FX-PU1', openingId: '56000000-0000-4000-a000-0000000000e1', closingId: '56000000-0000-4000-a000-0000000000e2', summaryId: '57000000-0000-4000-a000-0000000000e1',
      opening: 1000, closing: 1250, good: 950, reject: 30, target: 1200, cavities: 4, unit: 'shots' as const, max: null as number | null, movementUnits: 250, movementPieces: 1000, unaccounted: 20, attainment: 79.17, rollover: false },
    { machine: 'FX-MU2', product: 'FX-PU2', openingId: '56000000-0000-4000-a000-0000000000e3', closingId: '56000000-0000-4000-a000-0000000000e4', summaryId: '57000000-0000-4000-a000-0000000000e2',
      opening: 999900, closing: 100, good: 150, reject: 10, target: 800, cavities: 1, unit: 'pieces' as const, max: 999999 as number | null, movementUnits: 200, movementPieces: 200, unaccounted: 40, attainment: 18.75, rollover: true },
  ],
};


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
  // 08: org H (handover). Canonical block, unused elsewhere (the demo tenant uses 00010-00012).
  fx('h1', '+919000000015', 'Fixture Admin H1', 'FX-H1', 'e2e org H', 'unit_admin'),
  fx('h2', '+919000000016', 'Fixture Supervisor H2', 'FX-H2', 'e2e org H', 'supervisor'),
  fx('h3', '+919000000017', 'Fixture Supervisor H3', 'FX-H3', 'e2e org H', 'supervisor'),
];

/** 03: plan label per fixture tenant (default trial). */
export const TENANT_PLANS: Record<string, 'trial' | 'active'> = { 'e2e org A': 'active', 'e2e org U': 'active' };

/** 03: Platform Super Admins (not tenant members). Canonical block, same safety rules as USERS. */
export const SUPER_ADMINS: Fixture[] = [
  fx('sa1', '+919000000098', 'Fixture Super Admin 1', '', null),
  fx('sa2', '+919000000099', 'Fixture Super Admin 2', '', null),
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

const REF_RE = /^[a-z0-9]{20}$/;

/**
 * Allows exactly three targets: the local stack (APP_ENV=local), the configured dev project (APP_ENV=development, DEV_SUPABASE_PROJECT_REF)
 * and the configured staging project (APP_ENV=staging, STAGING_SUPABASE_PROJECT_REF; staging-setup D2). The prod project is refused in every
 * mode (D6); an empty PROD_SUPABASE_PROJECT_REF means "no prod yet". Messages never contain a URL or ref.
 */
export function assertSafeTarget(env: Record<string, string | undefined>, users: Fixture[] = USERS): void {
  const url = (env.SUPABASE_URL ?? '').replace(/\/$/, '');
  const appEnv = env.APP_ENV ?? '';
  if (!['local', 'development', 'staging'].includes(appEnv)) throw new Error(`Refusing: APP_ENV must be local, development or staging (got "${appEnv}")`);
  const dev = env.DEV_SUPABASE_PROJECT_REF ?? '';
  const staging = env.STAGING_SUPABASE_PROJECT_REF ?? '';
  const prod = env.PROD_SUPABASE_PROJECT_REF ?? '';
  if (prod && url === `https://${prod}.supabase.co`) throw new Error('Refusing: SUPABASE_URL is the prod project');
  if (dev && staging && dev === staging) throw new Error('Refusing: the dev and staging project refs are equal');
  for (const [name, ref] of [['dev', dev], ['staging', staging]] as const)
    if (prod && ref && ref === prod) throw new Error(`Refusing: the ${name} project ref equals the prod project ref`);
  const isLocal = appEnv !== 'staging' && /^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(url);
  const isDev = appEnv === 'development' && REF_RE.test(dev) && url === `https://${dev}.supabase.co`;
  const isStaging = appEnv === 'staging' && REF_RE.test(staging) && url === `https://${staging}.supabase.co`;
  if (!isLocal && !isDev && !isStaging) throw new Error(`Refusing: SUPABASE_URL is not the ${appEnv === 'staging' ? 'configured staging' : 'local or the configured dev'} project`);
  if (!users.every((u) => u.email.endsWith(`@${AUTH_DOMAIN}`))) throw new Error('Refusing: fixture email must use the reserved .invalid domain');
  if (!users.every((u) => isCanonicalPhone(u.phone))) throw new Error('Refusing: fixture phone outside the canonical block +91 90000 00001-00099');
  if (!users.every((u) => u.email === `${u.phone.slice(3)}@${AUTH_DOMAIN}`)) throw new Error('Refusing: fixture email does not match its phone');
}

type Admin = SupabaseClient;
const must = <T>(r: { data: T; error: { message: string } | null }): T => {
  if (r.error) throw new Error(r.error.message);
  return r.data;
};


/** True when any of the given tables (append-only history) still references the row: such rows are retired, never deleted. */
async function referenced(admin: Admin, refs: [string, string][], id: string): Promise<boolean> {
  for (const [table, column] of refs) {
    const r = must(await admin.from(table).select('id').eq(column, id).limit(1));
    if (r && r.length > 0) return true;
  }
  return false;
}

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
      const used = await referenced(admin, [['target_version', 'machine_id'], ['assignment_version', 'machine_id'], ['assignment_cover', 'machine_id'], ['target_override_version', 'machine_id'], ['machine_issue', 'machine_id']], m.id as string);
      if (used) {
        if (!m.retired_at) must(await admin.from('machine').update({ retired_at: new Date().toISOString() }).eq('id', m.id).select('id'));
      } else must(await admin.from('machine').delete().eq('id', m.id).select('id'));
    }
    const staleP = must(await admin.from('product').select('id, code, retired_at').eq('tenant_id', tenantId).like('code', 'E2E-%'));
    for (const p of staleP ?? []) {
      if (!isThrowawayPlantName(p.code as string)) continue;
      const used = await referenced(admin, [['target_version', 'product_id'], ['target_override_version', 'product_id']], p.id as string);
      if (used) {
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

const plantDate = (offsetDays = 0): string =>
  new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Kolkata' }).format(new Date(Date.now() + offsetDays * 86_400_000));

/**
 * Shift fixtures (05, D12). Shifts are matched by their fixed id and restored to their fixture name, times and active state. Plan versions and
 * covers are append-only, so a reset only appends versions that put the fixture supervisor back in charge (see planCorrections /
 * coverCorrections). Throwaway shifts (E2E-...) are deleted when nothing references them, otherwise retired.
 */
async function resetShifts(admin: Admin, tenantIds: Map<string, string>) {
  const today = plantDate();
  const yesterday = plantDate(-1);
  for (const fx of SHIFTS) {
    const tenantId = tenantIds.get(fx.tenant)!;
    const site = must(await admin.from('site').select('id').eq('tenant_id', tenantId).maybeSingle());
    if (!site) continue;
    const row = { id: fx.id, tenant_id: tenantId, site_id: site.id, name: fx.name, start_time: fx.start, end_time: fx.end, retired_at: null };
    // A throwaway shift with the fixture's name would block the unique name: retire it first (names are per site, case-insensitive).
    const clash = must(await admin.from('shift').select('id').eq('site_id', site.id).ilike('name', fx.name).neq('id', fx.id));
    for (const c of clash ?? []) must(await admin.from('shift').update({ name: `E2E-${String(c.id).slice(0, 8)}`, retired_at: new Date().toISOString() }).eq('id', c.id).select('id'));
    const found = must(await admin.from('shift').select('id').eq('id', fx.id).maybeSingle());
    if (found) must(await admin.from('shift').update(row).eq('id', fx.id).select('id'));
    else must(await admin.from('shift').insert(row).select('id'));

    for (const a of fx.assignments) {
      const supervisor = USERS.find((u) => u.key === a.supervisor)!;
      const sup = must(await admin.from('membership').select('user_id').eq('tenant_id', tenantId).eq('phone_e164', supervisor.phone).maybeSingle());
      const machine = must(await admin.from('machine').select('id').eq('tenant_id', tenantId).eq('code', a.machine).maybeSingle());
      const ua = must(await admin.from('membership').select('user_id').eq('tenant_id', tenantId).eq('role', 'unit_admin').limit(1));
      if (!sup || !machine || !ua?.length) continue;
      const recordedBy = ua[0].user_id as string;
      const plan = must(await admin.from('assignment_version').select('id, effective_from, supervisor_id, recorded_at').eq('shift_id', fx.id).eq('machine_id', machine.id));
      for (const d of planCorrections((plan ?? []) as PlanRow[], sup.user_id as string, today)) {
        must(await admin.from('assignment_version').insert({
          tenant_id: tenantId, shift_id: fx.id, machine_id: machine.id, supervisor_id: sup.user_id, effective_from: d, recorded_by: recordedBy,
        }).select('id'));
      }
      const covers = must(await admin.from('assignment_cover').select('id, shift_date, supervisor_id, recorded_at').eq('shift_id', fx.id).eq('machine_id', machine.id).gte('shift_date', yesterday));
      for (const d of coverCorrections((covers ?? []) as CoverRow[], sup.user_id as string, yesterday)) {
        must(await admin.from('assignment_cover').insert({
          tenant_id: tenantId, shift_id: fx.id, shift_date: d, machine_id: machine.id, supervisor_id: sup.user_id, reason: FIXTURE_COVER_REASON, recorded_by: recordedBy,
        }).select('id'));
      }
    }
  }

  // Throwaway shifts left by e2e runs.
  for (const tenantId of tenantIds.values()) {
    const stale = must(await admin.from('shift').select('id, name, retired_at').eq('tenant_id', tenantId).like('name', 'E2E-%'));
    for (const sh of stale ?? []) {
      if (!isThrowawayPlantName(sh.name as string)) continue;
      const used = (await Promise.all([['assignment_version', 'shift_id'], ['assignment_cover', 'shift_id'], ['target_override_version', 'shift_id'],
        ['machine_issue', 'reported_shift_id'], ['machine_issue', 'resolved_shift_id']].map(async ([t, c]) =>
        must(await admin.from(t).select('id').eq(c, sh.id).limit(1))))).some((r) => (r ?? []).length > 0);
      if (used) { if (!sh.retired_at) must(await admin.from('shift').update({ retired_at: new Date().toISOString() }).eq('id', sh.id).select('id')); }
      else must(await admin.from('shift').delete().eq('id', sh.id).select('id'));
    }
  }
}

/**
 * Issue fixtures (07, D12). Matched by fixed id and inserted only when missing (with their report/resolve actions and the ownership row): the issue
 * tables are append-only for service_role, so a reset never changes them. Throwaway categories (E2E-...) are deleted when no issue uses them,
 * otherwise retired. Throwaway issues created by e2e runs stay (history is append-only): known debt, like 04/05.
 */
/**
 * N-14: the "awaiting verification" fixture is consumed when someone verifies it (a Unit Admin may), and issues are append-only. When the seeded
 * one is no longer Resolved and no other Resolved copy exists, a new copy is inserted under a fresh id. Known debt: closed copies accumulate.
 */
export function needsFreshCopy(fx: IssueFixture, found: { status: string } | null, resolvedCopies: number): boolean {
  return fx.status === 'resolved' && found !== null && found.status !== 'resolved' && resolvedCopies === 0;
}

async function resetIssues(admin: Admin, tenantIds: Map<string, string>) {
  for (const base of ISSUES) {
    const tenantId = tenantIds.get(base.tenant)!;
    const found = must(await admin.from('machine_issue').select('id, status').eq('id', base.id).maybeSingle()) as { id: string; status: string } | null;
    let fx = base;
    if (found && base.status === 'resolved' && found.status !== 'resolved') {
      const copies = must(await admin.from('machine_issue').select('id').eq('tenant_id', tenantId).eq('description', base.description).eq('status', 'resolved')) ?? [];
      if (!needsFreshCopy(base, found, copies.length)) continue;
      fx = { ...base, id: crypto.randomUUID() };
    } else if (found) continue;
    const user = USERS.find((u) => u.key === fx.reporter)!;
    const sup = must(await admin.from('membership').select('user_id').eq('tenant_id', tenantId).eq('phone_e164', user.phone).maybeSingle());
    const machine = must(await admin.from('machine').select('id').eq('tenant_id', tenantId).eq('code', fx.machine).maybeSingle());
    const cat = must(await admin.from('issue_category').select('id').eq('tenant_id', tenantId).eq('name', 'Mechanical').maybeSingle());
    if (!sup || !machine || !cat) continue;
    const by = sup.user_id as string;
    const closed = fx.status === 'closed';
    must(await admin.from('machine_issue').insert({
      id: fx.id, tenant_id: tenantId, machine_id: machine.id, category_id: cat.id, priority: fx.priority, description: fx.description,
      machine_stopped: fx.stopped, status: fx.status, accountable_owner_id: by, reported_by: by, reported_at: fx.reportedAt,
      resolved_by: fx.resolvedAt ? by : null, resolved_at: fx.resolvedAt ?? null, resolution_notes: fx.resolution ?? null,
      closed_at: closed ? fx.resolvedAt : null, closed_by: closed ? by : null,
    }).select('id'));
    must(await admin.from('issue_action').insert({ tenant_id: tenantId, issue_id: fx.id, actor_id: by, actor_role: 'supervisor', type: 'report', status_after: 'open', at: fx.reportedAt }).select('id'));
    if (fx.resolvedAt) {
      must(await admin.from('issue_action').insert({
        tenant_id: tenantId, issue_id: fx.id, actor_id: by, actor_role: 'supervisor', type: 'resolve', notes: fx.resolution,
        status_before: 'open', status_after: fx.status, at: fx.resolvedAt,
      }).select('id'));
    }
    must(await admin.from('issue_ownership_history').insert({ tenant_id: tenantId, issue_id: fx.id, new_owner: by, source: 'report', actor_id: by, at: fx.reportedAt }).select('id'));
  }
  for (const tenantId of tenantIds.values()) {
    const stale = must(await admin.from('issue_category').select('id, name, retired_at').eq('tenant_id', tenantId).like('name', 'E2E-%'));
    for (const c of stale ?? []) {
      if (!isThrowawayPlantName(c.name as string)) continue;
      const used = must(await admin.from('machine_issue').select('id').eq('category_id', c.id).limit(1));
      if (used && used.length > 0) { if (!c.retired_at) must(await admin.from('issue_category').update({ retired_at: new Date().toISOString() }).eq('id', c.id).select('id')); }
      else must(await admin.from('issue_category').delete().eq('id', c.id).select('id'));
    }
  }
}

/** Reading fixtures (06, D11). Counter settings are restored; cavities, readings and summaries are append-only, so they are inserted only when missing. */
async function resetReadings(admin: Admin, tenantIds: Map<string, string>) {
  const tenantId = tenantIds.get(READINGS.tenant);
  if (!tenantId) return;
  const ua = must(await admin.from('membership').select('user_id').eq('tenant_id', tenantId).eq('role', 'unit_admin').limit(1));
  const sup = must(await admin.from('membership').select('user_id').eq('tenant_id', tenantId).eq('role', 'supervisor').eq('employee_id', 'FX-U3').maybeSingle());
  if (!ua?.length || !sup) return;
  const uaId = ua[0].user_id as string;
  const machineId = async (code: string) => (must(await admin.from('machine').select('id').eq('tenant_id', tenantId).eq('code', code).maybeSingle()))?.id as string | undefined;
  const productId = async (code: string) => (must(await admin.from('product').select('id').eq('tenant_id', tenantId).eq('code', code).maybeSingle()))?.id as string | undefined;

  for (const m of READINGS.machines) {
    const id = await machineId(m.code);
    if (!id) continue;
    const used = must(await admin.from('production_reading').select('id').eq('machine_id', id).limit(1));
    // The unit is locked once readings exist (they always do for these two), so it is only written before the first reading.
    must(await admin.from('machine').update(used && used.length > 0 ? { counter_max: m.max } : { counter_unit: m.unit, counter_max: m.max }).eq('id', id).select('id'));
    if (m.cavities) {
      const pid = await productId(m.cavities.product);
      const have = pid ? must(await admin.from('cavity_version').select('id').eq('machine_id', id).eq('product_id', pid).limit(1)) : [];
      if (pid && have && have.length === 0) {
        must(await admin.from('cavity_version').insert({ tenant_id: tenantId, machine_id: id, product_id: pid, effective_from: FIXTURE_TARGET_FROM, cavities: m.cavities.count, recorded_by: uaId }).select('id'));
      }
    }
  }
  for (const o of READINGS.occurrences) {
    const mid = await machineId(o.machine);
    const pid = await productId(o.product);
    if (!mid || !pid) continue;
    const key = { tenant_id: tenantId, machine_id: mid, shift_id: READINGS.shiftId, shift_date: READINGS_DATE };
    const recorded = (hhmm: string) => `${READINGS_DATE}T${hhmm}:00+05:30`;
    const has = async (table: string, id: string) => (must(await admin.from(table).select('id').eq('id', id).maybeSingle())) != null;
    if (!(await has('production_reading', o.openingId))) {
      must(await admin.from('production_reading').insert({ id: o.openingId, ...key, kind: 'opening', product_id: pid, counter_value: o.opening, late: false, recorded_by: sup.user_id, recorded_at: recorded('06:05') }).select('id'));
    }
    if (!(await has('production_reading', o.closingId))) {
      must(await admin.from('production_reading').insert({ id: o.closingId, ...key, kind: 'closing', counter_value: o.closing, good: o.good, reject: o.reject, late: false, counter_max: o.max, recorded_by: sup.user_id, recorded_at: recorded('14:05') }).select('id'));
    }
    if (!(await has('production_summary', o.summaryId))) {
      must(await admin.from('production_summary').insert({
        id: o.summaryId, ...key, calc_version: 1, product_id: pid, counter_unit: o.unit, cavities: o.cavities, counter_max: o.max,
        opening_reading_id: o.openingId, closing_reading_id: o.closingId, opening_counter: o.opening, closing_counter: o.closing, good: o.good, reject: o.reject,
        target: o.target, movement_units: o.movementUnits, movement_pieces: o.movementPieces, unaccounted: o.unaccounted, attainment_pct: o.attainment,
        rollover: o.rollover, needs_review: false, over_reported: false, late_opening: false, late_closing: false, entered_by_ua: false, recorded_by: sup.user_id, recorded_at: recorded('14:05'),
      }).select('id'));
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
  // 08: the enforced fixture tenant has its handover setting (the gate applies there); the row is the whole switch (D1).
  for (const name of HANDOVER_ENFORCED) {
    const { error } = await admin.from('handover_setting').upsert(
      { tenant_id: tenantIds.get(name)!, overdue_minutes: HANDOVER_OVERDUE_MINUTES, required: true },
      { onConflict: 'tenant_id', ignoreDuplicates: true },
    );
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

  // D16: close the throwaway issues earlier runs left open in the e2e orgs (through the RPCs, as a Unit Admin of each org), before their users are removed below.
  // Best effort: a failure here is logged and never stops the reset.
  const e2eTenants = must(await admin.from('tenant').select('id, name').ilike('name', 'e2e %').eq('status', 'active')) ?? [];
  for (const t of e2eTenants) {
    try {
      const ua = must(await admin.from('membership').select('phone_e164').eq('tenant_id', t.id).eq('role', 'unit_admin').eq('status', 'active').eq('must_change_password', false).limit(1).maybeSingle());
      if (!ua) continue;
      const res = await closeAsUnitAdmin(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, `${(ua.phone_e164 as string).slice(3)}@${AUTH_DOMAIN}`, password);
      if (res.closed || res.left) console.log(`throwaway issues in "${t.name}": closed ${res.closed}, left ${res.left}`);
    } catch (e) {
      console.warn(`throwaway issue clean-up skipped for "${t.name}": ${(e as Error).message}`);
    }
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
  await resetShifts(admin, tenantIds);
  await resetIssues(admin, tenantIds);
  await resetReadings(admin, tenantIds);
  // Super Admins: reuse the Auth user, reset password + unban, and put the platform_admin row in its canonical state.
  for (const f of SUPER_ADMINS) {
    let id = existing.get(f.email);
    if (id && !doomed.has(id)) {
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
    const o = (e ?? {}) as { message?: string; code?: string; details?: string; hint?: string; status?: number };
    // PostgREST/Auth errors are plain objects: print their fields (no secrets in them), never "[object Object]".
    console.error(`fixtures-reset failed: ${e instanceof Error ? e.message : [o.code, o.status, o.message, o.details, o.hint].filter(Boolean).join(' | ') || JSON.stringify(e)}`);
    process.exit(1);
  });
}
