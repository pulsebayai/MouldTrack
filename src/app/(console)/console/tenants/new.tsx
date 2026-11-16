import { router } from 'expo-router';
import { ScrollView, View } from 'react-native';
import { TenantForm } from '@/components/console/tenant-form';

export default function NewTenant() {
  return (
    <ScrollView contentContainerStyle={{ alignItems: 'center', padding: 24 }}>
      <View style={{ width: '100%', maxWidth: 480 }}>
        <TenantForm onDone={(id) => router.replace(`/console/tenants/${id}`)} onCancel={() => router.replace('/console')} />
      </View>
    </ScrollView>
  );
}
