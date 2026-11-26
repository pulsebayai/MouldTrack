import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { assertExportTarget, listAll, toCopy } from '../storage-export';

const PROD = 'p'.repeat(20);
const ok = {
  PROD_SUPABASE_PROJECT_REF: PROD,
  DEV_SUPABASE_PROJECT_REF: 'd'.repeat(20),
  STAGING_SUPABASE_PROJECT_REF: 's'.repeat(20),
  PROD_SUPABASE_URL: `https://${PROD}.supabase.co`,
  PROD_SUPABASE_SERVICE_ROLE_KEY: 'key',
  BACKUP_S3_BUCKET: 'mouldtrack-prod-photos',
};

describe('photo backup target guard (R1)', () => {
  it('accepts exactly the prod project and a bucket name', () => {
    expect(assertExportTarget(ok)).toEqual({ url: `https://${PROD}.supabase.co`, ref: PROD, bucket: 'mouldtrack-prod-photos' });
  });
  it.each([
    ['the staging URL', { PROD_SUPABASE_URL: `https://${'s'.repeat(20)}.supabase.co` }],
    ['a prod ref equal to dev', { DEV_SUPABASE_PROJECT_REF: PROD }],
    ['a prod ref equal to staging', { STAGING_SUPABASE_PROJECT_REF: PROD }],
    ['no service key', { PROD_SUPABASE_SERVICE_ROLE_KEY: '' }],
    ['no bucket', { BACKUP_S3_BUCKET: '' }],
    ['a malformed URL', { PROD_SUPABASE_URL: 'not a url' }],
  ])('refuses %s', (_why, patch) => {
    expect(() => assertExportTarget({ ...ok, ...patch })).toThrow(/^Refusing/);
  });
  it('never puts a ref, URL or key in its messages', () => {
    try {
      assertExportTarget({ ...ok, PROD_SUPABASE_URL: `https://${'s'.repeat(20)}.supabase.co` });
    } catch (e) {
      expect(String(e)).not.toContain('s'.repeat(20));
      expect(String(e)).not.toContain(PROD);
    }
  });
});

describe('what gets copied', () => {
  it('copies new objects and objects whose size differs, skips identical ones', () => {
    const backup = new Map([['a', 10], ['b', 5]]);
    expect(toCopy([{ key: 'a', size: 10 }, { key: 'b', size: 6 }, { key: 'c', size: 1 }], backup).map((o) => o.key)).toEqual(['b', 'c']);
  });
  it('walks nested folders and pages of 1000', async () => {
    const tree: Record<string, { name: string; id: string | null; size: number | null }[]> = {
      '': [{ name: 'tenant', id: null, size: null }],
      tenant: [{ name: 't1', id: null, size: null }],
      'tenant/t1': Array.from({ length: 1001 }, (_, i) => ({ name: `f${i}.jpg`, id: `x${i}`, size: i })),
    };
    const objs = await listAll(async (prefix, offset) => (tree[prefix] ?? []).slice(offset, offset + 1000));
    expect(objs).toHaveLength(1001);
    expect(objs[0]).toEqual({ key: 'tenant/t1/f0.jpg', size: 0 });
  });
  it('stops at the bound instead of running away', async () => {
    await expect(listAll(async () => [{ name: 'x', id: 'x', size: 1 }, { name: 'y', id: 'y', size: 1 }], 1)).rejects.toThrow(/Refusing/);
  });
});

describe('storage-export.yml', () => {
  const wf = readFileSync(join(__dirname, '../../.github/workflows/storage-export.yml'), 'utf8').replace(/^\s*#.*$/gm, '');
  const script = readFileSync(join(__dirname, '../storage-export.ts'), 'utf8');
  it('runs nightly and by hand, from main only, with its secrets in environment prod-backup', () => {
    expect(wf).toMatch(/schedule:/);
    expect(wf).toContain('workflow_dispatch:');
    expect(wf).not.toMatch(/pull_request|push:/);
    expect(wf).toContain("github.ref == 'refs/heads/main'");
    expect(wf).toContain('environment: prod-backup');
  });
  it('never deletes, moves or writes on prod, and never deletes on S3', () => {
    expect(script).not.toMatch(/DeleteObject|\.remove\(|\.move\(|\.upload\(|\.update\(/);
  });
});
