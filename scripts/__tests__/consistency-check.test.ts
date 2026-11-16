import { findInconsistencies } from '../consistency-check';

const now = new Date('2026-11-16T10:00:00Z');
const future = '2126-01-01T00:00:00Z';
const mem = (user_id: string, phone_e164: string, status: 'active' | 'inactive') => ({ user_id, phone_e164, status });
const au = (id: string, email: string | null, banned_until: string | null = null) => ({ id, email, banned_until });

describe('consistency-check (R7)', () => {
  it('is empty when every membership matches its Auth user', () => {
    const out = findInconsistencies(
      [mem('1', '+919000000001', 'active'), mem('2', '+919000000002', 'inactive')],
      [au('1', '9000000001@phone.mouldtrack.invalid'), au('2', '9000000002@phone.mouldtrack.invalid', future)],
      now,
    );
    expect(out).toEqual([]);
  });
  it('reports an Auth email that differs from the membership phone', () => {
    const out = findInconsistencies([mem('1', '+919000000001', 'active')], [au('1', '9000000099@phone.mouldtrack.invalid')], now);
    expect(out).toEqual(['1: auth email does not match the membership phone']);
  });
  it('reports an inactive member whose Auth user is not banned (also an expired ban)', () => {
    const out = findInconsistencies(
      [mem('1', '+919000000001', 'inactive'), mem('2', '+919000000002', 'inactive')],
      [au('1', '9000000001@phone.mouldtrack.invalid'), au('2', '9000000002@phone.mouldtrack.invalid', '2020-01-01T00:00:00Z')],
      now,
    );
    expect(out).toEqual(['1: inactive member is not banned in Auth', '2: inactive member is not banned in Auth']);
  });
  it('reports an active member whose Auth user is banned', () => {
    const out = findInconsistencies([mem('1', '+919000000001', 'active')], [au('1', '9000000001@phone.mouldtrack.invalid', future)], now);
    expect(out).toEqual(['1: active member is banned in Auth']);
  });
  it('reports a membership without an Auth user, and never prints phones or emails', () => {
    const out = findInconsistencies([mem('7', '+919000000007', 'active')], [], now);
    expect(out).toEqual(['7: membership has no Auth user']);
    expect(JSON.stringify(out)).not.toMatch(/9000000007|@/);
  });
  it('ignores Auth users that have no membership (orphan-check owns that)', () => {
    expect(findInconsistencies([], [au('9', 'x@y.invalid')], now)).toEqual([]);
  });
});
