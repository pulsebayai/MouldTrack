import { router } from 'expo-router';
import { Text } from 'react-native';
import { SignOutButton } from '@/components/sign-out-button';
import { Screen, colors } from '@/components/ui';

export default function NoAccess() {
  return (
    <Screen>
      <Text testID="no-access" accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>
        No access — contact your administrator
      </Text>
      <Text style={{ fontSize: 15, color: colors.muted }}>
        Your account is not linked to an active manufacturing unit.
      </Text>
      <SignOutButton onSignedOut={() => router.replace('/sign-in')} />
    </Screen>
  );
}
