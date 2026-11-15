import { render, screen, waitFor } from '@testing-library/react-native';
import { Text } from 'react-native';
import { SessionProvider, useSession } from '@/lib/session-provider';

function Probe() {
  const { status, ctx } = useSession();
  return <Text testID="probe">{`${status}:${ctx ? ('noAccess' in ctx ? 'noAccess' : ctx.tenant.name) : 'none'}`}</Text>;
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
        maybeSingle: async () =>
          opts.fail
            ? { data: null, error: new Error('Failed to fetch') }
            : { data: { role: 'supervisor', status: 'active', tenant: { name: 'e2e org A', status: 'active' } }, error: null },
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
