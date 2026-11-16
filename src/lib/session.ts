import type { SupabaseClient } from '@supabase/supabase-js';

export type Role = 'unit_admin' | 'supervisor' | 'maintenance';
export type SessionContext =
  | { user: { id: string; email: string | undefined }; tenant: { name: string }; role: Role }
  | { noAccess: true }
  // The user signed in with a temporary password: the server returns no tenant data until it is changed (02, AC-3).
  | { user: { id: string; email: string | undefined }; mustChangePassword: true; expired: boolean };

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

const ROLE_LABELS: Record<Role, string> = { unit_admin: 'Unit Admin', supervisor: 'Supervisor', maintenance: 'Maintenance' };
export function roleLabel(role: Role): string {
  return ROLE_LABELS[role];
}

/** A signed-in user with a normal tenant context (not no-access, not forced to change the password). */
export function isMember(ctx: SessionContext | null): ctx is Extract<SessionContext, { tenant: unknown }> {
  return !!ctx && 'tenant' in ctx;
}
