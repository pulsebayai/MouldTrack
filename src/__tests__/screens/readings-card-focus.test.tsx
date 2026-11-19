import { act, screen, waitFor } from '@testing-library/react-native';
import { ReadingsCard } from '@/components/readings/readings-card';
import { sup } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';
import { readingState, rpcOk, shiftClient, stateMachine } from '@/test/shift-fixtures';

// Focus callbacks registered through expo-router's useFocusEffect, so the test can fire "the screen regained focus".
const focusCallbacks: (() => void)[] = [];
jest.mock('expo-router', () => ({
  router: { push: jest.fn(), replace: jest.fn() },
  useFocusEffect: (cb: () => void) => {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    require('react').useEffect(() => {
      focusCallbacks.push(cb);
      cb();
    }, [cb]);
  },
}));
jest.setTimeout(20_000);

const key = 'sh-1-m-1-2026-11-18';

describe('test-reliability: the readings list refreshes when the screen regains focus', () => {
  it('shows the closed state after coming back from the closing form, without waiting for the 60 s timer', async () => {
    let state = readingState([stateMachine({ state: 'closing_due', can_open: false, can_close: true })]);
    const t = shiftClient({}, { reading_state: () => rpcOk(state) });
    await renderWithSession(<ReadingsCard />, { ctx: sup, client: t.client });
    expect(await screen.findByTestId(`reading-state-${key}`)).toHaveTextContent(/Closing reading due/);

    state = readingState([stateMachine({ state: 'closed', can_open: false, can_close: false })]); // the closing was saved on the other screen
    await act(async () => focusCallbacks[focusCallbacks.length - 1]());
    await waitFor(() => expect(screen.getByTestId(`reading-state-${key}`)).toHaveTextContent(/Both readings recorded/));
  });
});
