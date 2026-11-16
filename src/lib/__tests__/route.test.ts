import { routeFor } from '@/lib/session-provider';

describe('routeFor (guard, AC-3/AC-4)', () => {
  it('sends signed-out users to sign-in', () => expect(routeFor(null)).toBe('/sign-in'));
  it('sends users without access to no-access', () => expect(routeFor({ noAccess: true })).toBe('/no-access'));
  it('sends members home', () =>
    expect(routeFor({ user: { id: 'u', email: 'x' }, tenant: { name: 'A' }, role: 'unit_admin' })).toBe('/home'));
});

describe('routeFor must-change state (02, AC-3)', () => {
  it('sends users who must change their password to /change-password', () => {
    expect(routeFor({ user: { id: 'u', email: 'x' }, mustChangePassword: true, expired: false })).toBe('/change-password');
    expect(routeFor({ user: { id: 'u', email: 'x' }, mustChangePassword: true, expired: true })).toBe('/change-password');
  });
});
