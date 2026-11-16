import { router, useLocalSearchParams } from 'expo-router';
import { useCallback, useRef, useState } from 'react';
import { ActivityIndicator, ScrollView, Text, View } from 'react-native';
import { PersonForm } from '@/components/console/person-form';
import { SuspendDialog } from '@/components/console/suspend-dialog';
import { TenantForm } from '@/components/console/tenant-form';
import { TempPasswordPanel } from '@/components/temp-password-panel';
import { Button, ConfirmDialog, ErrorText, StatusLabel, colors } from '@/components/ui';
import { ApiError, keepRequestIdAfter, newRequestId } from '@/lib/api';
import { toUserMessage } from '@/lib/errors';
import {
  PLAN_TEXT, TENANT_STATUS_TEXT, adminStatusText, fetchTenant, fetchTenantUnitAdmins, platformApi, type UnitAdminRow,
} from '@/lib/platform';
import { useSession } from '@/lib/session-provider';
import { useLoad } from '@/lib/use-load';

type Pending = { kind: 'activate' } | { kind: 'reset'; row: UnitAdminRow };

export default function TenantDetail() {
  const { client } = useSession();
  const { id } = useLocalSearchParams<{ id: string }>();
  const tenantId = String(id);
  const loadTenant = useCallback(() => fetchTenant(client, tenantId), [client, tenantId]);
  const loadAdmins = useCallback(() => fetchTenantUnitAdmins(client, tenantId), [client, tenantId]);
  const tenant = useLoad(loadTenant);
  const admins = useLoad(loadAdmins);

  const [editing, setEditing] = useState(false);
  const [adding, setAdding] = useState(false);
  const [suspending, setSuspending] = useState(false);
  const [pending, setPending] = useState<Pending | null>(null);
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [dialogError, setDialogError] = useState<string | null>(null);
  const [temp, setTemp] = useState<{ name: string; password: string } | null>(null);
  const requestIds = useRef(new Map<string, string>());

  const reloadAll = () => {
    tenant.reload();
    admins.reload();
  };

  /** One idempotent request per intent: a retry after a network failure reuses the id, after a 5xx a fresh one (R2). */
  async function run(key: string, call: (requestId: string) => Promise<void>, onError: (m: string) => void) {
    const requestId = requestIds.current.get(key) ?? newRequestId();
    requestIds.current.set(key, requestId);
    setBusy(true);
    onError('');
    try {
      await call(requestId);
      requestIds.current.delete(key);
      return true;
    } catch (e) {
      if (!keepRequestIdAfter(e)) requestIds.current.delete(key);
      onError(e instanceof ApiError ? e.message : toUserMessage(e));
      return false;
    } finally {
      setBusy(false);
    }
  }

  if (tenant.state === 'loading') {
    return (
      <ScrollView contentContainerStyle={{ alignItems: 'center', padding: 24 }}>
        <ActivityIndicator testID="tenant-loading" color={colors.primary} accessibilityLabel="Loading tenant" />
      </ScrollView>
    );
  }
  if (tenant.state === 'error') {
    return (
      <ScrollView contentContainerStyle={{ alignItems: 'center', padding: 24 }}>
        <View style={{ width: '100%', maxWidth: 640, gap: 12 }}>
          <ErrorText testID="tenant-error">{toUserMessage(new TypeError('Failed to fetch'))}</ErrorText>
          <Button title="Try again" testID="tenant-retry" onPress={reloadAll} />
        </View>
      </ScrollView>
    );
  }
  const t = tenant.data;
  if (!t) {
    return (
      <ScrollView contentContainerStyle={{ alignItems: 'center', padding: 24 }}>
        <View style={{ width: '100%', maxWidth: 640, gap: 12 }}>
          <Text testID="tenant-not-found" accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>Tenant not found</Text>
          <Button title="Back to tenants" variant="secondary" testID="tenant-back" onPress={() => router.replace('/console')} />
        </View>
      </ScrollView>
    );
  }

  const suspended = t.status === 'suspended';

  async function confirmPending() {
    if (!pending) return;
    const p = pending;
    const ok = await run(
      p.kind === 'activate' ? `activate:${tenantId}` : `reset:${p.row.user_id}`,
      async (requestId) => {
        if (p.kind === 'activate') {
          await platformApi.tenantSetStatus(client, tenantId, 'active', null, requestId);
        } else {
          const res = await platformApi.uaResetPassword(client, p.row.user_id, requestId);
          if (res.temp_password) setTemp({ name: p.row.full_name, password: res.temp_password });
          else setActionError(res.message ?? 'Already done — reset the password if it was lost');
        }
      },
      (m) => setActionError(m || null),
    );
    setPending(null);
    if (ok) reloadAll();
  }

  async function confirmSuspend(reason: string) {
    const ok = await run(`suspend:${tenantId}:${reason}`, (requestId) => platformApi.tenantSetStatus(client, tenantId, 'suspended', reason, requestId).then(() => undefined), (m) => setDialogError(m || null));
    if (ok) {
      setSuspending(false);
      reloadAll();
    }
  }

  return (
    <ScrollView testID="tenant-screen" contentContainerStyle={{ alignItems: 'center', padding: 24 }}>
      <View style={{ width: '100%', maxWidth: 800, gap: 16 }}>
        <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 12 }}>
          <Text testID="tenant-detail-name" accessibilityRole="header" style={{ fontSize: 26, fontWeight: '700', color: colors.text }}>{t.name}</Text>
          <Button title="All tenants" variant="secondary" testID="tenant-all" onPress={() => router.replace('/console')} />
        </View>
        <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 12, alignItems: 'center' }}>
          <StatusLabel testID="tenant-detail-status" status={TENANT_STATUS_TEXT[t.status]} />
          <Text testID="tenant-detail-plan" style={{ fontSize: 15, color: colors.text }}>Plan: {PLAN_TEXT[t.plan_label]}</Text>
          <Text testID="tenant-detail-timezone" style={{ fontSize: 15, color: colors.text }}>Time zone: {t.timezone}</Text>
          <Text style={{ fontSize: 15, color: colors.text }}>Created {t.created_at.slice(0, 10)}</Text>
        </View>
        {suspended && t.suspended_reason ? (
          <Text testID="tenant-detail-reason" style={{ fontSize: 15, color: colors.text }}>Suspended because: {t.suspended_reason}</Text>
        ) : null}

        {temp ? <TempPasswordPanel name={temp.name} password={temp.password} onDone={() => setTemp(null)} /> : null}
        {actionError ? <ErrorText testID="tenant-action-error">{actionError}</ErrorText> : null}

        {editing ? (
          <TenantForm tenant={t} onDone={() => { setEditing(false); reloadAll(); }} onCancel={() => setEditing(false)} />
        ) : (
          <View style={{ flexDirection: 'row', gap: 12, flexWrap: 'wrap' }}>
            <Button title="Edit" variant="secondary" testID="tenant-edit" onPress={() => setEditing(true)} />
            {suspended ? (
              <Button title="Activate" testID="tenant-activate" onPress={() => { setActionError(null); setPending({ kind: 'activate' }); }} />
            ) : (
              <Button title="Suspend" variant="secondary" testID="tenant-suspend" onPress={() => { setActionError(null); setDialogError(null); setSuspending(true); }} />
            )}
          </View>
        )}

        <View testID="ua-card" style={{ gap: 12, borderWidth: 1, borderColor: colors.border, borderRadius: 12, padding: 16 }}>
          <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 12 }}>
            <Text accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>Unit Admins</Text>
            {adding ? null : <Button title="Add Unit Admin" testID="ua-add" onPress={() => setAdding(true)} />}
          </View>
          {adding ? (
            <PersonForm
              tenantId={tenantId}
              onCancel={() => setAdding(false)}
              onCreated={(name, password) => { setAdding(false); setTemp({ name, password }); admins.reload(); }}
            />
          ) : null}
          {admins.state === 'loading' ? <ActivityIndicator testID="ua-loading" color={colors.primary} accessibilityLabel="Loading Unit Admins" /> : null}
          {admins.state === 'error' ? (
            <View style={{ gap: 12 }}>
              <ErrorText testID="ua-error">{toUserMessage(new TypeError('Failed to fetch'))}</ErrorText>
              <Button title="Try again" testID="ua-retry" onPress={admins.reload} />
            </View>
          ) : null}
          {admins.state === 'ready' && (admins.data ?? []).length === 0 ? (
            <Text testID="ua-empty" style={{ fontSize: 16, color: colors.text }}>No Unit Admin yet — add the first one so this tenant can sign in</Text>
          ) : null}
          {admins.state === 'ready'
            ? (admins.data ?? []).map((r) => (
                <View key={r.user_id} testID={`ua-row-${r.user_id}`} style={{ borderWidth: 1, borderColor: colors.border, borderRadius: 8, padding: 12, gap: 8 }}>
                  <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 16, alignItems: 'center' }}>
                    <Text testID={`ua-name-${r.user_id}`} style={{ fontSize: 17, fontWeight: '700', color: colors.text, minWidth: 160 }}>{r.full_name}</Text>
                    <Text testID={`ua-phone-${r.user_id}`} style={{ fontSize: 15, color: colors.text }}>{r.phone_masked}</Text>
                    <StatusLabel testID={`ua-status-${r.user_id}`} status={adminStatusText(r)} />
                  </View>
                  {r.status === 'active' ? (
                    <View style={{ flexDirection: 'row', gap: 8 }}>
                      <Button title="Reset password" variant="secondary" testID={`ua-reset-${r.user_id}`} onPress={() => { setActionError(null); setPending({ kind: 'reset', row: r }); }} />
                    </View>
                  ) : null}
                </View>
              ))
            : null}
        </View>
      </View>

      <SuspendDialog
        visible={suspending} tenantName={t.name} busy={busy} error={dialogError}
        onConfirm={confirmSuspend} onCancel={() => setSuspending(false)}
      />
      <ConfirmDialog
        visible={!!pending}
        busy={busy}
        title={pending ? (pending.kind === 'activate' ? `Activate ${t.name}?` : `Reset password for ${pending.row.full_name}?`) : ''}
        message={pending ? (pending.kind === 'activate' ? 'Every user of this tenant can use MouldTrack again.' : 'A new temporary password will be shown once. Their current password stops working and their sessions end.') : ''}
        confirmLabel={pending ? (pending.kind === 'activate' ? 'Activate tenant' : 'Reset password') : ''}
        onConfirm={confirmPending}
        onCancel={() => setPending(null)}
      />
    </ScrollView>
  );
}
