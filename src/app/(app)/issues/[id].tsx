import { useLocalSearchParams } from 'expo-router';
import { IssueDetailView } from '@/components/issues/issue-detail';
import { NotAllowed } from '@/components/not-allowed';
import { isMember } from '@/lib/session';
import { useSession } from '@/lib/session-provider';

export default function IssueScreen() {
  const { ctx } = useSession();
  const { id } = useLocalSearchParams<{ id: string }>();
  if (!isMember(ctx)) return null;
  if (ctx.role !== 'supervisor' && ctx.role !== 'unit_admin') return <NotAllowed />;
  return <IssueDetailView id={id} />;
}
