import { useLocalSearchParams } from 'expo-router';
import { MachineForm } from '@/components/plant/machine-form';

export default function MachineDetail() {
  const { id } = useLocalSearchParams<{ id: string }>();
  return <MachineForm machineId={String(id)} />;
}
