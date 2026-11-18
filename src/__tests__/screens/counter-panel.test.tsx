import { fireEvent, screen, waitFor } from '@testing-library/react-native';
import { CounterPanel } from '@/components/plant/counter-panel';
import { admin, product } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';
import { ok, rpcOk, shiftClient } from '@/test/shift-fixtures';

jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: jest.fn() }, useFocusEffect: () => {} }));
jest.setTimeout(20_000);

function render(counter: { counter_unit: string; counter_max: number | null }, rpcs: Record<string, unknown> = {}, versions: unknown[] = []) {
  const t = shiftClient(
    { machine: ok(counter), product: ok([product(1)]), cavity_version: ok(versions), plant_today: ok({ plant_date: '2026-11-18' }) },
    { rd_set_machine_counter: rpcOk({ ok: true, id: 'm-1', changed: true }), rd_set_cavities: rpcOk({ ok: true, id: 'c-1' }), rd_end_cavities: rpcOk({ ok: true, id: 'c-2' }), ...rpcs },
  );
  return { ...t, ui: renderWithSession(<CounterPanel machineId="m-1" retired={false} />, { ctx: admin, client: t.client }) };
}

describe('Counter panel (D3)', () => {
  it('saves the unit and the rollover value', async () => {
    const { rpc, ui } = render({ counter_unit: 'pieces', counter_max: null });
    await ui;
    await fireEvent.press(await screen.findByTestId('counter-unit-shots'));
    await fireEvent.changeText(screen.getByTestId('counter-max'), '999999');
    await fireEvent.press(screen.getByTestId('counter-save'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('rd_set_machine_counter', { p_request_id: expect.any(String), p_machine_id: 'm-1', p_unit: 'shots', p_max: 999999 }));
    expect(await screen.findByTestId('counter-saved')).toBeTruthy();
  });

  it('refuses a rollover value below 9 without calling the server', async () => {
    const { rpc, ui } = render({ counter_unit: 'pieces', counter_max: null });
    await ui;
    await fireEvent.changeText(await screen.findByTestId('counter-max'), '5');
    await fireEvent.press(screen.getByTestId('counter-save'));
    expect(screen.getByTestId('counter-max-error')).toHaveTextContent('Enter a whole number from 9 to 1,000,000,000,000, or leave it empty');
    expect(rpc).not.toHaveBeenCalledWith('rd_set_machine_counter', expect.anything());
  });

  it('shows the server refusal of a locked unit', async () => {
    const { ui } = render({ counter_unit: 'pieces', counter_max: null }, {
      rd_set_machine_counter: { data: null, error: { code: 'P0001', message: 'Readings already use this unit', details: '{"code":"guard","field":"counter_unit_locked"}' }, status: 400 },
    });
    await ui;
    await fireEvent.press(await screen.findByTestId('counter-unit-shots'));
    await fireEvent.press(screen.getByTestId('counter-save'));
    expect(await screen.findByTestId('counter-save-error')).toHaveTextContent('Readings already use this unit');
  });

  it('shows cavities only for a shot counter, with the history, and sets them', async () => {
    const { rpc, ui } = render({ counter_unit: 'shots', counter_max: null }, {}, [{ id: 'v1', product_id: 'p-1', effective_from: '2026-01-01', cavities: 4, recorded_at: '2026-01-01T00:00:00Z' }]);
    await ui;
    expect(await screen.findByTestId('cavity-version-v1')).toHaveTextContent('P-1 · 4 cavities · from 1 Jan 2026');
    await fireEvent.press(screen.getByTestId('cavity-product-p-1'));
    await fireEvent.changeText(screen.getByTestId('cavity-count'), '2');
    await fireEvent.press(screen.getByTestId('cavity-set'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('rd_set_cavities', expect.objectContaining({ p_machine_id: 'm-1', p_product_id: 'p-1', p_cavities: 2, p_effective_from: '2026-11-18' })));
  });

  it('hides cavities for a pieces counter', async () => {
    await render({ counter_unit: 'pieces', counter_max: null }).ui;
    await screen.findByTestId('counter-unit-pieces');
    expect(screen.queryByTestId('cavities-section')).toBeNull();
  });
});
