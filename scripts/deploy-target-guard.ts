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

/**
 * Prod variant (r1-release-prep D4). Allows exactly the project named by PROD_SUPABASE_PROJECT_REF, deployed from main. Unlike staging, the
 * dev AND staging refs are both required and must differ from it; the API URL, database URL and web origin must belong to prod. The web origin
 * (PROD_WEB_ORIGIN, optional here: empty = taken from the deploy output later) may never be a dev or staging origin.
 */
export function assertProdDeployTarget(env: DeployEnv): { ref: string } {
  if (env.GITHUB_REF !== 'refs/heads/main') refuse('prod is deployed from main only');
  const ref = env.PROD_SUPABASE_PROJECT_REF ?? '';
  if (!REF_RE.test(ref)) refuse('the prod project ref is not configured');
  for (const [name, label] of [['DEV', 'dev'], ['STAGING', 'staging']] as const) {
    const other = env[`${name}_SUPABASE_PROJECT_REF`] ?? '';
    if (!REF_RE.test(other)) refuse(`the ${label} project ref is not configured, so the prod target cannot be told apart from it`);
    if (other === ref) refuse(`the prod project ref equals the ${label} project ref`);
  }
  const api = parse(env.PROD_SUPABASE_URL);
  if (!api || api.protocol !== 'https:' || api.hostname !== `${ref}.supabase.co`) refuse('the API URL is not the prod project');

  const db = parse(env.PROD_SUPABASE_DB_URL);
  if (!db || !/^postgres(ql)?:$/.test(db.protocol)) return refuse('the database URL is missing or invalid');
  const pooler = db.username === `postgres.${ref}` && db.hostname.endsWith('.pooler.supabase.com');
  const direct = db.username === 'postgres' && db.hostname === `db.${ref}.supabase.co`;
  if (!pooler && !direct) refuse('the database URL is not the prod project');

  if (env.PROD_WEB_ORIGIN) {
    const o = parse(env.PROD_WEB_ORIGIN);
    if (!o || o.protocol !== 'https:' || o.origin !== env.PROD_WEB_ORIGIN) refuse('the web origin is not a plain https origin');
    if (/^mouldtrack--(dev|staging)\./.test(o!.hostname)) refuse('the web origin is a dev or staging alias');
  }
  return { ref };
}

if (require.main === module) {
  try {
    if (process.env.DEPLOY_TARGET === 'prod') {
      assertProdDeployTarget(process.env);
      console.log('deploy target: prod project confirmed (main, ref differs from dev and staging)');
    } else {
      assertDeployTarget(process.env);
      console.log('deploy target: staging project confirmed (main, ref differs from dev and prod)');
    }
  } catch (e) {
    console.error((e as Error).message);
    process.exit(1);
  }
}
