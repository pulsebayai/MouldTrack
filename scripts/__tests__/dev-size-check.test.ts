import { diffCounts, expectedCounts, formatCounts, COUNT_KEYS } from '../dev-size-check';
import { PLANT, SHIFTS, ISSUES, READINGS, USERS, SUPER_ADMINS, TENANTS } from '../fixtures-reset';
import { demoCounts } from '../dev-demo-spec';

const TODAY = '2026-11-18';

describe('dev-size-check baseline (D5)', () => {
  const e = expectedCounts(TODAY);
  it('is built from the fixture lists plus the demo tenant', () => {
    const d = demoCounts(TODAY);
    expect(e.tenant).toBe(TENANTS.length + 1);
    expect(e.site).toBe(PLANT.length + 1);
    expect(e.machine).toBe(PLANT.reduce((n, p) => n + p.machines.length, 0) + d.machine);
    expect(e.product).toBe(PLANT.reduce((n, p) => n + p.products.length, 0) + d.product);
    expect(e.target_version).toBe(PLANT.reduce((n, p) => n + p.targets.length, 0) + d.target_version);
    expect(e.shift).toBe(SHIFTS.length + d.shift);
    expect(e.machine_issue).toBe(ISSUES.length + d.machine_issue);
    expect(e.production_reading).toBe(READINGS.occurrences.length * 2 + d.production_reading);
    expect(e.production_summary).toBe(READINGS.occurrences.length + d.production_summary);
    expect(e.membership).toBe(USERS.filter((u) => u.tenant).length + d.membership);
    expect(e.platform_admin).toBe(SUPER_ADMINS.length);
    expect(e.auth_users).toBe(USERS.length + SUPER_ADMINS.length + d.authUsers);
  });
  it('expects nothing a test could have left behind', () => {
    expect(e.storage_objects).toBe(0);
    expect(e.attachment).toBe(0);
    expect(e.assignment_cover).toBe(0);
    expect(e.target_override_version).toBe(0);
  });
  it('is identical on every day (history is dated relative to the reset)', () => {
    expect(expectedCounts('2027-03-01')).toEqual(e);
  });
  it('counts a fresh plan twice per assignment (the version at the fixture date and the one for today)', () => {
    expect(e.assignment_version).toBe(SHIFTS.reduce((n, s) => n + s.assignments.length, 0) * 2 + demoCounts(TODAY).assignment_version);
  });
});

describe('dev-size-check diff', () => {
  const e = expectedCounts(TODAY);
  it('is empty when equal', () => expect(diffCounts({ ...e }, e)).toEqual([]));
  it('names every mismatch with expected and actual', () => {
    const d = diffCounts({ ...e, auth_users: e.auth_users + 1, storage_objects: 3 }, e);
    expect(d).toEqual([
      `auth_users: expected ${e.auth_users}, got ${e.auth_users + 1}`,
      'storage_objects: expected 0, got 3',
    ]);
  });
  it('reports a count that could not be read', () => {
    const { audit_event: _a, ...rest } = e;
    expect(diffCounts(rest as typeof e, e)).toEqual(['audit_event: expected 0, got unreadable']);
  });
  it('formats one stable line per counter, in a fixed order', () => {
    const lines = formatCounts(e).split('\n');
    expect(lines).toHaveLength(COUNT_KEYS.length);
    expect(lines[0]).toBe(`${COUNT_KEYS[0]}=${e[COUNT_KEYS[0]]}`);
  });
});
