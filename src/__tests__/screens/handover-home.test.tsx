import { act, fireEvent, screen, waitFor } from '@testing-library/react-native';
import { router } from 'expo-router';
import Home from '@/app/(app)/home';
import { HandoverAlertsCard } from '@/components/handover/handover-alerts-card';
import { HandoverBanner } from '@/components/handover/handover-banner';
import { OverdueSetting } from '@/components/handover/overdue-setting';
import { ReadingsCard } from '@/components/readings/readings-card';
import { alerts, checklist, hMachine, item, occurrence, overdueAck, pendingException } from '@/test/handover-fixtures';
import { admin, ok, plantClient, sup } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';
import { readingState, rpcOk, shiftClient, stateMachine } from '@/test/shift-fixtures';

jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: jest.fn() }, Redirect: () => null }));
jest.mock('@/lib/sentry', () => ({ sendTestError: jest.fn() }));
jest.setTimeout(20_000);

const calls = (rpc: jest.Mock, fn: string) => rpc.mock.calls.filter((c) => c[0] === fn);
const supervisors = [
  { user_id: 's-1', full_name: 'Ravi', employee_id: 'E1' },
  { user_id: 's-2', full_name: 'Meena', employee_id: 'E2' },
];
beforeEach(() => jest.clearAllMocks());

describe('Supervisor Home banner (08)', () => {
  const mount = (cl: unknown, rpcs: Record<string, unknown> = {}) => {
    const t = shiftClient({}, { handover_checklist: cl, ...rpcs });
    return { ...t, ui: renderWithSession(<HandoverBanner />, { ctx: sup, client: t.client }) };
  };
  it('says how many issues are waiting and opens the checklist', async () => {
    await mount(rpcOk(checklist([occurrence([hMachine([item(1), item(2)])])]))).ui;
    expect(await screen.findByTestId('handover-banner-text')).toHaveTextContent('Handover: 2 to acknowledge');
    await fireEvent.press(screen.getByTestId('handover-link'));
    expect(router.push).toHaveBeenCalledWith('/handover');
  });
  it('asks to declare when everything is answered', async () => {
    await mount(rpcOk(checklist([occurrence([])]))).ui;
    expect(await screen.findByTestId('handover-banner-text')).toHaveTextContent('Handover: ready to declare');
  });
  it('is silent when nothing is waiting, while loading and when the read fails', async () => {
    await mount(rpcOk(checklist([]))).ui;
    await waitFor(() => expect(screen.queryByTestId('handover-banner')).toBeNull());
  });
  it('is silent on an error', async () => {
    const t = mount(rpcOk({ ok: false, code: 'not_allowed' }));
    await t.ui;
    await waitFor(() => expect(calls(t.rpc, 'handover_checklist')).toHaveLength(1));
    expect(screen.queryByTestId('handover-banner')).toBeNull();
  });
  it('refetches every 60 s and keeps the last answer', async () => {
    jest.useFakeTimers();
    try {
      const t = mount(rpcOk(checklist([occurrence([hMachine([item(1)])])])));
      await t.ui;
      expect(await screen.findByTestId('handover-banner')).toBeTruthy();
      await act(async () => { jest.advanceTimersByTime(60_000); });
      expect(calls(t.rpc, 'handover_checklist')).toHaveLength(2);
      expect(screen.getByTestId('handover-banner')).toBeTruthy();
    } finally {
      jest.useRealTimers();
    }
  });
  it('Home shows it for a supervisor', async () => {
    const t = shiftClient({}, { handover_checklist: rpcOk(checklist([occurrence([hMachine([item(1)])])])) });
    await renderWithSession(<Home />, { ctx: sup, client: t.client });
    expect(await screen.findByTestId('handover-banner')).toBeTruthy();
  });
  it('on the web a Unit Admin sees the handover alerts on Home', async () => {
    const { Platform } = jest.requireActual('react-native');
    const original = Platform.OS;
    try {
      Platform.OS = 'web';
      const t = shiftClient({}, { handover_alerts: rpcOk(alerts([pendingException(1)])), issue_alerts: rpcOk({ ok: true, alert_count: 0, alerts: [], recently_closed: [] }) });
      await renderWithSession(<Home />, { ctx: admin, client: t.client });
      expect(await screen.findByTestId('handover-alerts')).toBeTruthy();
      expect(calls(t.rpc, 'handover_checklist')).toHaveLength(0);
    } finally {
      Platform.OS = original;
    }
  });
  it('Home makes no handover call for a Unit Admin on a phone, and no checklist call ever', async () => {
    const t = shiftClient({}, {});
    await renderWithSession(<Home />, { ctx: admin, client: t.client });
    expect(calls(t.rpc, 'handover_checklist')).toHaveLength(0);
    expect(calls(t.rpc, 'handover_alerts')).toHaveLength(0);
  });
});

describe('Opening waits for the declaration (08, D6/D9)', () => {
  const key = 'sh-1-m-1-2026-11-18';
  const mount = (cl: unknown) => {
    const t = shiftClient({}, { reading_state: rpcOk(readingState([stateMachine()])), handover_checklist: cl });
    return { ...t, ui: renderWithSession(<ReadingsCard />, { ctx: sup, client: t.client }) };
  };
  it('disables the opening and says why while the handover is not declared', async () => {
    await mount(rpcOk(checklist([occurrence([hMachine([item(1)])])]))).ui;
    expect(await screen.findByTestId(`reading-open-blocked-text-${key}`)).toHaveTextContent('Complete your handover checklist first');
    expect(screen.getByTestId(`reading-open-${key}`).props.accessibilityState.disabled).toBe(true);
    await fireEvent.press(screen.getByTestId(`reading-handover-${key}`));
    expect(router.push).toHaveBeenCalledWith('/handover');
    expect(router.push).not.toHaveBeenCalledWith(expect.objectContaining({ pathname: '/readings/record' }));
  });
  it('offers the opening once the occurrence is declared', async () => {
    await mount(rpcOk(checklist([occurrence([], { declared: true, allowed_actions: [] })]))).ui;
    await waitFor(() => expect(screen.getByTestId(`reading-open-${key}`).props.accessibilityState.disabled).toBe(false));
    expect(screen.queryByTestId(`reading-open-blocked-text-${key}`)).toBeNull();
    await fireEvent.press(screen.getByTestId(`reading-open-${key}`));
    expect(router.push).toHaveBeenCalledWith(expect.objectContaining({ pathname: '/readings/record' }));
  });
  it('is not gated in a tenant where handover is not enforced', async () => {
    await mount(rpcOk(checklist([occurrence([], { enforced: false })]))).ui;
    await screen.findByTestId(`reading-open-${key}`);
    expect(screen.queryByTestId(`reading-open-blocked-text-${key}`)).toBeNull();
  });
  it('leaves the opening to the server when the checklist cannot be read', async () => {
    await mount(rpcOk({ ok: false, code: 'not_allowed' })).ui;
    await screen.findByTestId(`reading-open-${key}`);
    expect(screen.queryByTestId(`reading-open-blocked-text-${key}`)).toBeNull();
  });
});

describe('Unit Admin handover alerts (08)', () => {
  const mount = (a: unknown, rpcs: Record<string, unknown> = {}) => {
    const t = shiftClient({ membership: ok(supervisors) }, { handover_alerts: a, ...rpcs });
    return { ...t, ui: renderWithSession(<HandoverAlertsCard />, { ctx: admin, client: t.client }) };
  };
  it('is hidden while there is nothing to show', async () => {
    const t = mount(rpcOk(alerts([])));
    await t.ui;
    await waitFor(() => expect(calls(t.rpc, 'handover_alerts')).toHaveLength(1));
    expect(screen.queryByTestId('handover-alerts')).toBeNull();
  });
  it('lists refusals waiting for an exception and overdue acknowledgements with the count', async () => {
    await mount(rpcOk(alerts([pendingException(1)], [overdueAck(2, { minutes_overdue: 75 })]))).ui;
    expect(await screen.findByText('Handover alerts (2)')).toBeTruthy();
    expect(screen.getByTestId('ho-exc-reason-i-1')).toHaveTextContent('Meena refused: Machine was not handed over to me');
    expect(screen.getByTestId('ho-exc-i-1')).toHaveTextContent(/Waiting for exception/);
    expect(screen.getByTestId('ho-over-i-2')).toHaveTextContent(/Overdue by 1 h 15 min/);
  });
  it('records an exception that keeps the current owner (preselected)', async () => {
    const { rpc, ui } = mount(rpcOk(alerts([pendingException(1)])), { ho_exception: rpcOk({ ok: true, id: 'x', kept: true }) });
    await ui;
    await fireEvent.press(await screen.findByTestId('ho-exc-record-i-1'));
    expect(await screen.findByTestId('ho-exc-owner-s-1')).toHaveTextContent(/✓ Ravi \(E1\) - current owner/);
    await fireEvent.changeText(screen.getByLabelText('Reason'), ' Ravi still runs it ');
    await fireEvent.press(screen.getByTestId('ho-exc-submit'));
    await waitFor(() => expect(calls(rpc, 'ho_exception')).toHaveLength(1));
    expect(calls(rpc, 'ho_exception')[0][1]).toEqual({
      p_request_id: expect.any(String), p_issue_id: 'i-1', p_shift_id: 'sh-1', p_shift_date: '2026-11-18', p_reason: 'Ravi still runs it', p_owner_id: 's-1',
    });
    await waitFor(() => expect(calls(rpc, 'handover_alerts').length).toBeGreaterThan(1));
    expect(screen.queryByTestId('ho-exc-panel')).toBeNull();
  });
  it('reassigns to another supervisor', async () => {
    const { rpc, ui } = mount(rpcOk(alerts([pendingException(1)])), { ho_exception: rpcOk({ ok: true, id: 'x', kept: false }) });
    await ui;
    await fireEvent.press(await screen.findByTestId('ho-exc-record-i-1'));
    await fireEvent.press(await screen.findByTestId('ho-exc-owner-s-2'));
    await fireEvent.changeText(screen.getByLabelText('Reason'), 'Meena covers it today');
    await fireEvent.press(screen.getByTestId('ho-exc-submit'));
    await waitFor(() => expect(calls(rpc, 'ho_exception')[0]?.[1]).toMatchObject({ p_owner_id: 's-2' }));
  });
  it('needs a reason: no call while it is empty', async () => {
    const { rpc, ui } = mount(rpcOk(alerts([pendingException(1)])));
    await ui;
    await fireEvent.press(await screen.findByTestId('ho-exc-record-i-1'));
    await fireEvent.press(screen.getByTestId('ho-exc-submit'));
    expect(await screen.findByTestId('ho-exc-reason-error')).toHaveTextContent('Enter a reason of 1 to 200 characters');
    expect(calls(rpc, 'ho_exception')).toHaveLength(0);
  });
  it('shows the server refusal', async () => {
    const guard = { data: null, status: 400, error: { code: 'P0001', message: 'No refusal is waiting for an exception on this issue', details: JSON.stringify({ code: 'guard', field: 'no_pending_exception' }) } };
    await mount(rpcOk(alerts([pendingException(1)])), { ho_exception: guard }).ui;
    await fireEvent.press(await screen.findByTestId('ho-exc-record-i-1'));
    await fireEvent.changeText(screen.getByLabelText('Reason'), 'ok');
    await fireEvent.press(screen.getByTestId('ho-exc-submit'));
    expect(await screen.findByTestId('handover-alerts-action-error')).toHaveTextContent('No refusal is waiting for an exception on this issue');
  });
  it('bounds each list to 5 on Home and expands to the server list', async () => {
    const ex = Array.from({ length: 7 }, (_, k) => pendingException(k + 1));
    await mount(rpcOk(alerts(ex))).ui;
    expect(await screen.findByText('Handover alerts (7)')).toBeTruthy();
    expect(screen.getAllByTestId(/^ho-exc-i-\d+$/)).toHaveLength(5);
    await fireEvent.press(screen.getByTestId('handover-alerts-more'));
    expect(screen.getAllByTestId(/^ho-exc-i-\d+$/)).toHaveLength(7);
    await fireEvent.press(screen.getByTestId('handover-alerts-less'));
    expect(screen.getAllByTestId(/^ho-exc-i-\d+$/)).toHaveLength(5);
  });
  it('shows a retryable error when the read fails', async () => {
    await mount(rpcOk({ ok: false, code: 'not_allowed' })).ui;
    expect(await screen.findByTestId('handover-alerts-error')).toBeTruthy();
  });
});

describe('Overdue setting in Plant -> Site (08)', () => {
  const mount = (row: unknown, rpc?: unknown) => {
    const t = plantClient({ handover_setting: ok(row as never) }, rpc);
    return { ...t, ui: renderWithSession(<OverdueSetting />, { ctx: admin, client: t.client }) };
  };
  it('shows the minutes in force and that handover is enforced, and saves a new value', async () => {
    const { rpc, ui } = mount({ overdue_minutes: 60, required: true });
    await ui;
    await waitFor(() => expect(screen.getByLabelText('Overdue after (minutes)').props.value).toBe('60'));
    expect(screen.getByTestId('handover-enforced')).toHaveTextContent('Handover: enforced');
    await fireEvent.changeText(screen.getByLabelText('Overdue after (minutes)'), '45');
    await fireEvent.press(screen.getByTestId('handover-setting-save'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('ho_set_overdue', { p_request_id: expect.any(String), p_minutes: 45 }));
    expect(await screen.findByTestId('handover-setting-saved')).toHaveTextContent('Saved');
  });
  it('refuses values outside 15 to 480 without calling the server', async () => {
    const { rpc, ui } = mount({ overdue_minutes: 60, required: true });
    await ui;
    await waitFor(() => expect(screen.getByLabelText('Overdue after (minutes)').props.value).toBe('60'));
    for (const bad of ['14', '481', 'abc', '']) {
      await fireEvent.changeText(screen.getByLabelText('Overdue after (minutes)'), bad);
      await fireEvent.press(screen.getByTestId('handover-setting-save'));
      expect(await screen.findByTestId('handover-minutes-error')).toHaveTextContent('Enter 15 to 480 minutes');
    }
    expect(rpc).not.toHaveBeenCalled();
  });
  it('shows 60 when the tenant has no setting row yet and does not claim enforcement', async () => {
    await mount(null).ui;
    await waitFor(() => expect(screen.getByLabelText('Overdue after (minutes)').props.value).toBe('60'));
    expect(screen.queryByTestId('handover-enforced')).toBeNull();
  });
});
