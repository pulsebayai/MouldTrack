// Data layer for the Super Admin console (03). Reads go through the pa_* functions (a Super Admin has no RLS access to tenant
// data) and the tenant table; writes go through the `platform` Edge Function. Phones arrive masked; the client never sees more.
import type { SupabaseClient } from '@supabase/supabase-js';
import { callFunction } from './api';

type Deps = { baseUrl?: string; anonKey?: string; fetchImpl?: typeof fetch };
type AuthClient = Pick<SupabaseClient, 'auth'>;
type ReadClient = Pick<SupabaseClient, 'from' | 'rpc'>;

export const TENANT_PAGE_SIZE = 25;
export const AUDIT_PAGE_SIZE = 50;

export type TenantStatus = 'active' | 'suspended';
export type PlanLabel = 'trial' | 'active';
export type TenantStatusFilter = 'all' | TenantStatus;
export type PlanFilter = 'all' | PlanLabel;

export type TenantSummary = {
  id: string;
  name: string;
  status: TenantStatus;
  plan_label: PlanLabel;
  timezone: string;
  created_at: string;
  active_users: number;
  active_unit_admins: number;
};
export type TenantDetail = Omit<TenantSummary, 'active_users' | 'active_unit_admins'> & { suspended_reason: string | null };
export type UnitAdminRow = { user_id: string; full_name: string; phone_masked: string; status: 'active' | 'inactive'; must_change_password: boolean };
export type SuperAdminRow = UnitAdminRow & { is_self: boolean };
export type AuditRow = {
  id: string;
  occurred_at: string;
  action: string;
  actor_name: string | null;
  tenant_id: string | null;
  tenant_name: string | null;
  entity_type: string | null;
  reason: string | null;
  source: string;
};

/** Status and plan are always shown as text (never by colour alone). */
export const TENANT_STATUS_TEXT: Record<TenantStatus, string> = { active: 'Active', suspended: 'Suspended' };
export const PLAN_TEXT: Record<PlanLabel, string> = { trial: 'Trial', active: 'Active plan' };
export function adminStatusText(r: Pick<UnitAdminRow, 'status' | 'must_change_password'>): 'Active' | 'Inactive' | 'Must change password' {
  if (r.status === 'inactive') return 'Inactive';
  return r.must_change_password ? 'Must change password' : 'Active';
}

const ACTION_TEXT: Record<string, string> = {
  'tenant.created': 'Tenant registered',
  'tenant.updated': 'Tenant edited',
  'tenant.suspended': 'Tenant suspended',
  'tenant.activated': 'Tenant activated',
  'user.created': 'Unit Admin created',
  'user.password_reset': 'Unit Admin password reset',
  'platform_admin.created': 'Super Admin created',
  'platform_admin.deactivated': 'Super Admin deactivated',
  'platform_admin.reactivated': 'Super Admin reactivated',
  'platform_admin.password_reset': 'Super Admin password reset',
  'platform_admin.password_changed': 'Super Admin changed own password',
  'access.denied': 'Access denied',
};
export function actionText(action: string): string {
  return ACTION_TEXT[action] ?? action;
}

export function sanitiseSearch(q: string): string {
  return q.trim();
}

type Rpc<T> = Promise<{ data: T[] | null; error: { message?: string } | null }>;

export async function fetchTenantSummaries(
  client: ReadClient,
  q: { search: string; status: TenantStatusFilter; plan: PlanFilter; page: number },
): Promise<{ rows: TenantSummary[]; total: number }> {
  const { data, error } = await (client.rpc('pa_tenant_summaries', {
    p_search: sanitiseSearch(q.search) || null,
    p_status: q.status === 'all' ? null : q.status,
    p_plan: q.plan === 'all' ? null : q.plan,
    p_page: q.page,
  }) as unknown as Rpc<TenantSummary & { total_count: number | string }>);
  if (error) throw error;
  const rows = data ?? [];
  return { rows: rows.map(({ total_count: _t, ...r }) => r as TenantSummary), total: rows.length ? Number(rows[0].total_count) : 0 };
}

export async function fetchTenant(client: ReadClient, id: string): Promise<TenantDetail | null> {
  const { data, error } = await client
    .from('tenant')
    .select('id, name, status, plan_label, timezone, created_at, suspended_reason')
    .eq('id', id)
    .maybeSingle();
  if (error) throw error;
  return (data as unknown as TenantDetail) ?? null;
}

export async function fetchTenantUnitAdmins(client: ReadClient, tenantId: string): Promise<UnitAdminRow[]> {
  const { data, error } = await (client.rpc('pa_tenant_unit_admins', { p_tenant: tenantId }) as unknown as Rpc<UnitAdminRow>);
  if (error) throw error;
  return data ?? [];
}

export async function fetchSuperAdmins(client: ReadClient): Promise<SuperAdminRow[]> {
  const { data, error } = await (client.rpc('pa_super_admins') as unknown as Rpc<SuperAdminRow>);
  if (error) throw error;
  return data ?? [];
}

export async function fetchPlatformAudit(client: ReadClient, page: number): Promise<{ rows: AuditRow[]; total: number }> {
  const { data, error } = await (client.rpc('pa_audit', { p_page: page }) as unknown as Rpc<AuditRow & { total_count: number | string }>);
  if (error) throw error;
  const rows = data ?? [];
  return { rows: rows.map(({ total_count: _t, ...r }) => r as AuditRow), total: rows.length ? Number(rows[0].total_count) : 0 };
}

export type TempResult = { temp_password?: string; already?: boolean; message?: string };

export const platformApi = {
  tenantCreate: (client: AuthClient, input: { name: string; timezone: string; plan_label: PlanLabel }, requestId: string, deps?: Deps) =>
    callFunction<{ tenant_id: string; already?: boolean }>(client, 'platform', { action: 'tenant_create', request_id: requestId, ...input }, deps),
  tenantUpdate: (client: AuthClient, tenantId: string, input: { name?: string; timezone?: string; plan_label?: PlanLabel }, requestId: string, deps?: Deps) =>
    callFunction<{ ok: boolean }>(client, 'platform', { action: 'tenant_update', request_id: requestId, tenant_id: tenantId, ...input }, deps),
  tenantSetStatus: (client: AuthClient, tenantId: string, status: TenantStatus, reason: string | null, requestId: string, deps?: Deps) =>
    callFunction<{ ok: boolean; status?: string }>(
      client, 'platform', { action: 'tenant_set_status', request_id: requestId, tenant_id: tenantId, status, ...(reason ? { reason } : {}) }, deps),
  uaCreate: (client: AuthClient, tenantId: string, input: { full_name: string; employee_id: string; phone: string }, requestId: string, deps?: Deps) =>
    callFunction<TempResult & { user_id: string }>(client, 'platform', { action: 'ua_create', request_id: requestId, tenant_id: tenantId, ...input }, deps),
  uaResetPassword: (client: AuthClient, userId: string, requestId: string, deps?: Deps) =>
    callFunction<TempResult>(client, 'platform', { action: 'ua_reset_password', request_id: requestId, user_id: userId }, deps),
  saCreate: (client: AuthClient, input: { full_name: string; phone: string }, requestId: string, deps?: Deps) =>
    callFunction<TempResult & { user_id: string }>(client, 'platform', { action: 'sa_create', request_id: requestId, ...input }, deps),
  saSetStatus: (client: AuthClient, userId: string, status: 'active' | 'inactive', requestId: string, deps?: Deps) =>
    callFunction<{ ok: boolean }>(client, 'platform', { action: 'sa_set_status', request_id: requestId, user_id: userId, status }, deps),
  saResetPassword: (client: AuthClient, userId: string, requestId: string, deps?: Deps) =>
    callFunction<TempResult>(client, 'platform', { action: 'sa_reset_password', request_id: requestId, user_id: userId }, deps),
};
