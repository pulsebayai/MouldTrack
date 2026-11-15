import * as Sentry from '@sentry/react-native';
import { Platform } from 'react-native';
import type { Env } from './env';

let initialised = false;

/** Error reporting only: no tracing, no session replay, no PII (Free plan quota + privacy). */
export function initSentry(env: Pick<Env, 'sentryDsn' | 'appEnv'>): boolean {
  if (initialised || !env.sentryDsn || env.appEnv === 'local') return false;
  // Static web export renders pages in Node at build time: never start Sentry there.
  if (Platform.OS === 'web' && typeof window === 'undefined') return false;
  Sentry.init({
    dsn: env.sentryDsn,
    environment: env.appEnv,
    sendDefaultPii: false,
    tracesSampleRate: 0,
    enableAutoSessionTracking: false,
  });
  initialised = true;
  return true;
}

/** Test-only: allows each unit test to start from a fresh state. */
export function resetSentryForTests(): void {
  initialised = false;
}

export function sendTestError(): void {
  Sentry.captureException(new Error('MouldTrack dev test error (AC-13)'));
}
