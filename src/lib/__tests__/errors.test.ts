import { toUserMessage, MESSAGES } from '@/lib/errors';

describe('toUserMessage (AC-2)', () => {
  it('maps invalid credentials (code) to a non-technical message', () => {
    expect(toUserMessage({ name: 'AuthApiError', code: 'invalid_credentials', message: 'Invalid login credentials' })).toBe(MESSAGES.invalidCredentials);
  });
  it('maps invalid credentials (message only)', () => {
    expect(toUserMessage(new Error('Invalid login credentials'))).toBe(MESSAGES.invalidCredentials);
  });
  it.each(['Failed to fetch', 'Network request failed'])('maps network failure "%s"', (m) => {
    expect(toUserMessage(new TypeError(m))).toBe(MESSAGES.network);
  });
  it('maps retryable fetch errors', () => {
    expect(toUserMessage({ name: 'AuthRetryableFetchError', message: '' })).toBe(MESSAGES.network);
  });
  it('falls back to a generic message and never leaks internals', () => {
    expect(toUserMessage(new Error('relation "membership" does not exist'))).toBe(MESSAGES.generic);
    expect(toUserMessage(undefined)).toBe(MESSAGES.generic);
  });
  it('has the exact copy from the spec', () => {
    expect(MESSAGES.invalidCredentials).toBe('Phone number or password is incorrect');
    expect(MESSAGES.network).toBe("Can't reach MouldTrack. Check your connection and try again.");
  });
});

describe('toUserMessage for deactivated accounts (02, D6)', () => {
  it.each([
    { name: 'AuthApiError', code: 'user_banned', message: 'User is banned' },
    { name: 'AuthApiError', message: 'User is banned' },
    { name: 'AuthApiError', code: 'invalid_credentials', message: 'Invalid login credentials' },
  ])('shows the single generic sign-in message for %j', (err) => {
    expect(toUserMessage(err)).toBe(MESSAGES.invalidCredentials);
  });
  it('the sign-in message names neither the phone nor the password as the culprit', () => {
    expect(MESSAGES.invalidCredentials).toBe('Phone number or password is incorrect');
  });
});
