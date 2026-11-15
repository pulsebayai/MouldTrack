import { useState } from 'react';
import { useSession } from '@/lib/session-provider';
import { Button } from './ui';

export function SignOutButton() {
  const { client, refresh } = useSession();
  const [busy, setBusy] = useState(false);
  return (
    <Button
      title="Sign out"
      variant="secondary"
      testID="sign-out"
      busy={busy}
      disabled={busy}
      onPress={async () => {
        setBusy(true);
        try {
          await client.auth.signOut();
        } finally {
          setBusy(false);
          await refresh();
        }
      }}
    />
  );
}
