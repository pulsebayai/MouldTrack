import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { assertBuildTarget } from '../eas-build-guard';

const DEV = 'abcdefghijklmnopqrst';
const STG = 'bcdefghijklmnopqrstu';
const PRD = 'cdefghijklmnopqrstuv';
const base = { GITHUB_REF: 'refs/heads/main', DEV_SUPABASE_PROJECT_REF: DEV, STAGING_SUPABASE_PROJECT_REF: STG, PROD_SUPABASE_PROJECT_REF: PRD, SUPABASE_ANON_KEY: 'anon' };
const preview = { ...base, EAS_PROFILE: 'preview', SUPABASE_URL: `https://${STG}.supabase.co` };
const prod = { ...base, EAS_PROFILE: 'production', SUPABASE_URL: `https://${PRD}.supabase.co` };

describe('eas build guard (D1)', () => {
  it('accepts preview with the staging URL and production with the prod URL', () => {
    expect(assertBuildTarget(preview)).toEqual({ profile: 'preview', ref: STG });
    expect(assertBuildTarget(prod)).toEqual({ profile: 'production', ref: PRD });
  });
  it.each([
    ['a feature branch', { ...preview, GITHUB_REF: 'refs/heads/x' }],
    ['no profile', { ...preview, EAS_PROFILE: '' }],
    ['the development profile', { ...preview, EAS_PROFILE: 'development' }],
    ['preview with the prod URL', { ...preview, SUPABASE_URL: `https://${PRD}.supabase.co` }],
    ['preview with the dev URL', { ...preview, SUPABASE_URL: `https://${DEV}.supabase.co` }],
    ['production with the staging URL', { ...prod, SUPABASE_URL: `https://${STG}.supabase.co` }],
    ['production with an http URL', { ...prod, SUPABASE_URL: `http://${PRD}.supabase.co` }],
    ['production with no URL', { ...prod, SUPABASE_URL: '' }],
    ['production with an invalid URL', { ...prod, SUPABASE_URL: 'nope' }],
    ['production ref unset', { ...prod, PROD_SUPABASE_PROJECT_REF: '' }],
    ['production ref equals staging', { ...prod, PROD_SUPABASE_PROJECT_REF: STG, SUPABASE_URL: `https://${STG}.supabase.co` }],
    ['production ref equals dev', { ...prod, PROD_SUPABASE_PROJECT_REF: DEV, SUPABASE_URL: `https://${DEV}.supabase.co` }],
    ['preview ref equals dev', { ...preview, STAGING_SUPABASE_PROJECT_REF: DEV, SUPABASE_URL: `https://${DEV}.supabase.co` }],
    ['dev ref unset', { ...prod, DEV_SUPABASE_PROJECT_REF: '' }],
    ['anon key missing', { ...prod, SUPABASE_ANON_KEY: '' }],
  ])('refuses %s', (_n, env) => expect(() => assertBuildTarget(env)).toThrow(/Refusing/));
  it('never puts a URL or ref into the message', () => {
    try {
      assertBuildTarget({ ...prod, SUPABASE_URL: `https://${STG}.supabase.co` });
      throw new Error('should have refused');
    } catch (e) {
      for (const s of [DEV, STG, PRD, 'https://']) expect((e as Error).message).not.toContain(s);
    }
  });
});

describe('eas.json and build-android-eas.yml (D1, D2)', () => {
  const eas = JSON.parse(readFileSync(join(__dirname, '../../eas.json'), 'utf8'));
  const wf = readFileSync(join(__dirname, '../../.github/workflows/build-android-eas.yml'), 'utf8').replace(/^\s*#.*$/gm, '');
  it('production builds an APK, keeps autoIncrement, and each profile reads its own EAS environment', () => {
    expect(eas.build.production.android.buildType).toBe('apk');
    expect(eas.build.production.autoIncrement).toBe(true);
    expect(eas.build.production.environment).toBe('production');
    expect(eas.build.preview.environment).toBe('preview');
  });
  it('is manual, main only, guarded before variables are written, and commits no secret values', () => {
    expect(wf).toContain('workflow_dispatch:');
    expect(wf).not.toMatch(/push:|pull_request|schedule:/);
    expect(wf).toContain("github.ref == 'refs/heads/main'");
    expect(wf.indexOf('eas-build-guard.ts')).toBeGreaterThan(0);
    expect(wf.indexOf('eas-build-guard.ts')).toBeLessThan(wf.indexOf('eas-env-set.sh'));
    expect(readFileSync(join(__dirname, '../eas-env-set.sh'), 'utf8')).toContain('--visibility plaintext');
    expect(wf).toMatch(/environment: production/);
  });
  it('the production job uses prod secrets only and the preview job staging secrets only', () => {
    const [pre, pro] = wf.split(/\n  production:/);
    expect(pre).not.toMatch(/secrets\.PROD_SUPABASE_(URL|ANON_KEY)/);
    expect(pro).not.toMatch(/secrets\.STAGING_SUPABASE_(URL|ANON_KEY)/);
    expect(pre).toContain('secrets.STAGING_SUPABASE_URL');
    expect(pro).toContain('secrets.PROD_SUPABASE_URL');
  });
});
