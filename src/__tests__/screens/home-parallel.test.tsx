import { waitFor } from '@testing-library/react-native';
import Home from '@/app/(app)/home';
import { sup } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';
import { myShiftRunning, rpcOk, shiftClient } from '@/test/shift-fixtures';

jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: jest.fn() }, Redirect: () => null }));
jest.mock('@/lib/sentry', () => ({ sendTestError: jest.fn() }));
jest.setTimeout(20_000);

describe('Supervisor Home reads are independent (screen-speed D2)', () => {
  it('my_shift is called while handover_checklist is still pending', async () => {
    const t = shiftClient({}, { handover_checklist: (() => new Promise(() => {})) as never, my_shift: rpcOk(myShiftRunning) });
    await renderWithSession(<Home />, { ctx: sup, client: t.client });
    await waitFor(() => expect(t.rpc.mock.calls.map((c) => c[0])).toContain('my_shift'));
    expect(t.rpc.mock.calls.map((c) => c[0])).toContain('handover_checklist');
  });
  it('and the other way round: the banner reads while my_shift is pending', async () => {
    const t = shiftClient({}, { my_shift: (() => new Promise(() => {})) as never, handover_checklist: rpcOk({ ok: true, occurrences: [], pending_total: 0, verify: [] }) });
    await renderWithSession(<Home />, { ctx: sup, client: t.client });
    await waitFor(() => expect(t.rpc.mock.calls.map((c) => c[0])).toEqual(expect.arrayContaining(['my_shift', 'handover_checklist'])));
  });
});
