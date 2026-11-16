// Shared helpers for the API project (02-tenancy-and-roles, D10). Talks to Auth, PostgREST and the Edge Functions over HTTP.
// Local/ephemeral stacks only: CI exports E2E_API_URL / E2E_ANON_KEY / E2E_SERVICE_ROLE_KEY from `supabase status`.
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { test, type APIRequestContext } from '@playwright/test';
import { authEmailToPhone, phoneToAuthEmail } from '../../supabase/functions/_shared/identity';

export const API_URL = process.env.E2E_API_URL ?? '';
const ANON_KEY = process.env.E2E_ANON_KEY ?? '';
const SERVICE_KEY = process.env.E2E_SERVICE_ROLE_KEY ?? '';
export const FIXTURE_PASSWORD = process.env.E2E_FIXTURE_PASSWORD || 'local-e2e-Passw0rd!';
export const API_CONFIGURED = Boolean(API_URL && ANON_KEY && SERVICE_KEY);

/** Skips the file when the stack env is missing, unless E2E_REQUIRE_API is set (PR CI), where missing env is a failure. */
export function requireApi() {
  if (!API_CONFIGURED && process.env.E2E_REQUIRE_API) throw new Error('E2E_API_URL / E2E_ANON_KEY / E2E_SERVICE_ROLE_KEY are required');
  test.skip(!API_CONFIGURED, 'API stack env not configured for this target');
}

const clientOpts = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } };
export const service = (): SupabaseClient => createClient(API_URL, SERVICE_KEY, clientOpts);
export const anon = (): SupabaseClient => createClient(API_URL, ANON_KEY, clientOpts);

export type Session = { client: SupabaseClient; token: string; refreshToken: string; userId: string };

export async function signIn(phone: string, password: string): Promise<Session> {
  const client = anon();
  const { data, error } = await client.auth.signInWithPassword({ email: phoneToAuthEmail(phone), password });
  if (error || !data.session) throw new Error(`sign-in failed: ${error?.message}`);
  const authed = createClient(API_URL, ANON_KEY, {
    ...clientOpts,
    global: { headers: { Authorization: `Bearer ${data.session.access_token}` } },
  });
  return { client: authed, token: data.session.access_token, refreshToken: data.session.refresh_token, userId: data.user.id };
}

export async function signInFails(phone: string, password: string): Promise<boolean> {
  const { data, error } = await anon().auth.signInWithPassword({ email: phoneToAuthEmail(phone), password });
  return Boolean(error) && !data.session;
}

export type FnResult = { status: number; body: Record<string, any> };

export async function callFn(request: APIRequestContext, fn: 'user-admin' | 'account' | 'platform' | 'platform-setup', token: string | null, data: Record<string, unknown>): Promise<FnResult> {
  const headers: Record<string, string> = { apikey: ANON_KEY, 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await request.post(`${API_URL}/functions/v1/${fn}`, { headers, data });
  let body: Record<string, any> = {};
  try {
    body = await res.json();
  } catch {
    body = {};
  }
  return { status: res.status(), body };
}

export const uuid = () => crypto.randomUUID();

/** Headers for platform-setup (no JWT; the apikey only reaches the function gateway). */
export async function callSetup(request: APIRequestContext, token: string | null, data: Record<string, unknown>): Promise<FnResult> {
  const headers: Record<string, string> = { apikey: ANON_KEY, 'Content-Type': 'application/json' };
  if (token !== null) headers['x-setup-token'] = token;
  const res = await request.post(`${API_URL}/functions/v1/platform-setup`, { headers, data });
  let body: Record<string, any> = {};
  try {
    body = await res.json();
  } catch {
    body = {};
  }
  return { status: res.status(), body };
}

// ---- Fixture orgs ------------------------------------------------------------------------------------------------
// Each spec file owns its own org so files can run in parallel. Canonical block +91 90000 00001-00099 (D2).
export type OrgUser = { key: 'ua1' | 'ua2' | 'sup' | 'fresh'; id: string; phone: string; role: 'unit_admin' | 'supervisor'; mustChange: boolean };
export type Org = { id: string; name: string; users: Record<OrgUser['key'], OrgUser> };

export function orgDef(n: number, name: string): Org {
  const mk = (key: OrgUser['key'], i: number, role: OrgUser['role'], mustChange: boolean): OrgUser => ({
    key,
    id: `30000000-0000-4000-a000-0000000000${n}${i}`,
    phone: `+9190000000${n}${i}`,
    role,
    mustChange,
  });
  return {
    id: `20000000-0000-4000-a000-00000000000${n}`,
    name,
    users: { ua1: mk('ua1', 1, 'unit_admin', false), ua2: mk('ua2', 2, 'unit_admin', false), sup: mk('sup', 3, 'supervisor', false), fresh: mk('fresh', 4, 'supervisor', true) },
  };
}

async function findAuthUserId(sb: SupabaseClient, email: string): Promise<string | null> {
  for (let page = 1; page < 50; page++) {
    const { data, error } = await sb.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) throw error;
    const hit = data.users.find((u) => u.email === email);
    if (hit) return hit.id;
    if (data.users.length < 1000) return null;
  }
  return null;
}

/** Idempotently (re)creates the org and puts its four users in their canonical state. */
export async function provisionOrg(org: Org): Promise<void> {
  const sb = service();
  const { error: tErr } = await sb.from('tenant').upsert({ id: org.id, name: org.name, status: 'active' });
  if (tErr) throw tErr;
  for (const u of Object.values(org.users)) {
    const email = phoneToAuthEmail(u.phone);
    let id = await findAuthUserId(sb, email);
    if (id) {
      const { error } = await sb.auth.admin.updateUserById(id, { password: FIXTURE_PASSWORD, ban_duration: 'none' });
      if (error) throw error;
    } else {
      const { data, error } = await sb.auth.admin.createUser({ email, password: FIXTURE_PASSWORD, email_confirm: true });
      if (error || !data.user) throw error ?? new Error('createUser failed');
      id = data.user.id;
    }
    u.id = id;
    const { error: mErr } = await sb.from('membership').upsert(
      {
        tenant_id: org.id, user_id: id, role: u.role, status: 'active',
        full_name: `Fixture ${u.key}`, employee_id: `FX-${org.id.slice(-2)}-${u.key}`.toUpperCase(), phone_e164: u.phone,
        must_change_password: u.mustChange, temp_password_expires_at: u.mustChange ? new Date(Date.now() + 20 * 3600_000).toISOString() : null,
      },
      { onConflict: 'user_id' },
    );
    if (mErr) throw mErr;
  }
}

// ---- Throwaway users (D2: +91 90000 10000-99999) ------------------------------------------------------------------
let seq = Math.floor(Math.random() * 40000);
export function throwawayPhone(): string {
  seq = (seq + 1 + Math.floor(Math.random() * 3)) % 89999;
  return `+9190000${String(10000 + seq).padStart(5, '0')}`;
}
export const throwawayEmpId = () => `T${Math.random().toString(36).slice(2, 9).toUpperCase()}`;

export const created: string[] = [];

// ---- Platform Super Admin fixtures (03, D8): canonical block +91 90000 00090-00091 -------------------------------------------------------
export const SA_FIXTURES = {
  sa1: { phone: '+919000000090', name: 'Fixture Super Admin 1' },
  sa2: { phone: '+919000000091', name: 'Fixture Super Admin 2' },
} as const;

/** Idempotently (re)creates a fixture Super Admin in its canonical state (active, normal password) and returns its user id. */
export async function provisionSuperAdmin(def: { phone: string; name: string }): Promise<string> {
  const sb = service();
  const email = phoneToAuthEmail(def.phone);
  let id = await findAuthUserId(sb, email);
  if (id) {
    const { error } = await sb.auth.admin.updateUserById(id, { password: FIXTURE_PASSWORD, ban_duration: 'none' });
    if (error) throw error;
  } else {
    const { data, error } = await sb.auth.admin.createUser({ email, password: FIXTURE_PASSWORD, email_confirm: true });
    if (error || !data.user) throw error ?? new Error('createUser failed');
    id = data.user.id;
  }
  const { error: pErr } = await sb.from('platform_admin').upsert(
    { user_id: id, full_name: def.name, phone_e164: def.phone, status: 'active', must_change_password: false, temp_password_expires_at: null },
    { onConflict: 'user_id' },
  );
  if (pErr) throw pErr;
  return id;
}

export const tenantNameOf = () => `e2e t3 ${Math.random().toString(36).slice(2, 10)}`;

export async function cleanupCreated() {
  if (created.length === 0) return;
  const sb = service();
  for (const id of created.splice(0)) await sb.auth.admin.deleteUser(id);
}

export type NewUser = { userId: string; phone: string; employeeId: string; tempPassword: string };

export async function createUserVia(request: APIRequestContext, token: string, over: Partial<{ full_name: string; employee_id: string; phone: string; role: string; request_id: string }> = {}) {
  const phone = over.phone ?? throwawayPhone();
  const employee_id = over.employee_id ?? throwawayEmpId();
  const res = await callFn(request, 'user-admin', token, {
    action: 'create', request_id: over.request_id ?? uuid(), full_name: over.full_name ?? 'Throwaway User', employee_id, phone, role: over.role ?? 'supervisor',
  });
  if (res.status === 200 && res.body.user_id) created.push(res.body.user_id);
  return { res, phone, employeeId: employee_id };
}

/** create -> sign in with the temporary password -> change it, so the user is a normal active user. */
export async function makeActiveUser(request: APIRequestContext, uaToken: string, role = 'supervisor') {
  const { res, phone, employeeId } = await createUserVia(request, uaToken, { role });
  if (res.status !== 200) throw new Error(`create failed ${res.status} ${JSON.stringify(res.body)}`);
  const s = await signIn(phone, res.body.temp_password);
  const password = `Active-${Math.random().toString(36).slice(2, 8)}9x`;
  const ch = await callFn(request, 'account', s.token, { action: 'change_password', current_password: res.body.temp_password, new_password: password });
  if (ch.status !== 200) throw new Error(`change failed ${ch.status} ${JSON.stringify(ch.body)}`);
  return { userId: res.body.user_id as string, phone, employeeId, password };
}

// ---- Queries via the service client -------------------------------------------------------------------------------
export async function auditRows(filter: { action?: string; actor?: string; entity?: string; tenant?: string; reason?: string; requestId?: string }) {
  let q = service().from('audit_event').select('*').order('occurred_at', { ascending: true });
  if (filter.action) q = q.eq('action', filter.action);
  if (filter.actor) q = q.eq('actor_user_id', filter.actor);
  if (filter.entity) q = q.eq('entity_id', filter.entity);
  if (filter.tenant) q = q.eq('tenant_id', filter.tenant);
  if (filter.reason) q = q.eq('reason', filter.reason);
  if (filter.requestId) q = q.eq('request_id', filter.requestId);
  const { data, error } = await q;
  if (error) throw error;
  return data ?? [];
}

export async function membershipOf(userId: string) {
  const { data, error } = await service().from('membership').select('*').eq('user_id', userId).maybeSingle();
  if (error) throw error;
  return data;
}

export async function authUserExists(phone: string): Promise<boolean> {
  return (await findAuthUserId(service(), phoneToAuthEmail(phone))) !== null;
}

export { authEmailToPhone, phoneToAuthEmail };
