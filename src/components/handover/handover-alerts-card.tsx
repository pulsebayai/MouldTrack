import { useEffect, useRef, useState } from 'react';
import { AppState, Text, View } from 'react-native';
import { LoadError } from '@/components/plant/common';
import { Button, Chip, ErrorText, Field, StatusLabel, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import { LIMITS, MSG, fetchHandoverAlerts, handoverApi, validateExceptionReason, type PendingException } from '@/lib/handover';
import { formatAge } from '@/lib/issues';
import { PlantError, RequestIds, fetchActiveSupervisors, formatPlantDate, type Supervisor } from '@/lib/plant';
import { fetchPlantTimezone, formatPlantDateTime } from '@/lib/plant-time';
import { useSession } from '@/lib/session-provider';
import { useLoad } from '@/lib/use-load';
import { useRefreshOnFocus } from '@/lib/use-refresh';

const REFRESH_MS = 60_000;
/** Home shows at most this many of each list; "Show all" expands to the server's bound (50). */
const SHOWN = 5;
const text = { fontSize: 16, color: colors.text } as const;

/** Unit Admin Home: refusals waiting for an exception and acknowledgements past their deadline (D9). Hidden while there is nothing to show. */
export function HandoverAlertsCard() {
  const { client } = useSession();
  const alerts = useLoad(() => fetchHandoverAlerts(client), []);
  const { reload } = alerts;
  useRefreshOnFocus(reload);
  const tz = useLoad(() => fetchPlantTimezone(client), []).data ?? 'Asia/Kolkata';
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
  const d = alerts.data ?? alerts.latest;
  const [all, setAll] = useState(false);
  const [target, setTarget] = useState<PendingException | null>(null);
  const [reason, setReason] = useState('');
  const [owner, setOwner] = useState<string | null>(null);
  const [fieldError, setFieldError] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const ids = useRef(new RequestIds());
  const sups = useLoad<Supervisor[]>(() => fetchActiveSupervisors(client), [], target !== null);

  if (alerts.state === 'error' && !d) return <LoadError testID="handover-alerts-error" onRetry={reload} error={alerts.error} />;
  if (!d || d.alert_count === 0) return null;

  function start(e: PendingException) {
    setTarget(e);
    setReason('');
    setOwner(e.owner_id);
    setFieldError(null);
    setError(null);
  }
  async function submit() {
    if (!target) return;
    const err = validateExceptionReason(reason);
    if (err) return setFieldError(err);
    if (!owner) return setFieldError(MSG.owner);
    const key = JSON.stringify([target.issue_id, target.shift_id, target.shift_date, reason.trim(), owner]);
    setBusy(true);
    setError(null);
    try {
      await handoverApi.exception(client, { issueId: target.issue_id, shiftId: target.shift_id, shiftDate: target.shift_date, reason, ownerId: owner }, ids.current.get(key));
      ids.current.succeeded(key);
      setTarget(null);
      reload();
    } catch (e) {
      ids.current.failed(key, e);
      setError(e instanceof PlantError ? e.message : toUserMessage(e));
      reload();
    } finally {
      setBusy(false);
    }
  }

  const exc = all ? d.exceptions : d.exceptions.slice(0, SHOWN);
  const over = all ? d.overdue : d.overdue.slice(0, SHOWN);
  const hidden = d.exceptions.length > SHOWN || d.overdue.length > SHOWN;
  return (
    <View testID="handover-alerts" style={{ gap: 8, borderWidth: 2, borderColor: colors.primary, borderRadius: 12, padding: 16 }}>
      <Text accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>Handover alerts ({d.alert_count})</Text>
      {error ? <ErrorText testID="handover-alerts-action-error">{error}</ErrorText> : null}
      {exc.length > 0 ? <Text accessibilityRole="header" style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>Refused - exception needed ({d.exceptions_total})</Text> : null}
      {exc.map((e) => {
        const k = `${e.issue_id}:${e.shift_id}:${e.shift_date}`;
        return (
          <View key={k} testID={`ho-exc-${e.issue_id}`} style={{ gap: 4, borderWidth: 1, borderColor: colors.border, borderRadius: 8, padding: 12 }}>
            <Text style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>{e.machine_code} · {e.shift_name} {formatPlantDate(e.shift_date)}</Text>
            <Text style={text}>{e.description}</Text>
            <Text testID={`ho-exc-reason-${e.issue_id}`} style={text}>{e.supervisor_name ?? 'A supervisor'} refused: {e.reason}</Text>
            <View style={{ flexDirection: 'row', gap: 6, flexWrap: 'wrap' }}>
              <StatusLabel status="Waiting for exception" />
              <StatusLabel status={`Waiting ${formatAge(e.minutes_waiting)}`} />
            </View>
            <Text style={{ fontSize: 14, color: colors.muted }}>Refused {formatPlantDateTime(e.refused_at, tz)}{e.owner_name ? ` · Owner: ${e.owner_name}` : ''}</Text>
            <Button title={`Record exception for ${e.machine_code}`} testID={`ho-exc-record-${e.issue_id}`} onPress={() => start(e)} disabled={busy} />
          </View>
        );
      })}
      {target ? (
        <View testID="ho-exc-panel" style={{ gap: 8, borderWidth: 2, borderColor: colors.primary, borderRadius: 8, padding: 12 }}>
          <Text accessibilityRole="header" style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>Exception for {target.machine_code}</Text>
          <Text style={{ fontSize: 15, color: colors.text }}>Choose who owns this issue from now on. Keeping the current owner is recorded as an exception too.</Text>
          {sups.state === 'error' ? <LoadError testID="ho-exc-owners-error" onRetry={sups.reload} error={sups.error} /> : null}
          <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
            {(sups.data ?? sups.latest ?? []).map((s) => (
              <Chip
                key={s.user_id}
                testID={`ho-exc-owner-${s.user_id}`}
                label={`${s.full_name} (${s.employee_id})${s.user_id === target.owner_id ? ' - current owner' : ''}`}
                selected={owner === s.user_id}
                onPress={() => { setOwner(s.user_id); setFieldError(null); }}
              />
            ))}
          </View>
          <Field label="Reason" testID="ho-exc-reason" value={reason} onChangeText={(v) => { setReason(v); setFieldError(null); }} error={fieldError} multiline maxLength={LIMITS.reason + 50} />
          <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
            <Button title="Save exception" testID="ho-exc-submit" onPress={submit} disabled={busy} busy={busy} />
            <Button title="Cancel" variant="secondary" testID="ho-exc-cancel" onPress={() => setTarget(null)} disabled={busy} />
          </View>
        </View>
      ) : null}
      {over.length > 0 ? <Text accessibilityRole="header" style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>Overdue acknowledgements ({d.overdue_total})</Text> : null}
      {over.map((o) => (
        <View key={`${o.issue_id}:${o.supervisor_id}:${o.shift_id}:${o.shift_date}`} testID={`ho-over-${o.issue_id}`} style={{ gap: 4, borderWidth: 1, borderColor: colors.border, borderRadius: 8, padding: 12 }}>
          <Text style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>{o.machine_code} · {o.supervisor_name ?? 'A supervisor'}</Text>
          <Text style={text}>{o.description}</Text>
          <StatusLabel status={`Overdue by ${formatAge(o.minutes_overdue)}`} />
          <Text style={{ fontSize: 14, color: colors.muted }}>{o.shift_name} · {formatPlantDate(o.shift_date)}</Text>
        </View>
      ))}
      {hidden && !all ? <Button title="Show all handover alerts" variant="secondary" testID="handover-alerts-more" onPress={() => setAll(true)} /> : null}
      {all && hidden ? <Button title="Show fewer" variant="secondary" testID="handover-alerts-less" onPress={() => setAll(false)} /> : null}
      <Button title="Refresh handover alerts" variant="secondary" testID="handover-alerts-refresh" onPress={reload} />
    </View>
  );
}
