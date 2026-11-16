import { useState, type ReactNode } from 'react';
import { ActivityIndicator, Modal, Pressable, StyleSheet, Text, TextInput, View, type TextInputProps } from 'react-native';

export const colors = {
  primary: '#0B4F71',
  primaryText: '#FFFFFF',
  text: '#1B1F23',
  muted: '#4A5560',
  error: '#B00020',
  border: '#8A96A3',
  bannerBg: '#FFF4CE',
  bannerText: '#5C4400',
  bg: '#FFFFFF',
};

export function Screen({ children, testID }: { children: ReactNode; testID?: string }) {
  return (
    <View style={styles.screen} testID={testID}>
      <View style={styles.inner}>{children}</View>
    </View>
  );
}

export function Button(props: {
  title: string;
  onPress: () => void;
  disabled?: boolean;
  busy?: boolean;
  variant?: 'primary' | 'secondary';
  testID?: string;
}) {
  const { title, onPress, disabled, busy, variant = 'primary', testID } = props;
  const primary = variant === 'primary';
  return (
    <Pressable
      testID={testID}
      accessibilityRole="button"
      accessibilityLabel={title}
      accessibilityState={{ disabled: !!disabled, busy: !!busy }}
      disabled={disabled}
      onPress={onPress}
      style={[styles.button, primary ? styles.buttonPrimary : styles.buttonSecondary, disabled && styles.buttonDisabled]}
    >
      {busy ? (
        <ActivityIndicator color={primary ? colors.primaryText : colors.primary} accessibilityLabel="Working" />
      ) : (
        <Text style={[styles.buttonText, { color: primary ? colors.primaryText : colors.primary }]}>{title}</Text>
      )}
    </Pressable>
  );
}

export function Field(props: { label: string; error?: string | null; prefix?: string } & TextInputProps) {
  const { label, error, prefix, ...input } = props;
  return (
    <View style={styles.field}>
      <Text style={styles.label}>{label}</Text>
      <View style={styles.inputRow}>
        {prefix ? (
          <Text testID={input.testID ? `${input.testID}-prefix` : undefined} style={styles.prefix}>
            {prefix}
          </Text>
        ) : null}
        <TextInput
          accessibilityLabel={label}
          aria-invalid={error ? true : undefined}
          style={[styles.input, { flex: 1 }, error ? styles.inputError : null]}
          placeholderTextColor={colors.muted}
          {...input}
        />
      </View>
      {error ? <ErrorText testID={input.testID ? `${input.testID}-error` : undefined}>{error}</ErrorText> : null}
    </View>
  );
}

/** Field with a Show/Hide control (48dp), for every password input. */
export function PasswordField(props: { label: string; error?: string | null } & TextInputProps) {
  const [shown, setShown] = useState(false);
  const { label, ...rest } = props;
  const toggle = `${shown ? 'Hide' : 'Show'} ${label.toLowerCase()}`;
  return (
    <View style={styles.field}>
      <Field label={label} secureTextEntry={!shown} {...rest} />
      <Pressable
        testID={props.testID ? `${props.testID}-toggle` : undefined}
        accessibilityRole="button"
        accessibilityLabel={toggle}
        onPress={() => setShown((s) => !s)}
        style={{ minHeight: 48, justifyContent: 'center', alignSelf: 'flex-start' }}
      >
        <Text style={{ color: colors.primary, fontSize: 15 }}>{toggle}</Text>
      </Pressable>
    </View>
  );
}

/** Status is always text; the border is decoration only. */
export function StatusLabel({ status, testID }: { status: string; testID?: string }) {
  return (
    <Text testID={testID} style={styles.status}>
      {status}
    </Text>
  );
}

/** Selectable filter chip: the selected state is shown with a check mark and bold text, not by colour alone. */
export function Chip({ label, selected, onPress, testID }: { label: string; selected: boolean; onPress: () => void; testID?: string }) {
  return (
    <Pressable
      testID={testID}
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityState={{ selected }}
      onPress={onPress}
      style={[styles.chip, selected && styles.chipSelected]}
    >
      <Text style={{ color: colors.text, fontSize: 15, fontWeight: selected ? '700' : '400' }}>{selected ? `✓ ${label}` : label}</Text>
    </Pressable>
  );
}

export function ConfirmDialog(props: {
  visible: boolean;
  title: string;
  message: string;
  confirmLabel: string;
  busy?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  const { visible, title, message, confirmLabel, busy, onConfirm, onCancel } = props;
  return (
    // No fade: a half-transparent dialog fails contrast checks and keeps blank controls mounted while it leaves.
    // react-native-web forwards unknown props to the dialog element, which needs an accessible name.
    <Modal visible={visible} transparent animationType="none" onRequestClose={onCancel} {...({ 'aria-label': title } as object)}>
      <View style={styles.backdrop}>
        <View testID="confirm-dialog" accessibilityRole="alert" accessibilityViewIsModal style={styles.dialog}>
          <Text testID="confirm-title" accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.text }}>
            {title}
          </Text>
          <Text testID="confirm-message" style={{ fontSize: 16, color: colors.text }}>
            {message}
          </Text>
          <Button title={confirmLabel} testID="confirm-ok" onPress={onConfirm} busy={busy} disabled={busy} />
          <Button title="Cancel" variant="secondary" testID="confirm-cancel" onPress={onCancel} disabled={busy} />
        </View>
      </View>
    </Modal>
  );
}

export function ErrorText({ children, testID }: { children: ReactNode; testID?: string }) {
  return (
    <Text testID={testID} accessibilityRole="alert" accessibilityLiveRegion="polite" style={styles.error}>
      {children}
    </Text>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.bg, alignItems: 'center', justifyContent: 'center', padding: 24 },
  inner: { width: '100%', maxWidth: 420, gap: 16 },
  button: { minHeight: 48, borderRadius: 8, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 16 },
  buttonPrimary: { backgroundColor: colors.primary },
  buttonSecondary: { backgroundColor: colors.bg, borderWidth: 1, borderColor: colors.primary },
  buttonDisabled: { opacity: 0.6 },
  buttonText: { fontSize: 16, fontWeight: '600' },
  field: { gap: 6 },
  label: { fontSize: 15, fontWeight: '600', color: colors.text },
  input: { minHeight: 48, borderWidth: 1, borderColor: colors.border, borderRadius: 8, paddingHorizontal: 12, fontSize: 16, color: colors.text },
  error: { color: colors.error, fontSize: 15 },
  inputRow: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  prefix: { fontSize: 16, color: colors.text, fontWeight: '600', minHeight: 48, textAlignVertical: 'center', lineHeight: 48 },
  inputError: { borderWidth: 2, borderColor: colors.error },
  status: { alignSelf: 'flex-start', borderWidth: 1, borderColor: colors.border, borderRadius: 6, paddingHorizontal: 8, paddingVertical: 2, fontSize: 14, color: colors.text },
  chip: { minHeight: 48, borderWidth: 1, borderColor: colors.border, borderRadius: 24, paddingHorizontal: 16, justifyContent: 'center' },
  chipSelected: { borderColor: colors.primary, borderWidth: 2 },
  backdrop: { flex: 1, backgroundColor: 'rgba(0,0,0,0.5)', alignItems: 'center', justifyContent: 'center', padding: 24 },
  dialog: { width: '100%', maxWidth: 420, backgroundColor: colors.bg, borderRadius: 12, padding: 24, gap: 16 },
});
