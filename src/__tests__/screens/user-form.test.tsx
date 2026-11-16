import { fireEvent, screen, waitFor } from '@testing-library/react-native';
import UserEdit from '@/app/(app)/users/[id]';
import UserNew from '@/app/(app)/users/new';
import { ApiError } from '@/lib/api';
import { fakeDb } from '@/test/fake-db';
import { renderWithSession } from '@/test/render-with-session';

const mockReplace = jest.fn();
let mockId = 'id-1';
jest.mock('expo-router', () => ({
  router: { replace: (...a: unknown[]) => mockReplace(...a), push: jest.fn() },
  useLocalSearchParams: () => ({ id: mockId }),
  Redirect: () => null,
}));
const mockCreate = jest.fn();
const mockUpdate = jest.fn();
jest.mock('@/lib/api', () => {
  const actual = jest.requireActual('@/lib/api');
  return { ...actual, userAdminApi: { create: (...a: unknown[]) => mockCreate(...a), update: (...a: unknown[]) => mockUpdate(...a) } };
});

const admin = { user: { id: 'me', email: 'x' }, tenant: { name: 'e2e org U' }, role: 'unit_admin' as const };
const sup = { ...admin, role: 'supervisor' as const };
const existing = { user_id: 'id-1', full_name: 'Asha Rao', employee_id: 'E-1', phone_e164: '+919876543210', role: 'supervisor', status: 'active', must_change_password: false };

async function fillNew(over: Partial<Record<'name' | 'emp' | 'phone', string>> = {}) {
  await fireEvent.changeText(screen.getByLabelText('Full name'), over.name ?? 'Meera Nair');
  await fireEvent.changeText(screen.getByLabelText('Employee ID'), over.emp ?? 'EMP-7');
  await fireEvent.changeText(screen.getByLabelText('Phone number'), over.phone ?? '98765 43211');
}

beforeEach(() => {
  mockReplace.mockReset();
  mockCreate.mockReset();
  mockUpdate.mockReset();
  mockId = 'id-1';
});

describe('Add user form (AC-1, AC-2)', () => {
  it('has labelled fields, a +91 prefix with a numeric keypad, role choices and 48dp save', async () => {
    await renderWithSession(<UserNew />, { ctx: admin });
    for (const l of ['Full name', 'Employee ID', 'Phone number']) expect(screen.getByLabelText(l)).toBeTruthy();
    expect(screen.getByTestId('phone-prefix')).toHaveTextContent('+91');
    expect(screen.getByLabelText('Phone number').props.keyboardType).toBe('number-pad');
    expect(screen.getByTestId('role-supervisor')).toHaveTextContent('✓ Supervisor'); // default
    expect(screen.getByTestId('role-unit_admin')).toBeTruthy();
    expect(screen.getByTestId('user-save')).toHaveStyle({ minHeight: 48 });
  });

  it('shows early feedback next to each field and sends nothing', async () => {
    await renderWithSession(<UserNew />, { ctx: admin });
    await fireEvent.press(screen.getByTestId('user-save'));
    expect(await screen.findByTestId('full-name-error')).toHaveTextContent('Enter a name of 1 to 80 characters');
    expect(screen.getByTestId('employee-id-error')).toHaveTextContent('Employee ID: 1 to 30 letters, digits, - _ or /');
    expect(screen.getByTestId('phone-error')).toHaveTextContent('Enter a valid 10-digit Indian mobile number');
    expect(mockCreate).not.toHaveBeenCalled();
  });

  it('creates with the normalised phone and then shows the temporary password once', async () => {
    mockCreate.mockResolvedValue({ user_id: 'new-1', temp_password: 'Abcdefgh2345' });
    const { value } = await renderWithSession(<UserNew />, { ctx: admin });
    await fillNew();
    await fireEvent.press(screen.getByTestId('role-unit_admin'));
    await fireEvent.press(screen.getByTestId('user-save'));
    await waitFor(() => expect(mockCreate).toHaveBeenCalledWith(
      value.client,
      { full_name: 'Meera Nair', employee_id: 'EMP-7', phone: '+919876543211', role: 'unit_admin' },
      expect.stringMatching(/^[0-9a-f-]{36}$/),
    ));
    expect(await screen.findByTestId('temp-password')).toHaveTextContent('Abcdefgh2345');
    expect(screen.getByTestId('temp-password-warning')).toHaveTextContent('Shown once. Hand it to the person directly.');
    expect(screen.queryByTestId('user-form')).toBeNull();
    await fireEvent.press(screen.getByTestId('temp-password-done'));
    expect(mockReplace).toHaveBeenCalledWith('/users');
    expect(screen.queryByText('Abcdefgh2345')).toBeNull();
  });

  it.each([
    [400, 'phone', 'Enter a valid 10-digit Indian mobile number', 'phone-error'],
    [409, 'phone', 'This phone number is already registered', 'phone-error'],
    [409, 'employee_id', 'This employee ID is already in use', 'employee-id-error'],
    [400, 'full_name', 'Enter a name of 1 to 80 characters', 'full-name-error'],
  ])('maps a %i on %s from the server to the field', async (status, field, message, testId) => {
    mockCreate.mockRejectedValue(new ApiError(status, field, message));
    await renderWithSession(<UserNew />, { ctx: admin });
    await fillNew();
    await fireEvent.press(screen.getByTestId('user-save'));
    expect(await screen.findByTestId(testId)).toHaveTextContent(message);
  });

  it('shows a 422 guard or 403 as a form-level message', async () => {
    mockCreate.mockRejectedValue(new ApiError(403, undefined, 'Not allowed'));
    await renderWithSession(<UserNew />, { ctx: admin });
    await fillNew();
    await fireEvent.press(screen.getByTestId('user-save'));
    expect(await screen.findByTestId('user-form-error')).toHaveTextContent('Not allowed');
  });

  it('reuses one request id for retries after a network failure (no duplicate user)', async () => {
    mockCreate.mockRejectedValueOnce(new TypeError('Network request failed')).mockResolvedValue({ user_id: 'n', temp_password: 'Abcdefgh2345' });
    await renderWithSession(<UserNew />, { ctx: admin });
    await fillNew();
    await fireEvent.press(screen.getByTestId('user-save'));
    expect(await screen.findByTestId('user-form-error')).toHaveTextContent(/Can't reach MouldTrack/);
    await fireEvent.press(screen.getByTestId('user-save'));
    await waitFor(() => expect(mockCreate).toHaveBeenCalledTimes(2));
    expect(mockCreate.mock.calls[1][2]).toBe(mockCreate.mock.calls[0][2]);
  });

  it('shows "Already done" and no password when the server reports a repeat', async () => {
    mockCreate.mockResolvedValue({ user_id: 'n', already: true, message: 'Already done — reset the password if it was lost' });
    await renderWithSession(<UserNew />, { ctx: admin });
    await fillNew();
    await fireEvent.press(screen.getByTestId('user-save'));
    expect(await screen.findByTestId('user-form-error')).toHaveTextContent('Already done — reset the password if it was lost');
    expect(screen.queryByTestId('temp-password-panel')).toBeNull();
  });

  it('Cancel returns to the list without a request', async () => {
    await renderWithSession(<UserNew />, { ctx: admin });
    await fireEvent.press(screen.getByTestId('user-cancel'));
    expect(mockReplace).toHaveBeenCalledWith('/users');
    expect(mockCreate).not.toHaveBeenCalled();
  });

  it('a supervisor sees "Not allowed" instead of the form', async () => {
    await renderWithSession(<UserNew />, { ctx: sup });
    expect(screen.getByTestId('not-allowed')).toHaveTextContent('Not allowed');
    expect(screen.queryByTestId('user-form')).toBeNull();
  });
});

describe('Edit user form (AC-7)', () => {
  const db = () => fakeDb((q) => ({ data: q.single ? existing : [existing], error: null }));

  it('loads the user and prefills the fields', async () => {
    const d = db();
    await renderWithSession(<UserEdit />, { ctx: admin, client: d.client as never });
    expect(await screen.findByDisplayValue('Asha Rao')).toBeTruthy();
    expect(screen.getByLabelText('Employee ID').props.value).toBe('E-1');
    expect(screen.getByLabelText('Phone number').props.value).toBe('9876543210');
    expect(screen.getByTestId('role-supervisor')).toHaveTextContent('✓ Supervisor');
    expect(d.queries[0].filters).toContainEqual(['eq', 'user_id', 'id-1']);
  });

  it('sends only the changed fields, with the normalised phone', async () => {
    mockUpdate.mockResolvedValue({ ok: true });
    const d = db();
    const { value } = await renderWithSession(<UserEdit />, { ctx: admin, client: d.client as never });
    await screen.findByDisplayValue('Asha Rao');
    await fireEvent.changeText(screen.getByLabelText('Phone number'), '0 98765 43299');
    await fireEvent.press(screen.getByTestId('user-save'));
    await waitFor(() => expect(mockUpdate).toHaveBeenCalledWith(value.client, 'id-1', { phone: '+919876543299' }, expect.any(String)));
    await waitFor(() => expect(mockReplace).toHaveBeenCalledWith('/users'));
  });

  it('does not call the server when nothing changed', async () => {
    const d = db();
    await renderWithSession(<UserEdit />, { ctx: admin, client: d.client as never });
    await screen.findByDisplayValue('Asha Rao');
    await fireEvent.press(screen.getByTestId('user-save'));
    expect(await screen.findByTestId('user-form-error')).toHaveTextContent('No changes to save');
    expect(mockUpdate).not.toHaveBeenCalled();
  });

  it('maps a duplicate phone from the server to the phone field and stays on the form', async () => {
    mockUpdate.mockRejectedValue(new ApiError(409, 'phone', 'This phone number is already registered'));
    const d = db();
    await renderWithSession(<UserEdit />, { ctx: admin, client: d.client as never });
    await screen.findByDisplayValue('Asha Rao');
    await fireEvent.changeText(screen.getByLabelText('Phone number'), '9876543299');
    await fireEvent.press(screen.getByTestId('user-save'));
    expect(await screen.findByTestId('phone-error')).toHaveTextContent('This phone number is already registered');
    expect(mockReplace).not.toHaveBeenCalled();
  });

  it('shows a 422 self-demotion refusal as text', async () => {
    mockUpdate.mockRejectedValue(new ApiError(422, 'self', 'You cannot do this to your own account'));
    const d = db();
    await renderWithSession(<UserEdit />, { ctx: admin, client: d.client as never });
    await screen.findByDisplayValue('Asha Rao');
    await fireEvent.press(screen.getByTestId('role-unit_admin'));
    await fireEvent.press(screen.getByTestId('user-save'));
    expect(await screen.findByTestId('user-form-error')).toHaveTextContent('You cannot do this to your own account');
  });

  it('shows a load error with retry', async () => {
    let fail = true;
    const d = fakeDb(() => (fail ? { data: null, error: new TypeError('Failed to fetch') } : { data: existing, error: null }));
    await renderWithSession(<UserEdit />, { ctx: admin, client: d.client as never });
    expect(await screen.findByTestId('user-form-load-error')).toHaveTextContent(/Can't reach MouldTrack/);
    fail = false;
    await fireEvent.press(screen.getByTestId('user-form-retry'));
    expect(await screen.findByDisplayValue('Asha Rao')).toBeTruthy();
  });

  it('says "User not found" for an id this tenant cannot read', async () => {
    const d = fakeDb(() => ({ data: null, error: null }));
    await renderWithSession(<UserEdit />, { ctx: admin, client: d.client as never });
    expect(await screen.findByTestId('user-not-found')).toHaveTextContent('User not found');
  });

  it('a supervisor sees "Not allowed" and nothing is requested', async () => {
    const d = db();
    await renderWithSession(<UserEdit />, { ctx: sup, client: d.client as never });
    expect(screen.getByTestId('not-allowed')).toHaveTextContent('Not allowed');
    expect(d.queries).toHaveLength(0);
  });
});
