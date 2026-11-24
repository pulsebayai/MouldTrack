import { readFileSync } from 'node:fs';
import { join } from 'node:path';

// Text checks (no YAML dependency) on the staging deploy workflow: the safety properties that must never regress.
const text = readFileSync(join(__dirname, '../../.github/workflows/deploy-staging.yml'), 'utf8');
const code = text.replace(/^\s*#.*$/gm, '');

describe('deploy-staging.yml (D3, D6)', () => {
  it('is manual only', () => {
    const on = code.slice(code.indexOf('\non:'), code.indexOf('\npermissions:'));
    expect(on).toContain('workflow_dispatch:');
    expect(on).not.toMatch(/push:|pull_request|schedule:|workflow_run/);
  });
  it('runs only on main and shares the staging-db group', () => {
    expect(code).toContain("if: github.ref == 'refs/heads/main'");
    expect(code).toMatch(/concurrency:\s+group: staging-db\s+cancel-in-progress: false/);
  });
  it('runs the deploy-target guard before anything that writes', () => {
    const guard = code.indexOf('deploy-target-guard.ts');
    expect(guard).toBeGreaterThan(0);
    for (const w of ['db push', 'functions deploy', 'secrets set', 'auth-config.mjs', '$EAS_CLI deploy', 'expo export']) expect(code.indexOf(w)).toBeGreaterThan(guard);
  });
  it('uses no dev or prod secret other than the refs the guard compares', () => {
    expect([...new Set(code.match(/secrets\.(DEV|PROD)_[A-Z_]+/g) ?? [])].sort()).toEqual(['secrets.DEV_SUPABASE_PROJECT_REF', 'secrets.PROD_SUPABASE_PROJECT_REF']);
  });
  it('targets staging in every write command', () => {
    expect(code).toContain('--db-url "$STAGING_SUPABASE_DB_URL"');
    expect(code).toContain('--project-ref "$STAGING_SUPABASE_PROJECT_REF"');
    expect(code).toContain('auth-config.mjs --apply --ref staging');
    expect(code).toContain('--alias staging');
    expect(code).not.toMatch(/--alias dev|--ref dev|DEV_SUPABASE_DB_URL|--project-ref "\$DEV/);
  });
  it('sets the staging CORS origin and checks the setup token', () => {
    expect(code).toContain('STAGING_WEB_ORIGIN: https://mouldtrack--staging.expo.app');
    expect(code).toContain('ALLOWED_ORIGINS="$STAGING_WEB_ORIGIN"');
    expect(code).toContain('PLATFORM_SETUP_TOKEN');
  });
  it('uses no GitHub environment (repo secrets)', () => expect(code).not.toMatch(/^\s+environment:/m));
});
