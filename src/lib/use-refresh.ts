import { useFocusEffect } from 'expo-router';
import { useCallback, useRef } from 'react';

/**
 * Reloads when the screen regains focus (coming back from another screen or tab), not on the first focus (the screen has just loaded).
 * Needs a navigator, so use it only in screens and in components rendered inside one.
 */
// Where there is no navigator (a component rendered on its own, or a test with a router stub) the hook is a no-op.
const useFocus: typeof useFocusEffect = typeof useFocusEffect === 'function' ? useFocusEffect : () => {};

export function useRefreshOnFocus(reload: () => void) {
  const first = useRef(true);
  useFocus(
    useCallback(() => {
      if (first.current) {
        first.current = false;
        return;
      }
      reload();
    }, [reload]),
  );
}
