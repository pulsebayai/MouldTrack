import type { SupabaseClient } from '@supabase/supabase-js';

export type Role = 'unit_admin' | 'supervisor' | 'maintenance';
export type SessionContext =
  | { user: { id: string; email: string | undefined }; tenant: { name: string }; role: Role }
  | { noAccess: true }
  // The user signed in with a temporary password: the server returns no tenant data until it is changed (02, AC-3).
  | { user: { id: string; email: string | undefined }; mustChangePassword: true; expired: boolean }
  // A Platform Super Admin (03): no membership, an own active platform_admin row. Routed to the console.
  | { user: { id: string; email: string | undefined }; platform: true };

/** The subset of the Supabase client this module needs (makes it testable with a fake). */
export type SessionClient = Pick<SupabaseClient, 'auth' | 'from'>;

type MembershipRow = {
  role: Role;
  status: 'active' | 'inactive';
  must_change_password?: boolean;
  temp_password_expires_at?: string | null;
  tenant: { name: string; status: 'active' | 'suspended' } | null;
};

/**
 * Single source of truth for the route guard.
 * null → not signed in; { noAccess } → signed in but no active membership in an active tenant.
 * Throws on query failure so the UI can show the network message + retry.
 */
export async function getSessionContext(client: SessionClient): Promise<SessionContext | null> {
  const { data: sessionData } = await client.auth.getSession();
  const session = sessionData.session;
  if (!session) return null;

  const { data, error } = await client
    .from('membership')
    .select('role, status, must_change_password, temp_password_expires_at, tenant:tenant(name, status)')
    // A Unit Admin can read every membership of the tenant (02 RLS), so always ask for the caller's own row.
    .eq('user_id', session.user.id)
    .maybeSingle<MembershipRow>();
  if (error) throw error;
  if (!data || data.status !== 'active') return { noAccess: true };
  // Checked before the tenant lookup: RLS hides the tenant until the temporary password has been changed.
  if (data.must_change_password) {
    const expires = data.temp_password_expires_at ? new Date(data.temp_password_expires_at).getTime() : null;
    return {
      user: { id: session.user.id, email: session.user.email },
      mustChangePassword: true,
      expired: expires !== null && expires < Date.now(),
    };
  }
  if (!data.tenant || data.tenant.status !== 'active') return { noAccess: true };
  return { user: { id: session.user.id, email: session.user.email }, tenant: { name: data.tenant.name }, role: data.role };
}

type PlatformRow = { status: 'active' | 'inactive'; must_change_password: boolean; temp_password_expires_at: string | null };

/**
 * 03: a signed-in user without an active membership may be a Platform Super Admin. RLS lets them read only their own platform_admin
 * row, which also carries the must-change flag. null when there is no such active row.
 */
export async function getPlatformContext(client: SessionClient): Promise<SessionContext | null> {
  const { data: sessionData } = await client.auth.getSession();
  const session = sessionData.session;
  if (!session) return null;
  const { data, error } = await client
    .from('platform_admin')
    .select('status, must_change_password, temp_password_expires_at')
    .eq('user_id', session.user.id)
    .maybeSingle<PlatformRow>();
  if (error) throw error;
  if (!data || data.status !== 'active') return null;
  const user = { id: session.user.id, email: session.user.email };
  if (data.must_change_password) {
    const expires = data.temp_password_expires_at ? new Date(data.temp_password_expires_at).getTime() : null;
    return { user, mustChangePassword: true, expired: expires !== null && expires < Date.now() };
  }
  return { user, platform: true };
}

/** The session context the app routes on: the membership path first (02), then the platform path (03). */
export async function loadSessionContext(client: SessionClient): Promise<SessionContext | null> {
  const ctx = await getSessionContext(client);
  if (ctx && 'noAccess' in ctx) return (await getPlatformContext(client)) ?? ctx;
  return ctx;
}

/** A signed-in active Platform Super Admin with a normal password. */
export function isPlatformAdmin(ctx: SessionContext | null): ctx is Extract<SessionContext, { platform: true }> {
  return !!ctx && 'platform' in ctx;
}

const ROLE_LABELS: Record<Role, string> = { unit_admin: 'Unit Admin', supervisor: 'Supervisor', maintenance: 'Maintenance' };
export function roleLabel(role: Role): string {
  return ROLE_LABELS[role];
}

/** A signed-in user with a normal tenant context (not no-access, not forced to change the password). */
export function isMember(ctx: SessionContext | null): ctx is Extract<SessionContext, { tenant: unknown }> {
  return !!ctx && 'tenant' in ctx;
}
