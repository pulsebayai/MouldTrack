import { router } from 'expo-router';
import { View } from 'react-native';
import { Chip } from '@/components/ui';

const TABS = [
  { key: 'machines', label: 'Machines', href: '/plant' },
  { key: 'products', label: 'Products', href: '/plant/products' },
  { key: 'site', label: 'Site & lines', href: '/plant/site' },
] as const;

export type PlantTab = (typeof TABS)[number]['key'];

export function tabFor(pathname: string): PlantTab {
  if (pathname.startsWith('/plant/products')) return 'products';
  if (pathname.startsWith('/plant/site')) return 'site';
  return 'machines';
}

export function PlantTabs({ active }: { active: PlantTab }) {
  return (
    <View accessibilityRole="tablist" style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
      {TABS.map((t) => (
        <Chip key={t.key} testID={`plant-tab-${t.key}`} label={t.label} selected={active === t.key} onPress={() => router.replace(t.href)} />
      ))}
    </View>
  );
}
