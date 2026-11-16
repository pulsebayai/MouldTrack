import { screen } from '@testing-library/react-native';
import AppLayout from '@/app/(app)/_layout';
import ConsoleLayout from '@/app/(console)/_layout';
import { renderWithSession } from '@/test/render-with-session';

let mockPath = '/console';
jest.mock('expo-router', () => {
  const { Text: T, View: V } = jest.requireActual('react-native');
  return {
    Redirect: ({ href }: { href: string }) => <T testID="redirect">{href}</T>,
    Stack: () => <T testID="stack">stack</T>,
    Slot: () => <V testID="slot" />,
    usePathname: () => mockPath,
    router: { push: jest.fn(), replace: jest.fn() },
  };
});

const user = { id: 'u', email: 'x' };
const platform = { user, platform: true as const };
const member = { user, tenant: { name: 'A' }, role: 'unit_admin' as const };
const forced = { user, mustChangePassword: true as const, expired: false };

describe('(app) layout with a Super Admin (AC-1)', () => {
  it.each(['/home', '/users', '/users/abc', '/plant'])('sends a Super Admin away from %s to the console', async (path) => {
    mockPath = path;
    await renderWithSession(<AppLayout />, { ctx: platform });
    expect(screen.getByTestId('redirect')).toHaveTextContent('/console');
  });
  it('lets a Super Admin open /change-password', async () => {
    mockPath = '/change-password';
    await renderWithSession(<AppLayout />, { ctx: platform });
    expect(screen.getByTestId('stack')).toBeTruthy();
    expect(screen.queryByTestId('redirect')).toBeNull();
  });
});

describe('(console) layout guard', () => {
  it('lets a Super Admin in and shows the console navigation', async () => {
    mockPath = '/console';
    await renderWithSession(<ConsoleLayout />, { ctx: platform });
    expect(screen.getByTestId('slot')).toBeTruthy();
    for (const id of ['nav-tenants', 'nav-admins', 'nav-audit', 'nav-password', 'sign-out']) expect(screen.getByTestId(id)).toBeTruthy();
  });
  it('sends a tenant member home', async () => {
    await renderWithSession(<ConsoleLayout />, { ctx: member });
    expect(screen.getByTestId('redirect')).toHaveTextContent('/home');
    expect(screen.queryByTestId('slot')).toBeNull();
  });
  it('sends signed-out users to sign-in, no-access users to no-access, forced-change users to change-password', async () => {
    await renderWithSession(<ConsoleLayout />, { ctx: null });
    expect(screen.getByTestId('redirect')).toHaveTextContent('/sign-in');
  });
  it('no-access', async () => {
    await renderWithSession(<ConsoleLayout />, { ctx: { noAccess: true } });
    expect(screen.getByTestId('redirect')).toHaveTextContent('/no-access');
  });
  it('forced change', async () => {
    await renderWithSession(<ConsoleLayout />, { ctx: forced });
    expect(screen.getByTestId('redirect')).toHaveTextContent('/change-password');
  });
  it('navigation targets are 48dp', async () => {
    await renderWithSession(<ConsoleLayout />, { ctx: platform });
    for (const id of ['nav-tenants', 'nav-admins', 'nav-audit', 'nav-password']) expect(screen.getByTestId(id)).toHaveStyle({ minHeight: 48 });
  });
});
