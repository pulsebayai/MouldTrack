import { Redirect, Slot, router, usePathname } from 'expo-router';
import { Text, View, useWindowDimensions } from 'react-native';
import { SignOutButton } from '@/components/sign-out-button';
import { Button, colors } from '@/components/ui';
import { routeFor, useSession } from '@/lib/session-provider';

const NAV = [
  { id: 'nav-tenants', label: 'Tenants', path: '/console', match: (p: string) => p === '/console' || p.startsWith('/console/tenants') },
  { id: 'nav-admins', label: 'Super Admins', path: '/console/admins', match: (p: string) => p.startsWith('/console/admins') },
  { id: 'nav-audit', label: 'Platform audit', path: '/console/audit', match: (p: string) => p.startsWith('/console/audit') },
  { id: 'nav-password', label: 'Change password', path: '/change-password', match: () => false },
] as const;

/** Console shell: left navigation on wide screens, a top bar on narrow ones. Only an active Super Admin gets past the guard. */
export default function ConsoleLayout() {
  const { ctx } = useSession();
  const pathname = usePathname();
  const { width } = useWindowDimensions();
  const route = routeFor(ctx);
  if (route !== '/console') return <Redirect href={route} />;
  const wide = width >= 900;
  return (
    <View style={{ flex: 1, flexDirection: wide ? 'row' : 'column', backgroundColor: colors.bg }}>
      <View
        accessibilityRole="menu"
        style={{ padding: 16, gap: 8, borderColor: colors.border, ...(wide ? { width: 240, borderRightWidth: 1 } : { borderBottomWidth: 1 }) }}
      >
        <Text accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.primary }}>
          MouldTrack Console
        </Text>
        <View style={{ gap: 8, flexDirection: wide ? 'column' : 'row', flexWrap: 'wrap' }}>
          {NAV.map((n) => (
            <Button key={n.id} testID={n.id} title={n.label} variant={n.match(pathname) ? 'primary' : 'secondary'} onPress={() => router.push(n.path)} />
          ))}
          <SignOutButton />
        </View>
      </View>
      <View style={{ flex: 1 }}>
        <Slot />
      </View>
    </View>
  );
}
