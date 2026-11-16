import { Redirect, Slot, router, usePathname } from 'expo-router';
import { Pressable, Text, View, useWindowDimensions } from 'react-native';
import { SignOutButton } from '@/components/sign-out-button';
import { colors } from '@/components/ui';
import { routeFor, useSession } from '@/lib/session-provider';

const NAV = [
  { id: 'nav-tenants', label: 'Tenants', path: '/console', match: (p: string) => p === '/console' || p.startsWith('/console/tenants') },
  { id: 'nav-admins', label: 'Super Admins', path: '/console/admins', match: (p: string) => p.startsWith('/console/admins') },
  { id: 'nav-audit', label: 'Platform audit', path: '/console/audit', match: (p: string) => p.startsWith('/console/audit') },
  { id: 'nav-password', label: 'Change password', path: '/change-password', match: () => false },
] as const;

/** A navigation entry. The current page is shown by state, by fill and by the words "Current page" (never by colour alone). */
function NavItem({ id, label, selected, onPress }: { id: string; label: string; selected: boolean; onPress: () => void }) {
  return (
    <Pressable
      testID={id}
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityState={{ selected }}
      onPress={onPress}
      style={{
        minHeight: 48, justifyContent: 'center', paddingHorizontal: 16, paddingVertical: 8, borderRadius: 8, borderWidth: 2,
        borderColor: colors.primary, backgroundColor: selected ? colors.primary : 'transparent',
      }}
    >
      <Text style={{ fontSize: 16, fontWeight: '600', color: selected ? colors.primaryText : colors.primary }}>{label}</Text>
      {selected ? (
        <Text testID={`${id}-current`} style={{ fontSize: 12, color: colors.primaryText }}>Current page</Text>
      ) : null}
    </Pressable>
  );
}

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
        role="navigation"
        style={{ padding: 16, gap: 8, borderColor: colors.border, ...(wide ? { width: 240, borderRightWidth: 1 } : { borderBottomWidth: 1 }) }}
      >
        <Text accessibilityRole="header" style={{ fontSize: 20, fontWeight: '700', color: colors.primary }}>
          MouldTrack Console
        </Text>
        <View style={{ gap: 8, flexDirection: wide ? 'column' : 'row', flexWrap: 'wrap' }}>
          {NAV.map((n) => (
            <NavItem key={n.id} id={n.id} label={n.label} selected={n.match(pathname)} onPress={() => router.push(n.path)} />
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
