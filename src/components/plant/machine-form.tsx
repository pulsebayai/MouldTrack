import { router } from 'expo-router';
import { useRef, useState } from 'react';
import { Text, View } from 'react-native';
import { Button, Chip, ConfirmDialog, ErrorText, Field, StatusLabel, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import {
  PlantError, RequestIds, fetchLines, fetchMachine, machineStatusLabel, plantApi, validateMachineForm, type FieldErrors, type Machine, type MachineStatus,
} from '@/lib/plant';
import { useSession } from '@/lib/session-provider';
import { Label, Loading, LoadError } from './common';
import { TargetsPanel } from './targets-panel';
import { useLoad } from './use-load';

type Values = { code: string; name: string; asset_tag: string; make: string; model: string; controller: string; line_id: string | null; status: MachineStatus };
const FIELDS = ['code', 'name', 'asset_tag', 'make', 'model', 'controller', 'line_id', 'status'];
const EMPTY: Values = { code: '', name: '', asset_tag: '', make: '', model: '', controller: '', line_id: null, status: 'active' };
const fromMachine = (m: Machine): Values => ({
  code: m.code, name: m.name, asset_tag: m.asset_tag ?? '', make: m.make ?? '', model: m.model ?? '', controller: m.controller ?? '', line_id: m.line_id, status: m.status,
});

/** Create or edit a machine; on an existing machine also retire/reinstate and the targets panel. */
export function MachineForm({ machineId }: { machineId?: string }) {
  const { client } = useSession();
  const editing = !!machineId;
  const machine = useLoad(() => fetchMachine(client, machineId!), [machineId], editing);
  const row = machine.latest && machine.latest.id === machineId ? machine.latest : null;
  if (editing && !row && machine.state === 'loading') return <Loading testID="machine-form-loading" label="Loading machine" />;
  if (editing && !row && machine.state === 'error') return <LoadError testID="machine-form-load-error" onRetry={machine.reload} />;
  if (editing && !row) {
    return (
      <View style={{ gap: 16 }}>
        <Text testID="machine-not-found" accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>Machine not found</Text>
        <Button title="Back to machines" variant="secondary" testID="machine-back" onPress={() => router.replace('/plant')} />
      </View>
    );
  }
  // Remounts (fresh field values) when the machine is retired or reinstated; an ordinary save keeps what was typed.
  return <MachineFormBody key={`${machineId ?? 'new'}:${row?.retired_at ? 'retired' : 'live'}`} row={row} reload={machine.reload} />;
}

function MachineFormBody({ row, reload }: { row: Machine | null; reload: () => void }) {
  const { client } = useSession();
  const machineId = row?.id;
  const editing = !!row;
  const lines = useLoad(() => fetchLines(client), []);
  const [values, setValues] = useState<Values>(row ? fromMachine(row) : EMPTY);
  const [errors, setErrors] = useState<FieldErrors>({});
  const [busy, setBusy] = useState(false);
  const [saved, setSaved] = useState(false);
  const [confirm, setConfirm] = useState<'retire' | 'reinstate' | null>(null);
  const ids = useRef(new RequestIds());

  const retired = !!row?.retired_at;
  const set = <K extends keyof Values>(k: K, v: Values[K]) => {
    setValues((s) => ({ ...s, [k]: v }));
    setSaved(false);
  };

  async function save() {
    const e = validateMachineForm(values);
    if (Object.keys(e).length) {
      setErrors(e);
      return;
    }
    const key = JSON.stringify(['save', machineId ?? null, values]);
    setBusy(true);
    setErrors({});
    setSaved(false);
    try {
      const res = await plantApi.saveMachine(client, machineId ?? null, { ...values, code: values.code.trim(), name: values.name.trim() }, ids.current.get(key));
      ids.current.succeeded(key);
      if (!editing && res.id) router.replace(`/plant/machines/${res.id}`);
      else {
        setSaved(true);
        reload();
      }
    } catch (err) {
      ids.current.failed(key, err);
      if (err instanceof PlantError && err.field && FIELDS.includes(err.field)) setErrors({ [err.field]: err.message });
      else setErrors({ form: err instanceof PlantError ? err.message : toUserMessage(err) });
    } finally {
      setBusy(false);
    }
  }

  async function setRetired(retire: boolean) {
    const key = JSON.stringify(['retire', machineId, retire]);
    setBusy(true);
    setErrors({});
    try {
      await plantApi.setMachineRetired(client, machineId!, retire, ids.current.get(key));
      ids.current.succeeded(key);
      reload();
    } catch (err) {
      ids.current.failed(key, err);
      setErrors({ form: err instanceof PlantError ? err.message : toUserMessage(err) });
    } finally {
      setBusy(false);
      setConfirm(null);
    }
  }

  const lineList = lines.data ?? [];
  return (
    <View style={{ gap: 16 }}>
      <View testID="machine-form" style={{ gap: 16 }}>
        <View style={{ flexDirection: 'row', gap: 12, alignItems: 'center', flexWrap: 'wrap' }}>
          <Text accessibilityRole="header" style={{ fontSize: 22, fontWeight: '700', color: colors.text }}>
            {editing ? `${row!.code} · ${row!.name}` : 'Add machine'}
          </Text>
          {row ? <StatusLabel testID="machine-status" status={machineStatusLabel(row)} /> : null}
        </View>
        {retired ? (
          <Text testID="machine-retired-note" style={{ fontSize: 16, color: colors.text }}>This machine is retired. Reinstate it to edit it or set targets.</Text>
        ) : null}
        <Field label="Code" testID="machine-code" value={values.code} onChangeText={(v) => set('code', v)} error={errors.code} editable={!retired} autoCapitalize="characters" autoComplete="off" />
        <Field label="Name" testID="machine-name" value={values.name} onChangeText={(v) => set('name', v)} error={errors.name} editable={!retired} autoComplete="off" />
        <Field label="Asset tag" testID="machine-asset-tag" value={values.asset_tag} onChangeText={(v) => set('asset_tag', v)} error={errors.asset_tag} editable={!retired} autoComplete="off" />
        <Field label="Make" testID="machine-make" value={values.make} onChangeText={(v) => set('make', v)} error={errors.make} editable={!retired} autoComplete="off" />
        <Field label="Model" testID="machine-model" value={values.model} onChangeText={(v) => set('model', v)} error={errors.model} editable={!retired} autoComplete="off" />
        <Field label="Controller" testID="machine-controller" value={values.controller} onChangeText={(v) => set('controller', v)} error={errors.controller} editable={!retired} autoComplete="off" />
        <View style={{ gap: 8 }}>
          <Label>Line</Label>
          <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
            <Chip testID="machine-line-none" label="No line" selected={values.line_id === null} onPress={() => !retired && set('line_id', null)} />
            {lineList.map((l) => (
              <Chip key={l.id} testID={`machine-line-${l.id}`} label={l.name} selected={values.line_id === l.id} onPress={() => !retired && set('line_id', l.id)} />
            ))}
          </View>
          {errors.line_id ? <ErrorText testID="machine-line-error">{errors.line_id}</ErrorText> : null}
        </View>
        <View style={{ gap: 8 }}>
          <Label>Status</Label>
          <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
            <Chip testID="machine-status-active" label="Active" selected={values.status === 'active'} onPress={() => !retired && set('status', 'active')} />
            <Chip testID="machine-status-under_maintenance" label="Under maintenance" selected={values.status === 'under_maintenance'} onPress={() => !retired && set('status', 'under_maintenance')} />
          </View>
          {errors.status ? <ErrorText testID="machine-status-error">{errors.status}</ErrorText> : null}
        </View>
        {errors.form ? <ErrorText testID="machine-form-error">{errors.form}</ErrorText> : null}
        {saved ? <Text testID="machine-saved" accessibilityLiveRegion="polite" style={{ fontSize: 15, color: colors.text }}>Saved</Text> : null}
        <View style={{ flexDirection: 'row', gap: 12, flexWrap: 'wrap' }}>
          {retired ? (
            <Button title="Reinstate" testID="machine-reinstate" onPress={() => setConfirm('reinstate')} disabled={busy} />
          ) : (
            <Button title={editing ? 'Save changes' : 'Create machine'} testID="machine-save" onPress={save} disabled={busy} busy={busy} />
          )}
          {editing && !retired ? <Button title="Retire" variant="secondary" testID="machine-retire" onPress={() => setConfirm('retire')} disabled={busy} /> : null}
          <Button title="Back to machines" variant="secondary" testID="machine-cancel" onPress={() => router.replace('/plant')} disabled={busy} />
        </View>
      </View>

      {editing && row ? <TargetsPanel machineId={row.id} machineCode={row.code} retired={retired} /> : null}

      <ConfirmDialog
        visible={confirm !== null}
        busy={busy}
        title={row ? `${confirm === 'reinstate' ? 'Reinstate' : 'Retire'} ${row.code} · ${row.name}?` : ''}
        message={
          confirm === 'reinstate'
            ? 'It will appear in lists and pickers again.'
            : 'It is hidden from lists and pickers. Its history is kept and you can reinstate it later.'
        }
        confirmLabel={confirm === 'reinstate' ? 'Reinstate' : 'Retire'}
        onConfirm={() => setRetired(confirm === 'retire')}
        onCancel={() => setConfirm(null)}
      />
    </View>
  );
}
