import { ActivityIndicator, Text, View } from 'react-native';
import { Button, ErrorText, colors } from '@/components/ui';
import { PLANT_PAGE_SIZE } from '@/lib/plant';
import { toUserMessage } from '@/lib/errors';

export function Loading({ testID, label }: { testID: string; label: string }) {
  return (
    <View testID={testID} style={{ gap: 12 }}>
      <ActivityIndicator color={colors.primary} accessibilityLabel={label} />
      {[0, 1, 2].map((i) => (
        <View key={i} style={{ height: 64, borderRadius: 8, backgroundColor: '#E6EAEE' }} />
      ))}
    </View>
  );
}

export function LoadError({ testID, onRetry }: { testID: string; onRetry: () => void }) {
  return (
    <View style={{ gap: 12 }}>
      <ErrorText testID={testID}>{toUserMessage(new TypeError('Failed to fetch'))}</ErrorText>
      <Button title="Try again" testID={`${testID}-retry`} onPress={onRetry} />
    </View>
  );
}

export function Pager({ prefix, page, total, onPage }: { prefix: string; page: number; total: number; onPage: (p: number) => void }) {
  const pages = Math.max(1, Math.ceil(total / PLANT_PAGE_SIZE));
  if (total === 0) return null;
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
      <Button title="Previous" variant="secondary" testID={`${prefix}-prev`} onPress={() => onPage(Math.max(0, page - 1))} disabled={page === 0} />
      <Text testID={`${prefix}-page`} style={{ fontSize: 16, color: colors.text }}>
        Page {page + 1} of {pages}
      </Text>
      <Button title="Next" variant="secondary" testID={`${prefix}-next`} onPress={() => onPage(page + 1)} disabled={page + 1 >= pages} />
    </View>
  );
}

export function Label({ children }: { children: string }) {
  return <Text style={{ fontSize: 15, fontWeight: '600', color: colors.text }}>{children}</Text>;
}

export const rowStyle = { borderWidth: 1, borderColor: colors.border, borderRadius: 8, padding: 12, gap: 8 } as const;
