import type { ReactNode } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, Text, TextInput, View, type TextInputProps } from 'react-native';

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

export function Field(props: { label: string } & TextInputProps) {
  const { label, ...input } = props;
  return (
    <View style={styles.field}>
      <Text style={styles.label}>{label}</Text>
      <TextInput accessibilityLabel={label} style={styles.input} placeholderTextColor={colors.muted} {...input} />
    </View>
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
});
