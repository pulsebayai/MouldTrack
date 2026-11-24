/**
 * Deploy-target guard for deploy-staging.yml (staging-setup D3, D6). Run as the first step: `npx tsx scripts/deploy-target-guard.ts`.
 * Allows exactly one target: the project named by STAGING_SUPABASE_PROJECT_REF, deployed from main. The API URL and database URL must
 * belong to that project, and its ref must differ from the dev ref (required, must be set) and from the prod ref (an empty value = no prod yet).
 * Messages never contain a URL, host, ref, key or password.
 */
export type DeployEnv = Record<string, string | undefined>;

const REF_RE = /^[a-z0-9]{20}$/;
const refuse = (why: string): never => {
  throw new Error(`Refusing: ${why}`);
};
const parse = (v: string | undefined): URL | null => {
  try {
    return v ? new URL(v) : null;
  } catch {
    return null;
  }
};

export function assertDeployTarget(env: DeployEnv): { ref: string } {
  if (env.GITHUB_REF !== 'refs/heads/main') refuse('staging is deployed from main only');
  const ref = env.STAGING_SUPABASE_PROJECT_REF ?? '';
  if (!REF_RE.test(ref)) refuse('the staging project ref is not configured');
  const dev = env.DEV_SUPABASE_PROJECT_REF ?? '';
  if (!REF_RE.test(dev)) refuse('the dev project ref is not configured, so the staging target cannot be told apart from it');
  if (dev === ref) refuse('the staging project ref equals the dev project ref');
  const prod = env.PROD_SUPABASE_PROJECT_REF ?? ''; // empty = no prod project yet
  if (prod && prod === ref) refuse('the staging project ref equals the prod project ref');

  const api = parse(env.STAGING_SUPABASE_URL);
  if (api && (api.protocol !== 'https:' || api.hostname !== `${ref}.supabase.co`)) refuse('the API URL is not the staging project');
  if (env.STAGING_SUPABASE_URL && !api) refuse('the API URL is invalid');

  const db = parse(env.STAGING_SUPABASE_DB_URL);
  if (!db || !/^postgres(ql)?:$/.test(db.protocol)) return refuse('the database URL is missing or invalid');
  const pooler = db.username === `postgres.${ref}` && db.hostname.endsWith('.pooler.supabase.com');
  const direct = db.username === 'postgres' && db.hostname === `db.${ref}.supabase.co`;
  if (!pooler && !direct) refuse('the database URL is not the staging project');
  return { ref };
}

if (require.main === module) {
  try {
    assertDeployTarget(process.env);
    console.log('deploy target: staging project confirmed (main, ref differs from dev and prod)');
  } catch (e) {
    console.error((e as Error).message);
    process.exit(1);
  }
}
