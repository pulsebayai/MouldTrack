import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { assertSafeTarget, isCanonicalPhone, isFixtureAuthEmail, isThrowawayAuthEmail, TENANTS, USERS } from '../fixtures-reset';

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
  // 02: sign-in is by phone, so fixture Auth addresses moved from the reserved .test domain to the reserved .invalid one
  // (RFC 2606, never deliverable). The same strictness: every fixture address must be in the reserved domain.
  it('only uses reserved .invalid addresses', () => expect(USERS.every((u) => u.email.endsWith('@phone.mouldtrack.invalid'))).toBe(true));
});

describe('fixtures-reset 02 identities (D2, D3)', () => {
  it('every fixture phone is in the canonical block +91 90000 00001-00099', () => {
    for (const u of USERS) expect(isCanonicalPhone(u.phone)).toBe(true);
  });
  it('canonical block boundaries', () => {
    expect(isCanonicalPhone('+919000000001')).toBe(true);
    expect(isCanonicalPhone('+919000000099')).toBe(true);
    expect(isCanonicalPhone('+919000000000')).toBe(false);
    expect(isCanonicalPhone('+919000000100')).toBe(false);
    expect(isCanonicalPhone('+919000010000')).toBe(false); // throwaway block
    expect(isCanonicalPhone('+919876543210')).toBe(false); // a real-looking number
  });
  it('each fixture email is derived from its phone', () => {
    for (const u of USERS) expect(u.email).toBe(`${u.phone.slice(3)}@phone.mouldtrack.invalid`);
  });
  it('fixture phones and employee ids are unique', () => {
    expect(new Set(USERS.map((u) => u.phone)).size).toBe(USERS.length);
    const ids = USERS.filter((u) => u.tenant).map((u) => `${u.tenant}/${u.employeeId}`);
    expect(new Set(ids).size).toBe(ids.length);
  });
  it('defines org U with two Unit Admins, a supervisor and a fresh must-change user, plus A, B, S', () => {
    expect(TENANTS.map((t) => t.name)).toEqual(['e2e org A', 'e2e org B', 'e2e org S', 'e2e org U']);
    const u = USERS.filter((x) => x.tenant === 'e2e org U');
    expect(u.map((x) => [x.role, !!x.mustChange])).toEqual([['unit_admin', false], ['unit_admin', false], ['supervisor', false], ['supervisor', true]]);
    expect(USERS.filter((x) => x.mustChange).map((x) => x.tenant)).toEqual(['e2e org U']);
  });
  it('recognises fixture and throwaway Auth addresses', () => {
    expect(isFixtureAuthEmail('9000000001@phone.mouldtrack.invalid')).toBe(true);
    expect(isFixtureAuthEmail('9000000100@phone.mouldtrack.invalid')).toBe(false);
    expect(isFixtureAuthEmail('9000000001@example.test')).toBe(false);
    expect(isThrowawayAuthEmail('9000010000@phone.mouldtrack.invalid')).toBe(true);
    expect(isThrowawayAuthEmail('9000099999@phone.mouldtrack.invalid')).toBe(true);
    expect(isThrowawayAuthEmail('9000009999@phone.mouldtrack.invalid')).toBe(false);
    expect(isThrowawayAuthEmail('9876543210@phone.mouldtrack.invalid')).toBe(false);
    expect(isThrowawayAuthEmail('9000010000@example.test')).toBe(false);
  });
  it('refuses a fixture with a phone outside the canonical block', () => {
    const bad = { ...USERS[0], phone: '+919876543210', email: '9876543210@phone.mouldtrack.invalid' };
    expect(() => assertSafeTarget({ APP_ENV: 'local', SUPABASE_URL: 'http://127.0.0.1:15321' }, [bad, ...USERS.slice(1)])).toThrow(/Refusing.*phone/);
  });
  it('refuses a fixture with a non-.invalid email', () => {
    const bad = { ...USERS[0], email: 'e2e-admin-a@example.test' };
    expect(() => assertSafeTarget({ APP_ENV: 'local', SUPABASE_URL: 'http://127.0.0.1:15321' }, [bad, ...USERS.slice(1)])).toThrow(/Refusing.*email/);
  });
  it('refuses a mismatch between phone and email', () => {
    const bad = { ...USERS[0], email: '9000000099@phone.mouldtrack.invalid' };
    expect(() => assertSafeTarget({ APP_ENV: 'local', SUPABASE_URL: 'http://127.0.0.1:15321' }, [bad, ...USERS.slice(1)])).toThrow(/Refusing/);
  });
  it('the seed file defines every fixture tenant, phone and email so local CI and hosted dev agree', () => {
    const seed = readFileSync(join(__dirname, '../../supabase/seed.sql'), 'utf8');
    for (const t of TENANTS) expect(seed).toContain(`'${t.name}'`);
    for (const u of USERS) {
      expect(seed).toContain(`'${u.phone.slice(3)}'`); // Auth address digits
      if (u.tenant) {
        expect(seed).toContain(u.phone);
        expect(seed).toContain(u.employeeId);
      }
    }
    expect(seed).not.toContain('@example.test');
  });
});
