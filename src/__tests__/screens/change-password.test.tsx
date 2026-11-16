import { fireEvent, screen, waitFor } from '@testing-library/react-native';
import ChangePassword from '@/app/(app)/change-password';
import { ApiError } from '@/lib/api';
import { renderWithSession } from '@/test/render-with-session';

const mockReplace = jest.fn();
jest.mock('expo-router', () => ({ router: { replace: (...a: unknown[]) => mockReplace(...a) }, Redirect: () => null }));
const mockChange = jest.fn();
jest.mock('@/lib/api', () => {
  const actual = jest.requireActual('@/lib/api');
  return { ...actual, accountApi: { changePassword: (...a: unknown[]) => mockChange(...a) } };
});

const forced = { user: { id: 'u4', email: '9000000009@phone.mouldtrack.invalid' }, mustChangePassword: true as const, expired: false };
const member = { user: { id: 'u3', email: '9000000008@phone.mouldtrack.invalid' }, tenant: { name: 'e2e org U' }, role: 'supervisor' as const };

async function fillForm(current = 'Temp-pass-1234', next = 'Brand-new-77x', confirm = next) {
  await fireEvent.changeText(screen.getByLabelText('Current password'), current);
  await fireEvent.changeText(screen.getByLabelText('New password'), next);
  await fireEvent.changeText(screen.getByLabelText('Confirm new password'), confirm);
}

beforeEach(() => {
  mockReplace.mockReset();
  mockChange.mockReset();
});

describe('Change password screen (AC-3, AC-13)', () => {
  it('has labelled fields with Show/Hide controls and a 48dp submit', async () => {
    await renderWithSession(<ChangePassword />, { ctx: forced });
    for (const l of ['Current password', 'New password', 'Confirm new password']) expect(screen.getByLabelText(l)).toBeTruthy();
    expect(screen.getByLabelText('Show new password')).toHaveStyle({ minHeight: 48 });
    expect(screen.getByTestId('change-password-submit')).toHaveStyle({ minHeight: 48 });
  });

  it('shows a live policy checklist as text, not colour', async () => {
    await renderWithSession(<ChangePassword />, { ctx: forced });
    expect(screen.getByTestId('rule-length')).toHaveTextContent('At least 10 characters: Not met');
    expect(screen.getByTestId('rule-letter')).toHaveTextContent('A letter: Not met');
    expect(screen.getByTestId('rule-digit')).toHaveTextContent('A digit: Not met');
    await fireEvent.changeText(screen.getByLabelText('New password'), 'abcdefghij');
    expect(screen.getByTestId('rule-length')).toHaveTextContent('At least 10 characters: Met');
    expect(screen.getByTestId('rule-letter')).toHaveTextContent('A letter: Met');
    expect(screen.getByTestId('rule-digit')).toHaveTextContent('A digit: Not met');
    await fireEvent.changeText(screen.getByLabelText('New password'), 'abcdefghi1');
    expect(screen.getByTestId('rule-digit')).toHaveTextContent('A digit: Met');
  });

  it('checks "different from the current password" and "matches the confirmation"', async () => {
    await renderWithSession(<ChangePassword />, { ctx: forced });
    await fillForm('Same-pass-12345', 'Same-pass-12345', 'Same-pass-12345');
    expect(screen.getByTestId('rule-different')).toHaveTextContent('Different from the current password: Not met');
    await fillForm('Temp-pass-1234', 'Brand-new-77x', 'Brand-new-77y');
    expect(screen.getByTestId('rule-different')).toHaveTextContent('Different from the current password: Met');
    expect(screen.getByTestId('rule-match')).toHaveTextContent('Matches the confirmation: Not met');
  });

  it('validates locally without a request: empty current, policy, mismatch', async () => {
    await renderWithSession(<ChangePassword />, { ctx: forced });
    await fireEvent.press(screen.getByTestId('change-password-submit'));
    expect(await screen.findByText('Enter your current password')).toBeTruthy();
    await fillForm('Temp-pass-1234', 'short1', 'short1');
    await fireEvent.press(screen.getByTestId('change-password-submit'));
    expect(await screen.findByTestId('new-password-error')).toBeTruthy();
    await fillForm('Temp-pass-1234', 'Brand-new-77x', 'Different-77x');
    await fireEvent.press(screen.getByTestId('change-password-submit'));
    expect(await screen.findByText('The two new passwords do not match')).toBeTruthy();
    expect(mockChange).not.toHaveBeenCalled();
  });

  // D14 (owner-approved 2026-11-16): Auth ends every session on a password change, so the client signs out locally and
  // asks for a fresh sign-in, for the forced change and for the change from Home alike.
  it.each([
    ['forced change', forced],
    ['change from Home', member],
  ])('after a successful %s: signs out locally, shows the sign-in notice, and does not go Home', async (_n, ctx) => {
    mockChange.mockResolvedValue({ ok: true });
    const { value } = await renderWithSession(<ChangePassword />, { ctx });
    await fillForm('Temp-pass-1234', 'Brand-new-77x');
    await fireEvent.press(screen.getByTestId('change-password-submit'));
    await waitFor(() => expect(mockChange).toHaveBeenCalledWith(value.client, 'Temp-pass-1234', 'Brand-new-77x'));
    await waitFor(() => expect((value.client.auth.signOut as jest.Mock)).toHaveBeenCalledWith({ scope: 'local' }));
    expect(value.setNotice).toHaveBeenCalledWith('password_changed');
    await waitFor(() => expect(value.refresh).toHaveBeenCalled());
    expect(mockReplace).not.toHaveBeenCalled();
    expect(screen.queryByTestId('password-changed')).toBeNull();
  });

  it('a failed change does not sign out and sets no notice', async () => {
    mockChange.mockRejectedValue(new ApiError(403, 'current_password', 'Current password is incorrect'));
    const { value } = await renderWithSession(<ChangePassword />, { ctx: forced });
    await fillForm();
    await fireEvent.press(screen.getByTestId('change-password-submit'));
    await screen.findByTestId('current-password-error');
    expect(value.client.auth.signOut).not.toHaveBeenCalled();
    expect(value.setNotice).not.toHaveBeenCalled();
  });

  it('forced users have no Back button; members do', async () => {
    await renderWithSession(<ChangePassword />, { ctx: forced });
    expect(screen.queryByTestId('change-password-back')).toBeNull();
  });

  it('members can go back without changing anything', async () => {
    await renderWithSession(<ChangePassword />, { ctx: member });
    await fireEvent.press(screen.getByTestId('change-password-back'));
    expect(mockReplace).toHaveBeenCalledWith('/home');
    expect(mockChange).not.toHaveBeenCalled();
  });

  it('maps server field errors next to the field', async () => {
    mockChange.mockRejectedValue(new ApiError(403, 'current_password', 'Current password is incorrect'));
    await renderWithSession(<ChangePassword />, { ctx: forced });
    await fillForm();
    await fireEvent.press(screen.getByTestId('change-password-submit'));
    expect(await screen.findByTestId('current-password-error')).toHaveTextContent('Current password is incorrect');
  });

  it('shows the network message when the server is unreachable', async () => {
    mockChange.mockRejectedValue(new TypeError('Network request failed'));
    await renderWithSession(<ChangePassword />, { ctx: forced });
    await fillForm();
    await fireEvent.press(screen.getByTestId('change-password-submit'));
    expect(await screen.findByTestId('change-password-error')).toHaveTextContent(/Can't reach MouldTrack/);
  });

  it('disables the button while submitting', async () => {
    let resolve!: (v: unknown) => void;
    mockChange.mockReturnValue(new Promise((r) => (resolve = r)));
    await renderWithSession(<ChangePassword />, { ctx: forced });
    await fillForm();
    void fireEvent.press(screen.getByTestId('change-password-submit'));
    await waitFor(() => expect(screen.getByTestId('change-password-submit')).toBeDisabled());
    resolve({ ok: true });
  });
});

describe('Change password expired state (AC-4)', () => {
  const message = 'Your temporary password has expired. Ask your Unit Admin to reset it.';

  it('shows the expiry message and Sign out, with no form', async () => {
    const { value } = await renderWithSession(<ChangePassword />, { ctx: { ...forced, expired: true } });
    expect(screen.getByTestId('password-expired')).toHaveTextContent(message);
    expect(screen.queryByLabelText('New password')).toBeNull();
    await fireEvent.press(screen.getByTestId('sign-out'));
    await waitFor(() => expect(value.client.auth.signOut).toHaveBeenCalled());
  });

  it('switches to the expired state when the server refuses with the expired code', async () => {
    mockChange.mockRejectedValue(new ApiError(403, undefined, message, 'expired'));
    await renderWithSession(<ChangePassword />, { ctx: forced });
    await fillForm();
    await fireEvent.press(screen.getByTestId('change-password-submit'));
    expect(await screen.findByTestId('password-expired')).toHaveTextContent(message);
  });

  it('goes by the code, not the wording: the same text without the code stays a form error (R5)', async () => {
    mockChange.mockRejectedValue(new ApiError(403, undefined, message));
    await renderWithSession(<ChangePassword />, { ctx: forced });
    await fillForm();
    await fireEvent.press(screen.getByTestId('change-password-submit'));
    expect(await screen.findByTestId('change-password-error')).toHaveTextContent(message);
    expect(screen.queryByTestId('password-expired')).toBeNull();
  });
});
