import { fireEvent, screen, waitFor } from '@testing-library/react-native';
import Home from '@/app/(app)/home';
import NoAccess from '@/app/no-access';
import { renderWithSession } from '@/test/render-with-session';

jest.mock('@/lib/sentry', () => ({ sendTestError: jest.fn() }));

const ctx = { user: { id: 'u1', email: 'e2e-sup-a@example.test' }, tenant: { name: 'e2e org A' }, role: 'supervisor' as const };

describe('Home screen', () => {
  it('shows tenant name, role as text, email (AC-1)', async () => {
    await renderWithSession(<Home />, { ctx });
    expect(screen.getByTestId('home-tenant')).toHaveTextContent('e2e org A');
    expect(screen.getByTestId('home-role')).toHaveTextContent(/Supervisor/);
    expect(screen.getByText('e2e-sup-a@example.test')).toBeTruthy();
  });

  it('shows an environment banner outside production', async () => {
    await renderWithSession(<Home />, { ctx, appEnv: 'development' });
    expect(screen.getByTestId('env-banner')).toHaveTextContent(/DEV/);
  });

  it('hides the environment banner in production', async () => {
    await renderWithSession(<Home />, { ctx, appEnv: 'production' });
    expect(screen.queryByTestId('env-banner')).toBeNull();
  });

  it('signs out and refreshes the session (AC-3)', async () => {
    const { value } = await renderWithSession(<Home />, { ctx });
    await fireEvent.press(screen.getByTestId('sign-out'));
    await waitFor(() => expect(value.client.auth.signOut).toHaveBeenCalled());
    await waitFor(() => expect(value.refresh).toHaveBeenCalled());
  });
});

describe('Sentry test button (AC-13)', () => {
  it('is shown only in development and reports a test error', async () => {
    const { sendTestError } = jest.requireMock('@/lib/sentry');
    await renderWithSession(<Home />, { ctx, appEnv: 'development' });
    await fireEvent.press(screen.getByTestId('send-test-error'));
    expect(sendTestError).toHaveBeenCalled();
  });
  it.each(['local', 'staging', 'production'] as const)('is hidden in %s', async (appEnv) => {
    await renderWithSession(<Home />, { ctx, appEnv });
    expect(screen.queryByTestId('send-test-error')).toBeNull();
  });
});

describe('No-access screen (AC-4)', () => {
  it('explains and offers sign-out, with no tenant data', async () => {
    const { value } = await renderWithSession(<NoAccess />, { ctx: { noAccess: true } });
    expect(screen.getByTestId('no-access')).toHaveTextContent('No access — contact your administrator');
    await fireEvent.press(screen.getByTestId('sign-out'));
    await waitFor(() => expect(value.client.auth.signOut).toHaveBeenCalled());
  });
});
