import type { BoardMachine, MyShift, Shift, ShiftBoard, Supervisor } from '@/lib/plant';
import { ok, plantClient, type Tables } from './plant-fixtures';

export const shift = (i: number, over: Partial<Shift> = {}): Shift => ({
  id: `sh-${i}`, name: i === 1 ? 'Morning' : i === 2 ? 'Night' : `Shift ${i}`, start_time: i === 2 ? '22:00:00' : '06:00:00', end_time: i === 2 ? '06:00:00' : '14:00:00', retired_at: null, ...over,
});
export const supervisor = (i: number): Supervisor => ({ user_id: `s-${i}`, full_name: `Sup ${i}`, employee_id: `E${i}` });
export const boardMachine = (i: number, over: Partial<BoardMachine> = {}): BoardMachine => ({
  machine_id: `m-${i}`, code: `M-${i}`, name: `Press ${i}`, line: null, status: 'active', owner_id: null, owner_name: null, owner_inactive: false, source: 'none', reason: null, ...over,
});
export const board = (machines: BoardMachine[], over: Partial<ShiftBoard> = {}): ShiftBoard => ({
  ok: true,
  shift: { id: 'sh-1', name: 'Morning', start_time: '06:00:00', end_time: '14:00:00', retired: false },
  shift_date: '2026-11-18',
  starts_at: '2026-11-18T00:30:00Z',
  ends_at: '2026-11-18T08:30:00Z',
  machines,
  unassigned_count: machines.filter((m) => m.owner_id === null).length,
  ...over,
});
export const myShiftRunning: MyShift = {
  ok: true, state: 'running', shift: { id: 'sh-1', name: 'Morning', start_time: '06:00:00', end_time: '14:00:00' }, shift_date: '2026-11-18',
  starts_at: '2026-11-18T00:30:00Z', ends_at: '2026-11-18T08:30:00Z', machines: [{ machine_id: 'm-1', code: 'M-1', name: 'Press 1', line: 'Line A' }],
};

type RpcHandler = unknown | ((args: Record<string, unknown>) => unknown);

/** plantClient whose rpc answers per function name (a value or a function of the arguments); unknown names answer { ok: true }. */
export function shiftClient(tables: Tables, rpcs: Record<string, RpcHandler> = {}) {
  const t = plantClient(tables);
  const rpc = jest.fn(async (fn: string, args?: Record<string, unknown>) => {
    const h = rpcs[fn];
    const v = typeof h === 'function' ? (h as (a: Record<string, unknown>) => unknown)(args ?? {}) : h;
    return v ?? { data: { ok: true, id: 'new-id' }, error: null, status: 200 };
  });
  return { ...t, rpc, client: { ...t.db.client, rpc } as never };
}
export const rpcOk = (data: unknown) => ({ data, error: null, status: 200 });
export { ok };
