import { MIN_SETUP_TOKEN_LENGTH, setupTokenConfigured, setupTokenMatches } from '../../../supabase/functions/_shared/setup-token';

const TOKEN = 'a-long-enough-setup-token-123456';

describe('setup token (03, AC-2)', () => {
  it('a token is configured only when it has at least 16 characters', () => {
    expect(setupTokenConfigured(undefined)).toBe(false);
    expect(setupTokenConfigured(null)).toBe(false);
    expect(setupTokenConfigured('')).toBe(false);
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
    const t = 'tokén-with-accents-1234567890';
    expect(setupTokenMatches(t, t)).toBe(true);
    expect(setupTokenMatches(t, 'token-with-accents-1234567890')).toBe(false);
  });
});
