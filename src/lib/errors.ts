export const MESSAGES = {
  invalidCredentials: 'Phone number or password is incorrect',
  network: "Can't reach MouldTrack. Check your connection and try again.",
  generic: 'Something went wrong. Please try again.',
} as const;

type ErrLike = { name?: string; code?: string; message?: string } | undefined | null;

/** Maps any thrown value to copy that is safe to show a supervisor. Never returns raw error text. */
export function toUserMessage(e: unknown): string {
  const err = (e ?? {}) as NonNullable<ErrLike>;
  const message = String(err.message ?? '');
  // A deactivated (banned) user must look exactly like a wrong password (02, D6).
  if (err.code === 'invalid_credentials' || err.code === 'user_banned' || /invalid login credentials|user is banned/i.test(message)) {
    return MESSAGES.invalidCredentials;
  }
  if (err.name === 'AuthRetryableFetchError' || /failed to fetch|network request failed|networkerror/i.test(message)) {
    return MESSAGES.network;
  }
  return MESSAGES.generic;
}
