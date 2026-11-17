import { useEffect } from 'react';
import { AppState, Text, View } from 'react-native';
import { Button, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import { fetchMyShift, formatPlantDate, timeWindow, type MyShift } from '@/lib/plant';
import { useSession } from '@/lib/session-provider';
import { useLoad } from '@/lib/use-load';

const REFRESH_MS = 60_000;

/** Supervisor home: every shift running now that I own machines in (or the next one) and the machines the server says are mine (AC-9, D11). */
export function MyShiftCard() {
  const { client } = useSession();
  const my = useLoad<MyShift>(() => fetchMyShift(client), []);
  const { reload } = my;
  // A shift boundary passes while the card is open: refetch when the app comes back to the foreground and every minute. (AppState rather than a router focus hook: the card also renders outside a navigator in tests.)
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
  // Keep showing the last answer while a refetch is in flight, so the card doesn't flicker every minute.
  const d = my.data ?? my.latest;
  const box = { gap: 8, borderWidth: 2, borderColor: colors.primary, borderRadius: 12, padding: 16 } as const;
  const text = { fontSize: 16, color: colors.text } as const;
  return (
    <View testID="my-shift" style={box}>
      <Text accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>My shift</Text>
      {my.state === 'loading' && !d ? <Text testID="my-shift-loading" accessibilityLiveRegion="polite" style={text}>Loading your shift</Text> : null}
      {my.state === 'error' ? (
        <Text testID="my-shift-error" accessibilityRole="alert" style={{ fontSize: 16, color: colors.error }}>{toUserMessage(my.error)}</Text>
      ) : null}
      {d && d.state === 'no_shifts' ? <Text testID="my-shift-no-shifts" style={text}>No shifts set up yet</Text> : null}
      {d && d.state === 'none' ? <Text testID="my-shift-none" style={text}>No machines assigned in the next 36 hours</Text> : null}
      {d && (d.state === 'running' || d.state === 'next')
        ? d.occurrences.map((o, i) => (
            <View key={`${o.shift.id}:${o.shift_date}`} testID={`my-shift-occurrence-${i}`} style={{ gap: 8 }}>
              <Text testID={`my-shift-state-${i}`} style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>
                {o.running ? 'Running now' : `Starts ${formatPlantDate(o.shift_date)}`}
              </Text>
              <Text testID={`my-shift-name-${i}`} style={text}>{o.shift.name} · {timeWindow(o.shift.start_time, o.shift.end_time)}</Text>
              {o.machines.map((m) => (
                <Text key={m.machine_id} testID={`my-shift-machine-${o.shift.id}-${m.machine_id}`} style={text}>
                  {m.code} · {m.name}{m.line ? ` · ${m.line}` : ''}
                </Text>
              ))}
            </View>
          ))
        : null}
      <Button title="Refresh" variant="secondary" testID="my-shift-refresh" onPress={reload} />
    </View>
  );
}
