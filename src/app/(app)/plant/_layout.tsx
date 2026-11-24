import { router, Slot, usePathname } from 'expo-router';
import { ScrollView, Text, View } from 'react-native';
import { NotAllowed } from '@/components/not-allowed';
import { Loading, LoadError } from '@/components/plant/common';
import { PlantContext } from '@/components/plant/plant-context';
import { PlantTabs, tabFor } from '@/components/plant/plant-tabs';
import { SiteForm } from '@/components/plant/site-form';
import { useLoad } from '@/lib/use-load';
import { Button, colors } from '@/components/ui';
import { fetchPlantToday, fetchSite, fetchTenantTimezone } from '@/lib/plant';
import { isMember } from '@/lib/session';
import { useSession } from '@/lib/session-provider';
import { DEFAULT_TIMEZONE } from '@/lib/timezones';

/** Unit Admin only (the server enforces it too). Until the tenant has a site, the only thing offered is "Set up your site". */
export default function PlantLayout() {
  const { ctx, client } = useSession();
  const pathname = usePathname();
  const allowed = isMember(ctx) && ctx.role === 'unit_admin';
  const base = useLoad(
    async () => {
      // Independent reads start together; the tenant default is needed (and read) only when there is no site.
      const [site, today] = await Promise.all([fetchSite(client), fetchPlantToday(client)]);
      return { site, today, tenantTimezone: site ? null : await fetchTenantTimezone(client) };
    },
    [],
    allowed,
  );

  if (!isMember(ctx)) return null;
  if (!allowed) return <NotAllowed />;

  return (
    <ScrollView testID="plant-screen" contentContainerStyle={{ alignItems: 'center', padding: 24 }}>
      <View style={{ width: '100%', maxWidth: 960, gap: 16 }}>
        <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 12 }}>
          <Text accessibilityRole="header" style={{ fontSize: 26, fontWeight: '700', color: colors.text }}>
            Plant
          </Text>
          <Button title="Home" variant="secondary" testID="plant-home" onPress={() => router.replace('/home')} />
        </View>
        {base.state === 'loading' ? <Loading testID="plant-loading" label="Loading plant" /> : null}
        {base.state === 'error' ? <LoadError testID="plant-error" onRetry={base.reload} error={base.error} /> : null}
        {base.state === 'ready' && base.data && !base.data.site ? (
          <SiteForm site={null} defaultTimezone={base.data.tenantTimezone ?? DEFAULT_TIMEZONE} onSaved={base.reload} />
        ) : null}
        {base.state === 'ready' && base.data?.site ? (
          <PlantContext.Provider value={{ site: base.data.site, today: base.data.today, reload: base.reload }}>
            <PlantTabs active={tabFor(pathname)} />
            <Slot />
          </PlantContext.Provider>
        ) : null}
      </View>
    </ScrollView>
  );
}
