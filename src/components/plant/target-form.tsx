import { useRef, useState } from 'react';
import { Text, View } from 'react-native';
import { Button, ErrorText, Field, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import { PlantError, RequestIds, formatPieces, formatPlantDate, isValidDate, parsePieces, plantApi, scheduledAfter, validateTargetForm, type FieldErrors, type TargetVersion } from '@/lib/plant';
import { useSession } from '@/lib/session-provider';

export type TargetFormProps = {
  mode: 'set' | 'end';
  machineId: string;
  productId: string;
  productLabel: string;
  today: string | null;
  /** This pair's versions: ending also cancels the scheduled changes after the chosen date, and the form says which. */
  versions?: TargetVersion[];
  unit?: string;
  onDone: () => void;
  onCancel: () => void;
};

/** Set (pieces + start date) or end (date only) a target. The date must be today or later in plant time; the server decides. */
export function TargetForm({ mode, machineId, productId, productLabel, today, versions = [], unit = 'pcs/shift', onDone, onCancel }: TargetFormProps) {
  const { client } = useSession();
  const [pieces, setPieces] = useState('');
  const [date, setDate] = useState(today ?? '');
  const [errors, setErrors] = useState<FieldErrors>({});
  const [busy, setBusy] = useState(false);
  const ids = useRef(new RequestIds());
  const setting = mode === 'set';
  const cancelled = !setting && isValidDate(date.trim()) ? scheduledAfter(versions, date.trim()) : [];

  async function submit() {
    const e = validateTargetForm({ pieces, date }, today, { needPieces: setting });
    if (Object.keys(e).length) {
      setErrors(e);
      return;
    }
    const key = JSON.stringify([mode, machineId, productId, pieces.replace(/[,\s]/g, ''), date.trim()]);
    setBusy(true);
    setErrors({});
    try {
      if (setting) {
        await plantApi.setTarget(client, { machineId, productId, pieces: parsePieces(pieces)!, effectiveFrom: date.trim() }, ids.current.get(key));
      } else {
        await plantApi.endTarget(client, { machineId, productId, effectiveFrom: date.trim() }, ids.current.get(key));
      }
      ids.current.succeeded(key);
      onDone();
    } catch (err) {
      ids.current.failed(key, err);
      if (err instanceof PlantError && (err.field === 'pieces' || err.field === 'effective_from')) setErrors({ [err.field]: err.message });
      else setErrors({ form: err instanceof PlantError ? err.message : toUserMessage(err) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <View testID="target-form" style={{ gap: 12, borderWidth: 2, borderColor: colors.primary, borderRadius: 12, padding: 16 }}>
      <Text accessibilityRole="header" style={{ fontSize: 18, fontWeight: '700', color: colors.text }}>
        {setting ? 'Set target' : 'End target'} · {productLabel}
      </Text>
      {setting ? (
        <Field label="Pieces per shift" testID="target-pieces" value={pieces} onChangeText={setPieces} error={errors.pieces} keyboardType="number-pad" inputMode="numeric" autoComplete="off" />
      ) : (
        <Text style={{ fontSize: 15, color: colors.text }}>The target stops applying from the date you choose.</Text>
      )}
      <Field
        label={setting ? 'Effective from (YYYY-MM-DD)' : 'Ends on (YYYY-MM-DD)'}
        testID="target-date"
        value={date}
        onChangeText={setDate}
        error={errors.effective_from}
        placeholder="YYYY-MM-DD"
        autoCapitalize="none"
        autoComplete="off"
      />
      {cancelled.length ? (
        <Text testID="target-end-cancels" style={{ fontSize: 15, color: colors.text }}>
          This also cancels the scheduled changes: {cancelled.map((c) => `${formatPieces(c.pieces)} ${unit} from ${formatPlantDate(c.from)}`).join(', ')}
        </Text>
      ) : null}
      {errors.form ? <ErrorText testID="target-form-error">{errors.form}</ErrorText> : null}
      <View style={{ flexDirection: 'row', gap: 12, flexWrap: 'wrap' }}>
        <Button title={setting ? 'Save target' : 'End target'} testID="target-submit" onPress={submit} disabled={busy} busy={busy} />
        <Button title="Cancel" variant="secondary" testID="target-cancel" onPress={onCancel} disabled={busy} />
      </View>
    </View>
  );
}
