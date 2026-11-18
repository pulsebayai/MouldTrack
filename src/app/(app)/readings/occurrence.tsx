import { useLocalSearchParams } from 'expo-router';
import { OccurrenceView } from '@/components/readings/occurrence-view';

export default function OccurrenceScreen() {
  const p = useLocalSearchParams<{ machineId: string; shiftId: string; date: string }>();
  return <OccurrenceView machineId={String(p.machineId)} shiftId={String(p.shiftId)} shiftDate={String(p.date)} />;
}
