import AsyncStorage from '@react-native-async-storage/async-storage';
import { fireEvent, screen, waitFor } from '@testing-library/react-native';
import { router } from 'expo-router';
import { ReportForm } from '@/components/issues/report-form';
import * as photos from '@/lib/photos';
import { category } from '@/test/issue-fixtures';
import { sup } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';
import { ok, rpcOk, shiftClient } from '@/test/shift-fixtures';

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
jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: jest.fn(), back: jest.fn(), canGoBack: () => false } }));
jest.mock('@/lib/photos', () => ({ ...jest.requireActual('@/lib/photos'), pickPhoto: jest.fn(), uploadIssuePhoto: jest.fn() }));
jest.setTimeout(20_000);

const cats = [category(1), category(2)];
function setup(rpcs: Record<string, unknown> = {}, machineId: string | null = 'm-1') {
  const t = shiftClient({ issue_category: ok(cats), machine: ok([{ id: 'm-1', code: 'M-1', name: 'Press 1' }]) }, { iss_report: rpcOk({ ok: true, id: 'i-9' }), ...rpcs });
  return { ...t, ui: renderWithSession(<ReportForm machineId={machineId} />, { ctx: sup, client: t.client }) };
}

describe('Report issue form', () => {
  beforeEach(() => { jest.clearAllMocks(); AsyncStorage.clear(); });

  it('lists the active categories and locks Critical when the machine is stopped', async () => {
    await setup().ui;
    expect(await screen.findByTestId('report-category-c-1')).toBeTruthy();
    await fireEvent.press(screen.getByTestId('report-priority-low'));
    await fireEvent.press(screen.getByTestId('report-stopped-yes'));
    expect(screen.getByTestId('report-priority-note')).toHaveTextContent('A stopped machine is always Critical.');
    expect(screen.getByTestId('report-priority-critical')).toHaveTextContent('✓ Critical');
    expect(screen.getByTestId('report-priority-low')).toBeDisabled();
  });

  it('refuses an empty form with messages next to the fields', async () => {
    const { rpc, ui } = setup();
    await ui;
    await fireEvent.press(await screen.findByTestId('report-submit'));
    expect(screen.getByTestId('report-category-error')).toHaveTextContent('Choose a category');
    expect(screen.getByTestId('report-priority-error')).toHaveTextContent('Choose a priority');
    expect(rpc).not.toHaveBeenCalled();
  });

  it('reports with the chosen values and opens the new issue', async () => {
    const { rpc, ui } = setup();
    await ui;
    await fireEvent.press(await screen.findByTestId('report-category-c-1'));
    await fireEvent.press(screen.getByTestId('report-stopped-yes'));
    await fireEvent.changeText(screen.getByTestId('report-description'), '  Hydraulic pump noise ');
    await fireEvent.press(screen.getByTestId('report-submit'));
    await waitFor(() => expect(router.replace).toHaveBeenCalledWith('/issues/i-9'));
    expect(rpc).toHaveBeenCalledWith('iss_report', expect.objectContaining({
      p_machine_id: 'm-1', p_category_id: 'c-1', p_priority: 'critical', p_machine_stopped: true, p_description: 'Hydraulic pump noise',
    }));
    expect(await AsyncStorage.getItem('issue-draft:m-1')).toBeNull();
  });

  it('keeps the draft when the submit fails', async () => {
    const t = setup({ iss_report: { data: null, error: { code: 'P0001', message: 'Something is off', details: '{"code":"validation"}' }, status: 400 } });
    await t.ui;
    await fireEvent.press(await screen.findByTestId('report-category-c-2'));
    await fireEvent.press(screen.getByTestId('report-priority-medium'));
    await fireEvent.changeText(screen.getByTestId('report-description'), 'Slow cycle');
    await fireEvent.press(screen.getByTestId('report-submit'));
    expect(await screen.findByTestId('report-error')).toHaveTextContent('Something is off');
    expect(router.replace).not.toHaveBeenCalled();
    await waitFor(async () => expect(JSON.parse((await AsyncStorage.getItem('issue-draft:m-1'))!)).toMatchObject({ categoryId: 'c-2', priority: 'medium', description: 'Slow cycle' }));
  });

  it('restores a saved draft on the next visit', async () => {
    await AsyncStorage.setItem('issue-draft:m-1', JSON.stringify({ categoryId: 'c-2', priority: 'medium', description: 'Slow cycle', stopped: false }));
    await setup().ui;
    await waitFor(() => expect(screen.getByTestId('report-description').props.value).toBe('Slow cycle'));
    expect(screen.getByTestId('report-priority-medium')).toHaveTextContent('✓ Medium');
  });

  it('uploads a chosen photo after the report exists', async () => {
    (photos.pickPhoto as jest.Mock).mockResolvedValue({ uri: 'u', bytes: new Uint8Array(2048), mime: 'image/jpeg', sha256: 'x' });
    (photos.uploadIssuePhoto as jest.Mock).mockResolvedValue({ attachmentId: 'a', actionId: 'x' });
    await setup().ui;
    await fireEvent.press(await screen.findByTestId('report-category-c-1'));
    await fireEvent.press(screen.getByTestId('report-priority-low'));
    await fireEvent.changeText(screen.getByTestId('report-description'), 'Scratch on mould');
    await fireEvent.press(screen.getByTestId('report-photo-library'));
    expect(await screen.findByTestId('report-photo-ready')).toHaveTextContent('Photo ready (2 KB)');
    await fireEvent.press(screen.getByTestId('report-submit'));
    await waitFor(() => expect(router.replace).toHaveBeenCalledWith('/issues/i-9'));
    expect(photos.uploadIssuePhoto).toHaveBeenCalledWith(expect.anything(), 'i-9', expect.objectContaining({ sha256: 'x' }), expect.objectContaining({ begin: expect.any(String), commit: expect.any(String) }));
  });

  it('a failed photo upload does not report twice on retry', async () => {
    (photos.pickPhoto as jest.Mock).mockResolvedValue({ uri: 'u', bytes: new Uint8Array(10), mime: 'image/jpeg', sha256: 'x' });
    (photos.uploadIssuePhoto as jest.Mock).mockRejectedValueOnce(new Error('Failed to fetch')).mockResolvedValueOnce({ attachmentId: 'a', actionId: 'x' });
    const { rpc, ui } = setup();
    await ui;
    await fireEvent.press(await screen.findByTestId('report-category-c-1'));
    await fireEvent.press(screen.getByTestId('report-priority-low'));
    await fireEvent.changeText(screen.getByTestId('report-description'), 'Crack');
    await fireEvent.press(screen.getByTestId('report-photo-library'));
    await screen.findByTestId('report-photo-ready');
    await fireEvent.press(screen.getByTestId('report-submit'));
    expect(await screen.findByTestId('report-error')).toHaveTextContent(/The issue was reported, but the photo did not upload/);
    expect(router.replace).not.toHaveBeenCalled();
    await fireEvent.press(screen.getByTestId('report-submit'));
    await waitFor(() => expect(router.replace).toHaveBeenCalledWith('/issues/i-9'));
    expect(rpc.mock.calls.filter((c) => c[0] === 'iss_report')).toHaveLength(1);
    expect(photos.uploadIssuePhoto).toHaveBeenCalledTimes(2);
  });

  it('shows a camera permission refusal without losing the form', async () => {
    (photos.pickPhoto as jest.Mock).mockRejectedValue(new photos.PhotoError('Allow camera access to take a photo, or choose one from your files.', 'permission'));
    await setup().ui;
    await fireEvent.press(await screen.findByTestId('report-photo-camera'));
    expect(await screen.findByTestId('report-photo-error')).toHaveTextContent(/Allow camera access/);
    expect(screen.getByTestId('report-submit')).toBeTruthy();
  });

  it('a Unit Admin with no machine chosen picks one first', async () => {
    await setup({}, null).ui;
    expect(screen.queryByTestId('report-submit')).toBeNull();
    await fireEvent.press(await screen.findByTestId('report-machine-m-1'));
    expect(await screen.findByTestId('report-submit')).toBeTruthy();
  });
});
