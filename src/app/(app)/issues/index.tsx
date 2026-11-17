import { IssueList } from '@/components/issues/issue-list';
import { NotAllowed } from '@/components/not-allowed';
import { isMember } from '@/lib/session';
import { useSession } from '@/lib/session-provider';

export default function IssuesScreen() {
  const { ctx } = useSession();
  if (!isMember(ctx)) return null;
  if (ctx.role !== 'supervisor' && ctx.role !== 'unit_admin') return <NotAllowed />;
  return <IssueList role={ctx.role} />;
}
