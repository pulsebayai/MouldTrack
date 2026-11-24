import { assertSafeTarget } from '../fixtures-reset';
import { assertResetTarget } from '../dev-reset';
import { assertDeployTarget } from '../deploy-target-guard';

const DEV = 'abcdefghijklmnopqrst';
const STG = 'bcdefghijklmnopqrstu';
const PRD = 'cdefghijklmnopqrstuv';
const stagingEnv = { APP_ENV: 'staging', STAGING_SUPABASE_PROJECT_REF: STG, SUPABASE_URL: `https://${STG}.supabase.co` };

describe('fixtures-reset staging mode (D2, D6)', () => {
  it('accepts the exact staging project', () => expect(() => assertSafeTarget(stagingEnv)).not.toThrow());
  it('accepts it with the other refs set and different', () =>
    expect(() => assertSafeTarget({ ...stagingEnv, DEV_SUPABASE_PROJECT_REF: DEV, PROD_SUPABASE_PROJECT_REF: PRD })).not.toThrow());
  it('treats an empty prod ref as "no prod yet"', () => expect(() => assertSafeTarget({ ...stagingEnv, PROD_SUPABASE_PROJECT_REF: '' })).not.toThrow());
  it('refuses when the staging ref is unset or malformed', () => {
    expect(() => assertSafeTarget({ ...stagingEnv, STAGING_SUPABASE_PROJECT_REF: '' })).toThrow(/Refusing/);
    expect(() => assertSafeTarget({ ...stagingEnv, STAGING_SUPABASE_PROJECT_REF: undefined })).toThrow(/Refusing/);
    expect(() => assertSafeTarget({ ...stagingEnv, STAGING_SUPABASE_PROJECT_REF: 'short' })).toThrow(/Refusing/);
  });
  it('refuses a URL that is not the staging project (dev, prod, other, local)', () => {
    for (const url of [`https://${DEV}.supabase.co`, `https://${PRD}.supabase.co`, 'https://zzzzzzzzzzzzzzzzzzzz.supabase.co', 'http://127.0.0.1:15321'])
      expect(() => assertSafeTarget({ ...stagingEnv, SUPABASE_URL: url })).toThrow(/Refusing/);
  });
  it('refuses when the staging ref equals the dev ref or the prod ref', () => {
    expect(() => assertSafeTarget({ ...stagingEnv, DEV_SUPABASE_PROJECT_REF: STG })).toThrow(/Refusing/);
    expect(() => assertSafeTarget({ ...stagingEnv, PROD_SUPABASE_PROJECT_REF: STG })).toThrow(/Refusing/);
  });
  it('refuses a dev-ref-only environment when APP_ENV=staging', () =>
    expect(() => assertSafeTarget({ APP_ENV: 'staging', DEV_SUPABASE_PROJECT_REF: DEV, SUPABASE_URL: `https://${DEV}.supabase.co` })).toThrow(/Refusing/));
  it('still refuses production and unknown APP_ENV', () => {
    expect(() => assertSafeTarget({ ...stagingEnv, APP_ENV: 'production' })).toThrow(/Refusing/);
    expect(() => assertSafeTarget({ ...stagingEnv, APP_ENV: '' })).toThrow(/Refusing/);
  });
});

describe('fixtures-reset refuses prod everywhere (D6)', () => {
  const dev = { APP_ENV: 'development', DEV_SUPABASE_PROJECT_REF: DEV, SUPABASE_URL: `https://${DEV}.supabase.co` };
  it('refuses a dev run whose URL is the prod project', () =>
    expect(() => assertSafeTarget({ ...dev, DEV_SUPABASE_PROJECT_REF: PRD, SUPABASE_URL: `https://${PRD}.supabase.co`, PROD_SUPABASE_PROJECT_REF: PRD })).toThrow(/Refusing/));
  it('refuses a dev ref that equals the staging ref', () =>
    expect(() => assertSafeTarget({ ...dev, STAGING_SUPABASE_PROJECT_REF: DEV })).toThrow(/Refusing/));
  it('refuses a local run pointed at prod', () =>
    expect(() => assertSafeTarget({ APP_ENV: 'local', SUPABASE_URL: `https://${PRD}.supabase.co`, PROD_SUPABASE_PROJECT_REF: PRD })).toThrow(/Refusing/));
  it('still allows dev with the other refs different or empty', () => {
    expect(() => assertSafeTarget({ ...dev, STAGING_SUPABASE_PROJECT_REF: STG, PROD_SUPABASE_PROJECT_REF: PRD })).not.toThrow();
    expect(() => assertSafeTarget({ ...dev, PROD_SUPABASE_PROJECT_REF: '' })).not.toThrow();
  });
});

describe('dev-reset and the demo seed stay dev-only (AC-4)', () => {
  const base = {
    SUPABASE_SERVICE_ROLE_KEY: 'service-role-key-secret-value-0123456789',
    SUPABASE_URL: `https://${STG}.supabase.co`,
    SUPABASE_DB_URL: `postgresql://postgres.${STG}:p4ss@aws-0-ap-south-1.pooler.supabase.com:5432/postgres`,
  };
  it('refuses APP_ENV=staging', () =>
    expect(() => assertResetTarget({ ...base, APP_ENV: 'staging', STAGING_SUPABASE_PROJECT_REF: STG })).toThrow(/Refusing/));
  it('refuses the staging project even as "development"', () =>
    expect(() => assertResetTarget({ ...base, APP_ENV: 'development', DEV_SUPABASE_PROJECT_REF: DEV })).toThrow(/Refusing/));
  it('refuses a dev ref equal to the staging ref', () =>
    expect(() => assertResetTarget({ ...base, APP_ENV: 'development', DEV_SUPABASE_PROJECT_REF: STG, STAGING_SUPABASE_PROJECT_REF: STG })).toThrow(/Refusing/));
  it('refuses a dev ref equal to the prod ref', () =>
    expect(() => assertResetTarget({ ...base, APP_ENV: 'development', DEV_SUPABASE_PROJECT_REF: STG, PROD_SUPABASE_PROJECT_REF: STG })).toThrow(/Refusing/));
});

describe('deploy-target guard (D3, D6)', () => {
  const ok = {
    GITHUB_REF: 'refs/heads/main',
    STAGING_SUPABASE_PROJECT_REF: STG,
    DEV_SUPABASE_PROJECT_REF: DEV,
    PROD_SUPABASE_PROJECT_REF: PRD,
    STAGING_SUPABASE_URL: `https://${STG}.supabase.co`,
    STAGING_SUPABASE_DB_URL: `postgresql://postgres.${STG}:p4ss@aws-0-ap-south-1.pooler.supabase.com:5432/postgres`,
  };
  it('accepts main with the exact staging project', () => expect(assertDeployTarget(ok).ref).toBe(STG));
  it('treats an empty prod ref as "no prod yet"', () => expect(() => assertDeployTarget({ ...ok, PROD_SUPABASE_PROJECT_REF: '' })).not.toThrow());
  it('accepts a direct database host of the staging project', () =>
    expect(() => assertDeployTarget({ ...ok, STAGING_SUPABASE_DB_URL: `postgresql://postgres:x@db.${STG}.supabase.co:5432/postgres` })).not.toThrow());
  it.each([
    ['a feature branch', { GITHUB_REF: 'refs/heads/chore/x' }],
    ['a pull request ref', { GITHUB_REF: 'refs/pull/1/merge' }],
    ['no ref', { GITHUB_REF: undefined }],
    ['staging ref unset', { STAGING_SUPABASE_PROJECT_REF: '' }],
    ['staging ref malformed', { STAGING_SUPABASE_PROJECT_REF: 'nope' }],
    ['staging ref equals dev', { STAGING_SUPABASE_PROJECT_REF: DEV, STAGING_SUPABASE_URL: `https://${DEV}.supabase.co`, STAGING_SUPABASE_DB_URL: `postgresql://postgres.${DEV}:p@h.pooler.supabase.com:5432/postgres` }],
    ['staging ref equals prod', { PROD_SUPABASE_PROJECT_REF: STG }],
    ['dev ref unset', { DEV_SUPABASE_PROJECT_REF: '' }],
    ['dev ref missing', { DEV_SUPABASE_PROJECT_REF: undefined }],
    ['API URL of another project', { STAGING_SUPABASE_URL: `https://${DEV}.supabase.co` }],
    ['API URL of prod', { STAGING_SUPABASE_URL: `https://${PRD}.supabase.co` }],
    ['database URL of another project', { STAGING_SUPABASE_DB_URL: `postgresql://postgres.${DEV}:p@h.pooler.supabase.com:5432/postgres` }],
    ['database URL of prod', { STAGING_SUPABASE_DB_URL: `postgresql://postgres.${PRD}:p@h.pooler.supabase.com:5432/postgres` }],
    ['database URL missing', { STAGING_SUPABASE_DB_URL: '' }],
    ['database URL not a postgres URL', { STAGING_SUPABASE_DB_URL: 'https://example.com' }],
    ['database host not Supabase', { STAGING_SUPABASE_DB_URL: `postgresql://postgres.${STG}:p@evil.example.com:5432/postgres` }],
  ])('refuses %s', (_n, patch) => expect(() => assertDeployTarget({ ...ok, ...patch })).toThrow(/Refusing/));
  it('never puts a URL, password or ref value into the message', () => {
    try {
      assertDeployTarget({ ...ok, STAGING_SUPABASE_DB_URL: `postgresql://postgres.${DEV}:topsecret@h.pooler.supabase.com:5432/postgres` });
      throw new Error('should have refused');
    } catch (e) {
      const m = (e as Error).message;
      for (const s of ['topsecret', DEV, STG, PRD, 'postgresql://']) expect(m).not.toContain(s);
    }
  });
});
