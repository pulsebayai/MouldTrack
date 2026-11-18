import type { HandoverAlerts, HandoverChecklist, HandoverItem, HandoverMachine, HandoverOccurrence, OverdueAck, PendingException } from '@/lib/handover';
import { issue } from './issue-fixtures';

export const item = (n: number, over: Partial<HandoverItem> = {}): HandoverItem => ({
  ...issue(n, { owner_id: 'me', machine_id: 'm-1', machine_code: 'M-1' }),
  state: 'pending', exception_pending: false, handled_at: null, handover_start: '2026-11-18T00:30:00Z', previous_owner_name: 'Ravi', last_actions: [], note: null,
  allowed_actions: ['acknowledge', 'refuse', 'add_note'], ...over,
});
export const hMachine = (items: HandoverItem[], over: Partial<HandoverMachine> = {}): HandoverMachine => ({ machine_id: 'm-1', code: 'M-1', name: 'Press 1', items, ...over });
export const occurrence = (machines: HandoverMachine[], over: Partial<HandoverOccurrence> = {}): HandoverOccurrence => {
  const pending = machines.reduce((n, m) => n + m.items.filter((i) => i.state === 'pending').length, 0);
  return {
    shift: { id: 'sh-1', name: 'Morning', start_time: '06:00:00', end_time: '14:00:00' }, shift_date: '2026-11-18', window_start: '2026-11-18T00:30:00Z', window_end: '2026-11-18T08:30:00Z',
    running: true, enforced: true, machines, pending_count: pending, declared: false, declared_at: null, overdue_minutes: 60, deadline: '2026-11-18T01:30:00Z',
    allowed_actions: pending === 0 ? ['declare'] : [], ...over,
  } as HandoverOccurrence;
};
export const checklist = (occs: HandoverOccurrence[], over: Partial<HandoverChecklist> = {}): HandoverChecklist => ({
  ok: true, occurrences: occs, pending_total: occs.reduce((n, o) => n + o.pending_count, 0), verify: [], ...over,
});
export const pendingException = (n: number, over: Partial<PendingException> = {}): PendingException => ({
  issue_id: `i-${n}`, supervisor_id: 's-2', supervisor_name: 'Meena', shift_id: 'sh-1', shift_name: 'Morning', shift_date: '2026-11-18', machine_code: `M-${n}`,
  description: `Oil leak ${n}`, priority: 'high', reason: 'Machine was not handed over to me', refused_at: '2026-11-18T01:00:00Z', owner_id: 's-1', owner_name: 'Ravi', minutes_waiting: 25, ...over,
});
export const overdueAck = (n: number, over: Partial<OverdueAck> = {}): OverdueAck => ({
  supervisor_id: 's-2', supervisor_name: 'Meena', shift_id: 'sh-1', shift_name: 'Morning', shift_date: '2026-11-18', machine_code: `M-${n}`, issue_id: `i-${n}`,
  description: `Oil leak ${n}`, priority: 'high', minutes_overdue: 20, ...over,
});
export const alerts = (exceptions: PendingException[], overdue: OverdueAck[] = []): HandoverAlerts => ({
  ok: true, exceptions, exceptions_total: exceptions.length, overdue, overdue_total: overdue.length, alert_count: exceptions.length + overdue.length,
});
