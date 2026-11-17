import type { AllowedAction, IssueAction, IssueDetail, IssueRow } from '@/lib/issues';

export const issue = (n: number, over: Partial<IssueRow> = {}): IssueRow => ({
  id: `i-${n}`, machine_id: 'm-1', machine_code: `M-${n}`, machine_name: `Press ${n}`, category: 'Hydraulics', category_id: 'c-1', priority: 'high', status: 'open',
  machine_stopped: false, escalated: false, description: `Oil leak ${n}`, technical_assignee: null, owner_id: 'me', owner_name: 'Asha', needs_owner: false,
  reported_by: 'me', reported_by_name: 'Asha', reported_at: '2026-11-17T04:00:00Z', resolved_at: null, closed_at: null, resolution_notes: null, age_minutes: 90, ...over,
});
export const action = (n: number, type: string, over: Partial<IssueAction> = {}): IssueAction => ({
  id: `a-${n}`, type, at: '2026-11-17T04:00:00Z', actor_id: 'me', actor_name: 'Asha', actor_role: 'supervisor', notes: null, status_before: null, status_after: 'open', attachments: [], ...over,
});
export const detail = (allowed: AllowedAction[], over: Partial<IssueRow> = {}, actions: IssueAction[] = [action(1, 'report', { notes: 'Oil leak 1' })]): IssueDetail => ({
  ok: true, issue: issue(1, over), actions, ownership: [{ at: '2026-11-17T04:00:00Z', source: 'report', reason: null, previous_owner: null, previous_owner_name: null, new_owner: 'me', new_owner_name: 'Asha', actor_id: 'me', actor_name: 'Asha' }],
  allowed_actions: allowed,
});
export const category = (n: number, retired = false) => ({ id: `c-${n}`, name: n === 1 ? 'Hydraulics' : `Category ${n}`, retired_at: retired ? '2026-11-01T00:00:00Z' : null });
