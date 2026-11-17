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
});
