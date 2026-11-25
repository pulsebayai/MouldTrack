import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { addDeepLinkFiles } from '../web-deep-links';

let root: string;
const put = (p: string, body: string) => {
  mkdirSync(join(root, p, '..'), { recursive: true });
  writeFileSync(join(root, p), body);
};
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'deeplinks-'));
});
afterEach(() => rmSync(root, { recursive: true, force: true }));

describe('addDeepLinkFiles (D3)', () => {
  it('writes <dir>.html next to every <dir>/index.html and returns the new files', () => {
    put('index.html', 'root');
    put('users/index.html', 'users');
    put('plant/index.html', 'plant');
    expect(addDeepLinkFiles(root)).toEqual(['plant.html', 'users.html']);
    expect(readFileSync(join(root, 'users.html'), 'utf8')).toBe('users');
    expect(readFileSync(join(root, 'plant.html'), 'utf8')).toBe('plant');
  });
  it('does not touch the root index.html', () => {
    put('index.html', 'root');
    expect(addDeepLinkFiles(root)).toEqual([]);
    expect(existsSync(join(root, '.html'))).toBe(false);
  });
  it('never overwrites an existing <dir>.html', () => {
    put('users/index.html', 'dir');
    put('users.html', 'existing');
    expect(addDeepLinkFiles(root)).toEqual([]);
    expect(readFileSync(join(root, 'users.html'), 'utf8')).toBe('existing');
  });
  it('handles nested directories and skips directories without index.html', () => {
    put('issues/index.html', 'issues');
    put('issues/new/index.html', 'new');
    put('_expo/static/js/app.js', 'js');
    expect(addDeepLinkFiles(root)).toEqual(['issues.html', 'issues/new.html']);
    expect(existsSync(join(root, '_expo.html'))).toBe(false);
  });
  it('is idempotent', () => {
    put('users/index.html', 'users');
    addDeepLinkFiles(root);
    expect(addDeepLinkFiles(root)).toEqual([]);
  });
});

describe('web deploy workflows run the deep-link fix before deploying (D3)', () => {
  const { readFileSync: rd } = jest.requireActual('node:fs') as typeof import('node:fs');
  for (const [f, alias] of [['deploy-dev.yml', 'dev'], ['deploy-staging.yml', 'staging']] as const) {
    it(`${f}: fixes the export, then deploys, then curls the five routes`, () => {
      const t = rd(join(__dirname, '../../.github/workflows', f), 'utf8').replace(/^\s*#.*$/gm, '');
      const fix = t.indexOf('web-deep-links.ts dist');
      expect(fix).toBeGreaterThan(t.indexOf('expo export'));
      expect(t.indexOf(`--alias ${alias}`)).toBeGreaterThan(fix);
      expect(t.indexOf('for p in users plant issues readings console')).toBeGreaterThan(t.indexOf(`--alias ${alias}`));
    });
  }
});
