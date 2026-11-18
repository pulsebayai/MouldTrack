import { fireEvent, screen, waitFor } from '@testing-library/react-native';
import { router } from 'expo-router';
import { HandoverChecklist } from '@/components/handover/checklist';
import HandoverScreen from '@/app/(app)/handover';
import { checklist, hMachine, item, occurrence } from '@/test/handover-fixtures';
import { issue } from '@/test/issue-fixtures';
import { admin, sup } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';
import { rpcOk, shiftClient } from '@/test/shift-fixtures';

jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: jest.fn(), canGoBack: () => false, back: jest.fn() } }));
jest.setTimeout(20_000);

const guard = (message: string, code: string) => ({ data: null, status: 400, error: { code: 'P0001', message, details: JSON.stringify({ code: 'guard', field: code }) } });
const setup = (cl: unknown, rpcs: Record<string, unknown> = {}) => {
  const t = shiftClient({}, { handover_checklist: typeof cl === 'function' ? cl : rpcOk(cl), ...rpcs });
  return { ...t, ui: renderWithSession(<HandoverChecklist />, { ctx: sup, client: t.client }) };
};
const calls = (rpc: jest.Mock, fn: string) => rpc.mock.calls.filter((c) => c[0] === fn);
const OCC = 'sh-1:2026-11-18';

describe('Handover checklist (08)', () => {
  beforeEach(() => jest.clearAllMocks());

  it('lists each inherited issue by machine with its state as text, the previous owner, the latest actions and the outgoing note', async () => {
    const i1 = item(1, {
      last_actions: [{ type: 'note', notes: 'Checked the seal', at: '2026-11-17T08:00:00Z', actor_name: 'Ravi' }],
      note: { note: 'Oil level drops by noon', at: '2026-11-17T13:50:00Z', author_name: 'Ravi', shift_date: '2026-11-17' },
    });
    await setup(checklist([occurrence([hMachine([i1])])])).ui;
    expect(await screen.findByTestId(`ho-item-${i1.id}`)).toBeTruthy();
    expect(screen.getByTestId(`ho-machine-${OCC}-m-1`)).toHaveTextContent(/^M-1 · Press 1/);
    expect(screen.getByTestId(`ho-state-${i1.id}`)).toHaveTextContent('Not answered yet');
    expect(screen.getByTestId(`ho-note-${i1.id}`)).toHaveTextContent('Note from Ravi: Oil level drops by noon');
    expect(screen.getByTestId(`ho-actions-${i1.id}`)).toHaveTextContent(/Note added by Ravi .* Checked the seal/);
    expect(screen.getByText(/Handed over by Ravi/)).toBeTruthy();
    expect(screen.getByTestId(`ho-occ-status-${OCC}`)).toHaveTextContent('1 to answer');
    expect(screen.getByTestId(`ho-deadline-${OCC}`)).toHaveTextContent(/Answer by .* \(60 min after the handover starts\)/);
  });

  it('declare is offered only when the server allows it, and the opening hint shows while answers are missing', async () => {
    await setup(checklist([occurrence([hMachine([item(1)])])])).ui;
    await screen.findByTestId('ho-item-i-1');
    expect(screen.queryByTestId(`ho-declare-${OCC}`)).toBeNull();
    expect(screen.getByTestId(`ho-blocked-${OCC}`)).toHaveTextContent(/Answer every issue/);
  });

  it('acknowledges with an optional remark and refreshes', async () => {
    const { rpc, ui } = setup(checklist([occurrence([hMachine([item(1)])])]), { ho_acknowledge: rpcOk({ ok: true, id: 'a-1' }) });
    await ui;
    await fireEvent.press(await screen.findByTestId('ho-ack-i-1'));
    await fireEvent.changeText(screen.getByLabelText('Remark (optional)'), ' seen it ');
    await fireEvent.press(screen.getByTestId('ho-submit-i-1'));
    await waitFor(() => expect(calls(rpc, 'ho_acknowledge')).toHaveLength(1));
    expect(calls(rpc, 'ho_acknowledge')[0][1]).toEqual({ p_request_id: expect.any(String), p_issue_id: 'i-1', p_shift_id: 'sh-1', p_shift_date: '2026-11-18', p_remark: 'seen it' });
    await waitFor(() => expect(calls(rpc, 'handover_checklist').length).toBeGreaterThan(1));
    expect(screen.queryByTestId('ho-panel-i-1')).toBeNull();
  });

  it('refusing needs a reason: no call while it is empty or too long', async () => {
    const { rpc, ui } = setup(checklist([occurrence([hMachine([item(1)])])]));
    await ui;
    await fireEvent.press(await screen.findByTestId('ho-refuse-i-1'));
    await fireEvent.press(screen.getByTestId('ho-submit-i-1'));
    expect(await screen.findByTestId('ho-input-i-1-error')).toHaveTextContent('Enter a reason of 1 to 200 characters');
    await fireEvent.changeText(screen.getByLabelText('Reason for refusing'), 'x'.repeat(201));
    await fireEvent.press(screen.getByTestId('ho-submit-i-1'));
    expect(await screen.findByTestId('ho-input-i-1-error')).toBeTruthy();
    expect(calls(rpc, 'ho_refuse')).toHaveLength(0);
    await fireEvent.changeText(screen.getByLabelText('Reason for refusing'), 'This machine was never handed to me');
    await fireEvent.press(screen.getByTestId('ho-submit-i-1'));
    await waitFor(() => expect(calls(rpc, 'ho_refuse')).toHaveLength(1));
    expect(calls(rpc, 'ho_refuse')[0][1]).toMatchObject({ p_issue_id: 'i-1', p_reason: 'This machine was never handed to me' });
  });

  it('an answered item shows its state and offers no answer buttons; a refused one says it waits for the Unit Admin', async () => {
    const acked = item(1, { state: 'acknowledged', allowed_actions: [] });
    const refused = item(2, { state: 'refused', exception_pending: true, allowed_actions: [] });
    await setup(checklist([occurrence([hMachine([acked, refused])])])).ui;
    expect(await screen.findByTestId('ho-state-i-1')).toHaveTextContent('Acknowledged');
    expect(screen.getByTestId('ho-state-i-2')).toHaveTextContent('Refused - waiting for the Unit Admin');
    for (const id of ['i-1', 'i-2']) {
      expect(screen.queryByTestId(`ho-ack-${id}`)).toBeNull();
      expect(screen.queryByTestId(`ho-refuse-${id}`)).toBeNull();
    }
    expect(screen.getByTestId(`ho-declare-${OCC}`)).toBeTruthy();
  });

  it('declares when every issue is answered', async () => {
    const { rpc, ui } = setup(checklist([occurrence([hMachine([item(1, { state: 'acknowledged', allowed_actions: [] })])])]), { ho_declare: rpcOk({ ok: true, id: 'd-1' }) });
    await ui;
    await fireEvent.press(await screen.findByTestId(`ho-declare-${OCC}`));
    await waitFor(() => expect(calls(rpc, 'ho_declare')).toEqual([['ho_declare', { p_request_id: expect.any(String), p_shift_id: 'sh-1', p_shift_date: '2026-11-18' }]]));
  });

  it('with nothing inherited the supervisor can declare straight away', async () => {
    await setup(checklist([occurrence([])])).ui;
    expect(await screen.findByTestId(`ho-empty-${OCC}`)).toHaveTextContent('No unresolved issues were handed over to you');
    expect(screen.getByTestId(`ho-occ-status-${OCC}`)).toHaveTextContent('Nothing inherited');
    expect(screen.getByTestId(`ho-declare-${OCC}`)).toBeTruthy();
  });

  it('a declared occurrence says so and offers no declare', async () => {
    await setup(checklist([occurrence([], { declared: true, declared_at: '2026-11-18T00:45:00Z', allowed_actions: [] })])).ui;
    expect(await screen.findByTestId(`ho-declared-${OCC}`)).toHaveTextContent(/Declared 18 Nov/);
    expect(screen.getByTestId(`ho-occ-status-${OCC}`)).toHaveTextContent('Handover declared');
    expect(screen.queryByTestId(`ho-declare-${OCC}`)).toBeNull();
  });

  it('adds a note only where the server allows it and sends the trimmed text', async () => {
    const { rpc, ui } = setup(checklist([occurrence([hMachine([item(1), item(2, { allowed_actions: ['acknowledge', 'refuse'] })])])]), { ho_add_note: rpcOk({ ok: true, id: 'n-1' }) });
    await ui;
    expect(await screen.findByTestId('ho-add-note-i-1')).toBeTruthy();
    expect(screen.queryByTestId('ho-add-note-i-2')).toBeNull();
    await fireEvent.press(screen.getByTestId('ho-add-note-i-1'));
    await fireEvent.changeText(screen.getByLabelText('Note for the next shift'), ' check the oil ');
    await fireEvent.press(screen.getByTestId('ho-submit-i-1'));
    await waitFor(() => expect(calls(rpc, 'ho_add_note')).toHaveLength(1));
    expect(calls(rpc, 'ho_add_note')[0][1]).toMatchObject({ p_issue_id: 'i-1', p_note: 'check the oil' });
  });

  it('shows the server refusal (window closed) and reloads', async () => {
    const { rpc, ui } = setup(checklist([occurrence([hMachine([item(1)])])]), { ho_acknowledge: guard('The handover window (12 hours after the shift) has passed', 'window_closed') });
    await ui;
    await fireEvent.press(await screen.findByTestId('ho-ack-i-1'));
    await fireEvent.press(screen.getByTestId('ho-submit-i-1'));
    expect(await screen.findByTestId('handover-error')).toHaveTextContent('The handover window (12 hours after the shift) has passed');
    await waitFor(() => expect(calls(rpc, 'handover_checklist').length).toBeGreaterThan(1));
  });

  it('a retry after a failure reuses the request id (idempotent); a new text is a new request', async () => {
    let n = 0;
    const { rpc, ui } = setup(checklist([occurrence([hMachine([item(1)])])]), { ho_acknowledge: () => (++n === 1 ? { data: null, error: { message: 'Failed to fetch' }, status: 0 } : rpcOk({ ok: true, id: 'a', already: true })) });
    await ui;
    await fireEvent.press(await screen.findByTestId('ho-ack-i-1'));
    await fireEvent.press(screen.getByTestId('ho-submit-i-1'));
    await waitFor(() => expect(screen.getByTestId('handover-error')).toBeTruthy());
    expect(screen.getByTestId('ho-panel-i-1')).toBeTruthy(); // the panel stays open with what was typed
    await fireEvent.press(screen.getByTestId('ho-submit-i-1'));
    await waitFor(() => expect(calls(rpc, 'ho_acknowledge')).toHaveLength(2));
    const [a, b] = calls(rpc, 'ho_acknowledge').map((c) => (c[1] as { p_request_id: string }).p_request_id);
    expect(a).toBe(b);
  });

  it('lists the fixes waiting for verification apart from the checklist, and opens an issue', async () => {
    await setup(checklist([], { verify: [issue(7, { status: 'resolved', machine_code: 'M-7' })] })).ui;
    expect(await screen.findByTestId('ho-verify')).toHaveTextContent(/does not block your shift/);
    await fireEvent.press(screen.getByTestId('ho-verify-i-7'));
    expect(router.push).toHaveBeenCalledWith('/issues/i-7');
  });

  it('shows a retryable error, and an empty state', async () => {
    await setup(rpcOk({ ok: false, code: 'not_allowed' })).ui;
    expect(await screen.findByTestId('handover-load-error')).toBeTruthy();
    expect(screen.getByTestId('handover-load-error-retry')).toBeTruthy();
  });
  it('says so when there is no handover right now', async () => {
    await setup(checklist([])).ui;
    expect(await screen.findByTestId('handover-none')).toHaveTextContent('No handover to complete right now');
  });
});

describe('Handover screen', () => {
  it('is for supervisors: a Unit Admin sees Not allowed and makes no checklist call', async () => {
    const t = shiftClient({}, {});
    await renderWithSession(<HandoverScreen />, { ctx: admin, client: t.client });
    expect(screen.getByTestId('not-allowed')).toBeTruthy();
    expect(calls(t.rpc, 'handover_checklist')).toHaveLength(0);
  });
  it('renders the checklist for a supervisor', async () => {
    const t = shiftClient({}, { handover_checklist: rpcOk(checklist([])) });
    await renderWithSession(<HandoverScreen />, { ctx: sup, client: t.client });
    expect(await screen.findByTestId('handover-none')).toBeTruthy();
    await fireEvent.press(screen.getByTestId('handover-back'));
    expect(router.replace).toHaveBeenCalledWith('/home');
  });
});
