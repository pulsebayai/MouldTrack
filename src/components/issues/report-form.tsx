import { router } from 'expo-router';
import { useEffect, useRef, useState } from 'react';
import { ScrollView, Text, View } from 'react-native';
import { Loading, LoadError } from '@/components/plant/common';
import { Button, Chip, ErrorText, Field, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import {
  PRIORITIES, PRIORITY_LABEL, effectivePriority, fetchCategories, issueApi, validateReport, type Priority,
} from '@/lib/issues';
import { clearDraft, loadDraft, saveDraft } from '@/lib/issue-draft';
import { PhotoError, pickPhoto, uploadIssuePhoto, type Photo } from '@/lib/photos';
import { PlantError, RequestIds, fetchMachines } from '@/lib/plant';
import { newRequestId } from '@/lib/api';
import { useSession } from '@/lib/session-provider';
import { useLoad } from '@/lib/use-load';

/**
 * Report an issue on one machine (D11). The server decides who may report where; this form only collects the fields. A stopped machine
 * locks Critical. The text is kept as a local draft until the report is accepted. A photo is optional and uploads after the report exists.
 */
export function ReportForm({ machineId }: { machineId: string | null }) {
  const { client } = useSession();
  const [machine, setMachine] = useState<string | null>(machineId);
  const cats = useLoad(() => fetchCategories(client), []);
  const machines = useLoad(() => fetchMachines(client, { search: '', status: 'all', line: 'all', showRetired: false, page: 0 }), [], machineId === null);
  const [categoryId, setCategoryId] = useState<string | null>(null);
  const [priority, setPriority] = useState<Priority | null>(null);
  const [description, setDescription] = useState('');
  const [stopped, setStopped] = useState(false);
  const [photo, setPhoto] = useState<Photo | null>(null);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [photoError, setPhotoError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [restored, setRestored] = useState(false);
  const ids = useRef(new RequestIds());
  const photoIds = useRef({ begin: newRequestId(), commit: newRequestId() });
  const [reported, setReported] = useState(false);
  const issueId = useRef<string | null>(null); // set once the report exists, so a failed photo upload retries without reporting twice

  useEffect(() => {
    if (!machine) return;
    loadDraft(machine).then((d) => {
      if (d) {
        setCategoryId(d.categoryId);
        setPriority(d.priority);
        setDescription(d.description);
        setStopped(d.stopped);
      }
      setRestored(true);
    });
  }, [machine]);
  useEffect(() => {
    if (machine && restored) saveDraft(machine, { categoryId, priority, description, stopped });
  }, [machine, restored, categoryId, priority, description, stopped]);

  const shownPriority = effectivePriority(priority, stopped);

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
    if (!machine) return;
    const found = validateReport({ categoryId, priority, description, stopped });
    setErrors(found);
    setError(null);
    if (Object.keys(found).length > 0) return;
    setBusy(true);
    try {
      if (!issueId.current) {
        const key = JSON.stringify(['report', machine, categoryId, shownPriority, description.trim(), stopped]);
        try {
          const r = await issueApi.report(client, { machineId: machine, categoryId: categoryId!, priority: shownPriority!, description, stopped }, ids.current.get(key));
          ids.current.succeeded(key);
          issueId.current = r.id ?? null;
          setReported(true);
        } catch (e) {
          ids.current.failed(key, e);
          throw e;
        }
      }
      if (photo && issueId.current) {
        try {
          await uploadIssuePhoto(client as never, issueId.current, photo, photoIds.current);
        } catch (e) {
          // The report is saved; only the photo failed. Keep the draft and the issue id so "Try again" uploads the photo only.
          setError(`The issue was reported, but the photo did not upload. ${toUserMessage(e)}`);
          return;
        }
      }
      await clearDraft(machine);
      router.replace(`/issues/${issueId.current}`);
    } catch (e) {
      if (e instanceof PlantError && e.field === 'category_id') setErrors({ category_id: e.message });
      else if (e instanceof PlantError && e.field === 'description') setErrors({ description: e.message });
      else setError(e instanceof PlantError ? e.message : toUserMessage(e));
    } finally {
      setBusy(false);
    }
  }

  const chosenMachine = machines.data?.rows.find((m) => m.id === machine);
  return (
    <ScrollView testID="report-screen" contentContainerStyle={{ alignItems: 'center', padding: 24 }}>
      <View style={{ width: '100%', maxWidth: 560, gap: 16 }}>
        <Text accessibilityRole="header" style={{ fontSize: 24, fontWeight: '700', color: colors.text }}>Report an issue</Text>
        {machineId === null ? (
          <View style={{ gap: 8 }}>
            <Text style={{ fontSize: 15, fontWeight: '600', color: colors.text }}>Machine</Text>
            {machines.state === 'loading' ? <Loading testID="report-machines-loading" label="Loading machines" /> : null}
            {machines.state === 'error' ? <LoadError testID="report-machines-error" onRetry={machines.reload} error={machines.error} /> : null}
            <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
              {(machines.data?.rows ?? []).map((m) => (
                <Chip key={m.id} testID={`report-machine-${m.id}`} label={`${m.code} · ${m.name}`} selected={machine === m.id} onPress={() => setMachine(m.id)} />
              ))}
            </View>
            {errors.machine ? <ErrorText>{errors.machine}</ErrorText> : null}
          </View>
        ) : null}
        {chosenMachine ? <Text testID="report-machine" style={{ fontSize: 16, color: colors.text }}>{chosenMachine.code} · {chosenMachine.name}</Text> : null}
        {machine ? (
          <>
            <View style={{ gap: 8 }}>
              <Text style={{ fontSize: 15, fontWeight: '600', color: colors.text }}>Category</Text>
              {cats.state === 'loading' ? <Loading testID="report-cats-loading" label="Loading categories" /> : null}
              {cats.state === 'error' ? <LoadError testID="report-cats-error" onRetry={cats.reload} error={cats.error} /> : null}
              <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
                {(cats.data ?? []).map((c) => (
                  <Chip key={c.id} testID={`report-category-${c.id}`} label={c.name} selected={categoryId === c.id} onPress={() => setCategoryId(c.id)} />
                ))}
              </View>
              {errors.category_id ? <ErrorText testID="report-category-error">{errors.category_id}</ErrorText> : null}
            </View>
            <View style={{ gap: 8 }}>
              <Text style={{ fontSize: 15, fontWeight: '600', color: colors.text }}>Is the machine stopped?</Text>
              <View style={{ flexDirection: 'row', gap: 8 }}>
                <Chip testID="report-stopped-yes" label="Machine stopped" selected={stopped} onPress={() => setStopped(true)} />
                <Chip testID="report-stopped-no" label="Still running" selected={!stopped} onPress={() => setStopped(false)} />
              </View>
            </View>
            <View style={{ gap: 8 }}>
              <Text style={{ fontSize: 15, fontWeight: '600', color: colors.text }}>Priority</Text>
              <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
                {PRIORITIES.map((p) => (
                  <Chip key={p} testID={`report-priority-${p}`} label={PRIORITY_LABEL[p]} selected={shownPriority === p} disabled={stopped && p !== 'critical'} onPress={() => setPriority(p)} />
                ))}
              </View>
              {stopped ? <Text testID="report-priority-note" style={{ fontSize: 14, color: colors.text }}>A stopped machine is always Critical.</Text> : null}
              {errors.priority ? <ErrorText testID="report-priority-error">{errors.priority}</ErrorText> : null}
            </View>
            <Field label="What is wrong?" testID="report-description" value={description} onChangeText={setDescription} multiline maxLength={1000} error={errors.description} />
            <View style={{ gap: 8 }}>
              <Text style={{ fontSize: 15, fontWeight: '600', color: colors.text }}>Photo (optional)</Text>
              {photo ? <Text testID="report-photo-ready" accessibilityLiveRegion="polite" style={{ fontSize: 15, color: colors.text }}>Photo ready ({Math.round(photo.bytes.length / 1024)} KB)</Text> : null}
              <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
                <Button title="Take photo" variant="secondary" testID="report-photo-camera" onPress={() => choosePhoto('camera')} disabled={busy} />
                <Button title="Choose photo" variant="secondary" testID="report-photo-library" onPress={() => choosePhoto('library')} disabled={busy} />
                {photo ? <Button title="Remove photo" variant="secondary" testID="report-photo-remove" onPress={() => setPhoto(null)} disabled={busy} /> : null}
              </View>
              {photoError ? <ErrorText testID="report-photo-error">{photoError}</ErrorText> : null}
            </View>
            {error ? <ErrorText testID="report-error">{error}</ErrorText> : null}
            <Button title={reported ? 'Try again' : 'Report issue'} testID="report-submit" onPress={submit} busy={busy} disabled={busy} />
          </>
        ) : null}
        <Button title="Cancel" variant="secondary" testID="report-cancel" onPress={() => (router.canGoBack() ? router.back() : router.replace('/home'))} disabled={busy} />
      </View>
    </ScrollView>
  );
}
