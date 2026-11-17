import { useRef, useState } from 'react';
import { ActivityIndicator, ScrollView, Text, View } from 'react-native';
import { PersonForm } from '@/components/console/person-form';
import { TempPasswordPanel } from '@/components/temp-password-panel';
import { Button, ConfirmDialog, ErrorText, StatusLabel, colors } from '@/components/ui';
import { ApiError, keepRequestIdAfter, newRequestId } from '@/lib/api';
import { toUserMessage } from '@/lib/errors';
import { adminStatusText, fetchSuperAdmins, platformApi, type SuperAdminRow } from '@/lib/platform';
import { useSession } from '@/lib/session-provider';
import { useLoad } from '@/lib/use-load';

type Pending = { kind: 'toggle' | 'reset'; row: SuperAdminRow };

export default function SuperAdmins() {
  const { client } = useSession();
  const { state, data, reload } = useLoad(() => fetchSuperAdmins(client), []);
  const rows = data ?? [];
  const [adding, setAdding] = useState(false);
  const [pending, setPending] = useState<Pending | null>(null);
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [temp, setTemp] = useState<{ name: string; password: string } | null>(null);
  const requestIds = useRef(new Map<string, string>());

  async function confirm() {
    if (!pending) return;
    const { kind, row } = pending;
    const target = kind === 'toggle' ? (row.status === 'active' ? 'inactive' : 'active') : 'reset';
    const key = `${kind}:${row.user_id}:${target}`;
    const requestId = requestIds.current.get(key) ?? newRequestId();
    requestIds.current.set(key, requestId);
    setBusy(true);
    setActionError(null);
    try {
      if (kind === 'toggle') {
        await platformApi.saSetStatus(client, row.user_id, target as 'active' | 'inactive', requestId);
      } else {
        const res = await platformApi.saResetPassword(client, row.user_id, requestId);
        if (res.temp_password) setTemp({ name: row.full_name, password: res.temp_password });
        else setActionError(res.message ?? 'Already done — reset the password if it was lost');
      }
      requestIds.current.delete(key);
      reload();
    } catch (e) {
      if (!keepRequestIdAfter(e)) requestIds.current.delete(key);
      setActionError(e instanceof ApiError ? e.message : toUserMessage(e));
    } finally {
      setBusy(false);
      setPending(null);
    }
  }

  return (
    <ScrollView testID="admins-screen" contentContainerStyle={{ alignItems: 'center', padding: 24 }}>
      <View style={{ width: '100%', maxWidth: 800, gap: 16 }}>
        <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 12 }}>
          <Text accessibilityRole="header" style={{ fontSize: 26, fontWeight: '700', color: colors.text }}>Super Admins</Text>
          {adding ? null : <Button title="Add Super Admin" testID="admins-add" onPress={() => setAdding(true)} />}
        </View>
        {temp ? <TempPasswordPanel name={temp.name} password={temp.password} onDone={() => setTemp(null)} /> : null}
        {actionError ? <ErrorText testID="admins-action-error">{actionError}</ErrorText> : null}
        {adding ? (
          <PersonForm onCancel={() => setAdding(false)} onCreated={(name, password) => { setAdding(false); setTemp({ name, password }); reload(); }} />
        ) : null}

        {state === 'loading' ? <ActivityIndicator testID="admins-loading" color={colors.primary} accessibilityLabel="Loading Super Admins" /> : null}
        {state === 'error' ? (
          <View style={{ gap: 12 }}>
            <ErrorText testID="admins-error">{toUserMessage(new TypeError('Failed to fetch'))}</ErrorText>
            <Button title="Try again" testID="admins-retry" onPress={reload} />
          </View>
        ) : null}
        {state === 'ready' && rows.length === 0 ? <Text testID="admins-empty" style={{ fontSize: 16, color: colors.text }}>No Super Admins</Text> : null}
        {state === 'ready'
          ? rows.map((r) => (
              <View key={r.user_id} testID={`admin-row-${r.user_id}`} style={{ borderWidth: 1, borderColor: colors.border, borderRadius: 8, padding: 12, gap: 8 }}>
                <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 16, alignItems: 'center' }}>
                  <Text testID={`admin-name-${r.user_id}`} style={{ fontSize: 17, fontWeight: '700', color: colors.text, minWidth: 160 }}>
                    {r.full_name}{r.is_self ? ' (you)' : ''}
                  </Text>
                  <Text testID={`admin-phone-${r.user_id}`} style={{ fontSize: 15, color: colors.text }}>{r.phone_masked}</Text>
                  <StatusLabel testID={`admin-status-${r.user_id}`} status={adminStatusText(r)} />
                </View>
                {r.is_self ? null : (
                  <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
                    <Button
                      title={r.status === 'active' ? 'Deactivate' : 'Reactivate'} variant="secondary" testID={`admin-toggle-${r.user_id}`}
                      onPress={() => { setActionError(null); setPending({ kind: 'toggle', row: r }); }}
                    />
                    {r.status === 'active' ? (
                      <Button title="Reset password" variant="secondary" testID={`admin-reset-${r.user_id}`} onPress={() => { setActionError(null); setPending({ kind: 'reset', row: r }); }} />
                    ) : null}
                  </View>
                )}
              </View>
            ))
          : null}
      </View>
      <ConfirmDialog
        visible={!!pending}
        busy={busy}
        title={pending ? (pending.kind === 'reset' ? `Reset password for ${pending.row.full_name}?` : `${pending.row.status === 'active' ? 'Deactivate' : 'Reactivate'} ${pending.row.full_name}?`) : ''}
        message={pending ? (pending.kind === 'reset' ? 'A new temporary password will be shown once. Their current password stops working.' : pending.row.status === 'active' ? 'They lose access at once and cannot sign in until you reactivate them.' : 'They can sign in again with their existing password.') : ''}
        confirmLabel={pending ? (pending.kind === 'reset' ? 'Reset password' : pending.row.status === 'active' ? 'Deactivate' : 'Reactivate') : ''}
        onConfirm={confirm}
        onCancel={() => setPending(null)}
      />
    </ScrollView>
  );
}
