import * as Sentry from '@sentry/react-native';
import { Platform } from 'react-native';
import type { Env } from './env';

let initialised = false;

const SENSITIVE_KEY = /phone|password|full_name|employee_id/i;
const FUNCTION_CALL = /\/functions\/v1\//;

function filterKeys<T>(value: T): T {
  if (Array.isArray(value)) return value.map(filterKeys) as unknown as T;
  if (value && typeof value === 'object') {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) out[k] = SENSITIVE_KEY.test(k) ? '[Filtered]' : filterKeys(v);
    return out as T;
  }
  return value;
}

/**
 * beforeSend (02, D12): request bodies and cookies never leave the device, nothing about Edge Function calls is kept,
 * and any key that looks like a phone, password, name or employee id is replaced. Always returns the event.
 */
export function scrubEvent<T extends Record<string, any>>(event: T): T {
  const e: Record<string, any> = { ...event };
  if (e.request) {
    if (typeof e.request.url === 'string' && FUNCTION_CALL.test(e.request.url)) delete e.request;
    else {
      const { data: _data, cookies: _cookies, ...rest } = e.request;
      e.request = rest;
    }
  }
  if (Array.isArray(e.breadcrumbs)) {
    e.breadcrumbs = e.breadcrumbs.map((b: Record<string, any>) => {
      const url = String(b?.data?.url ?? b?.message ?? '');
      if (FUNCTION_CALL.test(url)) {
        const { data: _d, ...rest } = b;
        return rest;
      }
      return b?.data ? { ...b, data: filterKeys(b.data) } : b;
    });
  }
  for (const key of ['extra', 'contexts', 'tags'] as const) if (e[key]) e[key] = filterKeys(e[key]);
  return e as T;
}

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
    beforeSend: scrubEvent,
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
