import { act, screen } from '@testing-library/react-native';
import PlantLayout from '@/app/(app)/plant/_layout';
import { admin, ok, plantClient } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';

jest.mock('expo-router', () => {
  const { Text: T } = jest.requireActual('react-native');
  return { router: { replace: jest.fn(), push: jest.fn() }, usePathname: () => '/plant', Slot: () => <T testID="slot">tab</T>, Redirect: () => null };
});

const site = { id: 's-1', name: 'Fixture Plant U', timezone: 'Asia/Kolkata' };
jest.setTimeout(20_000);

describe('Plant layout starts its independent reads together (screen-speed step 3)', () => {
  it('asks for the plant date while the site read is still running (2 calls, 1 round trip)', async () => {
    let resolve!: (v: unknown) => void;
    const { client, db } = plantClient({ site: () => new Promise((r) => (resolve = r)) as never, plant_today: ok({ plant_date: '2026-11-18' }) });
    await renderWithSession(<PlantLayout />, { ctx: admin, client });
    expect(db.queries.map((q) => q.table).sort()).toEqual(['plant_today', 'site']);
    await act(async () => resolve(ok(site)));
    expect(await screen.findByTestId('slot')).toBeTruthy();
    expect(db.queries.map((q) => q.table).sort()).toEqual(['plant_today', 'site']); // the tenant timezone is not read when a site exists
  });
  it('without a site the tenant default is read after the answer (only then it is needed)', async () => {
    const { client, db } = plantClient({ site: ok(null), plant_today: ok({ plant_date: '2026-11-18' }), tenant: ok({ timezone: 'Asia/Kolkata' }) });
    await renderWithSession(<PlantLayout />, { ctx: admin, client });
    expect(await screen.findByText('Set up your site')).toBeTruthy();
    expect(db.queries.map((q) => q.table).sort()).toEqual(['plant_today', 'site', 'tenant']);
  });
});
