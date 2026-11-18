import { assertResetTarget, isFixturePhone, nonFixtureIdentities, redact } from '../dev-reset';

const REF = 'abcdefghijklmnopqrst';
const KEY = 'service-role-key-secret-value-0123456789';
const dev = {
  APP_ENV: 'development',
  DEV_SUPABASE_PROJECT_REF: REF,
  SUPABASE_URL: `https://${REF}.supabase.co`,
  SUPABASE_SERVICE_ROLE_KEY: KEY,
  SUPABASE_DB_URL: `postgresql://postgres.${REF}:p4ssw0rd-secret@aws-0-ap-south-1.pooler.supabase.com:5432/postgres`,
};
const local = {
  APP_ENV: 'local',
  SUPABASE_URL: 'http://127.0.0.1:15321',
  SUPABASE_SERVICE_ROLE_KEY: KEY,
  SUPABASE_DB_URL: 'postgresql://postgres:postgres@127.0.0.1:15322/postgres',
};

describe('dev-reset guard (D4)', () => {
  it('accepts the exact dev project', () => expect(assertResetTarget(dev).mode).toBe('dev'));
  it('accepts the local stack only with APP_ENV=local', () => expect(assertResetTarget(local).mode).toBe('local'));
  it('accepts 0.0.0.0 as the local database host (CLI remote code path in CI)', () =>
    expect(assertResetTarget({ ...local, SUPABASE_DB_URL: 'postgresql://postgres:postgres@0.0.0.0:15322/postgres' }).mode).toBe('local'));
  it('accepts a direct db host of the dev project', () =>
    expect(assertResetTarget({ ...dev, SUPABASE_DB_URL: `postgresql://postgres:x@db.${REF}.supabase.co:5432/postgres` }).mode).toBe('dev'));

  it.each([
    ['APP_ENV missing', { ...dev, APP_ENV: undefined }],
    ['APP_ENV production', { ...dev, APP_ENV: 'production' }],
    ['APP_ENV staging', { ...dev, APP_ENV: 'staging' }],
    ['dev ref missing', { ...dev, DEV_SUPABASE_PROJECT_REF: '' }],
    ['URL of another project', { ...dev, SUPABASE_URL: 'https://zzzzzzzzzzzzzzzzzzzz.supabase.co' }],
    ['URL with the ref as a prefix of another host', { ...dev, SUPABASE_URL: `https://${REF}.evil.example` }],
    ['URL with the ref as a subdomain suffix', { ...dev, SUPABASE_URL: `https://x${REF}.supabase.co` }],
    ['db url of another project', { ...dev, SUPABASE_DB_URL: 'postgresql://postgres.zzzzzzzzzzzzzzzzzzzz:x@aws-0-ap-south-1.pooler.supabase.com:5432/postgres' }],
    ['db url missing', { ...dev, SUPABASE_DB_URL: '' }],
    ['db url not a url', { ...dev, SUPABASE_DB_URL: 'not a url' }],
    ['ref only in the db url path', { ...dev, SUPABASE_DB_URL: `postgresql://postgres:x@other.example:5432/${REF}` }],
    ['service key missing', { ...dev, SUPABASE_SERVICE_ROLE_KEY: '' }],
    ['local APP_ENV with the hosted URL', { ...dev, APP_ENV: 'local' }],
    ['development APP_ENV with the local URL', { ...local, APP_ENV: 'development', DEV_SUPABASE_PROJECT_REF: REF }],
    ['local with a hosted db url', { ...local, SUPABASE_DB_URL: dev.SUPABASE_DB_URL }],
    ['local url on another host', { ...local, SUPABASE_URL: 'http://10.0.0.5:15321' }],
    ['0.0.0.0 as the API URL', { ...local, SUPABASE_URL: 'http://0.0.0.0:15321' }],
    ['https url for local', { ...local, SUPABASE_URL: 'https://127.0.0.1:15321' }],
  ])('refuses: %s', (_name, env) => {
    expect(() => assertResetTarget(env as Record<string, string | undefined>)).toThrow(/^Refusing/);
  });

  it('never puts a secret, URL or key in a refusal message', () => {
    const bad = [
      { ...dev, APP_ENV: 'production' },
      { ...dev, SUPABASE_URL: 'https://zzzzzzzzzzzzzzzzzzzz.supabase.co' },
      { ...dev, SUPABASE_DB_URL: 'postgresql://postgres.zzzzzzzzzzzzzzzzzzzz:p4ssw0rd-secret@host.example:5432/postgres' },
      { ...local, SUPABASE_DB_URL: dev.SUPABASE_DB_URL },
    ];
    for (const env of bad) {
      let msg = '';
      try { assertResetTarget(env); } catch (e) { msg = (e as Error).message; }
      expect(msg).toMatch(/^Refusing/);
      for (const secret of [KEY, 'p4ssw0rd-secret', 'supabase.co', 'pooler', '127.0.0.1', REF, 'zzzzzzzzzzzz']) expect(msg).not.toContain(secret);
    }
  });

  it('can skip the db url for the size check', () => {
    expect(assertResetTarget({ ...dev, SUPABASE_DB_URL: undefined }, { needDb: false }).dbUrl).toBeNull();
  });
});

describe('dev-reset identity guard (real data on dev is a stop)', () => {
  it('knows the fixture phone blocks', () => {
    expect(isFixturePhone('+919000000001')).toBe(true);
    expect(isFixturePhone('+919000000099')).toBe(true);
    expect(isFixturePhone('+919000010000')).toBe(true);
    expect(isFixturePhone('+919000099999')).toBe(true);
    expect(isFixturePhone('+919000000000')).toBe(false);
    expect(isFixturePhone('+919000000100')).toBe(false);
    expect(isFixturePhone('+919000009999')).toBe(false);
    expect(isFixturePhone('+919876543210')).toBe(false);
  });
  it('accepts fixture, throwaway and legacy Auth addresses', () => {
    expect(nonFixtureIdentities(['9000000010@phone.mouldtrack.invalid', '9000012345@phone.mouldtrack.invalid', 'e2e-admin-a@example.test'], ['+919000000011'])).toEqual([]);
  });
  it('flags a real-looking phone or address and reports it masked', () => {
    const bad = nonFixtureIdentities(['9876543210@phone.mouldtrack.invalid', 'someone@company.example'], ['+919812345678']);
    expect(bad).toHaveLength(3);
    for (const b of bad) {
      expect(b).not.toContain('9876543210');
      expect(b).not.toContain('9812345678');
      expect(b).not.toContain('someone');
    }
  });
});

describe('redact', () => {
  it('removes database URLs, the service key and bearer tokens', () => {
    const text = `failed: ${dev.SUPABASE_DB_URL} key=${KEY} Authorization: Bearer eyJhbGciOi.abc.def host ${dev.SUPABASE_URL}`;
    const out = redact(text, { SUPABASE_SERVICE_ROLE_KEY: KEY, SUPABASE_DB_URL: dev.SUPABASE_DB_URL, SUPABASE_URL: dev.SUPABASE_URL, E2E_FIXTURE_PASSWORD: 'pw-fixture-secret-123' });
    expect(out).not.toContain('p4ssw0rd-secret');
    expect(out).not.toContain(KEY);
    expect(out).not.toContain('eyJhbGciOi');
    expect(out).not.toContain(REF);
  });
});
