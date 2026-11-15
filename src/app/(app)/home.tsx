import Constants from 'expo-constants';
import { Text, View } from 'react-native';
import { SignOutButton } from '@/components/sign-out-button';
import { Screen, colors } from '@/components/ui';
import type { AppEnv } from '@/lib/env';
import { roleLabel } from '@/lib/session';
import { useSession } from '@/lib/session-provider';

const ENV_LABEL: Record<AppEnv, string | null> = {
  local: 'LOCAL ENVIRONMENT',
  development: 'DEV ENVIRONMENT',
  staging: 'STAGING ENVIRONMENT',
  production: null,
};

export default function Home() {
  const { ctx, appEnv } = useSession();
  if (!ctx || 'noAccess' in ctx) return null; // the (app) layout redirects; nothing tenant-scoped renders here
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
      <Text style={{ fontSize: 15, color: colors.muted }}>{ctx.user.email}</Text>
      <SignOutButton />
      <Text style={{ fontSize: 12, color: colors.muted }}>Version {Constants.expoConfig?.version ?? '0.0.0'}</Text>
    </Screen>
  );
}
