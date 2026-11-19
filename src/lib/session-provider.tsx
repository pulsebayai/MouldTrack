import type { SupabaseClient } from '@supabase/supabase-js';
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import type { AppEnv } from './env';
import { loadSessionContext, type SessionContext } from './session';

export type SessionState = {
  status: 'loading' | 'ready' | 'error';
  ctx: SessionContext | null;
  appEnv: AppEnv;
  client: Pick<SupabaseClient, 'auth' | 'from' | 'rpc'>;
  refresh: () => Promise<void>;
  /** One-shot message for the sign-in screen (D14: after a password change the user signs in again). */
  notice: SignInNotice | null;
  setNotice: (n: SignInNotice | null) => void;
};

export type SignInNotice = 'password_changed';

export const SessionStateContext = createContext<SessionState | null>(null);

export function useSession(): SessionState {
  const v = useContext(SessionStateContext);
  if (!v) throw new Error('useSession must be used inside <SessionProvider>');
  return v;
}

export type AppRoute = '/sign-in' | '/no-access' | '/change-password' | '/home' | '/console';
export function routeFor(ctx: SessionContext | null): AppRoute {
  if (!ctx) return '/sign-in';
  if ('noAccess' in ctx) return '/no-access';
  if ('mustChangePassword' in ctx) return '/change-password';
  if ('platform' in ctx) return '/console';
  return '/home';
}

function fingerprint(session: { access_token?: string; user?: { id: string; updated_at?: string } } | null): string {
  return session ? `${session.user?.id}|${session.access_token}|${session.user?.updated_at}` : 'none';
}

export function SessionProvider(props: { client: SessionState['client']; appEnv: AppEnv; children: ReactNode }) {
  const { client, appEnv, children } = props;
  const [status, setStatus] = useState<SessionState['status']>('loading');
  const [ctx, setCtx] = useState<SessionContext | null>(null);
  const [notice, setNotice] = useState<SignInNotice | null>(null);

  // Auth events arrive in bursts (INITIAL_SESSION, SIGNED_IN, TOKEN_REFRESHED within milliseconds). One load runs at a time; any request that
  // arrives while it runs shares ONE trailing load that starts after it, so the last state always wins and no stale result is applied late.
  const running = useRef<Promise<void> | null>(null);
  const trailing = useRef<Promise<void> | null>(null);
  // Fingerprint of the session the running load reads / the last successful load read. An auth event that carries the same session
  // (sign-in: explicit refresh() plus the SIGNED_IN event; a repeated SIGNED_IN on tab focus) adds nothing and must not cost another load.
  const runningFp = useRef<string | null>(null);
  const loadedFp = useRef<string | null>(null);
  const start = useCallback((): Promise<void> => {
    const p: Promise<void> = (async () => {
      let fp: string | null = null;
      try {
        fp = fingerprint((await client.auth.getSession()).data.session);
        runningFp.current = fp;
        setCtx(await loadSessionContext(client));
        loadedFp.current = fp;
        setStatus('ready');
      } catch {
        loadedFp.current = null;
        setStatus('error');
      }
    })().finally(() => {
      if (running.current === p) {
        running.current = null;
        runningFp.current = null;
      }
    });
    running.current = p;
    return p;
  }, [client]);
  const refresh = useCallback((): Promise<void> => {
    if (!running.current) return start();
    if (!trailing.current) {
      trailing.current = running.current.then(() => {
        trailing.current = null;
        return start();
      });
    }
    return trailing.current;
  }, [start]);

  useEffect(() => {
    // Supabase emits INITIAL_SESSION on subscribe, so this also performs the first load.
    // Defer the refresh: awaiting other Supabase calls inside this callback can deadlock the auth lock.
    const { data } = client.auth.onAuthStateChange((event, session) => {
      if (['INITIAL_SESSION', 'SIGNED_IN', 'SIGNED_OUT', 'USER_UPDATED', 'TOKEN_REFRESHED'].includes(event)) {
        setTimeout(() => {
          // Decided when the timer fires, so an explicit refresh() made meanwhile (sign-in) counts. SIGNED_OUT always loads.
          const fp = session === undefined ? null : fingerprint(session);
          const same = running.current ? runningFp.current === fp : loadedFp.current === fp;
          if (event !== 'SIGNED_OUT' && fp !== null && same) return;
          void refresh();
        }, 0);
      }
    });
    return () => data.subscription.unsubscribe();
  }, [client, refresh]);

  const value = useMemo(() => ({ status, ctx, appEnv, client, refresh, notice, setNotice }), [status, ctx, appEnv, client, refresh, notice]);
  return <SessionStateContext.Provider value={value}>{children}</SessionStateContext.Provider>;
}
