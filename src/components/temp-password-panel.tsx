import { useState } from 'react';
import { Text, View } from 'react-native';
import { Button, colors } from '@/components/ui';

/** Shows a temporary password exactly once: it lives only in the caller's state and is gone after Done. */
export function TempPasswordPanel({ name, password, onDone }: { name?: string; password: string; onDone: () => void }) {
  const [copied, setCopied] = useState(false);
  async function copy() {
    try {
      await navigator.clipboard.writeText(password);
      setCopied(true);
    } catch {
      setCopied(false);
    }
  }
  return (
    <View testID="temp-password-panel" accessibilityRole="alert" style={{ gap: 12, borderWidth: 2, borderColor: colors.primary, borderRadius: 12, padding: 16, backgroundColor: colors.bg }}>
      <Text accessibilityRole="header" style={{ fontSize: 18, fontWeight: '700', color: colors.text }}>
        Temporary password{name ? ` for ${name}` : ''}
      </Text>
      <Text testID="temp-password" selectable style={{ fontSize: 24, fontWeight: '700', letterSpacing: 1, color: colors.text }}>
        {password}
      </Text>
      <Text testID="temp-password-warning" style={{ fontSize: 15, color: colors.text }}>
        Shown once. Hand it to the person directly.
      </Text>
      <View style={{ flexDirection: 'row', gap: 12, flexWrap: 'wrap', alignItems: 'center' }}>
        <Button title="Copy" variant="secondary" testID="temp-password-copy" onPress={copy} />
        <Button title="Done" testID="temp-password-done" onPress={onDone} />
        {copied ? (
          <Text accessibilityLiveRegion="polite" style={{ fontSize: 15, color: colors.text }}>
            Copied
          </Text>
        ) : null}
      </View>
    </View>
  );
}
