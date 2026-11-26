import { readFileSync } from 'node:fs';
import { join } from 'node:path';

// OTA updates (R1, owner 2026-11-26): the same guards as the APK builds, so an update can never point phones at the wrong backend.
describe('app.json updates and eas-update.yml', () => {
  const app = JSON.parse(readFileSync(join(__dirname, '../../app.json'), 'utf8')).expo;
  const wf = readFileSync(join(__dirname, '../../.github/workflows/eas-update.yml'), 'utf8').replace(/^\s*#.*$/gm, '');
  const [pre, pro] = wf.split(/\n {2}production:/);

  it('the app checks its own EAS project for updates, keyed by the app version', () => {
    expect(app.updates.url).toBe(`https://u.expo.dev/${app.extra.eas.projectId}`);
    expect(app.runtimeVersion).toEqual({ policy: 'appVersion' });
    expect(app.updates.fallbackToCacheTimeout).toBe(0); // never delay a supervisor's launch waiting for the network
  });

  it('is manual, main only, and guarded before any variable is written or update published', () => {
    expect(wf).toContain('workflow_dispatch:');
    expect(wf).not.toMatch(/push:|pull_request|schedule:/);
    for (const job of [pre, pro]) {
      expect(job).toContain("github.ref == 'refs/heads/main'");
      const guard = job.indexOf('eas-build-guard.ts');
      expect(guard).toBeGreaterThan(0);
      expect(guard).toBeLessThan(job.indexOf('eas-env-set.sh'));
      expect(job.indexOf('eas-env-set.sh')).toBeLessThan(job.indexOf('eas-update.sh'));
    }
  });

  it('production publishes behind the production environment with prod secrets only; preview with staging secrets only', () => {
    expect(pro).toMatch(/environment: production/);
    expect(pre).not.toMatch(/environment: production/);
    expect(pro).not.toMatch(/secrets\.STAGING_SUPABASE_(URL|ANON_KEY)/);
    expect(pre).not.toMatch(/secrets\.PROD_SUPABASE_(URL|ANON_KEY)/);
    expect(pro).toContain('EXPO_PUBLIC_APP_ENV: production');
    expect(pre).toContain('EXPO_PUBLIC_APP_ENV: staging');
  });

  it('never interpolates the free-text message into a shell line', () => {
    const runs = wf.split('\n').filter((l) => /^\s+run:/.test(l));
    for (const r of runs) expect(r).not.toContain('inputs.message');
  });
});
