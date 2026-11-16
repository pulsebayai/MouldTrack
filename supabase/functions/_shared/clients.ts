import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { HttpError } from './errors.ts';

const opts = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } };

function env(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`missing env ${name}`);
  return v;
}

/** Service-role client. Only ever created inside an Edge Function; the key never leaves the function environment. */
export function serviceClient(): SupabaseClient {
  return createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), opts);
}

/** Anon client, used only to verify a user's current password with a throwaway session. */
export function anonClient(): SupabaseClient {
  return createClient(env('SUPABASE_URL'), env('SUPABASE_ANON_KEY'), opts);
}

/** Verifies the caller's JWT with Auth and returns their user id. */
export async function callerId(req: Request, sb: SupabaseClient): Promise<string> {
  const header = req.headers.get('authorization') ?? '';
  const token = header.toLowerCase().startsWith('bearer ') ? header.slice(7).trim() : '';
  if (!token) throw new HttpError(401, { message: 'Sign in again' });
  const { data, error } = await sb.auth.getUser(token);
  if (error || !data.user) throw new HttpError(401, { message: 'Sign in again' });
  return data.user.id;
}

/** The `session_id` claim of an access token that callerId already verified with Auth (null if absent or malformed). */
export function sessionIdOf(req: Request): string | null {
  const header = req.headers.get('authorization') ?? '';
  const token = header.toLowerCase().startsWith('bearer ') ? header.slice(7).trim() : '';
  const part = token.split('.')[1];
  if (!part) return null;
  try {
    const json = atob(part.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(part.length / 4) * 4, '='));
    const id = JSON.parse(json).session_id;
    return typeof id === 'string' && /^[0-9a-f-]{36}$/i.test(id) ? id : null;
  } catch {
    return null;
  }
}

export function randomBytes(n: number): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(n));
}
