import type { SupabaseClient } from '@supabase/supabase-js';
import { call, readRpc, type RpcClient } from './plant';

// ---- Types (the shapes returned by reading_state / reading_detail / today_board) -----------------------------------------------------------
export type CounterUnit = 'pieces' | 'shots';
export type ReadingStateCode = 'opening_due' | 'opening_done' | 'closing_due' | 'closed' | 'opening_missed';
export type ReadingFlag = 'late_opening' | 'late_closing' | 'rollover' | 'needs_review' | 'over_reported' | 'entered_by_ua';

export type OpeningInfo = { id: string; counter: number; product_id: string; product_code: string | null; recorded_at: string; late: boolean; entered_by_ua: boolean; remarks: string | null };
export type ClosingInfo = { id: string; counter: number; good: number; reject: number; recorded_at: string; late: boolean; entered_by_ua: boolean; remarks: string | null };
export type SummaryInfo = {
  id: string; target: number | null; movement_pieces: number | null; good: number; reject: number; unaccounted: number | null; attainment_pct: number | null;
  rollover: boolean; needs_review: boolean; over_reported: boolean;
};
export type StateMachine = {
  machine_id: string; code: string; name: string; line: string | null; counter_unit: CounterUnit; counter_max: number | null; state: ReadingStateCode;
  can_open: boolean; can_close: boolean; can_correct: boolean; default_product_id: string | null;
  opening: OpeningInfo | null; closing: ClosingInfo | null; summary: SummaryInfo | null;
};
export type Occurrence<M> = {
  shift: { id: string; name: string; start_time: string; end_time: string }; shift_date: string; starts_at: string; ends_at: string; running: boolean; machines: M[];
};
export type ReadingState = { ok: true; state: 'no_shifts' | 'none' | 'active'; occurrences: Occurrence<StateMachine>[] };

export type ReadingEntry = {
  id: string; kind: 'opening' | 'closing'; counter: number; product_id: string | null; product_code: string | null; good: number | null; reject: number | null;
  remarks: string | null; late: boolean; entered_by_ua: boolean; supersedes_id: string | null; correction_reason: string | null;
  recorded_by: string; recorded_by_name: string | null; recorded_at: string; current: boolean;
};
export type SummaryFull = SummaryInfo & {
  calc_version: number; product_id: string; counter_unit: CounterUnit; cavities: number; counter_max: number | null; opening_counter: number; closing_counter: number; reject: number;
  movement_units: number | null; late_opening: boolean; late_closing: boolean; entered_by_ua: boolean; recorded_at: string;
};
export type ReadingPhoto = { id: string; reading_id: string; path: string; mime: string; ready_at: string };
export type ReadingDetail = {
  ok: true;
  machine: { id: string; code: string; name: string; counter_unit: CounterUnit; counter_max: number | null };
  shift: { id: string; name: string; start_time: string; end_time: string };
  shift_date: string; starts_at: string; ends_at: string; owner_id: string | null; owner_name: string | null;
  readings: ReadingEntry[]; opening: ReadingEntry | null; closing: ReadingEntry | null; summary: SummaryFull | null; summary_count: number; photos: ReadingPhoto[];
  allowed: { can_open: boolean; can_close: boolean; can_correct: boolean };
};

export type BoardMachine = {
  machine_id: string; code: string; name: string; counter_unit: CounterUnit; owner_id: string; owner_name: string | null; product_id: string | null; product_code: string | null;
  target: number | null; target_assumed: boolean; opening_status: 'missing' | 'late' | 'on_time'; closing_status: 'missing' | 'late' | 'on_time';
  opening_counter: number | null; closing_counter: number | null; movement_pieces: number | null; good: number | null; reject: number | null; unaccounted: number | null;
  attainment_pct: number | null; flags: ReadingFlag[];
};
export type BoardTotals = {
  machines_expected: number; openings_on_time: number; closings_on_time: number; both_on_time: number; target: number; target_closed: number; good: number; attainment_pct: number | null;
};
export type BoardOccurrence = Occurrence<BoardMachine> & { current: boolean; totals: BoardTotals };
export type TodayBoard = { ok: true; as_of: string; occurrences: BoardOccurrence[] };

// ---- Labels (status is always text, never colour alone) ----------------------------------------------------------------------------------
export const STATE_LABEL: Record<ReadingStateCode, string> = {
  opening_due: 'Opening reading due', opening_done: 'Opening recorded, closing due at the end', closing_due: 'Closing reading due', closed: 'Both readings recorded', opening_missed: 'Opening was not recorded',
};
export const STATUS_LABEL = { missing: 'Missing', late: 'Late', on_time: 'On time' } as const;
export const FLAG_LABEL: Record<ReadingFlag, string> = {
  late_opening: 'Late opening', late_closing: 'Late closing', rollover: 'Counter rolled over', needs_review: 'Needs review',
  over_reported: 'Good + reject is more than the counter movement', entered_by_ua: 'Entered by a Unit Admin',
};
export const UNIT_LABEL: Record<CounterUnit, string> = { pieces: 'Pieces', shots: 'Shots / cycles' };

/** "1250" -> "1,250". */
export const formatCount = (n: number | null | undefined): string => (n === null || n === undefined ? '-' : String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ','));
export const formatPct = (n: number | null | undefined): string => (n === null || n === undefined ? 'No target' : `${Number(n).toFixed(2)}%`);

// ---- Validation (limits and messages equal the server's; the server stays the authority) ---------------------------------------------------
export const MAX_COUNTER = 1_000_000_000_000;
export const MAX_QTY = 10_000_000;
export const LIMITS = { remarks: 500, reason: 200 } as const;
export const MSG = {
  counter: 'Counter: enter a whole number from 0 to 1,000,000,000,000',
  good: 'Good: enter a whole number from 0 to 10,000,000',
  reject: 'Reject: enter a whole number from 0 to 10,000,000',
  product: 'Choose the product',
  remarks: 'Remarks: up to 500 characters',
  reason: 'Enter a reason of 1 to 200 characters',
  max: 'Enter a whole number from 9 to 1,000,000,000,000, or leave it empty',
  cavities: 'Enter a whole number from 1 to 256',
} as const;

/** Parses a whole number typed by a person (digits only, optional thousands commas/spaces). null when it is not one. */
export function parseWhole(text: string): number | null {
  const t = text.replace(/[,\s]/g, '');
  if (!/^\d{1,13}$/.test(t)) return null;
  return Number(t);
}
export function validateCounter(text: string, label: 'counter' = 'counter'): string | null {
  const n = parseWhole(text);
  return n === null || n > MAX_COUNTER ? MSG[label] : null;
}
export function validateQty(text: string, field: 'good' | 'reject'): string | null {
  const n = parseWhole(text);
  return n === null || n > MAX_QTY ? MSG[field] : null;
}
export function validateRemarks(text: string): string | null {
  return text.trim().length > LIMITS.remarks ? MSG.remarks : null;
}
export function validateReason(text: string): string | null {
  const t = text.trim();
  return t.length < 1 || t.length > LIMITS.reason ? MSG.reason : null;
}
export type OpeningForm = { productId: string | null; counter: string; remarks: string };
export type ClosingForm = { counter: string; good: string; reject: string; remarks: string };
export function validateOpening(f: OpeningForm): Record<string, string> {
  const out: Record<string, string> = {};
  if (!f.productId) out.product_id = MSG.product;
  const c = validateCounter(f.counter);
  if (c) out.counter = c;
  const r = validateRemarks(f.remarks);
  if (r) out.remarks = r;
  return out;
}
export function validateClosing(f: ClosingForm): Record<string, string> {
  const out: Record<string, string> = {};
  const c = validateCounter(f.counter);
  if (c) out.counter = c;
  const g = validateQty(f.good, 'good');
  if (g) out.good = g;
  const j = validateQty(f.reject, 'reject');
  if (j) out.reject = j;
  const r = validateRemarks(f.remarks);
  if (r) out.remarks = r;
  return out;
}
export function validateMax(text: string): string | null {
  if (text.trim() === '') return null;
  const n = parseWhole(text);
  return n === null || n < 9 || n > MAX_COUNTER ? MSG.max : null;
}
export function validateCavities(text: string): string | null {
  const n = parseWhole(text);
  return n === null || n < 1 || n > 256 ? MSG.cavities : null;
}

// ---- Reads ---------------------------------------------------------------------------------------------------------------------------------
export const fetchReadingState = (c: RpcClient): Promise<ReadingState> => readRpc<ReadingState>(c, 'reading_state');
export const fetchReadingDetail = (c: RpcClient, machineId: string, shiftId: string, date: string): Promise<ReadingDetail> =>
  readRpc<ReadingDetail>(c, 'reading_detail', { p_machine_id: machineId, p_shift_id: shiftId, p_shift_date: date });
export const fetchTodayBoard = (c: RpcClient): Promise<TodayBoard> => readRpc<TodayBoard>(c, 'today_board');

export type CavityRow = { id: string; product_id: string; effective_from: string; cavities: number | null; recorded_at: string };
/** Cavity history of one machine (Unit Admins read the table under RLS; the append-only list is shown newest first). */
export async function fetchCavityVersions(client: Pick<SupabaseClient, 'from'>, machineId: string): Promise<CavityRow[]> {
  const { data, error } = await client.from('cavity_version').select('id, product_id, effective_from, cavities, recorded_at').eq('machine_id', machineId)
    .order('effective_from', { ascending: false }).order('recorded_at', { ascending: false }).range(0, 99);
  if (error) throw error;
  return (data ?? []) as CavityRow[];
}
export type MachineCounter = { counter_unit: CounterUnit; counter_max: number | null };
export async function fetchMachineCounter(client: Pick<SupabaseClient, 'from'>, machineId: string): Promise<MachineCounter | null> {
  const { data, error } = await client.from('machine').select('counter_unit, counter_max').eq('id', machineId).maybeSingle();
  if (error) throw error;
  return (data as MachineCounter | null) ?? null;
}

// ---- Writes (RPC) --------------------------------------------------------------------------------------------------------------------------
export const readingApi = {
  opening: (c: RpcClient, i: { machineId: string; shiftId: string; shiftDate: string; productId: string; counter: string; remarks: string }, rid: string) =>
    call(c, 'rd_opening', {
      p_request_id: rid, p_machine_id: i.machineId, p_shift_id: i.shiftId, p_shift_date: i.shiftDate, p_product_id: i.productId, p_counter: parseWhole(i.counter),
      p_remarks: i.remarks.trim() === '' ? null : i.remarks.trim(),
    }),
  closing: (c: RpcClient, i: { machineId: string; shiftId: string; shiftDate: string; counter: string; good: string; reject: string; remarks: string }, rid: string) =>
    call(c, 'rd_closing', {
      p_request_id: rid, p_machine_id: i.machineId, p_shift_id: i.shiftId, p_shift_date: i.shiftDate, p_counter: parseWhole(i.counter), p_good: parseWhole(i.good),
      p_reject: parseWhole(i.reject), p_remarks: i.remarks.trim() === '' ? null : i.remarks.trim(),
    }),
  correct: (c: RpcClient, i: { readingId: string; kind: 'opening' | 'closing'; productId: string | null; counter: string; good: string; reject: string; remarks: string; reason: string }, rid: string) =>
    call(c, 'rd_correct', {
      p_request_id: rid, p_reading_id: i.readingId, p_counter: parseWhole(i.counter), p_product_id: i.kind === 'opening' ? i.productId : null,
      p_good: i.kind === 'closing' ? parseWhole(i.good) : null, p_reject: i.kind === 'closing' ? parseWhole(i.reject) : null,
      p_remarks: i.remarks.trim() === '' ? null : i.remarks.trim(), p_reason: i.reason.trim(),
    }),
  setCounter: (c: RpcClient, machineId: string, unit: CounterUnit, max: string, rid: string) =>
    call(c, 'rd_set_machine_counter', { p_request_id: rid, p_machine_id: machineId, p_unit: unit, p_max: max.trim() === '' ? null : parseWhole(max) }),
  setCavities: (c: RpcClient, machineId: string, productId: string, cavities: string, from: string, rid: string) =>
    call(c, 'rd_set_cavities', { p_request_id: rid, p_machine_id: machineId, p_product_id: productId, p_cavities: parseWhole(cavities), p_effective_from: from }),
  endCavities: (c: RpcClient, machineId: string, productId: string, from: string, rid: string) =>
    call(c, 'rd_end_cavities', { p_request_id: rid, p_machine_id: machineId, p_product_id: productId, p_effective_from: from }),
};
