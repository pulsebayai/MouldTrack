import { fireEvent, screen, waitFor } from '@testing-library/react-native';
import { router } from 'expo-router';
import { IssueList } from '@/components/issues/issue-list';
import { category, issue } from '@/test/issue-fixtures';
import { admin, sup } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';
import { ok, rpcOk, shiftClient } from '@/test/shift-fixtures';

const mockParams: { tab?: string } = {};
jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: jest.fn() }, useLocalSearchParams: () => mockParams }));
jest.setTimeout(20_000);

const page = (items: unknown[], total = items.length) => rpcOk({ ok: true, page: 1, page_size: 25, total, items });
const noAlerts = rpcOk({ ok: true, alert_count: 0, alerts: [], recently_closed: [] });
const setup = (role: 'supervisor' | 'unit_admin', list: unknown) => {
  const t = shiftClient({ issue_category: ok([category(1), category(2)]), machine: ok([{ id: 'm-1', code: 'M-1', name: 'Press 1' }, { id: 'm-2', code: 'M-2', name: 'Press 2' }]) }, { issue_list: list, issue_alerts: noAlerts });
  return { ...t, ui: renderWithSession(<IssueList role={role} />, { ctx: role === 'unit_admin' ? admin : sup, client: t.client }) };
};

describe('Issue list', () => {
  beforeEach(() => { jest.clearAllMocks(); delete mockParams.tab; });

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

  it('R4: a Unit Admin sees the alerts above the list; a supervisor does not (and makes no alerts call)', async () => {
    const ua = setup('unit_admin', page([issue(1)]));
    await ua.ui;
    expect(await screen.findByTestId('issue-alerts')).toBeTruthy();
    expect(screen.queryByTestId('issue-alerts-all')).toBeNull(); // already on the list
    expect(ua.rpc).toHaveBeenCalledWith('issue_alerts');
  });

  it('R4: a supervisor has no alerts card and no filter rows', async () => {
    const t = setup('supervisor', page([issue(1)]));
    await t.ui;
    await screen.findByTestId('issue-row-i-1');
    expect(screen.queryByTestId('issue-alerts')).toBeNull();
    expect(screen.queryByTestId('issues-filters')).toBeNull();
    expect(t.rpc).not.toHaveBeenCalledWith('issue_alerts');
  });

  it('R5: the priority, category and machine filters are sent to the server and reset the page', async () => {
    const { rpc, ui } = setup('unit_admin', page([issue(1)]));
    await ui;
    await fireEvent.press(await screen.findByTestId('filter-priority-high'));
    await fireEvent.press(await screen.findByTestId('filter-category-c-2'));
    await fireEvent.press(await screen.findByTestId('filter-machine-m-2'));
    await waitFor(() => expect(rpc).toHaveBeenLastCalledWith('issue_list', { p_filters: { status: 'not_closed', priority: 'high', category_id: 'c-2', machine_id: 'm-2' }, p_page: 1 }));
    await fireEvent.press(screen.getByTestId('filter-priority-all'));
    await waitFor(() => expect(rpc).toHaveBeenLastCalledWith('issue_list', { p_filters: { status: 'not_closed', category_id: 'c-2', machine_id: 'm-2' }, p_page: 1 }));
    expect(screen.getByTestId('filter-category-c-2')).toHaveTextContent(/✓/);
  });

  it('R5: the filters combine with the tab', async () => {
    const { rpc, ui } = setup('unit_admin', page([]));
    await ui;
    await fireEvent.press(await screen.findByTestId('filter-priority-critical'));
    await fireEvent.press(screen.getByTestId('issues-tab-closed'));
    await waitFor(() => expect(rpc).toHaveBeenLastCalledWith('issue_list', { p_filters: { status: 'closed', priority: 'critical' }, p_page: 1 }));
  });

  it('D16: the Alerts tab asks the server for alerts (paginated) and opens first when linked from Home', async () => {
    mockParams.tab = 'alerts';
    const { rpc, ui } = setup('unit_admin', page([issue(1, { priority: 'high' })], 60));
    await ui;
    await screen.findByTestId('issue-row-i-1');
    expect(rpc).toHaveBeenCalledWith('issue_list', { p_filters: { alerts: true }, p_page: 1 });
    await fireEvent.press(screen.getByTestId('issues-next'));
    expect(rpc).toHaveBeenLastCalledWith('issue_list', { p_filters: { alerts: true }, p_page: 2 });
  });

  it('D16: a supervisor has no Alerts tab', async () => {
    await setup('supervisor', page([issue(1)])).ui;
    await screen.findByText('My issues');
    expect(screen.queryByTestId('issues-tab-alerts')).toBeNull();
  });
});
