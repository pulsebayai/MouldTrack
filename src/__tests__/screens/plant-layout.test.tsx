import { act, fireEvent, screen, waitFor } from '@testing-library/react-native';
import PlantLayout from '@/app/(app)/plant/_layout';
import { admin, ok, plantClient, sup } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';

const mockReplace = jest.fn();
let mockPath = '/plant';
jest.mock('expo-router', () => {
  const { Text: T } = jest.requireActual('react-native');
  return {
    router: { replace: (...a: unknown[]) => mockReplace(...a), push: jest.fn() },
    usePathname: () => mockPath,
    Slot: () => <T testID="slot">tab content</T>,
    Redirect: () => null,
  };
});

const site = { id: 's-1', name: 'Fixture Plant U', timezone: 'Asia/Kolkata' };
beforeEach(() => {
  mockReplace.mockReset();
  mockPath = '/plant';
});
jest.setTimeout(20_000);

describe('Plant layout (AC-1, AC-13)', () => {
  it('shows Not allowed to a supervisor and loads nothing', async () => {
    const { client, db } = plantClient({});
    await renderWithSession(<PlantLayout />, { ctx: sup, client });
    expect(screen.getByTestId('not-allowed')).toBeTruthy();
    expect(db.queries).toHaveLength(0);
  });

  it('renders nothing until the session is a member', async () => {
    const { client } = plantClient({});
    await renderWithSession(<PlantLayout />, { ctx: { noAccess: true }, client });
    expect(screen.queryByTestId('plant-screen')).toBeNull();
  });

  it('shows a loading state, then the three tabs and the tab content once a site exists', async () => {
    let resolve!: (v: unknown) => void;
    const { client } = plantClient({ site: () => new Promise((r) => (resolve = r)) as never, plant_today: ok({ plant_date: '2026-11-18' }) });
    await renderWithSession(<PlantLayout />, { ctx: admin, client });
    expect(screen.getByTestId('plant-loading')).toBeTruthy();
    await act(async () => resolve(ok(site)));
    expect(await screen.findByTestId('slot')).toBeTruthy();
    expect(screen.queryByTestId('plant-loading')).toBeNull();
    expect(screen.getByTestId('plant-tab-machines')).toHaveTextContent('✓ Machines');
    expect(screen.getByTestId('plant-tab-products')).toHaveTextContent('Products');
    expect(screen.getByTestId('plant-tab-site')).toHaveTextContent('Site & lines');
    expect(screen.queryByTestId('site-form')).toBeNull();
  });

  it('marks the tab of the current route and navigates between tabs', async () => {
    mockPath = '/plant/products';
    const { client } = plantClient({ site: ok(site), plant_today: ok({ plant_date: '2026-11-18' }) });
    await renderWithSession(<PlantLayout />, { ctx: admin, client });
    await screen.findByTestId('slot');
    expect(screen.getByTestId('plant-tab-products')).toHaveTextContent('✓ Products');
    await fireEvent.press(screen.getByTestId('plant-tab-site'));
    expect(mockReplace).toHaveBeenCalledWith('/plant/site');
    await fireEvent.press(screen.getByTestId('plant-tab-machines'));
    expect(mockReplace).toHaveBeenCalledWith('/plant');
    await fireEvent.press(screen.getByTestId('plant-home'));
    expect(mockReplace).toHaveBeenCalledWith('/home');
  });

  it('keeps machine detail routes on the Machines tab', async () => {
    mockPath = '/plant/machines/m-1';
    const { client } = plantClient({ site: ok(site), plant_today: ok({ plant_date: '2026-11-18' }) });
    await renderWithSession(<PlantLayout />, { ctx: admin, client });
    await screen.findByTestId('slot');
    expect(screen.getByTestId('plant-tab-machines')).toHaveTextContent('✓ Machines');
  });

  it('asks for the site first when the tenant has none, defaulting to the tenant timezone', async () => {
    const { client, rpc } = plantClient({ site: ok(null), tenant: ok({ timezone: 'Asia/Tokyo' }) });
    await renderWithSession(<PlantLayout />, { ctx: admin, client });
    expect(await screen.findByTestId('site-form')).toBeTruthy();
    expect(screen.getByText('Set up your site')).toBeTruthy();
    expect(screen.queryByTestId('plant-tab-machines')).toBeNull();
    expect(screen.queryByTestId('slot')).toBeNull();
    expect(screen.getByTestId('site-tz-Asia/Tokyo')).toHaveTextContent('✓ Asia / Tokyo');
    await fireEvent.changeText(screen.getByLabelText('Site name'), '  Pilot Plant ');
    await fireEvent.press(screen.getByTestId('site-save'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('pm_save_site', { p_request_id: expect.stringMatching(/^[0-9a-f-]{36}$/), p_name: 'Pilot Plant', p_timezone: 'Asia/Tokyo' }));
  });

  it('falls back to Asia/Kolkata and offers a unit zone outside the list', async () => {
    const { client } = plantClient({ site: ok(null), tenant: ok({ timezone: 'Europe/Madrid' }) });
    await renderWithSession(<PlantLayout />, { ctx: admin, client });
    expect(await screen.findByTestId('site-tz-Europe/Madrid')).toHaveTextContent('✓ Europe / Madrid');
    expect(screen.getByTestId('site-tz-Asia/Kolkata')).toBeTruthy();
  });

  it('refuses a blank site name before calling the server', async () => {
    const { client, rpc } = plantClient({ site: ok(null), tenant: ok({ timezone: 'Asia/Kolkata' }) });
    await renderWithSession(<PlantLayout />, { ctx: admin, client });
    await screen.findByTestId('site-form');
    await fireEvent.press(screen.getByTestId('site-save'));
    expect(await screen.findByTestId('site-name-error')).toHaveTextContent('Enter a name of 1 to 80 characters');
    expect(rpc).not.toHaveBeenCalled();
  });

  it('shows the server field error for the time zone', async () => {
    const { client } = plantClient(
      { site: ok(null), tenant: ok({ timezone: 'Asia/Kolkata' }) },
      { data: null, status: 400, error: { code: 'P0001', message: 'Choose a valid time zone', details: '{"code":"validation","field":"timezone"}' } },
    );
    await renderWithSession(<PlantLayout />, { ctx: admin, client });
    await screen.findByTestId('site-form');
    await fireEvent.changeText(screen.getByLabelText('Site name'), 'Plant');
    await fireEvent.press(screen.getByTestId('site-save'));
    expect(await screen.findByTestId('site-tz-error')).toHaveTextContent('Choose a valid time zone');
  });

  it('shows an error with Try again, and recovers', async () => {
    let fail = true;
    const { client } = plantClient({ site: () => (fail ? { data: null, error: new TypeError('Failed to fetch') } : ok(site)), plant_today: ok({ plant_date: '2026-11-18' }) });
    await renderWithSession(<PlantLayout />, { ctx: admin, client });
    expect(await screen.findByTestId('plant-error')).toHaveTextContent(/Can't reach MouldTrack/);
    fail = false;
    await fireEvent.press(screen.getByTestId('plant-error-retry'));
    expect(await screen.findByTestId('slot')).toBeTruthy();
  });
});
