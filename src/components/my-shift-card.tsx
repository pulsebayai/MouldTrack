import { Text, View } from 'react-native';
import { Button, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import { fetchMyShift, formatPlantDate, timeWindow, type MyShift } from '@/lib/plant';
import { useSession } from '@/lib/session-provider';
import { useLoad } from './plant/use-load';

/** Supervisor home: the shift running now (or the next one) and the machines the server says are mine (AC-9, D11). */
export function MyShiftCard() {
  const { client } = useSession();
  const my = useLoad<MyShift>(() => fetchMyShift(client), []);
  const d = my.data;
  const box = { gap: 8, borderWidth: 2, borderColor: colors.primary, borderRadius: 12, padding: 16 } as const;
  const text = { fontSize: 16, color: colors.text } as const;
  return (
    <View testID="my-shift" style={box}>
      <Text accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>My shift</Text>
      {my.state === 'loading' ? <Text testID="my-shift-loading" style={text}>Loading your shift</Text> : null}
      {my.state === 'error' ? (
        <>
          <Text testID="my-shift-error" accessibilityRole="alert" style={{ fontSize: 16, color: colors.error }}>{toUserMessage(my.error)}</Text>
        </>
      ) : null}
      {d && d.state === 'no_shifts' ? <Text testID="my-shift-no-shifts" style={text}>No shifts set up yet</Text> : null}
      {d && d.state === 'none' ? <Text testID="my-shift-none" style={text}>No machines assigned for your next shift</Text> : null}
      {d && (d.state === 'running' || d.state === 'next') ? (
        <>
          <Text testID="my-shift-state" style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>
            {d.state === 'running' ? 'Running now' : `Starts ${formatPlantDate(d.shift_date)}`}
          </Text>
          <Text testID="my-shift-name" style={text}>{d.shift.name} · {timeWindow(d.shift.start_time, d.shift.end_time)}</Text>
          {d.machines.map((m) => (
            <Text key={m.machine_id} testID={`my-shift-machine-${m.machine_id}`} style={text}>
              {m.code} · {m.name}{m.line ? ` · ${m.line}` : ''}
            </Text>
          ))}
        </>
      ) : null}
      <Button title="Refresh" variant="secondary" testID="my-shift-refresh" onPress={my.reload} />
    </View>
  );
}
