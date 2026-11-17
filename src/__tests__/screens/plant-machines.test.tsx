import { act, fireEvent, screen, waitFor } from '@testing-library/react-native';
import Machines from '@/app/(app)/plant/index';
import { admin, machine, ok, plantClient } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';

const mockPush = jest.fn();
jest.mock('expo-router', () => ({ router: { push: (...a: unknown[]) => mockPush(...a), replace: jest.fn() }, Redirect: () => null }));

const lines = [{ id: 'l-1', name: 'Line A', archived_at: null }, { id: 'l-2', name: 'Old line', archived_at: '2026-01-01T00:00:00Z' }];
const setup = (machines: unknown) => {
  const t = plantClient({ machine: typeof machines === 'function' ? (machines as never) : ok(machines as never[]), line: ok(lines) });
  return { ...t, ui: renderWithSession(<Machines />, { ctx: admin, client: t.client }) };
};
beforeEach(() => mockPush.mockReset());
jest.setTimeout(20_000);

describe('Machines tab (AC-3, AC-13)', () => {
  it('shows code, name, line and a text status for each machine', async () => {
    await setup([machine(1, { line_id: 'l-1' }), machine(2, { status: 'under_maintenance' }), machine(3, { retired_at: '2026-11-01T00:00:00Z' })]).ui;
    expect(await screen.findByTestId('machine-row-m-1')).toBeTruthy();
    expect(screen.getByTestId('machine-code-m-1')).toHaveTextContent('M-1');
    expect(screen.getByTestId('machine-name-m-1')).toHaveTextContent('Press 1');
    expect(screen.getByTestId('machine-line-m-1')).toHaveTextContent('Line: Line A');
    expect(screen.getByTestId('machine-line-m-2')).toHaveTextContent('No line');
    expect(screen.getByTestId('machine-status-m-1')).toHaveTextContent('Active');
    expect(screen.getByTestId('machine-status-m-2')).toHaveTextContent('Under maintenance');
    expect(screen.getByTestId('machine-status-m-3')).toHaveTextContent('Retired');
  });

  it('shows a loading state first', async () => {
    let resolve!: (v: unknown) => void;
    const { ui } = setup((() => new Promise((r) => (resolve = r))) as never);
    await ui;
    expect(screen.getByTestId('machines-loading')).toBeTruthy();
    await act(async () => resolve(ok([machine(1)])));
    expect(await screen.findByTestId('machine-row-m-1')).toBeTruthy();
    expect(screen.queryByTestId('machines-loading')).toBeNull();
  });

  it('shows the empty state with a prompt to add the first machine', async () => {
    await setup([]).ui;
    expect(await screen.findByTestId('machines-empty')).toHaveTextContent('No machines yet — add your first machine');
  });

  it('shows "No machines match" when a search finds nothing', async () => {
    let rows = [machine(1)];
    await setup(() => ok(rows)).ui;
    await screen.findByTestId('machine-row-m-1');
    rows = [];
    await fireEvent.changeText(screen.getByLabelText('Search machines'), 'zzz');
    expect(await screen.findByTestId('machines-no-match')).toHaveTextContent('No machines match');
    expect(screen.queryByTestId('machines-empty')).toBeNull();
  });

  it('shows an error with Try again, and recovers', async () => {
    let fail = true;
    await setup(() => (fail ? { data: null, count: null, error: new TypeError('Failed to fetch') } : ok([machine(1)]))).ui;
    expect(await screen.findByTestId('machines-error')).toHaveTextContent(/Can't reach MouldTrack/);
    fail = false;
    await fireEvent.press(screen.getByTestId('machines-error-retry'));
    expect(await screen.findByTestId('machine-row-m-1')).toBeTruthy();
  });

  it('Add and Open navigate', async () => {
    await setup([machine(1)]).ui;
    await screen.findByTestId('machine-row-m-1');
    await fireEvent.press(screen.getByTestId('machines-add'));
    expect(mockPush).toHaveBeenCalledWith('/plant/machines/new');
    await fireEvent.press(screen.getByTestId('machine-open-m-1'));
    expect(mockPush).toHaveBeenCalledWith('/plant/machines/m-1');
  });

  it('has 48dp targets on every action', async () => {
    await setup([machine(1)]).ui;
    await screen.findByTestId('machine-row-m-1');
    for (const id of ['machines-add', 'machine-open-m-1', 'machines-filter-status-active', 'machines-show-retired']) expect(screen.getByTestId(id)).toHaveStyle({ minHeight: 48 });
  });
});

describe('Machines search, filters and pages', () => {
  it('searches code and name', async () => {
    const { db, ui } = setup([machine(1)]);
    await ui;
    await screen.findByTestId('machine-row-m-1');
    await fireEvent.changeText(screen.getByLabelText('Search machines'), 'press');
    await waitFor(() => expect(db.queries.at(-1)!.filters).toContainEqual(['or', 'code.ilike.%press%,name.ilike.%press%']));
  });

  it('hides retired machines until "Show retired" is selected', async () => {
    const { db, ui } = setup([machine(1)]);
    await ui;
    await screen.findByTestId('machine-row-m-1');
    expect(db.queries.at(-1)!.filters).toContainEqual(['is', 'retired_at', null]);
    await fireEvent.press(screen.getByTestId('machines-show-retired'));
    await waitFor(() => expect(db.queries.at(-1)!.filters).not.toContainEqual(['is', 'retired_at', null]));
    expect(screen.getByTestId('machines-show-retired')).toHaveTextContent('✓ Show retired');
  });

  it('filters by status and by line, showing only live lines as choices', async () => {
    const { db, ui } = setup([machine(1)]);
    await ui;
    await screen.findByTestId('machine-row-m-1');
    expect(screen.queryByTestId('machines-filter-line-l-2')).toBeNull();
    await fireEvent.press(screen.getByTestId('machines-filter-status-under_maintenance'));
    await waitFor(() => expect(db.queries.at(-1)!.filters).toContainEqual(['eq', 'status', 'under_maintenance']));
    expect(screen.getByTestId('machines-filter-status-under_maintenance')).toHaveTextContent('✓ Under maintenance');
    await fireEvent.press(screen.getByTestId('machines-filter-line-l-1'));
    await waitFor(() => expect(db.queries.at(-1)!.filters).toContainEqual(['eq', 'line_id', 'l-1']));
    await fireEvent.press(screen.getByTestId('machines-filter-line-none'));
    await waitFor(() => expect(db.queries.at(-1)!.filters).toContainEqual(['is', 'line_id', null]));
  });

  it('paginates 25 per page and goes back to page 1 when a filter changes', async () => {
    const { db, ui } = setup(((q: { range?: [number, number] }) => ok([machine(q.range![0] + 1)], 60)) as never);
    await ui;
    expect(await screen.findByTestId('machines-page')).toHaveTextContent('Page 1 of 3');
    expect(db.queries.at(-1)!.range).toEqual([0, 24]);
    expect(screen.getByTestId('machines-prev')).toBeDisabled();
    await fireEvent.press(screen.getByTestId('machines-next'));
    await waitFor(() => expect(screen.getByTestId('machines-page')).toHaveTextContent('Page 2 of 3'));
    expect(db.queries.at(-1)!.range).toEqual([25, 49]);
    await fireEvent.press(screen.getByTestId('machines-filter-status-active'));
    await waitFor(() => expect(screen.getByTestId('machines-page')).toHaveTextContent('Page 1 of 3'));
  });
});
