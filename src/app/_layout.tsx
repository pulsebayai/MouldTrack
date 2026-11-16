import { Stack } from 'expo-router';
import { ActivityIndicator, Text } from 'react-native';
import { Button, Screen, colors } from '@/components/ui';
import { getEnv } from '@/lib/env';
import { MESSAGES } from '@/lib/errors';
import { initSentry } from '@/lib/sentry';
import { SessionProvider, useSession } from '@/lib/session-provider';
import { supabase } from '@/lib/supabase';

const env = getEnv();
initSentry(env);

function Gate() {
  const { status, refresh } = useSession();
  if (status === 'loading') {
    return (
      <Screen testID="loading">
        <ActivityIndicator size="large" color={colors.primary} accessibilityLabel="Loading MouldTrack" />
      </Screen>
    );
  }
  if (status === 'error') {
    return (
      <Screen testID="network-error">
        <Text style={{ fontSize: 16, color: colors.text }}>{MESSAGES.network}</Text>
        <Button title="Try again" testID="retry" onPress={refresh} />
      </Screen>
    );
  }
  return <Stack screenOptions={{ headerShown: false, title: 'MouldTrack' }} />;
}

export default function RootLayout() {
  return (
    <SessionProvider client={supabase} appEnv={env.appEnv}>
      <Gate />
    </SessionProvider>
  );
}
