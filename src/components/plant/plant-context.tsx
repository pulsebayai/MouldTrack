import { createContext, useContext } from 'react';
import type { Site } from '@/lib/plant';

export type PlantState = { site: Site; today: string | null; reload: () => void };
export const PlantContext = createContext<PlantState | null>(null);

/** Site and plant date of the caller's tenant; only rendered under the Plant layout, which guarantees a site. */
export function usePlant(): PlantState {
  const v = useContext(PlantContext);
  if (!v) throw new Error('usePlant must be used inside the Plant layout');
  return v;
}
