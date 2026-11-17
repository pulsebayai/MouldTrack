import { fireEvent, screen, waitFor } from '@testing-library/react-native';
import Shifts from '@/app/(app)/plant/shifts';
import { admin } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';
import { ok, shift, shiftClient } from '@/test/shift-fixtures';

jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: jest.fn() }, Redirect: () => null }));
jest.setTimeout(20_000);

const setup = (rows: unknown, rpcs: Record<string, unknown> = {}) => {
  const t = shiftClient({ shift: typeof rows === 'function' ? (rows as never) : ok(rows as never[]) }, rpcs);
  return { ...t, ui: renderWithSession(<Shifts />, { ctx: admin, client: t.client }) };
};

describe('Shifts tab (AC-1)', () => {
  it('lists shifts with the window, an overnight note and a text status', async () => {
    await setup([shift(1), shift(2)]).ui;
    expect(await screen.findByTestId('shift-row-sh-1')).toBeTruthy();
    expect(screen.getByTestId('shift-window-sh-1')).toHaveTextContent('06:00 – 14:00 · 8 h');
    expect(screen.getByTestId('shift-window-sh-2')).toHaveTextContent(/^22:00 – 06:00/);
    expect(screen.getByTestId('shift-window-sh-2')).toHaveTextContent(/overnight/i);
    expect(screen.getByTestId('shift-status-sh-1')).toHaveTextContent('Active');
  });

  it('shows the empty state', async () => {
    await setup([]).ui;
    expect(await screen.findByTestId('shifts-empty')).toHaveTextContent('No shifts yet — add your first shift');
  });

  it('recovers from a load error', async () => {
    let fail = true;
    await setup(() => (fail ? { data: null, count: null, error: new TypeError('Failed to fetch') } : ok([shift(1)]))).ui;
    expect(await screen.findByTestId('shifts-error')).toBeTruthy();
    fail = false;
    await fireEvent.press(screen.getByTestId('shifts-error-retry'));
    expect(await screen.findByTestId('shift-row-sh-1')).toBeTruthy();
  });

  it('validates on the client, then creates a shift with a request id', async () => {
    const { rpc, ui } = setup([]);
    await ui;
    await fireEvent.press(await screen.findByTestId('shifts-add'));
    await fireEvent.press(screen.getByTestId('shift-save'));
    expect(rpc).not.toHaveBeenCalled();
    await fireEvent.changeText(screen.getByTestId('shift-name'), 'Night');
    await fireEvent.changeText(screen.getByTestId('shift-start'), '22:00');
    await fireEvent.changeText(screen.getByTestId('shift-end'), '06:00');
    expect(screen.getByTestId('shift-duration')).toHaveTextContent('Duration: 8 h (overnight: ends the next day)');
    await fireEvent.press(screen.getByTestId('shift-save'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('sh_save_shift', { p_request_id: expect.any(String), p_id: null, p_name: 'Night', p_start: '22:00', p_end: '06:00' }));
    await waitFor(() => expect(screen.queryByTestId('shift-form')).toBeNull());
  });

  it('refuses a time off the 15-minute grid without calling the server', async () => {
    const { rpc, ui } = setup([]);
    await ui;
    await fireEvent.press(await screen.findByTestId('shifts-add'));
    await fireEvent.changeText(screen.getByTestId('shift-name'), 'X');
    await fireEvent.changeText(screen.getByTestId('shift-start'), '06:10');
    await fireEvent.changeText(screen.getByTestId('shift-end'), '14:00');
    await fireEvent.press(screen.getByTestId('shift-save'));
    expect(screen.getByText('Use 15-minute steps: :00, :15, :30 or :45')).toBeTruthy();
    expect(rpc).not.toHaveBeenCalled();
  });

  it('shows a duplicate-name refusal against the name field', async () => {
    const dup = { data: null, status: 400, error: { code: 'P0001', message: 'A shift with this name already exists', details: '{"code":"duplicate","field":"name"}' } };
    const { ui } = setup([], { sh_save_shift: dup });
    await ui;
    await fireEvent.press(await screen.findByTestId('shifts-add'));
    await fireEvent.changeText(screen.getByTestId('shift-name'), 'Morning');
    await fireEvent.changeText(screen.getByTestId('shift-start'), '06:00');
    await fireEvent.changeText(screen.getByTestId('shift-end'), '14:00');
    await fireEvent.press(screen.getByTestId('shift-save'));
    expect(await screen.findByText('A shift with this name already exists')).toBeTruthy();
  });

  it('edits an existing shift', async () => {
    const { rpc, ui } = setup([shift(1)]);
    await ui;
    await fireEvent.press(await screen.findByTestId('shift-edit-sh-1'));
    await fireEvent.changeText(screen.getByTestId('shift-end'), '15:00');
    await fireEvent.press(screen.getByTestId('shift-save'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('sh_save_shift', expect.objectContaining({ p_id: 'sh-1', p_name: 'Morning', p_end: '15:00' })));
  });

  it('retires only after the dialog is confirmed, and reinstates', async () => {
    const { rpc, ui } = setup([shift(1), shift(2, { retired_at: '2026-11-01T00:00:00Z' })]);
    await ui;
    await fireEvent.press(await screen.findByTestId('shift-toggle-sh-1'));
    expect(screen.getByTestId('confirm-title')).toHaveTextContent('Retire Morning?');
    await fireEvent.press(screen.getByTestId('confirm-cancel'));
    expect(rpc).not.toHaveBeenCalled();
    await fireEvent.press(screen.getByTestId('shift-toggle-sh-1'));
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('sh_set_shift_retired', { p_request_id: expect.any(String), p_id: 'sh-1', p_retired: true }));
    expect(screen.queryByTestId('shift-edit-sh-2')).toBeNull();
    expect(screen.getByTestId('shift-status-sh-2')).toHaveTextContent('Retired');
    await fireEvent.press(screen.getByTestId('shift-toggle-sh-2'));
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('sh_set_shift_retired', expect.objectContaining({ p_id: 'sh-2', p_retired: false })));
  });

  it('shows a server refusal of a retire', async () => {
    const guard = { data: null, status: 400, error: { code: 'P0001', message: 'Cannot retire', details: '{"code":"guard","field":"shift"}' } };
    const { ui } = setup([shift(1)], { sh_set_shift_retired: guard });
    await ui;
    await fireEvent.press(await screen.findByTestId('shift-toggle-sh-1'));
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    expect(await screen.findByTestId('shifts-action-error')).toHaveTextContent('Cannot retire');
  });

  it('hides retired shifts unless asked', async () => {
    const { db, ui } = setup([shift(1)]);
    await ui;
    await screen.findByTestId('shift-row-sh-1');
    await fireEvent.press(screen.getByTestId('shifts-show-retired'));
    await waitFor(() => expect(db.queries.length).toBeGreaterThan(1));
    const hidden = (q: { filters: unknown[][] }) => q.filters.some((f) => f[0] === 'is');
    expect(hidden(db.queries[0])).toBe(true);
    expect(hidden(db.queries[db.queries.length - 1])).toBe(false);
  });
});
