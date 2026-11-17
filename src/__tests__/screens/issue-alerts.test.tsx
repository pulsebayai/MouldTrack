import { act, fireEvent, screen } from '@testing-library/react-native';
import { router } from 'expo-router';
import { IssueAlertsCard } from '@/components/issue-alerts-card';
import { issue } from '@/test/issue-fixtures';
import { admin } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';
import { rpcOk, shiftClient } from '@/test/shift-fixtures';

jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: jest.fn() } }));
jest.setTimeout(20_000);

const alerts = (a: unknown[], closed: unknown[] = []) => rpcOk({ ok: true, alert_count: a.length, alerts: a, recently_closed: closed });
const setup = (v: unknown) => {
  const t = shiftClient({}, { issue_alerts: v });
  return { ...t, ui: renderWithSession(<IssueAlertsCard />, { ctx: admin, client: t.client }) };
};

describe('UA issue alerts card', () => {
  it('lists alerts in the server order (stopped machine first) with the count', async () => {
    await setup(alerts([issue(1, { machine_stopped: true, priority: 'critical' }), issue(2, { priority: 'high' })])).ui;
    expect(await screen.findByText('Issue alerts (2)')).toBeTruthy();
    const rows = screen.getAllByTestId(/^alert-i-\d$/);
    expect(rows.map((r) => r.props.testID)).toEqual(['alert-i-1', 'alert-i-2']);
    expect(screen.getByText('Machine stopped')).toBeTruthy();
  });

  it('shows what closed recently, and an empty state', async () => {
    await setup(alerts([], [issue(3, { status: 'closed', closed_at: '2026-11-16T10:00:00Z', closed_by_name: 'Ravi' })])).ui;
    expect(await screen.findByTestId('issue-alerts-empty')).toBeTruthy();
    expect(screen.getByTestId('closed-i-3')).toHaveTextContent(/Closed .* by Ravi/);
  });

  it('R6: the closed date is the plant day (23:59 UTC is already the next day in IST)', async () => {
    await setup(alerts([], [issue(3, { status: 'closed', closed_at: '2026-11-17T23:59:00Z', closed_by_name: 'Ravi' })])).ui;
    expect(await screen.findByTestId('closed-i-3')).toHaveTextContent(/Closed 18 Nov 2026 by Ravi/);
  });

  it('opens an alert and the full list', async () => {
    await setup(alerts([issue(1)])).ui;
    await fireEvent.press(await screen.findByTestId('alert-i-1'));
    expect(router.push).toHaveBeenCalledWith('/issues/i-1');
    await fireEvent.press(screen.getByTestId('issue-alerts-all'));
    expect(router.push).toHaveBeenCalledWith('/issues');
  });

  it('refetches every 60 s and keeps the last answer while loading', async () => {
    jest.useFakeTimers();
    try {
      const { rpc, ui } = setup(alerts([issue(1)]));
      await ui;
      expect(await screen.findByTestId('alert-i-1')).toBeTruthy();
      await act(async () => { jest.advanceTimersByTime(60_000); });
      expect(rpc).toHaveBeenCalledTimes(2);
      expect(screen.getByTestId('alert-i-1')).toBeTruthy();
    } finally {
      jest.useRealTimers();
    }
  });

  it('shows an error when the read fails', async () => {
    await setup(rpcOk({ ok: false, code: 'not_allowed' })).ui;
    expect(await screen.findByTestId('issue-alerts-error')).toBeTruthy();
  });

  describe('D16: the card is bounded', () => {
    const many = (n: number) => Array.from({ length: n }, (_, k) => issue(k + 1, { priority: 'high' }));
    it('0 alerts: the empty state and no link', async () => {
      await setup(alerts([])).ui;
      expect(await screen.findByTestId('issue-alerts-empty')).toBeTruthy();
      expect(screen.queryByTestId('issue-alerts-more')).toBeNull();
    });
    it('5 alerts: all five, no "more" link', async () => {
      await setup(alerts(many(5))).ui;
      expect(await screen.findByText('Issue alerts (5)')).toBeTruthy();
      expect(screen.getAllByTestId(/^alert-i-\d+$/)).toHaveLength(5);
      expect(screen.queryByTestId('issue-alerts-more')).toBeNull();
    });
    it('12 alerts: the first five in server order, the true count, and a link to all alerts', async () => {
      await setup(alerts(many(12))).ui;
      expect(await screen.findByText('Issue alerts (12)')).toBeTruthy();
      expect(screen.getAllByTestId(/^alert-i-\d+$/).map((r) => r.props.testID)).toEqual(['alert-i-1', 'alert-i-2', 'alert-i-3', 'alert-i-4', 'alert-i-5']);
      expect(screen.getByTestId('issue-alerts-more')).toHaveTextContent(/7 more/);
      await fireEvent.press(screen.getByTestId('issue-alerts-more'));
      expect(router.push).toHaveBeenCalledWith({ pathname: '/issues', params: { tab: 'alerts' } });
    });
    it('recently closed shows at most five and links to the Closed list', async () => {
      const closed = Array.from({ length: 8 }, (_, k) => issue(k + 20, { status: 'closed', closed_at: '2026-11-16T10:00:00Z' }));
      await setup(alerts([], closed)).ui;
      expect(await screen.findByTestId('issue-recently-closed')).toBeTruthy();
      expect(screen.getAllByTestId(/^closed-i-\d+$/)).toHaveLength(5);
      await fireEvent.press(screen.getByTestId('issue-closed-more'));
      expect(router.push).toHaveBeenCalledWith({ pathname: '/issues', params: { tab: 'closed' } });
    });
  });
});
