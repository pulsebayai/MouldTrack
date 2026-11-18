/**
 * Shared safety code for dev-reset, dev-size-check and the demo seed (dev-reset D4). Pure functions and small Storage helpers.
 * Messages never contain a URL, host, key or password.
 */
import type { SupabaseClient } from '@supabase/supabase-js';
import { LEGACY_EMAILS, isCanonicalPhone } from './fixtures-reset';

export type ResetEnv = Record<string, string | undefined>;
export type ResetTarget = { mode: 'local' | 'dev'; supabaseUrl: string; dbUrl: string | null };

const LOCAL_HOSTS = new Set(['127.0.0.1', 'localhost']);
// 0.0.0.0 reaches the same local Postgres on Linux, and makes the Supabase CLI take its remote-database code path (the one hosted dev uses): CI proves both.
const LOCAL_DB_HOSTS = new Set([...LOCAL_HOSTS, '0.0.0.0']);
const refuse = (why: string): never => {
  throw new Error(`Refusing: ${why}`);
};
const parse = (value: string | undefined): URL | null => {
  try {
    return value ? new URL(value) : null;
  } catch {
    return null;
  }
};

/**
 * Allows exactly two targets: the local stack (APP_ENV=local, loopback URLs only) or the configured dev project (APP_ENV=development,
 * DEV_SUPABASE_PROJECT_REF set, API URL host == <ref>.supabase.co, database user or host naming the same ref). Anything else is refused.
 */
export function assertResetTarget(env: ResetEnv, opts: { needDb?: boolean } = {}): ResetTarget {
  const needDb = opts.needDb ?? true;
  const appEnv = env.APP_ENV ?? '';
  if (appEnv !== 'local' && appEnv !== 'development') refuse('APP_ENV must be local or development');
  if (!env.SUPABASE_SERVICE_ROLE_KEY) refuse('the service-role key is not set');
  const url = parse(env.SUPABASE_URL);
  if (!url) return refuse('the API URL is missing or invalid');
  const db = needDb ? parse(env.SUPABASE_DB_URL) : null;
  if (needDb && (!db || !/^postgres(ql)?:$/.test(db.protocol))) refuse('the database URL is missing or invalid');

  if (appEnv === 'local') {
    if (url.protocol !== 'http:' || !LOCAL_HOSTS.has(url.hostname)) refuse('local mode requires a loopback API URL');
    if (db && !LOCAL_DB_HOSTS.has(db.hostname)) refuse('local mode requires a loopback database URL');
    return { mode: 'local', supabaseUrl: url.origin, dbUrl: db ? env.SUPABASE_DB_URL! : null };
  }
  const ref = env.DEV_SUPABASE_PROJECT_REF ?? '';
  if (!/^[a-z0-9]{20}$/.test(ref)) refuse('the dev project ref is not configured');
  if (url.protocol !== 'https:' || url.hostname !== `${ref}.supabase.co`) refuse('the API URL is not the configured dev project');
  if (db && db.username !== `postgres.${ref}` && db.hostname !== `db.${ref}.supabase.co`) refuse('the database URL is not the configured dev project');
  return { mode: 'dev', supabaseUrl: url.origin, dbUrl: db ? env.SUPABASE_DB_URL! : null };
}

/** Fixture phone blocks: canonical +91 90000 00001-00099 and throwaway +91 90000 10000-99999. */
export const isFixturePhone = (phone: string): boolean => isCanonicalPhone(phone) || /^\+9190000[1-9][0-9]{4}$/.test(phone);

const maskPhone = (p: string): string => `phone ******${p.slice(-4)}`;

/** Identities that are not fixtures, described without revealing them. Real data on dev is a stop, never a wipe. */
export function nonFixtureIdentities(authEmails: string[], phones: string[]): string[] {
  const out: string[] = [];
  for (const email of authEmails) {
    if (LEGACY_EMAILS.includes(email)) continue;
    const m = /^(\d{10})@phone\.mouldtrack\.invalid$/.exec(email);
    if (m) {
      if (!isFixturePhone(`+91${m[1]}`)) out.push(`auth user with ${maskPhone(`+91${m[1]}`)}`);
    } else out.push('auth user with a non-fixture address');
  }
  for (const p of phones) if (!isFixturePhone(p)) out.push(maskPhone(p));
  return out;
}

/** Removes anything secret-looking from text that is about to be printed. */
export function redact(text: string, env: ResetEnv): string {
  let out = text;
  for (const k of ['SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_DB_URL', 'SUPABASE_URL', 'E2E_FIXTURE_PASSWORD', 'DEV_SUPABASE_PROJECT_REF']) {
    const v = env[k];
    if (v && v.length >= 8) out = out.split(v).join('<redacted>');
  }
  return out
    .replace(/postgres(ql)?:\/\/\S+/g, '<redacted-db-url>')
    .replace(/[a-z0-9]{20}\.supabase\.co/g, '<redacted-host>')
    .replace(/Bearer\s+\S+/g, 'Bearer <redacted>')
    .replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g, '<redacted-jwt>');
}

// ---- Storage helpers (service role) ----
async function listFiles(admin: SupabaseClient, bucket: string, prefix: string, out: string[]): Promise<void> {
  for (let offset = 0; ; offset += 1000) {
    const { data, error } = await admin.storage.from(bucket).list(prefix, { limit: 1000, offset });
    if (error) throw new Error(`storage list failed: ${error.message}`);
    for (const e of data ?? []) {
      const path = prefix ? `${prefix}/${e.name}` : e.name;
      if (e.id === null) await listFiles(admin, bucket, path, out); // a folder
      else out.push(path);
    }
    if ((data ?? []).length < 1000) break;
  }
}

/** Number of objects in a bucket, or null when the bucket cannot be read (missing). */
export async function countStorageObjects(admin: SupabaseClient, bucket: string): Promise<number | null> {
  try {
    const files: string[] = [];
    await listFiles(admin, bucket, '', files);
    return files.length;
  } catch {
    return null;
  }
}

/** Deletes every object in the bucket through the Storage API (the bucket itself stays). Returns how many were removed. */
export async function clearStorage(admin: SupabaseClient, bucket: string): Promise<number> {
  const files: string[] = [];
  try {
    await listFiles(admin, bucket, '', files);
  } catch (e) {
    if (/not found/i.test((e as Error).message)) return 0; // bucket row absent (e.g. right after a database reset)
    throw e;
  }
  for (let i = 0; i < files.length; i += 100) {
    const { error } = await admin.storage.from(bucket).remove(files.slice(i, i + 100));
    if (error) throw new Error(`storage remove failed: ${error.message}`);
  }
  return files.length;
}
