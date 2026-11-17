import { router } from 'expo-router';
import { useState } from 'react';
import { ScrollView, Text, View } from 'react-native';
import { IssueRowView } from '@/components/issues/issue-row';
import { Loading, LoadError, Pager } from '@/components/plant/common';
import { Button, Chip, colors } from '@/components/ui';
import { fetchIssueList, type IssueFilters } from '@/lib/issues';
import { useSession } from '@/lib/session-provider';
import { useLoad } from '@/lib/use-load';

type Tab = 'open' | 'closed' | 'escalated' | 'stopped' | 'needs_owner';
const TABS: { key: Tab; label: string; filters: IssueFilters; ua?: boolean }[] = [
  { key: 'open', label: 'Open', filters: { status: 'not_closed' } },
  { key: 'closed', label: 'Closed', filters: { status: 'closed' } },
  { key: 'escalated', label: 'Escalated', filters: { status: 'not_closed', escalated: true } },
  { key: 'stopped', label: 'Machine stopped', filters: { status: 'not_closed', stopped: true } },
  { key: 'needs_owner', label: 'No owner', filters: { status: 'not_closed', needs_owner: true }, ua: true },
];

/** Supervisors see the issues the server lets them see (My issues); a Unit Admin sees the whole tenant. Filters are sent to the server. */
export function IssueList({ role }: { role: 'supervisor' | 'unit_admin' }) {
  const { client } = useSession();
  const [tab, setTab] = useState<Tab>('open');
  const [page, setPage] = useState(1);
  const tabs = TABS.filter((t) => !t.ua || role === 'unit_admin');
  const filters = TABS.find((t) => t.key === tab)!.filters;
  const list = useLoad(() => fetchIssueList(client, filters, page), [tab, page]);
  const d = list.data ?? list.latest;
  return (
    <ScrollView testID="issues-screen" contentContainerStyle={{ alignItems: 'center', padding: 24 }}>
      <View style={{ width: '100%', maxWidth: 720, gap: 16 }}>
        <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 12 }}>
          <Text accessibilityRole="header" style={{ fontSize: 24, fontWeight: '700', color: colors.text }}>{role === 'unit_admin' ? 'Issues' : 'My issues'}</Text>
          <Button title="Home" variant="secondary" testID="issues-home" onPress={() => router.replace('/home')} />
        </View>
        {role === 'unit_admin' ? <Button title="Report issue" testID="issues-new" onPress={() => router.push('/issues/new')} /> : null}
        <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
          {tabs.map((t) => (
            <Chip key={t.key} testID={`issues-tab-${t.key}`} label={t.label} selected={tab === t.key} onPress={() => { setTab(t.key); setPage(1); }} />
          ))}
        </View>
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
