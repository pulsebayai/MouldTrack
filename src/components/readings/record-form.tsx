import { router } from 'expo-router';
import { useEffect, useRef, useState } from 'react';
import { ScrollView, Text, View } from 'react-native';
import { Loading, LoadError } from '@/components/plant/common';
import { Button, Chip, ErrorText, Field, colors } from '@/components/ui';
import { newRequestId } from '@/lib/api';
import { toUserMessage } from '@/lib/errors';
import { PhotoError, pickPhoto, uploadReadingPhoto, type Photo } from '@/lib/photos';
import { PlantError, RequestIds, fetchActiveProducts, formatPlantDate, timeWindow } from '@/lib/plant';
import { clearReadingDraft, loadReadingDraft, readingDraftKey, saveReadingDraft } from '@/lib/reading-draft';
import { UNIT_LABEL, fetchReadingDetail, readingApi, validateClosing, validateOpening } from '@/lib/readings';
import { useSession } from '@/lib/session-provider';
import { useLoad } from '@/lib/use-load';

type Props = { machineId: string; shiftId: string; shiftDate: string; kind: 'opening' | 'closing' };

/**
 * Record the opening or the closing reading of one machine in one shift occurrence. The server decides who may record and when (window,
 * owner); this form only collects the numbers, keeps a local draft until the reading is accepted and uploads the optional photo afterwards.
 */
export function RecordForm({ machineId, shiftId, shiftDate, kind }: Props) {
  const { client } = useSession();
  // The form's context (machine, unit, default product, what may be recorded) comes from reading_detail, so it also works for a Unit Admin who
  // records on behalf of a supervisor (reading_state lists only the caller's own machines).
  const detail = useLoad(() => fetchReadingDetail(client, machineId, shiftId, shiftDate), [machineId, shiftId, shiftDate]);
  const products = useLoad(() => fetchActiveProducts(client), [], kind === 'opening');
  const [productId, setProductId] = useState<string | null>(null);
  const [counter, setCounter] = useState('');
  const [good, setGood] = useState('');
  const [reject, setReject] = useState('');
  const [remarks, setRemarks] = useState('');
  const [photo, setPhoto] = useState<Photo | null>(null);
  const [photoError, setPhotoError] = useState<string | null>(null);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [restored, setRestored] = useState(false);
  const ids = useRef(new RequestIds());
  const photoIds = useRef({ begin: newRequestId(), commit: newRequestId() });
  const saved = useRef<string | null>(null); // the reading id once recorded, so a failed photo upload retries without recording twice
  const [recorded, setRecorded] = useState(false);
  const draftKey = readingDraftKey(machineId, shiftId, shiftDate, kind);

  const d = detail.data ?? detail.latest;
  const allowed = d ? (kind === 'opening' ? d.allowed.can_open : d.allowed.can_close) : false;

  useEffect(() => {
    loadReadingDraft(draftKey).then((d) => {
      if (d) {
        setProductId(d.productId);
        setCounter(d.counter);
        setGood(d.good);
        setReject(d.reject);
        setRemarks(d.remarks);
      }
      setRestored(true);
    });
  }, [draftKey]);
  useEffect(() => {
    if (restored) saveReadingDraft(draftKey, { productId, counter, good, reject, remarks });
  }, [draftKey, restored, productId, counter, good, reject, remarks]);
  // The default product (the latest opening's) is shown as chosen until the person picks another (derived, not copied into state).
  const chosen = productId ?? (kind === 'opening' ? d?.default_product_id ?? null : null);

  async function choosePhoto(source: 'camera' | 'library') {
    setPhotoError(null);
    try {
      const p = await pickPhoto(source);
      if (p) {
        setPhoto(p);
        photoIds.current = { begin: newRequestId(), commit: newRequestId() };
      }
    } catch (e) {
      setPhotoError(e instanceof PhotoError ? e.message : toUserMessage(e));
    }
  }

  async function submit() {
    const found = kind === 'opening' ? validateOpening({ productId: chosen, counter, remarks }) : validateClosing({ counter, good, reject, remarks });
    setErrors(found);
    setError(null);
    if (Object.keys(found).length > 0) return;
    setBusy(true);
    try {
      if (!saved.current) {
        const key = JSON.stringify([kind, machineId, shiftId, shiftDate, chosen, counter, good, reject, remarks.trim()]);
        try {
          const r = kind === 'opening'
            ? await readingApi.opening(client, { machineId, shiftId, shiftDate, productId: chosen!, counter, remarks }, ids.current.get(key))
            : await readingApi.closing(client, { machineId, shiftId, shiftDate, counter, good, reject, remarks }, ids.current.get(key));
          ids.current.succeeded(key);
          saved.current = r.id ?? null;
          setRecorded(true);
          await clearReadingDraft(draftKey); // N-8: the reading is saved, so the draft is done even if the photo still has to be retried
        } catch (e) {
          ids.current.failed(key, e);
          throw e;
        }
      }
      if (photo && saved.current) {
        try {
          await uploadReadingPhoto(client as never, saved.current, photo, photoIds.current);
        } catch (e) {
          setError(`The reading was recorded, but the photo did not upload. ${toUserMessage(e)}`);
          return;
        }
      }
      await clearReadingDraft(draftKey);
      router.replace('/readings');
    } catch (e) {
      if (e instanceof PlantError && e.field && ['counter', 'good', 'reject', 'remarks', 'product_id'].includes(e.field)) setErrors({ [e.field]: e.message });
      else setError(e instanceof PlantError ? e.message : toUserMessage(e));
    } finally {
      setBusy(false);
    }
  }

  const unit = d ? UNIT_LABEL[d.machine.counter_unit].toLowerCase() : 'counter';
  const title = kind === 'opening' ? 'Opening reading' : 'Closing reading';
  return (
    <ScrollView testID={`record-${kind}-screen`} contentContainerStyle={{ alignItems: 'center', padding: 24 }}>
      <View style={{ width: '100%', maxWidth: 560, gap: 16 }}>
        <Text accessibilityRole="header" style={{ fontSize: 24, fontWeight: '700', color: colors.text }}>{title}</Text>
        {detail.state === 'loading' && !d ? <Loading testID="record-loading" label="Loading" /> : null}
        {detail.state === 'error' ? <LoadError testID="record-load-error" onRetry={detail.reload} error={detail.error} /> : null}
        {d ? (
          <View style={{ gap: 4 }}>
            <Text testID="record-machine" style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>{d.machine.code} · {d.machine.name}</Text>
            <Text testID="record-shift" style={{ fontSize: 15, color: colors.text }}>
              {d.shift.name} · {timeWindow(d.shift.start_time, d.shift.end_time)} · {formatPlantDate(d.shift_date)}
            </Text>
            <Text testID="record-unit" style={{ fontSize: 15, color: colors.text }}>Counter counts: {UNIT_LABEL[d.machine.counter_unit]}</Text>
          </View>
        ) : null}
        {d && !allowed && !recorded ? (
          <Text testID="record-not-allowed" accessibilityRole="alert" style={{ fontSize: 16, color: colors.error }}>
            The {kind} reading cannot be recorded for this machine right now. Go back to the readings to see what is open.
          </Text>
        ) : null}
        {d && (allowed || recorded) ? (
          <>
            {kind === 'opening' ? (
              <View style={{ gap: 8 }}>
                <Text style={{ fontSize: 15, fontWeight: '600', color: colors.text }}>Product</Text>
                {products.state === 'loading' ? <Loading testID="record-products-loading" label="Loading products" /> : null}
                {products.state === 'error' ? <LoadError testID="record-products-error" onRetry={products.reload} error={products.error} /> : null}
                <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
                  {(products.data ?? []).map((p) => (
                    <Chip key={p.id} testID={`record-product-${p.id}`} label={`${p.code} · ${p.description}`} selected={chosen === p.id} onPress={() => setProductId(p.id)} />
                  ))}
                </View>
                {errors.product_id ? <ErrorText testID="record-product-error">{errors.product_id}</ErrorText> : null}
              </View>
            ) : null}
            <Field label={`Counter reading (${unit})`} testID="record-counter" value={counter} onChangeText={setCounter} keyboardType="number-pad" inputMode="numeric" error={errors.counter} />
            {kind === 'closing' ? (
              <>
                <Field label="Good pieces" testID="record-good" value={good} onChangeText={setGood} keyboardType="number-pad" inputMode="numeric" error={errors.good} />
                <Field label="Reject pieces" testID="record-reject" value={reject} onChangeText={setReject} keyboardType="number-pad" inputMode="numeric" error={errors.reject} />
              </>
            ) : null}
            <Field label="Remarks (optional)" testID="record-remarks" value={remarks} onChangeText={setRemarks} multiline maxLength={500} error={errors.remarks} />
            <View style={{ gap: 8 }}>
                <Text style={{ fontSize: 15, fontWeight: '600', color: colors.text }}>Photo of the counter (optional)</Text>
                {photo ? <Text testID="record-photo-ready" accessibilityLiveRegion="polite" style={{ fontSize: 15, color: colors.text }}>Photo ready ({Math.round(photo.bytes.length / 1024)} KB)</Text> : null}
                <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
                  <Button title="Take photo" variant="secondary" testID="record-photo-camera" onPress={() => choosePhoto('camera')} disabled={busy} />
                  <Button title="Choose photo" variant="secondary" testID="record-photo-library" onPress={() => choosePhoto('library')} disabled={busy} />
                  {photo ? <Button title="Remove photo" variant="secondary" testID="record-photo-remove" onPress={() => setPhoto(null)} disabled={busy} /> : null}
                </View>
                {photoError ? <ErrorText testID="record-photo-error">{photoError}</ErrorText> : null}
            </View>
            {error ? <ErrorText testID="record-error">{error}</ErrorText> : null}
            <Button title={recorded ? 'Try again' : `Save ${kind} reading`} testID="record-submit" onPress={submit} busy={busy} disabled={busy} />
          </>
        ) : null}
        <Button title="Cancel" variant="secondary" testID="record-cancel" onPress={() => (router.canGoBack() ? router.back() : router.replace('/readings'))} disabled={busy} />
      </View>
    </ScrollView>
  );
}
