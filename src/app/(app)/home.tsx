import Constants from 'expo-constants';
import { router } from 'expo-router';
import { useState } from 'react';
import { Platform, Text, View } from 'react-native';
import { SignOutButton } from '@/components/sign-out-button';
import { Button, Screen, colors } from '@/components/ui';
import type { AppEnv } from '@/lib/env';
import { authEmailToPhone, formatPhone } from '@/lib/identity';
import { sendTestError } from '@/lib/sentry';
import { isMember, roleLabel } from '@/lib/session';
import { useSession } from '@/lib/session-provider';

const ENV_LABEL: Record<AppEnv, string | null> = {
  local: 'LOCAL ENVIRONMENT',
  development: 'DEV ENVIRONMENT',
  staging: 'STAGING ENVIRONMENT',
  production: null,
};

export default function Home() {
  const { ctx, appEnv } = useSession();
  const [testErrorSent, setTestErrorSent] = useState(false);
  if (!isMember(ctx)) return null; // the (app) layout redirects; nothing tenant-scoped renders here
  const phone = ctx.user.email ? authEmailToPhone(ctx.user.email) : null;
  const banner = ENV_LABEL[appEnv];
  return (
    <Screen testID="home-screen">
      {banner ? (
        <View style={{ backgroundColor: colors.bannerBg, padding: 8, borderRadius: 6 }}>
          <Text testID="env-banner" style={{ color: colors.bannerText, fontWeight: '700', textAlign: 'center' }}>
            {banner}
          </Text>
        </View>
      ) : null}
      <Text testID="home-tenant" accessibilityRole="header" style={{ fontSize: 24, fontWeight: '700', color: colors.text }}>
        {ctx.tenant.name}
      </Text>
      <Text testID="home-role" style={{ fontSize: 16, color: colors.text }}>
        Role: {roleLabel(ctx.role)}
      </Text>
      <Text style={{ fontSize: 15, color: colors.muted }}>{phone ? formatPhone(phone) : ctx.user.email}</Text>
      {ctx.role === 'unit_admin' && Platform.OS === 'web' ? (
        <Button title="Users" testID="users-link" onPress={() => router.push('/users')} />
      ) : null}
      {ctx.role === 'unit_admin' && Platform.OS === 'web' ? (
        <Button title="Plant" testID="plant-link" onPress={() => router.push('/plant')} />
      ) : null}
      <Button title="Change password" variant="secondary" testID="change-password-link" onPress={() => router.push('/change-password')} />
      <SignOutButton />
      {appEnv === 'development' ? (
        <>
          <Button
            title="Send test error"
            variant="secondary"
            testID="send-test-error"
            onPress={() => {
              sendTestError();
              setTestErrorSent(true);
            }}
          />
          {testErrorSent ? (
            <Text testID="test-error-sent" accessibilityLiveRegion="polite" style={{ fontSize: 14, color: colors.text }}>
              Test error sent to Sentry
            </Text>
          ) : null}
        </>
      ) : null}
      <Text style={{ fontSize: 12, color: colors.muted }}>Version {Constants.expoConfig?.version ?? '0.0.0'}</Text>
    </Screen>
  );
}
