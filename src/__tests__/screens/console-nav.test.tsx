import { screen } from '@testing-library/react-native';
import ConsoleLayout from '@/app/(console)/_layout';
import { renderWithSession } from '@/test/render-with-session';

let mockPath = '/console';
jest.mock('expo-router', () => {
  const { Text: T, View: V } = jest.requireActual('react-native');
  return {
    Redirect: ({ href }: { href: string }) => <T testID="redirect">{href}</T>,
    Slot: () => <V testID="slot" />,
    usePathname: () => mockPath,
    router: { push: jest.fn(), replace: jest.fn() },
  };
});
const ctx = { user: { id: 'u', email: 'x' }, platform: true as const };

describe('console navigation marks the current page (03 N-5)', () => {
  it.each([
    ['/console', 'nav-tenants'],
    ['/console/tenants/abc', 'nav-tenants'],
    ['/console/admins', 'nav-admins'],
    ['/console/audit', 'nav-audit'],
  ])('on %s only %s is selected, by state and by text', async (path, id) => {
    mockPath = path;
    await renderWithSession(<ConsoleLayout />, { ctx });
    for (const nav of ['nav-tenants', 'nav-admins', 'nav-audit', 'nav-password']) {
      const el = screen.getByTestId(nav);
      expect(el.props.accessibilityState?.selected ?? false).toBe(nav === id);
    }
    expect(screen.getAllByText('Current page')).toHaveLength(1);
    expect(screen.getByTestId(`${id}-current`)).toBeTruthy();
  });
});
