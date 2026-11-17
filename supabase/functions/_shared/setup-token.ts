// One-time setup token check (03, D4). Pure TS, no Deno APIs, so Jest tests it with the app's toolchain.
// The token is never logged. The comparison does not exit early on the first differing character.

/** A configured token must be at least this long (32 characters of any kind; the owner generates one with `openssl rand -hex 32`). */
export const MIN_SETUP_TOKEN_LENGTH = 32;

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

/** The non-secret token in supabase/config.toml for the local stack. It must never authorise anything on a hosted project. */
export const LOCAL_SETUP_TOKEN = 'local-setup-token-not-a-secret-0123456789';

/**
 * True for the local stack's SUPABASE_URL: plain http to localhost, a loopback address, host.docker.internal or a dotless docker
 * service name (the edge runtime sees `http://kong:8000`). A hosted project is always https on a dotted host.
 */
export function isLocalSupabaseUrl(url: string | undefined | null): boolean {
  if (typeof url !== 'string' || url === '') return false;
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return false;
  }
  if (u.protocol !== 'http:') return false;
  const host = u.hostname.replace(/^\[|\]$/g, '');
  return host === 'localhost' || host === '127.0.0.1' || host === '::1' || host === 'host.docker.internal' || !host.includes('.');
}

/** A usable token is configured and, when it is the local literal, only on the local stack (R3). */
export function setupTokenUsable(expected: string | undefined | null, supabaseUrl: string | undefined | null): expected is string {
  if (!setupTokenConfigured(expected)) return false;
  if (expected === LOCAL_SETUP_TOKEN && !isLocalSupabaseUrl(supabaseUrl)) return false;
  return true;
}
