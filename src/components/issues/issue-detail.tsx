import { router } from 'expo-router';
import { useEffect, useRef, useState } from 'react';
import { Image, ScrollView, Text, View } from 'react-native';
import { Loading, LoadError, rowStyle } from '@/components/plant/common';
import { Button, Chip, ErrorText, Field, StatusLabel, colors } from '@/components/ui';
import { newRequestId } from '@/lib/api';
import { toUserMessage } from '@/lib/errors';
import {
  ACTION_LABEL, LIMITS, MSG, PRIORITY_LABEL, STATUS_LABEL, fetchIssueDetail, formatAge, issueApi, validateText, type AllowedAction, type IssueAttachment, type IssueDetail,
} from '@/lib/issues';
import { PhotoError, downloadPhoto, pickPhoto, uploadIssuePhoto, type Photo } from '@/lib/photos';
import { PlantError, RequestIds, fetchActiveSupervisors, type Supervisor } from '@/lib/plant';
import { fetchPlantTimezone, formatPlantDateTime } from '@/lib/plant-time';
import { useRefreshOnFocus } from '@/lib/use-refresh';
import { useSession } from '@/lib/session-provider';
import { useLoad } from '@/lib/use-load';

type Panel = 'note' | 'set_assignee' | 'escalate' | 'ack_escalation' | 'reassign' | 'resolve' | 'reject' | 'reopen' | 'photo';

const PANEL: Record<Panel, { title: string; label: string; submit: string; max: number; message: string }> = {
  note: { title: 'Add a note', label: 'Note', submit: 'Add note', max: LIMITS.note, message: MSG.note },
  set_assignee: { title: 'Technical assignee', label: 'Who is fixing it (name or team)', submit: 'Save assignee', max: LIMITS.assignee, message: MSG.assignee },
  escalate: { title: 'Escalate to the Unit Admin', label: 'Why are you escalating?', submit: 'Escalate', max: LIMITS.reason, message: MSG.reason },
  ack_escalation: { title: 'Acknowledge escalation', label: 'Note', submit: 'Acknowledge', max: LIMITS.ackNote, message: MSG.ackNote },
  reassign: { title: 'Change owner', label: 'Reason', submit: 'Change owner', max: LIMITS.reason, message: MSG.reason },
  resolve: { title: 'Mark resolved', label: 'What was done?', submit: 'Mark resolved', max: LIMITS.resolution, message: MSG.resolution },
  reject: { title: 'Not fixed', label: 'What is still wrong?', submit: 'Send back', max: LIMITS.reason, message: MSG.reason },
  reopen: { title: 'Reopen', label: 'Why reopen?', submit: 'Reopen', max: LIMITS.reason, message: MSG.reason },
  photo: { title: 'Add a photo', label: '', submit: 'Upload photo', max: 0, message: '' },
};

const ACTION_BUTTON: { action: AllowedAction; title: string; panel?: Panel }[] = [
  { action: 'start', title: 'Start work' },
  { action: 'note', title: 'Add note', panel: 'note' },
  { action: 'photo', title: 'Add photo', panel: 'photo' },
  { action: 'set_assignee', title: 'Set assignee', panel: 'set_assignee' },
  { action: 'escalate', title: 'Escalate', panel: 'escalate' },
  { action: 'ack_escalation', title: 'Acknowledge escalation', panel: 'ack_escalation' },
  { action: 'reassign', title: 'Change owner', panel: 'reassign' },
  { action: 'resolve', title: 'Mark resolved', panel: 'resolve' },
  { action: 'reopen', title: 'Reopen', panel: 'reopen' },
];

function Photo_({ att }: { att: IssueAttachment }) {
  const { client } = useSession();
  const [url, setUrl] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    let live = true;
    let release: (() => void) | null = null;
    downloadPhoto(client as never, att.path, att.id).then(
      (p) => {
        if (!live) return p?.release();
        if (!p) return setFailed(true);
        release = p.release;
        setUrl(p.uri);
      },
      () => live && setFailed(true),
    );
    return () => {
      live = false;
      release?.();
    };
  }, [client, att.path, att.id]);
  if (failed) return <Text testID={`photo-failed-${att.id}`} style={{ fontSize: 14, color: colors.muted }}>Photo unavailable</Text>;
  if (!url) return <Text style={{ fontSize: 14, color: colors.muted }}>Loading photo</Text>;
  return <Image testID={`photo-${att.id}`} accessibilityLabel="Issue photo" source={{ uri: url }} style={{ width: 240, height: 180, borderRadius: 8 }} resizeMode="contain" />;
}

/** The server computes allowed_actions (the same helpers the RPCs use); this screen only renders them (principle 1). */
export function IssueDetailView({ id }: { id: string }) {
  const { client } = useSession();
  const detail = useLoad<IssueDetail>(() => fetchIssueDetail(client, id), [id]);
  const d = detail.data ?? detail.latest;
  useRefreshOnFocus(detail.reload);
  const tz = useLoad(() => fetchPlantTimezone(client), []).data ?? 'Asia/Kolkata';
  const when = (iso: string) => formatPlantDateTime(iso, tz);
  const [panel, setPanel] = useState<Panel | null>(null);
  const [text, setText] = useState('');
  const [owner, setOwner] = useState<string | null>(null);
  const [photo, setPhoto] = useState<Photo | null>(null);
  const [fieldError, setFieldError] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const ids = useRef(new RequestIds());
  const photoIds = useRef({ begin: newRequestId(), commit: newRequestId() });
  const sups = useLoad<Supervisor[]>(() => fetchActiveSupervisors(client), [], panel === 'reassign');

  function open(p: Panel) {
    setPanel(p); setText(''); setOwner(null); setPhoto(null); setFieldError(null); setError(null);
    photoIds.current = { begin: newRequestId(), commit: newRequestId() };
  }
  function close() { setPanel(null); }
  function show(e: unknown) {
    setError(e instanceof PlantError ? e.message : toUserMessage(e));
  }

  /** Runs one write with the request-id rules of 02: same id on a network retry, a new one after a refusal or success. */
  async function run(key: string, fn: (rid: string) => Promise<unknown>, after?: () => void) {
    setBusy(true); setError(null);
    try {
      await fn(ids.current.get(key));
      ids.current.succeeded(key);
      close();
      after?.();
      detail.reload();
    } catch (e) {
      ids.current.failed(key, e);
      show(e);
      detail.reload(); // a refusal usually means the state moved on (someone else acted): show the new one
    } finally {
      setBusy(false);
    }
  }

  async function submit() {
    if (!panel || !d) return;
    const issueId = d.issue.id;
    if (panel === 'photo') {
      if (!photo) { setFieldError('Choose a photo first'); return; }
      setBusy(true); setError(null);
      try {
        await uploadIssuePhoto(client as never, issueId, photo, photoIds.current);
        close();
        detail.reload();
      } catch (e) { show(e); } finally { setBusy(false); }
      return;
    }
    const cfg = PANEL[panel];
    const bad = validateText(text, cfg.max, cfg.message);
    if (bad) { setFieldError(bad); return; }
    if (panel === 'reassign' && !owner) { setFieldError('Choose the new owner'); return; }
    setFieldError(null);
    const key = JSON.stringify([panel, issueId, owner, text.trim()]);
    switch (panel) {
      case 'note': return run(key, (r) => issueApi.note(client, issueId, text, r));
      case 'set_assignee': return run(key, (r) => issueApi.setAssignee(client, issueId, text, r));
      case 'escalate': return run(key, (r) => issueApi.escalate(client, issueId, text, r));
      case 'ack_escalation': return run(key, (r) => issueApi.ackEscalation(client, issueId, text, r));
      case 'reassign': return run(key, (r) => issueApi.reassign(client, issueId, owner!, text, r));
      case 'resolve': return run(key, (r) => issueApi.resolve(client, issueId, text, r));
      case 'reject': return run(key, (r) => issueApi.verify(client, issueId, false, text, r));
      case 'reopen': return run(key, (r) => issueApi.reopen(client, issueId, text, r));
    }
  }

  async function choosePhoto() {
    try {
      const p = await pickPhoto('library');
      if (p) { setPhoto(p); setFieldError(null); photoIds.current = { begin: newRequestId(), commit: newRequestId() }; }
    } catch (e) {
      setFieldError(e instanceof PhotoError ? e.message : toUserMessage(e));
    }
  }
  async function takePhoto() {
    try {
      const p = await pickPhoto('camera');
      if (p) { setPhoto(p); setFieldError(null); photoIds.current = { begin: newRequestId(), commit: newRequestId() }; }
    } catch (e) {
      setFieldError(e instanceof PhotoError ? e.message : toUserMessage(e));
    }
  }

  const allowed = new Set(d?.allowed_actions ?? []);
  const i = d?.issue;
  return (
    <ScrollView testID="issue-screen" contentContainerStyle={{ alignItems: 'center', padding: 24 }}>
      <View style={{ width: '100%', maxWidth: 720, gap: 16 }}>
        <Button title="Back to issues" variant="secondary" testID="issue-back" onPress={() => (router.canGoBack() ? router.back() : router.replace('/issues'))} />
        {detail.state === 'loading' && !d ? <Loading testID="issue-loading" label="Loading issue" /> : null}
        {detail.state === 'error' ? <LoadError testID="issue-error" onRetry={detail.reload} error={detail.error} /> : null}
        {d && i ? (
          <>
            <Text accessibilityRole="header" testID="issue-title" style={{ fontSize: 24, fontWeight: '700', color: colors.text }}>{i.machine_code} · {i.category}</Text>
            <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 6 }}>
              <StatusLabel testID="issue-priority" status={PRIORITY_LABEL[i.priority]} />
              <StatusLabel testID="issue-status" status={STATUS_LABEL[i.status]} />
              {i.machine_stopped ? <StatusLabel testID="issue-stopped" status="Machine stopped" /> : null}
              {i.escalated ? <StatusLabel testID="issue-escalated" status="Escalated" /> : null}
              {i.needs_owner ? <StatusLabel testID="issue-no-owner" status="Needs owner" /> : null}
            </View>
            <Text testID="issue-description" style={{ fontSize: 16, color: colors.text }}>{i.description}</Text>
            <Text testID="issue-owner" style={{ fontSize: 15, color: colors.text }}>Owner: {i.owner_name ?? 'None'}</Text>
            {i.technical_assignee ? <Text testID="issue-assignee" style={{ fontSize: 15, color: colors.text }}>Technical assignee: {i.technical_assignee}</Text> : null}
            <Text style={{ fontSize: 14, color: colors.muted }}>Reported by {i.reported_by_name ?? 'unknown'} · {formatAge(i.age_minutes)} ago</Text>
            {i.resolution_notes ? <Text testID="issue-resolution" style={{ fontSize: 15, color: colors.text }}>Resolution: {i.resolution_notes}</Text> : null}

            {allowed.has('verify') ? (
              <View testID="verify-panel" style={{ ...rowStyle, borderColor: colors.primary, borderWidth: 2 }}>
                <Text accessibilityRole="header" style={{ fontSize: 18, fontWeight: '700', color: colors.text }}>Verify the fix</Text>
                <Text style={{ fontSize: 15, color: colors.text }}>Check the machine, then confirm it is fixed or send it back.</Text>
                <Button title="Confirm fixed" testID="verify-confirm" onPress={() => run(JSON.stringify(['confirm', i.id]), (r) => issueApi.verify(client, i.id, true, null, r))} disabled={busy} />
                <Button title="Not fixed - give a reason" variant="secondary" testID="verify-reject" onPress={() => open('reject')} disabled={busy} />
              </View>
            ) : null}

            <View testID="issue-actions" style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
              {ACTION_BUTTON.filter((b) => allowed.has(b.action)).map((b) => (
                <Button
                  key={b.action}
                  title={b.title}
                  variant="secondary"
                  testID={`action-${b.action}`}
                  disabled={busy}
                  onPress={() => (b.panel ? open(b.panel) : run(JSON.stringify([b.action, i.id]), (r) => issueApi.start(client, i.id, r)))}
                />
              ))}
            </View>

            {panel ? (
              <View testID="action-panel" style={rowStyle}>
                <Text accessibilityRole="header" style={{ fontSize: 18, fontWeight: '700', color: colors.text }}>{PANEL[panel].title}</Text>
                {panel === 'reassign' ? (
                  <View style={{ gap: 8 }}>
                    <Text style={{ fontSize: 15, fontWeight: '600', color: colors.text }}>New owner</Text>
                    {sups.state === 'error' ? <LoadError testID="reassign-error" onRetry={sups.reload} error={sups.error} /> : null}
                    <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
                      {(sups.data ?? []).map((s) => (
                        <Chip key={s.user_id} testID={`reassign-${s.user_id}`} label={`${s.full_name} (${s.employee_id})`} selected={owner === s.user_id} onPress={() => setOwner(s.user_id)} />
                      ))}
                    </View>
                  </View>
                ) : null}
                {panel === 'photo' ? (
                  <View style={{ gap: 8 }}>
                    {photo ? <Text testID="detail-photo-ready" style={{ fontSize: 15, color: colors.text }}>Photo ready ({Math.round(photo.bytes.length / 1024)} KB)</Text> : null}
                    <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
                      <Button title="Take photo" variant="secondary" testID="detail-photo-camera" onPress={takePhoto} disabled={busy} />
                      <Button title="Choose photo" variant="secondary" testID="detail-photo-library" onPress={choosePhoto} disabled={busy} />
                    </View>
                    {fieldError ? <ErrorText testID="action-field-error">{fieldError}</ErrorText> : null}
                  </View>
                ) : (
                  <Field label={PANEL[panel].label} testID="action-text" value={text} onChangeText={setText} multiline maxLength={PANEL[panel].max} error={fieldError} />
                )}
                {error ? <ErrorText testID="action-error">{error}</ErrorText> : null}
                <Button title={PANEL[panel].submit} testID="action-submit" onPress={submit} busy={busy} disabled={busy} />
                <Button title="Cancel" variant="secondary" testID="action-cancel" onPress={close} disabled={busy} />
              </View>
            ) : error ? <ErrorText testID="action-error">{error}</ErrorText> : null}

            <Text accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>History</Text>
            {d.actions.map((a, n) => (
              <View key={a.id} testID={`timeline-${n}`} style={rowStyle}>
                <Text testID={`timeline-${n}-label`} style={{ fontSize: 16, fontWeight: '700', color: colors.text }}>{ACTION_LABEL[a.type] ?? a.type}</Text>
                <Text style={{ fontSize: 14, color: colors.muted }}>{a.actor_name ?? 'Unknown'} · {when(a.at)}</Text>
                {a.status_before && a.status_after && a.status_before !== a.status_after ? (
                  <Text style={{ fontSize: 14, color: colors.text }}>{STATUS_LABEL[a.status_before]} to {STATUS_LABEL[a.status_after]}</Text>
                ) : null}
                {a.notes ? <Text style={{ fontSize: 15, color: colors.text }}>{a.notes}</Text> : null}
                {a.attachments.map((t) => <Photo_ key={t.id} att={t} />)}
              </View>
            ))}
            <Text accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>Ownership</Text>
            {d.ownership.map((o, n) => (
              <View key={`${o.at}-${n}`} testID={`ownership-${n}`} style={rowStyle}>
                <Text style={{ fontSize: 15, color: colors.text }}>
                  {o.previous_owner_name ? `${o.previous_owner_name} to ` : 'Assigned to '}{o.new_owner_name ?? 'nobody'}
                </Text>
                <Text style={{ fontSize: 14, color: colors.muted }}>{when(o.at)}{o.reason ? ` · ${o.reason}` : ''}</Text>
              </View>
            ))}
          </>
        ) : null}
      </View>
    </ScrollView>
  );
}
