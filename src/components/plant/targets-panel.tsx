import { useState } from 'react';
import { Text, View } from 'react-native';
import { Button, Chip, colors } from '@/components/ui';
import {
  fetchActiveProducts, fetchPlantToday, fetchProductsByIds, fetchRecorderNames, fetchTargetVersions, formatPieces, formatPlantDate, summariseTargets, type PairSummary, type Product,
} from '@/lib/plant';
import { useSession } from '@/lib/session-provider';
import { Label, Loading, LoadError, rowStyle } from './common';
import { TargetForm } from './target-form';
import { useLoad } from './use-load';

/** Targets of one machine: per product the current and next target and the full history (AC-9). */
export function TargetsPanel({ machineId, machineCode, retired }: { machineId: string; machineCode: string; retired: boolean }) {
  const { client } = useSession();
  const [form, setForm] = useState<{ mode: 'set' | 'end'; productId: string } | null>(null);
  const [picking, setPicking] = useState(false);

  const data = useLoad(
    async () => {
      const [versions, today, active] = await Promise.all([
        fetchTargetVersions(client, machineId),
        fetchPlantToday(client),
        retired ? Promise.resolve([] as Product[]) : fetchActiveProducts(client),
      ]);
      const [products, names] = await Promise.all([
        fetchProductsByIds(client, versions.map((v) => v.product_id)),
        fetchRecorderNames(client, versions.map((v) => v.recorded_by)),
      ]);
      return { versions, today, active, products: new Map([...products, ...active].map((p) => [p.id, p])), names };
    },
    [machineId, retired],
  );

  const label = (p?: Product) => (p ? `${p.code} · ${p.description}` : 'Unknown product');
  const done = () => {
    setForm(null);
    setPicking(false);
    data.reload();
  };

  return (
    <View testID="targets-panel" style={{ gap: 12 }}>
      <Text accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>
        Targets (pieces per shift)
      </Text>
      {data.state === 'loading' ? <Loading testID="targets-loading" label="Loading targets" /> : null}
      {data.state === 'error' ? <LoadError testID="targets-error" onRetry={data.reload} error={data.error} /> : null}
      {data.state === 'ready' && data.data ? (
        <>
          {data.data.versions.length === 0 ? (
            <Text testID="targets-empty" style={{ fontSize: 16, color: colors.text }}>No target set</Text>
          ) : null}
          {data.data.today
            ? summariseTargets(data.data.versions, data.data.today).map((s) => (
                <PairRow
                  key={s.productId}
                  s={s}
                  product={data.data!.products.get(s.productId)}
                  names={data.data!.names}
                  retired={retired}
                  onAction={(mode) => {
                    setPicking(false);
                    setForm({ mode, productId: s.productId });
                  }}
                />
              ))
            : null}

          {!retired ? (
            <View style={{ gap: 8 }}>
              <Button title="Add product target" variant="secondary" testID="target-add" onPress={() => { setForm(null); setPicking((p) => !p); }} />
              {picking ? (
                <View style={{ gap: 8 }}>
                  <Label>Choose a product</Label>
                  {data.data.active.length === 0 ? (
                    <Text testID="target-pick-empty" style={{ fontSize: 15, color: colors.text }}>No active products — add a product first</Text>
                  ) : null}
                  <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
                    {data.data.active.map((p) => (
                      <Chip key={p.id} testID={`target-pick-${p.id}`} label={label(p)} selected={false} onPress={() => { setPicking(false); setForm({ mode: 'set', productId: p.id }); }} />
                    ))}
                  </View>
                </View>
              ) : null}
            </View>
          ) : null}

          {form ? (
            <TargetForm
              key={`${form.mode}:${form.productId}`}
              mode={form.mode}
              machineId={machineId}
              productId={form.productId}
              productLabel={`${machineCode} · ${label(data.data.products.get(form.productId))}`}
              today={data.data.today}
              onDone={done}
              onCancel={() => setForm(null)}
            />
          ) : null}
        </>
      ) : null}
    </View>
  );
}

function PairRow({ s, product, names, retired, onAction }: { s: PairSummary; product?: Product; names: Record<string, string>; retired: boolean; onAction: (m: 'set' | 'end') => void }) {
  const unit = `${product?.uom ?? 'pcs'}/shift`;
  const canEnd = s.current !== null || (s.next !== null && s.next.pieces !== null);
  return (
    <View testID={`target-row-${s.productId}`} style={rowStyle}>
      <Text style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>{product ? `${product.code} · ${product.description}` : 'Unknown product'}</Text>
      <Text testID={`target-current-${s.productId}`} style={{ fontSize: 16, color: colors.text }}>
        {s.current ? `Current: ${formatPieces(s.current.pieces)} ${unit} · from ${formatPlantDate(s.current.from)}` : 'No current target'}
      </Text>
      {s.next ? (
        <Text testID={`target-next-${s.productId}`} style={{ fontSize: 16, color: colors.text }}>
          {s.next.pieces === null ? `Next: ends ${formatPlantDate(s.next.from)}` : `Next: ${formatPieces(s.next.pieces)} ${unit} from ${formatPlantDate(s.next.from)}`}
        </Text>
      ) : null}
      <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
        {!retired ? <Button title="Set target" variant="secondary" testID={`target-set-${s.productId}`} onPress={() => onAction('set')} /> : null}
        {canEnd ? <Button title="End target" variant="secondary" testID={`target-end-${s.productId}`} onPress={() => onAction('end')} /> : null}
      </View>
      <Label>History</Label>
      {s.history.map((v) => (
        <Text key={v.id} testID={`target-history-${v.id}`} style={{ fontSize: 15, color: colors.text }}>
          {formatPlantDate(v.effective_from)} · {v.pieces_per_shift === null ? 'Ended' : `${formatPieces(v.pieces_per_shift)} ${unit}`} · by {names[v.recorded_by] ?? 'Unknown'}
        </Text>
      ))}
    </View>
  );
}
