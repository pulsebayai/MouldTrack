import { readFileSync } from 'node:fs';
import { join } from 'node:path';

// Text checks on the staging branch of regression.yml and hosted-checks.sh (staging-setup D5, AC-4).
const read = (p: string) => readFileSync(join(__dirname, '../..', p), 'utf8');
const strip = (t: string) => t.replace(/^\s*#.*$/gm, '');
const wf = strip(read('.github/workflows/regression.yml'));
const job = (name: string) => {
  const start = wf.indexOf(`\n  ${name}:\n`);
  const next = wf.slice(start + 1).search(/\n  [a-z-]+:\n/);
  return wf.slice(start, next < 0 ? undefined : start + 1 + next);
};

describe('regression.yml target=staging', () => {
  it('uses the staging-db group for staging', () => expect(wf).toContain("inputs.target == 'staging' && 'staging-db'"));
  it('keeps drift and reset dev-only', () => {
    expect(job('drift')).toContain("target == 'dev'");
    expect(job('reset')).toContain("target == 'dev'");
    expect(job('reset')).not.toContain('STAGING');
  });
  it('resets fixtures on staging only, with the staging project and the guard refs', () => {
    const f = job('fixtures');
    expect(f).toContain("target == 'staging'");
    expect(f).toContain('APP_ENV: staging');
    for (const s of ['STAGING_SUPABASE_URL', 'STAGING_SUPABASE_SERVICE_ROLE_KEY', 'STAGING_SUPABASE_PROJECT_REF', 'PROD_SUPABASE_PROJECT_REF']) expect(f).toContain(s);
    expect(f).not.toMatch(/DEV_SUPABASE_(URL|SERVICE|DB)/);
    expect(f).not.toContain('dev:reset');
  });
  it('web and android wait for fixtures; hosted checks run for both targets', () => {
    for (const j of ['web', 'android', 'hosted-checks']) expect(job(j)).toMatch(/needs: \[[^\]]*fixtures/);
    expect(job('hosted-checks')).toContain("target == 'staging'");
  });
  it('never runs the dev reset or demo seed outside the dev-only job', () => {
    expect(wf.match(/dev:reset|dev-demo-seed|dev-reset/g)?.length).toBe(job('reset').match(/dev:reset|dev-demo-seed|dev-reset/g)?.length);
    expect(job('redeploy')).toContain("target == 'dev'");
  });
  it('the only prod secret passed anywhere is the prod ref', () =>
    expect([...new Set(wf.match(/secrets\.PROD_[A-Z_]+/g) ?? [])]).toEqual(['secrets.PROD_SUPABASE_PROJECT_REF']));
});

describe('hosted-checks.sh per target', () => {
  const sh = read('scripts/hosted-checks.sh');
  it('accepts dev and staging only, and checks the URL belongs to the target', () => {
    expect(sh).toContain('dev) REF=');
    expect(sh).toContain('staging) REF=');
    expect(sh).toContain('TARGET must be dev or staging');
    expect(sh).toContain('is not the $TARGET project');
    expect(sh).toContain('PROD_SUPABASE_PROJECT_REF');
  });
  it('has no hard-coded dev reference left in the checks', () => {
    const body = strip(sh);
    expect(body).not.toMatch(/--ref dev|\$DEV_SUPABASE_PROJECT_REF\}?\.supabase|--project-ref "\$DEV/);
  });
});
