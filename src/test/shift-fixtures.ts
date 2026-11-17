import type { BoardMachine, MyShift, MyShiftOccurrence, Shift, ShiftBoard, Supervisor } from '@/lib/plant';
import { ok, plantClient, type Tables } from './plant-fixtures';

export const shift = (i: number, over: Partial<Shift> = {}): Shift => ({
  id: `sh-${i}`, name: i === 1 ? 'Morning' : i === 2 ? 'Night' : `Shift ${i}`, start_time: i === 2 ? '22:00:00' : '06:00:00', end_time: i === 2 ? '06:00:00' : '14:00:00', retired_at: null, ...over,
});
export const supervisor = (i: number): Supervisor => ({ user_id: `s-${i}`, full_name: `Sup ${i}`, employee_id: `E${i}` });
/** A machine on the board; when the owner comes from the plan, the plan owner defaults to the same person (pass plan_owner_* to differ, e.g. under a cover). */
export const boardMachine = (i: number, over: Partial<BoardMachine> = {}): BoardMachine => {
  const m: BoardMachine = ({
  machine_id: `m-${i}`, code: `M-${i}`, name: `Press ${i}`, line: null, status: 'active', owner_id: null, owner_name: null, owner_inactive: false, source: 'none', reason: null,
  plan_owner_id: null, plan_owner_name: null, later_dates: [], ...over,
  });
  return over.plan_owner_id === undefined && m.source === 'plan' ? { ...m, plan_owner_id: m.owner_id, plan_owner_name: m.owner_name } : m;
};
export const board = (machines: BoardMachine[], over: Partial<ShiftBoard> = {}): ShiftBoard => ({
  ok: true,
  shift: { id: 'sh-1', name: 'Morning', start_time: '06:00:00', end_time: '14:00:00', retired: false },
  shift_date: '2026-11-18',
  plan_date: '2026-11-18',
  starts_at: '2026-11-18T00:30:00Z',
  ends_at: '2026-11-18T08:30:00Z',
  machines,
  unassigned_count: machines.filter((m) => m.owner_id === null).length,
  ...over,
});
export const myShiftOccurrence = (over: Partial<MyShiftOccurrence> = {}): MyShiftOccurrence => ({
  shift: { id: 'sh-1', name: 'Morning', start_time: '06:00:00', end_time: '14:00:00' }, shift_date: '2026-11-18',
  starts_at: '2026-11-18T00:30:00Z', ends_at: '2026-11-18T08:30:00Z', running: true, machines: [{ machine_id: 'm-1', code: 'M-1', name: 'Press 1', line: 'Line A' }], ...over,
});
export const myShiftRunning: MyShift = { ok: true, state: 'running', occurrences: [myShiftOccurrence()] };

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
