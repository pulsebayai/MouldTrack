import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  assertSafeTarget, coverCorrections, ensureFixtureSite, FIXTURE_PLAN_FROM, isCanonicalPhone, isFixtureAuthEmail, isThrowawayAuthEmail, isThrowawayPlantName, PLANT,
  planCorrections, SHIFTS, TENANTS, USERS,
} from '../fixtures-reset';

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

describe('fixtures-reset 04 plant fixtures (D8)', () => {
  const seed = readFileSync(join(__dirname, '../../supabase/seed.sql'), 'utf8');
  const byTenant = (t: string) => PLANT.find((p) => p.tenant === t)!;

  it('covers orgs A, B and U only (S has no plant)', () => expect(PLANT.map((p) => p.tenant)).toEqual(['e2e org A', 'e2e org B', 'e2e org U']));
  it('orgs A and B hold one machine and one product each; org U holds 2 lines, 3 machines, 3 products', () => {
    for (const t of ['e2e org A', 'e2e org B']) expect([byTenant(t).machines.length, byTenant(t).products.length, byTenant(t).lines.length]).toEqual([1, 1, 0]);
    const u = byTenant('e2e org U');
    expect([u.lines.length, u.machines.length, u.products.length]).toEqual([2, 3, 3]);
  });
  it('org U keeps a machine without a target, and every target names a fixture machine and product', () => {
    const u = byTenant('e2e org U');
    expect(u.machines.some((m) => !u.targets.some((t) => t.machine === m.code))).toBe(true);
    for (const p of PLANT) for (const t of p.targets) {
      expect(p.machines.map((m) => m.code)).toContain(t.machine);
      expect(p.products.map((x) => x.code)).toContain(t.product);
      expect(Number.isInteger(t.pieces) && t.pieces >= 1 && t.pieces <= 1_000_000).toBe(true);
    }
  });
  it('fixture machine and product codes are valid and never look like throwaway rows', () => {
    for (const p of PLANT) {
      for (const m of p.machines) { expect(m.code).toMatch(/^[A-Za-z0-9_/-]{1,20}$/); expect(isThrowawayPlantName(m.code)).toBe(false); }
      for (const x of p.products) { expect(x.code).toMatch(/^[A-Za-z0-9_/-]{1,20}$/); expect(isThrowawayPlantName(x.code)).toBe(false); }
      for (const l of p.lines) expect(isThrowawayPlantName(l)).toBe(false);
    }
  });
  it('recognises throwaway e2e rows by their E2E- prefix only', () => {
    expect(isThrowawayPlantName('E2E-ab12cd34')).toBe(true);
    expect(isThrowawayPlantName('E2E-ABC')).toBe(true);
    expect(isThrowawayPlantName('FX-MU1')).toBe(false);
    expect(isThrowawayPlantName('E2E-')).toBe(false);
    expect(isThrowawayPlantName('e2e-abc123')).toBe(false);
    expect(isThrowawayPlantName('E2E-abc123 extra')).toBe(false);
  });
  it('the seed file defines every fixture site, line, machine and product, and each target amount', () => {
    for (const p of PLANT) {
      expect(seed).toContain(`'${p.site}'`);
      for (const l of p.lines) expect(seed).toContain(`'${l}'`);
      for (const m of p.machines) { expect(seed).toContain(`'${m.code}'`); expect(seed).toContain(`'${m.name}'`); }
      for (const x of p.products) { expect(seed).toContain(`'${x.code}'`); expect(seed).toContain(`'${x.description}'`); }
      for (const t of p.targets) expect(seed).toMatch(new RegExp(`date '2026-01-01', ${t.pieces},`));
    }
  });
});

describe('fixtures-reset ensureFixtureSite (R4 item 14)', () => {
  // a recording stand-in for the service-role client's site table
  function fakeAdmin(existing: { id: string; name: string; timezone: string } | null) {
    const calls: { op: string; payload?: unknown; id?: unknown }[] = [];
    const chain = (op: string, payload?: unknown) => {
      const c: Record<string, unknown> = {};
      for (const n of ['select', 'eq']) c[n] = (...a: unknown[]) => { if (n === 'eq' && op === 'update') calls[calls.length - 1].id = a[1]; return c; };
      c.maybeSingle = async () => ({ data: existing, error: null });
      c.single = async () => ({ data: { id: 'new-site' }, error: null });
      c.then = (res: (v: unknown) => unknown) => Promise.resolve({ data: [{ id: 'x' }], error: null }).then(res);
      calls.push({ op, payload });
      return c;
    };
    return { calls, admin: { from: () => ({ select: () => chain('select'), insert: (p: unknown) => chain('insert', p), update: (p: unknown) => chain('update', p) }) } as never };
  }
  it('restores the name and time zone when an e2e run changed them', async () => {
    const f = fakeAdmin({ id: 's-1', name: 'Renamed by a test', timezone: 'UTC' });
    expect(await ensureFixtureSite(f.admin, 't-1', { site: 'Fixture Plant U' })).toBe('s-1');
    expect(f.calls.find((c) => c.op === 'update')).toMatchObject({ payload: { name: 'Fixture Plant U', timezone: 'Asia/Kolkata' }, id: 's-1' });
  });
  it('leaves an untouched site alone', async () => {
    const f = fakeAdmin({ id: 's-1', name: 'Fixture Plant U', timezone: 'Asia/Kolkata' });
    expect(await ensureFixtureSite(f.admin, 't-1', { site: 'Fixture Plant U' })).toBe('s-1');
    expect(f.calls.some((c) => c.op === 'update' || c.op === 'insert')).toBe(false);
  });
  it('creates a missing site', async () => {
    const f = fakeAdmin(null);
    expect(await ensureFixtureSite(f.admin, 't-1', { site: 'Fixture Plant U' })).toBe('new-site');
    expect(f.calls.find((c) => c.op === 'insert')).toMatchObject({ payload: { tenant_id: 't-1', name: 'Fixture Plant U', timezone: 'Asia/Kolkata' } });
  });
});

describe('fixtures-reset 05 shift fixtures (D12)', () => {
  const seed = readFileSync(join(__dirname, '../../supabase/seed.sql'), 'utf8');
  const minutes = (t: string) => Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5));
  const covered = (fx: { start: string; end: string }): Set<number> => {
    const out = new Set<number>();
    const s = minutes(fx.start);
    const e = minutes(fx.end);
    for (let m = s; m !== e; m = (m + 1) % 1440) out.add(m);
    return out;
  };

  it('defines shifts for orgs A and U only', () => expect([...new Set(SHIFTS.map((s) => s.tenant))]).toEqual(['e2e org A', 'e2e org U']));
  it('every shift is valid: 15-minute steps, end differs from start, name 1-40 characters, never a throwaway name', () => {
    for (const s of SHIFTS) {
      expect(s.start).toMatch(/^([01][0-9]|2[0-3]):(00|15|30|45)$/);
      expect(s.end).toMatch(/^([01][0-9]|2[0-3]):(00|15|30|45)$/);
      expect(s.end).not.toBe(s.start);
      expect(s.name.length >= 1 && s.name.length <= 40).toBe(true);
      expect(isThrowawayPlantName(s.name)).toBe(false);
    }
    expect(new Set(SHIFTS.map((s) => s.id)).size).toBe(SHIFTS.length);
    expect(new Set(SHIFTS.map((s) => `${s.tenant}/${s.name.toLowerCase()}`)).size).toBe(SHIFTS.length);
  });
  it('org A shifts together cover all 24 hours exactly once, so supervisor A always has a running shift', () => {
    const a = SHIFTS.filter((s) => s.tenant === 'e2e org A').map(covered);
    const all = new Set<number>();
    let total = 0;
    for (const set of a) { total += set.size; set.forEach((m) => all.add(m)); }
    expect(all.size).toBe(1440);
    expect(total).toBe(1440);
  });
  it('org U has an overnight Night shift and a day Morning shift; U3 owns two machines on both', () => {
    const u = SHIFTS.filter((s) => s.tenant === 'e2e org U');
    expect(u.map((s) => s.name)).toEqual(['Fixture Morning', 'Fixture Night']);
    expect(minutes(u[1].end) < minutes(u[1].start)).toBe(true);
    for (const s of u) expect(s.assignments).toEqual([{ machine: 'FX-MU1', supervisor: 'u3' }, { machine: 'FX-MU2', supervisor: 'u3' }]);
  });
  it('every assignment names a fixture machine of the same tenant and a supervisor of that tenant', () => {
    for (const s of SHIFTS) {
      const plant = PLANT.find((p) => p.tenant === s.tenant)!;
      for (const a of s.assignments) {
        expect(plant.machines.map((m) => m.code)).toContain(a.machine);
        const user = USERS.find((u) => u.key === a.supervisor)!;
        expect([user.tenant, user.role, !!user.mustChange]).toEqual([s.tenant, 'supervisor', false]);
      }
    }
  });
  it('the seed file defines every fixture shift (id, name, times) and its plan from the fixed date', () => {
    expect(seed).toContain(`date '${FIXTURE_PLAN_FROM}'`);
    for (const s of SHIFTS) {
      expect(seed).toContain(`'${s.id}'`);
      expect(seed).toContain(`'${s.name}', '${s.start}', '${s.end}'`);
    }
    // one plan row per fixture assignment (recorded_by is the tenant's Unit Admin)
    expect(seed.match(/date '2026-01-01', '30000000-0000-4000-a000-0000000000(a1|e1)'\)/g)?.length).toBe(SHIFTS.reduce((n, s) => n + s.assignments.length, 0));
  });
});

describe('fixtures-reset 05 append-only corrections', () => {
  const SUP = 'sup-1';
  const OTHER = 'sup-2';
  const row = (id: string, effective_from: string, supervisor_id: string | null, recorded_at = '2026-11-01T00:00:00+00:00') => ({ id, effective_from, supervisor_id, recorded_at });

  it('appends the base version when there is none', () => expect(planCorrections([], SUP, '2026-11-17')).toEqual([FIXTURE_PLAN_FROM, '2026-11-17']));
  it('appends nothing when the fixture supervisor already owns every checked date', () =>
    expect(planCorrections([row('a', FIXTURE_PLAN_FROM, SUP)], SUP, '2026-11-17')).toEqual([]));
  it('restores the owner after an e2e plan change today', () => {
    const rows = [row('a', FIXTURE_PLAN_FROM, SUP), row('b', '2026-11-17', OTHER, '2026-11-17T01:00:00+00:00')];
    expect(planCorrections(rows, SUP, '2026-11-17')).toEqual(['2026-11-17']);
  });
  it('restores the owner for a scheduled change and for an unassign in the future', () => {
    const rows = [row('a', FIXTURE_PLAN_FROM, SUP), row('b', '2026-11-20', OTHER), row('c', '2026-11-25', null)];
    expect(planCorrections(rows, SUP, '2026-11-17')).toEqual(['2026-11-20', '2026-11-25']);
  });
  it('a later correction recorded on the same date wins, so a corrected date is not appended again', () => {
    const rows = [row('a', FIXTURE_PLAN_FROM, SUP), row('b', '2026-11-20', OTHER, '2026-11-17T01:00:00+00:00'), row('c', '2026-11-20', SUP, '2026-11-17T02:00:00+00:00')];
    expect(planCorrections(rows, SUP, '2026-11-17')).toEqual([]);
  });
  it('ignores past changes that are not the current owner of today', () => {
    const rows = [row('a', FIXTURE_PLAN_FROM, OTHER), row('b', '2026-06-01', SUP)];
    expect(planCorrections(rows, SUP, '2026-11-17')).toEqual([FIXTURE_PLAN_FROM]);
  });

  const cover = (id: string, shift_date: string, supervisor_id: string | null, recorded_at = '2026-11-17T00:00:00+00:00') => ({ id, shift_date, supervisor_id, recorded_at });
  it('puts the fixture supervisor back on covered occurrences from yesterday on', () => {
    const rows = [cover('a', '2026-11-16', OTHER), cover('b', '2026-11-17', null), cover('c', '2026-11-18', OTHER)];
    expect(coverCorrections(rows, SUP, '2026-11-16')).toEqual(['2026-11-16', '2026-11-17', '2026-11-18']);
    expect(coverCorrections(rows, SUP, '2026-11-17')).toEqual(['2026-11-17', '2026-11-18']);
  });
  it('leaves occurrences whose latest cover already names the fixture supervisor', () => {
    const rows = [cover('a', '2026-11-18', OTHER, '2026-11-17T01:00:00+00:00'), cover('b', '2026-11-18', SUP, '2026-11-17T02:00:00+00:00')];
    expect(coverCorrections(rows, SUP, '2026-11-17')).toEqual([]);
  });
});
