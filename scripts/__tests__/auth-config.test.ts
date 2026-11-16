import { execFile } from 'node:child_process';
import { createServer, type Server } from 'node:http';
import { join } from 'node:path';

const SCRIPT = join(__dirname, '..', 'auth-config.mjs');
const LETTERS_DIGITS = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ:0123456789';
const GOOD = { disable_signup: true, password_min_length: 10, password_required_characters: LETTERS_DIGITS };
const REF = 'abcdefghijklmnopqrst';

type Req = { method: string; url: string; auth: string | undefined; body: string };
let server: Server;
let port = 0;
let state: Record<string, unknown>;
let reqs: Req[];
let patchStatus = 200;

beforeAll(async () => {
  server = createServer((req, res) => {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      reqs.push({ method: req.method!, url: req.url!, auth: req.headers.authorization, body });
      if (req.method === 'PATCH') {
        if (patchStatus !== 200) {
          res.writeHead(patchStatus, { 'content-type': 'application/json' });
          return res.end(JSON.stringify({ message: 'password_required_characters is not available on this plan' }));
        }
        state = { ...state, ...JSON.parse(body) };
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ...state, smtp_pass: 'must-never-be-printed' }));
    });
  });
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  port = (server.address() as { port: number }).port;
});
afterAll(() => new Promise<void>((r) => server.close(() => r())));
beforeEach(() => {
  reqs = [];
  patchStatus = 200;
  state = { ...GOOD };
});

function run(args: string[], env: Record<string, string> = {}): Promise<{ code: number; out: string }> {
  return new Promise((resolve) => {
    execFile(
      'node',
      [SCRIPT, ...args],
      { env: { NODE_ENV: 'test', PATH: process.env.PATH ?? '', SUPABASE_ACCESS_TOKEN: 'sbp_test_token', DEV_SUPABASE_PROJECT_REF: REF, STAGING_SUPABASE_PROJECT_REF: 'zzzzzzzzzzzzzzzzzzzz', SUPABASE_API_URL: `http://127.0.0.1:${port}`, ...env } },
      (err: Error | null, stdout: string | Buffer, stderr: string | Buffer) => resolve({ code: err ? ((err as { code?: number }).code ?? 1) : 0, out: `${stdout}${stderr}` }),
    );
  });
}

describe('auth-config (D9)', () => {
  it('--check passes when signup is off, min length 10 and letters+digits are required; never writes', async () => {
    const r = await run(['--check', '--ref', 'dev']);
    expect(r.code).toBe(0);
    expect(reqs.map((q) => q.method)).toEqual(['GET']);
    expect(reqs[0].url).toBe(`/v1/projects/${REF}/config/auth`);
    expect(reqs[0].auth).toBe('Bearer sbp_test_token');
  });
  it('--check fails and names each differing field when the config is wrong', async () => {
    state = { disable_signup: false, password_min_length: 6, password_required_characters: '' };
    const r = await run(['--check', '--ref', 'dev']);
    expect(r.code).toBe(1);
    expect(r.out).toMatch(/disable_signup/);
    expect(r.out).toMatch(/password_min_length/);
    expect(r.out).toMatch(/password_required_characters/);
    expect(reqs.every((q) => q.method === 'GET')).toBe(true);
  });
  it('--apply patches only the three fields, then verifies', async () => {
    state = { disable_signup: false, password_min_length: 6, password_required_characters: '', site_url: 'https://keep.me' };
    const r = await run(['--apply', '--ref', 'dev']);
    expect(r.code).toBe(0);
    const patch = reqs.find((q) => q.method === 'PATCH')!;
    expect(JSON.parse(patch.body)).toEqual(GOOD);
    expect(state.site_url).toBe('https://keep.me');
    expect(reqs[reqs.length - 1].method).toBe('GET');
  });
  it('--apply does nothing when already correct', async () => {
    const r = await run(['--apply', '--ref', 'dev']);
    expect(r.code).toBe(0);
    expect(reqs.some((q) => q.method === 'PATCH')).toBe(false);
  });
  it('never prints secrets from the response or the token', async () => {
    state = { ...GOOD, password_min_length: 6 };
    const r = await run(['--check', '--ref', 'dev']);
    expect(r.out).not.toContain('must-never-be-printed');
    expect(r.out).not.toContain('sbp_test_token');
  });
  it('reports a rejected field as BLOCKED with the API status and message (exit 2)', async () => {
    state = { ...GOOD, password_required_characters: '' };
    patchStatus = 400;
    const r = await run(['--apply', '--ref', 'dev']);
    expect(r.code).toBe(2);
    expect(r.out).toMatch(/BLOCKED/);
    expect(r.out).toMatch(/400/);
    expect(r.out).toMatch(/not available on this plan/);
    expect(r.out).not.toContain('sbp_test_token');
  });
  it('resolves dev and staging refs from the environment and refuses anything else (incl. prod and raw refs)', async () => {
    expect((await run(['--check', '--ref', 'staging'])).code).toBe(0);
    expect(reqs[0].url).toBe('/v1/projects/zzzzzzzzzzzzzzzzzzzz/config/auth');
    reqs = [];
    for (const bad of ['prod', 'production', REF, '']) {
      const r = await run(['--check', '--ref', bad]);
      expect(r.code).toBe(1);
      expect(r.out).toMatch(/Refusing/);
    }
    expect(reqs).toEqual([]);
  });
  it('requires a mode, a token and the ref variable', async () => {
    expect((await run(['--ref', 'dev'])).code).toBe(1);
    expect((await run(['--check', '--ref', 'dev'], { SUPABASE_ACCESS_TOKEN: '' })).code).toBe(1);
    expect((await run(['--check', '--ref', 'dev'], { DEV_SUPABASE_PROJECT_REF: '' })).code).toBe(1);
  });
});
