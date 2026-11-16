import { fireEvent, screen, waitFor } from '@testing-library/react-native';
import { TenantForm } from '@/components/console/tenant-form';
import * as platform from '@/lib/platform';
import { renderWithSession } from '@/test/render-with-session';

jest.mock('@/lib/platform', () => ({
  ...jest.requireActual('@/lib/platform'),
  platformApi: { tenantCreate: jest.fn(async () => ({ tenant_id: 'new1' })), tenantUpdate: jest.fn(async () => ({ ok: true })) },
}));
const api = (platform as unknown as { platformApi: Record<string, jest.Mock> }).platformApi;
beforeEach(() => jest.clearAllMocks());

describe('tenant form', () => {
  it('validates the name before calling the server', async () => {
    await renderWithSession(<TenantForm onDone={jest.fn()} onCancel={jest.fn()} />);
    await fireEvent.press(screen.getByTestId('tenant-save'));
    expect(screen.getByText('Enter a name of 1 to 80 characters')).toBeTruthy();
    expect(api.tenantCreate).not.toHaveBeenCalled();
  });
  it('registers a tenant with the chosen plan label', async () => {
    const onDone = jest.fn();
    await renderWithSession(<TenantForm onDone={onDone} onCancel={jest.fn()} />);
    await fireEvent.changeText(screen.getByTestId('tenant-name'), 'Acme Plastics');
    await fireEvent.press(screen.getByTestId('plan-active'));
    await fireEvent.press(screen.getByTestId('tenant-save'));
    await waitFor(() => expect(onDone).toHaveBeenCalledWith('new1'));
    expect(api.tenantCreate.mock.calls[0][1]).toEqual({ name: 'Acme Plastics', timezone: 'Asia/Kolkata', plan_label: 'active' });
  });
  it('an edit sends only what changed and refuses an empty change', async () => {
    const tenant = { id: 't1', name: 'Acme', status: 'active' as const, plan_label: 'trial' as const, timezone: 'Asia/Kolkata', created_at: '2026-11-01T00:00:00Z', suspended_reason: null };
    const onDone = jest.fn();
    await renderWithSession(<TenantForm tenant={tenant} onDone={onDone} onCancel={jest.fn()} />);
    await fireEvent.press(screen.getByTestId('tenant-save'));
    expect(screen.getByTestId('tenant-form-error')).toHaveTextContent(/No changes/);
    await fireEvent.changeText(screen.getByTestId('tenant-name'), 'Acme Ltd');
    await fireEvent.press(screen.getByTestId('tenant-save'));
    await waitFor(() => expect(onDone).toHaveBeenCalled());
    expect(api.tenantUpdate.mock.calls[0].slice(1, 3)).toEqual(['t1', { name: 'Acme Ltd' }]);
  });
});
