import { Redirect, Stack } from 'expo-router';
import { routeFor, useSession } from '@/lib/session-provider';

export default function AppLayout() {
  const { ctx } = useSession();
  const route = routeFor(ctx);
  if (route !== '/home') return <Redirect href={route} />;
  return <Stack screenOptions={{ headerShown: false }} />;
}
