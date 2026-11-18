// Shared helpers for the API project (02-tenancy-and-roles, D10). Talks to Auth, PostgREST and the Edge Functions over HTTP.
// Local/ephemeral stacks only: CI exports E2E_API_URL / E2E_ANON_KEY / E2E_SERVICE_ROLE_KEY from `supabase status`.
import { createHash } from 'node:crypto';
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

/**
 * An org with explicit ids and phones, for specs that need an org outside orgDef(1..9). `phones` = [ua1, ua2, sup, fresh]; keep them in the
 * throwaway block (+91 90000 10000-99999), never in the canonical 00001-00099 block (D2).
 */
export function customOrg(tenantId: string, name: string, phones: [string, string, string, string]): Org {
  const mk = (key: OrgUser['key'], i: number, role: OrgUser['role'], mustChange: boolean): OrgUser => ({
    key, id: '', phone: phones[i - 1], role, mustChange,
  });
  return {
    id: tenantId,
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

// ---- Platform Super Admin fixtures (03, D8): canonical block +91 90000 00098-00099 -------------------------------------------------------
export const SA_FIXTURES = {
  sa1: { phone: '+919000000098', name: 'Fixture Super Admin 1' },
  sa2: { phone: '+919000000099', name: 'Fixture Super Admin 2' },
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

// ---- 07-issue-lifecycle world --------------------------------------------------------------------------------------------------------------
// One machine on two shifts that together cover the day (AM 00:00-12:00 owned by sup1, PM 12:00-00:00 owned by sup2, plant time Asia/Kolkata),
// so exactly one shift is running at any moment and the shift that started at the last boundary has an owner who may verify an issue that
// was resolved before that boundary. Everything is derived from the clock, so no case depends on the time of day (D10). Not safe in the
// two seconds around 00:00 / 12:00 IST (the running shift would flip mid-test).
export const IST_OFFSET_MIN = 330;
export const TINY_JPEG = Buffer.from(
  '/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=',
  'base64',
);
export const sha256Hex = (b: Buffer) => createHash('sha256').update(b).digest('hex');
/** A 1x1 PNG, for the web file chooser. */
export const TINY_PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');

export type IssueWorld = {
  org: Org;
  ua: Session;
  sup1: Session; // owns the AM shift
  sup2: Session; // owns the PM shift
  machine: { id: string; code: string };
  shiftAm: string;
  shiftPm: string;
  today: string;
  /** The supervisor whose shift is running now, and the one whose shift is not. */
  running: { user: OrgUser; session: Session };
  idle: { user: OrgUser; session: Session };
  /** Start of the shift that is running now (the last boundary). An issue resolved before it can be verified by `running`. */
  lastBoundary: Date;
  categoryId: string;
  cleanup: string[];
};

export async function setupIssueWorld(org: Org, plantName: string): Promise<IssueWorld> {
  org.users.fresh.mustChange = false; // the fourth user is the second supervisor here
  await provisionOrg(org);
  const ua = await signIn(org.users.ua1.phone, FIXTURE_PASSWORD);
  const sup1 = await signIn(org.users.sup.phone, FIXTURE_PASSWORD);
  const sup2 = await signIn(org.users.fresh.phone, FIXTURE_PASSWORD);
  const rpc = (fn: string, args: Record<string, unknown>) => ua.client.rpc(fn, args);
  const site = await rpc('pm_save_site', { p_request_id: uuid(), p_name: plantName, p_timezone: 'Asia/Kolkata' });
  if (site.error) throw site.error;
  const old = await ua.client.from('shift').select('id').is('retired_at', null);
  for (const row of old.data ?? []) await rpc('sh_set_shift_retired', { p_request_id: uuid(), p_id: row.id, p_retired: true });
  const code = `E2E-${Math.random().toString(36).slice(2, 10).toUpperCase()}`;
  const mk = await rpc('pm_save_machine', { p_request_id: uuid(), p_id: null, p_code: code, p_name: 'E2E issue machine', p_asset_tag: '', p_make: '', p_model: '', p_controller: '', p_line_id: null, p_status: 'active' });
  if (!mk.data?.ok) throw new Error(`machine: ${JSON.stringify(mk)}`);
  const shift = async (start: string, end: string) => {
    const r = await rpc('sh_save_shift', { p_request_id: uuid(), p_id: null, p_name: `E2E-${Math.random().toString(36).slice(2, 10).toUpperCase()}`, p_start: start, p_end: end });
    if (!r.data?.ok) throw new Error(`shift: ${JSON.stringify(r)}`);
    return r.data.id as string;
  };
  const shiftAm = await shift('00:00', '12:00');
  const shiftPm = await shift('12:00', '00:00');
  const t = await ua.client.from('plant_today').select('plant_date').single();
  const today = t.data!.plant_date as string;
  // The standing plan is seeded as service role dated today (a plan change cannot start on an occurrence that has already started, 05 R1).
  for (const [s, who] of [[shiftAm, sup1], [shiftPm, sup2]] as const) {
    const r = await service().from('assignment_version').insert({ tenant_id: org.id, shift_id: s, machine_id: mk.data.id, supervisor_id: who.userId, effective_from: today, recorded_by: ua.userId }).select('id');
    if (r.error) throw r.error;
  }
  const cat = await ua.client.from('issue_category').select('id').eq('name', 'Mechanical').single();
  if (cat.error) throw cat.error;
  const ist = new Date(Date.now() + IST_OFFSET_MIN * 60_000);
  const pm = ist.getUTCHours() >= 12;
  const lastBoundary = new Date(Date.UTC(ist.getUTCFullYear(), ist.getUTCMonth(), ist.getUTCDate(), pm ? 12 : 0) - IST_OFFSET_MIN * 60_000);
  return {
    org, ua, sup1, sup2, machine: { id: mk.data.id, code }, shiftAm, shiftPm, today, lastBoundary, categoryId: cat.data.id,
    running: pm ? { user: org.users.fresh, session: sup2 } : { user: org.users.sup, session: sup1 },
    idle: pm ? { user: org.users.sup, session: sup1 } : { user: org.users.fresh, session: sup2 },
    cleanup: [mk.data.id],
  };
}

/** Retires the throwaway shifts and machine (history is append-only, so they cannot be deleted). Never throws. */
export async function teardownIssueWorld(w: IssueWorld | undefined) {
  if (!w) return;
  try {
    for (const id of [w.shiftAm, w.shiftPm]) await w.ua.client.rpc('sh_set_shift_retired', { p_request_id: uuid(), p_id: id, p_retired: true });
    for (const id of w.cleanup) await w.ua.client.rpc('pm_set_machine_retired', { p_request_id: uuid(), p_id: id, p_retired: true });
  } catch {
    /* best effort */
  }
}

/**
 * An issue already resolved by the idle supervisor one hour before the last shift boundary (service-role insert, like the fixture issues):
 * the running supervisor owns the shift that started after it, so they may verify it (D4). Returns the issue id.
 */
export async function seedResolvedIssue(w: IssueWorld, priority: 'high' | 'critical', description: string): Promise<string> {
  const sb = service();
  const id = uuid();
  const resolver = w.idle.session.userId;
  const reportedAt = new Date(w.lastBoundary.getTime() - 2 * 3600_000).toISOString();
  const resolvedAt = new Date(w.lastBoundary.getTime() - 3600_000).toISOString();
  const ins = async (table: string, row: Record<string, unknown>) => {
    const r = await sb.from(table).insert(row).select('*');
    if (r.error) throw new Error(`${table}: ${r.error.message}`);
  };
  await ins('machine_issue', {
    id, tenant_id: w.org.id, machine_id: w.machine.id, category_id: w.categoryId, priority, description, machine_stopped: false, status: 'resolved',
    accountable_owner_id: resolver, reported_by: resolver, reported_at: reportedAt, resolved_by: resolver, resolved_at: resolvedAt, resolution_notes: 'E2E seeded fix',
  });
  await ins('issue_action', { tenant_id: w.org.id, issue_id: id, actor_id: resolver, actor_role: 'supervisor', type: 'report', status_after: 'open', at: reportedAt });
  await ins('issue_action', { tenant_id: w.org.id, issue_id: id, actor_id: resolver, actor_role: 'supervisor', type: 'resolve', notes: 'E2E seeded fix', status_before: 'open', status_after: 'resolved', at: resolvedAt });
  await ins('issue_ownership_history', { tenant_id: w.org.id, issue_id: id, new_owner: resolver, source: 'report', actor_id: resolver, at: reportedAt });
  return id;
}

/**
 * 08: turns the handover gate on for the world's tenant (a tenant inserted directly has no handover_setting row and is not gated). Service role, like the
 * issue seeds; a tenant registered through the Console gets the row from the registration hook.
 */
export async function enforceHandover(w: IssueWorld, overdueMinutes = 60): Promise<void> {
  const r = await service().from('handover_setting').upsert({ tenant_id: w.org.id, overdue_minutes: overdueMinutes, required: true }, { onConflict: 'tenant_id' }).select('tenant_id');
  if (r.error) throw new Error(`handover_setting: ${r.error.message}`);
}

/**
 * 08: an issue that is open on the world's machine, reported by the idle supervisor two hours before the last shift boundary and owned by them, so the
 * running supervisor (who owns the machine in the shift that started at that boundary) inherits it at their handover. Service-role insert (like
 * seedResolvedIssue); returns the issue id.
 */
export async function seedInheritedIssue(w: IssueWorld, priority: 'low' | 'medium' | 'high' | 'critical', description: string): Promise<string> {
  const sb = service();
  const id = uuid();
  const owner = w.idle.session.userId;
  const reportedAt = new Date(w.lastBoundary.getTime() - 2 * 3600_000).toISOString();
  const ins = async (table: string, row: Record<string, unknown>) => {
    const r = await sb.from(table).insert(row).select('*');
    if (r.error) throw new Error(`${table}: ${r.error.message}`);
  };
  await ins('machine_issue', {
    id, tenant_id: w.org.id, machine_id: w.machine.id, category_id: w.categoryId, priority, description, machine_stopped: false, status: 'open',
    accountable_owner_id: owner, reported_by: owner, reported_at: reportedAt,
  });
  await ins('issue_action', { tenant_id: w.org.id, issue_id: id, actor_id: owner, actor_role: 'supervisor', type: 'report', status_after: 'open', at: reportedAt });
  await ins('issue_ownership_history', { tenant_id: w.org.id, issue_id: id, new_owner: owner, source: 'report', actor_id: owner, at: reportedAt });
  return id;
}
