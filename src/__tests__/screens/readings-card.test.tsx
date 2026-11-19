import { fireEvent, screen } from '@testing-library/react-native';
import { router } from 'expo-router';
import { ReadingsCard } from '@/components/readings/readings-card';
import { sup } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';
import { readingState, rpcOk, shiftClient, stateMachine } from '@/test/shift-fixtures';

jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: jest.fn() }, Redirect: () => null }));
jest.setTimeout(20_000);

const render = (state: unknown) => {
  const t = shiftClient({}, { reading_state: typeof state === 'function' ? state : rpcOk(state) });
  return { ...t, ui: renderWithSession(<ReadingsCard />, { ctx: sup, client: t.client }) };
};
const key = 'sh-1-m-1-2026-11-18';

describe('Readings card (AC-11)', () => {
  beforeEach(() => jest.clearAllMocks());

  it('offers the opening reading when it is due, with the state as text', async () => {
    await render(readingState([stateMachine()])).ui;
    expect(await screen.findByTestId(`reading-state-${key}`)).toHaveTextContent(/Opening reading due/);
    await fireEvent.press(screen.getByTestId(`reading-open-${key}`));
    expect(router.push).toHaveBeenCalledWith({ pathname: '/readings/record', params: { machineId: 'm-1', shiftId: 'sh-1', date: '2026-11-18', kind: 'opening' } });
    expect(screen.queryByTestId(`reading-close-${key}`)).toBeNull();
  });

  it('labels every state line with the machine code, so one machine can be addressed by its code (Maestro N3)', async () => {
    await render(readingState([stateMachine()])).ui;
    const state = await screen.findByTestId(`reading-state-${key}`);
    expect(state.props.accessibilityLabel).toBe(`${stateMachine().code}: Opening reading due`);
    expect(state).toHaveTextContent(/^Opening reading due$/);
  });

  it('offers only what the server allows: closing after an opening', async () => {
    const opening = { id: 'r-1', counter: 10, product_id: 'p-1', product_code: 'P-1', recorded_at: '2026-11-18T00:40:00Z', late: false, entered_by_ua: false, remarks: null };
    await render(readingState([stateMachine({ state: 'opening_done', can_open: false, can_close: true, opening })])).ui;
    expect(await screen.findByTestId(`reading-state-${key}`)).toHaveTextContent(/Opening recorded/);
    expect(screen.queryByTestId(`reading-open-${key}`)).toBeNull();
    await fireEvent.press(screen.getByTestId(`reading-close-${key}`));
    expect(router.push).toHaveBeenCalledWith({ pathname: '/readings/record', params: expect.objectContaining({ kind: 'closing' }) });
    await fireEvent.press(screen.getByTestId(`reading-details-${key}`));
    expect(router.push).toHaveBeenLastCalledWith({ pathname: '/readings/occurrence', params: { machineId: 'm-1', shiftId: 'sh-1', date: '2026-11-18' } });
  });

  it('R7: shows the opening time in plant time and Late while the closing is still due', async () => {
    const opening = { id: 'r-1', counter: 10, product_id: 'p-1', product_code: 'P-1', recorded_at: '2026-11-18T03:00:00Z', late: true, entered_by_ua: false, remarks: null };
    await render(readingState([stateMachine({ state: 'opening_done', can_open: false, can_close: true, opening })])).ui;
    expect(await screen.findByTestId(`reading-opening-time-${key}`)).toHaveTextContent(/Opening recorded 18 Nov 2026 08:30 · Late/);
  });

  it('R7: the opening time without Late when it was on time, also while the closing is overdue', async () => {
    const opening = { id: 'r-1', counter: 10, product_id: 'p-1', product_code: 'P-1', recorded_at: '2026-11-18T00:40:00Z', late: false, entered_by_ua: false, remarks: null };
    await render(readingState([stateMachine({ state: 'closing_due', can_open: false, can_close: true, opening })])).ui;
    expect(await screen.findByTestId(`reading-opening-time-${key}`)).toHaveTextContent(/^Opening recorded 18 Nov 2026 06:10$/);
  });

  it('shows the summary with the target next to the numbers and the flags as text', async () => {
    const summary = { id: 's', target: 1200, movement_pieces: 1000, good: 950, reject: 30, unaccounted: 20, attainment_pct: 79.17, rollover: true, needs_review: false, over_reported: false };
    await render(readingState([stateMachine({ state: 'closed', can_open: false, summary })])).ui;
    expect(await screen.findByTestId(`reading-summary-${key}-target`)).toHaveTextContent(/Target: 1,200/);
    expect(screen.getByTestId(`reading-summary-${key}-attainment`)).toHaveTextContent(/Attainment: 79.17%/);
    expect(screen.getByTestId(`reading-summary-${key}-flags-rollover`)).toHaveTextContent(/Counter rolled over/);
  });

  it('says so when nothing is open for readings, and when no shifts exist', async () => {
    await render({ ok: true, state: 'none', occurrences: [] }).ui;
    expect(await screen.findByTestId('readings-none')).toHaveTextContent('No readings to record right now');
  });

  it('shows a denial as an error', async () => {
    await render(rpcOk({ ok: false, code: 'not_allowed' })).ui;
    expect(await screen.findByTestId('readings-error')).toBeTruthy();
  });
});
