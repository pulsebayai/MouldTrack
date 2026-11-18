import { router } from 'expo-router';
import { useEffect } from 'react';
import { AppState, Text, View } from 'react-native';
import { Button, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import { formatPlantDate, timeWindow } from '@/lib/plant';
import { STATE_LABEL, fetchReadingState, type ReadingState } from '@/lib/readings';
import { useSession } from '@/lib/session-provider';
import { useLoad } from '@/lib/use-load';
import { SummaryBlock } from './summary-block';

const REFRESH_MS = 60_000;

/** Supervisor home: the readings of my machines in every shift occurrence that is open for readings (AC-11). Rendered from reading_state only. */
export function ReadingsCard() {
  const { client } = useSession();
  const st = useLoad<ReadingState>(() => fetchReadingState(client), []);
  const { reload } = st;
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
  const d = st.data ?? st.latest;
  const text = { fontSize: 16, color: colors.text } as const;
  return (
    <View testID="readings" style={{ gap: 8, borderWidth: 2, borderColor: colors.primary, borderRadius: 12, padding: 16 }}>
      <Text accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>Readings</Text>
      {st.state === 'loading' && !d ? <Text testID="readings-loading" accessibilityLiveRegion="polite" style={text}>Loading readings</Text> : null}
      {st.state === 'error' ? <Text testID="readings-error" accessibilityRole="alert" style={{ fontSize: 16, color: colors.error }}>{toUserMessage(st.error)}</Text> : null}
      {d && d.state === 'no_shifts' ? <Text testID="readings-none" style={text}>No shifts set up yet</Text> : null}
      {d && d.state === 'none' ? <Text testID="readings-none" style={text}>No readings to record right now</Text> : null}
      {(d?.occurrences ?? []).map((o, i) => (
        <View key={`${o.shift.id}:${o.shift_date}`} testID={`readings-occurrence-${i}`} style={{ gap: 8 }}>
          <Text style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>
            {o.shift.name} · {timeWindow(o.shift.start_time, o.shift.end_time)} · {formatPlantDate(o.shift_date)}
          </Text>
          {o.machines.map((m) => {
            const key = `${o.shift.id}-${m.machine_id}-${o.shift_date}`;
            const go = (pathname: string, extra: Record<string, string> = {}) =>
              router.push({ pathname: pathname as never, params: { machineId: m.machine_id, shiftId: o.shift.id, date: o.shift_date, ...extra } });
            return (
              <View key={m.machine_id} testID={`reading-machine-${key}`} style={{ gap: 6 }}>
                <Text style={text}>{m.code} · {m.name}</Text>
                <Text testID={`reading-state-${key}`} style={{ fontSize: 15, fontWeight: '700', color: colors.text }}>{STATE_LABEL[m.state]}</Text>
                {m.summary ? <SummaryBlock s={m.summary} testID={`reading-summary-${key}`} late={{ opening: m.opening?.late, closing: m.closing?.late }} /> : null}
                {m.can_open ? <Button title={`Record opening for ${m.code}`} testID={`reading-open-${key}`} onPress={() => go('/readings/record', { kind: 'opening' })} /> : null}
                {m.can_close ? <Button title={`Record closing for ${m.code}`} testID={`reading-close-${key}`} onPress={() => go('/readings/record', { kind: 'closing' })} /> : null}
                {m.opening || m.closing ? <Button title={`Details for ${m.code}`} variant="secondary" testID={`reading-details-${key}`} onPress={() => go('/readings/occurrence')} /> : null}
              </View>
            );
          })}
        </View>
      ))}
      <Button title="Refresh readings" variant="secondary" testID="readings-refresh" onPress={reload} />
    </View>
  );
}
