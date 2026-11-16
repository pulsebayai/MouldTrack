import { PAGE_SIZE, fetchUsers, sanitiseSearch, statusLabel, type UserRow } from '@/lib/users';
import { fakeDb } from '@/test/fake-db';

const row = (over: Partial<UserRow> = {}): UserRow => ({
  user_id: 'u1', full_name: 'Asha Rao', employee_id: 'E-1', phone_e164: '+919876543210', role: 'supervisor', status: 'active', must_change_password: false, ...over,
});

describe('statusLabel (status is text, AC-14)', () => {
  it('labels Active, Inactive and Must change password', () => {
    expect(statusLabel(row())).toBe('Active');
    expect(statusLabel(row({ status: 'inactive' }))).toBe('Inactive');
    expect(statusLabel(row({ must_change_password: true }))).toBe('Must change password');
  });
  it('inactive wins over must-change', () => {
    expect(statusLabel(row({ status: 'inactive', must_change_password: true }))).toBe('Inactive');
  });
});

describe('sanitiseSearch', () => {
  it('trims and removes characters that would break the PostgREST filter', () => {
    expect(sanitiseSearch('  asha  ')).toBe('asha');
    expect(sanitiseSearch('a,b(c)d%e*f\\g"h')).toBe('abcdefgh');
    expect(sanitiseSearch('   ')).toBe('');
  });
});

describe('fetchUsers', () => {
  const run = async (args: Partial<Parameters<typeof fetchUsers>[1]> = {}) => {
    const db = fakeDb(() => ({ data: [row()], count: 60, error: null }));
    const out = await fetchUsers(db.client as never, { search: '', role: 'all', status: 'all', page: 0, ...args });
    return { out, q: db.queries[0] };
  };

  it('pages 25 at a time, ordered by name, with an exact count', async () => {
    expect(PAGE_SIZE).toBe(25);
    const { out, q } = await run({ page: 2 });
    expect(q.table).toBe('membership');
    expect(q.select?.[1]).toEqual({ count: 'exact' });
    expect(q.range).toEqual([50, 74]);
    expect(q.order).toEqual(['full_name', { ascending: true }]);
    expect(out).toEqual({ rows: [row()], total: 60 });
  });

  it('adds no filters by default', async () => {
    const { q } = await run();
    expect(q.filters).toEqual([]);
  });

  it('searches name, employee id and phone', async () => {
    const { q } = await run({ search: ' ash,a ' });
    expect(q.filters).toEqual([['or', 'full_name.ilike.%asha%,employee_id.ilike.%asha%,phone_e164.ilike.%asha%']]);
  });

  it('filters by role', async () => {
    const { q } = await run({ role: 'unit_admin' });
    expect(q.filters).toEqual([['eq', 'role', 'unit_admin']]);
  });

  it.each([
    ['active', [['eq', 'status', 'active'], ['eq', 'must_change_password', false]]],
    ['inactive', [['eq', 'status', 'inactive']]],
    ['must_change', [['eq', 'status', 'active'], ['eq', 'must_change_password', true]]],
  ] as const)('filters by status %s', async (status, expected) => {
    const { q } = await run({ status });
    expect(q.filters).toEqual(expected);
  });

  it('throws the database error so the screen can offer retry', async () => {
    const db = fakeDb(() => ({ data: null, count: null, error: new Error('Failed to fetch') }));
    await expect(fetchUsers(db.client as never, { search: '', role: 'all', status: 'all', page: 0 })).rejects.toThrow('Failed to fetch');
  });
});
