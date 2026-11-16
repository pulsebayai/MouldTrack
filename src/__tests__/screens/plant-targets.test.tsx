import { act, fireEvent, screen, waitFor } from '@testing-library/react-native';
import { TargetsPanel } from '@/components/plant/targets-panel';
import { admin, ok, plantClient, product, version } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';

jest.mock('expo-router', () => ({ router: { replace: jest.fn(), push: jest.fn() }, Redirect: () => null }));

const TODAY = '2026-11-18';
const products = [product(1), product(2, { uom: 'kg' })];
const names = [{ user_id: 'u-1', full_name: 'Asha Rao' }];

function setup(versions: unknown[], over: { retired?: boolean; rpc?: unknown; today?: string | null } = {}) {
  const t = plantClient(
    {
      target_version: ok(versions),
      plant_today: ok(over.today === null ? null : { plant_date: over.today ?? TODAY }),
      product: (q) => ok(q.filters.some((f) => f[0] === 'is') ? products : products.filter((p) => versions.some((v) => (v as { product_id: string }).product_id === p.id))),
      membership: ok(names),
    },
    over.rpc,
  );
  return { ...t, ui: renderWithSession(<TargetsPanel machineId="m-1" machineCode="M-1" retired={!!over.retired} />, { ctx: admin, client: t.client }) };
}
jest.setTimeout(20_000);

describe('Targets panel (AC-9)', () => {
  it('shows "No target set" for a machine without any version', async () => {
    await setup([]).ui;
    expect(await screen.findByTestId('targets-empty')).toHaveTextContent('No target set');
  });

  it('shows a loading state, then current, next and history per product', async () => {
    let resolve!: (v: unknown) => void;
    const t = plantClient({ target_version: (() => new Promise((r) => (resolve = r))) as never, plant_today: ok({ plant_date: TODAY }), product: ok(products), membership: ok(names) });
    await renderWithSession(<TargetsPanel machineId="m-1" machineCode="M-1" retired={false} />, { ctx: admin, client: t.client });
    expect(screen.getByTestId('targets-loading')).toBeTruthy();
    await act(async () => resolve(ok([version('v3', 'p-1', '2026-12-01', 1300, 't3'), version('v2', 'p-1', '2026-11-18', 1200, 't2'), version('v1', 'p-1', '2026-01-01', 1000, 't1')])));
    expect(await screen.findByTestId('target-row-p-1')).toBeTruthy();
    expect(screen.getByTestId('target-current-p-1')).toHaveTextContent('Current: 1,200 pcs/shift · from 18 Nov 2026');
    expect(screen.getByTestId('target-next-p-1')).toHaveTextContent('Next: 1,300 pcs/shift from 1 Dec 2026');
    expect(screen.getByTestId('target-history-v3')).toHaveTextContent('1 Dec 2026 · 1,300 pcs/shift · by Asha Rao');
    expect(screen.getByTestId('target-history-v1')).toHaveTextContent('1 Jan 2026 · 1,000 pcs/shift · by Asha Rao');
    expect(screen.queryByTestId('targets-empty')).toBeNull();
  });

  it('shows an ended target as "No current target" with an Ended history entry, and a scheduled end', async () => {
    await setup([version('v2', 'p-1', '2026-11-10', null, 't2'), version('v1', 'p-1', '2026-01-01', 1000, 't1'), version('v4', 'p-2', '2026-12-31', null, 't4'), version('v3', 'p-2', '2026-01-01', 400, 't3')]).ui;
    expect(await screen.findByTestId('target-current-p-1')).toHaveTextContent('No current target');
    expect(screen.getByTestId('target-history-v2')).toHaveTextContent('10 Nov 2026 · Ended · by Asha Rao');
    expect(screen.queryByTestId('target-end-p-1')).toBeNull(); // nothing left to end
    expect(screen.getByTestId('target-current-p-2')).toHaveTextContent(/^Current: 400 kg\/shift/);
    expect(screen.getByTestId('target-next-p-2')).toHaveTextContent('Next: ends 31 Dec 2026');
  });

  it('names an unknown recorder as Unknown', async () => {
    await setup([version('v1', 'p-1', '2026-01-01', 1000, 't1', 'someone-else')]).ui;
    expect(await screen.findByTestId('target-history-v1')).toHaveTextContent(/by Unknown$/);
  });

  it('shows an error with Try again', async () => {
    let fail = true;
    const t = plantClient({ target_version: () => (fail ? { data: null, error: new TypeError('Failed to fetch') } : ok([])), plant_today: ok({ plant_date: TODAY }), product: ok(products), membership: ok([]) });
    await renderWithSession(<TargetsPanel machineId="m-1" machineCode="M-1" retired={false} />, { ctx: admin, client: t.client });
    expect(await screen.findByTestId('targets-error')).toBeTruthy();
    fail = false;
    await fireEvent.press(screen.getByTestId('targets-error-retry'));
    expect(await screen.findByTestId('targets-empty')).toBeTruthy();
  });
});

describe('Set and end a target (AC-5, AC-6, AC-8)', () => {
  const v1 = version('v1', 'p-1', '2026-01-01', 1000, 't1');

  it('Set target opens a form with the plant date preselected and sends whole pieces', async () => {
    const { rpc, ui } = setup([v1]);
    await ui;
    await fireEvent.press(await screen.findByTestId('target-set-p-1'));
    expect(screen.getByTestId('target-date').props.value).toBe(TODAY);
    await fireEvent.changeText(screen.getByLabelText('Pieces per shift'), '1,250');
    await fireEvent.changeText(screen.getByTestId('target-date'), '2026-12-01');
    await fireEvent.press(screen.getByTestId('target-submit'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('pm_set_target', {
      p_request_id: expect.stringMatching(/^[0-9a-f-]{36}$/), p_machine_id: 'm-1', p_product_id: 'p-1', p_pieces: 1250, p_effective_from: '2026-12-01',
    }));
    await waitFor(() => expect(screen.queryByTestId('target-form')).toBeNull()); // closes and reloads
  });

  it('refuses a past date and non-integer pieces before calling the server', async () => {
    const { rpc, ui } = setup([v1]);
    await ui;
    await fireEvent.press(await screen.findByTestId('target-set-p-1'));
    await fireEvent.changeText(screen.getByLabelText('Pieces per shift'), '12.5');
    await fireEvent.changeText(screen.getByTestId('target-date'), '2026-11-17');
    await fireEvent.press(screen.getByTestId('target-submit'));
    expect(await screen.findByTestId('target-pieces-error')).toHaveTextContent('Enter a whole number from 1 to 1,000,000');
    expect(screen.getByTestId('target-date-error')).toHaveTextContent("Targets can't start in the past");
    expect(rpc).not.toHaveBeenCalled();
    await fireEvent.changeText(screen.getByLabelText('Pieces per shift'), '0');
    await fireEvent.press(screen.getByTestId('target-submit'));
    expect(await screen.findByTestId('target-pieces-error')).toBeTruthy();
    await fireEvent.changeText(screen.getByLabelText('Pieces per shift'), '1000001');
    await fireEvent.press(screen.getByTestId('target-submit'));
    expect(screen.getByTestId('target-pieces-error')).toBeTruthy();
    expect(rpc).not.toHaveBeenCalled();
  });

  it('shows a server refusal on the field it names', async () => {
    const err = { data: null, status: 400, error: { code: 'P0001', message: "Targets can't start in the past", details: '{"code":"validation","field":"effective_from"}' } };
    const { ui } = setup([v1], { rpc: err });
    await ui;
    await fireEvent.press(await screen.findByTestId('target-set-p-1'));
    await fireEvent.changeText(screen.getByLabelText('Pieces per shift'), '900');
    await fireEvent.press(screen.getByTestId('target-submit'));
    expect(await screen.findByTestId('target-date-error')).toHaveTextContent("Targets can't start in the past");
  });

  it('shows other server refusals as a form message', async () => {
    const err = { data: null, status: 400, error: { code: 'P0001', message: 'This machine is retired', details: '{"code":"guard","field":"machine_id"}' } };
    const { ui } = setup([v1], { rpc: err });
    await ui;
    await fireEvent.press(await screen.findByTestId('target-set-p-1'));
    await fireEvent.changeText(screen.getByLabelText('Pieces per shift'), '900');
    await fireEvent.press(screen.getByTestId('target-submit'));
    expect(await screen.findByTestId('target-form-error')).toHaveTextContent('This machine is retired');
  });

  it('End target asks only for a date', async () => {
    const { rpc, ui } = setup([v1]);
    await ui;
    await fireEvent.press(await screen.findByTestId('target-end-p-1'));
    expect(screen.queryByLabelText('Pieces per shift')).toBeNull();
    await fireEvent.changeText(screen.getByTestId('target-date'), '2026-12-31');
    await fireEvent.press(screen.getByTestId('target-submit'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('pm_end_target', { p_request_id: expect.any(String), p_machine_id: 'm-1', p_product_id: 'p-1', p_effective_from: '2026-12-31' }));
  });

  it('Add product target lists active products and opens the set form for the chosen one', async () => {
    const { ui } = setup([]);
    await ui;
    await fireEvent.press(await screen.findByTestId('target-add'));
    await fireEvent.press(screen.getByTestId('target-pick-p-2'));
    expect(screen.getByTestId('target-form')).toBeTruthy();
    expect(screen.getByText(/Set target · M-1 · P-2 · Cap 2/)).toBeTruthy();
  });

  it('Add product target says so when no active product exists', async () => {
    const t = plantClient({ target_version: ok([]), plant_today: ok({ plant_date: TODAY }), product: ok([]), membership: ok([]) });
    await renderWithSession(<TargetsPanel machineId="m-1" machineCode="M-1" retired={false} />, { ctx: admin, client: t.client });
    await fireEvent.press(await screen.findByTestId('target-add'));
    expect(screen.getByTestId('target-pick-empty')).toHaveTextContent('No active products — add a product first');
  });

  it('a retired machine can end targets but not set or add them', async () => {
    await setup([v1], { retired: true }).ui;
    expect(await screen.findByTestId('target-end-p-1')).toBeTruthy();
    expect(screen.queryByTestId('target-set-p-1')).toBeNull();
    expect(screen.queryByTestId('target-add')).toBeNull();
  });

  it('has 48dp targets on every action', async () => {
    await setup([v1]).ui;
    await screen.findByTestId('target-row-p-1');
    for (const id of ['target-add', 'target-set-p-1', 'target-end-p-1']) expect(screen.getByTestId(id)).toHaveStyle({ minHeight: 48 });
  });
});
