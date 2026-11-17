// 03 AC-2: the one-time setup endpoint. LOCAL STACK ONLY: the test empties platform_admin (hosted dev already has Super Admins and
// no token; the hosted check asserts the endpoint refuses there). Runs in its own Playwright project after every other project,
// then restores the fixture Super Admins. The token is a non-secret literal from supabase/config.toml (local stack only).
import { expect, test } from '@playwright/test';
import { API_URL, SA_FIXTURES, auditRows, callFn, callSetup, created, cleanupCreated, provisionSuperAdmin, requireApi, service, signIn, throwawayPhone, uuid } from './helpers';

const LOCAL = /^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(API_URL);
const TOKEN = process.env.E2E_SETUP_TOKEN ?? 'local-setup-token-not-a-secret-0123456789';

test.describe.configure({ mode: 'serial' });

test.beforeAll(async () => {
  requireApi();
  test.skip(!LOCAL, 'platform-setup behaviour tests run on the local stack only (D9)');
  const sb = service();
  const { error } = await sb.from('platform_admin').delete().not('user_id', 'is', null); // frees the claims too (trigger)
  if (error) throw error;
});

test.afterAll(async () => {
  if (!LOCAL) return;
  await cleanupCreated();
  await provisionSuperAdmin(SA_FIXTURES.sa1);
  await provisionSuperAdmin(SA_FIXTURES.sa2);
});

test('a missing or wrong token is refused with 403 and creates nothing', async ({ request }) => {
  const phone = throwawayPhone();
  for (const token of [null, '', 'wrong-token', TOKEN.slice(0, -1), `${TOKEN}x`]) {
    const r = await callSetup(request, token, { full_name: 'Intruder', phone });
    expect(r.status, String(token)).toBe(403);
    expect(r.body).toEqual({ code: 'not_allowed', message: 'Not allowed' });
  }
  expect((await service().from('platform_admin').select('user_id')).data).toEqual([]);
  // R2: while setup is open a wrong token is audited, throttled to one row a minute, and the secret never appears in the row.
  const since = new Date(Date.now() - 60_000).toISOString();
  const { data: rows } = await service().from('audit_event').select('reason, source, actor_user_id, tenant_id, before, after').eq('reason', 'setup_bad_token').gte('occurred_at', since);
  expect(rows!.length).toBe(1);
  expect(rows![0]).toMatchObject({ source: 'edge:platform-setup', actor_user_id: null, tenant_id: null });
  expect(JSON.stringify(rows)).not.toContain(TOKEN);
});

test('GET and non-JSON bodies are refused before anything happens', async ({ request }) => {
  const get = await request.get(`${API_URL}/functions/v1/platform-setup`, { headers: { 'x-setup-token': TOKEN } });
  expect(get.status()).toBe(405);
  const bad = await request.post(`${API_URL}/functions/v1/platform-setup`, { headers: { 'x-setup-token': TOKEN, 'Content-Type': 'text/plain' }, data: 'nope' });
  expect(bad.status()).toBe(400);
});

test('the right token creates the first Super Admin and returns a temporary password once; the account then signs in and works', async ({ request }) => {
  const phone = throwawayPhone();
  const bad = await callSetup(request, TOKEN, { full_name: '', phone });
  expect(bad.status).toBe(400);
  const r = await callSetup(request, TOKEN, { full_name: ' First Platform Admin ', phone });
  expect(r.status).toBe(200);
  created.push(r.body.user_id);
  expect(r.body.temp_password).toMatch(/^[A-HJ-NP-Za-km-z2-9]{12}$/);
  expect(Object.keys(r.body).sort()).toEqual(['temp_password', 'user_id']);

  const row = (await service().from('platform_admin').select('*').eq('user_id', r.body.user_id).single()).data!;
  expect(row).toMatchObject({ full_name: 'First Platform Admin', status: 'active', must_change_password: true, created_by: null });
  const events = await auditRows({ action: 'platform_admin.created', entity: r.body.user_id });
  expect(events).toHaveLength(1);
  expect(events[0]).toMatchObject({ source: 'edge:platform-setup', actor_user_id: null, tenant_id: null });
  expect(events[0].after.phone).toBe(`+91******${phone.slice(-4)}`);
  expect(JSON.stringify(events)).not.toContain(r.body.temp_password);
  expect(JSON.stringify(events)).not.toContain(TOKEN);

  const s = await signIn(phone, r.body.temp_password);
  expect((await callFn(request, 'platform', s.token, { action: 'tenant_create', request_id: uuid(), name: 'e2e t3 setup' })).status).toBe(403); // must change password first
});

test('once any Super Admin exists the endpoint refuses, with or without the token, and audits it', async ({ request }) => {
  const before = (await service().from('platform_admin').select('user_id')).data!.length;
  for (const token of [TOKEN, null, 'wrong']) {
    const r = await callSetup(request, token, { full_name: 'Second', phone: throwawayPhone() });
    expect(r.status, String(token)).toBe(403);
    expect(r.body).toEqual({ code: 'setup_closed', message: 'Not allowed' });
  }
  expect((await service().from('platform_admin').select('user_id')).data).toHaveLength(before);
  const denied = await auditRows({ action: 'access.denied', reason: 'setup_closed' });
  expect(denied.length).toBeGreaterThanOrEqual(1);
  expect(denied[0]).toMatchObject({ source: 'edge:platform-setup', actor_user_id: null, tenant_id: null });
});

test('two simultaneous setup calls on an empty platform create exactly one Super Admin', async ({ request }) => {
  await service().from('platform_admin').delete().not('user_id', 'is', null);
  const phones = [throwawayPhone(), throwawayPhone()];
  const results = await Promise.all(phones.map((phone) => callSetup(request, TOKEN, { full_name: 'Racer', phone })));
  for (const r of results) if (r.status === 200) created.push(r.body.user_id);
  expect(results.filter((r) => r.status === 200)).toHaveLength(1);
  expect(results.filter((r) => r.status === 403)).toHaveLength(1);
  expect((await service().from('platform_admin').select('user_id')).data).toHaveLength(1);
});

test('F2: an expired setup password does not lock the platform out: the token re-issues a new one for the same Super Admin', async ({ request }) => {
  const sb = service();
  const sa = (await sb.from('platform_admin').select('user_id, phone_e164, full_name').single()).data!;
  // Still valid: closed.
  const closed = await callSetup(request, TOKEN, { full_name: 'Again', phone: throwawayPhone() });
  expect(closed.status).toBe(403);
  expect(closed.body).toEqual({ code: 'setup_closed', message: 'Not allowed' });
  // The temporary password expires without anyone signing in: setup re-opens for that account only.
  await sb.from('platform_admin').update({ temp_password_expires_at: new Date(Date.now() - 60_000).toISOString() }).eq('user_id', sa.user_id);
  const wrong = await callSetup(request, 'wrong-token', { full_name: 'Again', phone: throwawayPhone() });
  expect(wrong.status).toBe(403);
  expect((await sb.from('platform_admin').select('temp_password_expires_at').eq('user_id', sa.user_id).single()).data!.temp_password_expires_at).not.toBeNull();
  const r = await callSetup(request, TOKEN, { full_name: 'Again', phone: throwawayPhone() });
  expect(r.status).toBe(200);
  expect(r.body.user_id).toBe(sa.user_id);
  expect(r.body.temp_password).toMatch(/^[A-HJ-NP-Za-km-z2-9]{12}$/);
  const row = (await sb.from('platform_admin').select('full_name, phone_e164, must_change_password, temp_password_expires_at').eq('user_id', sa.user_id).single()).data!;
  expect(row).toMatchObject({ full_name: sa.full_name, phone_e164: sa.phone_e164, must_change_password: true });
  expect(new Date(row.temp_password_expires_at!).getTime()).toBeGreaterThan(Date.now() + 23 * 3600_000);
  expect((await sb.from('platform_admin').select('user_id')).data).toHaveLength(1);
  const events = await auditRows({ action: 'platform_admin.password_reset', entity: sa.user_id });
  expect(events).toHaveLength(1);
  expect(events[0]).toMatchObject({ source: 'edge:platform-setup', actor_user_id: null, tenant_id: null });
  expect(JSON.stringify(events)).not.toContain(r.body.temp_password);
  await signIn(sa.phone_e164, r.body.temp_password); // the new password works
  const again = await callSetup(request, TOKEN, { full_name: 'Again', phone: throwawayPhone() });
  expect(again.status).toBe(403); // closed again while the new password is valid
});
