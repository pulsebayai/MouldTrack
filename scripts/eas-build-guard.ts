/**
 * Guard for build-android-eas.yml (r1-release-prep D1). Run before any EAS variable is written:
 * `EAS_PROFILE=preview|production npx tsx scripts/eas-build-guard.ts`.
 * `preview` must carry the staging Supabase URL and `production` the prod one, so a phone can never be built against the wrong backend.
 * Messages never contain a URL, ref or key.
 */
export type BuildEnv = Record<string, string | undefined>;

const REF_RE = /^[a-z0-9]{20}$/;
const refuse = (why: string): never => {
  throw new Error(`Refusing: ${why}`);
};

export function assertBuildTarget(env: BuildEnv): { profile: 'preview' | 'production'; ref: string } {
  if (env.GITHUB_REF !== 'refs/heads/main') refuse('EAS builds run from main only');
  const profile = env.EAS_PROFILE;
  if (profile !== 'preview' && profile !== 'production') return refuse('the profile must be preview or production');
  const want = profile === 'preview' ? 'STAGING' : 'PROD';
  const ref = env[`${want}_SUPABASE_PROJECT_REF`] ?? '';
  if (!REF_RE.test(ref)) refuse(`the ${want.toLowerCase()} project ref is not configured`);
  const others = ['DEV', profile === 'preview' ? 'PROD' : 'STAGING'];
  const dev = env.DEV_SUPABASE_PROJECT_REF ?? '';
  if (!REF_RE.test(dev)) refuse('the dev project ref is not configured, so the target cannot be told apart from it');
  for (const o of others) if (env[`${o}_SUPABASE_PROJECT_REF`] === ref) refuse(`the ${want.toLowerCase()} project ref equals the ${o.toLowerCase()} project ref`);

  let url: URL | null = null;
  try {
    url = env.SUPABASE_URL ? new URL(env.SUPABASE_URL) : null;
  } catch {
    url = null;
  }
  if (!url || url.protocol !== 'https:' || url.hostname !== `${ref}.supabase.co`) refuse(`the API URL is not the ${want.toLowerCase()} project`);
  if (!env.SUPABASE_ANON_KEY) refuse('the anon key is missing');
  return { profile, ref };
}

if (require.main === module) {
  try {
    const r = assertBuildTarget(process.env);
    console.log(`EAS build target confirmed: profile ${r.profile} (main, API URL is the matching project)`);
  } catch (e) {
    console.error((e as Error).message);
    process.exit(1);
  }
}
