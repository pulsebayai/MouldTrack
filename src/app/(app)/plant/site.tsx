import { useRef, useState } from 'react';
import { Text, View } from 'react-native';
import { Loading, LoadError, rowStyle } from '@/components/plant/common';
import { usePlant } from '@/components/plant/plant-context';
import { SiteForm } from '@/components/plant/site-form';
import { useLoad } from '@/lib/use-load';
import { Button, ConfirmDialog, ErrorText, Field, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import { MSG, PlantError, RequestIds, fetchHasTargets, fetchLines, plantApi, type Line } from '@/lib/plant';
import { useSession } from '@/lib/session-provider';

/** Site & lines tab: edit the site name / time zone, add, rename and archive lines. */
export default function SiteTab() {
  const { client } = useSession();
  const { site, reload } = usePlant();
  const lines = useLoad(() => fetchLines(client), []);
  const hasTargets = useLoad(() => fetchHasTargets(client), []);
  const [newName, setNewName] = useState('');
  const [editing, setEditing] = useState<{ id: string; name: string } | null>(null);
  const [pending, setPending] = useState<Line | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [fieldError, setFieldError] = useState<string | null>(null);
  const ids = useRef(new RequestIds());

  function show(e: unknown) {
    if (e instanceof PlantError) setError(e.machines?.length ? `${e.message}. Machines: ${e.machines.join(', ')}` : e.message);
    else setError(toUserMessage(e));
  }

  async function saveLine(id: string | null, name: string) {
    const n = name.trim();
    if (n.length < 1 || n.length > 60) {
      setFieldError(MSG.lineName);
      return;
    }
    const key = JSON.stringify(['line', id, n]);
    setBusy(true);
    setError(null);
    setFieldError(null);
    try {
      await plantApi.saveLine(client, id, n, ids.current.get(key));
      ids.current.succeeded(key);
      if (id) setEditing(null);
      else setNewName('');
      lines.reload();
    } catch (e) {
      ids.current.failed(key, e);
      if (e instanceof PlantError && e.field === 'name') setFieldError(e.message);
      else show(e);
    } finally {
      setBusy(false);
    }
  }

  async function archive() {
    if (!pending) return;
    const key = JSON.stringify(['archive', pending.id]);
    setBusy(true);
    setError(null);
    try {
      await plantApi.archiveLine(client, pending.id, ids.current.get(key));
      ids.current.succeeded(key);
      lines.reload();
    } catch (e) {
      ids.current.failed(key, e);
      show(e);
    } finally {
      setBusy(false);
      setPending(null);
    }
  }

  return (
    <View testID="site-tab" style={{ gap: 24 }}>
      <SiteForm site={site} defaultTimezone={site.timezone} onSaved={reload} timezoneLocked={hasTargets.latest === true} />

      <View testID="lines-section" style={{ gap: 12 }}>
        <Text accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>Lines</Text>
        <Text style={{ fontSize: 15, color: colors.text }}>Lines group machines. They are optional.</Text>
        {error ? <ErrorText testID="lines-error">{error}</ErrorText> : null}
        <Field label="New line name" testID="line-new-name" value={newName} onChangeText={setNewName} error={editing ? null : fieldError} autoComplete="off" />
        <Button title="Add line" testID="line-add" onPress={() => saveLine(null, newName)} disabled={busy} busy={busy && !editing && !pending} />

        {lines.state === 'loading' ? <Loading testID="lines-loading" label="Loading lines" /> : null}
        {lines.state === 'error' ? <LoadError testID="lines-load-error" onRetry={lines.reload} error={lines.error} /> : null}
        {lines.state === 'ready' && (lines.data ?? []).length === 0 ? (
          <Text testID="lines-empty" style={{ fontSize: 16, color: colors.text }}>No lines yet</Text>
        ) : null}
        {lines.state === 'ready'
          ? (lines.data ?? []).map((l) => (
              <View key={l.id} testID={`line-row-${l.id}`} style={rowStyle}>
                {editing?.id === l.id ? (
                  <>
                    <Field label="Line name" testID={`line-edit-name-${l.id}`} value={editing.name} onChangeText={(v) => setEditing({ id: l.id, name: v })} error={fieldError} autoComplete="off" />
                    <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
                      <Button title="Save" testID={`line-save-${l.id}`} onPress={() => saveLine(l.id, editing.name)} disabled={busy} />
                      <Button title="Cancel" variant="secondary" testID={`line-cancel-${l.id}`} onPress={() => { setEditing(null); setFieldError(null); }} disabled={busy} />
                    </View>
                  </>
                ) : (
                  <>
                    <Text testID={`line-name-${l.id}`} style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>{l.name}</Text>
                    <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
                      <Button title="Rename" variant="secondary" testID={`line-rename-${l.id}`} onPress={() => { setError(null); setFieldError(null); setEditing({ id: l.id, name: l.name }); }} />
                      <Button title="Archive" variant="secondary" testID={`line-archive-${l.id}`} onPress={() => { setError(null); setPending(l); }} />
                    </View>
                  </>
                )}
              </View>
            ))
          : null}
      </View>

      <ConfirmDialog
        visible={!!pending}
        busy={busy}
        title={pending ? `Archive ${pending.name}?` : ''}
        message="You can only archive a line when none of its machines is in use. Move or retire its machines first."
        confirmLabel="Archive"
        onConfirm={archive}
        onCancel={() => setPending(null)}
      />
    </View>
  );
}
