import { act, renderHook, waitFor } from '@testing-library/react-native';
import { useLoad } from '@/lib/use-load';

function deferred<T>() {
  let resolve!: (v: T) => void;
  let reject!: (e: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

describe('useLoad (one shared hook: deps + latest, step 8 N-10)', () => {
  it('goes loading -> ready with the data', async () => {
    const d = deferred<string>();
    const { result } = await renderHook(() => useLoad(() => d.promise, []));
    expect(result.current.state).toBe('loading');
    await act(async () => d.resolve('a'));
    await waitFor(() => expect(result.current.state).toBe('ready'));
    expect(result.current.data).toBe('a');
  });

  it('reports an error and offers reload to try again', async () => {
    let fail = true;
    const { result } = await renderHook(() => useLoad(async () => (fail ? Promise.reject(new Error('boom')) : 'ok'), []));
    await waitFor(() => expect(result.current.state).toBe('error'));
    expect(result.current.data).toBeNull();
    expect(result.current.error).toBeInstanceOf(Error);
    fail = false;
    await act(async () => result.current.reload());
    await waitFor(() => expect(result.current.state).toBe('ready'));
    expect(result.current.data).toBe('ok');
  });

  it('a change of deps shows loading (never the stale answer) and keeps the last good answer in `latest`', async () => {
    const d = deferred<string>();
    const { result, rerender } = await renderHook((p: { q: string }) => useLoad(() => (p.q === 'a' ? Promise.resolve('A') : d.promise), [p.q]), { initialProps: { q: 'a' } });
    await waitFor(() => expect(result.current.state).toBe('ready'));
    await rerender({ q: 'b' });
    expect(result.current.state).toBe('loading');
    expect(result.current.data).toBeNull();
    expect(result.current.latest).toBe('A');
    await act(async () => d.resolve('B'));
    await waitFor(() => expect(result.current.data).toBe('B'));
  });

  it('ignores an out-of-order answer to an older request', async () => {
    const first = deferred<string>();
    const second = deferred<string>();
    const { result, rerender } = await renderHook((p: { q: number }) => useLoad(() => (p.q === 1 ? first.promise : second.promise), [p.q]), { initialProps: { q: 1 } });
    await rerender({ q: 2 });
    await act(async () => second.resolve('two'));
    await waitFor(() => expect(result.current.data).toBe('two'));
    await act(async () => first.resolve('one'));
    expect(result.current.data).toBe('two');
  });

  it('does not load while disabled', async () => {
    const load = jest.fn(async () => 1);
    const { result } = await renderHook(() => useLoad(load, [], false));
    expect(result.current.state).toBe('loading');
    expect(load).not.toHaveBeenCalled();
  });

  it('uses the latest load function without restarting (a closure over fresh state is fine)', async () => {
    const calls: string[] = [];
    const { result, rerender } = await renderHook((p: { tag: string }) => useLoad(async () => { calls.push(p.tag); return p.tag; }, []), { initialProps: { tag: 'x' } });
    await waitFor(() => expect(result.current.state).toBe('ready'));
    await rerender({ tag: 'y' });
    expect(calls).toEqual(['x']);
    await act(async () => result.current.reload());
    await waitFor(() => expect(calls).toEqual(['x', 'y']));
  });
});
