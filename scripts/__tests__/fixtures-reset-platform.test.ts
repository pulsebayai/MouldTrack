import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { assertSafeTarget, isCanonicalPhone, SUPER_ADMINS, TENANT_PLANS, TENANTS, TEST_TENANT_PREFIX, USERS } from '../fixtures-reset';

const local = { APP_ENV: 'local', SUPABASE_URL: 'http://127.0.0.1:15321' };

describe('fixtures-reset 03 Super Admin fixtures (D8)', () => {
  it('defines two Super Admins in the canonical block, with emails derived from their phones', () => {
    expect(SUPER_ADMINS.map((s) => s.phone)).toEqual(['+919000000090', '+919000000091']);
    for (const s of SUPER_ADMINS) {
      expect(isCanonicalPhone(s.phone)).toBe(true);
      expect(s.email).toBe(`${s.phone.slice(3)}@phone.mouldtrack.invalid`);
      expect(s.tenant).toBeNull();
    }
  });
  it('their phones do not collide with tenant fixtures', () => {
    const phones = [...USERS, ...SUPER_ADMINS].map((u) => u.phone);
    expect(new Set(phones).size).toBe(phones.length);
  });
  it('the safety guard applies to them too', () => {
    expect(() => assertSafeTarget(local, [...USERS, ...SUPER_ADMINS])).not.toThrow();
    const bad = { ...SUPER_ADMINS[0], phone: '+919876543210', email: '9876543210@phone.mouldtrack.invalid' };
    expect(() => assertSafeTarget(local, [...USERS, bad])).toThrow(/Refusing.*phone/);
  });
  it('plan labels are given only to fixture tenants', () => {
    const names = TENANTS.map((t) => t.name);
    for (const name of Object.keys(TENANT_PLANS)) expect(names).toContain(name);
    for (const plan of Object.values(TENANT_PLANS)) expect(['trial', 'active']).toContain(plan);
  });
  it('tenants created by 03 tests are recognised by their prefix', () => expect(TEST_TENANT_PREFIX).toBe('e2e t3 '));
  it('the seed file creates the Super Admins and their plan labels so local CI and hosted dev agree', () => {
    const seed = readFileSync(join(__dirname, '../../supabase/seed.sql'), 'utf8');
    for (const s of SUPER_ADMINS) {
      expect(seed).toContain(`'${s.phone.slice(3)}'`);
      expect(seed).toContain(`'${s.phone}'`);
      expect(seed).toContain(`'${s.name}'`);
    }
    expect(seed).toContain('insert into public.platform_admin');
    for (const [name, plan] of Object.entries(TENANT_PLANS)) {
      expect(seed).toContain(`'${name}'`);
      expect(seed).toContain(`plan_label = '${plan}'`);
    }
  });
});
