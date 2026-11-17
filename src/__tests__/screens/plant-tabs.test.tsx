import { fireEvent, render, screen } from '@testing-library/react-native';
import { router } from 'expo-router';
import { PlantTabs, tabFor } from '@/components/plant/plant-tabs';

jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: jest.fn() } }));

describe('Plant tabs', () => {
  it.each([
    ['/plant', 'machines'],
    ['/plant/products', 'products'],
    ['/plant/shifts', 'shifts'],
    ['/plant/assignments', 'assignments'],
    ['/plant/site', 'site'],
  ])('maps %s to %s', (path, tab) => expect(tabFor(path)).toBe(tab));

  it('shows the five tabs in order and navigates to Shifts and Assignments', async () => {
    await render(<PlantTabs active="shifts" />);
    for (const k of ['machines', 'products', 'shifts', 'assignments', 'site']) expect(screen.getByTestId(`plant-tab-${k}`)).toBeTruthy();
    await fireEvent.press(screen.getByTestId('plant-tab-assignments'));
    expect(router.replace).toHaveBeenCalledWith('/plant/assignments');
    await fireEvent.press(screen.getByTestId('plant-tab-shifts'));
    expect(router.replace).toHaveBeenCalledWith('/plant/shifts');
  });
});
