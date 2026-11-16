import { fireEvent, screen, waitFor } from '@testing-library/react-native';
import NoAccess from '@/app/no-access';
import { renderWithSession } from '@/test/render-with-session';

const mockReplace = jest.fn();
jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: (...a: unknown[]) => mockReplace(...a) } }));

describe('no-access sign-out (03 R6)', () => {
  it('signs out and then leaves the page for sign-in', async () => {
    const { value } = await renderWithSession(<NoAccess />, { ctx: { noAccess: true } });
    await fireEvent.press(screen.getByTestId('sign-out'));
    await waitFor(() => expect(value.client.auth.signOut).toHaveBeenCalled());
    await waitFor(() => expect(mockReplace).toHaveBeenCalledWith('/sign-in'));
  });
});
