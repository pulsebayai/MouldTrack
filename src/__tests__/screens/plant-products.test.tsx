import { act, fireEvent, screen, waitFor } from '@testing-library/react-native';
import Products from '@/app/(app)/plant/products';
import { admin, ok, plantClient, product } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';

jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: jest.fn() }, Redirect: () => null }));

const setup = (rows: unknown, rpcResult?: unknown) => {
  const t = plantClient({ product: typeof rows === 'function' ? (rows as never) : ok(rows as never[]) }, rpcResult);
  return { ...t, ui: renderWithSession(<Products />, { ctx: admin, client: t.client }) };
};
const guard = { data: null, status: 400, error: { code: 'P0001', message: 'End its targets first', details: '{"code":"guard","field":"product","machines":["M-1","M-2"]}' } };
jest.setTimeout(20_000);

describe('Products tab (AC-4, AC-13)', () => {
  it('shows code, description, unit and a text status', async () => {
    await setup([product(1), product(2, { uom: 'kg', retired_at: '2026-11-01T00:00:00Z' })]).ui;
    expect(await screen.findByTestId('product-row-p-1')).toBeTruthy();
    expect(screen.getByTestId('product-code-p-1')).toHaveTextContent('P-1');
    expect(screen.getByTestId('product-description-p-1')).toHaveTextContent('Cap 1');
    expect(screen.getByTestId('product-uom-p-2')).toHaveTextContent('kg');
    expect(screen.getByTestId('product-status-p-1')).toHaveTextContent('Active');
    expect(screen.getByTestId('product-status-p-2')).toHaveTextContent('Retired');
  });

  it('shows a loading state, the empty state, a no-match state and an error with retry', async () => {
    let resolve!: (v: unknown) => void;
    let first = true;
    const { ui } = setup((() => (first ? ((first = false), new Promise((r) => (resolve = r))) : ok([]))) as never);
    await ui;
    expect(screen.getByTestId('products-loading')).toBeTruthy();
    await act(async () => resolve(ok([])));
    expect(await screen.findByTestId('products-empty')).toHaveTextContent('No products yet — add your first product');
    await fireEvent.changeText(screen.getByLabelText('Search products'), 'zzz');
    expect(await screen.findByTestId('products-no-match')).toHaveTextContent('No products match');
  });

  it('recovers from a load error with Try again', async () => {
    let fail = true;
    await setup(() => (fail ? { data: null, count: null, error: new TypeError('Failed to fetch') } : ok([product(1)]))).ui;
    expect(await screen.findByTestId('products-error')).toHaveTextContent(/Can't reach MouldTrack/);
    fail = false;
    await fireEvent.press(screen.getByTestId('products-error-retry'));
    expect(await screen.findByTestId('product-row-p-1')).toBeTruthy();
  });

  it('searches, hides retired by default and pages 25 at a time', async () => {
    const { db, ui } = setup(((q: { range?: [number, number] }) => ok([product(q.range![0] + 1)], 60)) as never);
    await ui;
    expect(await screen.findByTestId('products-page')).toHaveTextContent('Page 1 of 3');
    expect(db.queries.at(-1)!.filters).toContainEqual(['is', 'retired_at', null]);
    await fireEvent.press(screen.getByTestId('products-next'));
    await waitFor(() => expect(screen.getByTestId('products-page')).toHaveTextContent('Page 2 of 3'));
    await fireEvent.changeText(screen.getByLabelText('Search products'), 'cap');
    await waitFor(() => expect(screen.getByTestId('products-page')).toHaveTextContent('Page 1 of 3'));
    expect(db.queries.at(-1)!.filters).toContainEqual(['or', 'code.ilike.%cap%,description.ilike.%cap%']);
    await fireEvent.press(screen.getByTestId('products-show-retired'));
    await waitFor(() => expect(db.queries.at(-1)!.filters).not.toContainEqual(['is', 'retired_at', null]));
  });

  it('has 48dp targets', async () => {
    await setup([product(1)]).ui;
    await screen.findByTestId('product-row-p-1');
    for (const id of ['products-add', 'product-edit-p-1', 'product-toggle-p-1', 'products-show-retired']) expect(screen.getByTestId(id)).toHaveStyle({ minHeight: 48 });
  });
});

describe('Product form (AC-4)', () => {
  it('validates, then creates with unit defaulting to pcs, and reloads the list', async () => {
    const { rpc, db, ui } = setup([]);
    await ui;
    await screen.findByTestId('products-empty');
    await fireEvent.press(screen.getByTestId('products-add'));
    expect(screen.getByTestId('product-uom').props.value).toBe('pcs');
    await fireEvent.press(screen.getByTestId('product-save'));
    expect(await screen.findByTestId('product-code-error')).toBeTruthy();
    expect(screen.getByTestId('product-description-error')).toBeTruthy();
    expect(rpc).not.toHaveBeenCalled();
    const before = db.queries.length;
    await fireEvent.changeText(screen.getByLabelText('Code'), 'P-9');
    await fireEvent.changeText(screen.getByLabelText('Description'), 'Lid 40mm');
    await fireEvent.press(screen.getByTestId('product-save'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('pm_save_product', { p_request_id: expect.any(String), p_id: null, p_code: 'P-9', p_description: 'Lid 40mm', p_uom: 'pcs' }));
    await waitFor(() => expect(screen.queryByTestId('product-form')).toBeNull());
    expect(db.queries.length).toBeGreaterThan(before);
  });

  it('edits an existing product by id and shows a duplicate code next to the field', async () => {
    const dup = { data: null, status: 400, error: { code: 'P0001', message: 'This code is already in use', details: '{"code":"duplicate","field":"code"}' } };
    const { rpc, ui } = setup([product(1)], dup);
    await ui;
    await fireEvent.press(await screen.findByTestId('product-edit-p-1'));
    expect(screen.getByLabelText('Code').props.value).toBe('P-1');
    await fireEvent.changeText(screen.getByLabelText('Code'), 'P-2');
    await fireEvent.press(screen.getByTestId('product-save'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('pm_save_product', expect.objectContaining({ p_id: 'p-1', p_code: 'P-2' })));
    expect(await screen.findByTestId('product-code-error')).toHaveTextContent('This code is already in use');
    await fireEvent.press(screen.getByTestId('product-cancel'));
    expect(screen.queryByTestId('product-form')).toBeNull();
  });

  it('offers no Edit for a retired product', async () => {
    await setup([product(1, { retired_at: '2026-11-01T00:00:00Z' })]).ui;
    await screen.findByTestId('product-row-p-1');
    expect(screen.queryByTestId('product-edit-p-1')).toBeNull();
    expect(screen.getByTestId('product-toggle-p-1')).toHaveTextContent('Reinstate');
  });
});

describe('Retire and reinstate (AC-4)', () => {
  it('names the product in the dialog and does nothing until confirmed', async () => {
    const { rpc, ui } = setup([product(1)]);
    await ui;
    await fireEvent.press(await screen.findByTestId('product-toggle-p-1'));
    expect(screen.getByTestId('confirm-title')).toHaveTextContent('Retire P-1 · Cap 1?');
    await fireEvent.press(screen.getByTestId('confirm-cancel'));
    expect(rpc).not.toHaveBeenCalled();
    await fireEvent.press(screen.getByTestId('product-toggle-p-1'));
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('pm_set_product_retired', { p_request_id: expect.any(String), p_id: 'p-1', p_retired: true }));
  });

  it('shows the blocked-retire message with the machines that still have a target', async () => {
    const { ui } = setup([product(1)], guard);
    await ui;
    await fireEvent.press(await screen.findByTestId('product-toggle-p-1'));
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    expect(await screen.findByTestId('products-action-error')).toHaveTextContent('End its targets first. Used on: M-1, M-2');
    expect(screen.queryByTestId('confirm-dialog')).toBeNull();
  });

  it('reinstates a retired product', async () => {
    const { rpc, ui } = setup([product(1, { retired_at: '2026-11-01T00:00:00Z' })]);
    await ui;
    await fireEvent.press(await screen.findByTestId('product-toggle-p-1'));
    expect(screen.getByTestId('confirm-title')).toHaveTextContent('Reinstate P-1 · Cap 1?');
    await fireEvent.press(screen.getByTestId('confirm-ok'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('pm_set_product_retired', expect.objectContaining({ p_retired: false })));
  });

  it('keeps the request id after a network failure and shows the network message', async () => {
    const { rpc, ui } = setup([product(1)]);
    rpc.mockRejectedValueOnce(new TypeError('Failed to fetch')).mockResolvedValue({ data: { ok: true }, error: null, status: 200 });
    await ui;
    const press = async () => {
      await fireEvent.press(screen.getByTestId('product-toggle-p-1'));
      await fireEvent.press(screen.getByTestId('confirm-ok'));
    };
    await screen.findByTestId('product-row-p-1');
    await press();
    expect(await screen.findByTestId('products-action-error')).toHaveTextContent(/Can't reach MouldTrack/);
    await press();
    await waitFor(() => expect(rpc).toHaveBeenCalledTimes(2));
    expect((rpc.mock.calls[1] as unknown as [string, { p_request_id: string }])[1].p_request_id).toBe((rpc.mock.calls[0] as unknown as [string, { p_request_id: string }])[1].p_request_id);
  });
});
