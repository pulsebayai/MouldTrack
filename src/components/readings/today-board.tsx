import { router } from 'expo-router';
import { useEffect } from 'react';
import { AppState, ScrollView, Text, View } from 'react-native';
import { Loading, LoadError } from '@/components/plant/common';
import { Button, colors } from '@/components/ui';
import { formatPlantDate, timeWindow } from '@/lib/plant';
import { STATUS_LABEL, attainmentText, closingStatusText, fetchTodayBoard, formatCount, formatPct, type TodayBoard } from '@/lib/readings';
import { useSession } from '@/lib/session-provider';
import { useLoad } from '@/lib/use-load';
import { useRefreshOnFocus } from '@/lib/use-refresh';
import { FlagList } from './summary-block';

const REFRESH_MS = 60_000;

/** Unit Admin "Today": the current and the previous occurrence of every shift, each machine's target next to its actual (AC-12). Bounded by the server. */
export function TodayBoardView() {
  const { client } = useSession();
  const board = useLoad<TodayBoard>(() => fetchTodayBoard(client), []);
  const { reload } = board;
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
  const d = board.data ?? board.latest;
  const text = { fontSize: 15, color: colors.text } as const;
  return (
    <ScrollView testID="today-screen" contentContainerStyle={{ alignItems: 'center', padding: 24 }}>
      <View style={{ width: '100%', maxWidth: 900, gap: 16 }}>
        <Text accessibilityRole="header" style={{ fontSize: 24, fontWeight: '700', color: colors.text }}>Today</Text>
        {board.state === 'loading' && !d ? <Loading testID="today-loading" label="Loading" /> : null}
        {board.state === 'error' ? <LoadError testID="today-error" onRetry={board.reload} error={board.error} /> : null}
        {d && (d.occurrences ?? []).length === 0 ? <Text testID="today-empty" style={text}>No shift has started yet, or no machine is assigned.</Text> : null}
        {(d?.occurrences ?? []).map((o) => {
          const k = `${o.shift.id}-${o.shift_date}`;
          return (
            <View key={k} testID={`today-occurrence-${k}`} style={{ gap: 8, borderWidth: 1, borderColor: colors.border, borderRadius: 8, padding: 12 }}>
              <Text accessibilityRole="header" style={{ fontSize: 18, fontWeight: '700', color: colors.text }}>
                {o.shift.name} · {timeWindow(o.shift.start_time, o.shift.end_time)} · {formatPlantDate(o.shift_date)}{o.running ? ' · Running now' : o.current ? ' · Latest' : ' · Previous'}
              </Text>
              <Text testID={`today-totals-${k}`} style={text}>
                {o.totals.machines_expected} machines · opening on time {o.totals.openings_on_time} · closing on time {o.totals.closings_on_time} · {(o.assumed_target ?? 0) > 0 ? 'target set' : 'target'} {formatCount(o.totals.target - (o.assumed_target ?? 0))}
                {(o.assumed_target ?? 0) > 0 ? ` · assumed from the default product (no opening yet) ${formatCount(o.assumed_target)}` : ''} · good (closed) {formatCount(o.totals.good)} · attainment {formatPct(o.totals.attainment_pct)}
              </Text>
              {o.machines.map((m) => (
                <View key={m.machine_id} testID={`today-machine-${k}-${m.machine_id}`} style={{ gap: 2, paddingVertical: 6, borderTopWidth: 1, borderTopColor: '#E6EAEE' }}>
                  <Text style={{ fontSize: 16, fontWeight: '700', color: colors.text }}>{m.code} · {m.name} · {m.owner_name ?? 'Unknown supervisor'}</Text>
                  <Text style={text}>
                    Opening: {STATUS_LABEL[m.opening_status]} · Closing: {closingStatusText(m.closing_status, o.running)}{m.product_code ? ` · ${m.product_code}` : ''}
                  </Text>
                  <Text testID={`today-target-${k}-${m.machine_id}`} style={text}>
                    Target: {m.target === null ? 'No target set' : `${formatCount(m.target)}${m.target_assumed ? ' (default product)' : ''}`} · Good: {formatCount(m.good)} · Attainment: {attainmentText(m)}
                  </Text>
                  <Text testID={`today-movement-${k}-${m.machine_id}`} style={text}>
                    Counter movement: {m.movement_pieces === null ? '-' : `${formatCount(m.movement_pieces)} pieces`} · Reject: {formatCount(m.reject)} · Unaccounted: {formatCount(m.unaccounted)}
                  </Text>
                  <FlagList testID={`today-flags-${k}-${m.machine_id}`} flags={m.flags} />
                  <Button title={`Open ${m.code}`} variant="secondary" testID={`today-open-${k}-${m.machine_id}`}
                    onPress={() => router.push({ pathname: '/readings/occurrence' as never, params: { machineId: m.machine_id, shiftId: o.shift.id, date: o.shift_date } })} />
                </View>
              ))}
            </View>
          );
        })}
        <Button title="Refresh" variant="secondary" testID="today-refresh" onPress={reload} />
        <Button title="Back" variant="secondary" testID="today-back" onPress={() => (router.canGoBack() ? router.back() : router.replace('/home'))} />
      </View>
    </ScrollView>
  );
}
