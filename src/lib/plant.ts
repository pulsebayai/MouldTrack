import type { SupabaseClient } from '@supabase/supabase-js';
import { ApiError, keepRequestIdAfter, newRequestId } from './api';
import { MESSAGES } from './errors';

export const PLANT_PAGE_SIZE = 25;

export type Site = { id: string; name: string; timezone: string };
export type Line = { id: string; name: string; archived_at: string | null };
export type MachineStatus = 'active' | 'under_maintenance';
export type Machine = {
  id: string;
  code: string;
  name: string;
  asset_tag: string | null;
  make: string | null;
  model: string | null;
  controller: string | null;
  line_id: string | null;
  status: MachineStatus;
  retired_at: string | null;
};
export type Product = { id: string; code: string; description: string; uom: string; retired_at: string | null };
export type TargetVersion = {
  id: string;
  machine_id: string;
  product_id: string;
  effective_from: string; // plant date, YYYY-MM-DD
  pieces_per_shift: number | null; // null = ended
  recorded_by: string;
  recorded_at: string;
};

type Db = Pick<SupabaseClient, 'from'>;
type RpcClient = Pick<SupabaseClient, 'rpc'>;

/** Escapes the LIKE wildcard `_` so a search for "M_1" matches literally (`%` is already removed by sanitiseSearch). */
function likeTerm(q: string): string {
  return sanitiseSearch(q).replace(/_/g, '\\_');
}

/** Removes characters that would change the meaning of a PostgREST `or`/`ilike` filter. */
export function sanitiseSearch(q: string): string {
  return q.replace(/[,()%*\\"]/g, '').trim();
}

// ---- Labels (status is always text) ------------------------------------------------------------------------------------
export function machineStatusLabel(m: Pick<Machine, 'status' | 'retired_at'>): 'Active' | 'Under maintenance' | 'Retired' {
  if (m.retired_at) return 'Retired';
  return m.status === 'under_maintenance' ? 'Under maintenance' : 'Active';
}
export const productStatusLabel = (p: Pick<Product, 'retired_at'>): 'Active' | 'Retired' => (p.retired_at ? 'Retired' : 'Active');

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
/** "2026-11-18" -> "18 Nov 2026". Plant dates are calendar dates: no timezone conversion is ever applied. */
export function formatPlantDate(d: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(d);
  if (!m) return d;
  return `${Number(m[3])} ${MONTHS[Number(m[2]) - 1] ?? m[2]} ${m[1]}`;
}
export const formatPieces = (n: number): string => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ',');

// ---- Client-side validation (mirrors the server so the form answers instantly; the server stays the authority) -----------------
export const MSG = {
  code: 'Code: 1 to 20 letters, digits, - _ or /',
  name: 'Enter a name of 1 to 80 characters',
  lineName: 'Enter a name of 1 to 60 characters',
  siteName: 'Enter a name of 1 to 80 characters',
  description: 'Enter a description of 1 to 120 characters',
  uom: 'Unit of measure: 1 to 10 characters',
  optional: (label: string) => `${label}: up to 80 characters`,
  pieces: 'Enter a whole number from 1 to 1,000,000',
  dateFormat: 'Enter a date as YYYY-MM-DD',
  past: "Targets can't start in the past",
} as const;

export const CODE_RE = /^[A-Za-z0-9_/-]{1,20}$/;

export type FieldErrors<K extends string = string> = Partial<Record<K, string>>;

export function validateMachineForm(f: { code: string; name: string; asset_tag: string; make: string; model: string; controller: string }): FieldErrors {
  const e: FieldErrors = {};
  if (!CODE_RE.test(f.code.trim())) e.code = MSG.code;
  const n = f.name.trim();
  if (n.length < 1 || n.length > 80) e.name = MSG.name;
  for (const [k, label] of [['asset_tag', 'Asset tag'], ['make', 'Make'], ['model', 'Model'], ['controller', 'Controller']] as const) {
    if (f[k].trim().length > 80) e[k] = MSG.optional(label);
  }
  return e;
}

export function validateProductForm(f: { code: string; description: string; uom: string }): FieldErrors {
  const e: FieldErrors = {};
  if (!CODE_RE.test(f.code.trim())) e.code = MSG.code;
  const d = f.description.trim();
  if (d.length < 1 || d.length > 120) e.description = MSG.description;
  const u = f.uom.trim();
  if (u.length > 10) e.uom = MSG.uom; // blank means the default, pcs
  return e;
}

/** "1,200" / "1 200" / "1200" -> 1200; anything else (decimals, signs, 0, > 1 000 000) -> null. */
export function parsePieces(text: string): number | null {
  const t = text.replace(/[,\s]/g, '');
  if (!/^\d{1,7}$/.test(t)) return null;
  const n = Number(t);
  return n >= 1 && n <= 1_000_000 ? n : null;
}

/** A real calendar date in YYYY-MM-DD form. */
export function isValidDate(text: string): boolean {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text.trim());
  if (!m) return false;
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const dt = new Date(Date.UTC(y, mo - 1, d));
  return dt.getUTCFullYear() === y && dt.getUTCMonth() === mo - 1 && dt.getUTCDate() === d;
}

/** Target form: pieces and a start date that is not before the plant date the server reported. */
export function validateTargetForm(f: { pieces: string; date: string }, today: string | null, opts: { needPieces: boolean } = { needPieces: true }): FieldErrors {
  const e: FieldErrors = {};
  if (opts.needPieces && parsePieces(f.pieces) === null) e.pieces = MSG.pieces;
  const d = f.date.trim();
  if (!isValidDate(d)) e.effective_from = MSG.dateFormat;
  else if (today && d < today) e.effective_from = MSG.past; // ISO dates compare as strings
  return e;
}

// ---- Reads (RLS scopes everything to the caller's tenant) ------------------------------------------------------------------------
const MACHINE_COLUMNS = 'id, code, name, asset_tag, make, model, controller, line_id, status, retired_at';
const PRODUCT_COLUMNS = 'id, code, description, uom, retired_at';

export async function fetchSite(client: Db): Promise<Site | null> {
  const { data, error } = await client.from('site').select('id, name, timezone').maybeSingle();
  if (error) throw error;
  return (data as unknown as Site) ?? null;
}

/** True once any target exists for the tenant: from then on the site timezone is locked (R2). Head count, no rows. */
export async function fetchHasTargets(client: Db): Promise<boolean> {
  const { count, error } = await client.from('target_version').select('id', { count: 'exact', head: true });
  if (error) throw error;
  return (count ?? 0) > 0;
}

/** The tenant's default timezone (offered when the site is first set up). */
export async function fetchTenantTimezone(client: Db): Promise<string | null> {
  const { data, error } = await client.from('tenant').select('timezone').maybeSingle();
  if (error) throw error;
  return (data as { timezone: string } | null)?.timezone ?? null;
}

/** The site's plant date as the server computes it (never derived from the device clock). */
export async function fetchPlantToday(client: Db): Promise<string | null> {
  const { data, error } = await client.from('plant_today').select('plant_date').maybeSingle();
  if (error) throw error;
  return (data as { plant_date: string } | null)?.plant_date ?? null;
}

export async function fetchLines(client: Db, opts: { includeArchived?: boolean } = {}): Promise<Line[]> {
  let q = client.from('line').select('id, name, archived_at');
  if (!opts.includeArchived) q = q.is('archived_at', null);
  const { data, error } = await q.order('name', { ascending: true });
  if (error) throw error;
  return (data ?? []) as unknown as Line[];
}

export type MachineStatusFilter = 'all' | 'active' | 'under_maintenance';
export type MachineQuery = { search: string; status: MachineStatusFilter; line: 'all' | 'none' | string; showRetired: boolean; page: number };

export async function fetchMachines(client: Db, query: MachineQuery): Promise<{ rows: Machine[]; total: number }> {
  let q = client.from('machine').select(MACHINE_COLUMNS, { count: 'exact' });
  const term = likeTerm(query.search);
  if (term) q = q.or(`code.ilike.%${term}%,name.ilike.%${term}%`);
  if (query.status !== 'all') q = q.eq('status', query.status);
  if (query.line === 'none') q = q.is('line_id', null);
  else if (query.line !== 'all') q = q.eq('line_id', query.line);
  if (!query.showRetired) q = q.is('retired_at', null);
  const from = query.page * PLANT_PAGE_SIZE;
  const { data, count, error } = await q.order('code', { ascending: true }).range(from, from + PLANT_PAGE_SIZE - 1);
  if (error) throw error;
  return { rows: (data ?? []) as unknown as Machine[], total: count ?? 0 };
}

export async function fetchMachine(client: Db, id: string): Promise<Machine | null> {
  const { data, error } = await client.from('machine').select(MACHINE_COLUMNS).eq('id', id).maybeSingle();
  if (error) throw error;
  return (data as unknown as Machine) ?? null;
}

export type ProductStatusFilter = 'all' | 'active';
export type ProductQuery = { search: string; showRetired: boolean; page: number };

export async function fetchProducts(client: Db, query: ProductQuery): Promise<{ rows: Product[]; total: number }> {
  let q = client.from('product').select(PRODUCT_COLUMNS, { count: 'exact' });
  const term = likeTerm(query.search);
  if (term) q = q.or(`code.ilike.%${term}%,description.ilike.%${term}%`);
  if (!query.showRetired) q = q.is('retired_at', null);
  const from = query.page * PLANT_PAGE_SIZE;
  const { data, count, error } = await q.order('code', { ascending: true }).range(from, from + PLANT_PAGE_SIZE - 1);
  if (error) throw error;
  return { rows: (data ?? []) as unknown as Product[], total: count ?? 0 };
}

export async function fetchProduct(client: Db, id: string): Promise<Product | null> {
  const { data, error } = await client.from('product').select(PRODUCT_COLUMNS).eq('id', id).maybeSingle();
  if (error) throw error;
  return (data as unknown as Product) ?? null;
}

/** Active products for the target picker. */
export async function fetchActiveProducts(client: Db): Promise<Product[]> {
  const { data, error } = await client.from('product').select(PRODUCT_COLUMNS).is('retired_at', null).order('code', { ascending: true });
  if (error) throw error;
  return (data ?? []) as unknown as Product[];
}

/** Products by id, retired ones included (target history keeps naming a product after it is retired). */
export async function fetchProductsByIds(client: Db, ids: string[]): Promise<Product[]> {
  if (ids.length === 0) return [];
  const { data, error } = await client.from('product').select(PRODUCT_COLUMNS).in('id', [...new Set(ids)]);
  if (error) throw error;
  return (data ?? []) as unknown as Product[];
}

export async function fetchTargetVersions(client: Db, machineId: string): Promise<TargetVersion[]> {
  const { data, error } = await client
    .from('target_version')
    .select('id, machine_id, product_id, effective_from, pieces_per_shift, recorded_by, recorded_at')
    .eq('machine_id', machineId)
    .order('effective_from', { ascending: false })
    .order('recorded_at', { ascending: false });
  if (error) throw error;
  return (data ?? []) as unknown as TargetVersion[];
}

/** Names of the people who recorded versions (a Unit Admin reads the tenant's memberships under RLS). */
export async function fetchRecorderNames(client: Db, userIds: string[]): Promise<Record<string, string>> {
  const ids = [...new Set(userIds)];
  if (ids.length === 0) return {};
  const { data, error } = await client.from('membership').select('user_id, full_name').in('user_id', ids);
  if (error) throw error;
  return Object.fromEntries(((data ?? []) as unknown as { user_id: string; full_name: string }[]).map((r) => [r.user_id, r.full_name]));
}

// ---- Target summary (display only; the authoritative lookup is app.target_for on the server) ------------------------------------
export type PairSummary = {
  productId: string;
  current: { pieces: number; from: string } | null;
  next: { pieces: number | null; from: string } | null; // pieces null = the target ends then
  history: TargetVersion[]; // newest first
};

/** The version that wins on one date among several recorded for it: the latest recorded. */
const latestFirst = (a: TargetVersion, b: TargetVersion) =>
  a.effective_from !== b.effective_from ? (a.effective_from < b.effective_from ? 1 : -1) : a.recorded_at < b.recorded_at ? 1 : a.recorded_at > b.recorded_at ? -1 : 0;

/** Groups a machine's versions by product and works out current and next from the server's plant date (AC-7, AC-9). */
export function summariseTargets(versions: TargetVersion[], today: string): PairSummary[] {
  const byProduct = new Map<string, TargetVersion[]>();
  for (const v of versions) byProduct.set(v.product_id, [...(byProduct.get(v.product_id) ?? []), v]);
  const out: PairSummary[] = [];
  for (const [productId, list] of byProduct) {
    const history = [...list].sort(latestFirst);
    const past = history.filter((v) => v.effective_from <= today);
    const cur = past[0];
    const future = history.filter((v) => v.effective_from > today);
    // Walk the future dates in order (on each, the latest recorded version wins). The next change is the first date whose
    // outcome differs from what is in force before it; a same-day end that cancels a scheduled change is not a change.
    let inForce = cur ? cur.pieces_per_shift : null;
    let nextV: TargetVersion | undefined;
    const dates = [...new Set(future.map((v) => v.effective_from))].sort();
    for (const d of dates) {
      const winner = future.find((v) => v.effective_from === d)!; // history is newest first within a date
      if (winner.pieces_per_shift !== inForce) {
        nextV = winner;
        break;
      }
    }
    out.push({
      productId,
      current: cur && cur.pieces_per_shift !== null ? { pieces: cur.pieces_per_shift, from: cur.effective_from } : null,
      next: nextV ? { pieces: nextV.pieces_per_shift, from: nextV.effective_from } : null,
      history,
    });
  }
  return out;
}

/** The scheduled (later than `date`) targets that ending on `date` would also cancel: per later date, the winning version if it is a target. */
export function scheduledAfter(versions: TargetVersion[], date: string): { from: string; pieces: number }[] {
  const sorted = [...versions].sort(latestFirst);
  const dates = [...new Set(sorted.filter((v) => v.effective_from > date).map((v) => v.effective_from))].sort();
  const out: { from: string; pieces: number }[] = [];
  for (const d of dates) {
    const winner = sorted.find((v) => v.effective_from === d)!;
    if (winner.pieces_per_shift !== null) out.push({ from: d, pieces: winner.pieces_per_shift });
  }
  return out;
}

// ---- Writes (RPC) ---------------------------------------------------------------------------------------------------------------
/** A server refusal. `field` names the form field for validation/duplicate errors; `machines` lists blocking machine codes. */
export class PlantError extends ApiError {
  constructor(status: number, field: string | undefined, message: string, code?: string, public machines?: string[], public dates?: string[]) {
    super(status, field, message, code);
    this.name = 'PlantError';
  }
}

type RpcError = { code?: string; message?: string; details?: string | null } | null;

/** Turns a PostgREST error into something the form can show. Network failures are re-thrown untouched (toUserMessage handles them). */
function mapRpcError(error: NonNullable<RpcError> & Record<string, unknown>, status: number | undefined): never {
  if (error.code === 'P0001') {
    let detail: { code?: string; field?: string; machines?: string[]; dates?: string[] } = {};
    try {
      detail = JSON.parse(String(error.details ?? '{}'));
    } catch {
      detail = {};
    }
    throw new PlantError(400, detail.field, String(error.message ?? MESSAGES.generic), detail.code, detail.machines, detail.dates);
  }
  if (status === 401) throw new PlantError(401, undefined, 'Sign in again', 'unauthenticated'); // expired session (R4 item 10)
  if (typeof status === 'number' && status >= 500) throw new ApiError(status, undefined, MESSAGES.generic);
  if (typeof status === 'number' && status >= 400 && status < 500) throw new ApiError(status, undefined, MESSAGES.generic);
  throw error; // no response: a network error
}

export type RpcOk = { ok: true; id?: string; already?: boolean; changed?: boolean };

async function call(client: RpcClient, fn: string, args: Record<string, unknown>): Promise<RpcOk> {
  const res = await client.rpc(fn, args);
  if (res.error) mapRpcError(res.error as never, res.status);
  const data = res.data as { ok?: boolean; code?: string } | null;
  if (!data || data.ok !== true) throw new PlantError(403, undefined, 'Not allowed', data?.code ?? 'not_allowed');
  return data as RpcOk;
}

export type MachineInput = {
  code: string; name: string; asset_tag: string; make: string; model: string; controller: string; line_id: string | null; status: MachineStatus;
};

export const plantApi = {
  saveSite: (c: RpcClient, i: { name: string; timezone: string }, rid: string) =>
    call(c, 'pm_save_site', { p_request_id: rid, p_name: i.name, p_timezone: i.timezone }),
  saveLine: (c: RpcClient, id: string | null, name: string, rid: string) =>
    call(c, 'pm_save_line', { p_request_id: rid, p_id: id, p_name: name }),
  archiveLine: (c: RpcClient, id: string, rid: string) => call(c, 'pm_archive_line', { p_request_id: rid, p_id: id }),
  saveMachine: (c: RpcClient, id: string | null, i: MachineInput, rid: string) =>
    call(c, 'pm_save_machine', {
      p_request_id: rid, p_id: id, p_code: i.code, p_name: i.name, p_asset_tag: i.asset_tag, p_make: i.make, p_model: i.model,
      p_controller: i.controller, p_line_id: i.line_id, p_status: i.status,
    }),
  setMachineRetired: (c: RpcClient, id: string, retired: boolean, rid: string) =>
    call(c, 'pm_set_machine_retired', { p_request_id: rid, p_id: id, p_retired: retired }),
  saveProduct: (c: RpcClient, id: string | null, i: { code: string; description: string; uom: string }, rid: string) =>
    call(c, 'pm_save_product', { p_request_id: rid, p_id: id, p_code: i.code, p_description: i.description, p_uom: i.uom }),
  setProductRetired: (c: RpcClient, id: string, retired: boolean, rid: string) =>
    call(c, 'pm_set_product_retired', { p_request_id: rid, p_id: id, p_retired: retired }),
  setTarget: (c: RpcClient, i: { machineId: string; productId: string; pieces: number; effectiveFrom: string }, rid: string) =>
    call(c, 'pm_set_target', { p_request_id: rid, p_machine_id: i.machineId, p_product_id: i.productId, p_pieces: i.pieces, p_effective_from: i.effectiveFrom }),
  endTarget: (c: RpcClient, i: { machineId: string; productId: string; effectiveFrom: string }, rid: string) =>
    call(c, 'pm_end_target', { p_request_id: rid, p_machine_id: i.machineId, p_product_id: i.productId, p_effective_from: i.effectiveFrom }),
};


// ================================================================================================================================
// 05-shifts-and-assignments: shifts, recurring assignments, cover and per-shift targets. The server decides everything (shift_board /
// my_shift resolve ownership, the sh_* RPCs enforce the rules); this section only reads, formats, validates early and calls.
// ================================================================================================================================
export type Shift = { id: string; name: string; start_time: string; end_time: string; retired_at: string | null };
export type Supervisor = { user_id: string; full_name: string; employee_id: string };
export type OwnerSource = 'plan' | 'cover' | 'none';
export type BoardMachine = {
  machine_id: string;
  code: string;
  name: string;
  line: string | null;
  status: MachineStatus;
  owner_id: string | null;
  owner_name: string | null;
  owner_inactive: boolean;
  source: OwnerSource;
  reason: string | null;
};
export type ShiftBoard = {
  ok: true;
  shift: { id: string; name: string; start_time: string; end_time: string; retired: boolean };
  shift_date: string;
  starts_at: string;
  ends_at: string;
  machines: BoardMachine[];
  unassigned_count: number;
};
export type MyShiftMachine = { machine_id: string; code: string; name: string; line: string | null };
export type MyShift =
  | { ok: true; state: 'no_shifts' | 'none' }
  | {
      ok: true;
      state: 'running' | 'next';
      shift: { id: string; name: string; start_time: string; end_time: string };
      shift_date: string;
      starts_at: string;
      ends_at: string;
      machines: MyShiftMachine[];
    };
export type OverrideVersion = TargetVersion & { shift_id: string };

// ---- Times (HH:MM, site time zone; the server owns the occurrence maths) --------------------------------------------------------
/** "06:00:00" (a database time) -> "06:00". */
export const hhmm = (t: string): string => t.slice(0, 5);
const toMinutes = (t: string): number => Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5));
export const isOvernight = (start: string, end: string): boolean => toMinutes(end) < toMinutes(start);
export const timeWindow = (start: string, end: string): string => `${hhmm(start)} – ${hhmm(end)}`;
/** Length of one occurrence in minutes; an end before the start means it finishes the next day. */
export function shiftMinutes(start: string, end: string): number {
  const d = toMinutes(end) - toMinutes(start);
  return d > 0 ? d : d + 1440;
}
export function formatDuration(minutes: number): string {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (h === 0) return `${m} min`;
  return m === 0 ? `${h} h` : `${h} h ${m} min`;
}

export const SHIFT_MSG = {
  name: 'Enter a name of 1 to 40 characters',
  time: 'Enter a time as HH:MM (24-hour)',
  step: 'Use 15-minute steps: :00, :15, :30 or :45',
  same: 'The end time must differ from the start time',
  supervisor: 'Choose a supervisor',
  machines: 'Choose at least one machine',
  assignPast: "Assignments can't start in the past",
  untilBefore: "The end date can't be before the start date",
  reason: 'Enter a reason of 1 to 200 characters',
} as const;

function timeError(t: string): string | null {
  const v = t.trim();
  if (!/^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(v)) return SHIFT_MSG.time;
  return Number(v.slice(3)) % 15 === 0 ? null : SHIFT_MSG.step;
}

export function validateShiftForm(f: { name: string; start: string; end: string }): FieldErrors {
  const e: FieldErrors = {};
  const n = f.name.trim();
  if (n.length < 1 || n.length > 40) e.name = SHIFT_MSG.name;
  const se = timeError(f.start);
  const ee = timeError(f.end);
  if (se) e.start_time = se;
  if (ee) e.end_time = ee;
  else if (!se && f.start.trim() === f.end.trim()) e.end_time = SHIFT_MSG.same;
  return e;
}

export function validateAssignForm(f: { supervisorId: string; machineIds: string[]; from: string; until: string }, today: string | null): FieldErrors {
  const e: FieldErrors = {};
  if (!f.supervisorId) e.supervisor = SHIFT_MSG.supervisor;
  if (f.machineIds.length === 0) e.machine_ids = SHIFT_MSG.machines;
  const from = f.from.trim();
  if (!isValidDate(from)) e.from = MSG.dateFormat;
  else if (today && from < today) e.from = SHIFT_MSG.assignPast;
  const until = f.until.trim();
  if (until) {
    if (!isValidDate(until)) e.until = MSG.dateFormat;
    else if (isValidDate(from) && until < from) e.until = SHIFT_MSG.untilBefore;
  }
  return e;
}

export function validateCoverForm(f: { machineIds: string[]; reason: string }): FieldErrors {
  const e: FieldErrors = {};
  if (f.machineIds.length === 0) e.machine_ids = SHIFT_MSG.machines;
  const r = f.reason.trim();
  if (r.length < 1 || r.length > 200) e.reason = SHIFT_MSG.reason;
  return e;
}

// ---- Board helpers (display only: ownership is resolved by the server) -----------------------------------------------------------
export type BoardGroup = { ownerId: string; name: string; inactive: boolean; machines: BoardMachine[] };
const byCode = (a: BoardMachine, b: BoardMachine) => (a.code < b.code ? -1 : a.code > b.code ? 1 : 0);

/** "Unassigned this shift" first (a cover to nobody included), then one group per supervisor by name. */
export function groupBoard(machines: BoardMachine[]): { unassigned: BoardMachine[]; groups: BoardGroup[] } {
  const unassigned = machines.filter((m) => m.owner_id === null).sort(byCode);
  const groups = new Map<string, BoardGroup>();
  for (const m of machines) {
    if (m.owner_id === null) continue;
    const g = groups.get(m.owner_id) ?? { ownerId: m.owner_id, name: m.owner_name ?? 'Unknown', inactive: m.owner_inactive, machines: [] };
    g.machines.push(m);
    groups.set(m.owner_id, g);
  }
  const list = [...groups.values()].sort((a, b) => a.name.localeCompare(b.name));
  for (const g of list) g.machines.sort(byCode);
  return { unassigned, groups: list };
}

/** Who loses machines when the selected ones move to `newOwnerId` (null = unassigned): the current owners of the other supervisors' machines. */
export function whoLoses(machines: BoardMachine[], selectedIds: string[], newOwnerId: string | null): { name: string; codes: string[] }[] {
  const chosen = new Set(selectedIds);
  const out = new Map<string, { name: string; codes: string[] }>();
  for (const m of machines) {
    if (!chosen.has(m.machine_id) || m.owner_id === null || m.owner_id === newOwnerId) continue;
    const g = out.get(m.owner_id) ?? { name: m.owner_name ?? 'Unknown', codes: [] };
    g.codes.push(m.code);
    out.set(m.owner_id, g);
  }
  const list = [...out.values()].sort((a, b) => a.name.localeCompare(b.name));
  for (const g of list) g.codes.sort();
  return list;
}

// ---- Per-shift target overrides (display) -------------------------------------------------------------------------------------------
export type OverrideSummary = PairSummary & { shiftId: string };

/** Current, next and history per (product, shift) pair, with the same rules as the base targets. */
export function summariseOverrides(versions: OverrideVersion[], today: string): OverrideSummary[] {
  const KEY = '\u0000';
  const byId = new Map(versions.map((v) => [v.id, v]));
  const pseudo = versions.map((v) => ({ ...v, product_id: `${v.product_id}${KEY}${v.shift_id}` }));
  return summariseTargets(pseudo, today).map((s) => {
    const [productId, shiftId] = s.productId.split(KEY);
    return { ...s, productId, shiftId, history: s.history.map((h) => byId.get(h.id)!) };
  });
}

// ---- Reads ---------------------------------------------------------------------------------------------------------------------------
const SHIFT_COLUMNS = 'id, name, start_time, end_time, retired_at';

export async function fetchShifts(client: Db, opts: { includeRetired?: boolean } = {}): Promise<Shift[]> {
  let q = client.from('shift').select(SHIFT_COLUMNS);
  if (!opts.includeRetired) q = q.is('retired_at', null);
  const { data, error } = await q.order('start_time', { ascending: true }).order('name', { ascending: true });
  if (error) throw error;
  return (data ?? []) as unknown as Shift[];
}

/** Supervisors a Unit Admin can assign: active, with their password already changed (the server refuses the others). */
export async function fetchActiveSupervisors(client: Db): Promise<Supervisor[]> {
  const { data, error } = await client
    .from('membership')
    .select('user_id, full_name, employee_id')
    .eq('role', 'supervisor')
    .eq('status', 'active')
    .eq('must_change_password', false)
    .order('full_name', { ascending: true });
  if (error) throw error;
  return (data ?? []) as unknown as Supervisor[];
}

export async function fetchOverrideVersions(client: Db, machineId: string): Promise<OverrideVersion[]> {
  const { data, error } = await client
    .from('target_override_version')
    .select('id, machine_id, product_id, shift_id, effective_from, pieces_per_shift, recorded_by, recorded_at')
    .eq('machine_id', machineId)
    .order('effective_from', { ascending: false })
    .order('recorded_at', { ascending: false });
  if (error) throw error;
  return (data ?? []) as unknown as OverrideVersion[];
}

/** Read RPCs return {ok:true,...} or the generic denial; planning data is never read from the tables by a supervisor. */
async function readRpc<T>(client: RpcClient, fn: string, args?: Record<string, unknown>): Promise<T> {
  const res = args === undefined ? await client.rpc(fn) : await client.rpc(fn, args);
  if (res.error) mapRpcError(res.error as never, res.status);
  const data = res.data as { ok?: boolean; code?: string } | null;
  if (!data || data.ok !== true) throw new PlantError(403, undefined, 'Not allowed', data?.code ?? 'not_allowed');
  return data as T;
}

export const fetchShiftBoard = (client: RpcClient, shiftId: string, date: string | null): Promise<ShiftBoard> =>
  readRpc<ShiftBoard>(client, 'shift_board', { p_shift_id: shiftId, p_date: date });
export const fetchMyShift = (client: RpcClient): Promise<MyShift> => readRpc<MyShift>(client, 'my_shift');

// ---- Writes (RPC) --------------------------------------------------------------------------------------------------------------------
export const shiftApi = {
  saveShift: (c: RpcClient, id: string | null, i: { name: string; start: string; end: string }, rid: string) =>
    call(c, 'sh_save_shift', { p_request_id: rid, p_id: id, p_name: i.name, p_start: i.start, p_end: i.end }),
  setShiftRetired: (c: RpcClient, id: string, retired: boolean, rid: string) =>
    call(c, 'sh_set_shift_retired', { p_request_id: rid, p_id: id, p_retired: retired }),
  assign: (c: RpcClient, i: { shiftId: string; supervisorId: string; machineIds: string[]; from: string; until: string | null }, rid: string) =>
    call(c, 'sh_assign', { p_request_id: rid, p_shift_id: i.shiftId, p_supervisor_id: i.supervisorId, p_machine_ids: i.machineIds, p_from: i.from, p_until: i.until }),
  unassign: (c: RpcClient, i: { shiftId: string; machineIds: string[]; from: string }, rid: string) =>
    call(c, 'sh_unassign', { p_request_id: rid, p_shift_id: i.shiftId, p_machine_ids: i.machineIds, p_from: i.from }),
  cover: (c: RpcClient, i: { shiftId: string; shiftDate: string; machineIds: string[]; supervisorId: string | null; reason: string }, rid: string) =>
    call(c, 'sh_cover', { p_request_id: rid, p_shift_id: i.shiftId, p_shift_date: i.shiftDate, p_machine_ids: i.machineIds, p_supervisor_id: i.supervisorId, p_reason: i.reason }),
  setOverride: (c: RpcClient, i: { machineId: string; productId: string; shiftId: string; pieces: number; effectiveFrom: string }, rid: string) =>
    call(c, 'sh_set_target_override', {
      p_request_id: rid, p_machine_id: i.machineId, p_product_id: i.productId, p_shift_id: i.shiftId, p_pieces: i.pieces, p_effective_from: i.effectiveFrom,
    }),
  endOverride: (c: RpcClient, i: { machineId: string; productId: string; shiftId: string; effectiveFrom: string }, rid: string) =>
    call(c, 'sh_end_target_override', { p_request_id: rid, p_machine_id: i.machineId, p_product_id: i.productId, p_shift_id: i.shiftId, p_effective_from: i.effectiveFrom }),
};

/**
 * Request ids per logical action (02 R2): reused for a retry after a network failure (the first attempt may have succeeded, so the server
 * replays it), replaced after a 5xx (the server may have half-done it) and after success.
 */
export class RequestIds {
  private ids = new Map<string, string>();
  get(key: string): string {
    const found = this.ids.get(key);
    if (found) return found;
    const id = newRequestId();
    this.ids.set(key, id);
    return id;
  }
  succeeded(key: string) {
    this.ids.delete(key);
  }
  failed(key: string, err: unknown) {
    if (!keepRequestIdAfter(err) || err instanceof PlantError) this.ids.delete(key); // a refusal means nothing was recorded: next try is a new request
  }
}
