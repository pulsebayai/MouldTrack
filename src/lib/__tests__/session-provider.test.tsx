import { act, fireEvent, render, screen, waitFor } from '@testing-library/react-native';
import { Pressable, Text } from 'react-native';
import { SessionProvider, useSession } from '@/lib/session-provider';

function Probe() {
  const { status, ctx } = useSession();
  return <Text testID="probe">{`${status}:${ctx ? ('tenant' in ctx ? ctx.tenant.name : 'noAccess') : 'none'}`}</Text>;
}

function client(opts: { session: boolean; fail?: boolean }) {
  let cb: (e: string) => void = () => {};
  return {
    emit: (e: string) => cb(e),
    auth: {
      getSession: async () => ({ data: { session: opts.session ? { user: { id: 'u', email: 'e' } } : null } }),
      onAuthStateChange: (fn: (e: string) => void) => {
        cb = fn;
        setTimeout(() => fn('INITIAL_SESSION'), 0);
        return { data: { subscription: { unsubscribe: jest.fn() } } };
      },
    },
    from: () => ({
      select: () => ({
        eq: () => ({
          maybeSingle: async () =>
            opts.fail
              ? { data: null, error: new Error('Failed to fetch') }
              : { data: { role: 'supervisor', status: 'active', tenant: { name: 'e2e org A', status: 'active' } }, error: null },
        }),
      }),
    }),
  };
}

describe('SessionProvider', () => {
  it('starts loading, then resolves the context from INITIAL_SESSION (AC-5)', async () => {
    await render(
      <SessionProvider client={client({ session: true }) as never} appEnv="local">
        <Probe />
      </SessionProvider>,
    );
    await waitFor(() => expect(screen.getByTestId('probe')).toHaveTextContent('ready:e2e org A'));
  });

  it('resolves to no session when signed out', async () => {
    await render(
      <SessionProvider client={client({ session: false }) as never} appEnv="local">
        <Probe />
      </SessionProvider>,
    );
    await waitFor(() => expect(screen.getByTestId('probe')).toHaveTextContent('ready:none'));
  });

  it('reports error status when the membership query fails (network retry path)', async () => {
    await render(
      <SessionProvider client={client({ session: true, fail: true }) as never} appEnv="local">
        <Probe />
      </SessionProvider>,
    );
    await waitFor(() => expect(screen.getByTestId('probe')).toHaveTextContent('error:none'));
  });
});

describe('SessionProvider (test-reliability: overlapping auth events)', () => {
  // Supabase emits INITIAL_SESSION, SIGNED_IN and TOKEN_REFRESHED within milliseconds of each other. Each used to start its own
  // 3-4 round-trip load, so on hosted dev the session resolved only when the slowest, possibly stale, one answered.
  it('coalesces a burst of auth events into at most one running and one trailing load, and ends on the latest state', async () => {
    let sessionPresent = false;
    let loads = 0;
    let release: () => void = () => {};
    const gate = new Promise<void>((r) => (release = r));
    let cb: (e: string) => void = () => {};
    const c = {
      auth: {
        getSession: async () => ({ data: { session: sessionPresent ? { user: { id: 'u', email: 'e' } } : null } }),
        onAuthStateChange: (fn: (e: string) => void) => {
          cb = fn;
          return { data: { subscription: { unsubscribe: jest.fn() } } };
        },
      },
      from: () => ({
        select: () => ({
          eq: () => ({
            maybeSingle: async () => {
              loads += 1;
              if (loads === 1) await gate;
              return { data: { role: 'supervisor', status: 'active', tenant: { name: 'e2e org A', status: 'active' } }, error: null };
            },
          }),
        }),
      }),
    };
    await render(
      <SessionProvider client={c as never} appEnv="local">
        <Probe />
      </SessionProvider>,
    );
    sessionPresent = true;
    await act(async () => {
      cb('INITIAL_SESSION');
      cb('SIGNED_IN');
      cb('TOKEN_REFRESHED');
      await new Promise((r) => setTimeout(r, 5));
      release();
    });
    await waitFor(() => expect(screen.getByTestId('probe')).toHaveTextContent('ready:e2e org A'));
    expect(loads).toBeLessThanOrEqual(2);
  });

  it('refresh() resolves only after a load that started after the call', async () => {
    let tenant = 'before';
    let cb: (e: string) => void = () => {};
    const calls: Promise<void>[] = [];
    const c = {
      auth: {
        getSession: async () => ({ data: { session: { user: { id: 'u', email: 'e' } } } }),
        onAuthStateChange: (fn: (e: string) => void) => {
          cb = fn;
          return { data: { subscription: { unsubscribe: jest.fn() } } };
        },
      },
      from: () => ({
        select: () => ({
          eq: () => ({
            maybeSingle: async () => {
              await new Promise((r) => setTimeout(r, 10));
              return { data: { role: 'supervisor', status: 'active', tenant: { name: tenant, status: 'active' } }, error: null };
            },
          }),
        }),
      }),
    };
    function Grab() {
      const { refresh } = useSession();
      return (
        <>
          <Probe />
          <Pressable testID="go" onPress={() => calls.push(refresh())} />
        </>
      );
    }
    await render(
      <SessionProvider client={c as never} appEnv="local">
        <Grab />
      </SessionProvider>,
    );
    await act(async () => {
      cb('INITIAL_SESSION');
    });
    // A load is running with tenant "before"; the data changes and refresh() is called: it must reflect "after" when it resolves.
    tenant = 'after';
    await act(async () => {
      fireEvent.press(screen.getByTestId('go'));
      await calls[0];
    });
    expect(screen.getByTestId('probe')).toHaveTextContent('ready:after');
  });
});

describe('SessionProvider (screen-speed: one membership read per sign-in)', () => {
  const session = (token: string) => ({ access_token: token, user: { id: 'u', email: 'e', updated_at: '2026-11-19T00:00:00Z' } });
  function setup() {
    const state = { memberships: 0, current: session('t1') as ReturnType<typeof session> | null };
    let cb: (e: string, s?: unknown) => void = () => {};
    const c = {
      auth: {
        getSession: async () => ({ data: { session: state.current } }),
        onAuthStateChange: (fn: (e: string, s?: unknown) => void) => {
          cb = fn;
          return { data: { subscription: { unsubscribe: jest.fn() } } };
        },
      },
      from: () => ({
        select: () => ({
          eq: () => ({
            maybeSingle: async () => {
              state.memberships += 1;
              await new Promise((r) => setTimeout(r, 5));
              return { data: { role: 'supervisor', status: 'active', tenant: { name: 'e2e org A', status: 'active' } }, error: null };
            },
          }),
        }),
      }),
    };
    let refresh: () => Promise<void> = async () => {};
    function Grab() {
      refresh = useSession().refresh;
      return <Probe />;
    }
    return { state, c, emit: (e: string, s?: unknown) => cb(e, s), refresh: () => refresh(), Grab };
  }

  it('sign-in: the explicit refresh() and the SIGNED_IN event for the same session share one load (one membership read)', async () => {
    const t = setup();
    await render(
      <SessionProvider client={t.c as never} appEnv="local">
        <t.Grab />
      </SessionProvider>,
    );
    await act(async () => {
      const p = t.refresh(); // sign-in.tsx: refresh() right after signInWithPassword resolves
      t.emit('SIGNED_IN', t.state.current); // the event arrives (deferred) afterwards
      await new Promise((r) => setTimeout(r, 0));
      await p;
    });
    await waitFor(() => expect(screen.getByTestId('probe')).toHaveTextContent('ready:e2e org A'));
    expect(t.state.memberships).toBe(1);
  });

  it('a repeated SIGNED_IN / TOKEN_REFRESHED for the already loaded session does not reload; a new token does', async () => {
    const t = setup();
    await render(
      <SessionProvider client={t.c as never} appEnv="local">
        <t.Grab />
      </SessionProvider>,
    );
    await act(async () => {
      await t.refresh();
    });
    expect(t.state.memberships).toBe(1);
    await act(async () => {
      t.emit('SIGNED_IN', t.state.current);
      t.emit('INITIAL_SESSION', t.state.current);
      await new Promise((r) => setTimeout(r, 20));
    });
    expect(t.state.memberships).toBe(1);
    await act(async () => {
      t.state.current = session('t2');
      t.emit('TOKEN_REFRESHED', t.state.current);
      await new Promise((r) => setTimeout(r, 30));
    });
    expect(t.state.memberships).toBe(2);
  });

  it('SIGNED_OUT always loads', async () => {
    const t = setup();
    await render(
      <SessionProvider client={t.c as never} appEnv="local">
        <t.Grab />
      </SessionProvider>,
    );
    await act(async () => {
      await t.refresh();
      t.state.current = null;
      t.emit('SIGNED_OUT', null);
      await new Promise((r) => setTimeout(r, 30));
    });
    await waitFor(() => expect(screen.getByTestId('probe')).toHaveTextContent('ready:none'));
  });
});
