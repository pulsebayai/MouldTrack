import { useState } from 'react';
import { Modal, Text, View } from 'react-native';
import { Button, ErrorText, Field, colors } from '@/components/ui';

/** Confirmation naming the tenant with a required reason (1-200 characters). */
export function SuspendDialog(props: {
  visible: boolean;
  tenantName: string;
  busy?: boolean;
  error?: string | null;
  onConfirm: (reason: string) => void;
  onCancel: () => void;
}) {
  const { visible, tenantName, busy, error, onConfirm, onCancel } = props;
  const [reason, setReason] = useState('');
  const [fieldError, setFieldError] = useState<string | null>(null);
  const title = `Suspend ${tenantName}?`;

  function submit() {
    const r = reason.trim();
    if (r.length < 1 || r.length > 200) return setFieldError('Give a reason of 1 to 200 characters');
    setFieldError(null);
    onConfirm(r);
  }

  return (
    <Modal visible={visible} transparent animationType="none" onRequestClose={onCancel} {...({ 'aria-label': title } as object)}>
      <View style={{ flex: 1, backgroundColor: 'rgba(0,0,0,0.5)', alignItems: 'center', justifyContent: 'center', padding: 24 }}>
        <View testID="suspend-dialog" accessibilityRole="alert" accessibilityViewIsModal style={{ width: '100%', maxWidth: 420, backgroundColor: colors.bg, borderRadius: 12, padding: 24, gap: 16 }}>
          <Text testID="suspend-title" accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>
            {title}
          </Text>
          <Text style={{ fontSize: 16, color: colors.text }}>
            Every user of this tenant loses access on their next request. You can activate the tenant again at any time.
          </Text>
          <Field label="Reason" testID="suspend-reason" value={reason} onChangeText={setReason} error={fieldError} maxLength={200} autoComplete="off" />
          {error ? <ErrorText testID="suspend-error">{error}</ErrorText> : null}
          <Button title="Suspend tenant" testID="suspend-confirm" onPress={submit} busy={busy} disabled={busy} />
          <Button title="Cancel" variant="secondary" testID="suspend-cancel" onPress={onCancel} disabled={busy} />
        </View>
      </View>
    </Modal>
  );
}
