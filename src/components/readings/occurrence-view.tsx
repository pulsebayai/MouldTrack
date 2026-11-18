import { router } from 'expo-router';
import { useEffect, useRef, useState } from 'react';
import { Image, ScrollView, Text, View } from 'react-native';
import { Loading, LoadError } from '@/components/plant/common';
import { Button, Chip, ErrorText, Field, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import { downloadPhoto } from '@/lib/photos';
import { PlantError, RequestIds, fetchActiveProducts, formatPlantDate, timeWindow } from '@/lib/plant';
import { fetchPlantTimezone, formatPlantDateTime } from '@/lib/plant-time';
import {
  UNIT_LABEL, fetchReadingDetail, formatCount, readingApi, validateClosing, validateOpening, validateReason, type ReadingDetail, type ReadingEntry, type ReadingPhoto,
} from '@/lib/readings';
import { useSession } from '@/lib/session-provider';
import { useLoad } from '@/lib/use-load';
import { useRefreshOnFocus } from '@/lib/use-refresh';
import { SummaryBlock } from './summary-block';

function PhotoThumb({ photo }: { photo: ReadingPhoto }) {
  const { client } = useSession();
  const [url, setUrl] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    let live = true;
    let release: (() => void) | null = null;
    downloadPhoto(client as never, photo.path, photo.id).then(
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
  }, [client, photo.path, photo.id]);
  if (failed) return <Text testID={`reading-photo-failed-${photo.id}`} style={{ fontSize: 14, color: colors.muted }}>Photo unavailable</Text>;
  if (!url) return <Text style={{ fontSize: 14, color: colors.muted }}>Loading photo</Text>;
  return <Image testID={`reading-photo-${photo.id}`} accessibilityLabel="Counter photo" source={{ uri: url }} style={{ width: 240, height: 180, borderRadius: 8 }} resizeMode="contain" />;
}

function CorrectForm({ d, entry, onDone, onCancel }: { d: ReadingDetail; entry: ReadingEntry; onDone: () => void; onCancel: () => void }) {
  const { client } = useSession();
  const products = useLoad(() => fetchActiveProducts(client), [], entry.kind === 'opening');
  const [productId, setProductId] = useState<string | null>(entry.product_id);
  const [counter, setCounter] = useState(String(entry.counter));
  const [good, setGood] = useState(entry.good === null ? '' : String(entry.good));
  const [reject, setReject] = useState(entry.reject === null ? '' : String(entry.reject));
  const [remarks, setRemarks] = useState(entry.remarks ?? '');
  const [reason, setReason] = useState('');
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const ids = useRef(new RequestIds());

  async function submit() {
    const found = entry.kind === 'opening' ? validateOpening({ productId, counter, remarks }) : validateClosing({ counter, good, reject, remarks });
    const r = validateReason(reason);
    if (r) found.reason = r;
    setErrors(found);
    setError(null);
    if (Object.keys(found).length > 0) return;
    setBusy(true);
    const key = JSON.stringify([entry.id, productId, counter, good, reject, remarks.trim(), reason.trim()]);
    try {
      await readingApi.correct(client, { readingId: entry.id, kind: entry.kind, productId, counter, good, reject, remarks, reason }, ids.current.get(key));
      ids.current.succeeded(key);
      onDone();
    } catch (e) {
      ids.current.failed(key, e);
      if (e instanceof PlantError && e.field && ['counter', 'good', 'reject', 'remarks', 'product_id', 'reason'].includes(e.field)) setErrors({ [e.field]: e.message });
      else setError(e instanceof PlantError ? e.message : toUserMessage(e));
    } finally {
      setBusy(false);
    }
  }
  return (
    <View testID="correct-form" style={{ gap: 12, borderWidth: 1, borderColor: colors.border, borderRadius: 8, padding: 12 }}>
      <Text accessibilityRole="header" style={{ fontSize: 18, fontWeight: '700', color: colors.text }}>Correct the {entry.kind} reading</Text>
      <Text style={{ fontSize: 14, color: colors.text }}>The earlier reading stays in the history. The summary is recalculated.</Text>
      {entry.kind === 'opening' ? (
        <View style={{ gap: 8 }}>
          <Text style={{ fontSize: 15, fontWeight: '600', color: colors.text }}>Product</Text>
          <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
            {(products.data ?? []).map((p) => (
              <Chip key={p.id} testID={`correct-product-${p.id}`} label={`${p.code} · ${p.description}`} selected={productId === p.id} onPress={() => setProductId(p.id)} />
            ))}
          </View>
          {errors.product_id ? <ErrorText testID="correct-product-error">{errors.product_id}</ErrorText> : null}
        </View>
      ) : null}
      <Field label={`Counter reading (${UNIT_LABEL[d.machine.counter_unit].toLowerCase()})`} testID="correct-counter" value={counter} onChangeText={setCounter} keyboardType="number-pad" inputMode="numeric" error={errors.counter} />
      {entry.kind === 'closing' ? (
        <>
          <Field label="Good pieces" testID="correct-good" value={good} onChangeText={setGood} keyboardType="number-pad" inputMode="numeric" error={errors.good} />
          <Field label="Reject pieces" testID="correct-reject" value={reject} onChangeText={setReject} keyboardType="number-pad" inputMode="numeric" error={errors.reject} />
        </>
      ) : null}
      <Field label="Remarks (optional)" testID="correct-remarks" value={remarks} onChangeText={setRemarks} multiline maxLength={500} error={errors.remarks} />
      <Field label="Reason for the correction" testID="correct-reason" value={reason} onChangeText={setReason} maxLength={200} error={errors.reason} />
      {error ? <ErrorText testID="correct-error">{error}</ErrorText> : null}
      <Button title="Save correction" testID="correct-submit" onPress={submit} busy={busy} disabled={busy} />
      <Button title="Cancel" variant="secondary" testID="correct-cancel" onPress={onCancel} disabled={busy} />
    </View>
  );
}

/** One machine-occurrence: every reading with its corrections, the latest summary next to the target, photos and what the server lets me do (AC-15). */
export function OccurrenceView({ machineId, shiftId, shiftDate }: { machineId: string; shiftId: string; shiftDate: string }) {
  const { client } = useSession();
  const detail = useLoad<ReadingDetail>(() => fetchReadingDetail(client, machineId, shiftId, shiftDate), [machineId, shiftId, shiftDate]);
  const tz = useLoad(() => fetchPlantTimezone(client), []).data ?? 'Asia/Kolkata';
  useRefreshOnFocus(detail.reload);
  const [correcting, setCorrecting] = useState<'opening' | 'closing' | null>(null);
  const d = detail.data ?? detail.latest;
  const when = (iso: string) => formatPlantDateTime(iso, tz);
  const record = (kind: 'opening' | 'closing') => router.push({ pathname: '/readings/record' as never, params: { machineId, shiftId, date: shiftDate, kind } });
  const text = { fontSize: 15, color: colors.text } as const;
  return (
    <ScrollView testID="occurrence-screen" contentContainerStyle={{ alignItems: 'center', padding: 24 }}>
      <View style={{ width: '100%', maxWidth: 560, gap: 16 }}>
        <Text accessibilityRole="header" style={{ fontSize: 24, fontWeight: '700', color: colors.text }}>Readings</Text>
        {detail.state === 'loading' && !d ? <Loading testID="occurrence-loading" label="Loading readings" /> : null}
        {detail.state === 'error' ? <LoadError testID="occurrence-error" onRetry={detail.reload} error={detail.error} /> : null}
        {d ? (
          <>
            <View style={{ gap: 4 }}>
              <Text testID="occurrence-machine" style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>{d.machine.code} · {d.machine.name}</Text>
              <Text testID="occurrence-shift" style={text}>{d.shift.name} · {timeWindow(d.shift.start_time, d.shift.end_time)} · {formatPlantDate(d.shift_date)}</Text>
              <Text testID="occurrence-owner" style={text}>Supervisor: {d.owner_name ?? 'Not assigned'}</Text>
            </View>
            {d.summary ? (
              <View style={{ gap: 4 }}>
                <Text style={{ fontSize: 18, fontWeight: '700', color: colors.text }}>Summary</Text>
                <Text testID="occurrence-counters" style={text}>Counters: opening {formatCount(d.summary.opening_counter)} · closing {formatCount(d.summary.closing_counter)}</Text>
                <SummaryBlock s={d.summary} testID="occurrence-summary" late={{ opening: d.summary.late_opening, closing: d.summary.late_closing, early: d.summary.early_closing }} />
                {d.summary_count > 1 ? <Text testID="occurrence-summary-count" style={text}>Recalculated {d.summary_count - 1} time(s) after corrections.</Text> : null}
              </View>
            ) : <Text testID="occurrence-no-summary" style={text}>The summary appears once the closing reading is recorded.</Text>}
            <View style={{ gap: 8 }}>
              <Text style={{ fontSize: 18, fontWeight: '700', color: colors.text }}>History</Text>
              {d.readings.map((r) => (
                <View key={r.id} testID={`reading-entry-${r.id}`} style={{ gap: 2, borderLeftWidth: 3, borderLeftColor: colors.border, paddingLeft: 8 }}>
                  <Text style={{ fontSize: 15, fontWeight: '700', color: colors.text }}>
                    {r.kind === 'opening' ? 'Opening' : 'Closing'}{r.supersedes_id ? ' (correction)' : ''}{r.current ? '' : ' · replaced'}
                  </Text>
                  <Text style={text}>Counter: {formatCount(r.counter)}{r.product_code ? ` · Product: ${r.product_code}` : ''}</Text>
                  {r.kind === 'closing' ? <Text style={text}>Good: {formatCount(r.good)} · Reject: {formatCount(r.reject)}</Text> : null}
                  <Text style={text}>{r.recorded_by_name ?? 'Unknown'} · {when(r.recorded_at)}{r.late ? ' · Late' : ''}{r.early ? ' · Early' : ''}{r.entered_by_ua ? ' · Entered by a Unit Admin' : ''}</Text>
                  {r.remarks ? <Text style={text}>Remarks: {r.remarks}</Text> : null}
                  {r.correction_reason ? <Text style={text}>Reason: {r.correction_reason}</Text> : null}
                </View>
              ))}
            </View>
            {d.photos.length > 0 ? (
              <View style={{ gap: 8 }}>
                <Text style={{ fontSize: 18, fontWeight: '700', color: colors.text }}>Photos</Text>
                {d.photos.map((p) => <PhotoThumb key={p.id} photo={p} />)}
              </View>
            ) : null}
            {(d.allowed.can_open || d.allowed.can_close) && correcting === null ? (
              <View style={{ gap: 8 }}>
                {d.allowed.can_open ? <Button title="Record opening" testID="occurrence-record-opening" onPress={() => record('opening')} /> : null}
                {d.allowed.can_close ? <Button title="Record closing" testID="occurrence-record-closing" onPress={() => record('closing')} /> : null}
              </View>
            ) : null}
            {d.allowed.can_correct && correcting === null ? (
              <View style={{ gap: 8 }}>
                {d.opening ? <Button title="Correct opening" variant="secondary" testID="correct-opening" onPress={() => setCorrecting('opening')} /> : null}
                {d.closing ? <Button title="Correct closing" variant="secondary" testID="correct-closing" onPress={() => setCorrecting('closing')} /> : null}
              </View>
            ) : null}
            {correcting && (correcting === 'opening' ? d.opening : d.closing) ? (
              <CorrectForm d={d} entry={(correcting === 'opening' ? d.opening : d.closing)!} onCancel={() => setCorrecting(null)} onDone={() => { setCorrecting(null); detail.reload(); }} />
            ) : null}
          </>
        ) : null}
        <Button title="Back" variant="secondary" testID="occurrence-back" onPress={() => (router.canGoBack() ? router.back() : router.replace('/home'))} />
      </View>
    </ScrollView>
  );
}
