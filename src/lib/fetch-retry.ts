/**
 * Connectivity (architecture, cross-cutting): an idempotent read (GET/HEAD, or an allowlisted read RPC) with no response after 4 s is aborted and retried ONCE; a second
 * stall surfaces the normal network error. Writes are never retried or timed out here: POST/PATCH/DELETE, every rpc not on the allowlist
 * below, auth and Edge Function calls keep the platform default.
 */
export const READ_TIMEOUT_MS = 4000;

type FetchFn = typeof fetch;
const READ_PATH = /\/(rest\/v1\/(?!rpc\/)|storage\/v1\/object\/)/;
const RPC_PATH = /\/rest\/v1\/rpc\/([a-z_0-9]+)(?:$|\?)/;

/**
 * D3: read-only RPCs that are safe to repeat (checked against the migrations: no insert/update/delete except `handover_checklist`, whose
 * only write is the `handover_session` snapshot, `insert ... on conflict do nothing`, so a repeat is a no-op). Explicit allowlist, default deny:
 * every other rpc (pm_*, sh_*, iss_*, rd_*, ho_*, psvc_*, svc_*, anything new) is never retried. A denial may add one more `access.denied` audit row.
 */
export const READ_RPCS: readonly string[] = [
  'my_shift', 'shift_board', 'reading_state', 'reading_detail', 'today_board', 'handover_checklist', 'handover_alerts',
  'issue_alerts', 'issue_detail', 'issue_list', 'pa_audit', 'pa_super_admins', 'pa_tenant_summaries', 'pa_tenant_unit_admins',
];
const READ_RPC_SET = new Set(READ_RPCS);

function isRetryable(method: string, url: string): boolean {
  if (method === 'GET' || method === 'HEAD') return READ_PATH.test(url);
  if (method === 'POST') {
    const m = RPC_PATH.exec(url.split('#')[0] ?? '');
    return !!m && READ_RPC_SET.has(m[1]!);
  }
  return false;
}

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
    if (!isRetryable(method, url)) return base(input, init);

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
