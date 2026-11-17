import { act, fireEvent, screen, waitFor } from '@testing-library/react-native';
import Home from '@/app/(app)/home';
import { admin, sup } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';
import { myShiftRunning, rpcOk, shiftClient } from '@/test/shift-fixtures';

jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: jest.fn() }, Redirect: () => null }));
jest.mock('@/lib/sentry', () => ({ sendTestError: jest.fn() }));
jest.setTimeout(20_000);

const render = (my: unknown, ctx: typeof sup | typeof admin = sup) => {
  const t = shiftClient({}, { my_shift: typeof my === 'function' ? my : rpcOk(my) });
  return { ...t, ui: renderWithSession(<Home />, { ctx, client: t.client }) };
};

describe('My shift card (AC-9)', () => {
  it('shows the running shift and my machines', async () => {
    await render(myShiftRunning).ui;
    expect(await screen.findByTestId('my-shift-state')).toHaveTextContent('Running now');
    expect(screen.getByTestId('my-shift-name')).toHaveTextContent('Morning · 06:00 – 14:00');
    expect(screen.getByTestId('my-shift-machine-m-1')).toHaveTextContent('M-1 · Press 1 · Line A');
  });

  it('shows the next shift with its date', async () => {
    await render({ ...myShiftRunning, state: 'next', shift_date: '2026-11-19' }).ui;
    expect(await screen.findByTestId('my-shift-state')).toHaveTextContent('Starts 19 Nov 2026');
  });

  it('says when nothing is assigned for the next shift', async () => {
    await render({ ok: true, state: 'none' }).ui;
    expect(await screen.findByTestId('my-shift-none')).toHaveTextContent('No machines assigned for your next shift');
  });

  it('says when no shifts are set up', async () => {
    await render({ ok: true, state: 'no_shifts' }).ui;
    expect(await screen.findByTestId('my-shift-no-shifts')).toHaveTextContent('No shifts set up yet');
  });

  it('shows a loading state while the shift is being read', async () => {
    let resolve!: (v: unknown) => void;
    await render((() => new Promise((r) => (resolve = r))) as never).ui;
    expect(screen.getByTestId('my-shift-loading')).toBeTruthy();
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
    await waitFor(() => expect(rpc).toHaveBeenCalledTimes(2));
  });

  it('is not shown to a Unit Admin and makes no call for one', async () => {
    const { rpc, ui } = render({ ok: true, state: 'none' }, admin);
    await ui;
    expect(screen.queryByTestId('my-shift')).toBeNull();
    expect(rpc).not.toHaveBeenCalled();
  });
});
