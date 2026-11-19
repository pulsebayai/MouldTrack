/**
 * Connectivity (architecture, cross-cutting): an idempotent read with no response after 6 s is aborted and retried ONCE; a second
 * stall surfaces the normal network error. Writes are never retried or timed out here: POST/PATCH/DELETE, rpc calls (all POST, and some
 * read RPCs write a snapshot, e.g. handover_checklist), auth and Edge Function calls keep the platform default.
 */
export const READ_TIMEOUT_MS = 6000;

type FetchFn = typeof fetch;
const READ_PATH = /\/(rest\/v1\/(?!rpc\/)|storage\/v1\/object\/)/;

function urlOf(input: RequestInfo | URL): string {
  return typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
}
function methodOf(input: RequestInfo | URL, init?: RequestInit): string {
  return (init?.method ?? (typeof input === 'object' && 'method' in input ? input.method : 'GET')).toUpperCase();
}
/** host + path only, never the query string (it can hold ids and filters). */
function pathOf(url: string): string {
  try {
    const u = new URL(url);
    return `${u.host}${u.pathname}`;
  } catch {
    return url.split('?')[0] ?? '';
  }
}

export function createRetryingFetch(base: FetchFn, opts: { timeoutMs?: number; onRetry?: (path: string) => void } = {}): FetchFn {
  const timeoutMs = opts.timeoutMs ?? READ_TIMEOUT_MS;
  return (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = urlOf(input);
    const method = methodOf(input, init);
    if ((method !== 'GET' && method !== 'HEAD') || !READ_PATH.test(url)) return base(input, init);

    const callerSignal = init?.signal ?? (typeof input === 'object' && 'signal' in input ? input.signal : undefined) ?? undefined;
    const attempt = async (): Promise<Response | 'stalled'> => {
      const ctl = new AbortController();
      let stalled = false;
      const onCallerAbort = () => ctl.abort();
      callerSignal?.addEventListener('abort', onCallerAbort);
      const timer = setTimeout(() => {
        stalled = true;
        ctl.abort();
      }, timeoutMs);
      try {
        return await base(input, { ...init, signal: ctl.signal });
      } catch (e) {
        if (stalled && !callerSignal?.aborted) return 'stalled';
        throw e;
      } finally {
        clearTimeout(timer);
        callerSignal?.removeEventListener('abort', onCallerAbort);
      }
    };

    if (callerSignal?.aborted) return base(input, init); // the caller already gave up: let the platform raise its AbortError
    const first = await attempt();
    if (first !== 'stalled') return first;
    opts.onRetry?.(pathOf(url));
    const second = await attempt();
    if (second !== 'stalled') return second;
    throw new TypeError('Failed to fetch'); // maps to the normal "Can't reach MouldTrack" message
  }) as FetchFn;
}
