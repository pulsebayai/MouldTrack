import { useRef, useState } from 'react';
import { Text, View } from 'react-native';
import { Button, ErrorText, Field, colors } from '@/components/ui';
import { ApiError, keepRequestIdAfter, newRequestId } from '@/lib/api';
import { toUserMessage } from '@/lib/errors';
import { normalisePhone } from '@/lib/identity';
import { platformApi } from '@/lib/platform';
import { useSession } from '@/lib/session-provider';

type Errors = Partial<Record<'full_name' | 'employee_id' | 'phone' | 'form', string>>;
const NAME_ERROR = 'Enter a name of 1 to 80 characters';
const EMP_ERROR = 'Employee ID: 1 to 30 letters, digits, - _ or /';

/**
 * Add a Unit Admin to a tenant (`tenantId` set: name, employee ID, phone) or a Super Admin (no `tenantId`: name, phone).
 * On success the temporary password goes to the caller exactly once.
 */
export function PersonForm({ tenantId, onCreated, onCancel }: { tenantId?: string; onCreated: (name: string, tempPassword: string) => void; onCancel: () => void }) {
  const { client } = useSession();
  const unitAdmin = !!tenantId;
  const [name, setName] = useState('');
  const [emp, setEmp] = useState('');
  const [phone, setPhone] = useState('');
  const [errors, setErrors] = useState<Errors>({});
  const [busy, setBusy] = useState(false);
  const requestId = useRef(newRequestId());

  async function onSave() {
    const e: Errors = {};
    const n = name.trim();
    const eid = emp.trim();
    if (n.length < 1 || n.length > 80) e.full_name = NAME_ERROR;
    if (unitAdmin && !/^[A-Za-z0-9_/-]{1,30}$/.test(eid)) e.employee_id = EMP_ERROR;
    const p = normalisePhone(phone);
    if (!p.ok) e.phone = p.message;
    if (Object.keys(e).length || !p.ok) return setErrors(e);

    setBusy(true);
    setErrors({});
    try {
      const res = unitAdmin
        ? await platformApi.uaCreate(client, tenantId!, { full_name: n, employee_id: eid, phone: p.e164 }, requestId.current)
        : await platformApi.saCreate(client, { full_name: n, phone: p.e164 }, requestId.current);
      if (res.already || !res.temp_password) setErrors({ form: res.message ?? 'Already done — reset the password if it was lost' });
      else {
        requestId.current = newRequestId();
        onCreated(n, res.temp_password);
      }
    } catch (err) {
      if (!keepRequestIdAfter(err)) requestId.current = newRequestId();
      if (err instanceof ApiError && err.field && ['full_name', 'employee_id', 'phone'].includes(err.field)) setErrors({ [err.field]: err.message } as Errors);
      else setErrors({ form: err instanceof ApiError ? err.message : toUserMessage(err) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <View testID={unitAdmin ? 'ua-form' : 'sa-form'} style={{ gap: 16, borderWidth: 1, borderColor: colors.border, borderRadius: 12, padding: 16 }}>
      <Text accessibilityRole="header" style={{ fontSize: 18, fontWeight: '700', color: colors.text }}>
        {unitAdmin ? 'Add Unit Admin' : 'Add Super Admin'}
      </Text>
      <Field label="Full name" testID="person-name" value={name} onChangeText={setName} error={errors.full_name} autoComplete="off" />
      {unitAdmin ? (
        <Field label="Employee ID" testID="person-employee" value={emp} onChangeText={setEmp} error={errors.employee_id} autoCapitalize="characters" autoComplete="off" />
      ) : null}
      <Field
        label="Phone number" testID="person-phone" prefix="+91" value={phone} onChangeText={setPhone} error={errors.phone}
        keyboardType="number-pad" inputMode="numeric" autoComplete="off"
      />
      {errors.form ? <ErrorText testID="person-form-error">{errors.form}</ErrorText> : null}
      <Button title="Create" testID="person-save" onPress={onSave} disabled={busy} busy={busy} />
      <Button title="Cancel" variant="secondary" testID="person-cancel" onPress={onCancel} disabled={busy} />
    </View>
  );
}
