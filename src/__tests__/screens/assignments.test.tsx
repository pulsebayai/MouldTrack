import { fireEvent, screen, waitFor } from '@testing-library/react-native';
import Assignments from '@/app/(app)/plant/assignments';
import { PlantContext } from '@/components/plant/plant-context';
import { admin } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';
import { board, boardMachine, ok, rpcOk, shift, shiftClient, supervisor } from '@/test/shift-fixtures';

jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: jest.fn() }, Redirect: () => null }));
jest.setTimeout(20_000);

const TODAY = '2026-11-18';
const machines = [
  boardMachine(1, { owner_id: 's-1', owner_name: 'Sup 1', source: 'plan' }),
  boardMachine(2, { owner_id: 's-1', owner_name: 'Sup 1', source: 'plan' }),
  boardMachine(3, { owner_id: 's-2', owner_name: 'Sup 2', source: 'cover', reason: 'Leave' }),
  boardMachine(4),
];

function setup(rpcs: Record<string, unknown> = {}, rows = machines) {
  const t = shiftClient(
    { shift: ok([shift(1), shift(2)]), membership: ok([supervisor(1), supervisor(2), supervisor(3)]) },
    { shift_board: rpcOk(board(rows)), ...rpcs },
  );
  const ui = renderWithSession(
    <PlantContext.Provider value={{ site: { id: 'site', name: 'Site', timezone: 'Asia/Kolkata' }, today: TODAY, reload: jest.fn() }}>
      <Assignments />
    </PlantContext.Provider>,
    { ctx: admin, client: t.client },
  );
  return { ...t, ui };
}
const pick = async (...ids: string[]) => {
  for (const id of ids) await fireEvent.press(await screen.findByTestId(`board-machine-${id}`));
};

describe('Assignments board (AC-9)', () => {
  it('asks for shifts first when there are none', async () => {
    const t = shiftClient({ shift: ok([]) });
    await renderWithSession(<PlantContext.Provider value={{ site: { id: 's', name: 'S', timezone: 'UTC' }, today: TODAY, reload: jest.fn() }}><Assignments /></PlantContext.Provider>, { ctx: admin, client: t.client });
    expect(await screen.findByTestId('assignments-no-shifts')).toBeTruthy();
  });

  it('loads the first shift for today and puts Unassigned first, then supervisors', async () => {
    const { rpc, ui } = setup();
    await ui;
    expect(await screen.findByTestId('board')).toBeTruthy();
    expect(rpc).toHaveBeenCalledWith('shift_board', { p_shift_id: 'sh-1', p_date: TODAY });
    expect(screen.getByTestId('board-unassigned-title')).toHaveTextContent('Unassigned this shift (1)');
    expect(screen.getByTestId('board-group-s-1')).toBeTruthy();
    expect(screen.getByTestId('board-source-m-1')).toHaveTextContent('Plan');
    expect(screen.getByTestId('board-source-m-3')).toHaveTextContent('Cover: Leave');
    expect(screen.getByTestId('board-source-m-4')).toHaveTextContent('No plan');
    expect(screen.queryByTestId('board-actions')).toBeNull();
  });

  it('reloads the board for another shift and for another date, and refuses a bad date', async () => {
    const { rpc, ui } = setup();
    await ui;
    await screen.findByTestId('board');
    await fireEvent.press(screen.getByTestId('board-shift-sh-2'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('shift_board', { p_shift_id: 'sh-2', p_date: TODAY }));
    await fireEvent.changeText(screen.getByTestId('board-date'), '2026-11-20');
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('shift_board', { p_shift_id: 'sh-2', p_date: '2026-11-20' }));
    const n = rpc.mock.calls.length;
    await fireEvent.changeText(screen.getByTestId('board-date'), '20/11');
    expect(screen.getByText('Enter a date as YYYY-MM-DD')).toBeTruthy();
    expect(rpc.mock.calls.length).toBe(n);
  });

  it('multi-selects machines and shows actions with the count', async () => {
    await setup().ui;
    await pick('m-1', 'm-4');
    expect(screen.getByTestId('board-selected-count')).toHaveTextContent('2 selected');
    expect(screen.getByTestId('board-assign')).toBeTruthy();
    expect(screen.getByTestId('board-cover')).toBeTruthy();
    expect(screen.getByTestId('board-end')).toBeTruthy();
    await fireEvent.press(screen.getByTestId('board-machine-m-1'));
    expect(screen.getByTestId('board-selected-count')).toHaveTextContent('1 selected');
  });

  it('assigns machines nobody owns without a dialog', async () => {
    const { rpc, ui } = setup();
    await ui;
    await pick('m-4');
    await fireEvent.press(screen.getByTestId('board-assign'));
    await fireEvent.press(screen.getByTestId('assign-submit'));
    expect(screen.getByTestId('assign-sup-error')).toHaveTextContent('Choose a supervisor');
    await fireEvent.press(screen.getByTestId('assign-sup-s-3'));
    await fireEvent.press(screen.getByTestId('assign-submit'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('sh_assign', { p_request_id: expect.any(String), p_shift_id: 'sh-1', p_supervisor_id: 's-3', p_machine_ids: ['m-4'], p_from: TODAY, p_until: null }));
    expect(screen.queryByTestId('confirm-dialog')).toBeNull();
  });

  it('names who loses machines before moving them, and does nothing until confirmed', async () => {
    const { rpc, ui } = setup();
    await ui;
    await pick('m-1', 'm-2', 'm-3');
    await fireEvent.press(screen.getByTestId('board-assign'));
    await fireEvent.press(screen.getByTestId('assign-sup-s-3'));
    await fireEvent.press(screen.getByTestId('assign-submit'));
    expect(screen.getByTestId('confirm-message')).toHaveTextContent(/Sup 1 loses M-1, M-2\. Sup 2 loses M-3\./);
    await fireEvent.press(screen.getByTestId('confirm-cancel'));
    expect(rpc).not.toHaveBeenCalledWith('sh_assign', expect.anything());
    await fireEvent.press(screen.getByTestId('assign-submit'));
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('sh_assign', expect.objectContaining({ p_machine_ids: ['m-1', 'm-2', 'm-3'], p_supervisor_id: 's-3' })));
  });

  it('refuses an assignment that starts in the past without calling the server', async () => {
    const { rpc, ui } = setup();
    await ui;
    await pick('m-4');
    await fireEvent.press(screen.getByTestId('board-assign'));
    await fireEvent.press(screen.getByTestId('assign-sup-s-3'));
    await fireEvent.changeText(screen.getByTestId('assign-from'), '2026-11-01');
    await fireEvent.press(screen.getByTestId('assign-submit'));
    expect(screen.getByText("Assignments can't start in the past")).toBeTruthy();
    expect(rpc).not.toHaveBeenCalledWith('sh_assign', expect.anything());
  });

  it('names the machines and dates of a later_change refusal', async () => {
    const later = { data: null, status: 400, error: { code: 'P0001', message: 'A later change exists', details: '{"code":"guard","field":"later_change","machines":["M-4"],"dates":["2026-12-01"]}' } };
    await setup({ sh_assign: later }).ui;
    await pick('m-4');
    await fireEvent.press(screen.getByTestId('board-assign'));
    await fireEvent.press(screen.getByTestId('assign-sup-s-3'));
    await fireEvent.press(screen.getByTestId('assign-submit'));
    expect(await screen.findByTestId('assign-form-error')).toHaveTextContent(/A later change exists: M-4 \(1 Dec 2026\)/);
  });

  it('covers one occurrence: reason is required, unassigned is allowed', async () => {
    const { rpc, ui } = setup();
    await ui;
    await pick('m-1');
    await fireEvent.press(screen.getByTestId('board-cover'));
    await fireEvent.press(screen.getByTestId('cover-submit'));
    expect(screen.getByTestId('cover-sup-error')).toBeTruthy();
    await fireEvent.press(screen.getByTestId('cover-sup-none'));
    expect(screen.getByTestId('cover-losers')).toHaveTextContent('Sup 1 loses M-1.');
    await fireEvent.press(screen.getByTestId('cover-submit'));
    expect(screen.getByText('Enter a reason of 1 to 200 characters')).toBeTruthy();
    expect(rpc).not.toHaveBeenCalledWith('sh_cover', expect.anything());
    await fireEvent.changeText(screen.getByTestId('cover-reason'), 'Sick');
    await fireEvent.press(screen.getByTestId('cover-submit'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('sh_cover', { p_request_id: expect.any(String), p_shift_id: 'sh-1', p_shift_date: TODAY, p_machine_ids: ['m-1'], p_supervisor_id: null, p_reason: 'Sick' }));
  });

  it('covers with another supervisor', async () => {
    const { rpc, ui } = setup();
    await ui;
    await pick('m-1');
    await fireEvent.press(screen.getByTestId('board-cover'));
    await fireEvent.press(screen.getByTestId('cover-sup-s-3'));
    await fireEvent.changeText(screen.getByTestId('cover-reason'), 'Training');
    await fireEvent.press(screen.getByTestId('cover-submit'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('sh_cover', expect.objectContaining({ p_supervisor_id: 's-3', p_reason: 'Training' })));
  });

  it('ends an assignment from a date', async () => {
    const { rpc, ui } = setup();
    await ui;
    await pick('m-1', 'm-2');
    await fireEvent.press(screen.getByTestId('board-end'));
    await fireEvent.press(screen.getByTestId('end-submit'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('sh_unassign', { p_request_id: expect.any(String), p_shift_id: 'sh-1', p_machine_ids: ['m-1', 'm-2'], p_from: TODAY }));
  });

  it('clears the selection and reloads the board after a write', async () => {
    const { rpc, ui } = setup();
    await ui;
    await pick('m-4');
    await fireEvent.press(screen.getByTestId('board-assign'));
    await fireEvent.press(screen.getByTestId('assign-sup-s-3'));
    const before = rpc.mock.calls.filter((c) => (c as unknown[])[0] === 'shift_board').length;
    await fireEvent.press(screen.getByTestId('assign-submit'));
    await waitFor(() => expect(rpc.mock.calls.filter((c) => (c as unknown[])[0] === 'shift_board').length).toBe(before + 1));
    await waitFor(() => expect(screen.queryByTestId('board-actions')).toBeNull());
  });

  it('flags an inactive supervisor with a text label and says when there are no machines', async () => {
    await setup({}, [boardMachine(1, { owner_id: 's-9', owner_name: 'Gone', owner_inactive: true, source: 'plan' })]).ui;
    expect(await screen.findByTestId('board-inactive-s-9')).toHaveTextContent('Inactive supervisor');
  });

  it('shows the empty-machines state', async () => {
    await setup({}, []).ui;
    expect(await screen.findByTestId('board-empty')).toBeTruthy();
  });

  it('shows a board error with Try again', async () => {
    let fail = true;
    const t = shiftClient({ shift: ok([shift(1)]), membership: ok([]) }, { shift_board: () => (fail ? { data: { ok: false, code: 'not_allowed' }, error: null, status: 200 } : rpcOk(board([]))) });
    await renderWithSession(<PlantContext.Provider value={{ site: { id: 's', name: 'S', timezone: 'UTC' }, today: TODAY, reload: jest.fn() }}><Assignments /></PlantContext.Provider>, { ctx: admin, client: t.client });
    expect(await screen.findByTestId('board-error')).toBeTruthy();
    fail = false;
    await fireEvent.press(screen.getByTestId('board-error-retry'));
    expect(await screen.findByTestId('board-empty')).toBeTruthy();
  });
});
