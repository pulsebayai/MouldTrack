import { fireEvent, screen, waitFor } from '@testing-library/react-native';
import { TargetsPanel } from '@/components/plant/targets-panel';
import { admin, product, version } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';
import { board, ok, rpcOk, shift, shiftClient } from '@/test/shift-fixtures';

jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: jest.fn() }, Redirect: () => null }));
jest.setTimeout(20_000);

const TODAY = '2026-11-18';
const products = [product(1), product(2)];
const ov = (id: string, shiftId: string, productId: string, from: string, pieces: number | null, rec: string) => ({ ...version(id, productId, from, pieces, rec), shift_id: shiftId });

function setup(overrides: unknown[], over: { retired?: boolean; shifts?: unknown[]; rpcs?: Record<string, unknown> } = {}) {
  const t = shiftClient({
    target_version: ok([version('v1', 'p-1', '2026-01-01', 1000, 't1')]),
    target_override_version: ok(overrides),
    shift: ok(over.shifts ?? [shift(1), shift(2, { retired_at: '2026-11-01T00:00:00Z' })]),
    plant_today: ok({ plant_date: TODAY }),
    product: (q) => ok(q.filters.some((f) => f[0] === 'is') ? products : products),
    membership: ok([{ user_id: 'u-1', full_name: 'Asha Rao' }]),
  }, over.rpcs);
  return { ...t, ui: renderWithSession(<TargetsPanel machineId="m-1" machineCode="M-1" retired={!!over.retired} />, { ctx: admin, client: t.client }) };
}

describe('Shift target overrides (AC-9)', () => {
  it('shows each shift override separately from the machine target, with history', async () => {
    await setup([ov('o2', 'sh-1', 'p-1', '2026-12-01', 900, 't3'), ov('o1', 'sh-1', 'p-1', '2026-11-01', 1100, 't2')]).ui;
    expect(await screen.findByTestId('override-row-p-1-sh-1')).toBeTruthy();
    expect(screen.getByTestId('override-current-p-1-sh-1')).toHaveTextContent('Current: 1,100 pcs/shift · from 1 Nov 2026');
    expect(screen.getByTestId('override-next-p-1-sh-1')).toHaveTextContent('Next: 900 pcs/shift from 1 Dec 2026');
    expect(screen.getByTestId('override-history-o1')).toHaveTextContent('1 Nov 2026 · 1,100 pcs/shift · by Asha Rao');
    expect(screen.getByTestId('target-current-p-1')).toHaveTextContent('Current: 1,000 pcs/shift · from 1 Jan 2026');
  });

  it('shows nothing extra when there are no overrides', async () => {
    await setup([]).ui;
    await screen.findByTestId('target-row-p-1');
    expect(screen.queryByTestId('overrides')).toBeNull();
  });

  it('sets a shift target through the shift API, naming the shift in the form', async () => {
    const { rpc, ui } = setup([]);
    await ui;
    await fireEvent.press(await screen.findByTestId('override-add'));
    expect(screen.queryByTestId('override-shift-sh-2')).toBeNull(); // retired shifts are not offered
    await fireEvent.press(screen.getByTestId('override-shift-sh-1'));
    await fireEvent.press(screen.getByTestId('override-pick-p-1'));
    expect(screen.getByText(/Set target for Morning/)).toBeTruthy();
    await fireEvent.changeText(screen.getByTestId('target-pieces'), '1,200');
    await fireEvent.press(screen.getByTestId('target-submit'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('sh_set_target_override', { p_request_id: expect.any(String), p_machine_id: 'm-1', p_product_id: 'p-1', p_shift_id: 'sh-1', p_pieces: 1200, p_effective_from: TODAY }));
  });

  it('R1: the date defaults to the first occurrence of the shift that has not started', async () => {
    const { rpc, ui } = setup([], { rpcs: { shift_board: rpcOk(board([], { plan_date: '2026-11-19' })) } });
    await ui;
    await fireEvent.press(await screen.findByTestId('override-add'));
    await fireEvent.press(screen.getByTestId('override-shift-sh-1'));
    await fireEvent.press(screen.getByTestId('override-pick-p-1'));
    await waitFor(() => expect(screen.getByTestId('target-date')).toHaveProp('value', '2026-11-19'));
    expect(rpc).toHaveBeenCalledWith('shift_board', { p_shift_id: 'sh-1', p_date: null });
    await fireEvent.changeText(screen.getByTestId('target-pieces'), '900');
    await fireEvent.press(screen.getByTestId('target-submit'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('sh_set_target_override', expect.objectContaining({ p_effective_from: '2026-11-19' })));
  });

  it('ends a shift target and says the machine target applies again', async () => {
    const { rpc, ui } = setup([ov('o1', 'sh-1', 'p-1', '2026-11-01', 1100, 't2')]);
    await ui;
    await fireEvent.press(await screen.findByTestId('override-end-p-1-sh-1'));
    expect(screen.getByText(/machine target applies again/)).toBeTruthy();
    await fireEvent.press(screen.getByTestId('target-submit'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('sh_end_target_override', { p_request_id: expect.any(String), p_machine_id: 'm-1', p_product_id: 'p-1', p_shift_id: 'sh-1', p_effective_from: TODAY }));
  });

  it('sets a new value on an existing override row', async () => {
    const { rpc, ui } = setup([ov('o1', 'sh-1', 'p-1', '2026-11-01', 1100, 't2')]);
    await ui;
    await fireEvent.press(await screen.findByTestId('override-set-p-1-sh-1'));
    await fireEvent.changeText(screen.getByTestId('target-pieces'), '950');
    await fireEvent.press(screen.getByTestId('target-submit'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('sh_set_target_override', expect.objectContaining({ p_shift_id: 'sh-1', p_pieces: 950 })));
  });

  it('offers no changes for a retired machine and no add button without active shifts', async () => {
    await setup([ov('o1', 'sh-1', 'p-1', '2026-11-01', 1100, 't2')], { retired: true }).ui;
    await screen.findByTestId('override-row-p-1-sh-1');
    expect(screen.queryByTestId('override-add')).toBeNull();
    expect(screen.queryByTestId('override-set-p-1-sh-1')).toBeNull();
    expect(screen.queryByTestId('override-end-p-1-sh-1')).toBeNull();
  });

  it('hides the add button when every shift is retired', async () => {
    await setup([], { shifts: [shift(2, { retired_at: '2026-11-01T00:00:00Z' })] }).ui;
    await screen.findByTestId('target-add');
    expect(screen.queryByTestId('override-add')).toBeNull();
  });
});
