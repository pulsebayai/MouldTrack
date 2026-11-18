import { router } from 'expo-router';
import { ScrollView, View } from 'react-native';
import { ReadingsCard } from '@/components/readings/readings-card';
import { Button, colors } from '@/components/ui';

/** The supervisor's readings: kept off Home so Home makes no extra call per minute (05's tests pin Home's calls). */
export default function ReadingsScreen() {
  return (
    <ScrollView testID="readings-screen" style={{ backgroundColor: colors.bg }} contentContainerStyle={{ alignItems: 'center', padding: 24 }}>
      <View style={{ width: '100%', maxWidth: 560, gap: 16 }}>
        <ReadingsCard />
        <Button title="Back" variant="secondary" testID="readings-back" onPress={() => (router.canGoBack() ? router.back() : router.replace('/home'))} />
      </View>
    </ScrollView>
  );
}
