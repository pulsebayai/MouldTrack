// Auth admin helpers shared by the platform functions (03). user-admin (02) keeps its own copies; this module only adds.
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { HttpError } from './errors.ts';
import { normalisePhone } from './identity.ts';
import { optionalString, requireString } from './http.ts';

export const ALREADY_DONE = 'Already done — reset the password if it was lost';
export const PHONE_TAKEN = 'This phone number is already registered';
export const BAN_FOREVER = '876000h'; // ~100 years; lifted with 'none'

export function phoneOf(body: Record<string, unknown>, required: boolean): string | null {
  const raw = required ? requireString(body, 'phone') : optionalString(body, 'phone');
  if (raw === null) return null;
  const n = normalisePhone(raw);
  if (!n.ok) throw new HttpError(400, { field: 'phone', message: n.message });
  return n.e164;
}

export function isEmailTaken(error: { code?: string; message?: string }): boolean {
  return error.code === 'email_exists' || /already (been )?registered|already exists/i.test(error.message ?? '');
}

/** Creates the Auth user (one retry on a 5xx from a concurrent create). Throws 409 for a taken phone, 500 otherwise. */
export async function createAuthUser(sb: SupabaseClient, email: string, password: string): Promise<string> {
  let user: { id: string } | null = null;
  let authError: { code?: string; message?: string; status?: number } | null = null;
  for (let attempt = 0; attempt < 2; attempt++) {
    const res = await sb.auth.admin.createUser({ email, password, email_confirm: true });
    user = res.data?.user ?? null;
    authError = res.error;
    if (!res.error || (res.error.status ?? 500) < 500) break;
    await new Promise((r) => setTimeout(r, 150));
  }
  if (authError || !user) {
    if (authError && isEmailTaken(authError)) throw new HttpError(409, { field: 'phone', message: PHONE_TAKEN });
    console.error('auth_create_failed', authError?.code ?? 'unknown');
    throw new HttpError(500, { message: 'Something went wrong. Try again.' });
  }
  return user.id;
}
