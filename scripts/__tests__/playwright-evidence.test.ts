import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { evidenceSettings, isLocalUrl } from '../../e2e/evidence';

describe('Playwright evidence on hosted targets (R3)', () => {
  it.each(['http://localhost:8081', 'http://127.0.0.1:8081', 'http://localhost'])('keeps trace and screenshots for local %s', (u) => {
    expect(isLocalUrl(u)).toBe(true);
    expect(evidenceSettings(u)).toEqual({ trace: 'retain-on-failure', screenshot: 'only-on-failure', video: 'off' });
  });
  it.each(['https://mouldtrack--dev.expo.app', 'https://mouldtrack--staging.expo.app', 'https://mouldtrack.expo.app', 'https://localhost.evil.example', 'http://127.0.0.1.evil.example:8081', ''])(
    'turns trace, screenshot and video off for %s',
    (u) => {
      expect(isLocalUrl(u)).toBe(false);
      expect(evidenceSettings(u)).toEqual({ trace: 'off', screenshot: 'off', video: 'off' });
    },
  );
  it('playwright.config.ts uses the helper for every project (no hard-coded trace/screenshot)', () => {
    const cfg = readFileSync(join(__dirname, '..', '..', 'playwright.config.ts'), 'utf8');
    expect(cfg).toMatch(/evidenceSettings\(baseURL\)/);
    expect(cfg).not.toMatch(/trace:\s*'retain-on-failure'/);
    expect(cfg).not.toMatch(/screenshot:\s*'only-on-failure'/);
  });
});
