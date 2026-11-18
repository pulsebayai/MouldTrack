import { useRef, useState } from 'react';
import { Text, View } from 'react-native';
import { LoadError } from '@/components/plant/common';
import { Button, ErrorText, Field, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import { fetchOverdueMinutes, handoverApi, validateMinutes } from '@/lib/handover';
import { PlantError, RequestIds } from '@/lib/plant';
import { useSession } from '@/lib/session-provider';
import { useLoad } from '@/lib/use-load';

/** Plant -> Site: how long a supervisor has to answer the handover checklist before it counts as overdue (15 to 480 minutes). */
export function OverdueSetting() {
  const { client } = useSession();
  const cur = useLoad(() => fetchOverdueMinutes(client), []);
  const [typed, setTyped] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [fieldError, setFieldError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const [busy, setBusy] = useState(false);
  const ids = useRef(new RequestIds());
  const loaded = cur.data !== null && cur.state === 'ready';
  // What is shown: what the person typed, else the value in force (60 when the tenant has no row yet).
  const minutes = typed ?? (cur.latest ? String(cur.latest.overdue_minutes) : cur.state === 'ready' ? '60' : '');

  async function save() {
    const err = validateMinutes(minutes);
    if (err) return setFieldError(err);
    const key = JSON.stringify(['overdue', minutes.trim()]);
    setBusy(true);
    setError(null);
    setFieldError(null);
    setSaved(false);
    try {
      await handoverApi.setOverdue(client, minutes, ids.current.get(key));
      ids.current.succeeded(key);
      setSaved(true);
      setTyped(null);
      cur.reload();
    } catch (e) {
      ids.current.failed(key, e);
      if (e instanceof PlantError && e.field === 'minutes') setFieldError(e.message);
      else setError(e instanceof PlantError ? e.message : toUserMessage(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <View testID="handover-setting" style={{ gap: 12 }}>
      <Text accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>Shift handover</Text>
      <Text style={{ fontSize: 15, color: colors.text }}>Minutes a supervisor has, from the start of the handover, to answer every inherited issue before it is reported as overdue.</Text>
      {cur.state === 'error' ? <LoadError testID="handover-setting-load-error" onRetry={cur.reload} error={cur.error} /> : null}
      {loaded && cur.data?.required ? <Text testID="handover-enforced" style={{ fontSize: 16, color: colors.text }}>Handover: enforced</Text> : null}
      <Field label="Overdue after (minutes)" testID="handover-minutes" value={minutes} onChangeText={(v) => { setTyped(v); setFieldError(null); setSaved(false); }} error={fieldError} keyboardType="number-pad" autoComplete="off" />
      {error ? <ErrorText testID="handover-setting-error">{error}</ErrorText> : null}
      {saved ? <Text testID="handover-setting-saved" accessibilityLiveRegion="polite" style={{ fontSize: 15, color: colors.text }}>Saved</Text> : null}
      <Button title="Save handover setting" testID="handover-setting-save" onPress={save} disabled={busy || cur.state === 'loading'} busy={busy} />
    </View>
  );
}
