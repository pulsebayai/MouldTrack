/**
 * Rebuilds hosted DEV (or the local CI stack) from the migration files, then recreates the canonical fixtures and the demo tenant
 * (dev-reset D1-D4, D9, D10). Order:
 *   1. guard: exactly the local stack or the configured dev project; real (non-fixture) identities on dev stop the run
 *   2. clear every object in Storage bucket `attachments` through the Storage API
 *   3. `supabase db reset --remote=<db url> --no-seed --yes` (applies supabase/migrations; no seed; never prompts)
 *   4. wait for the API to see the new schema, clear Storage again and delete every Auth user through the Auth admin API
 *      (whatever the CLI leaves behind in the system schemas is removed explicitly, so the result does not depend on the CLI's behaviour)
 *   5. `npm run fixtures:reset` (canonical fixtures) and the demo seed
 * Env: APP_ENV, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_DB_URL, E2E_FIXTURE_PASSWORD, DEV_SUPABASE_PROJECT_REF (dev only).
 * Never prints a URL, key or password. Edge Functions, function secrets and hosted Auth settings are not touched.
 */
import { spawnSync } from 'node:child_process';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { assertResetTarget, clearStorage, nonFixtureIdentities, redact } from './dev-guard';
import { seedDemo } from './dev-demo-seed';

export * from './dev-guard';

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function listAuthUsers(admin: SupabaseClient): Promise<{ id: string; email: string }[]> {
  const out: { id: string; email: string }[] = [];
  for (let page = 1; ; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 });
    if (error) throw new Error(`list Auth users failed: ${error.message}`);
    for (const u of data.users) out.push({ id: u.id, email: u.email ?? '' });
    if (data.users.length < 200) break;
  }
  return out;
}

/** PostgREST says PGRST205 (not in the schema cache) or Postgres 42P01 (undefined table) when the table does not exist, e.g. on a half-built dev. */
export const isMissingTable = (error: { code?: string; message?: string } | null): boolean =>
  !!error && (error.code === 'PGRST205' || error.code === '42P01' || /could not find the table|does not exist/i.test(error.message ?? ''));

/**
 * D4: real data on dev is a stop, never a wipe. Phones are read from membership and platform_admin; when one of those tables is missing
 * (a half-built or freshly dropped database) the Auth addresses alone are checked and that is logged. Any other read error refuses.
 */
export async function assertNoRealData(admin: SupabaseClient, log: (m: string) => void = console.log): Promise<void> {
  const users = await listAuthUsers(admin);
  const phones: string[] = [];
  for (const table of ['membership', 'platform_admin']) {
    const r = await admin.from(table).select('phone_e164');
    if (r.error) {
      if (isMissingTable(r.error)) {
        log(`dev-reset: table ${table} not found; checking the Auth addresses only`);
        continue;
      }
      throw new Error(`Refusing: cannot verify the identities in ${table}`);
    }
    for (const row of r.data ?? []) phones.push(row.phone_e164 as string);
  }
  const bad = nonFixtureIdentities(users.map((u) => u.email), phones);
  if (bad.length) throw new Error(`Refusing: ${bad.length} identity(ies) outside the fixture phone blocks (real data is never wiped), e.g. ${bad[0]}`);
}

function runSupabaseReset(env: NodeJS.ProcessEnv, dbUrl: string): void {
  // --remote=<url> is the supported spelling of the deprecated --db-url; stdin is closed so a prompt could never hang the run.
  const r = spawnSync('npx', ['supabase', 'db', 'reset', `--remote=${dbUrl}`, '--no-seed', '--yes'], {
    env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 10 * 60_000,
  });
  const out = redact(`${r.stdout ?? ''}${r.stderr ?? ''}`, env).trim();
  if (out) console.log(out.split('\n').map((l) => `  supabase: ${l}`).join('\n'));
  if (r.status !== 0) throw new Error(`supabase db reset failed (exit ${r.status ?? 'signal'})`);
}

/** Runs one SQL statement through psql (the same database URL as the CLI). Returns trimmed stdout, or null (and a redacted warning) on failure. */
function psql(env: NodeJS.ProcessEnv, dbUrl: string, sql: string): string | null {
  const r = spawnSync('psql', [dbUrl, '-v', 'ON_ERROR_STOP=1', '-qAt', '-c', sql], { env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 120_000 });
  if (r.status !== 0) {
    console.warn(`dev-reset: psql step skipped (${redact(`${r.stderr ?? r.error?.message ?? ''}`, env).trim().split('\n')[0] || 'psql unavailable'})`);
    return null;
  }
  return (r.stdout ?? '').trim();
}

async function waitForSchema(admin: SupabaseClient): Promise<void> {
  for (let i = 0; i < 40; i++) {
    const r = await admin.from('tenant').select('id', { count: 'exact', head: true });
    if (!r.error) return;
    await sleep(3000);
  }
  throw new Error('API did not see the migrated schema within 2 minutes');
}

async function main() {
  const target = assertResetTarget(process.env);
  const password = process.env.E2E_FIXTURE_PASSWORD;
  if (!password || password.length < 16) throw new Error('E2E_FIXTURE_PASSWORD missing or shorter than 16 chars');
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false, autoRefreshToken: false } });
  console.log(`dev-reset: target ${target.mode}`);

  await assertNoRealData(admin);
  console.log(`dev-reset: identities are fixtures only; removed ${await clearStorage(admin, 'attachments')} storage object(s) before the reset`);

  runSupabaseReset(process.env, target.dbUrl!);
  // N4: PostgREST must reload its schema cache for the freshly migrated database (best effort; waitForSchema is the real check).
  psql(process.env, target.dbUrl!, "NOTIFY pgrst, 'reload schema'");
  await waitForSchema(admin);

  const left = await clearStorage(admin, 'attachments');
  const users = await listAuthUsers(admin);
  for (const u of users) {
    const { error } = await admin.auth.admin.deleteUser(u.id);
    if (error) throw new Error(`delete Auth user failed: ${error.message}`);
  }
  console.log(`dev-reset: after the database reset ${users.length} Auth user(s) and ${left} storage object(s) were still present and were removed`);

  const fx = spawnSync('npx', ['tsx', 'scripts/fixtures-reset.ts'], { env: process.env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const fxOut = redact(`${fx.stdout ?? ''}${fx.stderr ?? ''}`, process.env).trim();
  if (fxOut) console.log(fxOut.split('\n').map((l) => `  fixtures: ${l}`).join('\n'));
  if (fx.status !== 0) throw new Error('fixtures-reset failed');

  await seedDemo(admin, password);

  // S6: GoTrue writes auth.audit_log_entries for every admin call above (and the hosted reset may keep older ones); dev holds fixtures only, so they are cleared.
  const cleared = psql(process.env, target.dbUrl!, 'with d as (delete from auth.audit_log_entries returning 1) select count(*) from d');
  if (cleared !== null) console.log(`dev-reset: cleared ${cleared} auth.audit_log_entries row(s)`);
  console.log('dev-reset: done (migrations + canonical fixtures + demo tenant)');
}

if (require.main === module) {
  main().catch((e) => {
    console.error(`dev-reset failed: ${redact(e instanceof Error ? e.message : String(e), process.env)}`);
    process.exit(1);
  });
}
