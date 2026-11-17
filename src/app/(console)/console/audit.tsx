import { useState } from 'react';
import { ActivityIndicator, ScrollView, Text, View } from 'react-native';
import { Button, ErrorText, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import { AUDIT_PAGE_SIZE, actionText, fetchPlatformAudit } from '@/lib/platform';
import { useSession } from '@/lib/session-provider';
import { useLoad } from '@/lib/use-load';

/** "2026-11-17 09:30 UTC": audit times are shown in UTC, the storage zone. */
export function whenText(iso: string): string {
  return `${iso.slice(0, 10)} ${iso.slice(11, 16)} UTC`;
}

export default function PlatformAudit() {
  const { client } = useSession();
  const [page, setPage] = useState(0);
  const { state, data, reload } = useLoad(() => fetchPlatformAudit(client, page), [page]);
  const rows = data?.rows ?? [];
  const total = data?.total ?? 0;
  const pages = Math.max(1, Math.ceil(total / AUDIT_PAGE_SIZE));

  return (
    <ScrollView testID="audit-screen" tabIndex={0} contentContainerStyle={{ alignItems: 'center', padding: 24 }}>
      <View style={{ width: '100%', maxWidth: 960, gap: 16 }}>
        <Text accessibilityRole="header" style={{ fontSize: 26, fontWeight: '700', color: colors.text }}>Platform audit</Text>
        <Text style={{ fontSize: 15, color: colors.muted }}>Actions by Super Admins, newest first. Tenant users&apos; own events are not shown here.</Text>
        {state === 'loading' ? <ActivityIndicator testID="audit-loading" color={colors.primary} accessibilityLabel="Loading audit" /> : null}
        {state === 'error' ? (
          <View style={{ gap: 12 }}>
            <ErrorText testID="audit-error">{toUserMessage(new TypeError('Failed to fetch'))}</ErrorText>
            <Button title="Try again" testID="audit-retry" onPress={reload} />
          </View>
        ) : null}
        {state === 'ready' && rows.length === 0 ? <Text testID="audit-empty" style={{ fontSize: 16, color: colors.text }}>No platform actions yet</Text> : null}
        {state === 'ready'
          ? rows.map((e) => (
              <View key={e.id} testID={`audit-row-${e.id}`} style={{ borderWidth: 1, borderColor: colors.border, borderRadius: 8, padding: 12, gap: 4 }}>
                <Text testID={`audit-action-${e.id}`} style={{ fontSize: 16, fontWeight: '700', color: colors.text }}>{actionText(e.action)}</Text>
                <Text testID={`audit-who-${e.id}`} style={{ fontSize: 15, color: colors.text }}>By {e.actor_name ?? 'System setup'}</Text>
                <Text testID={`audit-tenant-${e.id}`} style={{ fontSize: 15, color: colors.text }}>Tenant: {e.tenant_name ?? 'None'}</Text>
                <Text testID={`audit-when-${e.id}`} style={{ fontSize: 15, color: colors.text }}>{whenText(e.occurred_at)}</Text>
                {e.reason ? <Text testID={`audit-reason-${e.id}`} style={{ fontSize: 15, color: colors.text }}>Reason: {e.reason}</Text> : null}
              </View>
            ))
          : null}
        {state === 'ready' && total > 0 ? (
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
            <Button title="Previous" variant="secondary" testID="audit-prev" onPress={() => setPage((p) => Math.max(0, p - 1))} disabled={page === 0} />
            <Text testID="audit-page" style={{ fontSize: 16, color: colors.text }}>Page {page + 1} of {pages}</Text>
            <Button title="Next" variant="secondary" testID="audit-next" onPress={() => setPage((p) => p + 1)} disabled={page + 1 >= pages} />
          </View>
        ) : null}
      </View>
    </ScrollView>
  );
}
