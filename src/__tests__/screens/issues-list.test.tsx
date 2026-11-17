import { fireEvent, screen } from '@testing-library/react-native';
import { router } from 'expo-router';
import { IssueList } from '@/components/issues/issue-list';
import { issue } from '@/test/issue-fixtures';
import { admin, sup } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';
import { rpcOk, shiftClient } from '@/test/shift-fixtures';

jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: jest.fn() } }));
jest.setTimeout(20_000);

const page = (items: unknown[], total = items.length) => rpcOk({ ok: true, page: 1, page_size: 25, total, items });
const setup = (role: 'supervisor' | 'unit_admin', list: unknown) => {
  const t = shiftClient({}, { issue_list: list });
  return { ...t, ui: renderWithSession(<IssueList role={role} />, { ctx: role === 'unit_admin' ? admin : sup, client: t.client }) };
};

describe('Issue list', () => {
  beforeEach(() => jest.clearAllMocks());

  it('a supervisor sees My issues with words for every state and no Report/No-owner controls', async () => {
    await setup('supervisor', page([issue(1, { machine_stopped: true, escalated: true, status: 'in_progress', priority: 'critical' })])).ui;
    expect(await screen.findByText('My issues')).toBeTruthy();
    expect(screen.getByTestId('issue-row-i-1-priority')).toHaveTextContent('Critical');
    expect(screen.getByTestId('issue-row-i-1-status')).toHaveTextContent('In progress');
    expect(screen.getAllByText('Machine stopped').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Escalated').length).toBeGreaterThan(0);
    expect(screen.queryByTestId('issues-tab-needs_owner')).toBeNull();
    expect(screen.queryByTestId('issues-new')).toBeNull();
  });

  it('a Unit Admin can filter and report; the filters go to the server', async () => {
    const { rpc, ui } = setup('unit_admin', page([issue(1)]));
    await ui;
    expect(await screen.findByText('Issues')).toBeTruthy();
    expect(rpc).toHaveBeenLastCalledWith('issue_list', { p_filters: { status: 'not_closed' }, p_page: 1 });
    await fireEvent.press(screen.getByTestId('issues-tab-needs_owner'));
    await screen.findByTestId('issues-tab-needs_owner');
    expect(rpc).toHaveBeenLastCalledWith('issue_list', { p_filters: { status: 'not_closed', needs_owner: true }, p_page: 1 });
    await fireEvent.press(screen.getByTestId('issues-tab-closed'));
    await screen.findByTestId('issues-tab-closed');
    expect(rpc).toHaveBeenLastCalledWith('issue_list', { p_filters: { status: 'closed' }, p_page: 1 });
    await fireEvent.press(screen.getByTestId('issues-new'));
    expect(router.push).toHaveBeenCalledWith('/issues/new');
  });

  it('opens an issue and shows the empty state', async () => {
    await setup('unit_admin', page([issue(2)])).ui;
    await fireEvent.press(await screen.findByTestId('issue-row-i-2'));
    expect(router.push).toHaveBeenCalledWith('/issues/i-2');
  });

  it('says when there are none, and pages', async () => {
    await setup('supervisor', page([])).ui;
    expect(await screen.findByTestId('issues-empty')).toHaveTextContent('No issues here');
  });

  it('shows a retryable error when the read fails', async () => {
    await setup('supervisor', rpcOk({ ok: false, code: 'not_allowed' })).ui;
    expect(await screen.findByTestId('issues-error')).toBeTruthy();
    expect(screen.getByTestId('issues-error-retry')).toBeTruthy();
  });
});
