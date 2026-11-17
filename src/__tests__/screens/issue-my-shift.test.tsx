import { fireEvent, screen } from '@testing-library/react-native';
import { router } from 'expo-router';
import Home from '@/app/(app)/home';
import { sup } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';
import { myShiftRunning, rpcOk, shiftClient } from '@/test/shift-fixtures';

jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: jest.fn() }, Redirect: () => null }));
jest.mock('@/lib/sentry', () => ({ sendTestError: jest.fn() }));
jest.setTimeout(20_000);

describe('Report issue from My shift (07)', () => {
  it('each machine row has a Report issue action that opens the form for that machine', async () => {
    const t = shiftClient({}, { my_shift: rpcOk(myShiftRunning) });
    await renderWithSession(<Home />, { ctx: sup, client: t.client });
    await fireEvent.press(await screen.findByTestId('report-issue-sh-1-m-1'));
    expect(router.push).toHaveBeenCalledWith({ pathname: '/issues/new', params: { machineId: 'm-1' } });
  });
  it('a supervisor has a My issues link on Home', async () => {
    const t = shiftClient({}, { my_shift: rpcOk(myShiftRunning) });
    await renderWithSession(<Home />, { ctx: sup, client: t.client });
    await fireEvent.press(await screen.findByTestId('issues-link'));
    expect(router.push).toHaveBeenCalledWith('/issues');
  });
});

describe('UA Home alerts (07)', () => {
  it('on the web a Unit Admin sees the alerts card; elsewhere Home makes no call (My shift rule)', async () => {
    const { Platform } = jest.requireActual('react-native');
    const { admin } = jest.requireActual('@/test/plant-fixtures');
    const original = Platform.OS;
    try {
      Platform.OS = 'web';
      const t = shiftClient({}, { issue_alerts: rpcOk({ ok: true, alert_count: 0, alerts: [], recently_closed: [] }) });
      await renderWithSession(<Home />, { ctx: admin, client: t.client });
      expect(await screen.findByTestId('issue-alerts-empty')).toBeTruthy();
      expect(t.rpc).toHaveBeenCalledWith('issue_alerts');
    } finally {
      Platform.OS = original;
    }
  });
});
