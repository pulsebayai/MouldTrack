import type { SupabaseClient } from '@supabase/supabase-js';
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import type { AppEnv } from './env';
import { getSessionContext, type SessionContext } from './session';

export type SessionState = {
  status: 'loading' | 'ready' | 'error';
  ctx: SessionContext | null;
  appEnv: AppEnv;
  client: Pick<SupabaseClient, 'auth' | 'from'>;
  refresh: () => Promise<void>;
};

export const SessionStateContext = createContext<SessionState | null>(null);

export function useSession(): SessionState {
  const v = useContext(SessionStateContext);
  if (!v) throw new Error('useSession must be used inside <SessionProvider>');
  return v;
}

export type AppRoute = '/sign-in' | '/no-access' | '/home';
export function routeFor(ctx: SessionContext | null): AppRoute {
  if (!ctx) return '/sign-in';
  if ('noAccess' in ctx) return '/no-access';
  return '/home';
}

export function SessionProvider(props: { client: SessionState['client']; appEnv: AppEnv; children: ReactNode }) {
  const { client, appEnv, children } = props;
  const [status, setStatus] = useState<SessionState['status']>('loading');
  const [ctx, setCtx] = useState<SessionContext | null>(null);

  const refresh = useCallback(async () => {
    try {
      setCtx(await getSessionContext(client));
      setStatus('ready');
    } catch {
      setStatus('error');
    }
  }, [client]);

  useEffect(() => {
    // Supabase emits INITIAL_SESSION on subscribe, so this also performs the first load.
    // Defer the refresh: awaiting other Supabase calls inside this callback can deadlock the auth lock.
    const { data } = client.auth.onAuthStateChange((event) => {
      if (['INITIAL_SESSION', 'SIGNED_IN', 'SIGNED_OUT', 'USER_UPDATED', 'TOKEN_REFRESHED'].includes(event)) {
        setTimeout(() => void refresh(), 0);
      }
    });
    return () => data.subscription.unsubscribe();
  }, [client, refresh]);

  const value = useMemo(() => ({ status, ctx, appEnv, client, refresh }), [status, ctx, appEnv, client, refresh]);
  return <SessionStateContext.Provider value={value}>{children}</SessionStateContext.Provider>;
}
