import { fireEvent, screen, waitFor } from '@testing-library/react-native';
import CategoriesTab from '@/app/(app)/plant/categories';
import { PlantTabs, tabFor } from '@/components/plant/plant-tabs';
import { category } from '@/test/issue-fixtures';
import { admin } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';
import { ok, rpcOk, shiftClient } from '@/test/shift-fixtures';
import { router } from 'expo-router';

jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: jest.fn() } }));
jest.setTimeout(20_000);

const setup = (rpcs: Record<string, unknown> = {}) => {
  const t = shiftClient({ issue_category: ok([category(1), category(2, true)]) }, rpcs);
  return { ...t, ui: renderWithSession(<CategoriesTab />, { ctx: admin, client: t.client }) };
};

describe('Issue categories tab', () => {
  beforeEach(() => jest.clearAllMocks());

  it('is a Plant tab', async () => {
    expect(tabFor('/plant/categories')).toBe('categories');
    await renderWithSession(<PlantTabs active="categories" />);
    await fireEvent.press(screen.getByTestId('plant-tab-categories'));
    expect(router.replace).toHaveBeenCalledWith('/plant/categories');
  });

  it('lists active and retired categories with status words', async () => {
    await setup().ui;
    expect(await screen.findByTestId('category-c-1-status')).toHaveTextContent('Active');
    expect(screen.getByTestId('category-c-2-status')).toHaveTextContent('Retired');
    expect(screen.getByTestId('category-c-2-toggle')).toHaveTextContent('Reinstate');
  });

  it('adds a category (trimmed) and refuses an empty name', async () => {
    const { rpc, ui } = setup();
    await ui;
    await fireEvent.press(await screen.findByTestId('category-add'));
    expect(screen.getByText('Enter a name of 1 to 60 characters')).toBeTruthy();
    await fireEvent.changeText(screen.getByTestId('category-new-name'), '  Moulds ');
    await fireEvent.press(screen.getByTestId('category-add'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('iss_category_save', expect.objectContaining({ p_id: null, p_name: 'Moulds' })));
  });

  it('renames, retires and reinstates', async () => {
    const { rpc, ui } = setup({ iss_category_save: rpcOk({ ok: true, id: 'c-1' }) });
    await ui;
    await fireEvent.press(await screen.findByTestId('category-c-1-rename'));
    await fireEvent.changeText(screen.getByTestId('category-edit-name'), 'Hydraulic');
    await fireEvent.press(screen.getByTestId('category-save'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('iss_category_save', expect.objectContaining({ p_id: 'c-1', p_name: 'Hydraulic' })));
    await fireEvent.press(await screen.findByTestId('category-c-1-toggle'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('iss_category_set_retired', expect.objectContaining({ p_id: 'c-1', p_retired: true })));
    await fireEvent.press(screen.getByTestId('category-c-2-toggle'));
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('iss_category_set_retired', expect.objectContaining({ p_id: 'c-2', p_retired: false })));
  });

  it('shows a duplicate-name message from the server next to the field', async () => {
    const { ui } = setup({ iss_category_save: { data: null, error: { code: 'P0001', message: 'That category already exists', details: '{"code":"duplicate","field":"name"}' }, status: 400 } });
    await ui;
    await fireEvent.changeText(await screen.findByTestId('category-new-name'), 'Hydraulics');
    await fireEvent.press(screen.getByTestId('category-add'));
    expect(await screen.findByText('That category already exists')).toBeTruthy();
  });
});
