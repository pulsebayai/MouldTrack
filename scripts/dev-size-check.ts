/**
 * Growth check (dev-reset D5): after `dev-reset` (reset + fixtures + demo tenant) the database, Auth and Storage must hold EXACTLY what one
 * run creates. Any other count means data accumulated (or a reset step was skipped) and fails the run, so growth cannot come back silently.
 * The baseline is computed from the fixture lists in fixtures-reset.ts and from the demo specification (dev-demo-spec.ts), not typed twice.
 *
 * Env (same guard as dev-reset): APP_ENV, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, DEV_SUPABASE_PROJECT_REF (hosted).
 * Prints one `name=count` line per counter (stable order) so two runs can be diffed.
 */
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { ISSUES, PLANT, READINGS, SHIFTS, SUPER_ADMINS, TENANTS, USERS } from './fixtures-reset';
import { demoCounts, plantToday } from './dev-demo-spec';
import { assertResetTarget, countStorageObjects, redact } from './dev-guard';

export const COUNT_KEYS = [
  'tenant', 'site', 'line', 'machine', 'product', 'target_version', 'cavity_version', 'shift', 'assignment_version', 'assignment_cover',
  'target_override_version', 'production_reading', 'production_summary', 'machine_issue', 'issue_action', 'issue_ownership_history',
  'issue_category', 'attachment', 'audit_event', 'membership', 'platform_admin', 'auth_users', 'storage_objects',
] as const;
export type CountKey = (typeof COUNT_KEYS)[number];
export type Counts = Record<CountKey, number>;

/** Starter issue categories seeded for every tenant by the tenant trigger (07). */
const STARTER_CATEGORIES = 7;
/**
 * Audit events a reset + fixtures + demo seed leaves behind. They are written only by RPC/Edge paths, which none of the three use, so the
 * expected value is 0; CI (reset-roundtrip) fails if that is ever wrong.
 */
const AUDIT_EVENTS_AFTER_RESET = 0;

/**
 * Tables and views the API exposes that are deliberately NOT counted (reference or derived data that a run cannot grow). Every other
 * public-exposed relation must be in COUNT_KEYS, so a feature that adds a table (08's shift_handover, ...) fails this check until it is counted.
 */
export const IGNORED_RELATIONS: string[] = [
  'current_target', // view over target_version (the current target per machine and product): no rows of its own; the hosted API lists it, the local one does not
  'plant_today', // view returning today's plant date: one row, never grows
];

/** Relations named by the paths of PostgREST's OpenAPI root (`/table`; `/rpc/...` and the root itself are not relations) that are neither counted nor ignored. */
export function unlistedRelations(paths: string[]): string[] {
  const counted = new Set<string>(COUNT_KEYS.filter((k) => k !== 'auth_users' && k !== 'storage_objects'));
  const ignored = new Set(IGNORED_RELATIONS);
  return paths
    .filter((p) => p !== '/' && !p.startsWith('/rpc/'))
    .map((p) => p.slice(1))
    .filter((name) => !counted.has(name) && !ignored.has(name))
    .sort();
}

async function openApiPaths(): Promise<string[] | null> {
  try {
    const key = process.env.SUPABASE_SERVICE_ROLE_KEY!;
    const res = await fetch(`${process.env.SUPABASE_URL}/rest/v1/`, { headers: { apikey: key, Authorization: `Bearer ${key}`, Accept: 'application/openapi+json' } });
    if (!res.ok) return null;
    const body = (await res.json()) as { paths?: Record<string, unknown> };
    return body.paths ? Object.keys(body.paths) : null;
  } catch {
    return null;
  }
}

export function expectedCounts(today: string): Counts {
  const d = demoCounts(today);
  const sum = <T>(xs: T[], f: (x: T) => number) => xs.reduce((n, x) => n + f(x), 0);
  const tenants = TENANTS.length + d.tenant;
  return {
    tenant: tenants,
    site: PLANT.length + d.site,
    line: sum(PLANT, (p) => p.lines.length) + d.line,
    machine: sum(PLANT, (p) => p.machines.length) + d.machine,
    product: sum(PLANT, (p) => p.products.length) + d.product,
    target_version: sum(PLANT, (p) => p.targets.length) + d.target_version,
    cavity_version: READINGS.machines.filter((x) => x.cavities).length + d.cavity_version,
    shift: SHIFTS.length + d.shift,
    // On an empty database fixtures-reset appends two plan versions per assignment (the fixture date and today); the demo plan is one version each.
    assignment_version: sum(SHIFTS, (s) => s.assignments.length) * 2 + d.assignment_version,
    assignment_cover: 0,
    target_override_version: 0,
    production_reading: READINGS.occurrences.length * 2 + d.production_reading,
    production_summary: READINGS.occurrences.length + d.production_summary,
    machine_issue: ISSUES.length + d.machine_issue,
    issue_action: sum(ISSUES, (i) => 1 + (i.resolvedAt ? 1 : 0)) + d.issue_action,
    issue_ownership_history: ISSUES.length + d.issue_ownership_history,
    issue_category: tenants * STARTER_CATEGORIES,
    attachment: 0,
    audit_event: AUDIT_EVENTS_AFTER_RESET,
    membership: USERS.filter((u) => u.tenant).length + d.membership,
    platform_admin: SUPER_ADMINS.length,
    auth_users: USERS.length + SUPER_ADMINS.length + d.authUsers,
    storage_objects: 0,
  };
}

export function formatCounts(c: Partial<Counts>): string {
  return COUNT_KEYS.map((k) => `${k}=${c[k] ?? 'unreadable'}`).join('\n');
}

/** One readable line per mismatch; empty when the counts equal the baseline. */
export function diffCounts(actual: Partial<Counts>, expected: Counts): string[] {
  const out: string[] = [];
  for (const k of COUNT_KEYS) {
    const a = actual[k];
    if (a === undefined) out.push(`${k}: expected ${expected[k]}, got unreadable`);
    else if (a !== expected[k]) out.push(`${k}: expected ${expected[k]}, got ${a}`);
  }
  return out;
}

export async function collectCounts(admin: SupabaseClient): Promise<Partial<Counts>> {
  const out: Partial<Counts> = {};
  const tables = COUNT_KEYS.filter((k) => k !== 'auth_users' && k !== 'storage_objects');
  for (const t of tables) {
    const r = await admin.from(t).select('*', { count: 'exact', head: true });
    if (!r.error && r.count !== null) out[t] = r.count;
  }
  let users = 0;
  for (let page = 1; ; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 });
    if (error) { users = -1; break; }
    users += data.users.length;
    if (data.users.length < 200) break;
  }
  if (users >= 0) out.auth_users = users;
  const objects = await countStorageObjects(admin, 'attachments');
  if (objects !== null) out.storage_objects = objects;
  return out;
}

async function main() {
  assertResetTarget(process.env, { needDb: false });
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false, autoRefreshToken: false } });
  const actual = await collectCounts(admin);
  const expected = expectedCounts(plantToday());
  const { data: bucket } = await admin.storage.getBucket('attachments');
  console.log(formatCounts(actual));
  const diff = diffCounts(actual, expected);
  if (!bucket) diff.push('storage bucket "attachments": missing');
  const paths = await openApiPaths();
  if (!paths) diff.push('API schema (OpenAPI root) could not be read, so new tables cannot be checked');
  else for (const name of unlistedRelations(paths)) diff.push(`public relation "${name}" is exposed by the API but neither counted (COUNT_KEYS) nor in IGNORED_RELATIONS`);
  if (diff.length) {
    console.error('dev size check FAILED (data differs from the one-run baseline):');
    for (const line of diff) console.error(`  ${line}`);
    process.exit(1);
  }
  console.error('dev size check ok: counts equal the one-run baseline; bucket "attachments" present');
}

if (require.main === module) {
  main().catch((e) => {
    console.error(`dev-size-check failed: ${redact(e instanceof Error ? e.message : String(e), process.env)}`);
    process.exit(1);
  });
}
