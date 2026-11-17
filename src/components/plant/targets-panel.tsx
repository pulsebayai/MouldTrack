import { useState } from 'react';
import { Text, View } from 'react-native';
import { Button, Chip, colors } from '@/components/ui';
import {
  fetchActiveProducts, fetchOverrideVersions, fetchPlantToday, fetchShifts, fetchProductsByIds, fetchRecorderNames, fetchTargetVersions, formatPieces, formatPlantDate, summariseOverrides, summariseTargets, type OverrideSummary, type PairSummary, type Product, type Shift,
} from '@/lib/plant';
import { useSession } from '@/lib/session-provider';
import { Label, Loading, LoadError, rowStyle } from './common';
import { TargetForm } from './target-form';
import { useLoad } from '@/lib/use-load';

/** Targets of one machine: per product the current and next target and the full history (AC-9). */
export function TargetsPanel({ machineId, machineCode, retired }: { machineId: string; machineCode: string; retired: boolean }) {
  const { client } = useSession();
  const [form, setForm] = useState<{ mode: 'set' | 'end'; productId: string; shift?: { id: string; name: string } } | null>(null);
  const [pickingShift, setPickingShift] = useState<{ shiftId: string | null } | null>(null);
  const [picking, setPicking] = useState(false);

  const data = useLoad(
    async () => {
      const [versions, today, active, overrides, shifts] = await Promise.all([
        fetchTargetVersions(client, machineId),
        fetchPlantToday(client),
        retired ? Promise.resolve([] as Product[]) : fetchActiveProducts(client),
        fetchOverrideVersions(client, machineId),
        fetchShifts(client, { includeRetired: true }),
      ]);
      const [products, names] = await Promise.all([
        fetchProductsByIds(client, [...versions, ...overrides].map((v) => v.product_id)),
        fetchRecorderNames(client, [...versions, ...overrides].map((v) => v.recorded_by)),
      ]);
      return { versions, overrides, shifts, today, active, products: new Map([...products, ...active].map((p) => [p.id, p])), names };
    },
    [machineId, retired],
  );

  const label = (p?: Product) => (p ? `${p.code} · ${p.description}` : 'Unknown product');
  const done = () => {
    setForm(null);
    setPicking(false);
    setPickingShift(null);
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

          {data.data.today && data.data.overrides.length > 0 ? (
            <View testID="overrides" style={{ gap: 12 }}>
              <Text accessibilityRole="header" style={{ fontSize: 18, fontWeight: '700', color: colors.text }}>Shift targets (override the machine target)</Text>
              {summariseOverrides(data.data.overrides, data.data.today).map((o) => (
                <OverrideRow
                  key={`${o.productId}:${o.shiftId}`}
                  o={o}
                  shift={data.data!.shifts.find((x) => x.id === o.shiftId)}
                  product={data.data!.products.get(o.productId)}
                  names={data.data!.names}
                  retired={retired}
                  onAction={(mode, shift) => {
                    setPicking(false);
                    setPickingShift(null);
                    setForm({ mode, productId: o.productId, shift });
                  }}
                />
              ))}
            </View>
          ) : null}

          {!retired && data.data.shifts.some((x) => !x.retired_at) ? (
            <View style={{ gap: 8 }}>
              <Button title="Add shift target" variant="secondary" testID="override-add" onPress={() => { setForm(null); setPicking(false); setPickingShift(pickingShift ? null : { shiftId: null }); }} />
              {pickingShift ? (
                <View style={{ gap: 8 }}>
                  <Label>Choose a shift</Label>
                  <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
                    {data.data.shifts.filter((x) => !x.retired_at).map((x) => (
                      <Chip key={x.id} testID={`override-shift-${x.id}`} label={x.name} selected={pickingShift.shiftId === x.id} onPress={() => setPickingShift({ shiftId: x.id })} />
                    ))}
                  </View>
                  {pickingShift.shiftId ? (
                    <>
                      <Label>Choose a product</Label>
                      <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
                        {data.data.active.map((p) => (
                          <Chip
                            key={p.id}
                            testID={`override-pick-${p.id}`}
                            label={label(p)}
                            selected={false}
                            onPress={() => {
                              const sh = data.data!.shifts.find((x) => x.id === pickingShift.shiftId)!;
                              setPickingShift(null);
                              setForm({ mode: 'set', productId: p.id, shift: { id: sh.id, name: sh.name } });
                            }}
                          />
                        ))}
                      </View>
                    </>
                  ) : null}
                </View>
              ) : null}
            </View>
          ) : null}

          {form ? (
            <TargetForm
              key={`${form.mode}:${form.productId}:${form.shift?.id ?? ''}`}
              mode={form.mode}
              machineId={machineId}
              productId={form.productId}
              productLabel={`${machineCode} · ${label(data.data.products.get(form.productId))}`}
              today={data.data.today}
              versions={(form.shift ? data.data.overrides.filter((v) => v.shift_id === form.shift!.id) : data.data.versions).filter((v) => v.product_id === form.productId)}
              shift={form.shift}
              unit={`${data.data.products.get(form.productId)?.uom ?? 'pcs'}/shift`}
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

function OverrideRow({ o, shift, product, names, retired, onAction }: { o: OverrideSummary; shift?: Shift; product?: Product; names: Record<string, string>; retired: boolean; onAction: (m: 'set' | 'end', shift: { id: string; name: string }) => void }) {
  const unit = `${product?.uom ?? 'pcs'}/shift`;
  const id = `${o.productId}-${o.shiftId}`;
  const shiftRef = { id: o.shiftId, name: shift?.name ?? 'Unknown shift' };
  const canEnd = o.current !== null || (o.next !== null && o.next.pieces !== null);
  return (
    <View testID={`override-row-${id}`} style={rowStyle}>
      <Text style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>
        {shiftRef.name}{shift?.retired_at ? ' (retired)' : ''} · {product ? `${product.code} · ${product.description}` : 'Unknown product'}
      </Text>
      <Text testID={`override-current-${id}`} style={{ fontSize: 16, color: colors.text }}>
        {o.current ? `Current: ${formatPieces(o.current.pieces)} ${unit} · from ${formatPlantDate(o.current.from)}` : 'No shift target (machine target applies)'}
      </Text>
      {o.next ? (
        <Text testID={`override-next-${id}`} style={{ fontSize: 16, color: colors.text }}>
          {o.next.pieces === null ? `Next: ends ${formatPlantDate(o.next.from)}` : `Next: ${formatPieces(o.next.pieces)} ${unit} from ${formatPlantDate(o.next.from)}`}
        </Text>
      ) : null}
      <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
        {!retired ? <Button title="Set target" variant="secondary" testID={`override-set-${id}`} onPress={() => onAction('set', shiftRef)} /> : null}
        {canEnd && !retired ? <Button title="End shift target" variant="secondary" testID={`override-end-${id}`} onPress={() => onAction('end', shiftRef)} /> : null}
      </View>
      <Label>History</Label>
      {o.history.map((v) => (
        <Text key={v.id} testID={`override-history-${v.id}`} style={{ fontSize: 15, color: colors.text }}>
          {formatPlantDate(v.effective_from)} · {v.pieces_per_shift === null ? 'Ended' : `${formatPieces(v.pieces_per_shift)} ${unit}`} · by {names[v.recorded_by] ?? 'Unknown'}
        </Text>
      ))}
    </View>
  );
}
