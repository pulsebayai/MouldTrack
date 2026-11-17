import type { SupabaseClient } from '@supabase/supabase-js';
import { call, readRpc, type RpcClient } from './plant';

// ---- Types (the shapes returned by issue_list / issue_detail / issue_alerts) -------------------------------------------------------------
export type Priority = 'low' | 'medium' | 'high' | 'critical';
export type IssueStatus = 'open' | 'in_progress' | 'resolved' | 'closed';
export type AllowedAction = 'note' | 'photo' | 'start' | 'set_assignee' | 'escalate' | 'ack_escalation' | 'reassign' | 'resolve' | 'verify' | 'reopen';

export type IssueRow = {
  id: string; machine_id: string; machine_code: string; machine_name: string; category: string; category_id: string;
  priority: Priority; status: IssueStatus; machine_stopped: boolean; escalated: boolean; description: string; technical_assignee: string | null;
  owner_id: string | null; owner_name: string | null; needs_owner: boolean; reported_by: string; reported_by_name: string | null; reported_at: string;
  resolved_at: string | null; closed_at: string | null; resolution_notes: string | null; age_minutes: number;
  resolved_by_name?: string | null; closed_by_name?: string | null;
};
export type IssueAttachment = { id: string; path: string; mime: string; size_bytes: number };
export type IssueAction = {
  id: string; type: string; at: string; actor_id: string; actor_name: string | null; actor_role: string; notes: string | null;
  status_before: IssueStatus | null; status_after: IssueStatus | null; attachments: IssueAttachment[];
};
export type OwnershipEntry = {
  at: string; source: string; reason: string | null; previous_owner: string | null; previous_owner_name: string | null;
  new_owner: string | null; new_owner_name: string | null; actor_id: string | null; actor_name: string | null;
};
export type IssueDetail = { ok: true; issue: IssueRow; actions: IssueAction[]; ownership: OwnershipEntry[]; allowed_actions: AllowedAction[] };
export type IssueList = { ok: true; page: number; page_size: number; total: number; items: IssueRow[] };
export type IssueAlerts = { ok: true; alert_count: number; alerts: IssueRow[]; recently_closed: IssueRow[] };
export type IssueCategory = { id: string; name: string; retired_at: string | null };
export type IssueFilters = {
  status?: IssueStatus | 'not_closed'; priority?: Priority; category_id?: string; machine_id?: string; escalated?: boolean; stopped?: boolean; needs_owner?: boolean;
};

// ---- Labels (status is always text, never colour alone) -----------------------------------------------------------------------------------
export const PRIORITIES: Priority[] = ['low', 'medium', 'high', 'critical'];
export const PRIORITY_LABEL: Record<Priority, string> = { low: 'Low', medium: 'Medium', high: 'High', critical: 'Critical' };
export const STATUS_LABEL: Record<IssueStatus, string> = { open: 'Open', in_progress: 'In progress', resolved: 'Awaiting verification', closed: 'Closed' };
export const ACTION_LABEL: Record<string, string> = {
  report: 'Reported', note: 'Note added', photo: 'Photo added', start: 'Work started', assignee: 'Technical assignee set', escalate: 'Escalated',
  escalation_ack: 'Escalation acknowledged', reassign: 'Owner changed', resolve: 'Marked resolved', verify_confirm: 'Fix confirmed',
  verify_reject: 'Fix rejected', reopen: 'Reopened',
};
/** Limits and messages equal the server's (N-8): the form answers instantly, the server stays the authority. */
export const LIMITS = { description: 1000, note: 1000, resolution: 1000, assignee: 80, reason: 200, ackNote: 200, category: 40 } as const;
export const MSG = {
  category: 'Choose a category',
  description: 'Describe the problem in 1 to 1000 characters',
  reason: 'Enter a reason of 1 to 200 characters',
  note: 'Enter a note of 1 to 1000 characters',
  ackNote: 'Enter a note of 1 to 200 characters',
  resolution: 'Enter resolution notes of 1 to 1000 characters',
  assignee: 'Enter who is fixing it, up to 80 characters',
  categoryName: 'Enter a name of 1 to 40 characters',
} as const;

/** A stopped machine is always Critical (the server enforces it; the form only shows it). */
export function effectivePriority(priority: Priority | null, stopped: boolean): Priority | null {
  return stopped ? 'critical' : priority;
}

export function validateReport(f: { categoryId: string | null; priority: Priority | null; description: string; stopped: boolean }): Record<string, string> {
  const out: Record<string, string> = {};
  if (!f.categoryId) out.category_id = MSG.category;
  const d = f.description.trim();
  if (d.length < 1 || d.length > 1000) out.description = MSG.description;
  if (!effectivePriority(f.priority, f.stopped)) out.priority = 'Choose a priority';
  return out;
}
export function validateText(text: string, max: number, message: string): string | null {
  const t = text.trim();
  return t.length < 1 || t.length > max ? message : null;
}

export function formatAge(minutes: number): string {
  if (minutes < 1) return 'just now';
  if (minutes < 60) return `${minutes} min`;
  const h = Math.floor(minutes / 60);
  if (h < 48) return `${h} h ${minutes % 60} min`;
  return `${Math.floor(h / 24)} days`;
}

// ---- Reads ---------------------------------------------------------------------------------------------------------------------------------
export const fetchIssueList = (c: RpcClient, filters: IssueFilters, page: number): Promise<IssueList> =>
  readRpc<IssueList>(c, 'issue_list', { p_filters: filters, p_page: page });
export const fetchIssueDetail = (c: RpcClient, id: string): Promise<IssueDetail> => readRpc<IssueDetail>(c, 'issue_detail', { p_id: id });
export const fetchIssueAlerts = (c: RpcClient): Promise<IssueAlerts> => readRpc<IssueAlerts>(c, 'issue_alerts');

export async function fetchCategories(client: Pick<SupabaseClient, 'from'>, opts: { includeRetired?: boolean } = {}): Promise<IssueCategory[]> {
  let q = client.from('issue_category').select('id, name, retired_at').order('name', { ascending: true });
  if (!opts.includeRetired) q = q.is('retired_at', null);
  const { data, error } = await q;
  if (error) throw error;
  return (data ?? []) as IssueCategory[];
}

// ---- Writes (RPC) --------------------------------------------------------------------------------------------------------------------------
export const issueApi = {
  report: (c: RpcClient, i: { machineId: string; categoryId: string; priority: Priority; description: string; stopped: boolean }, rid: string) =>
    call(c, 'iss_report', {
      p_request_id: rid, p_machine_id: i.machineId, p_category_id: i.categoryId, p_priority: i.priority, p_description: i.description.trim(), p_machine_stopped: i.stopped,
    }),
  note: (c: RpcClient, id: string, notes: string, rid: string) => call(c, 'iss_note', { p_request_id: rid, p_issue_id: id, p_notes: notes.trim() }),
  start: (c: RpcClient, id: string, rid: string) => call(c, 'iss_start', { p_request_id: rid, p_issue_id: id }),
  setAssignee: (c: RpcClient, id: string, assignee: string, rid: string) => call(c, 'iss_set_assignee', { p_request_id: rid, p_issue_id: id, p_assignee: assignee.trim() }),
  escalate: (c: RpcClient, id: string, reason: string, rid: string) => call(c, 'iss_escalate', { p_request_id: rid, p_issue_id: id, p_reason: reason.trim() }),
  ackEscalation: (c: RpcClient, id: string, note: string, rid: string) => call(c, 'iss_ack_escalation', { p_request_id: rid, p_issue_id: id, p_note: note.trim() }),
  reassign: (c: RpcClient, id: string, newOwner: string, reason: string, rid: string) =>
    call(c, 'iss_reassign', { p_request_id: rid, p_issue_id: id, p_new_owner: newOwner, p_reason: reason.trim() }),
  resolve: (c: RpcClient, id: string, notes: string, rid: string) => call(c, 'iss_resolve', { p_request_id: rid, p_issue_id: id, p_notes: notes.trim() }),
  verify: (c: RpcClient, id: string, confirm: boolean, reason: string | null, rid: string) =>
    call(c, 'iss_verify', { p_request_id: rid, p_issue_id: id, p_confirm: confirm, p_reason: reason === null ? null : reason.trim() }),
  reopen: (c: RpcClient, id: string, reason: string, rid: string) => call(c, 'iss_reopen', { p_request_id: rid, p_issue_id: id, p_reason: reason.trim() }),
  saveCategory: (c: RpcClient, id: string | null, name: string, rid: string) => call(c, 'iss_category_save', { p_request_id: rid, p_id: id, p_name: name.trim() }),
  setCategoryRetired: (c: RpcClient, id: string, retired: boolean, rid: string) => call(c, 'iss_category_set_retired', { p_request_id: rid, p_id: id, p_retired: retired }),
};
