import { fetchPlantTimezone, formatPlantDateTime, formatPlantDay } from '@/lib/plant-time';
import { fakeDb } from '@/test/fake-db';

const IST = 'Asia/Kolkata';

describe('plant-time formatting (R6)', () => {
  // IST = UTC+5:30: the plant day starts at 18:30 UTC the evening before.
  it.each([
    ['2026-11-17T18:29:00Z', '17 Nov 2026 23:59'],
    ['2026-11-17T18:30:00Z', '18 Nov 2026 00:00'],
    ['2026-11-17T20:00:00Z', '18 Nov 2026 01:30'],
    ['2026-11-17T23:59:00Z', '18 Nov 2026 05:29'],
    ['2026-11-18T00:00:00Z', '18 Nov 2026 05:30'],
  ])('%s is %s in IST', (iso, text) => expect(formatPlantDateTime(iso, IST)).toBe(text));
  it('the date alone moves with the plant day, not UTC', () => {
    expect(formatPlantDay('2026-11-17T23:59:00Z', IST)).toBe('18 Nov 2026');
    expect(formatPlantDay('2026-11-17T18:29:00Z', IST)).toBe('17 Nov 2026');
  });
  it('uses the plant timezone, whatever the device uses', () => {
    expect(formatPlantDateTime('2026-11-17T23:59:00Z', 'UTC')).toBe('17 Nov 2026 23:59');
    expect(formatPlantDateTime('2026-11-17T23:59:00Z', 'America/New_York')).toBe('17 Nov 2026 18:59');
  });
  it('returns the input when it is not a date', () => expect(formatPlantDateTime('nope', IST)).toBe('nope'));
});

describe('fetchPlantTimezone', () => {
  const db = (site: unknown, tenant: unknown) => fakeDb((q) => ({ data: q.table === 'site' ? site : tenant, error: null })).client as never;
  it('prefers the site, then the tenant, then India', async () => {
    expect(await fetchPlantTimezone(db({ id: 's', name: 'S', timezone: 'Asia/Dubai' }, { timezone: 'UTC' }))).toBe('Asia/Dubai');
    expect(await fetchPlantTimezone(db(null, { timezone: 'Asia/Singapore' }))).toBe('Asia/Singapore');
    expect(await fetchPlantTimezone(db(null, null))).toBe('Asia/Kolkata');
  });
});
