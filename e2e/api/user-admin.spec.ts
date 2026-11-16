// 02 AC-1, 2, 5, 6, 7, 8, 15(local) through the user-admin Edge Function on org U (own org: "e2e org U", users U1-U4).
// Also asserts every Supabase Auth behaviour the design relies on (admin createUser with sign-up disabled, ban blocks
// sign-in and refresh, email change applies immediately).
import { expect, test } from '@playwright/test';
import {
  anon, auditRows, authUserExists, callFn, cleanupCreated, createUserVia, makeActiveUser, membershipOf, orgDef,
  phoneToAuthEmail, provisionOrg, requireApi, service, signIn, signInFails, throwawayEmpId, throwawayPhone, uuid, FIXTURE_PASSWORD, type Session,
} from './helpers';

const org = orgDef(1, 'e2e org U');
const other = orgDef(5, 'e2e org U-other'); // supplies a phone that belongs to a different tenant
let ua1: Session;
let ua2: Session;

test.beforeAll(async () => {
  requireApi();
  await provisionOrg(org);
  await provisionOrg(other);
  ua1 = await signIn(org.users.ua1.phone, FIXTURE_PASSWORD);
  ua2 = await signIn(org.users.ua2.phone, FIXTURE_PASSWORD);
});
test.afterAll(async () => {
  await cleanupCreated();
});

test.describe('AC-1 create', () => {
  test('creates an active member with a once-shown temporary password and a forced change', async ({ request }) => {
    const { res, phone } = await createUserVia(request, ua1.token, { full_name: '  Meera Nair ', role: 'supervisor' });
    expect(res.status).toBe(200);
    expect(res.body.temp_password).toMatch(/^[A-HJ-NP-Za-km-z2-9]{12}$/);
    expect(Object.keys(res.body).sort()).toEqual(['temp_password', 'user_id']);

    const m = await membershipOf(res.body.user_id);
    expect(m).toMatchObject({ tenant_id: org.id, role: 'supervisor', status: 'active', full_name: 'Meera Nair', must_change_password: true, created_by: ua1.userId });
    expect(new Date(m!.temp_password_expires_at).getTime()).toBeGreaterThan(Date.now() + 23 * 3600_000);

    const events = await auditRows({ action: 'user.created', entity: res.body.user_id });
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ tenant_id: org.id, actor_user_id: ua1.userId, source: 'edge:user-admin' });
    expect(events[0].after.phone).toBe(`+91******${phone.slice(-4)}`);
    expect(JSON.stringify(events[0])).not.toContain(phone);
    expect(JSON.stringify(events[0])).not.toContain(res.body.temp_password);

    // AC-3 gate (server-enforced): the new user can sign in but sees only their own membership row, no tenant data.
    const s = await signIn(phone, res.body.temp_password);
    const own = await s.client.from('membership').select('must_change_password');
    expect(own.data).toEqual([{ must_change_password: true }]);
    expect((await s.client.from('tenant').select('id')).data).toEqual([]);
    expect((await s.client.from('audit_event').select('id')).data).toEqual([]);
  });

  test('a retry with the same request id does not create a second user and never repeats the password', async ({ request }) => {
    const request_id = uuid();
    const phone = throwawayPhone();
    const employee_id = throwawayEmpId();
    const body = { action: 'create', request_id, full_name: 'Retry User', employee_id, phone, role: 'supervisor' };
    const first = await callFn(request, 'user-admin', ua1.token, body);
    expect(first.status).toBe(200);
    const second = await callFn(request, 'user-admin', ua1.token, body);
    expect(second.status).toBe(200);
    expect(second.body).toMatchObject({ already: true, user_id: first.body.user_id, message: 'Already done — reset the password if it was lost' });
    expect(second.body.temp_password).toBeUndefined();
    const { count } = await service().from('membership').select('*', { count: 'exact', head: true }).eq('phone_e164', phone);
    expect(count).toBe(1);
    expect(await auditRows({ action: 'user.created', requestId: request_id })).toHaveLength(1);
    await service().auth.admin.deleteUser(first.body.user_id);
  });

  test('Auth assumption: public sign-up is disabled but admin createUser works (AC-15, local)', async () => {
    const { error } = await anon().auth.signUp({ email: phoneToAuthEmail(throwawayPhone()), password: 'Sign-up-12345' });
    expect(error).not.toBeNull();
  });
});

test.describe('AC-2 validation and duplicates', () => {
  const base = () => ({ action: 'create', request_id: uuid(), full_name: 'Valid Name', employee_id: throwawayEmpId(), phone: throwawayPhone(), role: 'supervisor' });

  test('invalid phone, name, employee id, role -> 400 with the field', async ({ request }) => {
    for (const [patch, field] of [
      [{ phone: '5876543210' }, 'phone'],
      [{ full_name: '   ' }, 'full_name'],
      [{ full_name: 'n'.repeat(81) }, 'full_name'],
      [{ employee_id: 'bad id!' }, 'employee_id'],
      [{ role: 'maintenance' }, 'role'],
    ] as const) {
      const r = await callFn(request, 'user-admin', ua1.token, { ...base(), ...patch });
      expect(r.status, JSON.stringify(patch)).toBe(400);
      expect(r.body.field).toBe(field);
      expect(typeof r.body.message).toBe('string');
    }
  });

  test('phone formats with spaces, a leading 0 or +91 are accepted and normalised', async ({ request }) => {
    const phone = throwawayPhone();
    const digits = phone.slice(3);
    const { res } = await createUserVia(request, ua1.token, { phone: `0${digits.slice(0, 5)} ${digits.slice(5)}` });
    expect(res.status).toBe(200);
    expect((await membershipOf(res.body.user_id))!.phone_e164).toBe(phone);
  });

  test('duplicate phone -> 409 with the neutral message, even for a phone of another tenant', async ({ request }) => {
    const a = await createUserVia(request, ua1.token);
    expect(a.res.status).toBe(200);
    const dup = await createUserVia(request, ua1.token, { phone: a.phone });
    expect(dup.res.status).toBe(409);
    expect(dup.res.body).toEqual({ field: 'phone', message: 'This phone number is already registered' });
    // A phone that belongs to another tenant is refused the same way and the message never names the tenant.
    const cross = await createUserVia(request, ua1.token, { phone: other.users.ua1.phone });
    expect(cross.res.status).toBe(409);
    expect(cross.res.body).toEqual({ field: 'phone', message: 'This phone number is already registered' });
  });

  test('duplicate employee id (case-insensitive) -> 409', async ({ request }) => {
    const a = await createUserVia(request, ua1.token, { employee_id: 'Dup-Case-1' });
    expect(a.res.status).toBe(200);
    const b = await createUserVia(request, ua1.token, { employee_id: 'dup-case-1' });
    expect(b.res.status).toBe(409);
    expect(b.res.body.field).toBe('employee_id');
  });

  test('request without a valid JWT -> 401; unknown action -> 400', async ({ request }) => {
    expect((await callFn(request, 'user-admin', null, base())).status).toBe(401);
    expect((await callFn(request, 'user-admin', 'not-a-jwt', base())).status).toBe(401);
    const r = await callFn(request, 'user-admin', ua1.token, { action: 'explode', request_id: uuid() });
    expect(r.status).toBe(400);
  });
});

test.describe('compensation: no orphan Auth users when the database refuses', () => {
  test('racing creates with one employee id: one wins, the others get 409 and leave no Auth user', async ({ request }) => {
    const employee_id = throwawayEmpId();
    const phones = [throwawayPhone(), throwawayPhone(), throwawayPhone()];
    const results = await Promise.all(phones.map((phone) => callFn(request, 'user-admin', ua1.token, {
      action: 'create', request_id: uuid(), full_name: 'Racer', employee_id, phone, role: 'supervisor',
    })));
    const ok = results.filter((r) => r.status === 200);
    const lost = results.filter((r) => r.status !== 200);
    for (const r of ok) await service().auth.admin.deleteUser(r.body.user_id);
    expect(ok).toHaveLength(1);
    for (const r of lost) {
      expect(r.status).toBe(409);
      expect(r.body.field).toBe('employee_id');
    }
    for (let i = 0; i < phones.length; i++) {
      const won = results[i].status === 200;
      // the winner's user was just deleted by this test; losers must never have had one left behind
      expect(await authUserExists(phones[i]), `phone ${i}`).toBe(false);
      void won;
    }
  });

  test('racing creates with one phone: one wins, the others 409 on phone', async ({ request }) => {
    const phone = throwawayPhone();
    const results = await Promise.all([1, 2, 3].map(() => callFn(request, 'user-admin', ua1.token, {
      action: 'create', request_id: uuid(), full_name: 'Racer', employee_id: throwawayEmpId(), phone, role: 'supervisor',
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
});

test.describe('AC-5 reset password', () => {
  test('a reset shows a new temporary password once, gates existing sessions at once, and is audited', async ({ request }) => {
    const u = await makeActiveUser(request, ua1.token);
    const old = await signIn(u.phone, u.password);
    expect((await old.client.from('tenant').select('id')).data).toHaveLength(1); // has data access before the reset

    const request_id = uuid();
    const r = await callFn(request, 'user-admin', ua1.token, { action: 'reset_password', request_id, user_id: u.userId });
    expect(r.status).toBe(200);
    expect(r.body.temp_password).toMatch(/^[A-HJ-NP-Za-km-z2-9]{12}$/);

    // the already-issued session loses data access immediately (AC-3 gate)
    expect((await old.client.from('tenant').select('id')).data).toEqual([]);
    const m = await membershipOf(u.userId);
    expect(m!.must_change_password).toBe(true);
    expect(new Date(m!.temp_password_expires_at).getTime()).toBeGreaterThan(Date.now() + 23 * 3600_000);

    // old password no longer works, the temporary one does
    expect(await signInFails(u.phone, u.password)).toBe(true);
    await signIn(u.phone, r.body.temp_password);

    const events = await auditRows({ action: 'user.password_reset', entity: u.userId });
    expect(events).toHaveLength(1);
    expect(JSON.stringify(events[0])).not.toContain(r.body.temp_password);

    const again = await callFn(request, 'user-admin', ua1.token, { action: 'reset_password', request_id, user_id: u.userId });
    expect(again.status).toBe(200);
    expect(again.body).toMatchObject({ already: true });
    expect(again.body.temp_password).toBeUndefined();
  });

  test('a UA cannot reset themself (422) and cannot reset an inactive user (422)', async ({ request }) => {
    const self = await callFn(request, 'user-admin', ua1.token, { action: 'reset_password', request_id: uuid(), user_id: ua1.userId });
    expect(self.status).toBe(422);
    expect(self.body.field).toBe('self');
    const u = await makeActiveUser(request, ua1.token);
    expect((await callFn(request, 'user-admin', ua1.token, { action: 'set_status', request_id: uuid(), user_id: u.userId, status: 'inactive' })).status).toBe(200);
    const r = await callFn(request, 'user-admin', ua1.token, { action: 'reset_password', request_id: uuid(), user_id: u.userId });
    expect(r.status).toBe(422);
    expect(r.body.field).toBe('inactive');
  });
});

test.describe('AC-6 deactivate / reactivate', () => {
  test('deactivation cuts data access, refresh and sign-in; reactivation restores the same password', async ({ request }) => {
    const u = await makeActiveUser(request, ua1.token);
    const live = await signIn(u.phone, u.password);
    expect((await live.client.from('tenant').select('id')).data).toHaveLength(1);

    const off = await callFn(request, 'user-admin', ua1.token, { action: 'set_status', request_id: uuid(), user_id: u.userId, status: 'inactive' });
    expect(off.status).toBe(200);
    expect((await membershipOf(u.userId))!.status).toBe('inactive');
    // existing access token: no data on the next call
    expect((await live.client.from('tenant').select('id')).data).toEqual([]);
    // Auth assumption: a ban blocks the refresh token and password sign-in
    const refreshed = await anon().auth.refreshSession({ refresh_token: live.refreshToken });
    expect(refreshed.error, 'refresh must fail for a banned user').not.toBeNull();
    expect(await signInFails(u.phone, u.password)).toBe(true);
    expect(await auditRows({ action: 'user.deactivated', entity: u.userId })).toHaveLength(1);

    const on = await callFn(request, 'user-admin', ua1.token, { action: 'set_status', request_id: uuid(), user_id: u.userId, status: 'active' });
    expect(on.status).toBe(200);
    const back = await signIn(u.phone, u.password); // existing password still works
    expect((await back.client.from('tenant').select('id')).data).toHaveLength(1);
    expect(await auditRows({ action: 'user.reactivated', entity: u.userId })).toHaveLength(1);
  });

  test('a retried deactivation is idempotent; a UA cannot deactivate themself', async ({ request }) => {
    const u = await makeActiveUser(request, ua1.token);
    const request_id = uuid();
    const body = { action: 'set_status', request_id, user_id: u.userId, status: 'inactive' };
    expect((await callFn(request, 'user-admin', ua1.token, body)).status).toBe(200);
    expect((await callFn(request, 'user-admin', ua1.token, body)).status).toBe(200);
    expect(await auditRows({ action: 'user.deactivated', entity: u.userId })).toHaveLength(1);
    const self = await callFn(request, 'user-admin', ua1.token, { action: 'set_status', request_id: uuid(), user_id: ua1.userId, status: 'inactive' });
    expect(self.status).toBe(422);
    expect(self.body.field).toBe('self');
  });
});

test.describe('AC-7 edit', () => {
  test('a phone change takes effect at once: the new number signs in, the old one fails; audit is masked', async ({ request }) => {
    const u = await makeActiveUser(request, ua1.token);
    const newPhone = throwawayPhone();
    const r = await callFn(request, 'user-admin', ua1.token, {
      action: 'update', request_id: uuid(), user_id: u.userId, full_name: 'Renamed Person', employee_id: throwawayEmpId(), phone: newPhone,
    });
    expect(r.status).toBe(200);
    // Auth assumption: updateUserById(email) with email_confirm applies immediately
    await signIn(newPhone, u.password);
    expect(await signInFails(u.phone, u.password)).toBe(true);
    const m = await membershipOf(u.userId);
    expect(m).toMatchObject({ full_name: 'Renamed Person', phone_e164: newPhone });

    const events = await auditRows({ action: 'user.updated', entity: u.userId });
    expect(events).toHaveLength(1);
    expect(events[0].before.phone).toBe(`+91******${u.phone.slice(-4)}`);
    expect(events[0].after.phone).toBe(`+91******${newPhone.slice(-4)}`);
    expect(JSON.stringify(events[0])).not.toContain(newPhone);
    expect(JSON.stringify(events[0])).not.toContain(u.phone);
  });

  test('role change works; update to a used phone or employee id -> 409 and Auth email is untouched', async ({ request }) => {
    const a = await makeActiveUser(request, ua1.token);
    const b = await makeActiveUser(request, ua1.token);
    const up = await callFn(request, 'user-admin', ua1.token, { action: 'update', request_id: uuid(), user_id: a.userId, role: 'unit_admin' });
    expect(up.status).toBe(200);
    expect((await membershipOf(a.userId))!.role).toBe('unit_admin');
    const dupPhone = await callFn(request, 'user-admin', ua1.token, { action: 'update', request_id: uuid(), user_id: a.userId, phone: b.phone });
    expect(dupPhone.status).toBe(409);
    expect(dupPhone.body.field).toBe('phone');
    await signIn(a.phone, a.password); // still signs in with its own number
    const dupEmp = await callFn(request, 'user-admin', ua1.token, { action: 'update', request_id: uuid(), user_id: a.userId, employee_id: b.employeeId.toLowerCase() });
    expect(dupEmp.status).toBe(409);
    expect(dupEmp.body.field).toBe('employee_id');
  });

  test('update is idempotent for a repeated request id', async ({ request }) => {
    const u = await makeActiveUser(request, ua1.token);
    const body = { action: 'update', request_id: uuid(), user_id: u.userId, full_name: 'Twice Named' };
    expect((await callFn(request, 'user-admin', ua1.token, body)).status).toBe(200);
    expect((await callFn(request, 'user-admin', ua1.token, body)).status).toBe(200);
    expect(await auditRows({ action: 'user.updated', entity: u.userId })).toHaveLength(1);
  });
});

test.describe('AC-8 guards', () => {
  test('a UA cannot demote themself (422)', async ({ request }) => {
    const r = await callFn(request, 'user-admin', ua1.token, { action: 'update', request_id: uuid(), user_id: ua1.userId, role: 'supervisor' });
    expect(r.status).toBe(422);
    expect(r.body.field).toBe('self');
    expect((await membershipOf(ua1.userId))!.role).toBe('unit_admin');
  });

  test('two UAs demoting each other at the same time leave exactly one active Unit Admin', async ({ request }) => {
    try {
      const [a, b] = await Promise.all([
        callFn(request, 'user-admin', ua1.token, { action: 'update', request_id: uuid(), user_id: org.users.ua2.id, role: 'supervisor' }),
        callFn(request, 'user-admin', ua2.token, { action: 'update', request_id: uuid(), user_id: org.users.ua1.id, role: 'supervisor' }),
      ]);
      expect([a.status, b.status].sort()).toEqual([200, 403]);
      const { data } = await service().from('membership').select('user_id').eq('tenant_id', org.id).eq('role', 'unit_admin').eq('status', 'active');
      expect(data).toHaveLength(1);
    } finally {
      await service().from('membership').update({ role: 'unit_admin' }).in('user_id', [org.users.ua1.id, org.users.ua2.id]);
    }
  });
});
