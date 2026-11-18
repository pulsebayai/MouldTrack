import { useLocalSearchParams } from 'expo-router';
import { RecordForm } from '@/components/readings/record-form';

export default function RecordScreen() {
  const p = useLocalSearchParams<{ machineId: string; shiftId: string; date: string; kind: string }>();
  return <RecordForm machineId={String(p.machineId)} shiftId={String(p.shiftId)} shiftDate={String(p.date)} kind={p.kind === 'closing' ? 'closing' : 'opening'} />;
}
