import { Redirect } from 'expo-router';
import { routeFor, useSession } from '@/lib/session-provider';

export default function Index() {
  const { ctx } = useSession();
  return <Redirect href={routeFor(ctx)} />;
}
