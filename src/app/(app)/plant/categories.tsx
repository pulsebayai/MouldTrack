import { useRef, useState } from 'react';
import { Text, View } from 'react-native';
import { Loading, LoadError, rowStyle } from '@/components/plant/common';
import { Button, ErrorText, Field, StatusLabel, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import { fetchCategories, issueApi } from '@/lib/issues';
import { PlantError, RequestIds } from '@/lib/plant';
import { useSession } from '@/lib/session-provider';
import { useLoad } from '@/lib/use-load';

/** Plant > Issue categories: add, rename, retire and reinstate. Retired categories stay on old issues and leave the report form. */
export default function CategoriesTab() {
  const { client } = useSession();
  const cats = useLoad(() => fetchCategories(client, { includeRetired: true }), []);
  const [newName, setNewName] = useState('');
  const [editing, setEditing] = useState<{ id: string; name: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [fieldError, setFieldError] = useState<string | null>(null);
  const ids = useRef(new RequestIds());

  async function run(key: string, fn: (rid: string) => Promise<unknown>, done: () => void) {
    setBusy(true); setError(null); setFieldError(null);
    try {
      await fn(ids.current.get(key));
      ids.current.succeeded(key);
      done();
      cats.reload();
    } catch (e) {
      ids.current.failed(key, e);
      if (e instanceof PlantError && e.field === 'name') setFieldError(e.message);
      else setError(e instanceof PlantError ? e.message : toUserMessage(e));
    } finally {
      setBusy(false);
    }
  }
  function save(id: string | null, name: string) {
    const n = name.trim();
    if (n.length < 1 || n.length > 60) { setFieldError('Enter a name of 1 to 60 characters'); return; }
    return run(JSON.stringify(['cat', id, n]), (r) => issueApi.saveCategory(client, id, n, r), () => { if (id) setEditing(null); else setNewName(''); });
  }

  return (
    <View testID="categories-tab" style={{ gap: 16 }}>
      <Field label="New category" testID="category-new-name" value={newName} onChangeText={setNewName} maxLength={60} error={editing ? null : fieldError} />
      <Button title="Add category" testID="category-add" onPress={() => save(null, newName)} busy={busy && !editing} disabled={busy} />
      {error ? <ErrorText testID="categories-error">{error}</ErrorText> : null}
      {cats.state === 'loading' && !cats.latest ? <Loading testID="categories-loading" label="Loading categories" /> : null}
      {cats.state === 'error' ? <LoadError testID="categories-load-error" onRetry={cats.reload} error={cats.error} /> : null}
      {(cats.data ?? cats.latest ?? []).map((c) => (
        <View key={c.id} testID={`category-${c.id}`} style={rowStyle}>
          {editing?.id === c.id ? (
            <>
              <Field label="Name" testID="category-edit-name" value={editing.name} onChangeText={(v) => setEditing({ id: c.id, name: v })} maxLength={60} error={fieldError} />
              <Button title="Save" testID="category-save" onPress={() => save(c.id, editing.name)} disabled={busy} />
              <Button title="Cancel" variant="secondary" testID="category-cancel" onPress={() => setEditing(null)} disabled={busy} />
            </>
          ) : (
            <>
              <Text style={{ fontSize: 17, fontWeight: '600', color: colors.text }}>{c.name}</Text>
              <StatusLabel testID={`category-${c.id}-status`} status={c.retired_at ? 'Retired' : 'Active'} />
              <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
                <Button title="Rename" variant="secondary" testID={`category-${c.id}-rename`} onPress={() => { setFieldError(null); setEditing({ id: c.id, name: c.name }); }} disabled={busy} />
                <Button
                  title={c.retired_at ? 'Reinstate' : 'Retire'}
                  variant="secondary"
                  testID={`category-${c.id}-toggle`}
                  onPress={() => run(JSON.stringify(['catret', c.id, !c.retired_at]), (r) => issueApi.setCategoryRetired(client, c.id, !c.retired_at, r), () => {})}
                  disabled={busy}
                />
              </View>
            </>
          )}
        </View>
      ))}
    </View>
  );
}
