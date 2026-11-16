import { getSessionContext, roleLabel, type SessionClient } from '@/lib/session';

type Row = { role: string; status: string; must_change_password?: boolean; temp_password_expires_at?: string | null; tenant: { name: string; status: string } | null } | null;

const eqCalls: [string, string][] = [];

function fakeClient(opts: { session?: { user: { id: string; email?: string } } | null; row?: Row; error?: Error }): SessionClient {
  return {
    auth: { getSession: async () => ({ data: { session: opts.session ?? null }, error: null }) },
    from: () => ({
      select: () => ({
        eq: (col: string, val: string) => {
          eqCalls.push([col, val]);
          return { maybeSingle: async () => ({ data: opts.row ?? null, error: opts.error ?? null }) };
        },
      }),
    }),
  } as unknown as SessionClient;
}

const user = { id: 'u1', email: 'e2e-sup-a@example.test' };

describe('getSessionContext', () => {
  it('asks only for the caller\'s own membership row (a Unit Admin can read the whole tenant)', async () => {
    eqCalls.length = 0;
    await getSessionContext(fakeClient({ session: { user }, row: null }));
    expect(eqCalls).toEqual([['user_id', 'u1']]);
  });

  it('returns null when there is no session (AC-3)', async () => {
    expect(await getSessionContext(fakeClient({ session: null }))).toBeNull();
  });

  it('returns user, tenant and role for an active membership (AC-1)', async () => {
    const ctx = await getSessionContext(
      fakeClient({ session: { user }, row: { role: 'supervisor', status: 'active', tenant: { name: 'e2e org A', status: 'active' } } }),
    );
    expect(ctx).toEqual({ user: { id: 'u1', email: 'e2e-sup-a@example.test' }, tenant: { name: 'e2e org A' }, role: 'supervisor' });
  });

  it.each<[string, Row]>([
    ['no membership row', null],
    ['inactive membership', { role: 'supervisor', status: 'inactive', tenant: { name: 'A', status: 'active' } }],
    ['suspended tenant (tenant hidden by RLS)', { role: 'supervisor', status: 'active', tenant: null }],
    ['suspended tenant (status visible)', { role: 'supervisor', status: 'active', tenant: { name: 'S', status: 'suspended' } }],
  ])('returns noAccess for %s (AC-4)', async (_label, row) => {
    expect(await getSessionContext(fakeClient({ session: { user }, row }))).toEqual({ noAccess: true });
  });

  it('throws when the membership query fails, so the UI can offer retry', async () => {
    await expect(getSessionContext(fakeClient({ session: { user }, error: new Error('Failed to fetch') }))).rejects.toThrow('Failed to fetch');
  });
});

describe('roleLabel', () => {
  it('maps roles to text labels (status never by colour alone)', () => {
    expect(roleLabel('unit_admin')).toBe('Unit Admin');
    expect(roleLabel('supervisor')).toBe('Supervisor');
    expect(roleLabel('maintenance')).toBe('Maintenance');
  });
});

describe('getSessionContext must-change-password state (02, AC-3)', () => {
  const future = new Date(Date.now() + 3600_000).toISOString();
  const past = new Date(Date.now() - 3600_000).toISOString();

  it('reports mustChangePassword before looking at the tenant (which RLS hides until the change is done)', async () => {
    const ctx = await getSessionContext(
      fakeClient({ session: { user }, row: { role: 'supervisor', status: 'active', must_change_password: true, temp_password_expires_at: future, tenant: null } }),
    );
    expect(ctx).toEqual({ user: { id: 'u1', email: 'e2e-sup-a@example.test' }, mustChangePassword: true, expired: false });
  });

  it('flags an expired temporary password', async () => {
    const ctx = await getSessionContext(
      fakeClient({ session: { user }, row: { role: 'supervisor', status: 'active', must_change_password: true, temp_password_expires_at: past, tenant: null } }),
    );
    expect(ctx).toMatchObject({ mustChangePassword: true, expired: true });
  });

  it('treats a must-change user without an expiry as not expired', async () => {
    const ctx = await getSessionContext(
      fakeClient({ session: { user }, row: { role: 'supervisor', status: 'active', must_change_password: true, temp_password_expires_at: null, tenant: null } }),
    );
    expect(ctx).toMatchObject({ mustChangePassword: true, expired: false });
  });

  it('an inactive must-change user has no access', async () => {
    const ctx = await getSessionContext(
      fakeClient({ session: { user }, row: { role: 'supervisor', status: 'inactive', must_change_password: true, temp_password_expires_at: future, tenant: null } }),
    );
    expect(ctx).toEqual({ noAccess: true });
  });

  it('a normal member (flag false) still gets the tenant context', async () => {
    const ctx = await getSessionContext(
      fakeClient({ session: { user }, row: { role: 'unit_admin', status: 'active', must_change_password: false, tenant: { name: 'A', status: 'active' } } }),
    );
    expect(ctx).toEqual({ user: { id: 'u1', email: 'e2e-sup-a@example.test' }, tenant: { name: 'A' }, role: 'unit_admin' });
  });
});
