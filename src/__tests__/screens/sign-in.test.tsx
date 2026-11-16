import { fireEvent, screen, waitFor } from '@testing-library/react-native';
import SignIn from '@/app/sign-in';
import { fakeAuthClient, renderWithSession } from '@/test/render-with-session';

jest.mock('expo-router', () => ({ Redirect: () => null }));

async function fill() {
  await fireEvent.changeText(screen.getByLabelText('Phone number'), '98765 43210');
  await fireEvent.changeText(screen.getByLabelText('Password'), 'wrong');
}

describe('Sign-in screen', () => {
  it('has labelled inputs and a 48dp primary button (accessibility)', async () => {
    await renderWithSession(<SignIn />);
    expect(screen.getByLabelText('Phone number')).toBeTruthy();
    expect(screen.getByLabelText('Password')).toBeTruthy();
    expect(screen.getByTestId('sign-in-submit')).toHaveStyle({ minHeight: 48 });
  });

  it('shows the non-technical error for bad credentials and stays on sign-in (AC-2)', async () => {
    const client = fakeAuthClient({
      signInWithPassword: jest.fn(async () => ({
        data: {},
        error: { name: 'AuthApiError', code: 'invalid_credentials', message: 'Invalid login credentials' },
      })),
    });
    const { value } = await renderWithSession(<SignIn />, { client: client as never });
    await fill();
    await fireEvent.press(screen.getByTestId('sign-in-submit'));
    expect(await screen.findByTestId('sign-in-error')).toHaveTextContent('Phone number or password is incorrect');
    expect(value.refresh).not.toHaveBeenCalled();
  });

  it('disables the button while submitting, then refreshes the session on success (AC-1)', async () => {
    let resolve!: (v: unknown) => void;
    const client = fakeAuthClient({ signInWithPassword: jest.fn(() => new Promise((r) => (resolve = r))) });
    const { value } = await renderWithSession(<SignIn />, { client: client as never });
    await fill();
    // Not awaited: the sign-in request is still pending while we assert the busy state.
    void fireEvent.press(screen.getByTestId('sign-in-submit'));
    await waitFor(() => expect(screen.getByTestId('sign-in-submit')).toBeDisabled());
    resolve({ data: {}, error: null });
    await waitFor(() => expect(value.refresh).toHaveBeenCalled());
  });

  it('shows the network message when the server is unreachable', async () => {
    const client = fakeAuthClient({
      signInWithPassword: jest.fn(async () => {
        throw new TypeError('Network request failed');
      }),
    });
    await renderWithSession(<SignIn />, { client: client as never });
    await fill();
    await fireEvent.press(screen.getByTestId('sign-in-submit'));
    expect(await screen.findByTestId('sign-in-error')).toHaveTextContent(/Can't reach MouldTrack/);
  });

  // --- 02-tenancy-and-roles (AC-13): sign-in by phone -------------------------------------------------------
  it('shows the fixed +91 prefix and asks for a numeric keypad', async () => {
    await renderWithSession(<SignIn />);
    expect(screen.getByTestId('phone-prefix')).toHaveTextContent('+91');
    expect(screen.getByLabelText('Phone number').props.keyboardType).toBe('number-pad');
    expect(screen.getByLabelText('Phone number').props.autoComplete).toBe('tel');
  });

  it('signs in with the Auth address derived from the normalised phone', async () => {
    const signInWithPassword = jest.fn(async () => ({ data: {}, error: null }));
    const { value } = await renderWithSession(<SignIn />, { client: fakeAuthClient({ signInWithPassword }) as never });
    await fill();
    await fireEvent.press(screen.getByTestId('sign-in-submit'));
    await waitFor(() => expect(value.refresh).toHaveBeenCalled());
    expect(signInWithPassword).toHaveBeenCalledWith({ email: '9876543210@phone.mouldtrack.invalid', password: 'wrong' });
  });

  it.each(['0 98765-43210', '+91 98765 43210', '9876543210'])('accepts the phone format "%s"', async (input) => {
    const signInWithPassword = jest.fn(async () => ({ data: {}, error: null }));
    await renderWithSession(<SignIn />, { client: fakeAuthClient({ signInWithPassword }) as never });
    await fireEvent.changeText(screen.getByLabelText('Phone number'), input);
    await fireEvent.changeText(screen.getByLabelText('Password'), 'pw');
    await fireEvent.press(screen.getByTestId('sign-in-submit'));
    await waitFor(() => expect(signInWithPassword).toHaveBeenCalledWith({ email: '9876543210@phone.mouldtrack.invalid', password: 'pw' }));
  });

  it('shows "Enter your phone number" and sends no request when the phone is empty', async () => {
    const signInWithPassword = jest.fn();
    await renderWithSession(<SignIn />, { client: fakeAuthClient({ signInWithPassword }) as never });
    await fireEvent.changeText(screen.getByLabelText('Password'), 'pw');
    await fireEvent.press(screen.getByTestId('sign-in-submit'));
    expect(await screen.findByText('Enter your phone number')).toBeTruthy();
    expect(signInWithPassword).not.toHaveBeenCalled();
  });

  it('shows "Enter your password" and sends no request when the password is empty', async () => {
    const signInWithPassword = jest.fn();
    await renderWithSession(<SignIn />, { client: fakeAuthClient({ signInWithPassword }) as never });
    await fireEvent.changeText(screen.getByLabelText('Phone number'), '9876543210');
    await fireEvent.press(screen.getByTestId('sign-in-submit'));
    expect(await screen.findByText('Enter your password')).toBeTruthy();
    expect(signInWithPassword).not.toHaveBeenCalled();
  });

  it('shows both messages when both fields are empty', async () => {
    const signInWithPassword = jest.fn();
    await renderWithSession(<SignIn />, { client: fakeAuthClient({ signInWithPassword }) as never });
    await fireEvent.press(screen.getByTestId('sign-in-submit'));
    expect(await screen.findByText('Enter your phone number')).toBeTruthy();
    expect(screen.getByText('Enter your password')).toBeTruthy();
    expect(signInWithPassword).not.toHaveBeenCalled();
  });

  it('keeps the button enabled when fields are empty so the messages can appear', async () => {
    await renderWithSession(<SignIn />);
    expect(screen.getByTestId('sign-in-submit')).not.toBeDisabled();
  });

  it('rejects a malformed phone locally without a request', async () => {
    const signInWithPassword = jest.fn();
    await renderWithSession(<SignIn />, { client: fakeAuthClient({ signInWithPassword }) as never });
    await fireEvent.changeText(screen.getByLabelText('Phone number'), '12345');
    await fireEvent.changeText(screen.getByLabelText('Password'), 'pw');
    await fireEvent.press(screen.getByTestId('sign-in-submit'));
    expect(await screen.findByText('Enter a valid 10-digit Indian mobile number')).toBeTruthy();
    expect(signInWithPassword).not.toHaveBeenCalled();
  });

  it('shows the same generic message for a deactivated (banned) account', async () => {
    const client = fakeAuthClient({
      signInWithPassword: jest.fn(async () => ({ data: {}, error: { name: 'AuthApiError', code: 'user_banned', message: 'User is banned' } })),
    });
    await renderWithSession(<SignIn />, { client: client as never });
    await fill();
    await fireEvent.press(screen.getByTestId('sign-in-submit'));
    expect(await screen.findByTestId('sign-in-error')).toHaveTextContent('Phone number or password is incorrect');
  });

  it('has a Show password control with a 48dp target', async () => {
    await renderWithSession(<SignIn />);
    const toggle = screen.getByLabelText('Show password');
    expect(toggle).toHaveStyle({ minHeight: 48 });
    await fireEvent.press(toggle);
    expect(screen.getByLabelText('Hide password')).toBeTruthy();
    expect(screen.getByLabelText('Password').props.secureTextEntry).toBe(false);
  });
});
