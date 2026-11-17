import { actionText, adminStatusText, fetchPlatformAudit, fetchSuperAdmins, fetchTenant, fetchTenantSummaries, fetchTenantUnitAdmins, platformApi } from '@/lib/platform';

const rpcCalls: [string, Record<string, unknown> | undefined][] = [];
function readClient(rpcData: unknown, error: unknown = null) {
  return {
    rpc: (fn: string, args?: Record<string, unknown>) => {
      rpcCalls.push([fn, args]);
      return Promise.resolve({ data: rpcData, error });
    },
    from: (table: string) => ({
      select: (cols: string) => ({ eq: (c: string, v: string) => ({ maybeSingle: async () => ({ data: { table, cols, c, v }, error: null }) }) }),
    }),
  } as never;
}
beforeEach(() => (rpcCalls.length = 0));

const summary = (i: number, total: number) => ({
  id: `t${i}`, name: `Tenant ${i}`, status: 'active', plan_label: 'trial', timezone: 'Asia/Kolkata', created_at: '2026-11-17T00:00:00Z',
  active_users: 3, active_unit_admins: 1, total_count: String(total),
});

describe('platform reads', () => {
  it('tenant summaries pass filters through, drop "all", strip total_count and return the total as a number', async () => {
    const r = await fetchTenantSummaries(readClient([summary(1, 40), summary(2, 40)]), { search: ' acme ', status: 'all', plan: 'trial', page: 2 });
    expect(rpcCalls[0]).toEqual(['pa_tenant_summaries', { p_search: 'acme', p_status: null, p_plan: 'trial', p_page: 2 }]);
    expect(r.total).toBe(40);
    expect(r.rows).toHaveLength(2);
    expect(r.rows[0]).not.toHaveProperty('total_count');
    expect(r.rows[0]).toMatchObject({ name: 'Tenant 1', active_users: 3 });
  });
  it('an empty page has total 0; an empty search becomes null', async () => {
    const r = await fetchTenantSummaries(readClient([]), { search: '  ', status: 'suspended', plan: 'all', page: 0 });
    expect(r).toEqual({ rows: [], total: 0 });
    expect(rpcCalls[0][1]).toMatchObject({ p_search: null, p_status: 'suspended', p_plan: null });
  });
  it('read errors are thrown for the UI to show', async () => {
    await expect(fetchTenantSummaries(readClient(null, { message: 'x' }), { search: '', status: 'all', plan: 'all', page: 0 })).rejects.toEqual({ message: 'x' });
    await expect(fetchSuperAdmins(readClient(null, { message: 'x' }))).rejects.toEqual({ message: 'x' });
    await expect(fetchTenantUnitAdmins(readClient(null, { message: 'x' }), 't')).rejects.toEqual({ message: 'x' });
    await expect(fetchPlatformAudit(readClient(null, { message: 'x' }), 0)).rejects.toEqual({ message: 'x' });
  });
  it('unit admins, super admins and the audit call their functions', async () => {
    await fetchTenantUnitAdmins(readClient([]), 'tid');
    await fetchSuperAdmins(readClient([]));
    const a = await fetchPlatformAudit(readClient([{ id: 'e', occurred_at: 'now', action: 'tenant.created', actor_name: 'SA', tenant_id: 't', tenant_name: 'T', entity_type: 'tenant', reason: null, source: 'edge:platform', total_count: 51 }]), 1);
    expect(rpcCalls.map((c) => c[0])).toEqual(['pa_tenant_unit_admins', 'pa_super_admins', 'pa_audit']);
    expect(rpcCalls[0][1]).toEqual({ p_tenant: 'tid' });
    expect(rpcCalls[2][1]).toEqual({ p_page: 1 });
    expect(a.total).toBe(51);
  });
  it('fetchTenant reads the tenant row by id', async () => {
    expect(await fetchTenant(readClient([]), 'tid')).toMatchObject({ table: 'tenant', c: 'id', v: 'tid' });
  });
});

describe('platformApi', () => {
  const fetchImpl = jest.fn(async (_url: string, init?: { body?: string }) => ({ ok: true, status: 200, json: async () => JSON.parse(init!.body!) }) as unknown as Response);
  const deps = { baseUrl: 'http://x', anonKey: 'k', fetchImpl: fetchImpl as unknown as typeof fetch };
  const client = { auth: { getSession: async () => ({ data: { session: { access_token: 'jwt' } } }) } } as never;
  beforeEach(() => fetchImpl.mockClear());
  const sent = () => JSON.parse(fetchImpl.mock.calls[0][1]!.body!);

  it('every action posts to the platform function with its request id', async () => {
    await platformApi.tenantCreate(client, { name: 'A', timezone: 'Asia/Kolkata', plan_label: 'trial' }, 'r1', deps);
    expect(fetchImpl.mock.calls[0][0]).toBe('http://x/functions/v1/platform');
    expect(sent()).toEqual({ action: 'tenant_create', request_id: 'r1', name: 'A', timezone: 'Asia/Kolkata', plan_label: 'trial' });
    fetchImpl.mockClear();
    await platformApi.tenantUpdate(client, 't', { plan_label: 'active' }, 'r2', deps);
    expect(sent()).toEqual({ action: 'tenant_update', request_id: 'r2', tenant_id: 't', plan_label: 'active' });
    fetchImpl.mockClear();
    await platformApi.tenantSetStatus(client, 't', 'suspended', 'Unpaid', 'r3', deps);
    expect(sent()).toEqual({ action: 'tenant_set_status', request_id: 'r3', tenant_id: 't', status: 'suspended', reason: 'Unpaid' });
    fetchImpl.mockClear();
    await platformApi.tenantSetStatus(client, 't', 'active', null, 'r4', deps);
    expect(sent()).toEqual({ action: 'tenant_set_status', request_id: 'r4', tenant_id: 't', status: 'active' });
    fetchImpl.mockClear();
    await platformApi.uaCreate(client, 't', { full_name: 'N', employee_id: 'E1', phone: '+919876543210' }, 'r5', deps);
    expect(sent()).toEqual({ action: 'ua_create', request_id: 'r5', tenant_id: 't', full_name: 'N', employee_id: 'E1', phone: '+919876543210' });
    fetchImpl.mockClear();
    await platformApi.uaResetPassword(client, 'u', 'r6', deps);
    expect(sent()).toEqual({ action: 'ua_reset_password', request_id: 'r6', user_id: 'u' });
    fetchImpl.mockClear();
    await platformApi.saCreate(client, { full_name: 'N', phone: '+919876543210' }, 'r7', deps);
    expect(sent()).toEqual({ action: 'sa_create', request_id: 'r7', full_name: 'N', phone: '+919876543210' });
    fetchImpl.mockClear();
    await platformApi.saSetStatus(client, 'u', 'inactive', 'r8', deps);
    expect(sent()).toEqual({ action: 'sa_set_status', request_id: 'r8', user_id: 'u', status: 'inactive' });
    fetchImpl.mockClear();
    await platformApi.saResetPassword(client, 'u', 'r9', deps);
    expect(sent()).toEqual({ action: 'sa_reset_password', request_id: 'r9', user_id: 'u' });
  });
});

describe('labels', () => {
  it('shows status as text', () => {
    expect(adminStatusText({ status: 'inactive', must_change_password: false })).toBe('Inactive');
    expect(adminStatusText({ status: 'active', must_change_password: true })).toBe('Must change password');
    expect(adminStatusText({ status: 'active', must_change_password: false })).toBe('Active');
  });
  it('names audit actions in words and falls back to the raw action', () => {
    expect(actionText('tenant.suspended')).toBe('Tenant suspended');
    expect(actionText('something.new')).toBe('something.new');
  });
});
