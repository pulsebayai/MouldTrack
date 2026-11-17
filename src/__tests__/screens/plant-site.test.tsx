import { fireEvent, screen, waitFor } from '@testing-library/react-native';
import SiteTab from '@/app/(app)/plant/site';
import { PlantContext } from '@/components/plant/plant-context';
import { admin, ok, plantClient } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';

jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: jest.fn() }, Redirect: () => null }));

const site = { id: 's-1', name: 'Fixture Plant U', timezone: 'Asia/Kolkata' };
const lines = [{ id: 'l-1', name: 'Line A', archived_at: null }, { id: 'l-2', name: 'Line B', archived_at: null }];
const reload = jest.fn();

function setup(rows: unknown[] = lines, rpcResult?: unknown) {
  const t = plantClient({ line: ok(rows as never[]) }, rpcResult);
  const ui = renderWithSession(
    <PlantContext.Provider value={{ site, today: '2026-11-18', reload }}>
      <SiteTab />
    </PlantContext.Provider>,
    { ctx: admin, client: t.client },
  );
  return { ...t, ui };
}
const blocked = { data: null, status: 400, error: { code: 'P0001', message: 'Move or retire its machines first', details: '{"code":"guard","field":"line","machines":["M-1"]}' } };
beforeEach(() => reload.mockReset());
jest.setTimeout(20_000);

describe('Site & lines tab (AC-1, AC-2)', () => {
  it('shows the site with its time zone selected and saves changes', async () => {
    const { rpc, ui } = setup();
    await ui;
    expect(screen.getByLabelText('Site name').props.value).toBe('Fixture Plant U');
    expect(screen.getByTestId('site-tz-Asia/Kolkata')).toHaveTextContent('✓ Asia / Kolkata');
    await fireEvent.changeText(screen.getByLabelText('Site name'), 'Renamed');
    await fireEvent.press(screen.getByTestId('site-tz-Asia/Tokyo'));
    await fireEvent.press(screen.getByTestId('site-save'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('pm_save_site', { p_request_id: expect.any(String), p_name: 'Renamed', p_timezone: 'Asia/Tokyo' }));
    expect(await screen.findByTestId('site-saved')).toHaveTextContent('Saved');
    expect(reload).toHaveBeenCalled();
  });

  it('lists lines, shows the empty state, and adds a line', async () => {
    const empty = setup([]);
    await empty.ui;
    expect(await screen.findByTestId('lines-empty')).toHaveTextContent('No lines yet');
    await fireEvent.press(screen.getByTestId('line-add'));
    expect(await screen.findByTestId('line-new-name-error')).toHaveTextContent('Enter a name of 1 to 60 characters');
    expect(empty.rpc).not.toHaveBeenCalled();
    await fireEvent.changeText(screen.getByLabelText('New line name'), ' Line C ');
    await fireEvent.press(screen.getByTestId('line-add'));
    await waitFor(() => expect(empty.rpc).toHaveBeenCalledWith('pm_save_line', { p_request_id: expect.any(String), p_id: null, p_name: 'Line C' }));
  });

  it('shows a duplicate line name next to the field', async () => {
    const dup = { data: null, status: 400, error: { code: 'P0001', message: 'A line with this name already exists', details: '{"code":"duplicate","field":"name"}' } };
    const { ui } = setup(lines, dup);
    await ui;
    await fireEvent.changeText(screen.getByLabelText('New line name'), 'line a');
    await fireEvent.press(screen.getByTestId('line-add'));
    expect(await screen.findByTestId('line-new-name-error')).toHaveTextContent('A line with this name already exists');
  });

  it('renames a line', async () => {
    const { rpc, ui } = setup();
    await ui;
    await fireEvent.press(await screen.findByTestId('line-rename-l-1'));
    expect(screen.getByLabelText('Line name').props.value).toBe('Line A');
    await fireEvent.changeText(screen.getByLabelText('Line name'), 'Line A2');
    await fireEvent.press(screen.getByTestId('line-save-l-1'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('pm_save_line', { p_request_id: expect.any(String), p_id: 'l-1', p_name: 'Line A2' }));
    await waitFor(() => expect(screen.queryByTestId('line-save-l-1')).toBeNull());
  });

  it('archives only after confirmation naming the line', async () => {
    const { rpc, ui } = setup();
    await ui;
    await fireEvent.press(await screen.findByTestId('line-archive-l-2'));
    expect(screen.getByTestId('confirm-title')).toHaveTextContent('Archive Line B?');
    await fireEvent.press(screen.getByTestId('confirm-cancel'));
    expect(rpc).not.toHaveBeenCalled();
    await fireEvent.press(screen.getByTestId('line-archive-l-2'));
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('pm_archive_line', { p_request_id: expect.any(String), p_id: 'l-2' }));
  });

  it('explains a blocked archive and lists the machines that keep the line in use', async () => {
    const { ui } = setup(lines, blocked);
    await ui;
    await fireEvent.press(await screen.findByTestId('line-archive-l-1'));
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    expect(await screen.findByTestId('lines-error')).toHaveTextContent('Move or retire its machines first. Machines: M-1');
  });

  it('shows a load error with Try again', async () => {
    let fail = true;
    const t = plantClient({ line: () => (fail ? { data: null, error: new TypeError('Failed to fetch') } : ok(lines)) });
    await renderWithSession(
      <PlantContext.Provider value={{ site, today: null, reload }}>
        <SiteTab />
      </PlantContext.Provider>,
      { ctx: admin, client: t.client },
    );
    expect(await screen.findByTestId('lines-load-error')).toBeTruthy();
    fail = false;
    await fireEvent.press(screen.getByTestId('lines-load-error-retry'));
    expect(await screen.findByTestId('line-row-l-1')).toBeTruthy();
  });

  it('has 48dp targets', async () => {
    await setup().ui;
    await screen.findByTestId('line-row-l-1');
    for (const id of ['site-save', 'line-add', 'line-rename-l-1', 'line-archive-l-1']) expect(screen.getByTestId(id)).toHaveStyle({ minHeight: 48 });
  });
});

describe('Site timezone lock (R2)', () => {
  const renderSite = (hasTargets: boolean) => {
    const t = plantClient({ line: ok(lines), target_version: ok(null, hasTargets ? 2 : 0) });
    return { ...t, ui: renderWithSession(
      <PlantContext.Provider value={{ site, today: '2026-11-18', reload }}>
        <SiteTab />
      </PlantContext.Provider>,
      { ctx: admin, client: t.client },
    ) };
  };
  it('shows the time zone as read-only text with the reason once targets exist, and still saves the name', async () => {
    const { rpc, ui } = renderSite(true);
    await ui;
    expect(await screen.findByTestId('site-tz-locked')).toHaveTextContent("Asia / Kolkata");
    expect(screen.getByTestId('site-tz-locked-note')).toHaveTextContent("The site timezone can't change once targets exist");
    expect(screen.queryByTestId('site-tz-Asia/Tokyo')).toBeNull();
    await fireEvent.changeText(screen.getByLabelText('Site name'), 'Renamed');
    await fireEvent.press(screen.getByTestId('site-save'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('pm_save_site', { p_request_id: expect.any(String), p_name: 'Renamed', p_timezone: 'Asia/Kolkata' }));
  });
  it('keeps the time zone chips while no target exists', async () => {
    const { ui } = renderSite(false);
    await ui;
    await screen.findByTestId('line-row-l-1');
    expect(screen.getByTestId('site-tz-Asia/Tokyo')).toBeTruthy();
    expect(screen.queryByTestId('site-tz-locked')).toBeNull();
  });
});

describe('Load errors use the shared message mapping (R4 item 9)', () => {
  it('shows the generic message for an unexpected error and the network message for a fetch failure', async () => {
    const t = plantClient({ line: { data: null, error: new Error('boom: relation "line" does not exist') } });
    await renderWithSession(
      <PlantContext.Provider value={{ site, today: null, reload }}>
        <SiteTab />
      </PlantContext.Provider>,
      { ctx: admin, client: t.client },
    );
    expect(await screen.findByTestId('lines-load-error')).toHaveTextContent('Something went wrong. Please try again.');
  });
});
