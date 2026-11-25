import { execFile } from 'node:child_process';
import { join } from 'node:path';

const SCRIPT = join(__dirname, '..', 'auth-config.mjs');
const run = (args: string[], env: Record<string, string>) =>
  new Promise<{ code: number; out: string }>((resolve) =>
    execFile('node', [SCRIPT, ...args], { env: { NODE_ENV: 'test', PATH: process.env.PATH ?? '', SUPABASE_ACCESS_TOKEN: 't', SUPABASE_API_URL: 'http://127.0.0.1:1', ...env } }, (err: Error | null, so: string | Buffer, se: string | Buffer) =>
      resolve({ code: err ? ((err as { code?: number }).code ?? 1) : 0, out: `${so}${se}` })));

describe('auth-config --ref prod is opt-in (D4)', () => {
  it('refuses prod unless AUTH_CONFIG_ALLOW_PROD=1', async () => {
    const r = await run(['--check', '--ref', 'prod'], { PROD_SUPABASE_PROJECT_REF: 'cdefghijklmnopqrstuv' });
    expect(r.code).toBe(1);
    expect(r.out).toMatch(/Refusing/);
  });
  it('with the opt-in it reads PROD_SUPABASE_PROJECT_REF (and fails when that is unset)', async () => {
    const r = await run(['--check', '--ref', 'prod'], { AUTH_CONFIG_ALLOW_PROD: '1' });
    expect(r.code).toBe(1);
    expect(r.out).toContain('PROD_SUPABASE_PROJECT_REF is not set');
  });
  it('the opt-in does not unlock any other ref name', async () => {
    const r = await run(['--check', '--ref', 'production'], { AUTH_CONFIG_ALLOW_PROD: '1', PROD_SUPABASE_PROJECT_REF: 'cdefghijklmnopqrstuv' });
    expect(r.out).toMatch(/Refusing/);
  });
});
