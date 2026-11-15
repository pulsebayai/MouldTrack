export type AppEnv = 'local' | 'development' | 'staging' | 'production';
const APP_ENVS: AppEnv[] = ['local', 'development', 'staging', 'production'];

export type Env = {
  supabaseUrl: string;
  supabaseAnonKey: string;
  appEnv: AppEnv;
  sentryDsn: string | undefined;
};

type RawEnv = { url?: string; anonKey?: string; appEnv?: string; sentryDsn?: string };

export function readEnv(raw: RawEnv): Env {
  if (!raw.url) throw new Error('Missing EXPO_PUBLIC_SUPABASE_URL');
  if (!raw.anonKey) throw new Error('Missing EXPO_PUBLIC_SUPABASE_ANON_KEY');
  const appEnv = (raw.appEnv || 'local') as AppEnv;
  if (!APP_ENVS.includes(appEnv)) throw new Error(`Invalid EXPO_PUBLIC_APP_ENV "${raw.appEnv}"`);
  return { supabaseUrl: raw.url, supabaseAnonKey: raw.anonKey, appEnv, sentryDsn: raw.sentryDsn || undefined };
}

// Expo inlines EXPO_PUBLIC_* only for literal `process.env.X` accesses, so keep them spelled out.
export function getEnv(): Env {
  return readEnv({
    url: process.env.EXPO_PUBLIC_SUPABASE_URL,
    anonKey: process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY,
    appEnv: process.env.EXPO_PUBLIC_APP_ENV,
    sentryDsn: process.env.EXPO_PUBLIC_SENTRY_DSN,
  });
}
