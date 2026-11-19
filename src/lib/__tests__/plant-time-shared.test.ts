import { fetchPlantTimezone, resetPlantTimezone } from '@/lib/plant-time';

function client(site: { timezone: string } | null) {
  const calls: string[] = [];
  const c = {
    calls,
    from: (t: string) => ({
      select: () => ({
        maybeSingle: async () => {
          calls.push(t);
          await new Promise((r) => setTimeout(r, 5));
          return { data: t === 'site' ? site : { timezone: 'Asia/Dubai' }, error: null };
        },
      }),
    }),
  };
  return c;
}

describe('fetchPlantTimezone is shared per session (screen-speed step 3)', () => {
  beforeEach(() => resetPlantTimezone());
  it('cards that ask at the same time share one site read, and later askers reuse the answer', async () => {
    const c = client({ timezone: 'Asia/Singapore' });
    const [a, b] = await Promise.all([fetchPlantTimezone(c as never), fetchPlantTimezone(c as never)]);
    expect([a, b]).toEqual(['Asia/Singapore', 'Asia/Singapore']);
    expect(await fetchPlantTimezone(c as never)).toBe('Asia/Singapore');
    expect(c.calls).toEqual(['site']);
  });
  it('without a site the tenant default is read once too', async () => {
    const c = client(null);
    await Promise.all([fetchPlantTimezone(c as never), fetchPlantTimezone(c as never)]);
    expect(c.calls).toEqual(['site', 'tenant']);
  });
  it('resetPlantTimezone (sign-in, site saved) forces a fresh read', async () => {
    const c = client({ timezone: 'Asia/Singapore' });
    await fetchPlantTimezone(c as never);
    resetPlantTimezone();
    await fetchPlantTimezone(c as never);
    expect(c.calls).toEqual(['site', 'site']);
  });
  it('a failed read is not cached', async () => {
    let fail = true;
    const c = { from: () => ({ select: () => ({ maybeSingle: async () => (fail ? { data: null, error: new Error('x') } : { data: { timezone: 'UTC' }, error: null }) }) }) };
    await expect(fetchPlantTimezone(c as never)).rejects.toThrow();
    fail = false;
    expect(await fetchPlantTimezone(c as never)).toBe('UTC');
  });
});
