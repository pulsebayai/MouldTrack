import { screen } from '@testing-library/react-native';
import { Text } from 'react-native';
import AppLayout from '@/app/(app)/_layout';
import { renderWithSession } from '@/test/render-with-session';

let mockPath = '/home';
jest.mock('expo-router', () => {
  const { Text: T } = jest.requireActual('react-native');
  return {
    Redirect: ({ href }: { href: string }) => <T testID="redirect">{href}</T>,
    Stack: () => <T testID="stack">stack</T>,
    usePathname: () => mockPath,
  };
});

const member = { user: { id: 'u', email: 'x' }, tenant: { name: 'A' }, role: 'supervisor' as const };
const forced = { user: { id: 'u', email: 'x' }, mustChangePassword: true as const, expired: false };
void Text;

describe('(app) layout guard', () => {
  it('lets a member through', async () => {
    mockPath = '/home';
    await renderWithSession(<AppLayout />, { ctx: member });
    expect(screen.getByTestId('stack')).toBeTruthy();
  });
  it('lets a member open /change-password', async () => {
    mockPath = '/change-password';
    await renderWithSession(<AppLayout />, { ctx: member });
    expect(screen.getByTestId('stack')).toBeTruthy();
  });
  it('sends signed-out users to sign-in', async () => {
    await renderWithSession(<AppLayout />, { ctx: null });
    expect(screen.getByTestId('redirect')).toHaveTextContent('/sign-in');
  });
  it('sends users without access to no-access', async () => {
    await renderWithSession(<AppLayout />, { ctx: { noAccess: true } });
    expect(screen.getByTestId('redirect')).toHaveTextContent('/no-access');
  });
  it.each(['/home', '/users', '/users/abc'])('forces a must-change user from %s to /change-password', async (path) => {
    mockPath = path;
    await renderWithSession(<AppLayout />, { ctx: forced });
    expect(screen.getByTestId('redirect')).toHaveTextContent('/change-password');
  });
  it('lets a must-change user stay on /change-password', async () => {
    mockPath = '/change-password';
    await renderWithSession(<AppLayout />, { ctx: forced });
    expect(screen.getByTestId('stack')).toBeTruthy();
    expect(screen.queryByTestId('redirect')).toBeNull();
  });
});
