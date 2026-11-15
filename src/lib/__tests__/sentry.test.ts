import * as Sentry from '@sentry/react-native';
import { initSentry, resetSentryForTests, sendTestError } from '@/lib/sentry';

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
