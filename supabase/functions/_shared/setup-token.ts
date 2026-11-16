// One-time setup token check (03, D4). Pure TS, no Deno APIs, so Jest tests it with the app's toolchain.
// The token is never logged. The comparison does not exit early on the first differing character.

/** A configured token must be at least this long (the owner generates one with `openssl rand -hex 32`). */
export const MIN_SETUP_TOKEN_LENGTH = 16;

export function setupTokenConfigured(expected: string | undefined | null): expected is string {
  return typeof expected === 'string' && expected.length >= MIN_SETUP_TOKEN_LENGTH;
}

/** True only when a token is configured and the provided one equals it. Length differences are folded into the same loop. */
export function setupTokenMatches(expected: string | undefined | null, provided: string | null | undefined): boolean {
  if (!setupTokenConfigured(expected) || typeof provided !== 'string') return false;
  const enc = new TextEncoder();
  const a = enc.encode(expected);
  const b = enc.encode(provided);
  const n = Math.max(a.length, b.length);
  let diff = a.length ^ b.length;
  for (let i = 0; i < n; i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0;
}
