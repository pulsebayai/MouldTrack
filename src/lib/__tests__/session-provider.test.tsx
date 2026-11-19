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
