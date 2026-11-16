import { act, fireEvent, screen, waitFor } from '@testing-library/react-native';
import Users from '@/app/(app)/users/index';
import { ApiError } from '@/lib/api';
import type { UserRow } from '@/lib/users';
import { fakeDb, type Query } from '@/test/fake-db';
import { renderWithSession } from '@/test/render-with-session';

const mockPush = jest.fn();
jest.mock('expo-router', () => ({ router: { push: (...a: unknown[]) => mockPush(...a), replace: jest.fn() }, Redirect: () => null }));
const mockSetStatus = jest.fn();
const mockReset = jest.fn();
jest.mock('@/lib/api', () => {
  const actual = jest.requireActual('@/lib/api');
  return { ...actual, userAdminApi: { setStatus: (...a: unknown[]) => mockSetStatus(...a), resetPassword: (...a: unknown[]) => mockReset(...a) } };
});

const admin = { user: { id: 'me', email: 'x' }, tenant: { name: 'e2e org U' }, role: 'unit_admin' as const };
const sup = { ...admin, role: 'supervisor' as const };

const row = (i: number, over: Partial<UserRow> = {}): UserRow => ({
  user_id: `id-${i}`, full_name: `Person ${i}`, employee_id: `E-${i}`, phone_e164: `+91900001${String(i).padStart(4, '0')}`,
  role: 'supervisor', status: 'active', must_change_password: false, ...over,
});

function setup(handler: (q: Query) => { data: unknown; count?: number | null; error: unknown } | Promise<{ data: unknown; count?: number | null; error: unknown }>) {
  const db = fakeDb(handler);
  return { db, ui: renderWithSession(<Users />, { ctx: admin, client: db.client as never }) };
}
const list = (rows: UserRow[], total = rows.length) => () => ({ data: rows, count: total, error: null });

beforeEach(() => {
  mockPush.mockReset();
  mockSetStatus.mockReset();
  mockReset.mockReset();
});

// The first test pays the cold module transform of the screen; on a loaded CI runner that exceeded the 5 s default (run 43829728473).
jest.setTimeout(20_000);

describe('Users list (AC-14)', () => {
  it('renders name, employee id, phone, role and a text status label for each user', async () => {
    const rows = [
      row(1, { full_name: 'Asha Rao', role: 'unit_admin' }),
      row(2, { status: 'inactive' }),
      row(3, { must_change_password: true }),
    ];
    await setup(list(rows)).ui;
    expect(await screen.findByTestId('user-row-id-1')).toBeTruthy();
    expect(screen.getByTestId('user-name-id-1')).toHaveTextContent(/Asha Rao/);
    expect(screen.getByTestId('user-employee-id-1')).toHaveTextContent('E-1');
    expect(screen.getByTestId('user-phone-id-1')).toHaveTextContent('+91 9000010001');
    expect(screen.getByTestId('user-role-id-1')).toHaveTextContent('Unit Admin');
    expect(screen.getByTestId('user-role-id-2')).toHaveTextContent('Supervisor');
    expect(screen.getByTestId('user-status-id-1')).toHaveTextContent('Active');
    expect(screen.getByTestId('user-status-id-2')).toHaveTextContent('Inactive');
    expect(screen.getByTestId('user-status-id-3')).toHaveTextContent('Must change password');
  });

  it('shows a loading state first', async () => {
    let resolve!: (v: unknown) => void;
    const { ui } = setup(() => new Promise((r) => (resolve = r)) as never);
    await ui;
    expect(screen.getByTestId('users-loading')).toBeTruthy();
    await act(async () => resolve({ data: [row(1)], count: 1, error: null }));
    expect(await screen.findByTestId('user-row-id-1')).toBeTruthy();
    expect(screen.queryByTestId('users-loading')).toBeNull();
  });

  it('shows the empty state with a prompt to add the first supervisor', async () => {
    await setup(list([])).ui;
    expect(await screen.findByTestId('users-empty')).toHaveTextContent('No users yet — add your first supervisor');
  });

  it('shows an error with Try again, and recovers', async () => {
    let fail = true;
    await setup(() => (fail ? { data: null, count: null, error: new TypeError('Failed to fetch') } : { data: [row(1)], count: 1, error: null })).ui;
    expect(await screen.findByTestId('users-error')).toHaveTextContent(/Can't reach MouldTrack/);
    fail = false;
    await fireEvent.press(screen.getByTestId('users-retry'));
    expect(await screen.findByTestId('user-row-id-1')).toBeTruthy();
  });

  it('Add opens the new-user form', async () => {
    await setup(list([row(1)])).ui;
    await screen.findByTestId('user-row-id-1');
    await fireEvent.press(screen.getByTestId('users-add'));
    expect(mockPush).toHaveBeenCalledWith('/users/new');
  });

  it('Edit opens that user', async () => {
    await setup(list([row(1)])).ui;
    await screen.findByTestId('user-row-id-1');
    await fireEvent.press(screen.getByTestId('user-edit-id-1'));
    expect(mockPush).toHaveBeenCalledWith('/users/id-1');
  });

  it('has 48dp targets on every action', async () => {
    await setup(list([row(1)])).ui;
    await screen.findByTestId('user-row-id-1');
    for (const id of ['users-add', 'user-edit-id-1', 'user-toggle-id-1', 'user-reset-id-1']) expect(screen.getByTestId(id)).toHaveStyle({ minHeight: 48 });
  });

  it('offers no deactivate or reset on the admin\'s own row (guards)', async () => {
    await setup(list([row(0, { user_id: 'me', role: 'unit_admin' }), row(1)])).ui;
    await screen.findByTestId('user-row-me');
    expect(screen.getByTestId('user-edit-me')).toBeTruthy();
    expect(screen.queryByTestId('user-toggle-me')).toBeNull();
    expect(screen.queryByTestId('user-reset-me')).toBeNull();
    expect(screen.getByTestId('user-toggle-id-1')).toBeTruthy();
  });
});

describe('Users search, filters and pagination (AC-14)', () => {
  it('searches by name, employee id or phone', async () => {
    const { db, ui } = setup(list([row(1)]));
    await ui;
    await screen.findByTestId('user-row-id-1');
    await fireEvent.changeText(screen.getByLabelText('Search users'), 'asha');
    await waitFor(() => expect(db.queries.at(-1)!.filters).toContainEqual(['or', 'full_name.ilike.%asha%,employee_id.ilike.%asha%,phone_e164.ilike.%asha%']));
  });

  it('filters by role and by status', async () => {
    const { db, ui } = setup(list([row(1)]));
    await ui;
    await screen.findByTestId('user-row-id-1');
    await fireEvent.press(screen.getByTestId('users-filter-role-unit_admin'));
    await waitFor(() => expect(db.queries.at(-1)!.filters).toContainEqual(['eq', 'role', 'unit_admin']));
    await fireEvent.press(screen.getByTestId('users-filter-status-inactive'));
    await waitFor(() => expect(db.queries.at(-1)!.filters).toContainEqual(['eq', 'status', 'inactive']));
    await fireEvent.press(screen.getByTestId('users-filter-role-all'));
    await waitFor(() => expect(db.queries.at(-1)!.filters).not.toContainEqual(['eq', 'role', 'unit_admin']));
  });

  it('shows the selected filter with a check mark, not only colour', async () => {
    await setup(list([row(1)])).ui;
    await screen.findByTestId('user-row-id-1');
    expect(screen.getByTestId('users-filter-status-all')).toHaveTextContent('✓ All');
    await fireEvent.press(screen.getByTestId('users-filter-status-must_change'));
    expect(await screen.findByTestId('users-filter-status-must_change')).toHaveTextContent('✓ Must change password');
    expect(screen.getByTestId('users-filter-status-all')).not.toHaveTextContent('✓');
  });

  it('paginates 25 per page with Previous / Next and "Page x of y"', async () => {
    const { db, ui } = setup((q) => ({ data: [row(q.range![0] + 1)], count: 60, error: null }));
    await ui;
    expect(await screen.findByTestId('users-page')).toHaveTextContent('Page 1 of 3');
    expect(db.queries.at(-1)!.range).toEqual([0, 24]);
    expect(screen.getByTestId('users-prev')).toBeDisabled();
    await fireEvent.press(screen.getByTestId('users-next'));
    await waitFor(() => expect(screen.getByTestId('users-page')).toHaveTextContent('Page 2 of 3'));
    expect(db.queries.at(-1)!.range).toEqual([25, 49]);
    await fireEvent.press(screen.getByTestId('users-next'));
    await waitFor(() => expect(screen.getByTestId('users-page')).toHaveTextContent('Page 3 of 3'));
    expect(screen.getByTestId('users-next')).toBeDisabled();
    await fireEvent.press(screen.getByTestId('users-prev'));
    await waitFor(() => expect(screen.getByTestId('users-page')).toHaveTextContent('Page 2 of 3'));
  });

  it('goes back to page 1 when the search or a filter changes', async () => {
    const { db, ui } = setup((q) => ({ data: [row(1)], count: 60, error: null }));
    await ui;
    await screen.findByTestId('users-page');
    await fireEvent.press(screen.getByTestId('users-next'));
    await waitFor(() => expect(screen.getByTestId('users-page')).toHaveTextContent('Page 2 of 3'));
    await fireEvent.press(screen.getByTestId('users-filter-role-supervisor'));
    await waitFor(() => expect(screen.getByTestId('users-page')).toHaveTextContent('Page 1 of 3'));
    expect(db.queries.at(-1)!.range).toEqual([0, 24]);
  });

  it('shows "No users match" (not the first-run empty state) when a search finds nothing', async () => {
    let rows: UserRow[] = [row(1)];
    await setup(() => ({ data: rows, count: rows.length, error: null })).ui;
    await screen.findByTestId('user-row-id-1');
    rows = [];
    await fireEvent.changeText(screen.getByLabelText('Search users'), 'zzz');
    expect(await screen.findByTestId('users-no-match')).toHaveTextContent('No users match');
    expect(screen.queryByTestId('users-empty')).toBeNull();
  });
});

describe('Deactivate / reactivate with confirmation (AC-6, AC-14)', () => {
  it('names the person in the dialog and does nothing until confirmed', async () => {
    await setup(list([row(1, { full_name: 'Asha Rao' })])).ui;
    await screen.findByTestId('user-row-id-1');
    await fireEvent.press(screen.getByTestId('user-toggle-id-1'));
    expect(screen.getByTestId('confirm-title')).toHaveTextContent('Deactivate Asha Rao?');
    expect(mockSetStatus).not.toHaveBeenCalled();
    await fireEvent.press(screen.getByTestId('confirm-cancel'));
    expect(screen.queryByTestId('confirm-dialog')).toBeNull();
    expect(mockSetStatus).not.toHaveBeenCalled();
  });

  it('deactivates, then reloads the list', async () => {
    mockSetStatus.mockResolvedValue({ ok: true });
    const { db, ui } = setup(list([row(1)]));
    await ui;
    await screen.findByTestId('user-row-id-1');
    const before = db.queries.length;
    await fireEvent.press(screen.getByTestId('user-toggle-id-1'));
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    await waitFor(() => expect(mockSetStatus).toHaveBeenCalledWith(expect.anything(), 'id-1', 'inactive', expect.stringMatching(/^[0-9a-f-]{36}$/)));
    await waitFor(() => expect(db.queries.length).toBeGreaterThan(before));
    expect(screen.queryByTestId('confirm-dialog')).toBeNull();
  });

  it('offers Reactivate for an inactive user', async () => {
    mockSetStatus.mockResolvedValue({ ok: true });
    await setup(list([row(1, { status: 'inactive', full_name: 'Asha Rao' })])).ui;
    await screen.findByTestId('user-row-id-1');
    expect(screen.getByTestId('user-toggle-id-1')).toHaveTextContent('Reactivate');
    await fireEvent.press(screen.getByTestId('user-toggle-id-1'));
    expect(screen.getByTestId('confirm-title')).toHaveTextContent('Reactivate Asha Rao?');
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    await waitFor(() => expect(mockSetStatus).toHaveBeenCalledWith(expect.anything(), 'id-1', 'active', expect.any(String)));
  });

  it('shows a server refusal (422 guard) as text and keeps the user unchanged', async () => {
    mockSetStatus.mockRejectedValue(new ApiError(422, 'last_admin', 'A unit must keep at least one active Unit Admin'));
    await setup(list([row(1, { role: 'unit_admin' })])).ui;
    await screen.findByTestId('user-row-id-1');
    await fireEvent.press(screen.getByTestId('user-toggle-id-1'));
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    expect(await screen.findByTestId('users-action-error')).toHaveTextContent('A unit must keep at least one active Unit Admin');
  });

  it('reuses the request id when the same action is retried after a network failure', async () => {
    mockSetStatus.mockRejectedValueOnce(new TypeError('Network request failed')).mockResolvedValue({ ok: true });
    await setup(list([row(1)])).ui;
    await screen.findByTestId('user-row-id-1');
    await fireEvent.press(screen.getByTestId('user-toggle-id-1'));
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    await waitFor(() => expect(mockSetStatus).toHaveBeenCalledTimes(1));
    expect(await screen.findByTestId('users-action-error')).toHaveTextContent(/Can't reach MouldTrack/);
    await fireEvent.press(screen.getByTestId('user-toggle-id-1'));
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    await waitFor(() => expect(mockSetStatus).toHaveBeenCalledTimes(2));
    expect(mockSetStatus.mock.calls[1][3]).toBe(mockSetStatus.mock.calls[0][3]);
  });
});

describe('Reset password and the temporary-password panel (AC-5, AC-14)', () => {
  it('names the person in the dialog, then shows the new password once with Copy and Done', async () => {
    mockReset.mockResolvedValue({ temp_password: 'Abcdefgh2345' });
    await setup(list([row(1, { full_name: 'Asha Rao' })])).ui;
    await screen.findByTestId('user-row-id-1');
    await fireEvent.press(screen.getByTestId('user-reset-id-1'));
    expect(screen.getByTestId('confirm-title')).toHaveTextContent('Reset password for Asha Rao?');
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    expect(await screen.findByTestId('temp-password-panel')).toBeTruthy();
    expect(screen.getByTestId('temp-password')).toHaveTextContent('Abcdefgh2345');
    expect(screen.getByTestId('temp-password-warning')).toHaveTextContent('Shown once. Hand it to the person directly.');
    expect(screen.getByTestId('temp-password-copy')).toBeTruthy();
    expect(screen.getByTestId('temp-password-panel')).toHaveTextContent(/Asha Rao/);
  });

  it('clears the password when Done is pressed and never shows it again', async () => {
    mockReset.mockResolvedValue({ temp_password: 'Abcdefgh2345' });
    await setup(list([row(1)])).ui;
    await screen.findByTestId('user-row-id-1');
    await fireEvent.press(screen.getByTestId('user-reset-id-1'));
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    await screen.findByTestId('temp-password-panel');
    await fireEvent.press(screen.getByTestId('temp-password-done'));
    expect(screen.queryByTestId('temp-password-panel')).toBeNull();
    expect(screen.queryByText('Abcdefgh2345')).toBeNull();
  });

  it('shows "Already done" and no password for a repeated reset', async () => {
    mockReset.mockResolvedValue({ already: true, message: 'Already done — reset the password if it was lost' });
    await setup(list([row(1)])).ui;
    await screen.findByTestId('user-row-id-1');
    await fireEvent.press(screen.getByTestId('user-reset-id-1'));
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    expect(await screen.findByTestId('users-action-error')).toHaveTextContent('Already done — reset the password if it was lost');
    expect(screen.queryByTestId('temp-password-panel')).toBeNull();
  });

  it('Copy writes the password to the clipboard and says so', async () => {
    const writeText = jest.fn(async () => {});
    Object.defineProperty(globalThis.navigator, 'clipboard', { value: { writeText }, configurable: true });
    mockReset.mockResolvedValue({ temp_password: 'Abcdefgh2345' });
    await setup(list([row(1)])).ui;
    await screen.findByTestId('user-row-id-1');
    await fireEvent.press(screen.getByTestId('user-reset-id-1'));
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    await screen.findByTestId('temp-password-panel');
    await fireEvent.press(screen.getByTestId('temp-password-copy'));
    await waitFor(() => expect(writeText).toHaveBeenCalledWith('Abcdefgh2345'));
    expect(await screen.findByText('Copied')).toBeTruthy();
  });
});

describe('Not allowed (AC-9, AC-14)', () => {
  it('a supervisor opening /users sees "Not allowed" and no data is requested', async () => {
    const db = fakeDb(list([row(1)]));
    await renderWithSession(<Users />, { ctx: sup, client: db.client as never });
    expect(screen.getByTestId('not-allowed')).toHaveTextContent('Not allowed');
    expect(db.queries).toHaveLength(0);
    expect(screen.queryByTestId('users-add')).toBeNull();
  });
});
