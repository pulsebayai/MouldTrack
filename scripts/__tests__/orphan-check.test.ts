import { ALLOWED_ORPHAN_EMAILS, findOrphans } from '../orphan-check';

const u = (id: string, email: string | null) => ({ id, email });

describe('orphan-check (D4 compensation proof)', () => {
  it('reports Auth users that have no membership', () => {
    const r = findOrphans([u('1', '9000000001@phone.mouldtrack.invalid'), u('2', '9000010001@phone.mouldtrack.invalid')], new Set(['1']));
    expect(r).toEqual(['9000010001@phone.mouldtrack.invalid']);
  });
  it('allows only the nomember fixture (9000000005) to be without a membership', () => {
    expect(ALLOWED_ORPHAN_EMAILS).toEqual(['9000000005@phone.mouldtrack.invalid']);
    expect(findOrphans([u('5', '9000000005@phone.mouldtrack.invalid')], new Set())).toEqual([]);
    expect(findOrphans([u('6', '9000000006@phone.mouldtrack.invalid')], new Set())).toEqual(['9000000006@phone.mouldtrack.invalid']);
  });
  it('reports users without an email too, without leaking ids as emails', () => {
    expect(findOrphans([u('abc', null)], new Set())).toEqual(['(no email) abc']);
  });
  it('is empty when every user is a member', () => expect(findOrphans([u('1', 'x@y.invalid')], new Set(['1']))).toEqual([]));
});
