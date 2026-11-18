import { router } from 'expo-router';
import { useEffect } from 'react';
import { AppState, Text, View } from 'react-native';
import { Button, colors } from '@/components/ui';
import { bannerText, fetchHandoverChecklist } from '@/lib/handover';
import { useSession } from '@/lib/session-provider';
import { useLoad } from '@/lib/use-load';
import { useRefreshOnFocus } from '@/lib/use-refresh';

const REFRESH_MS = 60_000;

/**
 * Supervisor Home: what is waiting in the handover checklist. Silent while loading, on an error and when nothing is waiting (the My shift card
 * carries the load and error states), so it never adds noise to Home.
 */
export function HandoverBanner() {
  const { client } = useSession();
  const c = useLoad(() => fetchHandoverChecklist(client), []);
  const { reload } = c;
  useRefreshOnFocus(reload);
  useEffect(() => {
    const timer = setInterval(reload, REFRESH_MS);
    const sub = AppState.addEventListener('change', (s) => {
      if (s === 'active') reload();
    });
    return () => {
      clearInterval(timer);
      sub.remove();
    };
  }, [reload]);
  const text = bannerText(c.data ?? c.latest);
  if (!text) return null;
  return (
    <View testID="handover-banner" accessibilityRole="alert" style={{ gap: 8, borderWidth: 2, borderColor: colors.primary, borderRadius: 12, padding: 16, backgroundColor: colors.bannerBg }}>
      <Text testID="handover-banner-text" style={{ fontSize: 18, fontWeight: '700', color: colors.bannerText }}>{text}</Text>
      <Button title="Open handover checklist" testID="handover-link" onPress={() => router.push('/handover')} />
    </View>
  );
}
