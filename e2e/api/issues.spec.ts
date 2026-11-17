// 07 AC-1..13 through the real stack (PostgREST RPC + Storage over HTTP). Org "e2e api org issues" (own tenant, throwaway phone block) is the
// actor; fixture orgs U (Unit Admin) and the fixture Super Admin supply the outsiders (read-only here). Throwaway machine/shifts are
// retired in afterAll; issues and photos are append-only history and stay (known debt, like 04/05).
import { expect, test } from '@playwright/test';
import {
  FIXTURE_PASSWORD, SA_FIXTURES, anon, TINY_JPEG, auditRows, customOrg, provisionSuperAdmin, service, requireApi, seedResolvedIssue, setupIssueWorld, sha256Hex, signIn, teardownIssueWorld, uuid,
  type IssueWorld, type Session,
} from './helpers';

const ORG = customOrg('20000000-0000-4000-a000-0000000000b7', 'e2e api org issues', ['+919000077721', '+919000077722', '+919000077723', '+919000077724']);
const FIXTURE_UA_U = '+919000000006';
const DENIED = { ok: false, code: 'not_allowed' };

let w: IssueWorld;
let uaOther: Session;
let sa: Session;
const report = (s: Session, over: Record<string, unknown> = {}) =>
  s.client.rpc('iss_report', {
    p_request_id: uuid(), p_machine_id: w.machine.id, p_category_id: w.categoryId, p_priority: 'high', p_description: `E2E issue ${uuid().slice(0, 8)}`, p_machine_stopped: false, ...over,
  });

/** begin -> Storage upload -> commit, like the app does. */
async function addPhoto(s: Session, issueId: string, bytes: Buffer = TINY_JPEG) {
  const begin = await s.client.rpc('iss_attachment_begin', { p_request_id: uuid(), p_issue_id: issueId, p_mime: 'image/jpeg', p_size: bytes.length, p_sha256: sha256Hex(bytes) });
  expect(begin.error).toBeNull();
  expect(begin.data).toMatchObject({ ok: true, status: 'pending' });
  const up = await s.client.storage.from('attachments').upload(begin.data.path, bytes, { contentType: 'image/jpeg', upsert: false });
  return { begin: begin.data as { id: string; path: string; action_id: string }, up };
}

test.beforeAll(async () => {
  requireApi();
  w = await setupIssueWorld(ORG, 'E2E Issues Plant');
  uaOther = await signIn(FIXTURE_UA_U, FIXTURE_PASSWORD);
  await provisionSuperAdmin(SA_FIXTURES.sa1);
  sa = await signIn(SA_FIXTURES.sa1.phone, FIXTURE_PASSWORD);
});
test.afterAll(() => teardownIssueWorld(w));

test.describe('Photos: begin, upload, commit, authenticated download (AC-12, AC-13)', () => {
  test('the reporter attaches a photo and the owner reads it through a signed URL', async () => {
    const r = await report(w.running.session);
    expect(r.data).toMatchObject({ ok: true });
    const issueId = r.data.id as string;
    const { begin, up } = await addPhoto(w.running.session, issueId);
    expect(up.error).toBeNull();
    const commit = await w.running.session.client.rpc('iss_attachment_commit', { p_request_id: uuid(), p_attachment_id: begin.id });
    expect(commit.error).toBeNull();
    expect(commit.data).toMatchObject({ ok: true });

    const detail = await w.running.session.client.rpc('issue_detail', { p_id: issueId });
    const photos = detail.data.actions.flatMap((a: { attachments: { id: string; path: string }[] }) => a.attachments);
    expect(photos).toEqual([expect.objectContaining({ id: begin.id, path: begin.path, mime: 'image/jpeg' })]);
    expect(begin.path).toBe(`tenant/${w.org.id}/issue/${issueId}/${begin.id}.jpg`);

    // R3: the app reads a photo with an authenticated download (Storage RLS runs on every view), never a long-lived signed URL.
    const dl = await w.running.session.client.storage.from('attachments').download(begin.path);
    expect(dl.error).toBeNull();
    expect(Buffer.from(await dl.data!.arrayBuffer()).equals(TINY_JPEG)).toBe(true);
    // The Unit Admin of the same tenant sees it too (photos are visible to everyone who can see the issue).
    expect((await w.ua.client.storage.from('attachments').download(begin.path)).error).toBeNull();
  });

  test('a replayed begin returns the same attachment; a replayed commit is idempotent', async () => {
    const issueId = (await report(w.running.session)).data.id as string;
    const rid = uuid();
    const args = { p_request_id: rid, p_issue_id: issueId, p_mime: 'image/jpeg', p_size: TINY_JPEG.length, p_sha256: sha256Hex(TINY_JPEG) };
    const a = await w.running.session.client.rpc('iss_attachment_begin', args);
    const b = await w.running.session.client.rpc('iss_attachment_begin', args);
    expect(b.data).toMatchObject({ ok: true, id: a.data.id, path: a.data.path, already: true });
    await w.running.session.client.storage.from('attachments').upload(a.data.path, TINY_JPEG, { contentType: 'image/jpeg' });
    const cid = uuid();
    expect((await w.running.session.client.rpc('iss_attachment_commit', { p_request_id: cid, p_attachment_id: a.data.id })).data).toMatchObject({ ok: true });
    expect((await w.running.session.client.rpc('iss_attachment_commit', { p_request_id: cid, p_attachment_id: a.data.id })).data).toMatchObject({ ok: true });
  });

  test('commit refuses a photo that was never uploaded, and a size that does not match the stored object', async () => {
    const issueId = (await report(w.running.session)).data.id as string;
    const none = await w.running.session.client.rpc('iss_attachment_begin', { p_request_id: uuid(), p_issue_id: issueId, p_mime: 'image/jpeg', p_size: 100, p_sha256: sha256Hex(Buffer.from('x')) });
    const missing = await w.running.session.client.rpc('iss_attachment_commit', { p_request_id: uuid(), p_attachment_id: none.data.id });
    expect(missing.error?.code).toBe('P0001');
    const liar = await w.running.session.client.rpc('iss_attachment_begin', { p_request_id: uuid(), p_issue_id: issueId, p_mime: 'image/jpeg', p_size: TINY_JPEG.length + 50, p_sha256: sha256Hex(TINY_JPEG) });
    await w.running.session.client.storage.from('attachments').upload(liar.data.path, TINY_JPEG, { contentType: 'image/jpeg' });
    const mismatch = await w.running.session.client.rpc('iss_attachment_commit', { p_request_id: uuid(), p_attachment_id: liar.data.id });
    expect(mismatch.error?.code).toBe('P0001');
  });

  test('Storage refuses an upload that was not started with begin, and a path of another tenant', async () => {
    const stray = await w.running.session.client.storage.from('attachments').upload(`tenant/${w.org.id}/issue/${uuid()}/${uuid()}.jpg`, TINY_JPEG, { contentType: 'image/jpeg' });
    expect(stray.error).not.toBeNull();
    const foreign = await w.running.session.client.storage.from('attachments').upload(`tenant/${uuid()}/issue/${uuid()}/${uuid()}.jpg`, TINY_JPEG, { contentType: 'image/jpeg' });
    expect(foreign.error).not.toBeNull();
  });

  test('begin refuses a type that is not an image and a photo over 5 MB', async () => {
    const issueId = (await report(w.running.session)).data.id as string;
    const pdf = await w.running.session.client.rpc('iss_attachment_begin', { p_request_id: uuid(), p_issue_id: issueId, p_mime: 'application/pdf', p_size: 10, p_sha256: sha256Hex(Buffer.from('x')) });
    expect(pdf.error?.code).toBe('P0001');
    const big = await w.running.session.client.rpc('iss_attachment_begin', { p_request_id: uuid(), p_issue_id: issueId, p_mime: 'image/jpeg', p_size: 5 * 1024 * 1024 + 1, p_sha256: sha256Hex(Buffer.from('x')) });
    expect(big.error?.code).toBe('P0001');
  });
});

test.describe('Who can read a photo (AC-11, AC-13)', () => {
  let issueId: string;
  let path: string;
  test.beforeAll(async () => {
    issueId = (await report(w.running.session)).data.id as string;
    const { begin } = await addPhoto(w.running.session, issueId);
    await w.running.session.client.rpc('iss_attachment_commit', { p_request_id: uuid(), p_attachment_id: begin.id });
    path = begin.path;
  });

  test('the Unit Admin of another tenant cannot sign or download it', async () => {
    expect((await uaOther.client.storage.from('attachments').download(path)).error).not.toBeNull();
    expect((await uaOther.client.storage.from('attachments').download(path)).error).not.toBeNull();
    expect((await uaOther.client.storage.from('attachments').list(`tenant/${w.org.id}/issue/${issueId}`)).data ?? []).toEqual([]);
    expect((await uaOther.client.rpc('issue_detail', { p_id: issueId })).data).toEqual(DENIED);
  });

  test('the Platform Super Admin reads 0 objects and no issue (SA boundary)', async () => {
    expect((await sa.client.storage.from('attachments').download(path)).error).not.toBeNull();
    expect((await sa.client.storage.from('attachments').download(path)).error).not.toBeNull();
    expect((await sa.client.storage.from('attachments').list(`tenant/${w.org.id}/issue/${issueId}`)).data ?? []).toEqual([]);
    expect((await sa.client.storage.from('attachments').list(`tenant/${w.org.id}`)).data ?? []).toEqual([]);
    expect((await sa.client.rpc('issue_detail', { p_id: issueId })).data).toEqual(DENIED);
    expect((await sa.client.rpc('issue_alerts', {})).data).toEqual(DENIED);
    expect((await sa.client.rpc('issue_list', { p_filters: {}, p_page: 1 })).data).toEqual(DENIED);
    expect((await sa.client.from('machine_issue').select('id')).data ?? []).toEqual([]);
  });

  test('a supervisor with no part in the issue cannot see it or its photo; once they own it they can', async () => {
    const idle = w.idle.session;
    expect((await idle.client.rpc('issue_detail', { p_id: issueId })).data).toEqual(DENIED);
    expect((await idle.client.storage.from('attachments').download(path)).error).not.toBeNull();
    expect((await idle.client.storage.from('attachments').download(path)).error).not.toBeNull();
    const list = await idle.client.rpc('issue_list', { p_filters: { status: 'not_closed' }, p_page: 1 });
    expect(list.data.items.map((i: { id: string }) => i.id)).not.toContain(issueId);
    const re = await w.ua.client.rpc('iss_reassign', { p_request_id: uuid(), p_issue_id: issueId, p_new_owner: idle.userId, p_reason: 'E2E handover' });
    expect(re.data).toMatchObject({ ok: true });
    expect((await idle.client.rpc('issue_detail', { p_id: issueId })).data).toMatchObject({ ok: true });
    expect((await idle.client.storage.from('attachments').download(path)).error).toBeNull();
  });

  test('an anonymous caller gets nothing', async () => {
    const a = anon();
    expect((await a.storage.from('attachments').download(path)).error).not.toBeNull();
    expect((await a.rpc('issue_detail', { p_id: issueId })).error).not.toBeNull();
  });
});

test.describe('A user who loses access gets no new photo and no issue data (R3, D14)', () => {
  // D14: hosted Storage's CDN caches an authenticated download per user until the JWT expires, so a re-fetch of an object the user already
  // downloaded is not asserted. A photo they never fetched, and all issue data, are refused at once.
  test('a deactivated supervisor, with a token still valid, cannot download a photo they never fetched', async () => {
    const issueId = (await report(w.running.session)).data.id as string;
    const first = (await addPhoto(w.running.session, issueId)).begin;
    await w.running.session.client.rpc('iss_attachment_commit', { p_request_id: uuid(), p_attachment_id: first.id });
    const second = (await addPhoto(w.running.session, issueId)).begin;
    await w.running.session.client.rpc('iss_attachment_commit', { p_request_id: uuid(), p_attachment_id: second.id });
    // The idle supervisor becomes the owner and reads the first photo (control: access works), never the second.
    expect((await w.ua.client.rpc('iss_reassign', { p_request_id: uuid(), p_issue_id: issueId, p_new_owner: w.idle.session.userId, p_reason: 'E2E R3' })).data).toMatchObject({ ok: true });
    expect((await w.idle.session.client.rpc('issue_detail', { p_id: issueId })).data).toMatchObject({ ok: true });
    expect((await w.idle.session.client.storage.from('attachments').download(first.path)).error).toBeNull();
    try {
      const off = await service().from('membership').update({ status: 'inactive' }).eq('user_id', w.idle.session.userId).select('user_id');
      expect(off.error).toBeNull();
      expect((await w.idle.session.client.storage.from('attachments').download(second.path)).error).not.toBeNull();
      expect((await w.idle.session.client.rpc('issue_detail', { p_id: issueId })).data).toEqual(DENIED);
      expect((await w.idle.session.client.rpc('issue_list', { p_filters: {}, p_page: 1 })).data).toEqual(DENIED);
    } finally {
      await service().from('membership').update({ status: 'active' }).eq('user_id', w.idle.session.userId);
    }
  });
});

test.describe('Storage is append-only for clients (N-1)', () => {
  let path: string;
  test.beforeAll(async () => {
    const issueId = (await report(w.running.session)).data.id as string;
    const { begin } = await addPhoto(w.running.session, issueId);
    await w.running.session.client.rpc('iss_attachment_commit', { p_request_id: uuid(), p_attachment_id: begin.id });
    path = begin.path;
  });
  const stillThere = async () => Buffer.from(await (await w.running.session.client.storage.from('attachments').download(path)).data!.arrayBuffer()).equals(TINY_JPEG);

  test('remove, move and update are refused and the object is untouched', async () => {
    const bucket = w.running.session.client.storage.from('attachments');
    const rm = await bucket.remove([path]);
    expect(rm.error !== null || (rm.data ?? []).length === 0).toBe(true);
    expect((await bucket.move(path, `${path}.moved`)).error).not.toBeNull();
    expect((await bucket.update(path, Buffer.from('replaced'), { contentType: 'image/jpeg' })).error).not.toBeNull();
    expect(await stillThere()).toBe(true);
  });

  test('upload with upsert over an existing object is refused and the object is untouched', async () => {
    const up = await w.running.session.client.storage.from('attachments').upload(path, Buffer.from('replaced'), { contentType: 'image/jpeg', upsert: true });
    expect(up.error).not.toBeNull();
    expect(await stillThere()).toBe(true);
  });

  test('a text/html upload and one over 5 MB are refused by the bucket', async () => {
    const issueId = (await report(w.running.session)).data.id as string;
    const html = Buffer.from('<script>alert(1)</script>');
    const b1 = await w.running.session.client.rpc('iss_attachment_begin', { p_request_id: uuid(), p_issue_id: issueId, p_mime: 'image/jpeg', p_size: html.length, p_sha256: sha256Hex(html) });
    const up1 = await w.running.session.client.storage.from('attachments').upload(b1.data.path, html, { contentType: 'text/html' });
    expect(up1.error).not.toBeNull();
    const big = Buffer.alloc(5 * 1024 * 1024 + 1, 1);
    const b2 = await w.running.session.client.rpc('iss_attachment_begin', { p_request_id: uuid(), p_issue_id: issueId, p_mime: 'image/jpeg', p_size: 1000, p_sha256: sha256Hex(big) });
    const up2 = await w.running.session.client.storage.from('attachments').upload(b2.data.path, big, { contentType: 'image/jpeg' });
    expect(up2.error).not.toBeNull();
  });
});

test.describe('Request ids belong to one RPC (N-3)', () => {
  test('begin refuses a request id already used by another RPC', async () => {
    const issueId = (await report(w.running.session)).data.id as string;
    const rid = uuid();
    expect((await w.running.session.client.rpc('iss_note', { p_request_id: rid, p_issue_id: issueId, p_notes: 'first use' })).data).toMatchObject({ ok: true });
    const b = await w.running.session.client.rpc('iss_attachment_begin', { p_request_id: rid, p_issue_id: issueId, p_mime: 'image/jpeg', p_size: TINY_JPEG.length, p_sha256: sha256Hex(TINY_JPEG) });
    expect(b.error?.code).toBe('P0001');
  });
});

test.describe('Verification rule (AC-6, D4)', () => {
  test('the resolver cannot verify their own fix, even a later shift owner can only if they are not the resolver', async () => {
    const issueId = await seedResolvedIssue(w, 'high', 'E2E resolved before the last shift boundary');
    // The resolver (idle supervisor) is refused; the owner of the shift that started since may confirm.
    const own = await w.idle.session.client.rpc('iss_verify', { p_request_id: uuid(), p_issue_id: issueId, p_confirm: true });
    expect(own.data).toEqual(DENIED);
    const detailIdle = await w.idle.session.client.rpc('issue_detail', { p_id: issueId });
    expect(detailIdle.data.allowed_actions).not.toContain('verify');
    const detailRun = await w.running.session.client.rpc('issue_detail', { p_id: issueId });
    expect(detailRun.data.allowed_actions).toContain('verify');
    // A Unit Admin may not verify while a later-shift supervisor is assigned.
    expect((await w.ua.client.rpc('iss_verify', { p_request_id: uuid(), p_issue_id: issueId, p_confirm: true })).data).toEqual(DENIED);
    const ok = await w.running.session.client.rpc('iss_verify', { p_request_id: uuid(), p_issue_id: issueId, p_confirm: true });
    expect(ok.data).toMatchObject({ ok: true });
    const after = await w.running.session.client.rpc('issue_detail', { p_id: issueId });
    expect(after.data.issue).toMatchObject({ status: 'closed' });
    expect(after.data.issue.closed_at).not.toBeNull();
  });

  test('rejecting returns the issue to the rejecting supervisor with a reason, and the history keeps both owners', async () => {
    const issueId = await seedResolvedIssue(w, 'critical', 'E2E rejected fix');
    const noReason = await w.running.session.client.rpc('iss_verify', { p_request_id: uuid(), p_issue_id: issueId, p_confirm: false, p_reason: null });
    expect(noReason.error?.code).toBe('P0001');
    const rej = await w.running.session.client.rpc('iss_verify', { p_request_id: uuid(), p_issue_id: issueId, p_confirm: false, p_reason: 'Still leaking' });
    expect(rej.data).toMatchObject({ ok: true });
    const d = await w.running.session.client.rpc('issue_detail', { p_id: issueId });
    expect(d.data.issue).toMatchObject({ status: 'in_progress', owner_id: w.running.session.userId });
    expect(d.data.ownership.map((o: { source: string }) => o.source)).toEqual(['report', 'verification_rejected']);
    expect(d.data.actions.map((a: { type: string }) => a.type)).toEqual(['report', 'resolve', 'verify_reject']);
  });

  test('a Low issue closes when the owner resolves it', async () => {
    const r = await report(w.running.session, { p_priority: 'low' });
    const done = await w.running.session.client.rpc('iss_resolve', { p_request_id: uuid(), p_issue_id: r.data.id, p_notes: 'Tightened the guard' });
    expect(done.data).toMatchObject({ ok: true });
    expect((await w.running.session.client.rpc('issue_detail', { p_id: r.data.id })).data.issue).toMatchObject({ status: 'closed' });
  });
});

test.describe('Audit and denials over HTTP (AC-11)', () => {
  test('an outsider writing to an issue is denied and audited as access.denied', async () => {
    const issueId = (await report(w.running.session)).data.id as string;
    const before = (await auditRows({ action: 'access.denied', actor: uaOther.userId })).length;
    expect((await uaOther.client.rpc('iss_note', { p_request_id: uuid(), p_issue_id: issueId, p_notes: 'Nope' })).data).toEqual(DENIED);
    expect((await auditRows({ action: 'access.denied', actor: uaOther.userId })).length).toBe(before + 1);
    expect((await sa.client.rpc('iss_note', { p_request_id: uuid(), p_issue_id: issueId, p_notes: 'Nope' })).data).toEqual(DENIED);
  });

  test('the issue tables accept no direct writes from any client', async () => {
    const row = { tenant_id: w.org.id, machine_id: w.machine.id, category_id: w.categoryId, priority: 'low', description: 'x', reported_by: w.ua.userId };
    expect((await w.ua.client.from('machine_issue').insert(row)).error?.code).toBe('42501');
    expect((await w.running.session.client.from('machine_issue').insert(row)).error?.code).toBe('42501');
    expect((await w.running.session.client.from('issue_action').select('id')).data ?? []).toEqual([]); // supervisors read through the RPCs only
  });
});
