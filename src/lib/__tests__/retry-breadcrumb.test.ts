import * as Sentry from '@sentry/react-native';
import { addRetryBreadcrumb, initSentry, resetSentryForTests } from '@/lib/sentry';

jest.mock('@sentry/react-native', () => ({ init: jest.fn(), addBreadcrumb: jest.fn(), captureException: jest.fn() }));

describe('retry breadcrumb (D1)', () => {
  beforeEach(() => {
    resetSentryForTests();
    jest.clearAllMocks();
  });
  it('does nothing before Sentry is initialised', () => {
    addRetryBreadcrumb('x.supabase.co/rest/v1/membership');
    expect(Sentry.addBreadcrumb).not.toHaveBeenCalled();
  });
  it('adds a breadcrumb with the path only once initialised', () => {
    initSentry({ sentryDsn: 'https://k@o.ingest.sentry.io/1', appEnv: 'development' });
    addRetryBreadcrumb('x.supabase.co/rest/v1/membership');
    expect(Sentry.addBreadcrumb).toHaveBeenCalledWith(expect.objectContaining({ category: 'network', data: { path: 'x.supabase.co/rest/v1/membership' } }));
  });
});
