import { fireEvent, screen, waitFor } from '@testing-library/react-native';
import Admins from '@/app/(console)/console/admins';
import Audit from '@/app/(console)/console/audit';
import Tenants from '@/app/(console)/console/index';
import TenantDetail from '@/app/(console)/console/tenants/[id]';
import * as platform from '@/lib/platform';
import { renderWithSession } from '@/test/render-with-session';

jest.mock('expo-router', () => ({
  router: { push: jest.fn(), replace: jest.fn() },
  useLocalSearchParams: () => ({ id: 't1' }),
}));
jest.mock('@/lib/platform', () => {
  const actual = jest.requireActual('@/lib/platform');
  return {
    ...actual,
    fetchTenantSummaries: jest.fn(),
    fetchTenant: jest.fn(),
    fetchTenantUnitAdmins: jest.fn(),
    fetchSuperAdmins: jest.fn(),
    fetchPlatformAudit: jest.fn(),
    platformApi: {
      tenantSetStatus: jest.fn(async () => ({ ok: true })),
      uaResetPassword: jest.fn(async () => ({ temp_password: 'Abcdef123456' })),
      saSetStatus: jest.fn(async () => ({ ok: true })),
      saResetPassword: jest.fn(async () => ({ temp_password: 'Zyxwvu654321' })),
    },
  };
});

const m = platform as unknown as Record<string, jest.Mock> & { platformApi: Record<string, jest.Mock> };
const ctx = { user: { id: 'sa1', email: 'x' }, platform: true as const };
const tenant = (i: number, over = {}) => ({
  id: `t${i}`, name: `Tenant ${i}`, status: 'active', plan_label: 'trial', timezone: 'Asia/Kolkata',
  created_at: '2026-11-01T00:00:00Z', active_users: 3, active_unit_admins: 1, ...over,
});

beforeEach(() => jest.clearAllMocks());

describe('tenants list', () => {
  it('shows status and plan as text, with a row per tenant', async () => {
    m.fetchTenantSummaries.mockResolvedValue({ rows: [tenant(1), tenant(2, { status: 'suspended', plan_label: 'active' })], total: 2 });
    await renderWithSession(<Tenants />, { ctx });
    await waitFor(() => expect(screen.getByTestId('tenant-row-t1')).toBeTruthy());
    expect(screen.getByTestId('tenant-status-t2')).toHaveTextContent('Suspended');
    expect(screen.getByTestId('tenant-plan-t2')).toHaveTextContent(/Active plan/);
  });
  it('passes search and filters to the server and pages 25 at a time', async () => {
    m.fetchTenantSummaries.mockResolvedValue({ rows: [tenant(1)], total: 60 });
    await renderWithSession(<Tenants />, { ctx });
    await waitFor(() => expect(screen.getByTestId('tenants-page')).toHaveTextContent('Page 1 of 3'));
    await fireEvent.press(screen.getByTestId('tenants-next'));
    await waitFor(() => expect(m.fetchTenantSummaries.mock.calls.at(-1)![1]).toMatchObject({ page: 1 }));
    await fireEvent.press(screen.getByTestId('tenants-filter-status-suspended'));
    await waitFor(() => expect(m.fetchTenantSummaries.mock.calls.at(-1)![1]).toMatchObject({ status: 'suspended', page: 0 }));
    await fireEvent.changeText(screen.getByTestId('tenants-search'), 'acme');
    await waitFor(() => expect(m.fetchTenantSummaries.mock.calls.at(-1)![1]).toMatchObject({ search: 'acme' }));
  });
  it('shows empty and error states', async () => {
    m.fetchTenantSummaries.mockResolvedValue({ rows: [], total: 0 });
    await renderWithSession(<Tenants />, { ctx });
    await waitFor(() => expect(screen.getByTestId('tenants-empty')).toBeTruthy());
  });
  it('shows an error with retry', async () => {
    m.fetchTenantSummaries.mockRejectedValueOnce(new TypeError('Failed to fetch')).mockResolvedValue({ rows: [tenant(1)], total: 1 });
    await renderWithSession(<Tenants />, { ctx });
    await waitFor(() => expect(screen.getByTestId('tenants-error')).toBeTruthy());
    await fireEvent.press(screen.getByTestId('tenants-retry'));
    await waitFor(() => expect(screen.getByTestId('tenant-row-t1')).toBeTruthy());
  });
});

describe('tenant detail', () => {
  const detail = (over = {}) => ({ id: 't1', name: 'Tenant 1', status: 'active', plan_label: 'trial', timezone: 'Asia/Kolkata', created_at: '2026-11-01T00:00:00Z', suspended_reason: null, ...over });
  const ua = { user_id: 'u1', full_name: 'Asha Rao', phone_masked: '+91******0001', status: 'active', must_change_password: false };

  it('requires a reason to suspend, then calls the server', async () => {
    m.fetchTenant.mockResolvedValue(detail());
    m.fetchTenantUnitAdmins.mockResolvedValue([ua]);
    await renderWithSession(<TenantDetail />, { ctx });
    await waitFor(() => expect(screen.getByTestId('tenant-suspend')).toBeTruthy());
    await fireEvent.press(screen.getByTestId('tenant-suspend'));
    await fireEvent.press(screen.getByTestId('suspend-confirm'));
    expect(m.platformApi.tenantSetStatus).not.toHaveBeenCalled();
    await fireEvent.changeText(screen.getByTestId('suspend-reason'), 'Unpaid invoice');
    await fireEvent.press(screen.getByTestId('suspend-confirm'));
    await waitFor(() => expect(m.platformApi.tenantSetStatus).toHaveBeenCalled());
    expect(m.platformApi.tenantSetStatus.mock.calls[0].slice(1, 4)).toEqual(['t1', 'suspended', 'Unpaid invoice']);
  });
  it('activates a suspended tenant after confirmation and shows the reason', async () => {
    m.fetchTenant.mockResolvedValue(detail({ status: 'suspended', suspended_reason: 'Unpaid invoice' }));
    m.fetchTenantUnitAdmins.mockResolvedValue([]);
    await renderWithSession(<TenantDetail />, { ctx });
    await waitFor(() => expect(screen.getByTestId('tenant-detail-reason')).toHaveTextContent(/Unpaid invoice/));
    expect(screen.getByTestId('ua-empty')).toBeTruthy();
    await fireEvent.press(screen.getByTestId('tenant-activate'));
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    await waitFor(() => expect(m.platformApi.tenantSetStatus).toHaveBeenCalled());
    expect(m.platformApi.tenantSetStatus.mock.calls[0].slice(1, 3)).toEqual(['t1', 'active']);
  });
  it('lists Unit Admins and shows a reset password once', async () => {
    m.fetchTenant.mockResolvedValue(detail());
    m.fetchTenantUnitAdmins.mockResolvedValue([ua]);
    await renderWithSession(<TenantDetail />, { ctx });
    await waitFor(() => expect(screen.getByTestId('ua-name-u1')).toHaveTextContent(/Asha Rao/));
    await fireEvent.press(screen.getByTestId('ua-reset-u1'));
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    await waitFor(() => expect(screen.getByText('Abcdef123456')).toBeTruthy());
  });
  it('says so when the tenant is not found', async () => {
    m.fetchTenant.mockResolvedValue(null);
    m.fetchTenantUnitAdmins.mockResolvedValue([]);
    await renderWithSession(<TenantDetail />, { ctx });
    await waitFor(() => expect(screen.getByTestId('tenant-not-found')).toBeTruthy());
  });
});

describe('super admins', () => {
  const rows = [
    { user_id: 'sa1', full_name: 'Me', phone_masked: '+91******0090', status: 'active', must_change_password: false, is_self: true },
    { user_id: 'sa2', full_name: 'Other', phone_masked: '+91******0091', status: 'active', must_change_password: false, is_self: false },
  ];
  it('offers no actions on your own row', async () => {
    m.fetchSuperAdmins.mockResolvedValue(rows);
    await renderWithSession(<Admins />, { ctx });
    await waitFor(() => expect(screen.getByTestId('admin-row-sa1')).toBeTruthy());
    expect(screen.queryByTestId('admin-toggle-sa1')).toBeNull();
    expect(screen.queryByTestId('admin-reset-sa1')).toBeNull();
    expect(screen.getByTestId('admin-toggle-sa2')).toBeTruthy();
  });
  it('deactivates another Super Admin after confirmation', async () => {
    m.fetchSuperAdmins.mockResolvedValue(rows);
    await renderWithSession(<Admins />, { ctx });
    await waitFor(() => expect(screen.getByTestId('admin-toggle-sa2')).toBeTruthy());
    await fireEvent.press(screen.getByTestId('admin-toggle-sa2'));
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    await waitFor(() => expect(m.platformApi.saSetStatus).toHaveBeenCalled());
    expect(m.platformApi.saSetStatus.mock.calls[0].slice(1, 3)).toEqual(['sa2', 'inactive']);
  });
  it('shows a server error message', async () => {
    m.fetchSuperAdmins.mockResolvedValue(rows);
    const { ApiError } = jest.requireActual('@/lib/api');
    m.platformApi.saSetStatus.mockRejectedValueOnce(new ApiError(409, 'last_super_admin', 'At least one Super Admin must stay active'));
    await renderWithSession(<Admins />, { ctx });
    await waitFor(() => expect(screen.getByTestId('admin-toggle-sa2')).toBeTruthy());
    await fireEvent.press(screen.getByTestId('admin-toggle-sa2'));
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    await waitFor(() => expect(screen.getByTestId('admins-action-error')).toHaveTextContent(/At least one Super Admin/));
  });
});

describe('platform audit', () => {
  it('lists events with who, action, tenant, time and reason', async () => {
    m.fetchPlatformAudit.mockResolvedValue({
      total: 1,
      rows: [{ id: 'e1', occurred_at: '2026-11-17T09:30:00Z', action: 'tenant.suspended', actor_name: 'Me', tenant_id: 't1', tenant_name: 'Tenant 1', entity_type: 'tenant', reason: 'Unpaid invoice', source: 'edge:platform' }],
    });
    await renderWithSession(<Audit />, { ctx });
    await waitFor(() => expect(screen.getByTestId('audit-row-e1')).toBeTruthy());
    expect(screen.getByTestId('audit-who-e1')).toHaveTextContent(/Me/);
    expect(screen.getByTestId('audit-tenant-e1')).toHaveTextContent(/Tenant 1/);
    expect(screen.getByTestId('audit-when-e1')).toHaveTextContent(/2026-11-17 09:30 UTC/);
    expect(screen.getByTestId('audit-reason-e1')).toHaveTextContent(/Unpaid invoice/);
  });
  it('shows an empty state', async () => {
    m.fetchPlatformAudit.mockResolvedValue({ rows: [], total: 0 });
    await renderWithSession(<Audit />, { ctx });
    await waitFor(() => expect(screen.getByTestId('audit-empty')).toBeTruthy());
  });
});
