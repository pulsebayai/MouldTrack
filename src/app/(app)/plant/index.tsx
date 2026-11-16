import { router } from 'expo-router';
import { useState } from 'react';
import { Text, View } from 'react-native';
import { Label, Loading, LoadError, Pager, rowStyle } from '@/components/plant/common';
import { useLoad } from '@/components/plant/use-load';
import { Button, Chip, Field, StatusLabel, colors } from '@/components/ui';
import { fetchLines, fetchMachines, machineStatusLabel, type MachineStatusFilter } from '@/lib/plant';
import { useSession } from '@/lib/session-provider';

const STATUS_FILTERS: { key: MachineStatusFilter; label: string }[] = [
  { key: 'all', label: 'All' },
  { key: 'active', label: 'Active' },
  { key: 'under_maintenance', label: 'Under maintenance' },
];

/** Machines tab (the Plant layout guarantees a Unit Admin and a site). */
export default function MachinesTab() {
  const { client } = useSession();
  const [search, setSearch] = useState('');
  const [status, setStatus] = useState<MachineStatusFilter>('all');
  const [line, setLine] = useState<string>('all');
  const [showRetired, setShowRetired] = useState(false);
  const [page, setPage] = useState(0);

  const lines = useLoad(() => fetchLines(client, { includeArchived: true }), []);
  const list = useLoad(() => fetchMachines(client, { search, status, line, showRetired, page }), [search, status, line, showRetired, page]);
  const lineName = new Map((lines.data ?? []).map((l) => [l.id, l.name]));
  const activeLines = (lines.data ?? []).filter((l) => !l.archived_at);
  const rows = list.data?.rows ?? [];
  const total = list.data?.total ?? 0;
  const filtered = search.trim() !== '' || status !== 'all' || line !== 'all';
  const reset = () => setPage(0);

  return (
    <View testID="machines-tab" style={{ gap: 16 }}>
      <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 12 }}>
        <Text accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>
          Machines
        </Text>
        <Button title="Add machine" testID="machines-add" onPress={() => router.push('/plant/machines/new')} />
      </View>

      <Field
        label="Search machines"
        testID="machines-search"
        value={search}
        onChangeText={(v) => {
          setSearch(v);
          reset();
        }}
        placeholder="Code or name"
        autoCapitalize="none"
      />
      <View style={{ gap: 8 }}>
        <Label>Status</Label>
        <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
          {STATUS_FILTERS.map((f) => (
            <Chip key={f.key} testID={`machines-filter-status-${f.key}`} label={f.label} selected={status === f.key} onPress={() => { setStatus(f.key); reset(); }} />
          ))}
          <Chip testID="machines-show-retired" label="Show retired" selected={showRetired} onPress={() => { setShowRetired((s) => !s); reset(); }} />
        </View>
        {activeLines.length > 0 ? (
          <>
            <Label>Line</Label>
            <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
              <Chip testID="machines-filter-line-all" label="All lines" selected={line === 'all'} onPress={() => { setLine('all'); reset(); }} />
              <Chip testID="machines-filter-line-none" label="No line" selected={line === 'none'} onPress={() => { setLine('none'); reset(); }} />
              {activeLines.map((l) => (
                <Chip key={l.id} testID={`machines-filter-line-${l.id}`} label={l.name} selected={line === l.id} onPress={() => { setLine(l.id); reset(); }} />
              ))}
            </View>
          </>
        ) : null}
      </View>

      {list.state === 'loading' ? <Loading testID="machines-loading" label="Loading machines" /> : null}
      {list.state === 'error' ? <LoadError testID="machines-error" onRetry={list.reload} /> : null}
      {list.state === 'ready' && rows.length === 0 ? (
        filtered ? (
          <Text testID="machines-no-match" style={{ fontSize: 16, color: colors.text }}>No machines match</Text>
        ) : (
          <Text testID="machines-empty" style={{ fontSize: 16, color: colors.text }}>No machines yet — add your first machine</Text>
        )
      ) : null}
      {list.state === 'ready'
        ? rows.map((m) => (
            <View key={m.id} testID={`machine-row-${m.id}`} style={rowStyle}>
              <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 16, alignItems: 'center' }}>
                <Text testID={`machine-code-${m.id}`} style={{ fontSize: 17, fontWeight: '700', color: colors.text, minWidth: 90 }}>{m.code}</Text>
                <Text testID={`machine-name-${m.id}`} style={{ fontSize: 16, color: colors.text, minWidth: 140 }}>{m.name}</Text>
                <Text testID={`machine-line-${m.id}`} style={{ fontSize: 15, color: colors.text }}>
                  {m.line_id ? `Line: ${lineName.get(m.line_id) ?? '—'}` : 'No line'}
                </Text>
                <StatusLabel testID={`machine-status-${m.id}`} status={machineStatusLabel(m)} />
              </View>
              <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
                <Button title="Open" variant="secondary" testID={`machine-open-${m.id}`} onPress={() => router.push(`/plant/machines/${m.id}`)} />
              </View>
            </View>
          ))
        : null}
      {list.state === 'ready' ? <Pager prefix="machines" page={page} total={total} onPage={setPage} /> : null}
    </View>
  );
}
