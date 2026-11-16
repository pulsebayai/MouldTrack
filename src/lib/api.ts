import type { SupabaseClient } from '@supabase/supabase-js';
import { getEnv } from './env';
import { MESSAGES } from './errors';

/** Error from an Edge Function: `field` (when the server names one) and a message that is safe to show. */
export class ApiError extends Error {
  constructor(public status: number, public field: string | undefined, message: string) {
    super(message);
    this.name = 'ApiError';
  }
}

type Deps = { baseUrl?: string; anonKey?: string; fetchImpl?: typeof fetch };
type AuthClient = Pick<SupabaseClient, 'auth'>;

/** RFC 4122 v4. Uniqueness is all a request id needs (idempotency key), so Math.random is a fine fallback. */
export function newRequestId(): string {
  const c = (globalThis as { crypto?: { randomUUID?: () => string; getRandomValues?: (a: Uint8Array) => Uint8Array } }).crypto;
  if (c?.randomUUID) return c.randomUUID();
  const b = new Uint8Array(16);
  if (c?.getRandomValues) c.getRandomValues(b);
  else for (let i = 0; i < 16; i++) b[i] = Math.floor(Math.random() * 256);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

export async function callFunction<T = Record<string, unknown>>(
  client: AuthClient,
  fn: 'user-admin' | 'account',
  body: Record<string, unknown>,
  deps: Deps = {},
): Promise<T> {
  const { data } = await client.auth.getSession();
  const token = data.session?.access_token;
  if (!token) throw new ApiError(401, undefined, 'Sign in again');
  const env = deps.baseUrl && deps.anonKey ? null : getEnv();
  const baseUrl = deps.baseUrl ?? env!.supabaseUrl;
  const anonKey = deps.anonKey ?? env!.supabaseAnonKey;
  const doFetch = deps.fetchImpl ?? fetch;

  // Network failures propagate as-is so toUserMessage shows the "can't reach" copy.
  const res = await doFetch(`${baseUrl}/functions/v1/${fn}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: anonKey, Authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });
  let json: Record<string, unknown> = {};
  try {
    json = (await res.json()) as Record<string, unknown>;
  } catch {
    json = {};
  }
  if (!res.ok) {
    const safe = res.status < 500 && typeof json.message === 'string' ? json.message : MESSAGES.generic;
    throw new ApiError(res.status, typeof json.field === 'string' ? json.field : undefined, safe);
  }
  return json as T;
}

export type CreateInput = { full_name: string; employee_id: string; phone: string; role: 'unit_admin' | 'supervisor' };
export type UpdateInput = Partial<CreateInput>;

export const userAdminApi = {
  create: (client: AuthClient, input: CreateInput, requestId: string, deps?: Deps) =>
    callFunction<{ user_id: string; temp_password?: string; already?: boolean; message?: string }>(
      client, 'user-admin', { action: 'create', request_id: requestId, ...input }, deps),
  update: (client: AuthClient, userId: string, input: UpdateInput, requestId: string, deps?: Deps) =>
    callFunction<{ ok: boolean }>(client, 'user-admin', { action: 'update', request_id: requestId, user_id: userId, ...input }, deps),
  setStatus: (client: AuthClient, userId: string, status: 'active' | 'inactive', requestId: string, deps?: Deps) =>
    callFunction<{ ok: boolean }>(client, 'user-admin', { action: 'set_status', request_id: requestId, user_id: userId, status }, deps),
  resetPassword: (client: AuthClient, userId: string, requestId: string, deps?: Deps) =>
    callFunction<{ temp_password?: string; already?: boolean; message?: string }>(
      client, 'user-admin', { action: 'reset_password', request_id: requestId, user_id: userId }, deps),
};

export const accountApi = {
  changePassword: (client: AuthClient, current: string, next: string, deps?: Deps) =>
    callFunction<{ ok: boolean }>(client, 'account', { action: 'change_password', current_password: current, new_password: next }, deps),
};
