import type { SupabaseClient } from '@supabase/supabase-js';
import type { IssueRow } from './issues';
import { call, readRpc, type RpcClient } from './plant';

// ---- Types (the shapes returned by handover_checklist / handover_alerts) -------------------------------------------------------------------
export type ItemState = 'pending' | 'acknowledged' | 'refused';
export type ItemAction = 'acknowledge' | 'refuse' | 'add_note';
export type HandoverActionLine = { type: string; notes: string | null; at: string; actor_name: string | null };
export type HandoverNote = { note: string; at: string; author_name: string | null; shift_date: string };
export type HandoverItem = IssueRow & {
  state: ItemState; exception_pending: boolean; handled_at: string | null; handover_start: string; previous_owner_name: string | null;
  last_actions: HandoverActionLine[]; note: HandoverNote | null; allowed_actions: ItemAction[];
};
export type HandoverMachine = { machine_id: string; code: string; name: string; items: HandoverItem[] };
export type HandoverOccurrence = {
  shift: { id: string; name: string; start_time: string; end_time: string }; shift_date: string; window_start: string; window_end: string; running: boolean;
  enforced: boolean; machines: HandoverMachine[]; pending_count: number; declared: boolean; declared_at: string | null; overdue_minutes: number; deadline: string;
  allowed_actions: 'declare'[] | [];
};
export type HandoverChecklist = { ok: true; occurrences: HandoverOccurrence[]; pending_total: number; verify: IssueRow[] };

export type PendingException = {
  issue_id: string; supervisor_id: string; supervisor_name: string | null; shift_id: string; shift_name: string; shift_date: string; machine_code: string;
  description: string; priority: string; reason: string | null; refused_at: string; owner_id: string | null; owner_name: string | null; minutes_waiting: number;
};
export type OverdueAck = {
  supervisor_id: string; supervisor_name: string | null; shift_id: string; shift_name: string; shift_date: string; machine_code: string; issue_id: string;
  description: string; priority: string; minutes_overdue: number;
};
export type HandoverAlerts = { ok: true; exceptions: PendingException[]; exceptions_total: number; overdue: OverdueAck[]; overdue_total: number; alert_count: number };

// ---- Labels (status is always text, never colour alone) ------------------------------------------------------------------------------------
export const ITEM_STATE_LABEL: Record<ItemState, string> = { pending: 'Not answered yet', acknowledged: 'Acknowledged', refused: 'Refused - waiting for the Unit Admin' };
export const GATE_MESSAGE = 'Complete your handover checklist first';

// ---- Validation (limits and messages equal the server's; the server stays the authority) ---------------------------------------------------
export const LIMITS = { remark: 200, reason: 200, note: 300 } as const;
export const MSG = {
  remark: 'Remark: up to 200 characters',
  refuse: 'Enter a reason of 1 to 200 characters',
  exception: 'Enter a reason of 1 to 200 characters',
  note: 'Enter a note of 1 to 300 characters',
  owner: 'Choose the supervisor who owns this issue now',
  minutes: 'Enter 15 to 480 minutes',
} as const;

const between = (text: string, max: number): boolean => {
  const n = text.trim().length;
  return n >= 1 && n <= max;
};
/** The remark on an acknowledgement is optional. */
export const validateRemark = (text: string): string | null => (text.trim() === '' || between(text, LIMITS.remark) ? null : MSG.remark);
export const validateRefusal = (text: string): string | null => (between(text, LIMITS.reason) ? null : MSG.refuse);
export const validateExceptionReason = (text: string): string | null => (between(text, LIMITS.reason) ? null : MSG.exception);
export const validateNote = (text: string): string | null => (between(text, LIMITS.note) ? null : MSG.note);
/** Overdue minutes typed by a person: a whole number from 15 to 480. */
export function validateMinutes(text: string): string | null {
  const t = text.trim();
  if (!/^\d{1,4}$/.test(t)) return MSG.minutes;
  const n = Number(t);
  return n < 15 || n > 480 ? MSG.minutes : null;
}

// ---- Derived text and decisions (the server decides; these only read what it returned) ---------------------------------------------------
/** Home banner for a supervisor: null when there is nothing to answer or declare. */
export function bannerText(c: Pick<HandoverChecklist, 'pending_total' | 'occurrences'> | null | undefined): string | null {
  const n = c?.pending_total ?? 0;
  if (n > 0) return `Handover: ${n} to acknowledge`;
  const declare = (c?.occurrences ?? []).some((o) => o.allowed_actions.length > 0);
  return declare ? 'Handover: ready to declare' : null;
}
/** True when the server says the opening for this occurrence is waiting for the handover declaration (enforced and not declared). */
export function openingBlocked(c: Pick<HandoverChecklist, 'occurrences'> | null | undefined, shiftId: string, date: string): boolean {
  const o = (c?.occurrences ?? []).find((x) => x.shift.id === shiftId && x.shift_date === date);
  return !!o && o.enforced && !o.declared;
}
/** Occurrences still to complete (not declared), for the checklist screen order. */
export const pendingOccurrences = (c: Pick<HandoverChecklist, 'occurrences'> | null | undefined): HandoverOccurrence[] => (c?.occurrences ?? []).filter((o) => !o.declared);

// ---- Reads ---------------------------------------------------------------------------------------------------------------------------------
/** The checklist read records the overdue snapshot the first time it opens, so it is a POST (supabase-js rpc is a POST unless `get: true`). */
export async function fetchHandoverChecklist(c: RpcClient): Promise<HandoverChecklist> {
  const d = await readRpc<Partial<HandoverChecklist>>(c, 'handover_checklist');
  return { ok: true, occurrences: d.occurrences ?? [], pending_total: d.pending_total ?? 0, verify: d.verify ?? [] };
}
export async function fetchHandoverAlerts(c: RpcClient): Promise<HandoverAlerts> {
  const d = await readRpc<Partial<HandoverAlerts>>(c, 'handover_alerts');
  return { ok: true, exceptions: d.exceptions ?? [], exceptions_total: d.exceptions_total ?? 0, overdue: d.overdue ?? [], overdue_total: d.overdue_total ?? 0, alert_count: d.alert_count ?? 0 };
}
/** The overdue minutes in force for the tenant (a Unit Admin reads the row under RLS); null when the tenant has no row. */
export async function fetchOverdueMinutes(client: Pick<SupabaseClient, 'from'>): Promise<{ overdue_minutes: number; required: boolean } | null> {
  const { data, error } = await client.from('handover_setting').select('overdue_minutes, required').maybeSingle();
  if (error) throw error;
  return (data as { overdue_minutes: number; required: boolean } | null) ?? null;
}

// ---- Writes (RPC) --------------------------------------------------------------------------------------------------------------------------
type Occ = { issueId: string; shiftId: string; shiftDate: string };
export const handoverApi = {
  acknowledge: (c: RpcClient, i: Occ & { remark: string }, rid: string) =>
    call(c, 'ho_acknowledge', { p_request_id: rid, p_issue_id: i.issueId, p_shift_id: i.shiftId, p_shift_date: i.shiftDate, p_remark: i.remark.trim() === '' ? null : i.remark.trim() }),
  refuse: (c: RpcClient, i: Occ & { reason: string }, rid: string) =>
    call(c, 'ho_refuse', { p_request_id: rid, p_issue_id: i.issueId, p_shift_id: i.shiftId, p_shift_date: i.shiftDate, p_reason: i.reason.trim() }),
  declare: (c: RpcClient, i: { shiftId: string; shiftDate: string }, rid: string) =>
    call(c, 'ho_declare', { p_request_id: rid, p_shift_id: i.shiftId, p_shift_date: i.shiftDate }),
  addNote: (c: RpcClient, i: Occ & { note: string }, rid: string) =>
    call(c, 'ho_add_note', { p_request_id: rid, p_issue_id: i.issueId, p_shift_id: i.shiftId, p_shift_date: i.shiftDate, p_note: i.note.trim() }),
  /** The owner to hold the issue from now on: the current owner means "keep" (the server records kept = true), another active supervisor reassigns. */
  exception: (c: RpcClient, i: Occ & { reason: string; ownerId: string }, rid: string) =>
    call(c, 'ho_exception', { p_request_id: rid, p_issue_id: i.issueId, p_shift_id: i.shiftId, p_shift_date: i.shiftDate, p_reason: i.reason.trim(), p_owner_id: i.ownerId }),
  setOverdue: (c: RpcClient, minutes: string, rid: string) => call(c, 'ho_set_overdue', { p_request_id: rid, p_minutes: Number(minutes.trim()) }),
};
