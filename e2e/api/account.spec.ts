// 02 AC-3, AC-4, AC-13 (API part): own password change through the account Edge Function. Own org: "e2e org U-acct".
import { expect, test } from '@playwright/test';
import {
  FIXTURE_PASSWORD, anon, auditRows, callFn, cleanupCreated, createUserVia, makeActiveUser, membershipOf, orgDef, phoneToAuthEmail, provisionOrg,
  requireApi, service, signIn, signInFails, type Session,
} from './helpers';

const org = orgDef(2, 'e2e api org 2');
let ua1: Session;

test.beforeAll(async () => {
  requireApi();
  await provisionOrg(org);
  ua1 = await signIn(org.users.ua1.phone, FIXTURE_PASSWORD);
});
test.afterAll(async () => {
  await cleanupCreated();
});

const NEW_PW = 'Brand-new-pass-77';

test.describe('AC-3 first sign-in', () => {
  test('forced change: temporary password -> new password clears the gate and is audited', async ({ request }) => {
    const { res, phone } = await createUserVia(request, ua1.token);
    expect(res.status).toBe(200);
    const temp = res.body.temp_password as string;
    const s = await signIn(phone, temp);
    expect((await s.client.from('tenant').select('id')).data).toEqual([]); // gated

    const ch = await callFn(request, 'account', s.token, { action: 'change_password', current_password: temp, new_password: NEW_PW });
    expect(ch.status).toBe(200);
    expect(ch.body).toEqual({ ok: true });

    const m = await membershipOf(res.body.user_id);
    expect(m!.must_change_password).toBe(false);
    expect(m!.temp_password_expires_at).toBeNull();
    const events = await auditRows({ action: 'user.password_changed', entity: res.body.user_id });
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ tenant_id: org.id, actor_user_id: res.body.user_id, source: 'edge:account' });
    expect(JSON.stringify(events[0])).not.toContain(NEW_PW);
    expect(JSON.stringify(events[0])).not.toContain(temp);

    expect(await signInFails(phone, temp)).toBe(true);
    const fresh = await signIn(phone, NEW_PW);
    expect((await fresh.client.from('tenant').select('id')).data).toHaveLength(1); // gate lifted
    // the pre-change session also sees data now (flag is read per query)
    expect((await s.client.from('tenant').select('id')).data).toHaveLength(1);
  });

  test('wrong current password -> 403 and nothing changes', async ({ request }) => {
    const u = await makeActiveUser(request, ua1.token);
    const s = await signIn(u.phone, u.password);
    const before = (await auditRows({ action: 'user.password_changed', entity: u.userId })).length; // the first change made it active
    const r = await callFn(request, 'account', s.token, { action: 'change_password', current_password: 'Wrong-password-1', new_password: NEW_PW });
    expect(r.status).toBe(403);
    expect(r.body.field).toBe('current_password');
    await signIn(u.phone, u.password);
    expect(await auditRows({ action: 'user.password_changed', entity: u.userId })).toHaveLength(before);
  });

  test('policy: too short, no digit, no letter, same as current -> 400 new_password', async ({ request }) => {
    const u = await makeActiveUser(request, ua1.token);
    const s = await signIn(u.phone, u.password);
    for (const next of ['Short1a', 'onlyletterslong', '12345678901234', u.password]) {
      const r = await callFn(request, 'account', s.token, { action: 'change_password', current_password: u.password, new_password: next });
      expect(r.status, next).toBe(400);
      expect(r.body.field).toBe('new_password');
    }
    await signIn(u.phone, u.password); // unchanged
  });

  test('self-service change from Home for a normal user (AC-13)', async ({ request }) => {
    const u = await makeActiveUser(request, ua1.token);
    const s = await signIn(u.phone, u.password);
    const before = (await auditRows({ action: 'user.password_changed', entity: u.userId })).length;
    const r = await callFn(request, 'account', s.token, { action: 'change_password', current_password: u.password, new_password: NEW_PW });
    expect(r.status).toBe(200);
    await signIn(u.phone, NEW_PW);
    expect(await signInFails(u.phone, u.password)).toBe(true);
    expect(await auditRows({ action: 'user.password_changed', entity: u.userId })).toHaveLength(before + 1);
  });

  test('no JWT -> 401; unknown action -> 400', async ({ request }) => {
    expect((await callFn(request, 'account', null, { action: 'change_password', current_password: 'a', new_password: 'b' })).status).toBe(401);
    const s = await signIn(org.users.sup.phone, FIXTURE_PASSWORD);
    expect((await callFn(request, 'account', s.token, { action: 'nope', current_password: 'a', new_password: 'b' })).status).toBe(400);
  });
});

test.describe('AC-4 expiry', () => {
  test('an expired temporary password is refused with the exact message and only access.denied is written', async ({ request }) => {
    const fresh = org.users.fresh;
    const sb = service();
    await sb.from('membership').update({ must_change_password: true, temp_password_expires_at: new Date(Date.now() - 60_000).toISOString() }).eq('user_id', fresh.id);
    const before = (await auditRows({ actor: fresh.id })).length;
    const s = await signIn(fresh.phone, FIXTURE_PASSWORD);
    const r = await callFn(request, 'account', s.token, { action: 'change_password', current_password: FIXTURE_PASSWORD, new_password: NEW_PW });
    expect(r.status).toBe(403);
    expect(r.body.message).toBe('Your temporary password has expired. Ask your Unit Admin to reset it.');
    const events = (await auditRows({ actor: fresh.id })).slice(before);
    expect(events.map((e) => [e.action, e.reason])).toEqual([['access.denied', 'temp_password_expired']]);
    expect((await membershipOf(fresh.id))!.must_change_password).toBe(true);
    expect(await auditRows({ action: 'user.password_changed', entity: fresh.id })).toHaveLength(0);
    // the password itself did not change
    await signIn(fresh.phone, FIXTURE_PASSWORD);
    const { error } = await anon().auth.signInWithPassword({ email: phoneToAuthEmail(fresh.phone), password: NEW_PW });
    expect(error).not.toBeNull();
  });

  test('a UA reset gives an expired user a fresh 24 h window', async ({ request }) => {
    const fresh = org.users.fresh;
    const r = await callFn(request, 'user-admin', ua1.token, { action: 'reset_password', request_id: crypto.randomUUID(), user_id: fresh.id });
    expect(r.status).toBe(200);
    const s = await signIn(fresh.phone, r.body.temp_password);
    const ch = await callFn(request, 'account', s.token, { action: 'change_password', current_password: r.body.temp_password, new_password: NEW_PW });
    expect(ch.status).toBe(200);
  });
});
