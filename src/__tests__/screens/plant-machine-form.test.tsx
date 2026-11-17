import { fireEvent, screen, waitFor } from '@testing-library/react-native';
import MachineDetail from '@/app/(app)/plant/machines/[id]';
import NewMachine from '@/app/(app)/plant/machines/new';
import { admin, machine, ok, plantClient } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';

const mockReplace = jest.fn();
let mockId = 'm-1';
jest.mock('expo-router', () => ({
  router: { replace: (...a: unknown[]) => mockReplace(...a), push: jest.fn() },
  useLocalSearchParams: () => ({ id: mockId }),
  Redirect: () => null,
}));

const lines = [{ id: 'l-1', name: 'Line A', archived_at: null }];
const base = { line: ok(lines), target_version: ok([]), plant_today: ok({ plant_date: '2026-11-18' }), product: ok([]), membership: ok([]) };
const validRpc = { data: { ok: true, id: 'm-new' }, error: null, status: 200 };
const dup = { data: null, status: 400, error: { code: 'P0001', message: 'This code is already in use', details: '{"code":"duplicate","field":"code"}' } };

beforeEach(() => {
  mockReplace.mockReset();
  mockId = 'm-1';
});
jest.setTimeout(20_000);

describe('Add machine (AC-3)', () => {
  it('has labelled fields, line and status choices and a 48dp save', async () => {
    const { client } = plantClient(base);
    await renderWithSession(<NewMachine />, { ctx: admin, client });
    for (const l of ['Code', 'Name', 'Asset tag', 'Make', 'Model', 'Controller']) expect(screen.getByLabelText(l)).toBeTruthy();
    expect(await screen.findByTestId('machine-line-l-1')).toBeTruthy();
    expect(screen.getByTestId('machine-line-none')).toHaveTextContent('✓ No line');
    expect(screen.getByTestId('machine-status-active')).toHaveTextContent('✓ Active');
    expect(screen.getByTestId('machine-save')).toHaveStyle({ minHeight: 48 });
    expect(screen.queryByTestId('targets-panel')).toBeNull(); // targets need a saved machine
  });

  it('gives early feedback next to each field and sends nothing', async () => {
    const { client, rpc } = plantClient(base);
    await renderWithSession(<NewMachine />, { ctx: admin, client });
    await fireEvent.press(screen.getByTestId('machine-save'));
    expect(await screen.findByTestId('machine-code-error')).toHaveTextContent('Code: 1 to 20 letters, digits, - _ or /');
    expect(screen.getByTestId('machine-name-error')).toHaveTextContent('Enter a name of 1 to 80 characters');
    expect(rpc).not.toHaveBeenCalled();
  });

  it('creates the machine and opens its detail page', async () => {
    const { client, rpc } = plantClient(base, validRpc);
    await renderWithSession(<NewMachine />, { ctx: admin, client });
    await fireEvent.changeText(screen.getByLabelText('Code'), ' M-9 ');
    await fireEvent.changeText(screen.getByLabelText('Name'), 'Press 9');
    await fireEvent.changeText(screen.getByLabelText('Make'), 'Haitian');
    await fireEvent.press(await screen.findByTestId('machine-line-l-1'));
    await fireEvent.press(screen.getByTestId('machine-status-under_maintenance'));
    await fireEvent.press(screen.getByTestId('machine-save'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('pm_save_machine', {
      p_request_id: expect.stringMatching(/^[0-9a-f-]{36}$/), p_id: null, p_code: 'M-9', p_name: 'Press 9', p_asset_tag: '', p_make: 'Haitian', p_model: '',
      p_controller: '', p_line_id: 'l-1', p_status: 'under_maintenance',
    }));
    await waitFor(() => expect(mockReplace).toHaveBeenCalledWith('/plant/machines/m-new'));
  });

  it('shows a duplicate code from the server next to the Code field', async () => {
    const { client } = plantClient(base, dup);
    await renderWithSession(<NewMachine />, { ctx: admin, client });
    await fireEvent.changeText(screen.getByLabelText('Code'), 'M-1');
    await fireEvent.changeText(screen.getByLabelText('Name'), 'Press');
    await fireEvent.press(screen.getByTestId('machine-save'));
    expect(await screen.findByTestId('machine-code-error')).toHaveTextContent('This code is already in use');
    expect(mockReplace).not.toHaveBeenCalled();
  });

  it('reuses the request id when the same form is submitted again after a network failure', async () => {
    const { client, rpc } = plantClient(base);
    rpc.mockRejectedValueOnce(new TypeError('Failed to fetch')).mockResolvedValue(validRpc);
    await renderWithSession(<NewMachine />, { ctx: admin, client });
    await fireEvent.changeText(screen.getByLabelText('Code'), 'M-9');
    await fireEvent.changeText(screen.getByLabelText('Name'), 'Press 9');
    await fireEvent.press(screen.getByTestId('machine-save'));
    expect(await screen.findByTestId('machine-form-error')).toHaveTextContent(/Can't reach MouldTrack/);
    await fireEvent.press(screen.getByTestId('machine-save'));
    await waitFor(() => expect(rpc).toHaveBeenCalledTimes(2));
    expect((rpc.mock.calls[1] as unknown as [string, { p_request_id: string }])[1].p_request_id).toBe((rpc.mock.calls[0] as unknown as [string, { p_request_id: string }])[1].p_request_id);
  });

  it('shows a generic denial as Not allowed text', async () => {
    const { client } = plantClient(base, { data: { ok: false, code: 'not_allowed' }, error: null, status: 200 });
    await renderWithSession(<NewMachine />, { ctx: admin, client });
    await fireEvent.changeText(screen.getByLabelText('Code'), 'M-9');
    await fireEvent.changeText(screen.getByLabelText('Name'), 'Press 9');
    await fireEvent.press(screen.getByTestId('machine-save'));
    expect(await screen.findByTestId('machine-form-error')).toHaveTextContent('Not allowed');
  });
});

describe('Edit, retire and reinstate (AC-3)', () => {
  const edit = (m = machine(1, { line_id: 'l-1', make: 'Haitian' }), rpcResult?: unknown) =>
    plantClient({ ...base, machine: ok(m) }, rpcResult ?? { data: { ok: true, id: m.id }, error: null, status: 200 });

  it('loads the machine into the form, shows its status and the targets panel', async () => {
    const { client } = edit();
    await renderWithSession(<MachineDetail />, { ctx: admin, client });
    expect(await screen.findByTestId('machine-form')).toBeTruthy();
    expect(screen.getByLabelText('Code').props.value).toBe('M-1');
    expect(screen.getByLabelText('Make').props.value).toBe('Haitian');
    expect(screen.getByTestId('machine-line-l-1')).toHaveTextContent('✓ Line A');
    expect(screen.getByTestId('machine-status')).toHaveTextContent('Active');
    expect(await screen.findByTestId('targets-panel')).toBeTruthy();
  });

  it('saves changes with the machine id', async () => {
    const { client, rpc } = edit();
    await renderWithSession(<MachineDetail />, { ctx: admin, client });
    await screen.findByTestId('machine-form');
    await fireEvent.changeText(screen.getByLabelText('Name'), 'Press 1b');
    await fireEvent.press(screen.getByTestId('machine-save'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('pm_save_machine', expect.objectContaining({ p_id: 'm-1', p_name: 'Press 1b', p_code: 'M-1' })));
    expect(await screen.findByTestId('machine-saved')).toHaveTextContent('Saved');
  });

  it('names the machine in the retire dialog and does nothing until confirmed', async () => {
    const { client, rpc } = edit();
    await renderWithSession(<MachineDetail />, { ctx: admin, client });
    await screen.findByTestId('machine-form');
    await fireEvent.press(screen.getByTestId('machine-retire'));
    expect(screen.getByTestId('confirm-title')).toHaveTextContent('Retire M-1 · Press 1?');
    expect(rpc).not.toHaveBeenCalled();
    await fireEvent.press(screen.getByTestId('confirm-cancel'));
    expect(screen.queryByTestId('confirm-dialog')).toBeNull();
    expect(rpc).not.toHaveBeenCalled();
    await fireEvent.press(screen.getByTestId('machine-retire'));
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('pm_set_machine_retired', { p_request_id: expect.any(String), p_id: 'm-1', p_retired: true }));
  });

  it('a retired machine is read-only with Reinstate, a Retired label and no Save', async () => {
    const { client, rpc } = edit(machine(1, { retired_at: '2026-11-01T00:00:00Z' }));
    await renderWithSession(<MachineDetail />, { ctx: admin, client });
    await screen.findByTestId('machine-form');
    expect(screen.getByTestId('machine-status')).toHaveTextContent('Retired');
    expect(screen.getByTestId('machine-retired-note')).toBeTruthy();
    expect(screen.queryByTestId('machine-save')).toBeNull();
    expect(screen.queryByTestId('machine-retire')).toBeNull();
    expect(screen.getByLabelText('Name').props.editable).toBe(false);
    for (const id of ['machine-line-none', 'machine-status-active', 'machine-status-under_maintenance']) expect(screen.getByTestId(id)).toBeDisabled(); // R4 item 11
    expect(screen.queryByTestId('target-add')).toBeNull(); // no new targets for a retired machine
    await fireEvent.press(screen.getByTestId('machine-reinstate'));
    expect(screen.getByTestId('confirm-title')).toHaveTextContent('Reinstate M-1 · Press 1?');
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('pm_set_machine_retired', { p_request_id: expect.any(String), p_id: 'm-1', p_retired: false }));
  });

  it('shows Machine not found for an unknown id', async () => {
    const { client } = plantClient({ ...base, machine: ok(null) });
    await renderWithSession(<MachineDetail />, { ctx: admin, client });
    expect(await screen.findByTestId('machine-not-found')).toBeTruthy();
  });

  it('shows a load error with Try again', async () => {
    let fail = true;
    const { client } = plantClient({ ...base, machine: () => (fail ? { data: null, error: new TypeError('Failed to fetch') } : ok(machine(1))) });
    await renderWithSession(<MachineDetail />, { ctx: admin, client });
    expect(await screen.findByTestId('machine-form-load-error')).toBeTruthy();
    fail = false;
    await fireEvent.press(screen.getByTestId('machine-form-load-error-retry'));
    expect(await screen.findByTestId('machine-form')).toBeTruthy();
  });
});
