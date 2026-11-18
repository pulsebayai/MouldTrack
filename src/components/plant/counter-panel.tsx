import { useRef, useState } from 'react';
import { Text, View } from 'react-native';
import { Button, Chip, ErrorText, Field, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import {
  PlantError, RequestIds, fetchActiveProducts, fetchPlantToday, fetchProductsByIds, formatPlantDate, isValidDate,
} from '@/lib/plant';
import {
  UNIT_LABEL, fetchCavityVersions, fetchMachineCounter, readingApi, validateCavities, validateMax, formatCount, type CounterUnit,
} from '@/lib/readings';
import { useSession } from '@/lib/session-provider';
import { useLoad } from '@/lib/use-load';
import { Loading, LoadError } from './common';

/**
 * Counter settings of one machine (D3): what its counter counts (pieces or shots/cycles), the value it rolls over at, and for shot counters the
 * cavities per product (effective-dated, append-only). The server enforces who may change what; this panel only collects the values.
 */
export function CounterPanel({ machineId, retired }: { machineId: string; retired: boolean }) {
  const { client } = useSession();
  const data = useLoad(
    async () => {
      const [counter, today, active, versions] = await Promise.all([
        fetchMachineCounter(client, machineId), fetchPlantToday(client), retired ? Promise.resolve([]) : fetchActiveProducts(client), fetchCavityVersions(client, machineId),
      ]);
      const products = await fetchProductsByIds(client, versions.map((v) => v.product_id));
      return { counter, today, active, versions, products: new Map([...products, ...active].map((p) => [p.id, p])) };
    },
    [machineId, retired],
  );
  const d = data.data;
  const [unit, setUnit] = useState<CounterUnit | null>(null);
  const [max, setMax] = useState<string | null>(null);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const [busy, setBusy] = useState(false);
  const ids = useRef(new RequestIds());

  const shownUnit = unit ?? d?.counter?.counter_unit ?? 'pieces';
  const shownMax = max ?? (d?.counter?.counter_max == null ? '' : String(d.counter.counter_max));

  async function saveCounter() {
    const e = validateMax(shownMax);
    setErrors(e ? { counter_max: e } : {});
    setError(null);
    setSaved(false);
    if (e) return;
    const key = JSON.stringify(['counter', machineId, shownUnit, shownMax.trim()]);
    setBusy(true);
    try {
      await readingApi.setCounter(client, machineId, shownUnit, shownMax, ids.current.get(key));
      ids.current.succeeded(key);
      setSaved(true);
      setUnit(null);
      setMax(null);
      data.reload();
    } catch (err) {
      ids.current.failed(key, err);
      if (err instanceof PlantError && (err.field === 'counter_max' || err.field === 'counter_unit')) setErrors({ [err.field]: err.message });
      else setError(err instanceof PlantError ? err.message : toUserMessage(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <View testID="counter-panel" style={{ gap: 12 }}>
      <Text accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>Counter</Text>
      {data.state === 'loading' && !d ? <Loading testID="counter-loading" label="Loading counter settings" /> : null}
      {data.state === 'error' ? <LoadError testID="counter-error" onRetry={data.reload} error={data.error} /> : null}
      {d ? (
        <>
          <Text style={{ fontSize: 15, color: colors.text }}>What does the counter on the machine count?</Text>
          <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
            {(['pieces', 'shots'] as const).map((u) => (
              <Chip key={u} testID={`counter-unit-${u}`} label={UNIT_LABEL[u]} selected={shownUnit === u} disabled={retired} onPress={() => setUnit(u)} />
            ))}
          </View>
          {errors.counter_unit ? <ErrorText testID="counter-unit-error">{errors.counter_unit}</ErrorText> : null}
          <Field label="Counter rolls over after (optional)" testID="counter-max" value={shownMax} onChangeText={setMax} keyboardType="number-pad" inputMode="numeric" editable={!retired} error={errors.counter_max} />
          {error ? <ErrorText testID="counter-save-error">{error}</ErrorText> : null}
          {saved ? <Text testID="counter-saved" accessibilityLiveRegion="polite" style={{ fontSize: 15, color: colors.text }}>Saved</Text> : null}
          {!retired ? <Button title="Save counter settings" testID="counter-save" onPress={saveCounter} busy={busy} disabled={busy} /> : null}
          {(d.counter?.counter_unit ?? 'pieces') === 'shots' ? <CavitiesSection machineId={machineId} data={d} retired={retired} onDone={data.reload} /> : null}
        </>
      ) : null}
    </View>
  );
}

type PanelData = { today: string | null; active: { id: string; code: string; description: string }[]; versions: { id: string; product_id: string; effective_from: string; cavities: number | null }[]; products: Map<string, { code: string; description: string }> };

function CavitiesSection({ machineId, data, retired, onDone }: { machineId: string; data: PanelData; retired: boolean; onDone: () => void }) {
  const { client } = useSession();
  const [productId, setProductId] = useState<string | null>(null);
  const [cavities, setCavities] = useState('');
  const [from, setFrom] = useState<string | null>(null);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const ids = useRef(new RequestIds());
  const date = (from ?? data.today ?? '').trim();

  async function run(mode: 'set' | 'end') {
    const e: Record<string, string> = {};
    if (!productId) e.product_id = 'Choose the product';
    if (mode === 'set') {
      const c = validateCavities(cavities);
      if (c) e.cavities = c;
    }
    if (!isValidDate(date)) e.effective_from = 'Enter a date as YYYY-MM-DD';
    setErrors(e);
    setError(null);
    if (Object.keys(e).length) return;
    const key = JSON.stringify([mode, machineId, productId, cavities.trim(), date]);
    setBusy(true);
    try {
      if (mode === 'set') await readingApi.setCavities(client, machineId, productId!, cavities, date, ids.current.get(key));
      else await readingApi.endCavities(client, machineId, productId!, date, ids.current.get(key));
      ids.current.succeeded(key);
      setCavities('');
      onDone();
    } catch (err) {
      ids.current.failed(key, err);
      if (err instanceof PlantError && err.field && ['cavities', 'effective_from', 'product_id'].includes(err.field)) setErrors({ [err.field]: err.message });
      else setError(err instanceof PlantError ? err.message : toUserMessage(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <View testID="cavities-section" style={{ gap: 12 }}>
      <Text accessibilityRole="header" style={{ fontSize: 18, fontWeight: '700', color: colors.text }}>Cavities per product</Text>
      <Text style={{ fontSize: 14, color: colors.text }}>Pieces = shots x cavities. A product with no setting counts 1 cavity.</Text>
      {data.versions.length === 0 ? <Text testID="cavities-empty" style={{ fontSize: 15, color: colors.text }}>No cavities set</Text> : null}
      {data.versions.map((v) => (
        <Text key={v.id} testID={`cavity-version-${v.id}`} style={{ fontSize: 15, color: colors.text }}>
          {data.products.get(v.product_id)?.code ?? 'Unknown product'} · {v.cavities === null ? 'Ended' : `${formatCount(v.cavities)} cavities`} · from {formatPlantDate(v.effective_from)}
        </Text>
      ))}
      {!retired ? (
        <>
          <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
            {data.active.map((p) => (
              <Chip key={p.id} testID={`cavity-product-${p.id}`} label={`${p.code} · ${p.description}`} selected={productId === p.id} onPress={() => setProductId(p.id)} />
            ))}
          </View>
          {errors.product_id ? <ErrorText testID="cavity-product-error">{errors.product_id}</ErrorText> : null}
          <Field label="Cavities" testID="cavity-count" value={cavities} onChangeText={setCavities} keyboardType="number-pad" inputMode="numeric" error={errors.cavities} />
          <Field label="From (plant date, YYYY-MM-DD)" testID="cavity-from" value={from ?? data.today ?? ''} onChangeText={setFrom} error={errors.effective_from} />
          {error ? <ErrorText testID="cavity-error">{error}</ErrorText> : null}
          <View style={{ flexDirection: 'row', gap: 12, flexWrap: 'wrap' }}>
            <Button title="Set cavities" testID="cavity-set" onPress={() => run('set')} busy={busy} disabled={busy} />
            <Button title="End setting" variant="secondary" testID="cavity-end" onPress={() => run('end')} disabled={busy} />
          </View>
        </>
      ) : null}
    </View>
  );
}
