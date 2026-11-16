// 03 AC-3..14 through the platform Edge Function: every action, role checks with audit, idempotency, compensation, suspension
// effects on a tenant's users, and the Super Admin data boundary over PostgREST. Own fixtures: Super Admins +91 90000 00098-99,
// org "e2e api org 7" for tenant-user denials, throwaway tenants "e2e t3 ..." (never deleted; fixtures-reset suspends them).
import { expect, test } from '@playwright/test';
import {
  SA_FIXTURES, anon, auditRows, authUserExists, callFn, cleanupCreated, created, makeActiveUser, membershipOf, orgDef, provisionOrg,
  provisionSuperAdmin, requireApi, service, signIn, signInFails, tenantNameOf, throwawayEmpId, throwawayPhone, uuid, FIXTURE_PASSWORD, type Session,
} from './helpers';

const org = orgDef(7, 'e2e api org 7'); // supplies a tenant UA and supervisor for denial checks
let sa: Session;
let saId: string;

test.beforeAll(async () => {
  requireApi();
  saId = await provisionSuperAdmin(SA_FIXTURES.sa1);
  await provisionSuperAdmin(SA_FIXTURES.sa2);
  await provisionOrg(org);
  sa = await signIn(SA_FIXTURES.sa1.phone, FIXTURE_PASSWORD);
});
test.afterAll(async () => {
  await cleanupCreated();
});

async function newTenant(request: Parameters<typeof callFn>[0], over: Record<string, unknown> = {}) {
  const name = tenantNameOf();
  const res = await callFn(request, 'platform', sa.token, { action: 'tenant_create', request_id: uuid(), name, ...over });
  if (res.status !== 200) throw new Error(`tenant_create failed ${res.status} ${JSON.stringify(res.body)}`);
  return { id: res.body.tenant_id as string, name };
}

async function newUnitAdmin(request: Parameters<typeof callFn>[0], tenantId: string) {
  const phone = throwawayPhone();
  const res = await callFn(request, 'platform', sa.token, {
    action: 'ua_create', request_id: uuid(), tenant_id: tenantId, full_name: 'First Admin', employee_id: throwawayEmpId(), phone,
  });
  if (res.status !== 200) throw new Error(`ua_create failed ${res.status} ${JSON.stringify(res.body)}`);
  created.push(res.body.user_id);
  return { userId: res.body.user_id as string, phone, tempPassword: res.body.temp_password as string };
}

/** temp password -> sign in -> change -> sign in again: a normal active user. */
async function activate(request: Parameters<typeof callFn>[0], phone: string, tempPassword: string) {
  const s = await signIn(phone, tempPassword);
  const password = `Active-${Math.random().toString(36).slice(2, 8)}9x`;
  const ch = await callFn(request, 'account', s.token, { action: 'change_password', current_password: tempPassword, new_password: password });
  if (ch.status !== 200) throw new Error(`change failed ${ch.status} ${JSON.stringify(ch.body)}`);
  return { session: await signIn(phone, password), password };
}

test.describe('AC-4 register tenant', () => {
  test('creates an active Trial tenant in Asia/Kolkata and audits it under the tenant', async ({ request }) => {
    const request_id = uuid();
    const name = tenantNameOf();
    const r = await callFn(request, 'platform', sa.token, { action: 'tenant_create', request_id, name: `  ${name}  ` });
    expect(r.status).toBe(200);
    const row = (await service().from('tenant').select('*').eq('id', r.body.tenant_id).single()).data!;
    expect(row).toMatchObject({ name, status: 'active', plan_label: 'trial', timezone: 'Asia/Kolkata', suspended_reason: null });
    const events = await auditRows({ action: 'tenant.created', entity: r.body.tenant_id });
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ tenant_id: r.body.tenant_id, actor_user_id: saId, actor_role: 'platform_admin', source: 'edge:platform', request_id });
    expect(events[0].after).toMatchObject({ name, plan_label: 'trial' });
  });

  test('a retry with the same request id creates nothing new', async ({ request }) => {
    const request_id = uuid();
    const name = tenantNameOf();
    const body = { action: 'tenant_create', request_id, name, timezone: 'Asia/Dubai', plan_label: 'active' };
    const a = await callFn(request, 'platform', sa.token, body);
    const b = await callFn(request, 'platform', sa.token, body);
    expect(a.status).toBe(200);
    expect(b.body).toEqual({ tenant_id: a.body.tenant_id, already: true });
    expect((await service().from('tenant').select('id').eq('name', name)).data).toHaveLength(1);
    expect(await auditRows({ action: 'tenant.created', requestId: request_id })).toHaveLength(1);
  });

  test('validation and duplicate names (any case)', async ({ request }) => {
    const t = await newTenant(request);
    for (const [patch, field] of [
      [{ name: '   ' }, 'name'],
      [{ name: 'n'.repeat(81) }, 'name'],
      [{ timezone: 'Mars/Base' }, 'timezone'],
      [{ plan_label: 'gold' }, 'plan_label'],
    ] as const) {
      const r = await callFn(request, 'platform', sa.token, { action: 'tenant_create', request_id: uuid(), name: tenantNameOf(), ...patch });
      expect(r.status, JSON.stringify(patch)).toBe(400);
      expect(r.body.field).toBe(field);
    }
    const dup = await callFn(request, 'platform', sa.token, { action: 'tenant_create', request_id: uuid(), name: t.name.toUpperCase() });
    expect(dup.status).toBe(409);
    expect(dup.body.field).toBe('name');
    expect((await callFn(request, 'platform', sa.token, { action: 'tenant_create', request_id: 'nope', name: 'x' })).status).toBe(400);
    expect((await callFn(request, 'platform', sa.token, { action: 'explode' })).status).toBe(400);
  });
});

test.describe('AC-5 edit tenant', () => {
  test('changes name, timezone and plan label with before/after audit', async ({ request }) => {
    const t = await newTenant(request);
    const newName = tenantNameOf();
    const request_id = uuid();
    const r = await callFn(request, 'platform', sa.token, { action: 'tenant_update', request_id, tenant_id: t.id, name: newName, timezone: 'Asia/Singapore', plan_label: 'active' });
    expect(r.status).toBe(200);
    expect((await service().from('tenant').select('name, timezone, plan_label').eq('id', t.id).single()).data).toEqual({ name: newName, timezone: 'Asia/Singapore', plan_label: 'active' });
    const e = (await auditRows({ action: 'tenant.updated', entity: t.id }))[0];
    expect(e.before).toMatchObject({ name: t.name, plan_label: 'trial' });
    expect(e.after).toMatchObject({ name: newName, plan_label: 'active' });
    expect((await callFn(request, 'platform', sa.token, { action: 'tenant_update', request_id, tenant_id: t.id, name: newName })).status).toBe(200);
    expect(await auditRows({ action: 'tenant.updated', entity: t.id })).toHaveLength(1);
    const other = await newTenant(request);
    const clash = await callFn(request, 'platform', sa.token, { action: 'tenant_update', request_id: uuid(), tenant_id: other.id, name: newName });
    expect(clash.status).toBe(409);
    const missing = await callFn(request, 'platform', sa.token, { action: 'tenant_update', request_id: uuid(), tenant_id: uuid(), name: 'x' });
    expect(missing.status).toBe(422);
  });
});

test.describe('AC-6 suspend and activate', () => {
  test('suspension blocks the tenant\'s users on their next request, activation restores them, sessions are kept', async ({ request }) => {
    const t = await newTenant(request);
    const ua = await newUnitAdmin(request, t.id);
    const { session } = await activate(request, ua.phone, ua.tempPassword);
    expect((await session.client.from('tenant').select('id')).data).toHaveLength(1);

    const noReason = await callFn(request, 'platform', sa.token, { action: 'tenant_set_status', request_id: uuid(), tenant_id: t.id, status: 'suspended' });
    expect(noReason.status).toBe(400);
    expect(noReason.body.field).toBe('reason');
    const request_id = uuid();
    const sus = await callFn(request, 'platform', sa.token, { action: 'tenant_set_status', request_id, tenant_id: t.id, status: 'suspended', reason: 'Unpaid invoice' });
    expect(sus.status).toBe(200);
    const events = await auditRows({ action: 'tenant.suspended', entity: t.id });
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ reason: 'Unpaid invoice', tenant_id: t.id, actor_role: 'platform_admin' });

    // Same token, next request: no tenant data and no write RPCs (the access token is still valid: suspension is not a credential change).
    expect((await session.client.from('tenant').select('id')).data).toEqual([]);
    expect((await session.client.from('audit_event').select('id')).data).toEqual([]);
    const blocked = await callFn(request, 'user-admin', session.token, { action: 'create', request_id: uuid(), full_name: 'X', employee_id: throwawayEmpId(), phone: throwawayPhone(), role: 'supervisor' });
    expect(blocked.status).toBe(403);
    expect((await callFn(request, 'platform', sa.token, { action: 'tenant_set_status', request_id, tenant_id: t.id, status: 'suspended', reason: 'Unpaid invoice' })).status).toBe(200);
    expect(await auditRows({ action: 'tenant.suspended', entity: t.id })).toHaveLength(1);

    const act = await callFn(request, 'platform', sa.token, { action: 'tenant_set_status', request_id: uuid(), tenant_id: t.id, status: 'active' });
    expect(act.status).toBe(200);
    expect((await session.client.from('tenant').select('id')).data).toHaveLength(1);
    expect(await auditRows({ action: 'tenant.activated', entity: t.id })).toHaveLength(1);
    expect((await service().from('tenant').select('suspended_reason').eq('id', t.id).single()).data).toEqual({ suspended_reason: null });
  });

  test('an SA can still create a Unit Admin for a suspended tenant', async ({ request }) => {
    const t = await newTenant(request);
    await callFn(request, 'platform', sa.token, { action: 'tenant_set_status', request_id: uuid(), tenant_id: t.id, status: 'suspended', reason: 'Paused' });
    const ua = await newUnitAdmin(request, t.id);
    expect((await membershipOf(ua.userId))!.tenant_id).toBe(t.id);
  });
});

test.describe('AC-8 create Unit Admin', () => {
  test('creates an active Unit Admin with a once-shown temporary password; audited under the tenant', async ({ request }) => {
    const t = await newTenant(request);
    const phone = throwawayPhone();
    const request_id = uuid();
    const employee_id = throwawayEmpId();
    const r = await callFn(request, 'platform', sa.token, { action: 'ua_create', request_id, tenant_id: t.id, full_name: ' Meera Nair ', employee_id, phone, role: 'supervisor' });
    expect(r.status).toBe(200);
    created.push(r.body.user_id);
    expect(r.body.temp_password).toMatch(/^[A-HJ-NP-Za-km-z2-9]{12}$/);
    expect(Object.keys(r.body).sort()).toEqual(['temp_password', 'user_id']);
    const m = await membershipOf(r.body.user_id);
    expect(m).toMatchObject({ tenant_id: t.id, role: 'unit_admin', status: 'active', full_name: 'Meera Nair', must_change_password: true, created_by: saId }); // a role in the body is ignored
    const e = (await auditRows({ action: 'user.created', entity: r.body.user_id }))[0];
    expect(e).toMatchObject({ tenant_id: t.id, actor_user_id: saId, actor_role: 'platform_admin', request_id });
    expect(e.after.phone).toBe(`+91******${phone.slice(-4)}`);
    expect(JSON.stringify(e)).not.toContain(phone);
    expect(JSON.stringify(e)).not.toContain(r.body.temp_password);

    const again = await callFn(request, 'platform', sa.token, { action: 'ua_create', request_id, tenant_id: t.id, full_name: 'Meera Nair', employee_id, phone });
    expect(again.body).toMatchObject({ already: true, user_id: r.body.user_id, message: 'Already done — reset the password if it was lost' });
    expect(again.body.temp_password).toBeUndefined();

    // 02's gate: with the temporary password the new Unit Admin sees only their own membership row, no tenant data.
    const s = await signIn(phone, r.body.temp_password);
    expect((await s.client.from('membership').select('must_change_password')).data).toEqual([{ must_change_password: true }]);
    expect((await s.client.from('tenant').select('id')).data).toEqual([]);
  });

  test('duplicates, validation and unknown tenant', async ({ request }) => {
    const t = await newTenant(request);
    const ua = await newUnitAdmin(request, t.id);
    const base = () => ({ action: 'ua_create', request_id: uuid(), tenant_id: t.id, full_name: 'Valid', employee_id: throwawayEmpId(), phone: throwawayPhone() });
    const dupPhone = await callFn(request, 'platform', sa.token, { ...base(), phone: ua.phone });
    expect(dupPhone.status).toBe(409);
    expect(dupPhone.body).toEqual({ field: 'phone', message: 'This phone number is already registered' });
    const dupSa = await callFn(request, 'platform', sa.token, { ...base(), phone: SA_FIXTURES.sa2.phone });
    expect(dupSa.status).toBe(409);
    expect(dupSa.body.field).toBe('phone');
    const dupEmp = await callFn(request, 'platform', sa.token, { ...base(), employee_id: (await membershipOf(ua.userId))!.employee_id.toLowerCase() });
    expect(dupEmp.status).toBe(409);
    expect(dupEmp.body.field).toBe('employee_id');
    for (const [patch, field] of [[{ phone: '5876543210' }, 'phone'], [{ full_name: '  ' }, 'full_name'], [{ employee_id: 'bad id!' }, 'employee_id']] as const) {
      const r = await callFn(request, 'platform', sa.token, { ...base(), ...patch });
      expect(r.status, JSON.stringify(patch)).toBe(400);
      expect(r.body.field).toBe(field);
    }
    expect((await callFn(request, 'platform', sa.token, { ...base(), tenant_id: uuid() })).status).toBe(422);
  });

  test('racing creates with one phone: one wins, the others 409 and leave no Auth user', async ({ request }) => {
    const t = await newTenant(request);
    const phone = throwawayPhone();
    const results = await Promise.all([1, 2, 3].map(() => callFn(request, 'platform', sa.token, {
      action: 'ua_create', request_id: uuid(), tenant_id: t.id, full_name: 'Racer', employee_id: throwawayEmpId(), phone,
    })));
    const ok = results.filter((r) => r.status === 200);
    for (const r of ok) await service().auth.admin.deleteUser(r.body.user_id);
    expect(ok).toHaveLength(1);
    for (const r of results.filter((x) => x.status !== 200)) {
      expect(r.status).toBe(409);
      expect(r.body.field).toBe('phone');
    }
    expect(await authUserExists(phone)).toBe(false);
  });

  test('racing creates with one employee id in a tenant: compensation leaves no orphan Auth users', async ({ request }) => {
    const t = await newTenant(request);
    const employee_id = throwawayEmpId();
    const phones = [throwawayPhone(), throwawayPhone(), throwawayPhone()];
    const results = await Promise.all(phones.map((phone) => callFn(request, 'platform', sa.token, {
      action: 'ua_create', request_id: uuid(), tenant_id: t.id, full_name: 'Racer', employee_id, phone,
    })));
    const ok = results.filter((r) => r.status === 200);
    for (const r of ok) await service().auth.admin.deleteUser(r.body.user_id);
    expect(ok).toHaveLength(1);
    for (const r of results.filter((x) => x.status !== 200)) expect([409]).toContain(r.status);
    for (const p of phones) expect(await authUserExists(p)).toBe(false);
  });
});

test.describe('AC-9 reset Unit Admin password', () => {
  test('shows a new temporary password once, ends sessions, forces a change, audits under the tenant', async ({ request }) => {
    const t = await newTenant(request);
    const ua = await newUnitAdmin(request, t.id);
    const { session, password } = await activate(request, ua.phone, ua.tempPassword);
    const request_id = uuid();
    const r = await callFn(request, 'platform', sa.token, { action: 'ua_reset_password', request_id, user_id: ua.userId });
    expect(r.status).toBe(200);
    expect(r.body.temp_password).toMatch(/^[A-HJ-NP-Za-km-z2-9]{12}$/);
    expect(await signInFails(ua.phone, password)).toBe(true);
    const { error } = await anon().auth.refreshSession({ refresh_token: session.refreshToken });
    expect(error).not.toBeNull();
    expect(await membershipOf(ua.userId)).toMatchObject({ must_change_password: true });
    const e = (await auditRows({ action: 'user.password_reset', entity: ua.userId }))[0];
    expect(e).toMatchObject({ tenant_id: t.id, actor_user_id: saId, actor_role: 'platform_admin' });
    expect(JSON.stringify(e)).not.toContain(r.body.temp_password);
    const again = await callFn(request, 'platform', sa.token, { action: 'ua_reset_password', request_id, user_id: ua.userId });
    expect(again.body.already).toBe(true);
    expect(again.body.temp_password).toBeUndefined();
    const s = await signIn(ua.phone, r.body.temp_password);
    expect(s.userId).toBe(ua.userId);
  });

  test('refuses a supervisor and an unknown user (403, audited), changing nothing', async ({ request }) => {
    const t = await newTenant(request);
    const ua = await newUnitAdmin(request, t.id);
    const { session } = await activate(request, ua.phone, ua.tempPassword);
    const sup = await makeActiveUser(request, session.token, 'supervisor');
    const r = await callFn(request, 'platform', sa.token, { action: 'ua_reset_password', request_id: uuid(), user_id: sup.userId });
    expect(r.status).toBe(403);
    expect(r.body).toMatchObject({ code: 'not_allowed' });
    expect(r.body.temp_password).toBeUndefined();
    expect(await signInFails(sup.phone, sup.password)).toBe(false);
    expect(await membershipOf(sup.userId)).toMatchObject({ must_change_password: false });
    const denied = await auditRows({ action: 'access.denied', entity: sup.userId });
    expect(denied.at(-1)).toMatchObject({ reason: 'target_not_unit_admin', tenant_id: t.id, actor_role: 'platform_admin' });
    expect((await callFn(request, 'platform', sa.token, { action: 'ua_reset_password', request_id: uuid(), user_id: uuid() })).status).toBe(403);
  });
});

test.describe('AC-3 Super Admins', () => {
  test('create, first sign-in, own password change, deactivate, reactivate, reset; guards; audit', async ({ request }) => {
    const phone = throwawayPhone();
    const request_id = uuid();
    const r = await callFn(request, 'platform', sa.token, { action: 'sa_create', request_id, full_name: ' Second Admin ', phone });
    expect(r.status).toBe(200);
    created.push(r.body.user_id);
    expect(r.body.temp_password).toMatch(/^[A-HJ-NP-Za-km-z2-9]{12}$/);
    expect((await callFn(request, 'platform', sa.token, { action: 'sa_create', request_id, full_name: 'Second Admin', phone })).body).toMatchObject({ already: true, user_id: r.body.user_id });
    const ev = (await auditRows({ action: 'platform_admin.created', entity: r.body.user_id }))[0];
    expect(ev).toMatchObject({ tenant_id: null, actor_user_id: saId, actor_role: 'platform_admin' });
    expect(ev.after.phone).toBe(`+91******${phone.slice(-4)}`);

    // Temporary password: signed in but gated; the platform function refuses until the password is changed (D5, account function).
    const first = await signIn(phone, r.body.temp_password);
    const gated = await callFn(request, 'platform', first.token, { action: 'tenant_create', request_id: uuid(), name: tenantNameOf() });
    expect(gated.status).toBe(403);
    expect((await first.client.from('tenant').select('id')).data).toEqual([]);
    expect((await first.client.from('platform_admin').select('must_change_password')).data).toEqual([{ must_change_password: true }]);
    const wrong = await callFn(request, 'account', first.token, { action: 'change_password', current_password: 'Wrong-pass-123', new_password: 'Brand-new-pass-1' });
    expect(wrong.status).toBe(403);
    expect(wrong.body.field).toBe('current_password');
    const ch = await callFn(request, 'account', first.token, { action: 'change_password', current_password: r.body.temp_password, new_password: 'Brand-new-pass-1' });
    expect(ch.status).toBe(200);
    expect(await membershipOf(r.body.user_id)).toBeNull();
    expect((await service().from('platform_admin').select('must_change_password').eq('user_id', r.body.user_id).single()).data).toEqual({ must_change_password: false });
    expect(await auditRows({ action: 'platform_admin.password_changed', entity: r.body.user_id })).toHaveLength(1);
    const second = await signIn(phone, 'Brand-new-pass-1');
    expect((await callFn(request, 'platform', second.token, { action: 'tenant_create', request_id: uuid(), name: tenantNameOf() })).status).toBe(200);
    expect((await second.client.from('tenant').select('id')).data!.length).toBeGreaterThan(0);

    // Guards: no self deactivate / reset.
    for (const action of ['sa_set_status', 'sa_reset_password']) {
      const self = await callFn(request, 'platform', second.token, { action, request_id: uuid(), user_id: r.body.user_id, status: 'inactive' });
      expect(self.status, action).toBe(422);
      expect(self.body.field).toBe('self');
    }
    // Deactivate -> Auth ban + sessions ended; reactivate -> sign-in works again.
    const off = await callFn(request, 'platform', sa.token, { action: 'sa_set_status', request_id: uuid(), user_id: r.body.user_id, status: 'inactive' });
    expect(off.status).toBe(200);
    expect(await signInFails(phone, 'Brand-new-pass-1')).toBe(true);
    expect((await anon().auth.refreshSession({ refresh_token: second.refreshToken })).error).not.toBeNull();
    // The ban ends the Auth session, so the old token is refused at the gateway (401); a still-valid token would be refused by the server (403).
    expect([401, 403]).toContain((await callFn(request, 'platform', second.token, { action: 'tenant_create', request_id: uuid(), name: tenantNameOf() })).status);
    expect((await callFn(request, 'platform', sa.token, { action: 'sa_reset_password', request_id: uuid(), user_id: r.body.user_id })).status).toBe(422);
    const on = await callFn(request, 'platform', sa.token, { action: 'sa_set_status', request_id: uuid(), user_id: r.body.user_id, status: 'active' });
    expect(on.status).toBe(200);
    expect(await signInFails(phone, 'Brand-new-pass-1')).toBe(false);
    expect(await auditRows({ action: 'platform_admin.deactivated', entity: r.body.user_id })).toHaveLength(1);
    expect(await auditRows({ action: 'platform_admin.reactivated', entity: r.body.user_id })).toHaveLength(1);

    const reset = await callFn(request, 'platform', sa.token, { action: 'sa_reset_password', request_id: uuid(), user_id: r.body.user_id });
    expect(reset.status).toBe(200);
    expect(await signInFails(phone, 'Brand-new-pass-1')).toBe(true);
    expect((await signIn(phone, reset.body.temp_password)).userId).toBe(r.body.user_id);
    expect(await auditRows({ action: 'platform_admin.password_reset', entity: r.body.user_id })).toHaveLength(1);
  });

  test('duplicate and invalid input', async ({ request }) => {
    const dupSa = await callFn(request, 'platform', sa.token, { action: 'sa_create', request_id: uuid(), full_name: 'Dup', phone: SA_FIXTURES.sa2.phone });
    expect(dupSa.status).toBe(409);
    const dupMember = await callFn(request, 'platform', sa.token, { action: 'sa_create', request_id: uuid(), full_name: 'Dup', phone: org.users.ua1.phone });
    expect(dupMember.status).toBe(409);
    expect(dupMember.body).toEqual({ field: 'phone', message: 'This phone number is already registered' });
    expect((await callFn(request, 'platform', sa.token, { action: 'sa_create', request_id: uuid(), full_name: '', phone: throwawayPhone() })).status).toBe(400);
    expect((await callFn(request, 'platform', sa.token, { action: 'sa_set_status', request_id: uuid(), user_id: uuid(), status: 'inactive' })).status).toBe(422);
  });
});

test.describe('AC-14 role checks', () => {
  test('a Unit Admin and a supervisor calling any platform action get a generic 403 and an audit row', async ({ request }) => {
    const ua = await signIn(org.users.ua1.phone, FIXTURE_PASSWORD);
    const sup = await signIn(org.users.sup.phone, FIXTURE_PASSWORD);
    const actions: Record<string, unknown>[] = [
      { action: 'tenant_create', name: tenantNameOf() },
      { action: 'tenant_update', tenant_id: org.id, name: 'hacked' },
      { action: 'tenant_set_status', tenant_id: org.id, status: 'suspended', reason: 'x' },
      { action: 'ua_create', tenant_id: org.id, full_name: 'X', employee_id: throwawayEmpId(), phone: throwawayPhone() },
      { action: 'ua_reset_password', user_id: org.users.ua2.id },
      { action: 'sa_create', full_name: 'X', phone: throwawayPhone() },
      { action: 'sa_set_status', user_id: saId, status: 'inactive' },
      { action: 'sa_reset_password', user_id: saId },
    ];
    for (const [who, s] of [['ua', ua], ['sup', sup]] as const) {
      for (const a of actions) {
        const r = await callFn(request, 'platform', s.token, { request_id: uuid(), ...a });
        expect(r.status, `${who} ${a.action}`).toBe(403);
        expect(r.body).toEqual({ code: 'not_allowed', message: 'Not allowed' });
      }
      const denied = await auditRows({ action: 'access.denied', actor: s.userId, reason: 'not_platform_admin' });
      expect(denied.length, who).toBeGreaterThanOrEqual(actions.length);
      expect(denied[0]).toMatchObject({ tenant_id: org.id, source: 'edge:platform' });
    }
    expect((await service().from('tenant').select('name').eq('id', org.id).single()).data!.name).toBe(org.name);
    expect((await callFn(request, 'platform', null, { action: 'tenant_create', request_id: uuid(), name: 'x' })).status).toBe(401);
  });

  test('N-2: a Unit Admin gets the generic 403 and an audit row even for malformed or unknown requests', async ({ request }) => {
    const ua = await signIn(org.users.ua1.phone, FIXTURE_PASSWORD);
    const before = (await auditRows({ action: 'access.denied', actor: ua.userId, reason: 'not_platform_admin' })).length;
    const bodies: Record<string, unknown>[] = [
      { action: 'tenant_create' }, // no request id, no name
      { action: 'ua_create', request_id: 'not-a-uuid' },
      { action: 'no_such_action', request_id: uuid() },
      { request_id: uuid() },
    ];
    for (const b of bodies) {
      const r = await callFn(request, 'platform', ua.token, b);
      expect(r.status, JSON.stringify(b)).toBe(403);
      expect(r.body).toEqual({ code: 'not_allowed', message: 'Not allowed' });
    }
    expect((await auditRows({ action: 'access.denied', actor: ua.userId, reason: 'not_platform_admin' })).length).toBe(before + bodies.length);
  });
});

test.describe('AC-11 / AC-12 / AC-13 boundary and audit visibility', () => {
  test('an SA reads tenants but no membership, audit or other operational rows, and cannot use 02\'s write paths', async ({ request }) => {
    expect((await sa.client.from('tenant').select('id')).data!.length).toBeGreaterThan(0);
    expect((await sa.client.from('membership').select('user_id')).data).toEqual([]);
    expect((await sa.client.from('audit_event').select('id')).data).toEqual([]);
    expect((await sa.client.from('platform_admin').select('user_id')).data).toHaveLength(1);
    const r = await callFn(request, 'user-admin', sa.token, { action: 'create', request_id: uuid(), full_name: 'X', employee_id: throwawayEmpId(), phone: throwawayPhone(), role: 'supervisor' });
    expect(r.status).toBe(403);
    const d = (await auditRows({ action: 'access.denied', actor: saId, reason: 'platform_admin' })).at(-1)!;
    expect(d).toMatchObject({ actor_role: 'platform_admin', source: 'edge:user-admin' });
    expect((await sa.client.from('tenant').update({ name: 'x' }).eq('id', org.id)).error).not.toBeNull();
  });

  test('platform audit lists SA events with tenant names, 50 a page, newest first; tenant users see none of it through pa_audit', async ({ request }) => {
    const t = await newTenant(request);
    const { data, error } = await sa.client.rpc('pa_audit', { p_page: 0 });
    expect(error).toBeNull();
    expect(data.length).toBeLessThanOrEqual(50);
    const mine = data.find((e: any) => e.action === 'tenant.created' && e.tenant_id === t.id);
    expect(mine).toMatchObject({ tenant_name: t.name, actor_name: SA_FIXTURES.sa1.name, source: 'edge:platform' });
    const times = data.map((e: any) => new Date(e.occurred_at).getTime());
    expect([...times].sort((a, b) => b - a)).toEqual(times);
    expect(data.some((e: any) => e.action === 'user.deactivated')).toBe(false);

    const ua = await signIn(org.users.ua1.phone, FIXTURE_PASSWORD);
    expect((await ua.client.rpc('pa_audit', { p_page: 0 })).data).toEqual([]);
    expect((await ua.client.rpc('pa_tenant_summaries', {})).data).toEqual([]);
    expect((await ua.client.rpc('pa_tenant_unit_admins', { p_tenant: org.id })).data).toEqual([]);
    expect((await ua.client.rpc('pa_super_admins', {})).data).toEqual([]);
    expect((await anon().rpc('pa_audit', { p_page: 0 })).error).not.toBeNull();
    expect(await auditRows({ action: 'access.denied', actor: ua.userId, reason: 'not_platform_admin' })).not.toHaveLength(0);
  });

  test('a Unit Admin sees platform actions on their own tenant in their audit rows (AC-13)', async ({ request }) => {
    const t = await newTenant(request);
    const ua = await newUnitAdmin(request, t.id);
    const { session } = await activate(request, ua.phone, ua.tempPassword);
    await callFn(request, 'platform', sa.token, { action: 'tenant_update', request_id: uuid(), tenant_id: t.id, plan_label: 'active' });
    const rows = (await session.client.from('audit_event').select('action, actor_role, tenant_id')).data!;
    for (const action of ['tenant.created', 'user.created', 'tenant.updated']) {
      expect(rows.find((e) => e.action === action), action).toMatchObject({ actor_role: 'platform_admin', tenant_id: t.id });
    }
    await callFn(request, 'platform', sa.token, { action: 'tenant_set_status', request_id: uuid(), tenant_id: t.id, status: 'suspended', reason: 'Check' });
    await callFn(request, 'platform', sa.token, { action: 'tenant_set_status', request_id: uuid(), tenant_id: t.id, status: 'active' });
    const later = (await session.client.from('audit_event').select('action').in('action', ['tenant.suspended', 'tenant.activated'])).data!;
    expect(later.map((e) => e.action).sort()).toEqual(['tenant.activated', 'tenant.suspended']);
  });
});

test.describe('read functions (AC-7, AC-10)', () => {
  test('tenant summaries: search, filters, 25 a page, counts; Unit Admin list masks phones and hides supervisors', async ({ request }) => {
    const t = await newTenant(request, { plan_label: 'active' });
    const ua = await newUnitAdmin(request, t.id);
    const { session } = await activate(request, ua.phone, ua.tempPassword);
    const sup = await makeActiveUser(request, session.token, 'supervisor');
    void sup;
    const found = (await sa.client.rpc('pa_tenant_summaries', { p_search: t.name.slice(0, 12).toUpperCase() })).data as any[];
    const row = found.find((x) => x.id === t.id)!;
    expect(row).toMatchObject({ name: t.name, status: 'active', plan_label: 'active', active_users: 2, active_unit_admins: 1 });
    expect(typeof row.created_at).toBe('string');
    expect(((await sa.client.rpc('pa_tenant_summaries', { p_search: t.name, p_status: 'suspended' })).data as any[])).toHaveLength(0);
    expect(((await sa.client.rpc('pa_tenant_summaries', { p_search: t.name, p_plan: 'trial' })).data as any[])).toHaveLength(0);
    expect(((await sa.client.rpc('pa_tenant_summaries', { p_search: '%' })).data as any[])).toHaveLength(0);
    const page0 = (await sa.client.rpc('pa_tenant_summaries', { p_page: 0 })).data as any[];
    expect(page0.length).toBeLessThanOrEqual(25);
    expect(Number(page0[0].total_count)).toBeGreaterThanOrEqual(page0.length);

    const admins = (await sa.client.rpc('pa_tenant_unit_admins', { p_tenant: t.id })).data as any[];
    expect(admins).toHaveLength(1);
    expect(admins[0]).toEqual({ user_id: ua.userId, full_name: 'First Admin', phone_masked: `+91******${ua.phone.slice(-4)}`, status: 'active', must_change_password: false });
    const sas = (await sa.client.rpc('pa_super_admins', {})).data as any[];
    expect(sas.find((x) => x.user_id === saId)).toMatchObject({ is_self: true, status: 'active' });
  });
});
