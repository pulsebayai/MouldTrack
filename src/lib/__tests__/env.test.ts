import { readEnv } from '@/lib/env';

describe('readEnv', () => {
  it('returns typed values', () => {
    expect(readEnv({ url: 'http://127.0.0.1:54321', anonKey: 'k', appEnv: 'local', sentryDsn: '' })).toEqual({
      supabaseUrl: 'http://127.0.0.1:54321', supabaseAnonKey: 'k', appEnv: 'local', sentryDsn: undefined,
    });
  });
  it('throws a clear error when Supabase config is missing', () => {
    expect(() => readEnv({ url: '', anonKey: 'k', appEnv: 'local' })).toThrow(/EXPO_PUBLIC_SUPABASE_URL/);
    expect(() => readEnv({ url: 'x', anonKey: undefined, appEnv: 'local' })).toThrow(/EXPO_PUBLIC_SUPABASE_ANON_KEY/);
  });
  it('rejects unknown environments', () => {
    expect(() => readEnv({ url: 'x', anonKey: 'k', appEnv: 'qa' })).toThrow(/EXPO_PUBLIC_APP_ENV/);
  });
});
