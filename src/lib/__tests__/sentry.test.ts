import * as Sentry from '@sentry/react-native';
import { initSentry, resetSentryForTests, scrubEvent, sendTestError } from '@/lib/sentry';

jest.mock('@sentry/react-native', () => ({ init: jest.fn(), captureException: jest.fn() }));

const DSN = 'https://k@o1.ingest.sentry.io/1';

describe('Sentry wiring (AC-13)', () => {
  beforeEach(() => {
    resetSentryForTests();
    jest.clearAllMocks();
  });

  it('does nothing without a DSN or in local runs', () => {
    expect(initSentry({ sentryDsn: undefined, appEnv: 'development' })).toBe(false);
    expect(initSentry({ sentryDsn: DSN, appEnv: 'local' })).toBe(false);
    expect(Sentry.init).not.toHaveBeenCalled();
  });

  it('initialises once with the environment, no tracing and no PII', () => {
    expect(initSentry({ sentryDsn: DSN, appEnv: 'development' })).toBe(true);
    expect(initSentry({ sentryDsn: DSN, appEnv: 'development' })).toBe(false);
    expect(Sentry.init).toHaveBeenCalledTimes(1);
    expect(Sentry.init).toHaveBeenCalledWith(
      expect.objectContaining({ dsn: DSN, environment: 'development', sendDefaultPii: false, tracesSampleRate: 0 }),
    );
  });

  it('sendTestError reports an identifiable error', () => {
    sendTestError();
    expect(Sentry.captureException).toHaveBeenCalledWith(expect.objectContaining({ message: expect.stringContaining('AC-13') }));
  });
});

describe('scrubEvent (02, D12): no names, phones, passwords or employee ids leave the device', () => {
  it('is installed as beforeSend', () => {
    resetSentryForTests();
    initSentry({ sentryDsn: DSN, appEnv: 'development' });
    expect(Sentry.init).toHaveBeenCalledWith(expect.objectContaining({ beforeSend: scrubEvent }));
  });

  it('drops the request of Edge Function calls entirely', () => {
    const out = scrubEvent({ request: { url: 'https://x.supabase.co/functions/v1/user-admin', data: '{"phone":"9876543210"}', headers: { a: 'b' } }, message: 'm' } as never) as { request?: unknown };
    expect(out.request).toBeUndefined();
  });

  it('removes bodies and cookies from other requests', () => {
    const out = scrubEvent({ request: { url: 'https://x/rest/v1/membership', data: 'secret', cookies: { s: '1' }, method: 'GET' } } as never) as { request: Record<string, unknown> };
    expect(out.request.data).toBeUndefined();
    expect(out.request.cookies).toBeUndefined();
    expect(out.request.method).toBe('GET');
  });

  it('strips breadcrumb data for function calls and sensitive keys elsewhere', () => {
    const out = scrubEvent({
      breadcrumbs: [
        { category: 'fetch', data: { url: 'https://x/functions/v1/account', body: 'p' } },
        { category: 'ui', data: { phone: '9876543210', ok: 1 } },
      ],
    } as never) as { breadcrumbs: { data?: Record<string, unknown> }[] };
    expect(out.breadcrumbs[0].data).toBeUndefined();
    expect(out.breadcrumbs[1].data).toEqual({ phone: '[Filtered]', ok: 1 });
  });

  it.each(['phone', 'phone_e164', 'password', 'current_password', 'full_name', 'employee_id', 'Phone'])('filters %s in extra, contexts and tags', (key) => {
    const out = scrubEvent({ extra: { [key]: 'v', keep: 'k' }, contexts: { form: { [key]: 'v' } }, tags: { [key]: 'v' } } as never) as {
      extra: Record<string, unknown>; contexts: { form: Record<string, unknown> }; tags: Record<string, unknown>;
    };
    expect(out.extra).toEqual({ [key]: '[Filtered]', keep: 'k' });
    expect(out.contexts.form[key]).toBe('[Filtered]');
    expect(out.tags[key]).toBe('[Filtered]');
  });

  it('never returns null (events are still reported)', () => {
    expect(scrubEvent({} as never)).toEqual({});
  });
});
