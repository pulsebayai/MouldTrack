import AsyncStorage from '@react-native-async-storage/async-storage';
import { fireEvent, screen, waitFor } from '@testing-library/react-native';
import { router } from 'expo-router';
import { OccurrenceView } from '@/components/readings/occurrence-view';
import { RecordForm } from '@/components/readings/record-form';
import { TodayBoardView } from '@/components/readings/today-board';
import * as photos from '@/lib/photos';
import { admin, product, sup } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';
import { ok, readingDetail, readingState, rpcOk, shiftClient, stateMachine, todayBoard } from '@/test/shift-fixtures';

jest.mock('@react-native-async-storage/async-storage', () => {
  const store = new Map<string, string>();
  return {
    __esModule: true,
    default: {
      getItem: jest.fn(async (k: string) => store.get(k) ?? null),
      setItem: jest.fn(async (k: string, v: string) => void store.set(k, v)),
      removeItem: jest.fn(async (k: string) => void store.delete(k)),
      clear: jest.fn(async () => store.clear()),
    },
  };
});
jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: jest.fn(), back: jest.fn(), canGoBack: () => false }, useFocusEffect: () => {} }));
jest.mock('@/lib/photos', () => ({ ...jest.requireActual('@/lib/photos'), pickPhoto: jest.fn(), uploadReadingPhoto: jest.fn(), downloadPhoto: jest.fn(async () => null) }));
jest.setTimeout(20_000);

const P = [product(1), product(2)];
const open = { machineId: 'm-1', shiftId: 'sh-1', shiftDate: '2026-11-18' };
function record(kind: 'opening' | 'closing', rpcs: Record<string, unknown> = {}) {
  const t = shiftClient({ product: ok(P) }, { reading_state: rpcOk(readingState([stateMachine({ default_product_id: 'p-2' })])), rd_opening: rpcOk({ ok: true, id: 'r-1' }), rd_closing: rpcOk({ ok: true, id: 'r-2' }), ...rpcs });
  return { ...t, ui: renderWithSession(<RecordForm {...open} kind={kind} />, { ctx: sup, client: t.client }) };
}

describe('Opening and closing forms (AC-1, AC-2)', () => {
  beforeEach(() => { jest.clearAllMocks(); AsyncStorage.clear(); });

  it('shows the machine, shift and counter unit, and preselects the default product', async () => {
    await record('opening').ui;
    expect(await screen.findByTestId('record-machine')).toHaveTextContent('M-1 · Press 1');
    expect(screen.getByTestId('record-shift')).toHaveTextContent(/Morning · 06:00 – 14:00 · 18 Nov 2026/);
    expect(screen.getByTestId('record-unit')).toHaveTextContent('Counter counts: Pieces');
    expect(await screen.findByTestId('record-product-p-2')).toHaveTextContent(/✓/);
  });

  it('refuses empty numbers with messages next to the fields and sends nothing', async () => {
    const { rpc, ui } = record('closing');
    await ui;
    await fireEvent.press(await screen.findByTestId('record-submit'));
    expect(screen.getByTestId('record-counter-error')).toHaveTextContent('Counter: enter a whole number from 0 to 1,000,000,000,000');
    expect(screen.getByTestId('record-good-error')).toBeTruthy();
    expect(screen.getByTestId('record-reject-error')).toBeTruthy();
    expect(rpc).not.toHaveBeenCalledWith('rd_closing', expect.anything());
  });

  it('records an opening and returns to the readings', async () => {
    const { rpc, ui } = record('opening');
    await ui;
    await fireEvent.changeText(await screen.findByTestId('record-counter'), '1,000');
    await fireEvent.press(screen.getByTestId('record-product-p-1'));
    await fireEvent.press(screen.getByTestId('record-submit'));
    await waitFor(() => expect(router.replace).toHaveBeenCalledWith('/readings'));
    expect(rpc).toHaveBeenCalledWith('rd_opening', expect.objectContaining({ p_machine_id: 'm-1', p_shift_id: 'sh-1', p_shift_date: '2026-11-18', p_product_id: 'p-1', p_counter: 1000, p_remarks: null }));
    expect(await AsyncStorage.getItem('reading-draft:m-1:sh-1:2026-11-18:opening')).toBeNull();
  });

  it('records a closing with good and reject', async () => {
    const { rpc, ui } = record('closing');
    await ui;
    await fireEvent.changeText(await screen.findByTestId('record-counter'), '1250');
    await fireEvent.changeText(screen.getByTestId('record-good'), '950');
    await fireEvent.changeText(screen.getByTestId('record-reject'), '30');
    await fireEvent.press(screen.getByTestId('record-submit'));
    await waitFor(() => expect(router.replace).toHaveBeenCalledWith('/readings'));
    expect(rpc).toHaveBeenCalledWith('rd_closing', expect.objectContaining({ p_counter: 1250, p_good: 950, p_reject: 30 }));
  });

  it('keeps the draft and shows the server message when the submit is refused', async () => {
    const { ui } = record('closing', { rd_closing: { data: null, error: { code: 'P0001', message: 'This shift has ended', details: '{"code":"guard","field":"window_closed"}' }, status: 400 } });
    await ui;
    await fireEvent.changeText(await screen.findByTestId('record-counter'), '1250');
    await fireEvent.changeText(screen.getByTestId('record-good'), '950');
    await fireEvent.changeText(screen.getByTestId('record-reject'), '30');
    await fireEvent.press(screen.getByTestId('record-submit'));
    expect(await screen.findByTestId('record-error')).toHaveTextContent('This shift has ended');
    await waitFor(async () => expect(JSON.parse((await AsyncStorage.getItem('reading-draft:m-1:sh-1:2026-11-18:closing')) ?? '{}')).toMatchObject({ counter: '1250', good: '950', reject: '30' }));
    expect(router.replace).not.toHaveBeenCalled();
  });

  it('uploads the optional photo after the opening, without recording twice on a retry', async () => {
    const upload = photos.uploadReadingPhoto as jest.Mock;
    upload.mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce({ attachmentId: 'a-1' });
    (photos.pickPhoto as jest.Mock).mockResolvedValue({ uri: 'x', bytes: new Uint8Array(2048), mime: 'image/jpeg', sha256: 'ab'.repeat(32) });
    const { rpc, ui } = record('opening');
    await ui;
    await fireEvent.changeText(await screen.findByTestId('record-counter'), '10');
    await fireEvent.press(await screen.findByTestId('record-photo-library'));
    expect(await screen.findByTestId('record-photo-ready')).toHaveTextContent('Photo ready (2 KB)');
    await fireEvent.press(screen.getByTestId('record-submit'));
    expect(await screen.findByTestId('record-error')).toHaveTextContent(/The reading was recorded, but the photo did not upload\./);
    await fireEvent.press(screen.getByTestId('record-submit'));
    await waitFor(() => expect(router.replace).toHaveBeenCalledWith('/readings'));
    expect(rpc.mock.calls.filter((c) => c[0] === 'rd_opening')).toHaveLength(1);
    expect(upload).toHaveBeenCalledTimes(2);
    expect(upload.mock.calls[1][1]).toBe('r-1');
  });
});

describe('Occurrence detail and correction (AC-6, AC-15)', () => {
  const entry = { id: 'r-1', kind: 'opening' as const, counter: 10, product_id: 'p-1', product_code: 'P-1', good: null, reject: null, remarks: null, late: true, entered_by_ua: false, supersedes_id: null, correction_reason: null, recorded_by: 's-1', recorded_by_name: 'Sup 1', recorded_at: '2026-11-18T01:30:00Z', current: true };
  const detail = (over = {}) => readingDetail({ readings: [entry], opening: entry, allowed: { can_open: false, can_close: true, can_correct: true }, ...over });
  function view(d: unknown, rpcs: Record<string, unknown> = {}) {
    const t = shiftClient({ product: ok(P) }, { reading_detail: rpcOk(d), rd_correct: rpcOk({ ok: true, id: 'r-3' }), ...rpcs });
    return { ...t, ui: renderWithSession(<OccurrenceView machineId="m-1" shiftId="sh-1" shiftDate="2026-11-18" />, { ctx: sup, client: t.client }) };
  }

  it('shows the history in plant time with Late as text, and no summary yet', async () => {
    await view(detail()).ui;
    expect(await screen.findByTestId('reading-entry-r-1')).toHaveTextContent(/Opening/);
    expect(screen.getByTestId('reading-entry-r-1')).toHaveTextContent(/Sup 1 · 18 Nov 2026 07:00 · Late/);
    expect(screen.getByTestId('occurrence-no-summary')).toBeTruthy();
    expect(screen.getByTestId('occurrence-owner')).toHaveTextContent('Supervisor: Sup 1');
  });

  it('offers a correction only when the server allows it', async () => {
    await view(detail({ allowed: { can_open: false, can_close: false, can_correct: false } })).ui;
    await screen.findByTestId('reading-entry-r-1');
    expect(screen.queryByTestId('correct-opening')).toBeNull();
  });

  it('requires a reason, sends the correction and reloads', async () => {
    const { rpc, ui } = view(detail());
    await ui;
    await fireEvent.press(await screen.findByTestId('correct-opening'));
    await fireEvent.changeText(screen.getByTestId('correct-counter'), '12');
    await fireEvent.press(screen.getByTestId('correct-submit'));
    expect(screen.getByTestId('correct-reason-error')).toHaveTextContent('Enter a reason of 1 to 200 characters');
    expect(rpc).not.toHaveBeenCalledWith('rd_correct', expect.anything());
    await fireEvent.changeText(screen.getByTestId('correct-reason'), 'typo');
    await fireEvent.press(screen.getByTestId('correct-submit'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('rd_correct', expect.objectContaining({ p_reading_id: 'r-1', p_counter: 12, p_product_id: 'p-1', p_reason: 'typo', p_good: null })));
    await waitFor(() => expect(screen.queryByTestId('correct-form')).toBeNull());
  });

  it('shows a denial as an error', async () => {
    await view({ ok: false, code: 'not_allowed' }).ui;
    expect(await screen.findByTestId('occurrence-error')).toBeTruthy();
  });
});

describe('Today board (AC-12)', () => {
  const machine = (over = {}) => ({
    machine_id: 'm-1', code: 'M-1', name: 'Press 1', counter_unit: 'pieces' as const, owner_id: 's-1', owner_name: 'Sup 1', product_id: 'p-1', product_code: 'P-1', target: 1000, target_assumed: false,
    opening_status: 'on_time' as const, closing_status: 'late' as const, opening_counter: 10, closing_counter: 300, movement_pieces: 290, good: 280, reject: 5, unaccounted: 5, attainment_pct: 28, flags: ['late_closing' as const], ...over,
  });
  const occ = { shift: { id: 'sh-1', name: 'Morning', start_time: '06:00', end_time: '14:00' }, shift_date: '2026-11-18', starts_at: 'a', ends_at: 'b', running: false, current: true,
    totals: { machines_expected: 1, openings_on_time: 1, closings_on_time: 0, both_on_time: 0, target: 1000, target_closed: 1000, good: 280, attainment_pct: 28 } };
  const board = (machines: unknown[]) => todayBoard({ occurrences: [{ ...occ, machines } as never] });
  function render(b: unknown) {
    const t = shiftClient({}, { today_board: rpcOk(b) });
    return { ...t, ui: renderWithSession(<TodayBoardView />, { ctx: admin, client: t.client }) };
  }
  it('shows each machine target next to its actual, statuses and flags as text', async () => {
    await render(board([machine()])).ui;
    const k = 'sh-1-2026-11-18';
    expect(await screen.findByTestId(`today-totals-${k}`)).toHaveTextContent(/1 machines · opening on time 1 · closing on time 0 · target 1,000 · good \(closed\) 280 · attainment 28.00%/);
    expect(screen.getByTestId(`today-machine-${k}-m-1`)).toHaveTextContent(/Opening: On time · Closing: Late/);
    expect(screen.getByTestId(`today-target-${k}-m-1`)).toHaveTextContent(/Target: 1,000 · Good: 280 · Attainment: 28.00%/);
    expect(screen.getByTestId(`today-flags-${k}-m-1-late_closing`)).toHaveTextContent(/Late closing/);
    await fireEvent.press(screen.getByTestId(`today-open-${k}-m-1`));
    expect(router.push).toHaveBeenCalledWith({ pathname: '/readings/occurrence', params: { machineId: 'm-1', shiftId: 'sh-1', date: '2026-11-18' } });
  });
  it('marks a target assumed from the default product, and shows No target set', async () => {
    await render(board([machine({ target_assumed: true }), machine({ machine_id: 'm-2', code: 'M-2', target: null, attainment_pct: null })])).ui;
    const k = 'sh-1-2026-11-18';
    expect(await screen.findByTestId(`today-target-${k}-m-1`)).toHaveTextContent(/1,000 \(default product\)/);
    expect(screen.getByTestId(`today-target-${k}-m-2`)).toHaveTextContent(/Target: No target set · Good: 280 · Attainment: No target/);
  });
  it('says so when nothing has started', async () => {
    await render(todayBoard()).ui;
    expect(await screen.findByTestId('today-empty')).toBeTruthy();
  });
});
