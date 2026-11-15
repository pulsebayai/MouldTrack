import { assertSafeTarget, USERS } from '../fixtures-reset';

const dev = { APP_ENV: 'development', DEV_SUPABASE_PROJECT_REF: 'abcdefghijklmnopqrst', SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co' };

describe('fixtures-reset safety guard', () => {
  it('allows local', () => expect(() => assertSafeTarget({ APP_ENV: 'local', SUPABASE_URL: 'http://127.0.0.1:54321' })).not.toThrow());
  it('allows the configured dev project', () => expect(() => assertSafeTarget(dev)).not.toThrow());
  it('refuses staging/production APP_ENV', () => {
    expect(() => assertSafeTarget({ ...dev, APP_ENV: 'staging' })).toThrow(/Refusing/);
    expect(() => assertSafeTarget({ ...dev, APP_ENV: 'production' })).toThrow(/Refusing/);
  });
  it('refuses a hosted project that is not the dev ref', () =>
    expect(() => assertSafeTarget({ ...dev, SUPABASE_URL: 'https://zzzzzzzzzzzzzzzzzzzz.supabase.co' })).toThrow(/Refusing/));
  it('refuses when the dev ref is unset', () =>
    expect(() => assertSafeTarget({ ...dev, DEV_SUPABASE_PROJECT_REF: '' })).toThrow(/Refusing/));
  it('only uses reserved .test addresses', () => expect(USERS.every((u) => u.email.endsWith('@example.test'))).toBe(true));
});
