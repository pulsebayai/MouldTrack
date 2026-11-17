import { router } from 'expo-router';
import { useState } from 'react';
import { ActivityIndicator, ScrollView, Text, View } from 'react-native';
import { Button, Chip, ErrorText, Field, StatusLabel, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import {
  PLAN_TEXT, TENANT_PAGE_SIZE, TENANT_STATUS_TEXT, fetchTenantSummaries,
  type PlanFilter, type TenantStatusFilter,
} from '@/lib/platform';
import { useSession } from '@/lib/session-provider';
import { useLoad } from '@/lib/use-load';

const STATUS_FILTERS: { key: TenantStatusFilter; label: string }[] = [
  { key: 'all', label: 'All' }, { key: 'active', label: 'Active' }, { key: 'suspended', label: 'Suspended' },
];
const PLAN_FILTERS: { key: PlanFilter; label: string }[] = [
  { key: 'all', label: 'All' }, { key: 'trial', label: 'Trial' }, { key: 'active', label: 'Active plan' },
];

export default function Tenants() {
  const { client } = useSession();
  const [search, setSearch] = useState('');
  const [status, setStatus] = useState<TenantStatusFilter>('all');
  const [plan, setPlan] = useState<PlanFilter>('all');
  const [page, setPage] = useState(0);
  const { state, data, reload } = useLoad(() => fetchTenantSummaries(client, { search, status, plan, page }), [search, status, plan, page]);
  const rows = data?.rows ?? [];
  const total = data?.total ?? 0;
  const pages = Math.max(1, Math.ceil(total / TENANT_PAGE_SIZE));
  const filtered = search.trim() !== '' || status !== 'all' || plan !== 'all';

  return (
    <ScrollView testID="tenants-screen" contentContainerStyle={{ alignItems: 'center', padding: 24 }}>
      <View style={{ width: '100%', maxWidth: 960, gap: 16 }}>
        <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 12 }}>
          <Text accessibilityRole="header" style={{ fontSize: 26, fontWeight: '700', color: colors.text }}>Tenants</Text>
          <Button title="Register tenant" testID="tenants-add" onPress={() => router.push('/console/tenants/new')} />
        </View>

        <Field
          label="Search tenants" testID="tenants-search" value={search} placeholder="Tenant name" autoCapitalize="none"
          onChangeText={(v) => { setSearch(v); setPage(0); }}
        />
        <View style={{ gap: 8 }}>
          <Text style={{ fontSize: 15, fontWeight: '600', color: colors.text }}>Status</Text>
          <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
            {STATUS_FILTERS.map((f) => (
              <Chip key={f.key} testID={`tenants-filter-status-${f.key}`} label={f.label} selected={status === f.key} onPress={() => { setStatus(f.key); setPage(0); }} />
            ))}
          </View>
          <Text style={{ fontSize: 15, fontWeight: '600', color: colors.text }}>Plan</Text>
          <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
            {PLAN_FILTERS.map((f) => (
              <Chip key={f.key} testID={`tenants-filter-plan-${f.key}`} label={f.label} selected={plan === f.key} onPress={() => { setPlan(f.key); setPage(0); }} />
            ))}
          </View>
        </View>

        {state === 'loading' ? (
          <View testID="tenants-loading" style={{ gap: 12 }}>
            <ActivityIndicator color={colors.primary} accessibilityLabel="Loading tenants" />
            {[0, 1, 2].map((i) => <View key={i} style={{ height: 72, borderRadius: 8, backgroundColor: '#E6EAEE' }} />)}
          </View>
        ) : null}

        {state === 'error' ? (
          <View style={{ gap: 12 }}>
            <ErrorText testID="tenants-error">{toUserMessage(new TypeError('Failed to fetch'))}</ErrorText>
            <Button title="Try again" testID="tenants-retry" onPress={reload} />
          </View>
        ) : null}

        {state === 'ready' && rows.length === 0 ? (
          filtered ? (
            <Text testID="tenants-no-match" style={{ fontSize: 16, color: colors.text }}>No tenants match</Text>
          ) : (
            <Text testID="tenants-empty" style={{ fontSize: 16, color: colors.text }}>No tenants yet — register the first one</Text>
          )
        ) : null}

        {state === 'ready'
          ? rows.map((t) => (
              <View key={t.id} testID={`tenant-row-${t.id}`} style={{ borderWidth: 1, borderColor: colors.border, borderRadius: 8, padding: 12, gap: 8 }}>
                <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 16, alignItems: 'center' }}>
                  <Text testID={`tenant-name-${t.id}`} style={{ fontSize: 17, fontWeight: '700', color: colors.text, minWidth: 160 }}>{t.name}</Text>
                  <StatusLabel testID={`tenant-status-${t.id}`} status={TENANT_STATUS_TEXT[t.status]} />
                  <Text testID={`tenant-plan-${t.id}`} style={{ fontSize: 15, color: colors.text }}>Plan: {PLAN_TEXT[t.plan_label]}</Text>
                  <Text testID={`tenant-created-${t.id}`} style={{ fontSize: 15, color: colors.text }}>Created {t.created_at.slice(0, 10)}</Text>
                  <Text testID={`tenant-users-${t.id}`} style={{ fontSize: 15, color: colors.text }}>{t.active_users} active users</Text>
                  <Text testID={`tenant-admins-${t.id}`} style={{ fontSize: 15, color: colors.text }}>{t.active_unit_admins} Unit Admins</Text>
                </View>
                <View style={{ flexDirection: 'row', gap: 8 }}>
                  <Button title="Open" variant="secondary" testID={`tenant-open-${t.id}`} onPress={() => router.push(`/console/tenants/${t.id}`)} />
                </View>
              </View>
            ))
          : null}

        {state === 'ready' && total > 0 ? (
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
            <Button title="Previous" variant="secondary" testID="tenants-prev" onPress={() => setPage((p) => Math.max(0, p - 1))} disabled={page === 0} />
            <Text testID="tenants-page" style={{ fontSize: 16, color: colors.text }}>Page {page + 1} of {pages}</Text>
            <Button title="Next" variant="secondary" testID="tenants-next" onPress={() => setPage((p) => p + 1)} disabled={page + 1 >= pages} />
          </View>
        ) : null}
      </View>
    </ScrollView>
  );
}
