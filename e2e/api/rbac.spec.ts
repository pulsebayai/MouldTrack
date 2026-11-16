// 02 AC-9, 10, 11, 12 through the real stack: role denial, cross-tenant denial, audit integrity, in-flight deactivation /
// suspension. Orgs: R "e2e org U-rbac" (users 1-4) and Q "e2e org U-other-rbac" (a different tenant to attack).
import { expect, test } from '@playwright/test';
import {
  FIXTURE_PASSWORD, anon, auditRows, callFn, cleanupCreated, makeActiveUser, membershipOf, orgDef, provisionOrg,
  requireApi, service, signIn, throwawayEmpId, throwawayPhone, uuid, API_URL, type Session,
} from './helpers';

const R = orgDef(3, 'e2e org U-rbac');
const Q = orgDef(4, 'e2e org U-other-rbac');
let ua: Session;
let sup: Session;
let qua: Session;

test.beforeAll(async () => {
  requireApi();
  await provisionOrg(R);
  await provisionOrg(Q);
  ua = await signIn(R.users.ua1.phone, FIXTURE_PASSWORD);
  sup = await signIn(R.users.sup.phone, FIXTURE_PASSWORD);
  qua = await signIn(Q.users.ua1.phone, FIXTURE_PASSWORD);
});
test.afterAll(async () => {
  await service().from('tenant').update({ status: 'active' }).eq('id', Q.id);
  await cleanupCreated();
});

const ACTIONS = (target: string) => [
  { action: 'create', request_id: uuid(), full_name: 'Nope', employee_id: throwawayEmpId(), phone: throwawayPhone(), role: 'supervisor' },
  { action: 'update', request_id: uuid(), user_id: target, full_name: 'Nope' },
  { action: 'set_status', request_id: uuid(), user_id: target, status: 'inactive' },
  { action: 'reset_password', request_id: uuid(), user_id: target },
];

test.describe('AC-9 role', () => {
  test('a supervisor gets a generic 403 for every user-admin action, each audited as access.denied (role)', async ({ request }) => {
    const before = (await auditRows({ action: 'access.denied', actor: sup.userId })).length;
    for (const body of ACTIONS(R.users.fresh.id)) {
      const r = await callFn(request, 'user-admin', sup.token, body);
      expect(r.status, body.action).toBe(403);
      expect(r.body).toEqual({ message: 'Not allowed' });
    }
    const events = (await auditRows({ action: 'access.denied', actor: sup.userId })).slice(before);
    expect(events).toHaveLength(4);
    for (const e of events) expect(e).toMatchObject({ tenant_id: R.id, reason: 'role', actor_role: 'supervisor', request_id: null });
    expect((await membershipOf(R.users.fresh.id))!.status).toBe('active');
  });

  test('a supervisor reads only their own membership and no audit events', async () => {
    const own = await sup.client.from('membership').select('user_id');
    expect(own.data).toEqual([{ user_id: sup.userId }]);
    expect((await sup.client.from('audit_event').select('id')).data).toEqual([]);
  });
});

test.describe('AC-10 cross-tenant', () => {
  test('a UA of R targeting a user of Q gets the same 403 as for an unknown id, audited under R', async ({ request }) => {
    const qUser = Q.users.sup.id;
    const unknown = uuid();
    const before = (await auditRows({ action: 'access.denied', actor: ua.userId })).length;
    for (const make of [
      (t: string) => ({ action: 'update', request_id: uuid(), user_id: t, full_name: 'Hacked' }),
      (t: string) => ({ action: 'set_status', request_id: uuid(), user_id: t, status: 'inactive' }),
      (t: string) => ({ action: 'reset_password', request_id: uuid(), user_id: t }),
    ]) {
      const cross = await callFn(request, 'user-admin', ua.token, make(qUser));
      const missing = await callFn(request, 'user-admin', ua.token, make(unknown));
      expect(cross.status).toBe(403);
      expect(cross).toEqual(missing); // no existence leak
      expect(cross.body).toEqual({ message: 'Not allowed' });
    }
    const events = (await auditRows({ action: 'access.denied', actor: ua.userId })).slice(before);
    expect(events.filter((e) => e.reason === 'cross_tenant')).toHaveLength(3);
    for (const e of events) expect(e.tenant_id).toBe(R.id);
    expect(await auditRows({ action: 'access.denied', tenant: Q.id, actor: ua.userId })).toHaveLength(0);
    expect(await membershipOf(qUser)).toMatchObject({ status: 'active', full_name: 'Fixture sup' });
  });

  test('a UA reads only their own tenant\'s memberships and audit events', async () => {
    const m = await ua.client.from('membership').select('tenant_id');
    expect(m.data!.length).toBeGreaterThanOrEqual(4);
    for (const r of m.data!) expect(r.tenant_id).toBe(R.id);
    const a = await ua.client.from('audit_event').select('tenant_id');
    expect(a.data!.length).toBeGreaterThan(0);
    for (const r of a.data!) expect(r.tenant_id).toBe(R.id);
    expect((await ua.client.from('membership').select('id').eq('user_id', Q.users.sup.id)).data).toEqual([]);
  });
});

test.describe('AC-11 audit integrity', () => {
  test('no client role can insert, update or delete audit events; neither can the service role update or delete', async () => {
    const rows = await auditRows({ tenant: R.id });
    expect(rows.length).toBeGreaterThan(0);
    const id = rows[0].id;
    for (const client of [ua.client, sup.client, anon()]) {
      expect((await client.from('audit_event').insert({ action: 'user.created', source: 'x', tenant_id: R.id })).error).not.toBeNull();
      expect((await client.from('audit_event').update({ reason: 'tamper' }).eq('id', id)).error).not.toBeNull();
      expect((await client.from('audit_event').delete().eq('id', id)).error).not.toBeNull();
    }
    const sb = service();
    expect((await sb.from('audit_event').update({ reason: 'tamper' }).eq('id', id)).error).not.toBeNull();
    expect((await sb.from('audit_event').delete().eq('id', id)).error).not.toBeNull();
    expect((await auditRows({ tenant: R.id })).find((r) => r.id === id)!.reason).toBe(rows[0].reason);
  });

  test('the service-only functions are not callable by clients', async () => {
    const args = { p_actor: ua.userId, p_request_id: uuid(), p_user_id: R.users.sup.id, p_status: 'inactive' };
    expect((await ua.client.rpc('svc_ua_set_status', args)).error).not.toBeNull();
    expect((await anon().rpc('svc_ua_set_status', args)).error).not.toBeNull();
    expect((await membershipOf(R.users.sup.id))!.status).toBe('active');
  });
});

test.describe('AC-12 in flight', () => {
  test('a user deactivated while holding a valid token is denied and audited (inactive)', async ({ request }) => {
    const u = await makeActiveUser(request, ua.token, 'unit_admin');
    const held = await signIn(u.phone, u.password);
    expect((await callFn(request, 'user-admin', ua.token, { action: 'set_status', request_id: uuid(), user_id: u.userId, status: 'inactive' })).status).toBe(200);
    const r = await callFn(request, 'user-admin', held.token, ACTIONS(R.users.sup.id)[0]);
    expect(r.status).toBe(403);
    expect(r.body).toEqual({ message: 'Not allowed' });
    const events = await auditRows({ action: 'access.denied', actor: u.userId });
    expect(events.map((e) => e.reason)).toEqual(['inactive']);
    expect(events[0].tenant_id).toBe(R.id);
  });

  test('a UA of a suspended tenant is denied and audited (inactive)', async ({ request }) => {
    const sb = service();
    try {
      await sb.from('tenant').update({ status: 'suspended' }).eq('id', Q.id);
      const r = await callFn(request, 'user-admin', qua.token, ACTIONS(Q.users.sup.id)[2]);
      expect(r.status).toBe(403);
      expect(r.body).toEqual({ message: 'Not allowed' });
      const events = await auditRows({ action: 'access.denied', actor: qua.userId });
      expect(events.at(-1)).toMatchObject({ reason: 'inactive', tenant_id: Q.id });
      expect((await qua.client.from('tenant').select('id')).data).toEqual([]);
    } finally {
      await sb.from('tenant').update({ status: 'active' }).eq('id', Q.id);
    }
  });
});

test.describe('CORS (D8)', () => {
  test('preflight allows the app origin and localhost, never a foreign origin', async ({ request }) => {
    const url = `${API_URL}/functions/v1/user-admin`;
    const ok = await request.fetch(url, { method: 'OPTIONS', headers: { Origin: 'http://localhost:8081', 'Access-Control-Request-Method': 'POST' } });
    expect(ok.status()).toBe(204);
    expect(ok.headers()['access-control-allow-origin']).toBe('http://localhost:8081');
    const evil = await request.fetch(url, { method: 'OPTIONS', headers: { Origin: 'https://evil.example', 'Access-Control-Request-Method': 'POST' } });
    expect(evil.status()).toBe(204);
    expect(evil.headers()['access-control-allow-origin']).toBeUndefined();
  });

  test('responses never expose auth internals or the service key', async ({ request }) => {
    const r = await callFn(request, 'user-admin', sup.token, ACTIONS(R.users.fresh.id)[0]);
    const text = JSON.stringify(r);
    expect(text).not.toMatch(/service_role|eyJ|password_hash|encrypted_password|stack/i);
  });
});
