import { DEFAULT_TIMEZONE, TIMEZONES, timezoneLabel } from '@/lib/timezones';

describe('timezones (D6)', () => {
  it('lists Asia/Kolkata first and is the default', () => {
    expect(TIMEZONES[0]).toBe('Asia/Kolkata');
    expect(DEFAULT_TIMEZONE).toBe('Asia/Kolkata');
  });
  it('has about 20 or more unique entries', () => {
    expect(TIMEZONES.length).toBeGreaterThanOrEqual(20);
    expect(new Set(TIMEZONES).size).toBe(TIMEZONES.length);
  });
  it('every entry is a real IANA zone', () => {
    for (const z of TIMEZONES) expect(() => new Intl.DateTimeFormat('en', { timeZone: z })).not.toThrow();
  });
  it('labels keep the id readable', () => {
    expect(timezoneLabel('America/Sao_Paulo')).toBe('America / Sao Paulo');
    expect(timezoneLabel('UTC')).toBe('UTC');
  });
});
