import { router } from 'expo-router';
import { Text } from 'react-native';
import { Button, Screen, colors } from '@/components/ui';

export function NotAllowed() {
  return (
    <Screen>
      <Text testID="not-allowed" accessibilityRole="header" style={{ fontSize: 22, fontWeight: '700', color: colors.text }}>
        Not allowed
      </Text>
      <Button title="Back to Home" variant="secondary" testID="not-allowed-home" onPress={() => router.replace('/home')} />
    </Screen>
  );
}
