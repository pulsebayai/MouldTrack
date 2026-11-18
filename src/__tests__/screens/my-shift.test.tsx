import { act, fireEvent, screen, waitFor } from '@testing-library/react-native';
import Home from '@/app/(app)/home';
import { admin, sup } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';
import { myShiftOccurrence, myShiftRunning, rpcOk, shiftClient } from '@/test/shift-fixtures';

jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: jest.fn() }, Redirect: () => null }));
jest.mock('@/lib/sentry', () => ({ sendTestError: jest.fn() }));
jest.setTimeout(20_000);

// Re-scoped (owner-approved 2026-11-18): these assertions are about the My shift card, so they count only
// `my_shift` calls — other Home features may make their own calls without breaking the card's tests.
const myShiftCalls = (rpc: jest.Mock) => rpc.mock.calls.filter((c) => c[0] === 'my_shift').length;

const render = (my: unknown, ctx: typeof sup | typeof admin = sup) => {
  const t = shiftClient({}, { my_shift: typeof my === 'function' ? my : rpcOk(my) });
  return { ...t, ui: renderWithSession(<Home />, { ctx, client: t.client }) };
};

describe('My shift card (AC-9)', () => {
  it('shows the running shift and my machines', async () => {
    await render(myShiftRunning).ui;
    expect(await screen.findByTestId('my-shift-state-0')).toHaveTextContent('Running now');
    expect(screen.getByTestId('my-shift-name-0')).toHaveTextContent('Morning · 06:00 – 14:00');
    expect(screen.getByTestId('my-shift-machine-sh-1-m-1')).toHaveTextContent('M-1 · Press 1 · Line A');
  });

  it('shows the next shift with its date', async () => {
    await render({ ok: true, state: 'next', occurrences: [myShiftOccurrence({ running: false, shift_date: '2026-11-19' })] }).ui;
    expect(await screen.findByTestId('my-shift-state-0')).toHaveTextContent('Starts 19 Nov 2026');
  });

  it('R3: lists every running occurrence, each with its own machines', async () => {
    const b = myShiftOccurrence({ shift: { id: 'sh-2', name: 'Day', start_time: '10:00:00', end_time: '18:00:00' }, machines: [{ machine_id: 'm-1', code: 'M-1', name: 'Press 1', line: null }, { machine_id: 'm-2', code: 'M-2', name: 'Press 2', line: null }] });
    await render({ ok: true, state: 'running', occurrences: [myShiftOccurrence(), b] }).ui;
    expect(await screen.findByTestId('my-shift-name-1')).toHaveTextContent('Day · 10:00 – 18:00');
    expect(screen.getByTestId('my-shift-state-0')).toHaveTextContent('Running now');
    expect(screen.getByTestId('my-shift-state-1')).toHaveTextContent('Running now');
    expect(screen.getByTestId('my-shift-machine-sh-1-m-1')).toBeTruthy();
    expect(screen.getByTestId('my-shift-machine-sh-2-m-1')).toBeTruthy();
    expect(screen.getByTestId('my-shift-machine-sh-2-m-2')).toBeTruthy();
  });

  it('R8: refetches every 60 s and keeps showing the last answer meanwhile', async () => {
    jest.useFakeTimers();
    try {
      let resolve!: (v: unknown) => void;
      let n = 0;
      const { rpc, ui } = render((() => (++n === 1 ? rpcOk(myShiftRunning) : new Promise((r) => (resolve = r)))) as never);
      await ui;
      expect(await screen.findByTestId('my-shift-state-0')).toBeTruthy();
      await act(async () => { jest.advanceTimersByTime(60_000); });
      expect(myShiftCalls(rpc)).toBe(2);
      expect(screen.getByTestId('my-shift-state-0')).toBeTruthy();
      expect(screen.queryByTestId('my-shift-loading')).toBeNull();
      await act(async () => resolve(rpcOk({ ok: true, state: 'none', occurrences: [] })));
      expect(await screen.findByTestId('my-shift-none')).toBeTruthy();
    } finally {
      jest.useRealTimers();
    }
  });

  it('says when nothing is assigned for the next shift', async () => {
    await render({ ok: true, state: 'none', occurrences: [] }).ui;
    expect(await screen.findByTestId('my-shift-none')).toHaveTextContent('No machines assigned in the next 36 hours');
  });

  it('says when no shifts are set up', async () => {
    await render({ ok: true, state: 'no_shifts' }).ui;
    expect(await screen.findByTestId('my-shift-no-shifts')).toHaveTextContent('No shifts set up yet');
  });

  it('shows a loading state while the shift is being read', async () => {
    let resolve!: (v: unknown) => void;
    await render((() => new Promise((r) => (resolve = r))) as never).ui;
    expect(screen.getByTestId('my-shift-loading')).toHaveProp('accessibilityLiveRegion', 'polite');
    await act(async () => resolve(rpcOk({ ok: true, state: 'none' })));
    expect(await screen.findByTestId('my-shift-none')).toBeTruthy();
  });

  it('shows a denial as an error and refreshes', async () => {
    let denied = true;
    const { rpc, ui } = render(() => (denied ? { data: { ok: false, code: 'not_allowed' }, error: null, status: 200 } : rpcOk({ ok: true, state: 'none' })));
    await ui;
    expect(await screen.findByTestId('my-shift-error')).toBeTruthy();
    denied = false;
    await fireEvent.press(screen.getByTestId('my-shift-refresh'));
    expect(await screen.findByTestId('my-shift-none')).toBeTruthy();
    await waitFor(() => expect(myShiftCalls(rpc)).toBe(2));
  });

  it('is not shown to a Unit Admin and makes no my_shift call for one', async () => {
    const { rpc, ui } = render({ ok: true, state: 'none' }, admin);
    await ui;
    expect(screen.queryByTestId('my-shift')).toBeNull();
    expect(myShiftCalls(rpc)).toBe(0);
  });
});
