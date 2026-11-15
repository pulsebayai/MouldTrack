import { fireEvent, screen, waitFor } from '@testing-library/react-native';
import SignIn from '@/app/sign-in';
import { fakeAuthClient, renderWithSession } from '@/test/render-with-session';

jest.mock('expo-router', () => ({ Redirect: () => null }));

async function fill() {
  await fireEvent.changeText(screen.getByLabelText('Email'), 'e2e-sup-a@example.test');
  await fireEvent.changeText(screen.getByLabelText('Password'), 'wrong');
}

describe('Sign-in screen', () => {
  it('has labelled inputs and a 48dp primary button (accessibility)', async () => {
    await renderWithSession(<SignIn />);
    expect(screen.getByLabelText('Email')).toBeTruthy();
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
    expect(await screen.findByTestId('sign-in-error')).toHaveTextContent('Email or password is incorrect');
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
});
