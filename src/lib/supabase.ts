import AsyncStorage from '@react-native-async-storage/async-storage';
import { createClient } from '@supabase/supabase-js';
import { AppState, Platform } from 'react-native';
import { getEnv } from './env';
import { createRetryingFetch } from './fetch-retry';
import { addRetryBreadcrumb } from './sentry';

const env = getEnv();
const isWeb = Platform.OS === 'web';

export const supabase = createClient(env.supabaseUrl, env.supabaseAnonKey, {
  // Stalled reads retry once; writes, rpc and auth keep the platform default (fetch-retry.ts).
  global: { fetch: createRetryingFetch((...a) => fetch(...a), { onRetry: addRetryBreadcrumb }) },
  auth: {
    // Android: AsyncStorage. Web: the library default (localStorage).
    ...(isWeb ? {} : { storage: AsyncStorage }),
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: false,
  },
});

// Native: refresh tokens only while the app is in the foreground (Supabase React Native guidance).
if (!isWeb) {
  AppState.addEventListener('change', (state) => {
    if (state === 'active') supabase.auth.startAutoRefresh();
    else supabase.auth.stopAutoRefresh();
  });
}
