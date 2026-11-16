import { fireEvent, screen, waitFor } from '@testing-library/react-native';
import { Platform } from 'react-native';
import Home from '@/app/(app)/home';
import NoAccess from '@/app/no-access';
import { renderWithSession } from '@/test/render-with-session';

const mockPush = jest.fn();
jest.mock('expo-router', () => ({ router: { push: (...a: unknown[]) => mockPush(...a), replace: jest.fn() }, Redirect: () => null }));
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
    expect(screen.queryByTestId('test-error-sent')).toBeNull();
    await fireEvent.press(screen.getByTestId('send-test-error'));
    expect(sendTestError).toHaveBeenCalled();
    expect(screen.getByTestId('test-error-sent')).toHaveTextContent('Test error sent to Sentry');
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

describe('Home 02 entries', () => {
  const admin = { ...ctx, role: 'unit_admin' as const };
  beforeEach(() => mockPush.mockReset());

  it('every member can change their password from Home', async () => {
    await renderWithSession(<Home />, { ctx });
    await fireEvent.press(screen.getByTestId('change-password-link'));
    expect(mockPush).toHaveBeenCalledWith('/change-password');
  });

  it('a Unit Admin on web sees the Users entry', async () => {
    jest.replaceProperty(Platform, 'OS', 'web');
    await renderWithSession(<Home />, { ctx: admin });
    await fireEvent.press(screen.getByTestId('users-link'));
    expect(mockPush).toHaveBeenCalledWith('/users');
    jest.restoreAllMocks();
  });

  it('a supervisor sees no Users entry', async () => {
    jest.replaceProperty(Platform, 'OS', 'web');
    await renderWithSession(<Home />, { ctx });
    expect(screen.queryByTestId('users-link')).toBeNull();
    jest.restoreAllMocks();
  });

  it('a Unit Admin on a phone (not web) sees no Users entry: the screen is web-only in 02', async () => {
    jest.replaceProperty(Platform, 'OS', 'android');
    await renderWithSession(<Home />, { ctx: admin });
    expect(screen.queryByTestId('users-link')).toBeNull();
    jest.restoreAllMocks();
  });

  it('shows the phone number instead of the synthetic sign-in address', async () => {
    await renderWithSession(<Home />, { ctx: { ...ctx, user: { id: 'u1', email: '9876543210@phone.mouldtrack.invalid' } } });
    expect(screen.getByText('+91 9876543210')).toBeTruthy();
    expect(screen.queryByText(/mouldtrack\.invalid/)).toBeNull();
  });
});
