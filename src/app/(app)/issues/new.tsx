import { useLocalSearchParams } from 'expo-router';
import { NotAllowed } from '@/components/not-allowed';
import { ReportForm } from '@/components/issues/report-form';
import { isMember } from '@/lib/session';
import { useSession } from '@/lib/session-provider';

export default function NewIssue() {
  const { ctx } = useSession();
  const { machineId } = useLocalSearchParams<{ machineId?: string }>();
  if (!isMember(ctx)) return null;
  if (ctx.role !== 'supervisor' && ctx.role !== 'unit_admin') return <NotAllowed />;
  return <ReportForm machineId={machineId ?? null} />;
}
