import {
  LOCAL_SETUP_TOKEN, MIN_SETUP_TOKEN_LENGTH, isLocalSupabaseUrl, setupTokenConfigured, setupTokenMatches, setupTokenUsable,
} from '../../../supabase/functions/_shared/setup-token';

const TOKEN = 'a-long-enough-setup-token-123456';

describe('setup token (03, AC-2)', () => {
  it('a token is configured only when it has at least 32 characters', () => {
    expect(setupTokenConfigured(undefined)).toBe(false);
    expect(setupTokenConfigured(null)).toBe(false);
    expect(setupTokenConfigured('')).toBe(false);
    expect(MIN_SETUP_TOKEN_LENGTH).toBe(32);
    expect(setupTokenConfigured('x'.repeat(15))).toBe(false);
    expect(setupTokenConfigured('x'.repeat(31))).toBe(false);
    expect(setupTokenConfigured('x'.repeat(MIN_SETUP_TOKEN_LENGTH - 1))).toBe(false);
    expect(setupTokenConfigured('x'.repeat(MIN_SETUP_TOKEN_LENGTH))).toBe(true);
  });

  it('refuses everything while no token is configured, even an empty or matching-looking one', () => {
    expect(setupTokenMatches(undefined, 'anything')).toBe(false);
    expect(setupTokenMatches('', '')).toBe(false);
    expect(setupTokenMatches('short', 'short')).toBe(false);
  });

  it('accepts only the exact token', () => {
    expect(setupTokenMatches(TOKEN, TOKEN)).toBe(true);
    expect(setupTokenMatches(TOKEN, null)).toBe(false);
    expect(setupTokenMatches(TOKEN, undefined)).toBe(false);
    expect(setupTokenMatches(TOKEN, '')).toBe(false);
    expect(setupTokenMatches(TOKEN, TOKEN.slice(0, -1))).toBe(false);
    expect(setupTokenMatches(TOKEN, `${TOKEN}x`)).toBe(false);
    expect(setupTokenMatches(TOKEN, TOKEN.toUpperCase())).toBe(false);
    expect(setupTokenMatches(TOKEN, `${TOKEN.slice(0, -1)}!`)).toBe(false);
  });

  it('compares multi-byte characters by their bytes', () => {
    const t = 'tokén-with-accents-1234567890-abcdefgh';
    expect(setupTokenMatches(t, t)).toBe(true);
    expect(setupTokenMatches(t, 'token-with-accents-1234567890-abcdefgh')).toBe(false);
  });
});

describe('local literal guard (03 R3)', () => {
  const LOCAL = LOCAL_SETUP_TOKEN;
  it('the local literal is itself a well-formed token (long enough), so only the guard stops it off the local stack', () => {
    expect(setupTokenConfigured(LOCAL)).toBe(true);
  });
  it.each([
    'http://127.0.0.1:15321',
    'http://localhost:15321',
    'http://kong:8000',
    'http://supabase_kong_MouldTrack:8000',
    'http://host.docker.internal:15321',
    'http://[::1]:15321',
  ])('treats %s as the local stack', (url) => {
    expect(isLocalSupabaseUrl(url)).toBe(true);
    expect(setupTokenUsable(LOCAL, url)).toBe(true);
  });
  it.each([
    'https://abcdefghijkl.supabase.co',
    'https://abcdefghijkl.supabase.red',
    'http://db.example.com',
    'https://localhost.evil.example.com',
    'http://127.0.0.1.evil.example.com',
    '',
    'not a url',
    undefined,
  ])('does not treat %s as the local stack and refuses the local literal there', (url) => {
    expect(isLocalSupabaseUrl(url)).toBe(false);
    expect(setupTokenUsable(LOCAL, url)).toBe(false);
  });
  it('any other well-formed token is usable anywhere', () => {
    expect(setupTokenUsable(TOKEN, 'https://abcdefghijkl.supabase.co')).toBe(true);
    expect(setupTokenUsable(TOKEN, undefined)).toBe(true);
  });
  it('an unconfigured token is never usable', () => {
    expect(setupTokenUsable(undefined, 'http://127.0.0.1:15321')).toBe(false);
    expect(setupTokenUsable('short', 'http://127.0.0.1:15321')).toBe(false);
  });
  it('the literal matches supabase/config.toml', () => {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const toml = require('fs').readFileSync(require('path').join(__dirname, '../../../supabase/config.toml'), 'utf8') as string;
    expect(toml).toContain(`PLATFORM_SETUP_TOKEN = "${LOCAL}"`);
  });
});
