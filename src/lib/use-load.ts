import { useCallback, useEffect, useRef, useState } from 'react';

/**
 * Loads data for a screen with loading / ready / error states and a reload. `load` must be memoised (useCallback) over everything it
 * reads: a new `load` starts a new request, and an answer to an older one is ignored.
 */
export function useLoad<T>(load: () => Promise<T>, enabled = true) {
  const [reloadKey, setReloadKey] = useState(0);
  const [result, setResult] = useState<{ run: string; error: boolean; data: T | null } | null>(null);
  const token = useRef(0);
  const runId = `${reloadKey}`;
  const [loadId, setLoadId] = useState<{ load: () => Promise<T>; id: number }>({ load, id: 0 });
  if (loadId.load !== load) setLoadId({ load, id: loadId.id + 1 });
  const key = `${loadId.id}:${runId}`;

  useEffect(() => {
    if (!enabled) return;
    const mine = ++token.current;
    load().then(
      (data) => mine === token.current && setResult({ run: key, error: false, data }),
      () => mine === token.current && setResult({ run: key, error: true, data: null }),
    );
  }, [enabled, load, key]);

  const reload = useCallback(() => setReloadKey((k) => k + 1), []);
  const state: 'loading' | 'ready' | 'error' = !result || result.run !== key ? 'loading' : result.error ? 'error' : 'ready';
  return { state, data: state === 'ready' ? result!.data : null, reload };
}
