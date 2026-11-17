import { useCallback, useEffect, useRef, useState } from 'react';

/**
 * Loads data keyed by `deps`: reports 'loading' until the result for the current key has arrived (so a stale answer never shows),
 * ignores out-of-order answers and exposes `reload` for Try again and for refreshing after a write.
 */
export function useLoad<T>(load: () => Promise<T>, deps: readonly unknown[], enabled = true) {
  const [reloadKey, setReloadKey] = useState(0);
  const [result, setResult] = useState<{ key: string; error: unknown; failed: boolean; data: T | null } | null>(null);
  const key = JSON.stringify([...deps, reloadKey]);
  const loader = useRef(load);
  const token = useRef(0);
  useEffect(() => {
    loader.current = load;
  });
  useEffect(() => {
    if (!enabled) return;
    const mine = ++token.current;
    loader.current().then(
      (data) => mine === token.current && setResult({ key, error: null, failed: false, data }),
      (error) => mine === token.current && setResult({ key, error, failed: true, data: null }),
    );
  }, [key, enabled]);
  const reload = useCallback(() => setReloadKey((k) => k + 1), []);
  const state: 'loading' | 'ready' | 'error' = !result || result.key !== key ? 'loading' : result.failed ? 'error' : 'ready';
  // `latest` is the last successful answer, kept while a reload is in flight so a form does not unmount (and lose what was typed).
  return { state, data: state === 'ready' ? result!.data : null, latest: result && !result.failed ? result.data : null, error: state === 'error' ? result!.error : null, reload };
}
