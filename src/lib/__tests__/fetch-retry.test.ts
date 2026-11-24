import { createRetryingFetch, READ_RPCS, READ_TIMEOUT_MS } from '@/lib/fetch-retry';

const READ = 'https://x.supabase.co/rest/v1/membership?select=role&user_id=eq.secret';
const ok = () => new Response('{}', { status: 200 });

/** A base fetch whose n-th call hangs (until aborted) when `hang(n)`, else answers. */
function base(hang: (n: number) => boolean) {
  const calls: { url: string; method?: string }[] = [];
  const fn = jest.fn((input: RequestInfo | URL, init?: RequestInit) => {
    const n = calls.length;
    calls.push({ url: String(input), method: init?.method });
    if (!hang(n)) return Promise.resolve(ok());
    return new Promise<Response>((_res, rej) => {
      if (init?.signal?.aborted) return rej(new DOMException('aborted', 'AbortError')); // like real fetch
      init?.signal?.addEventListener('abort', () => rej(new DOMException('aborted', 'AbortError')));
    });
  });
  return { fn, calls };
}

beforeEach(() => jest.useFakeTimers());
afterEach(() => jest.useRealTimers());

describe('retrying fetch (D1: stalled reads retry once, writes never)', () => {
  it('a read that stalls is aborted after READ_TIMEOUT_MS (4 s) and retried once, and resolves', async () => {
    const b = base((n) => n === 0);
    const onRetry = jest.fn();
    const f = createRetryingFetch(b.fn as never, { onRetry });
    const p = f(READ);
    await jest.advanceTimersByTimeAsync(READ_TIMEOUT_MS);
    const res = await p;
    expect(res.status).toBe(200);
    expect(b.calls).toHaveLength(2);
    expect(onRetry).toHaveBeenCalledTimes(1);
    expect(onRetry.mock.calls[0][0]).toBe('x.supabase.co/rest/v1/membership'); // path only: no query string
  });
  it('a read that stalls twice errors (the normal network error path)', async () => {
    const b = base(() => true);
    const f = createRetryingFetch(b.fn as never);
    const p = f(READ, { method: 'GET' });
    const assertion = expect(p).rejects.toThrow(/failed to fetch/i);
    await jest.advanceTimersByTimeAsync(READ_TIMEOUT_MS * 2);
    await assertion;
    expect(b.calls).toHaveLength(2);
  });
  it('a read that answers in time is not retried and its timer is cleared', async () => {
    const b = base(() => false);
    await createRetryingFetch(b.fn as never)(READ);
    expect(b.calls).toHaveLength(1);
    expect(jest.getTimerCount()).toBe(0);
  });
  it('storage downloads (GET) are retried too', async () => {
    const b = base((n) => n === 0);
    const p = createRetryingFetch(b.fn as never)('https://x.supabase.co/storage/v1/object/attachments/a.jpg');
    await jest.advanceTimersByTimeAsync(READ_TIMEOUT_MS);
    await p;
    expect(b.calls).toHaveLength(2);
  });
  it.each([
    ['a write rpc', 'https://x.supabase.co/rest/v1/rpc/rd_opening', 'POST'],
    ['an unknown rpc (default deny)', 'https://x.supabase.co/rest/v1/rpc/brand_new_fn', 'POST'],
    ['PATCH', 'https://x.supabase.co/rest/v1/membership', 'PATCH'],
    ['DELETE', 'https://x.supabase.co/rest/v1/membership', 'DELETE'],
    ['auth token', 'https://x.supabase.co/auth/v1/token?grant_type=password', 'POST'],
    ['auth GET', 'https://x.supabase.co/auth/v1/user', 'GET'],
    ['edge function', 'https://x.supabase.co/functions/v1/user-admin', 'POST'],
    ['storage upload', 'https://x.supabase.co/storage/v1/object/attachments/a.jpg', 'POST'],
  ])('never retries or times out %s', async (_n, url, method) => {
    const b = base(() => true);
    const f = createRetryingFetch(b.fn as never);
    const p = f(url, { method });
    p.catch(() => {});
    await jest.advanceTimersByTimeAsync(READ_TIMEOUT_MS * 3);
    expect(b.calls).toHaveLength(1);
    expect(b.fn.mock.calls[0][1]?.signal).toBeUndefined(); // untouched: platform default
  });
  it("honours the caller's own AbortSignal: no retry, abort error passes through", async () => {
    const b = base(() => true);
    const f = createRetryingFetch(b.fn as never);
    const ctl = new AbortController();
    const p = f(READ, { signal: ctl.signal });
    const assertion = expect(p).rejects.toMatchObject({ name: 'AbortError' });
    await jest.advanceTimersByTimeAsync(1000);
    ctl.abort();
    await assertion;
    await jest.advanceTimersByTimeAsync(READ_TIMEOUT_MS * 2);
    expect(b.calls).toHaveLength(1);
  });
  it('an already aborted caller signal is not retried', async () => {
    const b = base(() => true);
    const ctl = new AbortController();
    ctl.abort();
    await expect(createRetryingFetch(b.fn as never)(READ, { signal: ctl.signal })).rejects.toMatchObject({ name: 'AbortError' });
    expect(b.calls.length).toBeLessThanOrEqual(1);
  });
});

describe('read-only RPC allowlist (D3)', () => {
  const rpc = (n: string) => `https://x.supabase.co/rest/v1/rpc/${n}`;
  it.each(READ_RPCS)('%s is a read RPC: a stall is retried once', async (name) => {
    const b = base((n) => n === 0);
    const p = createRetryingFetch(b.fn as never)(rpc(name), { method: 'POST', body: '{}' });
    await jest.advanceTimersByTimeAsync(READ_TIMEOUT_MS);
    expect((await p).status).toBe(200);
    expect(b.calls).toHaveLength(2);
  });
  it('a read rpc that stalls twice errors', async () => {
    const b = base(() => true);
    const p = createRetryingFetch(b.fn as never)(rpc('my_shift'), { method: 'POST' });
    const a = expect(p).rejects.toThrow(/failed to fetch/i);
    await jest.advanceTimersByTimeAsync(READ_TIMEOUT_MS * 2);
    await a;
    expect(b.calls).toHaveLength(2);
  });
  it.each(['pm_save_site', 'sh_assign', 'iss_report', 'rd_closing', 'ho_declare', 'psvc_tenant_create', 'svc_user_create'])('write rpc %s is never retried', async (name) => {
    const b = base(() => true);
    const p = createRetryingFetch(b.fn as never)(rpc(name), { method: 'POST' });
    p.catch(() => {});
    await jest.advanceTimersByTimeAsync(READ_TIMEOUT_MS * 3);
    expect(b.calls).toHaveLength(1);
  });
  it('the allowlist holds no write-prefixed name', () => {
    for (const n of READ_RPCS) expect(n).not.toMatch(/^(pm|sh|iss|rd|ho|psvc|svc)_/);
  });
});
