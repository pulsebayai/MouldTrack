import { waitFor } from '@testing-library/react-native';
import Assignments from '@/app/(app)/plant/assignments';
import { PlantContext } from '@/components/plant/plant-context';
import { admin } from '@/test/plant-fixtures';
import { renderWithSession } from '@/test/render-with-session';
import { board, ok, rpcOk, shift, shiftClient, supervisor } from '@/test/shift-fixtures';

jest.mock('expo-router', () => ({ router: { push: jest.fn(), replace: jest.fn() }, Redirect: () => null }));
jest.setTimeout(20_000);

describe('Assignments starts shifts and supervisors together (screen-speed step 3)', () => {
  it('reads the supervisors while the shifts read is still running', async () => {
    let release!: (v: unknown) => void;
    const t = shiftClient({ shift: (() => new Promise((r) => (release = r))) as never, membership: ok([supervisor(1)]) }, { shift_board: rpcOk(board([])) });
    await renderWithSession(
      <PlantContext.Provider value={{ site: { id: 'site', name: 'Site', timezone: 'Asia/Kolkata' }, today: '2026-11-18', reload: jest.fn() }}>
        <Assignments />
      </PlantContext.Provider>,
      { ctx: admin, client: t.client },
    );
    expect(t.db.queries.map((q) => q.table).sort()).toEqual(['membership', 'shift']);
    release(ok([shift(1)]));
    await waitFor(() => expect(t.rpc).toHaveBeenCalledWith('shift_board', expect.anything()));
  });
});
