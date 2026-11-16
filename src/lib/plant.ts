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
  const term = sanitiseSearch(query.search);
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
  const term = sanitiseSearch(query.search);
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

// ---- Writes (RPC) ---------------------------------------------------------------------------------------------------------------
/** A server refusal. `field` names the form field for validation/duplicate errors; `machines` lists blocking machine codes. */
export class PlantError extends ApiError {
  constructor(status: number, field: string | undefined, message: string, code?: string, public machines?: string[]) {
    super(status, field, message, code);
    this.name = 'PlantError';
  }
}

type RpcError = { code?: string; message?: string; details?: string | null } | null;

/** Turns a PostgREST error into something the form can show. Network failures are re-thrown untouched (toUserMessage handles them). */
function mapRpcError(error: NonNullable<RpcError> & Record<string, unknown>, status: number | undefined): never {
  if (error.code === 'P0001') {
    let detail: { code?: string; field?: string; machines?: string[] } = {};
    try {
      detail = JSON.parse(String(error.details ?? '{}'));
    } catch {
      detail = {};
    }
    throw new PlantError(400, detail.field, String(error.message ?? MESSAGES.generic), detail.code, detail.machines);
  }
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
