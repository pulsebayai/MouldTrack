import { useRef, useState } from 'react';
import { Text, View } from 'react-native';
import { Loading, LoadError, Pager, rowStyle } from '@/components/plant/common';
import { ProductForm } from '@/components/plant/product-form';
import { useLoad } from '@/components/plant/use-load';
import { Button, Chip, ConfirmDialog, ErrorText, Field, StatusLabel, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import { PlantError, RequestIds, fetchProducts, plantApi, productStatusLabel, type Product } from '@/lib/plant';
import { useSession } from '@/lib/session-provider';

/** Products tab: list with search, add/edit inline, retire (blocked while a current or future target exists) and reinstate. */
export default function ProductsTab() {
  const { client } = useSession();
  const [search, setSearch] = useState('');
  const [showRetired, setShowRetired] = useState(false);
  const [page, setPage] = useState(0);
  const [editing, setEditing] = useState<'new' | Product | null>(null);
  const [pending, setPending] = useState<Product | null>(null);
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const ids = useRef(new RequestIds());

  const list = useLoad(() => fetchProducts(client, { search, showRetired, page }), [search, showRetired, page]);
  const rows = list.data?.rows ?? [];
  const filtered = search.trim() !== '';

  async function confirm() {
    if (!pending) return;
    const retire = !pending.retired_at;
    const key = JSON.stringify(['retire', pending.id, retire]);
    setBusy(true);
    setActionError(null);
    try {
      await plantApi.setProductRetired(client, pending.id, retire, ids.current.get(key));
      ids.current.succeeded(key);
      list.reload();
    } catch (e) {
      ids.current.failed(key, e);
      if (e instanceof PlantError) setActionError(e.machines?.length ? `${e.message}. Used on: ${e.machines.join(', ')}` : e.message);
      else setActionError(toUserMessage(e));
    } finally {
      setBusy(false);
      setPending(null);
    }
  }

  return (
    <View testID="products-tab" style={{ gap: 16 }}>
      <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 12 }}>
        <Text accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>Products</Text>
        <Button title="Add product" testID="products-add" onPress={() => setEditing('new')} />
      </View>
      {editing ? (
        <ProductForm
          key={editing === 'new' ? 'new' : editing.id}
          product={editing === 'new' ? null : editing}
          onCancel={() => setEditing(null)}
          onSaved={() => {
            setEditing(null);
            list.reload();
          }}
        />
      ) : null}
      {actionError ? <ErrorText testID="products-action-error">{actionError}</ErrorText> : null}
      <Field
        label="Search products"
        testID="products-search"
        value={search}
        onChangeText={(v) => {
          setSearch(v);
          setPage(0);
        }}
        placeholder="Code or description"
        autoCapitalize="none"
      />
      <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
        <Chip testID="products-show-retired" label="Show retired" selected={showRetired} onPress={() => { setShowRetired((s) => !s); setPage(0); }} />
      </View>

      {list.state === 'loading' ? <Loading testID="products-loading" label="Loading products" /> : null}
      {list.state === 'error' ? <LoadError testID="products-error" onRetry={list.reload} error={list.error} /> : null}
      {list.state === 'ready' && rows.length === 0 ? (
        filtered ? (
          <Text testID="products-no-match" style={{ fontSize: 16, color: colors.text }}>No products match</Text>
        ) : (
          <Text testID="products-empty" style={{ fontSize: 16, color: colors.text }}>No products yet — add your first product</Text>
        )
      ) : null}
      {list.state === 'ready'
        ? rows.map((p) => (
            <View key={p.id} testID={`product-row-${p.id}`} style={rowStyle}>
              <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 16, alignItems: 'center' }}>
                <Text testID={`product-code-${p.id}`} style={{ fontSize: 17, fontWeight: '700', color: colors.text, minWidth: 90 }}>{p.code}</Text>
                <Text testID={`product-description-${p.id}`} style={{ fontSize: 16, color: colors.text, minWidth: 160 }}>{p.description}</Text>
                <Text testID={`product-uom-${p.id}`} style={{ fontSize: 15, color: colors.text }}>{p.uom}</Text>
                <StatusLabel testID={`product-status-${p.id}`} status={productStatusLabel(p)} />
              </View>
              <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
                {p.retired_at ? null : <Button title="Edit" variant="secondary" testID={`product-edit-${p.id}`} onPress={() => { setActionError(null); setEditing(p); }} />}
                <Button
                  title={p.retired_at ? 'Reinstate' : 'Retire'}
                  variant="secondary"
                  testID={`product-toggle-${p.id}`}
                  onPress={() => { setActionError(null); setPending(p); }}
                />
              </View>
            </View>
          ))
        : null}
      {list.state === 'ready' ? <Pager prefix="products" page={page} total={list.data?.total ?? 0} onPage={setPage} /> : null}

      <ConfirmDialog
        visible={!!pending}
        busy={busy}
        title={pending ? `${pending.retired_at ? 'Reinstate' : 'Retire'} ${pending.code} · ${pending.description}?` : ''}
        message={pending?.retired_at ? 'It will appear in pickers again.' : 'It is hidden from pickers. History is kept. A product with a current or future target cannot be retired.'}
        confirmLabel={pending?.retired_at ? 'Reinstate' : 'Retire'}
        onConfirm={confirm}
        onCancel={() => setPending(null)}
      />
    </View>
  );
}
