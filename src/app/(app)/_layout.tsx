import { Redirect, Stack, usePathname } from 'expo-router';
import { routeFor, useSession } from '@/lib/session-provider';

export default function AppLayout() {
  const { ctx } = useSession();
  const pathname = usePathname();
  const route = routeFor(ctx);
  // A user with a temporary password may see only the change-password screen (the server also returns no data).
  if (route === '/change-password') {
    if (pathname !== '/change-password') return <Redirect href="/change-password" />;
    return <Stack screenOptions={{ headerShown: false }} />;
  }
  if (route !== '/home') return <Redirect href={route} />;
  return <Stack screenOptions={{ headerShown: false }} />;
}
