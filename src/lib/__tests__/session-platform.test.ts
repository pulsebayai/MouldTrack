import { getPlatformContext, isPlatformAdmin, loadSessionContext, type SessionClient } from '@/lib/session';

type Table = 'membership' | 'platform_admin';
const calls: [Table, string, string][] = [];

function fakeClient(opts: { session?: boolean; membership?: unknown; platform?: unknown; platformError?: Error }): SessionClient {
  return {
    auth: { getSession: async () => ({ data: { session: opts.session === false ? null : { user: { id: 'sa1', email: '9000000090@phone.mouldtrack.invalid' } } }, error: null }) },
    from: (table: Table) => ({
      select: () => ({
        eq: (col: string, val: string) => {
          calls.push([table, col, val]);
          return {
            maybeSingle: async () =>
              table === 'membership'
                ? { data: opts.membership ?? null, error: null }
                : { data: opts.platform ?? null, error: opts.platformError ?? null },
          };
        },
      }),
    }),
  } as unknown as SessionClient;
}

const user = { id: 'sa1', email: '9000000090@phone.mouldtrack.invalid' };
const future = new Date(Date.now() + 3600_000).toISOString();
const past = new Date(Date.now() - 3600_000).toISOString();
beforeEach(() => (calls.length = 0));

describe('loadSessionContext (03, AC-1 / FR-4)', () => {
  it('a member never triggers a platform lookup', async () => {
    const ctx = await loadSessionContext(fakeClient({ membership: { role: 'supervisor', status: 'active', tenant: { name: 'A', status: 'active' } } }));
    expect(ctx).toEqual({ user, tenant: { name: 'A' }, role: 'supervisor' });
    expect(calls.map((c) => c[0])).toEqual(['membership']);
  });

  it('no membership but an active platform_admin row -> platform context (own row only)', async () => {
    const ctx = await loadSessionContext(fakeClient({ platform: { status: 'active', must_change_password: false, temp_password_expires_at: null } }));
    expect(ctx).toEqual({ user, platform: true });
    expect(isPlatformAdmin(ctx)).toBe(true);
    expect(calls).toContainEqual(['platform_admin', 'user_id', 'sa1']);
  });

  it('a Super Admin with a temporary password must change it first', async () => {
    expect(await loadSessionContext(fakeClient({ platform: { status: 'active', must_change_password: true, temp_password_expires_at: future } }))).toEqual({ user, mustChangePassword: true, expired: false });
    expect(await loadSessionContext(fakeClient({ platform: { status: 'active', must_change_password: true, temp_password_expires_at: past } }))).toMatchObject({ mustChangePassword: true, expired: true });
  });

  it('an inactive Super Admin, or a user in neither table, has no access', async () => {
    expect(await loadSessionContext(fakeClient({ platform: { status: 'inactive', must_change_password: false, temp_password_expires_at: null } }))).toEqual({ noAccess: true });
    expect(await loadSessionContext(fakeClient({}))).toEqual({ noAccess: true });
  });

  it('an inactive member is not looked up as a Super Admin of any use: still no access', async () => {
    const ctx = await loadSessionContext(fakeClient({ membership: { role: 'supervisor', status: 'inactive', tenant: { name: 'A', status: 'active' } } }));
    expect(ctx).toEqual({ noAccess: true });
  });

  it('signed-out stays null and queries nothing', async () => {
    expect(await loadSessionContext(fakeClient({ session: false }))).toBeNull();
    expect(calls).toEqual([]);
  });

  it('a failing platform lookup throws, so the UI can offer retry', async () => {
    await expect(loadSessionContext(fakeClient({ platformError: new Error('Failed to fetch') }))).rejects.toThrow('Failed to fetch');
  });

  it('getPlatformContext on its own returns null without a session', async () => {
    expect(await getPlatformContext(fakeClient({ session: false }))).toBeNull();
  });

  it('isPlatformAdmin is false for members, forced-change users and signed-out', () => {
    expect(isPlatformAdmin(null)).toBe(false);
    expect(isPlatformAdmin({ noAccess: true })).toBe(false);
    expect(isPlatformAdmin({ user, tenant: { name: 'A' }, role: 'unit_admin' })).toBe(false);
    expect(isPlatformAdmin({ user, mustChangePassword: true, expired: false })).toBe(false);
  });
});
