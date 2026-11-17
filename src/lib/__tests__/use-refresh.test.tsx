import { render } from '@testing-library/react-native';
import { Text } from 'react-native';
import { useRefreshOnFocus } from '@/lib/use-refresh';

let mockFocus: (() => void) | null = null;
jest.mock('expo-router', () => ({ useFocusEffect: (cb: () => void) => { mockFocus = cb; } }));

function Probe({ reload }: { reload: () => void }) {
  useRefreshOnFocus(reload);
  return <Text>x</Text>;
}

describe('useRefreshOnFocus (N-12)', () => {
  it('does not reload on the first focus, reloads on every later one', async () => {
    const reload = jest.fn();
    await render(<Probe reload={reload} />);
    mockFocus!();
    expect(reload).not.toHaveBeenCalled();
    mockFocus!();
    mockFocus!();
    expect(reload).toHaveBeenCalledTimes(2);
  });
});
