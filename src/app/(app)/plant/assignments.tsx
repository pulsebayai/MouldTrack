import { useState } from 'react';
import { Pressable, Text, View } from 'react-native';
import { AssignForm, CoverForm, EndForm } from '@/components/plant/assignment-forms';
import { Label, Loading, LoadError, rowStyle } from '@/components/plant/common';
import { usePlant } from '@/components/plant/plant-context';
import { useLoad } from '@/components/plant/use-load';
import { Button, Chip, Field, StatusLabel, colors } from '@/components/ui';
import {
  fetchActiveSupervisors, fetchShiftBoard, fetchShifts, formatPlantDate, groupBoard, isValidDate, timeWindow, type BoardMachine,
} from '@/lib/plant';
import { useSession } from '@/lib/session-provider';

type Action = 'assign' | 'cover' | 'end' | null;

const sourceLabel = (m: BoardMachine): string => (m.source === 'cover' ? `Cover: ${m.reason ?? ''}`.trim() : m.source === 'plan' ? 'Plan' : 'No plan');

/** Assignments tab (AC-9): the shift board for one shift occurrence. Ownership is resolved by the server (cover > plan > unassigned). */
export default function AssignmentsTab() {
  const { client } = useSession();
  const { today } = usePlant();
  const [shiftId, setShiftId] = useState<string | null>(null);
  const [date, setDate] = useState(today ?? '');
  const [selected, setSelected] = useState<string[]>([]);
  const [action, setAction] = useState<Action>(null);

  const base = useLoad(async () => ({ shifts: await fetchShifts(client), supervisors: await fetchActiveSupervisors(client) }), []);
  const shifts = base.data?.shifts ?? [];
  const activeShiftId = shiftId ?? shifts[0]?.id ?? null;
  const dateOk = isValidDate(date.trim());
  const board = useLoad(() => fetchShiftBoard(client, activeShiftId!, date.trim()), [activeShiftId, date.trim()], !!activeShiftId && dateOk);
  const data = board.data;
  const grouped = data ? groupBoard(data.machines) : null;

  const toggle = (id: string) => setSelected((s) => (s.includes(id) ? s.filter((x) => x !== id) : [...s, id]));
  const done = () => {
    setAction(null);
    setSelected([]);
    board.reload();
  };
  const machineRow = (m: BoardMachine) => {
    const on = selected.includes(m.machine_id);
    return (
      <Pressable
        key={m.machine_id}
        testID={`board-machine-${m.machine_id}`}
        accessibilityRole="checkbox"
        accessibilityLabel={`${m.code} ${m.name}`}
        accessibilityState={{ checked: on }}
        onPress={() => toggle(m.machine_id)}
        style={{ minHeight: 48, flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center', gap: 12, borderWidth: on ? 2 : 1, borderColor: on ? colors.primary : colors.border, borderRadius: 8, paddingHorizontal: 12, paddingVertical: 6 }}
      >
        <Text style={{ fontSize: 16, fontWeight: on ? '700' : '400', color: colors.text }}>{on ? '✓ ' : ''}{m.code} · {m.name}</Text>
        <Text testID={`board-source-${m.machine_id}`} style={{ fontSize: 14, color: colors.text }}>{sourceLabel(m)}</Text>
        {m.status === 'under_maintenance' ? <Text style={{ fontSize: 14, color: colors.text }}>Under maintenance</Text> : null}
      </Pressable>
    );
  };

  return (
    <View testID="assignments-tab" style={{ gap: 16 }}>
      <Text accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>Assignments</Text>
      {base.state === 'loading' ? <Loading testID="assignments-loading" label="Loading shifts" /> : null}
      {base.state === 'error' ? <LoadError testID="assignments-error" onRetry={base.reload} error={base.error} /> : null}
      {base.state === 'ready' && shifts.length === 0 ? (
        <Text testID="assignments-no-shifts" style={{ fontSize: 16, color: colors.text }}>No shifts yet — add a shift on the Shifts tab first</Text>
      ) : null}

      {base.state === 'ready' && shifts.length > 0 ? (
        <>
          <View style={{ gap: 8 }}>
            <Label>Shift</Label>
            <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
              {shifts.map((s) => (
                <Chip
                  key={s.id}
                  testID={`board-shift-${s.id}`}
                  label={`${s.name} · ${timeWindow(s.start_time, s.end_time)}`}
                  selected={activeShiftId === s.id}
                  onPress={() => { setShiftId(s.id); setSelected([]); setAction(null); }}
                />
              ))}
            </View>
          </View>
          <Field
            label="Shift date (YYYY-MM-DD)"
            testID="board-date"
            value={date}
            onChangeText={(v) => { setDate(v); setSelected([]); setAction(null); }}
            error={dateOk ? null : 'Enter a date as YYYY-MM-DD'}
            placeholder="YYYY-MM-DD"
            autoCapitalize="none"
            autoComplete="off"
          />

          {board.state === 'loading' && dateOk ? <Loading testID="board-loading" label="Loading board" /> : null}
          {board.state === 'error' ? <LoadError testID="board-error" onRetry={board.reload} error={board.error} /> : null}
          {data && grouped ? (
            <View testID="board" style={{ gap: 16 }}>
              <Text testID="board-heading" style={{ fontSize: 16, color: colors.text }}>
                {data.shift.name} · {timeWindow(data.shift.start_time, data.shift.end_time)} · {formatPlantDate(data.shift_date)}
              </Text>
              {data.machines.length === 0 ? <Text testID="board-empty" style={{ fontSize: 16, color: colors.text }}>No machines yet — add machines on the Machines tab</Text> : null}

              {grouped.unassigned.length > 0 ? (
                <View testID="board-group-unassigned" style={{ ...rowStyle, borderWidth: 2 }}>
                  <Text accessibilityRole="header" testID="board-unassigned-title" style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>
                    Unassigned this shift ({data.unassigned_count})
                  </Text>
                  {grouped.unassigned.map(machineRow)}
                </View>
              ) : null}
              {grouped.groups.map((g) => (
                <View key={g.ownerId} testID={`board-group-${g.ownerId}`} style={rowStyle}>
                  <View style={{ flexDirection: 'row', gap: 12, flexWrap: 'wrap', alignItems: 'center' }}>
                    <Text accessibilityRole="header" style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>{g.name}</Text>
                    {g.inactive ? <StatusLabel testID={`board-inactive-${g.ownerId}`} status="Inactive supervisor" /> : null}
                    <Text style={{ fontSize: 14, color: colors.text }}>{g.machines.length} {g.machines.length === 1 ? 'machine' : 'machines'}</Text>
                  </View>
                  {g.machines.map(machineRow)}
                </View>
              ))}

              {selected.length > 0 ? (
                <View testID="board-actions" style={{ gap: 8 }}>
                  <Text testID="board-selected-count" style={{ fontSize: 15, color: colors.text }}>{selected.length} selected</Text>
                  <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
                    <Button title="Assign to…" testID="board-assign" onPress={() => setAction('assign')} />
                    <Button title="Cover this shift…" variant="secondary" testID="board-cover" onPress={() => setAction('cover')} />
                    <Button title="End assignment" variant="secondary" testID="board-end" onPress={() => setAction('end')} />
                  </View>
                </View>
              ) : null}
              {action && selected.length > 0 ? (
                <ActionForm action={action} board={data} selected={selected} supervisors={base.data?.supervisors ?? []} today={today} onDone={done} onCancel={() => setAction(null)} />
              ) : null}
            </View>
          ) : null}
        </>
      ) : null}
    </View>
  );
}

function ActionForm(p: { action: Exclude<Action, null>; board: NonNullable<ReturnType<typeof useLoad<Awaited<ReturnType<typeof fetchShiftBoard>>>>['data']>; selected: string[]; supervisors: Awaited<ReturnType<typeof fetchActiveSupervisors>>; today: string | null; onDone: () => void; onCancel: () => void }) {
  const common = { board: p.board, selected: p.selected, today: p.today, onDone: p.onDone, onCancel: p.onCancel };
  if (p.action === 'assign') return <AssignForm key={`assign:${p.selected.join()}`} {...common} supervisors={p.supervisors} />;
  if (p.action === 'cover') return <CoverForm key={`cover:${p.selected.join()}`} {...common} supervisors={p.supervisors} />;
  return <EndForm key={`end:${p.selected.join()}`} {...common} />;
}
