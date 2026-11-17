import { router } from 'expo-router';
import { useState } from 'react';
import { ScrollView, Text, View } from 'react-native';
import { IssueAlertsCard } from '@/components/issue-alerts-card';
import { IssueRowView } from '@/components/issues/issue-row';
import { Loading, LoadError, Pager } from '@/components/plant/common';
import { Button, Chip, colors } from '@/components/ui';
import { PRIORITIES, PRIORITY_LABEL, fetchCategories, fetchIssueList, type IssueFilters, type Priority } from '@/lib/issues';
import { fetchMachines } from '@/lib/plant';
import { useSession } from '@/lib/session-provider';
import { useLoad } from '@/lib/use-load';
import { useRefreshOnFocus } from '@/lib/use-refresh';

type Tab = 'open' | 'closed' | 'escalated' | 'stopped' | 'needs_owner';
const TABS: { key: Tab; label: string; filters: IssueFilters; ua?: boolean }[] = [
  { key: 'open', label: 'Open', filters: { status: 'not_closed' } },
  { key: 'closed', label: 'Closed', filters: { status: 'closed' } },
  { key: 'escalated', label: 'Escalated', filters: { status: 'not_closed', escalated: true } },
  { key: 'stopped', label: 'Machine stopped', filters: { status: 'not_closed', stopped: true } },
  { key: 'needs_owner', label: 'Needs owner', filters: { status: 'not_closed', needs_owner: true }, ua: true },
];

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <View style={{ gap: 6 }}>
      <Text style={{ fontSize: 15, fontWeight: '600', color: colors.text }}>{label}</Text>
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>{children}</View>
    </View>
  );
}

/**
 * Supervisors see the issues the server lets them see (My issues); a Unit Admin sees the whole tenant, with the alerts above the list and
 * priority / category / machine filters (R4, R5). Every filter is sent to the server.
 */
export function IssueList({ role }: { role: 'supervisor' | 'unit_admin' }) {
  const { client } = useSession();
  const ua = role === 'unit_admin';
  const [tab, setTab] = useState<Tab>('open');
  const [page, setPage] = useState(1);
  const [priority, setPriority] = useState<Priority | null>(null);
  const [categoryId, setCategoryId] = useState<string | null>(null);
  const [machineId, setMachineId] = useState<string | null>(null);
  const tabs = TABS.filter((t) => !t.ua || ua);
  const filters: IssueFilters = {
    ...TABS.find((t) => t.key === tab)!.filters,
    ...(ua && priority ? { priority } : {}),
    ...(ua && categoryId ? { category_id: categoryId } : {}),
    ...(ua && machineId ? { machine_id: machineId } : {}),
  };
  const list = useLoad(() => fetchIssueList(client, filters, page), [tab, page, priority, categoryId, machineId]);
  useRefreshOnFocus(list.reload);
  const cats = useLoad(() => fetchCategories(client, { includeRetired: true }), [], ua);
  // Only the first page of machines (25, by code): enough for the R1 pilot unit; a search picker comes with larger tenants.
  const machines = useLoad(() => fetchMachines(client, { search: '', status: 'all', line: 'all', showRetired: false, page: 0 }), [], ua);
  const d = list.data ?? list.latest;
  const pick = <T,>(set: (v: T) => void, v: T) => { set(v); setPage(1); };
  return (
    <ScrollView testID="issues-screen" contentContainerStyle={{ alignItems: 'center', padding: 24 }}>
      <View style={{ width: '100%', maxWidth: 720, gap: 16 }}>
        <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 12 }}>
          <Text accessibilityRole="header" style={{ fontSize: 24, fontWeight: '700', color: colors.text }}>{ua ? 'Issues' : 'My issues'}</Text>
          <Button title="Home" variant="secondary" testID="issues-home" onPress={() => router.replace('/home')} />
        </View>
        {ua ? <IssueAlertsCard showAll={false} /> : null}
        {ua ? <Button title="Report issue" testID="issues-new" onPress={() => router.push('/issues/new')} /> : null}
        <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
          {tabs.map((t) => (
            <Chip key={t.key} testID={`issues-tab-${t.key}`} label={t.label} selected={tab === t.key} onPress={() => pick(setTab, t.key)} />
          ))}
        </View>
        {ua ? (
          <View testID="issues-filters" style={{ gap: 12 }}>
            <Row label="Priority">
              <Chip testID="filter-priority-all" label="Any" selected={priority === null} onPress={() => pick(setPriority, null)} />
              {PRIORITIES.map((p) => <Chip key={p} testID={`filter-priority-${p}`} label={PRIORITY_LABEL[p]} selected={priority === p} onPress={() => pick(setPriority, p)} />)}
            </Row>
            <Row label="Category">
              <Chip testID="filter-category-all" label="Any" selected={categoryId === null} onPress={() => pick(setCategoryId, null)} />
              {(cats.data ?? []).map((c) => <Chip key={c.id} testID={`filter-category-${c.id}`} label={c.name} selected={categoryId === c.id} onPress={() => pick(setCategoryId, c.id)} />)}
            </Row>
            <Row label="Machine">
              <Chip testID="filter-machine-all" label="Any" selected={machineId === null} onPress={() => pick(setMachineId, null)} />
              {(machines.data?.rows ?? []).map((m) => <Chip key={m.id} testID={`filter-machine-${m.id}`} label={m.code} selected={machineId === m.id} onPress={() => pick(setMachineId, m.id)} />)}
            </Row>
          </View>
        ) : null}
        {list.state === 'loading' && !d ? <Loading testID="issues-loading" label="Loading issues" /> : null}
        {list.state === 'error' ? <LoadError testID="issues-error" onRetry={list.reload} error={list.error} /> : null}
        {d && d.items.length === 0 ? <Text testID="issues-empty" style={{ fontSize: 16, color: colors.text }}>No issues here</Text> : null}
        {d?.items.map((i) => <IssueRowView key={i.id} issue={i} prefix="issue-row" />)}
        {d && d.total > d.page_size ? <Pager prefix="issues" page={page - 1} total={d.total} onPage={(p) => setPage(p + 1)} /> : null}
        <Button title="Refresh" variant="secondary" testID="issues-refresh" onPress={list.reload} />
      </View>
    </ScrollView>
  );
}
