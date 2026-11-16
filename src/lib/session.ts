import type { SupabaseClient } from '@supabase/supabase-js';

export type Role = 'unit_admin' | 'supervisor' | 'maintenance';
export type SessionContext =
  | { user: { id: string; email: string | undefined }; tenant: { name: string }; role: Role }
  | { noAccess: true };

/** The subset of the Supabase client this module needs (makes it testable with a fake). */
export type SessionClient = Pick<SupabaseClient, 'auth' | 'from'>;

type MembershipRow = {
  role: Role;
  status: 'active' | 'inactive';
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
    .select('role, status, tenant:tenant(name, status)')
    // A Unit Admin can read every membership of the tenant (02 RLS), so always ask for the caller's own row.
    .eq('user_id', session.user.id)
    .maybeSingle<MembershipRow>();
  if (error) throw error;
  if (!data || data.status !== 'active' || !data.tenant || data.tenant.status !== 'active') {
    return { noAccess: true };
  }
  return { user: { id: session.user.id, email: session.user.email }, tenant: { name: data.tenant.name }, role: data.role };
}

const ROLE_LABELS: Record<Role, string> = { unit_admin: 'Unit Admin', supervisor: 'Supervisor', maintenance: 'Maintenance' };
export function roleLabel(role: Role): string {
  return ROLE_LABELS[role];
}
