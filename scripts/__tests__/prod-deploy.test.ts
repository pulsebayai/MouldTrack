import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { assertProdDeployTarget } from '../deploy-target-guard';

const DEV = 'abcdefghijklmnopqrst';
const STG = 'bcdefghijklmnopqrstu';
const PRD = 'cdefghijklmnopqrstuv';
const ok = {
  GITHUB_REF: 'refs/heads/main',
  DEV_SUPABASE_PROJECT_REF: DEV,
  STAGING_SUPABASE_PROJECT_REF: STG,
  PROD_SUPABASE_PROJECT_REF: PRD,
  PROD_SUPABASE_URL: `https://${PRD}.supabase.co`,
  PROD_SUPABASE_DB_URL: `postgresql://postgres.${PRD}:p4ss@aws-0-ap-south-1.pooler.supabase.com:5432/postgres`,
  PROD_WEB_ORIGIN: 'https://mouldtrack.expo.app',
};

describe('prod deploy-target guard (D4)', () => {
  it('accepts main with the exact prod project', () => expect(assertProdDeployTarget(ok).ref).toBe(PRD));
  it('accepts a direct database host and an empty web origin', () => {
    expect(() => assertProdDeployTarget({ ...ok, PROD_SUPABASE_DB_URL: `postgresql://postgres:x@db.${PRD}.supabase.co:5432/postgres` })).not.toThrow();
    expect(() => assertProdDeployTarget({ ...ok, PROD_WEB_ORIGIN: '' })).not.toThrow();
  });
  const dbOf = (r: string) => `postgresql://postgres.${r}:p@h.pooler.supabase.com:5432/postgres`;
  it.each([
    ['a feature branch', { GITHUB_REF: 'refs/heads/chore/x' }],
    ['a pull request ref', { GITHUB_REF: 'refs/pull/1/merge' }],
    ['prod ref unset', { PROD_SUPABASE_PROJECT_REF: '' }],
    ['prod ref malformed', { PROD_SUPABASE_PROJECT_REF: 'nope' }],
    ['prod ref equals dev', { PROD_SUPABASE_PROJECT_REF: DEV, PROD_SUPABASE_URL: `https://${DEV}.supabase.co`, PROD_SUPABASE_DB_URL: dbOf(DEV) }],
    ['prod ref equals staging', { PROD_SUPABASE_PROJECT_REF: STG, PROD_SUPABASE_URL: `https://${STG}.supabase.co`, PROD_SUPABASE_DB_URL: dbOf(STG) }],
    ['dev ref unset', { DEV_SUPABASE_PROJECT_REF: '' }],
    ['staging ref unset', { STAGING_SUPABASE_PROJECT_REF: undefined }],
    ['API URL of staging', { PROD_SUPABASE_URL: `https://${STG}.supabase.co` }],
    ['API URL of dev', { PROD_SUPABASE_URL: `https://${DEV}.supabase.co` }],
    ['API URL missing', { PROD_SUPABASE_URL: '' }],
    ['API URL not https', { PROD_SUPABASE_URL: `http://${PRD}.supabase.co` }],
    ['database URL of staging', { PROD_SUPABASE_DB_URL: dbOf(STG) }],
    ['database URL of dev', { PROD_SUPABASE_DB_URL: dbOf(DEV) }],
    ['database URL missing', { PROD_SUPABASE_DB_URL: '' }],
    ['database URL not postgres', { PROD_SUPABASE_DB_URL: 'https://example.com' }],
    ['database host not Supabase', { PROD_SUPABASE_DB_URL: `postgresql://postgres.${PRD}:p@evil.example.com:5432/postgres` }],
    ['the staging web origin', { PROD_WEB_ORIGIN: 'https://mouldtrack--staging.expo.app' }],
    ['the dev web origin', { PROD_WEB_ORIGIN: 'https://mouldtrack--dev.expo.app' }],
    ['an http web origin', { PROD_WEB_ORIGIN: 'http://mouldtrack.expo.app' }],
    ['a web origin with a path', { PROD_WEB_ORIGIN: 'https://mouldtrack.expo.app/x' }],
  ])('refuses %s', (_n, patch) => expect(() => assertProdDeployTarget({ ...ok, ...patch })).toThrow(/Refusing/));
  it('never puts a URL, password or ref value into the message', () => {
    try {
      assertProdDeployTarget({ ...ok, PROD_SUPABASE_DB_URL: `postgresql://postgres.${DEV}:topsecret@h.pooler.supabase.com:5432/postgres` });
      throw new Error('should have refused');
    } catch (e) {
      for (const s of ['topsecret', DEV, STG, PRD, 'postgresql://']) expect((e as Error).message).not.toContain(s);
    }
  });
});

const read = (f: string) => readFileSync(join(__dirname, '../../.github/workflows', f), 'utf8');
const strip = (t: string) => t.replace(/^\s*#.*$/gm, '');

describe('deploy-prod.yml (D4)', () => {
  const code = strip(read('deploy-prod.yml'));
  it('is manual only, main only, behind the production environment, one writer', () => {
    const on = code.slice(code.indexOf('\non:'), code.indexOf('\npermissions:'));
    expect(on).toContain('workflow_dispatch:');
    expect(on).not.toMatch(/push:|pull_request|schedule:|workflow_run/);
    expect(code).toContain("if: github.ref == 'refs/heads/main'");
    expect(code).toMatch(/^\s+environment: production$/m);
    expect(code).toMatch(/concurrency:\s+group: prod-db\s+cancel-in-progress: false/);
  });
  it('runs the prod guard before anything that writes', () => {
    const guard = code.indexOf('deploy-target-guard.ts');
    expect(code).toContain('DEPLOY_TARGET: prod');
    expect(guard).toBeGreaterThan(0);
    for (const w of ['db push', 'functions deploy', 'secrets set', 'auth-config.mjs', '$EAS_CLI deploy', 'expo export']) expect(code.indexOf(w)).toBeGreaterThan(guard);
  });
  it('targets prod in every write command and never uses dev or staging secrets except the refs', () => {
    expect(code).toContain('--db-url "$PROD_SUPABASE_DB_URL"');
    expect(code).toContain('--project-ref "$PROD_SUPABASE_PROJECT_REF"');
    expect(code).toContain('auth-config.mjs --apply --ref prod');
    expect(code).toContain('deploy --non-interactive --export-dir dist --prod');
    expect(code).toContain('SUPABASE_ACCESS_TOKEN: ${{ secrets.PROD_SUPABASE_ACCESS_TOKEN }}');
    expect([...new Set(code.match(/secrets\.(DEV|STAGING)_[A-Z_]+/g) ?? [])].sort()).toEqual(['secrets.DEV_SUPABASE_PROJECT_REF', 'secrets.STAGING_SUPABASE_PROJECT_REF']);
    expect(code).not.toMatch(/--alias|--ref (dev|staging)|DEV_SUPABASE_DB_URL|STAGING_SUPABASE_DB_URL|secrets\.SUPABASE_ACCESS_TOKEN/);
  });
  it('never writes data: no fixtures, no reset, no tests, no regression', () => {
    expect(code).not.toMatch(/fixtures|dev-reset|dev:reset|playwright|maestro|jest|npm run test|supabase db reset|seed/i);
  });
  it('checks deep links and the setup token', () => {
    expect(code).toContain('for p in users plant issues readings console');
    expect(code).toContain('web-deep-links.ts dist');
    expect(code).toContain('PLATFORM_SETUP_TOKEN');
  });
});

describe('regression.yml target=prod stays smoke only and read-only (D4)', () => {
  const code = strip(read('regression.yml'));
  it('prod is not a full run', () => expect(code).toMatch(/prod\) def="[^"]+"; full=false ;;/));
  it('the web job runs only the smoke project when not full', () => expect(code).toContain('npx playwright test --project smoke'));
  const job = (n: string) => {
    const i = code.indexOf(`\n  ${n}:\n`);
    const rest = code.slice(i + 1);
    const m = rest.slice(rest.indexOf('\n') + 1).search(/\n  [a-z-]+:\n/);
    return m < 0 ? rest : rest.slice(0, rest.indexOf('\n') + 1 + m);
  };
  it('every job that writes data (drift, reset, fixtures, hosted-checks, android) is skipped on prod', () => {
    expect(job('drift')).toContain("target == 'dev'");
    expect(job('reset')).toContain("target == 'dev'");
    expect(job('fixtures')).toContain("target == 'staging'");
    expect(job('hosted-checks')).toContain("(needs.setup.outputs.target == 'dev' || needs.setup.outputs.target == 'staging')");
    expect(job('android')).toContain("needs.setup.outputs.full == 'true'");
  });
  it('the smoke spec only reads (GET requests, no sign-in, no form input)', () => {
    const spec = readFileSync(join(__dirname, '../../e2e/web/smoke.spec.ts'), 'utf8');
    expect(spec).not.toMatch(/\.(post|put|patch|delete)\(|signIn|\.fill\(|\.click\(|rpc|E2E_FIXTURE_PASSWORD|SERVICE_ROLE/i);
  });
  it('no API service-role or anon secret is passed for prod', () => {
    expect(code).not.toMatch(/secrets\.PROD_SUPABASE_(SERVICE_ROLE_KEY|DB_URL|ACCESS_TOKEN)/);
    expect(code).toContain("E2E_REQUIRE_API: ${{ (needs.setup.outputs.target == 'dev' || needs.setup.outputs.target == 'staging') && '1' || '' }}");
    expect(code).toContain("|| '' }}"); // prod resolves to an empty API url / anon key / service key
  });
});
