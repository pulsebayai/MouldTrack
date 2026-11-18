import { router } from 'expo-router';
import { useEffect, useRef, useState } from 'react';
import { AppState, Text, View } from 'react-native';
import { Loading, LoadError } from '@/components/plant/common';
import { Button, ErrorText, Field, StatusLabel, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import {
  ITEM_STATE_LABEL, LIMITS, fetchHandoverChecklist, handoverApi, validateNote, validateRefusal, validateRemark,
  type HandoverItem, type HandoverOccurrence,
} from '@/lib/handover';
import { ACTION_LABEL, PRIORITY_LABEL, STATUS_LABEL, formatAge } from '@/lib/issues';
import { PlantError, RequestIds, formatPlantDate, timeWindow } from '@/lib/plant';
import { fetchPlantTimezone, formatPlantDateTime } from '@/lib/plant-time';
import { useSession } from '@/lib/session-provider';
import { useLoad } from '@/lib/use-load';
import { useRefreshOnFocus } from '@/lib/use-refresh';

const REFRESH_MS = 60_000;
type Kind = 'ack' | 'refuse' | 'note';
type Open = { kind: Kind; key: string } | null;

const text = { fontSize: 16, color: colors.text } as const;

/**
 * The supervisor's handover checklist (D9): every inherited issue on my machines for the shift that is starting or running, answered one by one
 * (acknowledge or refuse), then declared. What may be done comes from the server (`allowed_actions`); this screen only renders it.
 */
export function HandoverChecklist() {
  const { client } = useSession();
  const list = useLoad(() => fetchHandoverChecklist(client), []);
  const { reload } = list;
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
  const d = list.data ?? list.latest;
  const [open, setOpen] = useState<Open>(null);
  const [value, setValue] = useState('');
  const [fieldError, setFieldError] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const ids = useRef(new RequestIds());

  function openPanel(kind: Kind, key: string) {
    setOpen({ kind, key });
    setValue('');
    setFieldError(null);
    setError(null);
  }
  function fail(e: unknown) {
    setError(e instanceof PlantError ? e.message : toUserMessage(e));
  }
  async function run(key: string, fn: (rid: string) => Promise<unknown>, done?: () => void) {
    setBusy(true);
    setError(null);
    try {
      await fn(ids.current.get(key));
      ids.current.succeeded(key);
      done?.();
      reload();
    } catch (e) {
      ids.current.failed(key, e);
      fail(e);
      reload(); // the answer may already be recorded (or the window closed): show what the server says now
    } finally {
      setBusy(false);
    }
  }
  function submit(o: HandoverOccurrence, it: HandoverItem) {
    if (!open) return;
    const err = open.kind === 'ack' ? validateRemark(value) : open.kind === 'refuse' ? validateRefusal(value) : validateNote(value);
    if (err) {
      setFieldError(err);
      return;
    }
    const base = { issueId: it.id, shiftId: o.shift.id, shiftDate: o.shift_date };
    const key = JSON.stringify([open.kind, base, value.trim()]);
    const close = () => setOpen(null);
    if (open.kind === 'ack') void run(key, (r) => handoverApi.acknowledge(client, { ...base, remark: value }, r), close);
    else if (open.kind === 'refuse') void run(key, (r) => handoverApi.refuse(client, { ...base, reason: value }, r), close);
    else void run(key, (r) => handoverApi.addNote(client, { ...base, note: value }, r), close);
  }
  function declare(o: HandoverOccurrence) {
    const key = JSON.stringify(['declare', o.shift.id, o.shift_date]);
    void run(key, (r) => handoverApi.declare(client, { shiftId: o.shift.id, shiftDate: o.shift_date }, r));
  }

  const panel = (o: HandoverOccurrence, it: HandoverItem, k: string) => {
    if (!open || open.key !== k) return null;
    const cfg = {
      ack: { label: 'Remark (optional)', submit: 'Confirm acknowledgement', max: LIMITS.remark },
      refuse: { label: 'Reason for refusing', submit: 'Confirm refusal', max: LIMITS.reason },
      note: { label: 'Note for the next shift', submit: 'Save note', max: LIMITS.note },
    }[open.kind];
    return (
      <View testID={`ho-panel-${it.id}`} style={{ gap: 8 }}>
        <Field label={cfg.label} testID={`ho-input-${it.id}`} value={value} onChangeText={(v) => { setValue(v); setFieldError(null); }} error={fieldError} multiline maxLength={cfg.max + 50} />
        <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
          <Button title={cfg.submit} testID={`ho-submit-${it.id}`} onPress={() => submit(o, it)} disabled={busy} busy={busy} />
          <Button title="Cancel" variant="secondary" testID={`ho-cancel-${it.id}`} onPress={() => setOpen(null)} disabled={busy} />
        </View>
      </View>
    );
  };

  return (
    <View testID="handover" style={{ gap: 16 }}>
      <Text accessibilityRole="header" style={{ fontSize: 22, fontWeight: '700', color: colors.text }}>Shift handover</Text>
      {list.state === 'loading' && !d ? <Loading testID="handover-loading" label="Loading the handover checklist" /> : null}
      {list.state === 'error' ? <LoadError testID="handover-load-error" onRetry={reload} error={list.error} /> : null}
      {error ? <ErrorText testID="handover-error">{error}</ErrorText> : null}
      {d && d.occurrences.length === 0 ? <Text testID="handover-none" style={text}>No handover to complete right now</Text> : null}
      {(d?.occurrences ?? []).map((o) => {
        const ok = `${o.shift.id}:${o.shift_date}`;
        const inherited = o.machines.reduce((n, m) => n + m.items.length, 0);
        return (
          <View key={ok} testID={`ho-occ-${ok}`} style={{ gap: 12, borderWidth: 2, borderColor: colors.primary, borderRadius: 12, padding: 16 }}>
            <Text accessibilityRole="header" style={{ fontSize: 19, fontWeight: '700', color: colors.text }}>
              {o.shift.name} · {timeWindow(o.shift.start_time, o.shift.end_time)} · {formatPlantDate(o.shift_date)}
            </Text>
            <View style={{ flexDirection: 'row', gap: 6, flexWrap: 'wrap' }}>
              <StatusLabel testID={`ho-occ-status-${ok}`} status={o.declared ? 'Handover declared' : o.pending_count > 0 ? `${o.pending_count} to answer` : inherited === 0 ? 'Nothing inherited' : 'Ready to declare'} />
              <StatusLabel status={o.running ? 'Shift running' : 'Shift not started'} />
            </View>
            <Text testID={`ho-deadline-${ok}`} style={{ fontSize: 15, color: colors.muted }}>
              Answer by {formatPlantDateTime(o.deadline, tz)} ({o.overdue_minutes} min after the handover starts)
            </Text>
            {o.declared && o.declared_at ? <Text testID={`ho-declared-${ok}`} style={text}>Declared {formatPlantDateTime(o.declared_at, tz)}</Text> : null}
            {inherited === 0 ? <Text testID={`ho-empty-${ok}`} style={text}>No unresolved issues were handed over to you</Text> : null}
            {o.machines.map((m) => (
              <View key={m.machine_id} testID={`ho-machine-${ok}-${m.machine_id}`} style={{ gap: 8 }}>
                <Text accessibilityRole="header" style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>{m.code} · {m.name}</Text>
                {m.items.map((it) => {
                  const k = `${ok}:${it.id}`;
                  const can = (a: string) => (it.allowed_actions as string[]).includes(a);
                  return (
                    <View key={it.id} testID={`ho-item-${it.id}`} style={{ gap: 6, borderWidth: 1, borderColor: colors.border, borderRadius: 8, padding: 12 }}>
                      <Text style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>{it.category}</Text>
                      <Text style={text}>{it.description}</Text>
                      <View style={{ flexDirection: 'row', gap: 6, flexWrap: 'wrap' }}>
                        <StatusLabel status={PRIORITY_LABEL[it.priority]} />
                        <StatusLabel status={STATUS_LABEL[it.status]} />
                        {it.machine_stopped ? <StatusLabel status="Machine stopped" /> : null}
                        {it.escalated ? <StatusLabel status="Escalated" /> : null}
                        <StatusLabel testID={`ho-state-${it.id}`} status={ITEM_STATE_LABEL[it.state]} />
                      </View>
                      <Text style={{ fontSize: 14, color: colors.muted }}>
                        {it.previous_owner_name ? `Handed over by ${it.previous_owner_name} · ` : ''}Reported {formatAge(it.age_minutes)} ago
                      </Text>
                      {it.note ? (
                        <Text testID={`ho-note-${it.id}`} style={text}>
                          Note{it.note.author_name ? ` from ${it.note.author_name}` : ''}: {it.note.note}
                        </Text>
                      ) : null}
                      {it.last_actions.length > 0 ? (
                        <View testID={`ho-actions-${it.id}`} style={{ gap: 2 }}>
                          <Text style={{ fontSize: 14, fontWeight: '700', color: colors.text }}>Latest actions</Text>
                          {it.last_actions.map((a, n) => (
                            <Text key={n} style={{ fontSize: 14, color: colors.muted }}>
                              {ACTION_LABEL[a.type] ?? a.type}{a.actor_name ? ` by ${a.actor_name}` : ''} · {formatPlantDateTime(a.at, tz)}{a.notes ? ` · ${a.notes}` : ''}
                            </Text>
                          ))}
                        </View>
                      ) : null}
                      {panel(o, it, k)}
                      {!open || open.key !== k ? (
                        <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
                          {can('acknowledge') ? <Button title={`Acknowledge ${m.code}: ${it.category}`} testID={`ho-ack-${it.id}`} onPress={() => openPanel('ack', k)} disabled={busy} /> : null}
                          {can('refuse') ? <Button title="Refuse" variant="secondary" testID={`ho-refuse-${it.id}`} onPress={() => openPanel('refuse', k)} disabled={busy} /> : null}
                          {can('add_note') ? <Button title="Add note" variant="secondary" testID={`ho-add-note-${it.id}`} onPress={() => openPanel('note', k)} disabled={busy} /> : null}
                          <Button title="Open issue" variant="secondary" testID={`ho-open-${it.id}`} onPress={() => router.push(`/issues/${it.id}`)} />
                        </View>
                      ) : null}
                    </View>
                  );
                })}
              </View>
            ))}
            {o.allowed_actions.length > 0 ? (
              <Button title="Declare handover complete" testID={`ho-declare-${ok}`} onPress={() => declare(o)} disabled={busy} busy={busy} />
            ) : null}
            {!o.declared && o.pending_count > 0 ? (
              <Text testID={`ho-blocked-${ok}`} style={text}>Answer every issue before you declare the handover. Recording the opening reading needs the declaration.</Text>
            ) : null}
          </View>
        );
      })}
      {d && d.verify.length > 0 ? (
        <View testID="ho-verify" style={{ gap: 8 }}>
          <Text accessibilityRole="header" style={{ fontSize: 19, fontWeight: '700', color: colors.text }}>Verify this fix</Text>
          <Text style={{ fontSize: 15, color: colors.text }}>These repairs are waiting for you to confirm. This does not block your shift.</Text>
          {d.verify.map((v) => (
            <Button key={v.id} title={`${v.machine_code}: ${v.category} - open to verify`} variant="secondary" testID={`ho-verify-${v.id}`} onPress={() => router.push(`/issues/${v.id}`)} />
          ))}
        </View>
      ) : null}
      <Button title="Refresh" variant="secondary" testID="handover-refresh" onPress={reload} />
    </View>
  );
}
