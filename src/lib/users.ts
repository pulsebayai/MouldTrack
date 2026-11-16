import type { SupabaseClient } from '@supabase/supabase-js';
import type { Role } from './session';

export const PAGE_SIZE = 25;
const COLUMNS = 'user_id, full_name, employee_id, phone_e164, role, status, must_change_password';

export type UserRow = {
  user_id: string;
  full_name: string;
  employee_id: string;
  phone_e164: string;
  role: Role;
  status: 'active' | 'inactive';
  must_change_password: boolean;
};

export type RoleFilter = 'all' | 'unit_admin' | 'supervisor';
export type StatusFilter = 'all' | 'active' | 'inactive' | 'must_change';
export type UserQuery = { search: string; role: RoleFilter; status: StatusFilter; page: number };

export type StatusText = 'Active' | 'Inactive' | 'Must change password';

/** Status is always shown as text. */
export function statusLabel(r: Pick<UserRow, 'status' | 'must_change_password'>): StatusText {
  if (r.status === 'inactive') return 'Inactive';
  return r.must_change_password ? 'Must change password' : 'Active';
}

export const ROLE_TEXT: Record<Role, string> = { unit_admin: 'Unit Admin', supervisor: 'Supervisor', maintenance: 'Maintenance' };

/** Removes characters that would change the meaning of a PostgREST `or`/`ilike` filter. */
export function sanitiseSearch(q: string): string {
  return q.replace(/[,()%*\\"]/g, '').trim();
}

type DbClient = Pick<SupabaseClient, 'from'>;

/** Reads the tenant's memberships under RLS (a Unit Admin sees the whole tenant). */
export async function fetchUsers(client: DbClient, query: UserQuery): Promise<{ rows: UserRow[]; total: number }> {
  let q = client.from('membership').select(COLUMNS, { count: 'exact' });
  const term = sanitiseSearch(query.search);
  if (term) q = q.or(`full_name.ilike.%${term}%,employee_id.ilike.%${term}%,phone_e164.ilike.%${term}%`);
  if (query.role !== 'all') q = q.eq('role', query.role);
  if (query.status === 'active') q = q.eq('status', 'active').eq('must_change_password', false);
  else if (query.status === 'inactive') q = q.eq('status', 'inactive');
  else if (query.status === 'must_change') q = q.eq('status', 'active').eq('must_change_password', true);
  const from = query.page * PAGE_SIZE;
  const { data, count, error } = await q.order('full_name', { ascending: true }).range(from, from + PAGE_SIZE - 1);
  if (error) throw error;
  return { rows: (data ?? []) as unknown as UserRow[], total: count ?? 0 };
}

export async function fetchUser(client: DbClient, userId: string): Promise<UserRow | null> {
  const { data, error } = await client.from('membership').select(COLUMNS).eq('user_id', userId).maybeSingle();
  if (error) throw error;
  return (data as unknown as UserRow) ?? null;
}
