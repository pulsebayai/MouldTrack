import { router } from 'expo-router';
import { useEffect } from 'react';
import { AppState, Text, View } from 'react-native';
import { IssueRowView } from '@/components/issues/issue-row';
import { Button, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import { fetchIssueAlerts, type IssueAlerts } from '@/lib/issues';
import { fetchPlantTimezone, formatPlantDay } from '@/lib/plant-time';
import { useRefreshOnFocus } from '@/lib/use-refresh';
import { useSession } from '@/lib/session-provider';
import { useLoad } from '@/lib/use-load';

const REFRESH_MS = 60_000;
/** D16: Home shows at most this many of each list; the Issues screen has the rest, paginated. */
const SHOWN = 5;

/** Unit Admin Home: open High/Critical issues (the server orders them, stopped machines first) and what closed in the last 7 days (D11). */
export function IssueAlertsCard({ showAll = true }: { showAll?: boolean }) {
  const { client } = useSession();
  const alerts = useLoad<IssueAlerts>(() => fetchIssueAlerts(client), []);
  const { reload } = alerts;
  useRefreshOnFocus(reload);
  const tz = useLoad(() => fetchPlantTimezone(client), []).data ?? 'Asia/Kolkata';
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
  const d = alerts.data ?? alerts.latest;
  const text = { fontSize: 16, color: colors.text } as const;
  return (
    <View testID="issue-alerts" style={{ gap: 8, borderWidth: 2, borderColor: colors.primary, borderRadius: 12, padding: 16 }}>
      <Text accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>
        Issue alerts{d ? ` (${d.alert_count})` : ''}
      </Text>
      {alerts.state === 'loading' && !d ? <Text testID="issue-alerts-loading" accessibilityLiveRegion="polite" style={text}>Loading alerts</Text> : null}
      {alerts.state === 'error' ? <Text testID="issue-alerts-error" accessibilityRole="alert" style={{ fontSize: 16, color: colors.error }}>{toUserMessage(alerts.error)}</Text> : null}
      {d && d.alerts.length === 0 ? <Text testID="issue-alerts-empty" style={text}>No open High or Critical issues</Text> : null}
      {d?.alerts.slice(0, SHOWN).map((i) => <IssueRowView key={i.id} issue={i} prefix="alert" />)}
      {d && d.alerts.length > SHOWN ? (
        <Button title={`${d.alerts.length - SHOWN} more - View all alerts`} variant="secondary" testID="issue-alerts-more" onPress={() => router.push({ pathname: '/issues', params: { tab: 'alerts' } })} />
      ) : null}
      {d && d.recently_closed.length > 0 ? (
        <View testID="issue-recently-closed" style={{ gap: 8 }}>
          <Text accessibilityRole="header" style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>Recently closed</Text>
          {d.recently_closed.slice(0, SHOWN).map((i) => (
            <View key={i.id} testID={`closed-${i.id}`} style={{ gap: 2 }}>
              <Text style={text}>{i.machine_code} · {i.category}</Text>
              <Text style={{ fontSize: 14, color: colors.muted }}>
                Closed {i.closed_at ? formatPlantDay(i.closed_at, tz) : ''}{i.closed_by_name ? ` by ${i.closed_by_name}` : ''}
              </Text>
            </View>
          ))}
          {d.recently_closed.length > SHOWN ? (
            <Button title={`${d.recently_closed.length - SHOWN} more - View closed issues`} variant="secondary" testID="issue-closed-more" onPress={() => router.push({ pathname: '/issues', params: { tab: 'closed' } })} />
          ) : null}
        </View>
      ) : null}
      {showAll ? <Button title="All issues" variant="secondary" testID="issue-alerts-all" onPress={() => router.push('/issues')} /> : null}
      <Button title="Refresh" variant="secondary" testID="issue-alerts-refresh" onPress={reload} />
    </View>
  );
}
