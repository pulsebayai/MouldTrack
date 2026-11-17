import { useRef, useState } from 'react';
import { Text, View } from 'react-native';
import { Button, Chip, ConfirmDialog, ErrorText, Field, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import {
  PlantError, RequestIds, SHIFT_MSG, formatPlantDate, isValidDate, shiftApi, validateAssignForm, validateCoverForm, whoLoses, type FieldErrors, type ShiftBoard, type Supervisor,
} from '@/lib/plant';
import { useSession } from '@/lib/session-provider';
import { Label } from './common';

type Common = {
  board: ShiftBoard;
  selected: string[];
  supervisors: Supervisor[];
  today: string | null;
  onDone: () => void;
  onCancel: () => void;
};

/** A server refusal as one sentence; the later_change guard names the machines and the dates it found. */
export function describeError(err: unknown): string {
  if (!(err instanceof PlantError)) return toUserMessage(err);
  if (err.field === 'later_change' && err.machines?.length) {
    const dates = (err.dates ?? []).map(formatPlantDate).join(', ');
    return `${err.message}: ${err.machines.join(', ')}${dates ? ` (${dates})` : ''}. Unassign them from that date first.`;
  }
  return err.machines?.length ? `${err.message}: ${err.machines.join(', ')}` : err.message;
}

const box = { gap: 12, borderWidth: 2, borderColor: colors.primary, borderRadius: 12, padding: 16 } as const;
const codesOf = (board: ShiftBoard, selected: string[]) => board.machines.filter((m) => selected.includes(m.machine_id)).map((m) => m.code).join(', ');
const startDate = (board: ShiftBoard, today: string | null) => (today && board.shift_date < today ? today : board.shift_date);

/** "Assign to…": a supervisor takes the selected machines on this shift from a date (until a date, or until changed). */
export function AssignForm({ board, selected, supervisors, today, onDone, onCancel }: Common) {
  const { client } = useSession();
  const [supervisorId, setSupervisorId] = useState('');
  const [from, setFrom] = useState(startDate(board, today));
  const [until, setUntil] = useState('');
  const [errors, setErrors] = useState<FieldErrors>({});
  const [busy, setBusy] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const ids = useRef(new RequestIds());
  const losers = whoLoses(board.machines, selected, supervisorId || null);
  const target = supervisors.find((s) => s.user_id === supervisorId);

  function submit() {
    const e = validateAssignForm({ supervisorId, machineIds: selected, from, until }, today);
    if (Object.keys(e).length) {
      setErrors(e);
      return;
    }
    setErrors({});
    if (losers.length > 0) setConfirming(true);
    else void go();
  }

  async function go() {
    const input = { shiftId: board.shift.id, supervisorId, machineIds: selected, from: from.trim(), until: until.trim() || null };
    const key = JSON.stringify(input);
    setBusy(true);
    try {
      await shiftApi.assign(client, input, ids.current.get(key));
      ids.current.succeeded(key);
      onDone();
    } catch (err) {
      ids.current.failed(key, err);
      setErrors({ form: describeError(err) });
    } finally {
      setBusy(false);
      setConfirming(false);
    }
  }

  return (
    <View testID="assign-form" style={box}>
      <Text accessibilityRole="header" style={{ fontSize: 18, fontWeight: '700', color: colors.text }}>Assign to…</Text>
      <Text testID="assign-machines" style={{ fontSize: 15, color: colors.text }}>Machines: {codesOf(board, selected)}</Text>
      <Label>Supervisor</Label>
      <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
        {supervisors.map((s) => (
          <Chip key={s.user_id} testID={`assign-sup-${s.user_id}`} label={`${s.full_name} · ${s.employee_id}`} selected={supervisorId === s.user_id} onPress={() => setSupervisorId(s.user_id)} />
        ))}
      </View>
      {supervisors.length === 0 ? <Text testID="assign-no-supervisors" style={{ fontSize: 15, color: colors.text }}>No active supervisors — add one under Users first</Text> : null}
      {errors.supervisor ? <ErrorText testID="assign-sup-error">{errors.supervisor}</ErrorText> : null}
      <Field label="From (YYYY-MM-DD)" testID="assign-from" value={from} onChangeText={setFrom} error={errors.from} placeholder="YYYY-MM-DD" autoCapitalize="none" autoComplete="off" />
      <Field label="Until (optional, YYYY-MM-DD)" testID="assign-until" value={until} onChangeText={setUntil} error={errors.until} placeholder="Until changed" autoCapitalize="none" autoComplete="off" />
      {errors.machine_ids ? <ErrorText testID="assign-machines-error">{errors.machine_ids}</ErrorText> : null}
      {errors.form ? <ErrorText testID="assign-form-error">{errors.form}</ErrorText> : null}
      <View style={{ flexDirection: 'row', gap: 12, flexWrap: 'wrap' }}>
        <Button title="Assign" testID="assign-submit" onPress={submit} disabled={busy} busy={busy && !confirming} />
        <Button title="Cancel" variant="secondary" testID="assign-cancel" onPress={onCancel} disabled={busy} />
      </View>
      <ConfirmDialog
        visible={confirming}
        busy={busy}
        title={`Move machines to ${target?.full_name ?? 'this supervisor'}?`}
        message={`${losers.map((l) => `${l.name} loses ${l.codes.join(', ')}`).join('. ')}. The change applies from ${isValidDate(from) ? formatPlantDate(from.trim()) : from}.`}
        confirmLabel="Move machines"
        onConfirm={() => void go()}
        onCancel={() => setConfirming(false)}
      />
    </View>
  );
}

/** "Cover this shift…": for this one occurrence only, the selected machines go to another supervisor or to nobody, with a reason. */
export function CoverForm({ board, selected, supervisors, today, onDone, onCancel }: Common) {
  const { client } = useSession();
  const [choice, setChoice] = useState<string>(''); // '' = not chosen, 'none' = unassigned, else a supervisor id
  const [reason, setReason] = useState('');
  const [errors, setErrors] = useState<FieldErrors>({});
  const [busy, setBusy] = useState(false);
  const ids = useRef(new RequestIds());
  const losers = whoLoses(board.machines, selected, choice && choice !== 'none' ? choice : null);
  void today;

  async function submit() {
    const e = validateCoverForm({ machineIds: selected, reason });
    if (!choice) e.supervisor = 'Choose a supervisor or Unassigned';
    if (Object.keys(e).length) {
      setErrors(e);
      return;
    }
    const input = { shiftId: board.shift.id, shiftDate: board.shift_date, machineIds: selected, supervisorId: choice === 'none' ? null : choice, reason: reason.trim() };
    const key = JSON.stringify(input);
    setBusy(true);
    setErrors({});
    try {
      await shiftApi.cover(client, input, ids.current.get(key));
      ids.current.succeeded(key);
      onDone();
    } catch (err) {
      ids.current.failed(key, err);
      if (err instanceof PlantError && err.field === 'reason') setErrors({ reason: err.message });
      else setErrors({ form: describeError(err) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <View testID="cover-form" style={box}>
      <Text accessibilityRole="header" style={{ fontSize: 18, fontWeight: '700', color: colors.text }}>Cover this shift…</Text>
      <Text style={{ fontSize: 15, color: colors.text }}>
        Only {board.shift.name} on {formatPlantDate(board.shift_date)} changes; the recurring plan stays as it is.
      </Text>
      <Text testID="cover-machines" style={{ fontSize: 15, color: colors.text }}>Machines: {codesOf(board, selected)}</Text>
      <Label>Move to</Label>
      <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
        {supervisors.map((s) => (
          <Chip key={s.user_id} testID={`cover-sup-${s.user_id}`} label={`${s.full_name} · ${s.employee_id}`} selected={choice === s.user_id} onPress={() => setChoice(s.user_id)} />
        ))}
        <Chip testID="cover-sup-none" label="Unassigned" selected={choice === 'none'} onPress={() => setChoice('none')} />
      </View>
      {errors.supervisor ? <ErrorText testID="cover-sup-error">{errors.supervisor}</ErrorText> : null}
      {choice && losers.length > 0 ? (
        <Text testID="cover-losers" style={{ fontSize: 15, color: colors.text }}>{losers.map((l) => `${l.name} loses ${l.codes.join(', ')}`).join('. ')}.</Text>
      ) : null}
      <Field label="Reason" testID="cover-reason" value={reason} onChangeText={setReason} error={errors.reason} placeholder="For example: on leave" autoComplete="off" />
      {errors.machine_ids ? <ErrorText testID="cover-machines-error">{errors.machine_ids}</ErrorText> : null}
      {errors.form ? <ErrorText testID="cover-form-error">{errors.form}</ErrorText> : null}
      <View style={{ flexDirection: 'row', gap: 12, flexWrap: 'wrap' }}>
        <Button title="Cover" testID="cover-submit" onPress={submit} disabled={busy} busy={busy} />
        <Button title="Cancel" variant="secondary" testID="cover-cancel" onPress={onCancel} disabled={busy} />
      </View>
    </View>
  );
}

/** "End assignment": the selected machines have no supervisor on this shift from a date. */
export function EndForm({ board, selected, today, onDone, onCancel }: Omit<Common, 'supervisors'>) {
  const { client } = useSession();
  const [from, setFrom] = useState(startDate(board, today));
  const [errors, setErrors] = useState<FieldErrors>({});
  const [busy, setBusy] = useState(false);
  const ids = useRef(new RequestIds());

  async function submit() {
    const e: FieldErrors = {};
    if (selected.length === 0) e.machine_ids = SHIFT_MSG.machines;
    if (!isValidDate(from.trim())) e.from = 'Enter a date as YYYY-MM-DD';
    else if (today && from.trim() < today) e.from = "Assignments can't end in the past";
    if (Object.keys(e).length) {
      setErrors(e);
      return;
    }
    const input = { shiftId: board.shift.id, machineIds: selected, from: from.trim() };
    const key = JSON.stringify(input);
    setBusy(true);
    setErrors({});
    try {
      await shiftApi.unassign(client, input, ids.current.get(key));
      ids.current.succeeded(key);
      onDone();
    } catch (err) {
      ids.current.failed(key, err);
      setErrors({ form: describeError(err) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <View testID="end-form" style={box}>
      <Text accessibilityRole="header" style={{ fontSize: 18, fontWeight: '700', color: colors.text }}>End assignment</Text>
      <Text testID="end-machines" style={{ fontSize: 15, color: colors.text }}>Machines: {codesOf(board, selected)}</Text>
      <Text style={{ fontSize: 15, color: colors.text }}>They have no supervisor on {board.shift.name} from the date you choose.</Text>
      <Field label="From (YYYY-MM-DD)" testID="end-from" value={from} onChangeText={setFrom} error={errors.from} placeholder="YYYY-MM-DD" autoCapitalize="none" autoComplete="off" />
      {errors.machine_ids ? <ErrorText testID="end-machines-error">{errors.machine_ids}</ErrorText> : null}
      {errors.form ? <ErrorText testID="end-form-error">{errors.form}</ErrorText> : null}
      <View style={{ flexDirection: 'row', gap: 12, flexWrap: 'wrap' }}>
        <Button title="End assignment" testID="end-submit" onPress={submit} disabled={busy} busy={busy} />
        <Button title="Cancel" variant="secondary" testID="end-cancel" onPress={onCancel} disabled={busy} />
      </View>
    </View>
  );
}
