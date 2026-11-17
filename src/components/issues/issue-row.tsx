import { router } from 'expo-router';
import { Pressable, Text, View } from 'react-native';
import { StatusLabel, colors } from '@/components/ui';
import { PRIORITY_LABEL, STATUS_LABEL, formatAge, type IssueRow } from '@/lib/issues';

/** One issue in a list: every state is a word (priority, status, Stopped, Escalated, Needs owner), never colour alone. */
export function IssueRowView({ issue, prefix }: { issue: IssueRow; prefix: string }) {
  return (
    <Pressable
      testID={`${prefix}-${issue.id}`}
      accessibilityRole="button"
      onPress={() => router.push(`/issues/${issue.id}`)}
      style={{ minHeight: 48, borderWidth: 1, borderColor: colors.border, borderRadius: 8, padding: 12, gap: 6 }}
    >
      <Text style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>{issue.machine_code} · {issue.category}</Text>
      <Text numberOfLines={2} style={{ fontSize: 15, color: colors.text }}>{issue.description}</Text>
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 6 }}>
        <StatusLabel testID={`${prefix}-${issue.id}-priority`} status={PRIORITY_LABEL[issue.priority]} />
        <StatusLabel testID={`${prefix}-${issue.id}-status`} status={STATUS_LABEL[issue.status]} />
        {issue.machine_stopped ? <StatusLabel status="Machine stopped" /> : null}
        {issue.escalated ? <StatusLabel status="Escalated" /> : null}
        {issue.needs_owner ? <StatusLabel status="Needs owner" /> : null}
      </View>
      <Text style={{ fontSize: 14, color: colors.muted }}>
        {issue.owner_name ? `Owner: ${issue.owner_name} · ` : ''}Reported {formatAge(issue.age_minutes)} ago
      </Text>
    </Pressable>
  );
}
