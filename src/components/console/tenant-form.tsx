import { useRef, useState } from 'react';
import { Text, View } from 'react-native';
import { Button, Chip, ErrorText, Field, colors } from '@/components/ui';
import { ApiError, keepRequestIdAfter, newRequestId } from '@/lib/api';
import { toUserMessage } from '@/lib/errors';
import { PLAN_TEXT, platformApi, type PlanLabel, type TenantDetail } from '@/lib/platform';
import { useSession } from '@/lib/session-provider';
import { DEFAULT_TIMEZONE, TIMEZONES, timezoneLabel } from '@/lib/timezones';

type Errors = Partial<Record<'name' | 'timezone' | 'plan_label' | 'form', string>>;
const NAME_ERROR = 'Enter a name of 1 to 80 characters';

/** Register (no `tenant`) or edit a tenant. The same form serves both; an edit sends only what changed. */
export function TenantForm({ tenant, onDone, onCancel }: { tenant?: TenantDetail; onDone: (tenantId: string) => void; onCancel: () => void }) {
  const { client } = useSession();
  const editing = !!tenant;
  const [name, setName] = useState(tenant?.name ?? '');
  const [timezone, setTimezone] = useState(tenant?.timezone ?? DEFAULT_TIMEZONE);
  const [plan, setPlan] = useState<PlanLabel>(tenant?.plan_label ?? 'trial');
  const [errors, setErrors] = useState<Errors>({});
  const [busy, setBusy] = useState(false);
  const requestId = useRef(newRequestId());
  // 04's list (src/lib/timezones.ts) is the one client source; a tenant already on a zone outside it keeps that zone as a choice. The server validates.
  const zones = TIMEZONES.includes(timezone) ? TIMEZONES : [timezone, ...TIMEZONES];

  async function onSave() {
    const e: Errors = {};
    const n = name.trim();
    const tz = timezone;
    if (n.length < 1 || n.length > 80) e.name = NAME_ERROR;
    if (Object.keys(e).length) return setErrors(e);

    const diff: { name?: string; timezone?: string; plan_label?: PlanLabel } = {};
    if (editing && tenant) {
      if (n !== tenant.name) diff.name = n;
      if (tz !== tenant.timezone) diff.timezone = tz;
      if (plan !== tenant.plan_label) diff.plan_label = plan;
      if (Object.keys(diff).length === 0) return setErrors({ form: 'No changes to save' });
    }
    setBusy(true);
    setErrors({});
    try {
      if (editing && tenant) {
        await platformApi.tenantUpdate(client, tenant.id, diff, requestId.current);
        onDone(tenant.id);
      } else {
        const res = await platformApi.tenantCreate(client, { name: n, timezone: tz, plan_label: plan }, requestId.current);
        onDone(res.tenant_id);
      }
    } catch (err) {
      if (!keepRequestIdAfter(err)) requestId.current = newRequestId();
      if (err instanceof ApiError && err.field && ['name', 'timezone', 'plan_label'].includes(err.field)) setErrors({ [err.field]: err.message } as Errors);
      else setErrors({ form: err instanceof ApiError ? err.message : toUserMessage(err) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <View testID="tenant-form" style={{ gap: 16 }}>
      <Text accessibilityRole="header" style={{ fontSize: 22, fontWeight: '700', color: colors.text }}>
        {editing ? 'Edit tenant' : 'Register tenant'}
      </Text>
      <Field label="Tenant name" testID="tenant-name" value={name} onChangeText={setName} error={errors.name} autoComplete="off" />
      <View style={{ gap: 6 }}>
        <Text style={{ fontSize: 15, fontWeight: '600', color: colors.text }}>Time zone</Text>
        <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
          {zones.map((z) => (
            <Chip key={z} testID={`tenant-tz-${z}`} label={timezoneLabel(z)} selected={timezone === z} onPress={() => setTimezone(z)} />
          ))}
        </View>
        {errors.timezone ? <ErrorText testID="tenant-tz-error">{errors.timezone}</ErrorText> : null}
      </View>
      <View style={{ gap: 6 }}>
        <Text style={{ fontSize: 15, fontWeight: '600', color: colors.text }}>Plan label</Text>
        <View style={{ flexDirection: 'row', gap: 12, flexWrap: 'wrap' }}>
          {(['trial', 'active'] as PlanLabel[]).map((p) => (
            <Chip key={p} testID={`plan-${p}`} label={PLAN_TEXT[p]} selected={plan === p} onPress={() => setPlan(p)} />
          ))}
        </View>
        <Text style={{ fontSize: 14, color: colors.muted }}>A label only. It does not limit anything.</Text>
        {errors.plan_label ? <ErrorText testID="plan-error">{errors.plan_label}</ErrorText> : null}
      </View>
      {errors.form ? <ErrorText testID="tenant-form-error">{errors.form}</ErrorText> : null}
      <Button title={editing ? 'Save changes' : 'Register tenant'} testID="tenant-save" onPress={onSave} disabled={busy} busy={busy} />
      <Button title="Cancel" variant="secondary" testID="tenant-cancel" onPress={onCancel} disabled={busy} />
    </View>
  );
}
