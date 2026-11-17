import { routeFor } from '@/lib/session-provider';

describe('routeFor platform (03, AC-1)', () => {
  it('sends an active Super Admin to the console', () => expect(routeFor({ user: { id: 'u', email: 'x' }, platform: true })).toBe('/console'));
  it('a Super Admin with a temporary password goes to change-password first', () =>
    expect(routeFor({ user: { id: 'u', email: 'x' }, mustChangePassword: true, expired: false })).toBe('/change-password'));
});
