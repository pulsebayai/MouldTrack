import { render, screen } from '@testing-library/react-native';
import Index from '@/app/index';

it('renders the placeholder screen (harness check)', async () => {
  await render(<Index />);
  expect(screen.getByText('MouldTrack')).toBeTruthy();
});
