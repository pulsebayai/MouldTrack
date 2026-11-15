import AsyncStorage from '@react-native-async-storage/async-storage';
import { createClient } from '@supabase/supabase-js';
import { AppState, Platform } from 'react-native';
import { getEnv } from './env';

const env = getEnv();
const isWeb = Platform.OS === 'web';

export const supabase = createClient(env.supabaseUrl, env.supabaseAnonKey, {
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
