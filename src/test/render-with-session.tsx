import { render } from '@testing-library/react-native';
import type { ReactElement } from 'react';
import { SessionStateContext, type SessionState } from '@/lib/session-provider';

export function fakeAuthClient(overrides: Record<string, unknown> = {}) {
  return {
    auth: {
      signInWithPassword: jest.fn(async () => ({ data: {}, error: null })),
      signOut: jest.fn(async () => ({ error: null })),
      ...overrides,
    },
  };
}

export async function renderWithSession(ui: ReactElement, state: Partial<SessionState> = {}) {
  const value: SessionState = {
    status: 'ready',
    ctx: null,
    appEnv: 'local',
    client: fakeAuthClient() as unknown as SessionState['client'],
    refresh: jest.fn(async () => {}),
    ...state,
  };
  const utils = await render(<SessionStateContext.Provider value={value}>{ui}</SessionStateContext.Provider>);
  return { value, ...utils };
}
