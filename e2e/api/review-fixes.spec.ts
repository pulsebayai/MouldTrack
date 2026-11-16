// 02 review fixes (plan step 12a): R1 session revocation, R2 replay re-sync, R5 account pre-check + 403 codes, R6 create race.
// Own org "e2e api org 6". Tests run serially (api project is not fully parallel).
import { expect, test } from '@playwright/test';
import {
  FIXTURE_PASSWORD, anon, auditRows, callFn, cleanupCreated, createUserVia, makeActiveUser, orgDef, provisionOrg, requireApi, service, signIn, signInFails, uuid, type Session,
} from './helpers';

const org = orgDef(6, 'e2e api org 6');
let ua1: Session;

test.beforeAll(async () => {
  requireApi();
  await provisionOrg(org);
  ua1 = await signIn(org.users.ua1.phone, FIXTURE_PASSWORD);
});
test.afterAll(async () => {
  await cleanupCreated();
});

const refreshWorks = async (refreshToken: string) => {
  const { data, error } = await anon().auth.refreshSession({ refresh_token: refreshToken });
  return !error && !!data.session;
};
const NEW_PW = 'Review-fixes-2026';

test.describe('R1 sessions are revoked server-side', () => {
  test('changing the password ends every other session but keeps the caller\'s', async ({ request }) => {
    const { res, phone } = await createUserVia(request, ua1.token);
    expect(res.status).toBe(200);
    const temp = res.body.temp_password as string;
    const a = await signIn(phone, temp);
    const b = await signIn(phone, temp);
    const ch = await callFn(request, 'account', a.token, { action: 'change_password', current_password: temp, new_password: NEW_PW });
    expect(ch.status).toBe(200);
    expect(await refreshWorks(b.refreshToken), 'the other session must not refresh').toBe(false);
    expect(await refreshWorks(a.refreshToken), 'the caller\'s own session survives').toBe(true);
  });

  test('a reset ends every session of the user', async ({ request }) => {
    const u = await makeActiveUser(request, ua1.token);
    const a = await signIn(u.phone, u.password);
    const b = await signIn(u.phone, u.password);
    const r = await callFn(request, 'user-admin', ua1.token, { action: 'reset_password', request_id: uuid(), user_id: u.userId });
    expect(r.status).toBe(200);
    expect(await refreshWorks(a.refreshToken)).toBe(false);
    expect(await refreshWorks(b.refreshToken)).toBe(false);
  });

  test('after deactivate then reactivate the pre-ban refresh token still fails', async ({ request }) => {
    const u = await makeActiveUser(request, ua1.token);
    const s = await signIn(u.phone, u.password);
    expect((await callFn(request, 'user-admin', ua1.token, { action: 'set_status', request_id: uuid(), user_id: u.userId, status: 'inactive' })).status).toBe(200);
    expect((await callFn(request, 'user-admin', ua1.token, { action: 'set_status', request_id: uuid(), user_id: u.userId, status: 'active' })).status).toBe(200);
    expect(await refreshWorks(s.refreshToken)).toBe(false);
    await signIn(u.phone, u.password); // the password itself still works
  });
});

test.describe('R2 replay of a status change re-syncs the Auth ban', () => {
  test('a replayed deactivation bans again; a replayed reactivation lifts the ban again; revert rows are marked', async ({ request }) => {
    const u = await makeActiveUser(request, ua1.token);
    const off = uuid();
    const offBody = { action: 'set_status', request_id: off, user_id: u.userId, status: 'inactive' };
    expect((await callFn(request, 'user-admin', ua1.token, offBody)).status).toBe(200);
    await service().auth.admin.updateUserById(u.userId, { ban_duration: 'none' }); // simulate a lost ban
    expect(await signInFails(u.phone, u.password)).toBe(false);
    expect((await callFn(request, 'user-admin', ua1.token, offBody)).status).toBe(200);
    expect(await signInFails(u.phone, u.password), 'the replay re-applies the ban').toBe(true);

    const on = uuid();
    const onBody = { action: 'set_status', request_id: on, user_id: u.userId, status: 'active' };
    expect((await callFn(request, 'user-admin', ua1.token, onBody)).status).toBe(200);
    await service().auth.admin.updateUserById(u.userId, { ban_duration: '876000h' });
    expect((await callFn(request, 'user-admin', ua1.token, onBody)).status).toBe(200);
    expect(await signInFails(u.phone, u.password), 'the replay lifts the ban again').toBe(false);
    expect(await auditRows({ action: 'user.deactivated', entity: u.userId })).toHaveLength(1);
    expect((await auditRows({ action: 'user.deactivated', entity: u.userId }))[0].reason).toBeNull();
  });
});

test.describe('R5 account refuses before Auth is touched; 403 bodies carry a code', () => {
  test('an inactive member cannot change the password: 403 not_allowed, nothing changes, denial audited', async ({ request }) => {
    const u = await makeActiveUser(request, ua1.token);
    const s = await signIn(u.phone, u.password);
    // Database inactive but Auth not banned: simulates the window between the two writes of a status change.
    await service().from('membership').update({ status: 'inactive' }).eq('user_id', u.userId);
    const before = (await auditRows({ actor: u.userId, action: 'access.denied' })).length;
    const ch = await callFn(request, 'account', s.token, { action: 'change_password', current_password: u.password, new_password: NEW_PW });
    expect(ch.status).toBe(403);
    expect(ch.body.code).toBe('not_allowed');
    expect(ch.body.message).toBe('Not allowed');
    expect(await signInFails(u.phone, NEW_PW)).toBe(true);
    await signIn(u.phone, u.password); // the old password still works: Auth was not updated
    const denied = (await auditRows({ actor: u.userId, action: 'access.denied' })).slice(before);
    expect(denied.map((e) => e.reason)).toEqual(['inactive']);
    await service().from('membership').update({ status: 'active' }).eq('user_id', u.userId);
  });

  test('a member of a suspended tenant cannot change the password', async ({ request }) => {
    const u = await makeActiveUser(request, ua1.token);
    const s = await signIn(u.phone, u.password);
    await service().from('tenant').update({ status: 'suspended' }).eq('id', org.id);
    try {
      const ch = await callFn(request, 'account', s.token, { action: 'change_password', current_password: u.password, new_password: NEW_PW });
      expect(ch.status).toBe(403);
      expect(ch.body.code).toBe('not_allowed');
      expect(await signInFails(u.phone, NEW_PW)).toBe(true);
    } finally {
      await service().from('tenant').update({ status: 'active' }).eq('id', org.id);
    }
  });

  test('an expired temporary password answers 403 with code expired', async ({ request }) => {
    const { res, phone } = await createUserVia(request, ua1.token);
    const temp = res.body.temp_password as string;
    await service().from('membership').update({ temp_password_expires_at: new Date(Date.now() - 60_000).toISOString() }).eq('user_id', res.body.user_id);
    const s = await signIn(phone, temp);
    const ch = await callFn(request, 'account', s.token, { action: 'change_password', current_password: temp, new_password: NEW_PW });
    expect(ch.status).toBe(403);
    expect(ch.body.code).toBe('expired');
  });

  test('user-admin denials also carry code not_allowed', async ({ request }) => {
    const u = await makeActiveUser(request, ua1.token, 'supervisor');
    const s = await signIn(u.phone, u.password);
    const r = await callFn(request, 'user-admin', s.token, { action: 'reset_password', request_id: uuid(), user_id: ua1.userId });
    expect(r.status).toBe(403);
    expect(r.body).toMatchObject({ code: 'not_allowed', message: 'Not allowed' });
  });
});

test.describe('R6 double submit of one create', () => {
  test('two concurrent creates with the same request id make one user and never a 5xx', async ({ request }) => {
    const request_id = uuid();
    const body = { action: 'create', request_id, full_name: 'Double Submit', employee_id: `DS${Math.random().toString(36).slice(2, 8).toUpperCase()}`, phone: `+9190000${String(10000 + Math.floor(Math.random() * 89999)).padStart(5, '0')}`, role: 'supervisor' };
    const [x, y] = await Promise.all([callFn(request, 'user-admin', ua1.token, body), callFn(request, 'user-admin', ua1.token, body)]);
    for (const r of [x, y]) if (r.body.user_id) await service().auth.admin.deleteUser(r.body.user_id as string);
    const statuses = [x.status, y.status].sort();
    expect(statuses.every((s) => s === 200 || s === 409), JSON.stringify([x, y])).toBe(true);
    expect([x, y].filter((r) => r.status === 200 && r.body.temp_password).length).toBe(1);
  });
});
