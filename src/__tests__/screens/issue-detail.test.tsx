import { fireEvent, screen, waitFor } from '@testing-library/react-native';
import { IssueDetailView } from '@/components/issues/issue-detail';
import { action, detail } from '@/test/issue-fixtures';
import { ok, rpcOk, shiftClient } from '@/test/shift-fixtures';
import { sup } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';

jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: jest.fn(), back: jest.fn(), canGoBack: () => false } }));
jest.mock('@/lib/photos', () => ({ ...jest.requireActual('@/lib/photos'), signedPhotoUrl: jest.fn(async () => 'https://signed/x'), pickPhoto: jest.fn(), uploadIssuePhoto: jest.fn() }));
jest.setTimeout(20_000);

function setup(d: unknown, rpcs: Record<string, unknown> = {}) {
  const t = shiftClient({ membership: ok([]) }, { issue_detail: d, ...rpcs });
  return { ...t, ui: renderWithSession(<IssueDetailView id="i-1" />, { ctx: sup, client: t.client }) };
}

describe('Issue detail', () => {
  beforeEach(() => jest.clearAllMocks());

  it('renders only the actions the server allows', async () => {
    await setup(rpcOk(detail(['note', 'photo', 'start', 'escalate']))).ui;
    expect(await screen.findByTestId('action-start')).toBeTruthy();
    for (const a of ['note', 'photo', 'escalate']) expect(screen.getByTestId(`action-${a}`)).toBeTruthy();
    for (const a of ['resolve', 'reassign', 'reopen', 'ack_escalation', 'set_assignee']) expect(screen.queryByTestId(`action-${a}`)).toBeNull();
    expect(screen.queryByTestId('verify-panel')).toBeNull();
  });

  it('shows the header, owner and the timeline with status words', async () => {
    await setup(rpcOk(detail(['note'], { machine_stopped: true, escalated: true, priority: 'critical' }, [
      action(1, 'report', { notes: 'Oil leak 1' }), action(2, 'start', { status_before: 'open', status_after: 'in_progress' }),
    ]))).ui;
    expect(await screen.findByTestId('issue-title')).toHaveTextContent('M-1 · Hydraulics');
    expect(screen.getByTestId('issue-priority')).toHaveTextContent('Critical');
    expect(screen.getByTestId('issue-stopped')).toHaveTextContent('Machine stopped');
    expect(screen.getByTestId('issue-escalated')).toHaveTextContent('Escalated');
    expect(screen.getByTestId('issue-owner')).toHaveTextContent('Owner: Asha');
    expect(screen.getByTestId('timeline-0-label')).toHaveTextContent('Reported');
    expect(screen.getByTestId('timeline-1-label')).toHaveTextContent('Work started');
    expect(screen.getByTestId('ownership-0')).toBeTruthy();
  });

  it('Start work calls the RPC and reloads', async () => {
    const { rpc, ui } = setup(rpcOk(detail(['start'])));
    await ui;
    await fireEvent.press(await screen.findByTestId('action-start'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('iss_start', expect.objectContaining({ p_issue_id: 'i-1' })));
    await waitFor(() => expect(rpc.mock.calls.filter((c) => c[0] === 'issue_detail').length).toBeGreaterThan(1));
  });

  it('Resolve needs notes, then sends them', async () => {
    const { rpc, ui } = setup(rpcOk(detail(['resolve'])));
    await ui;
    await fireEvent.press(await screen.findByTestId('action-resolve'));
    await fireEvent.press(screen.getByTestId('action-submit'));
    expect(screen.getByText('Enter notes of 1 to 1000 characters')).toBeTruthy();
    expect(rpc).not.toHaveBeenCalledWith('iss_resolve', expect.anything());
    await fireEvent.changeText(screen.getByTestId('action-text'), ' Replaced seal ');
    await fireEvent.press(screen.getByTestId('action-submit'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('iss_resolve', expect.objectContaining({ p_notes: 'Replaced seal' })));
  });

  it('Escalate sends the reason', async () => {
    const { rpc, ui } = setup(rpcOk(detail(['escalate'])));
    await ui;
    await fireEvent.press(await screen.findByTestId('action-escalate'));
    await fireEvent.changeText(screen.getByTestId('action-text'), 'Need maintenance now');
    await fireEvent.press(screen.getByTestId('action-submit'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('iss_escalate', expect.objectContaining({ p_reason: 'Need maintenance now' })));
  });

  it('Reassign requires choosing the new owner', async () => {
    const { rpc, ui } = setup(rpcOk(detail(['reassign'])));
    await ui;
    await fireEvent.press(await screen.findByTestId('action-reassign'));
    await fireEvent.changeText(screen.getByTestId('action-text'), 'Shift cover');
    await fireEvent.press(screen.getByTestId('action-submit'));
    expect(screen.getByText('Choose the new owner')).toBeTruthy();
    expect(rpc).not.toHaveBeenCalledWith('iss_reassign', expect.anything());
  });

  it('verify panel: confirm fixed, and not fixed needs a reason', async () => {
    const { rpc, ui } = setup(rpcOk(detail(['verify'], { status: 'resolved' })));
    await ui;
    expect(await screen.findByTestId('verify-panel')).toBeTruthy();
    await fireEvent.press(screen.getByTestId('verify-reject'));
    await fireEvent.press(screen.getByTestId('action-submit'));
    expect(screen.getByText('Enter a reason of 1 to 500 characters')).toBeTruthy();
    await fireEvent.changeText(screen.getByTestId('action-text'), 'Still leaking');
    await fireEvent.press(screen.getByTestId('action-submit'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('iss_verify', expect.objectContaining({ p_confirm: false, p_reason: 'Still leaking' })));
    await fireEvent.press(await screen.findByTestId('verify-confirm'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('iss_verify', expect.objectContaining({ p_confirm: true, p_reason: null })));
  });

  it('a refusal is shown and the state is reloaded', async () => {
    const { rpc, ui } = setup(rpcOk(detail(['start'])), { iss_start: rpcOk({ ok: false, code: 'not_allowed' }) });
    await ui;
    await fireEvent.press(await screen.findByTestId('action-start'));
    expect(await screen.findByTestId('action-error')).toHaveTextContent('Not allowed');
    await waitFor(() => expect(rpc.mock.calls.filter((c) => c[0] === 'issue_detail').length).toBeGreaterThan(1));
  });

  it('shows a photo from its signed URL', async () => {
    await setup(rpcOk(detail([], {}, [action(1, 'photo', { attachments: [{ id: 'at-1', path: 'tenant/t/issue/i/at-1.jpg', mime: 'image/jpeg', size_bytes: 10 }] })]))).ui;
    expect(await screen.findByTestId('photo-at-1')).toBeTruthy();
  });

  it('a read denial shows the retryable error', async () => {
    await setup(rpcOk({ ok: false, code: 'not_allowed' })).ui;
    expect(await screen.findByTestId('issue-error')).toBeTruthy();
  });
});
