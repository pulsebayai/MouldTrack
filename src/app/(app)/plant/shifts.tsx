import { useRef, useState } from 'react';
import { Text, View } from 'react-native';
import { Loading, LoadError, rowStyle } from '@/components/plant/common';
import { ShiftForm } from '@/components/plant/shift-form';
import { useLoad } from '@/components/plant/use-load';
import { Button, Chip, ConfirmDialog, ErrorText, StatusLabel, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import { PlantError, RequestIds, fetchShifts, formatDuration, isOvernight, shiftApi, shiftMinutes, timeWindow, type Shift } from '@/lib/plant';
import { useSession } from '@/lib/session-provider';

/** Shifts tab (AC-1): the daily shift pattern of the site. Times are in the site's time zone; an end before the start is an overnight shift. */
export default function ShiftsTab() {
  const { client } = useSession();
  const [showRetired, setShowRetired] = useState(false);
  const [editing, setEditing] = useState<'new' | Shift | null>(null);
  const [pending, setPending] = useState<Shift | null>(null);
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const ids = useRef(new RequestIds());
  const list = useLoad(() => fetchShifts(client, { includeRetired: showRetired }), [showRetired]);
  const rows = list.data ?? [];

  async function confirm() {
    if (!pending) return;
    const retire = !pending.retired_at;
    const key = JSON.stringify(['retire', pending.id, retire]);
    setBusy(true);
    setActionError(null);
    try {
      await shiftApi.setShiftRetired(client, pending.id, retire, ids.current.get(key));
      ids.current.succeeded(key);
      list.reload();
    } catch (e) {
      ids.current.failed(key, e);
      setActionError(e instanceof PlantError ? e.message : toUserMessage(e));
    } finally {
      setBusy(false);
      setPending(null);
    }
  }

  return (
    <View testID="shifts-tab" style={{ gap: 16 }}>
      <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 12 }}>
        <Text accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>Shifts</Text>
        <Button title="Add shift" testID="shifts-add" onPress={() => { setActionError(null); setEditing('new'); }} />
      </View>
      <Text style={{ fontSize: 15, color: colors.muted }}>Times are in the site&apos;s time zone. A shift that ends before it starts finishes the next day.</Text>
      {editing ? (
        <ShiftForm
          key={editing === 'new' ? 'new' : editing.id}
          shift={editing === 'new' ? null : editing}
          onCancel={() => setEditing(null)}
          onSaved={() => {
            setEditing(null);
            list.reload();
          }}
        />
      ) : null}
      {actionError ? <ErrorText testID="shifts-action-error">{actionError}</ErrorText> : null}
      <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
        <Chip testID="shifts-show-retired" label="Show retired" selected={showRetired} onPress={() => setShowRetired((s) => !s)} />
      </View>

      {list.state === 'loading' ? <Loading testID="shifts-loading" label="Loading shifts" /> : null}
      {list.state === 'error' ? <LoadError testID="shifts-error" onRetry={list.reload} error={list.error} /> : null}
      {list.state === 'ready' && rows.length === 0 ? (
        <Text testID="shifts-empty" style={{ fontSize: 16, color: colors.text }}>No shifts yet — add your first shift</Text>
      ) : null}
      {list.state === 'ready'
        ? rows.map((s) => (
            <View key={s.id} testID={`shift-row-${s.id}`} style={rowStyle}>
              <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 16, alignItems: 'center' }}>
                <Text testID={`shift-name-${s.id}`} style={{ fontSize: 17, fontWeight: '700', color: colors.text, minWidth: 120 }}>{s.name}</Text>
                <Text testID={`shift-window-${s.id}`} style={{ fontSize: 16, color: colors.text }}>
                  {timeWindow(s.start_time, s.end_time)} · {formatDuration(shiftMinutes(s.start_time, s.end_time))}
                  {isOvernight(s.start_time, s.end_time) ? ' · Overnight' : ''}
                </Text>
                <StatusLabel testID={`shift-status-${s.id}`} status={s.retired_at ? 'Retired' : 'Active'} />
              </View>
              <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
                {s.retired_at ? null : <Button title="Edit" variant="secondary" testID={`shift-edit-${s.id}`} onPress={() => { setActionError(null); setEditing(s); }} />}
                <Button title={s.retired_at ? 'Reinstate' : 'Retire'} variant="secondary" testID={`shift-toggle-${s.id}`} onPress={() => { setActionError(null); setPending(s); }} />
              </View>
            </View>
          ))
        : null}

      <ConfirmDialog
        visible={!!pending}
        busy={busy}
        title={pending ? `${pending.retired_at ? 'Reinstate' : 'Retire'} ${pending.name}?` : ''}
        message={pending?.retired_at ? 'It will appear in pickers and on the board again.' : 'It is hidden from pickers and boards. History is kept.'}
        confirmLabel={pending?.retired_at ? 'Reinstate' : 'Retire'}
        onConfirm={confirm}
        onCancel={() => setPending(null)}
      />
    </View>
  );
}
