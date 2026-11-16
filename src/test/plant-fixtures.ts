import type { Machine, Product, TargetVersion } from '@/lib/plant';
import { fakeDb, type Query } from './fake-db';

export const admin = { user: { id: 'me', email: 'x' }, tenant: { name: 'e2e org U' }, role: 'unit_admin' as const };
export const sup = { ...admin, role: 'supervisor' as const };

export const machine = (i: number, over: Partial<Machine> = {}): Machine => ({
  id: `m-${i}`, code: `M-${i}`, name: `Press ${i}`, asset_tag: null, make: null, model: null, controller: null, line_id: null, status: 'active', retired_at: null, ...over,
});
export const product = (i: number, over: Partial<Product> = {}): Product => ({ id: `p-${i}`, code: `P-${i}`, description: `Cap ${i}`, uom: 'pcs', retired_at: null, ...over });
export const version = (id: string, productId: string, from: string, pieces: number | null, rec: string, by = 'u-1'): TargetVersion => ({
  id, machine_id: 'm-1', product_id: productId, effective_from: from, pieces_per_shift: pieces, recorded_by: by, recorded_at: rec,
});

type Result = { data: unknown; count?: number | null; error: unknown };
export type Tables = Partial<Record<string, Result | ((q: Query) => Result | Promise<Result>)>>;

/** A fake Supabase client: tables answer from `tables` (a result or a function of the query); `rpc` is a jest mock. */
export function plantClient(tables: Tables, rpcResult: unknown = { data: { ok: true, id: 'new-id' }, error: null, status: 200 }) {
  const db = fakeDb((q) => {
    const t = tables[q.table];
    if (!t) return { data: q.single ? null : [], count: 0, error: null };
    return typeof t === 'function' ? t(q) : t;
  });
  const rpc = jest.fn(async () => rpcResult);
  return { db, rpc, client: { ...db.client, rpc } as never };
}

export const ok = (data: unknown, count?: number): Result => ({ data, count: count ?? (Array.isArray(data) ? data.length : null), error: null });
