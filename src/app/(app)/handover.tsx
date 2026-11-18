import { router } from 'expo-router';
import { ScrollView, View } from 'react-native';
import { HandoverChecklist } from '@/components/handover/checklist';
import { NotAllowed } from '@/components/not-allowed';
import { Button, colors } from '@/components/ui';
import { isMember } from '@/lib/session';
import { useSession } from '@/lib/session-provider';

/** The supervisor's handover checklist (08, D9). The server also denies everyone else; this only avoids rendering an empty screen. */
export default function HandoverScreen() {
  const { ctx } = useSession();
  if (!isMember(ctx)) return null;
  if (ctx.role !== 'supervisor') return <NotAllowed />;
  return (
    <ScrollView testID="handover-screen" style={{ backgroundColor: colors.bg }} contentContainerStyle={{ alignItems: 'center', padding: 24 }}>
      <View style={{ width: '100%', maxWidth: 560, gap: 16 }}>
        <HandoverChecklist />
        <Button title="Back" variant="secondary" testID="handover-back" onPress={() => (router.canGoBack() ? router.back() : router.replace('/home'))} />
      </View>
    </ScrollView>
  );
}
