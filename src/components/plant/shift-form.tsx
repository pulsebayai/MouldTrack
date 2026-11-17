import { useRef, useState } from 'react';
import { Text, View } from 'react-native';
import { Button, ErrorText, Field, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import { PlantError, RequestIds, formatDuration, hhmm, isOvernight, shiftApi, shiftMinutes, validateShiftForm, type FieldErrors, type Shift } from '@/lib/plant';
import { useSession } from '@/lib/session-provider';

type Props = { shift: Shift | null; onSaved: () => void; onCancel: () => void };

/** Create or edit a shift (inline on the Shifts tab): name and start/end times in the site's time zone, 15-minute steps. */
export function ShiftForm({ shift, onSaved, onCancel }: Props) {
  const { client } = useSession();
  const [name, setName] = useState(shift?.name ?? '');
  const [start, setStart] = useState(shift ? hhmm(shift.start_time) : '');
  const [end, setEnd] = useState(shift ? hhmm(shift.end_time) : '');
  const [errors, setErrors] = useState<FieldErrors>({});
  const [busy, setBusy] = useState(false);
  const ids = useRef(new RequestIds());
  const valid = Object.keys(validateShiftForm({ name: 'x', start, end })).length === 0;

  async function save() {
    const e = validateShiftForm({ name, start, end });
    if (Object.keys(e).length) {
      setErrors(e);
      return;
    }
    const input = { name: name.trim(), start: start.trim(), end: end.trim() };
    const key = JSON.stringify([shift?.id ?? null, input]);
    setBusy(true);
    setErrors({});
    try {
      await shiftApi.saveShift(client, shift?.id ?? null, input, ids.current.get(key));
      ids.current.succeeded(key);
      onSaved();
    } catch (err) {
      ids.current.failed(key, err);
      if (err instanceof PlantError && (err.field === 'name' || err.field === 'start_time' || err.field === 'end_time')) setErrors({ [err.field]: err.message });
      else setErrors({ form: err instanceof PlantError ? err.message : toUserMessage(err) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <View testID="shift-form" style={{ gap: 12, borderWidth: 2, borderColor: colors.primary, borderRadius: 12, padding: 16 }}>
      <Text accessibilityRole="header" style={{ fontSize: 18, fontWeight: '700', color: colors.text }}>
        {shift ? 'Edit shift' : 'Add shift'}
      </Text>
      <Field label="Name" testID="shift-name" value={name} onChangeText={setName} error={errors.name} autoComplete="off" />
      <Field label="Start time (HH:MM)" testID="shift-start" value={start} onChangeText={setStart} error={errors.start_time} placeholder="06:00" autoCapitalize="none" autoComplete="off" />
      <Field label="End time (HH:MM)" testID="shift-end" value={end} onChangeText={setEnd} error={errors.end_time} placeholder="14:00" autoCapitalize="none" autoComplete="off" />
      {valid ? (
        <Text testID="shift-duration" style={{ fontSize: 15, color: colors.text }}>
          Duration: {formatDuration(shiftMinutes(start.trim(), end.trim()))}
          {isOvernight(start.trim(), end.trim()) ? ' (overnight: ends the next day)' : ''}
        </Text>
      ) : null}
      {errors.form ? <ErrorText testID="shift-form-error">{errors.form}</ErrorText> : null}
      <View style={{ flexDirection: 'row', gap: 12, flexWrap: 'wrap' }}>
        <Button title={shift ? 'Save changes' : 'Create shift'} testID="shift-save" onPress={save} disabled={busy} busy={busy} />
        <Button title="Cancel" variant="secondary" testID="shift-cancel" onPress={onCancel} disabled={busy} />
      </View>
    </View>
  );
}
