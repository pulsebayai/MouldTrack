// 06 AC-1..15 through the real stack (PostgREST RPC + Storage over HTTP). Own tenant "e2e api org readings" and throwaway E2E-<random> machine,
// product and shifts (07's clock-derived world: one shift is running at any moment and its supervisor owns the machine). Readings and summaries are
// append-only history and stay (known debt, like 04/05/07); every machine and product code is unique per run so a persistent dev database never collides.
import { expect, test } from '@playwright/test';
import {
  FIXTURE_PASSWORD, SA_FIXTURES, TINY_JPEG, anon, auditRows, customOrg, requireApi, setupIssueWorld, sha256Hex, signIn, teardownIssueWorld, uuid,
  type IssueWorld, type Session,
} from './helpers';

const ORG = customOrg('20000000-0000-4000-a000-0000000000b9', 'e2e api org readings', ['+919000077741', '+919000077742', '+919000077743', '+919000077744']);
const FIXTURE_UA_U = '+919000000006';
const DENIED = { ok: false, code: 'not_allowed' };

let w: IssueWorld;
let uaOther: Session;
// A Super Admin session is signed in right before it is used and the shared fixture SA is never re-provisioned here: platform.spec re-provisions
// it, and doing so concurrently invalidates the other spec's session (the two api files may run on different workers).
let sa: Session;
const saNow = async () => (sa = await signIn(SA_FIXTURES.sa2.phone, FIXTURE_PASSWORD));
let shiftId: string;
let productId: string;
let productCode: string;
let closingId: string;
const run = Math.random().toString(36).slice(2, 8).toUpperCase();

const date = () => w.today;
const opening = (s: Session, over: Record<string, unknown> = {}) =>
  s.client.rpc('rd_opening', { p_request_id: uuid(), p_machine_id: w.machine.id, p_shift_id: shiftId, p_shift_date: date(), p_product_id: productId, p_counter: 1000, p_remarks: null, ...over });
const closing = (s: Session, over: Record<string, unknown> = {}) =>
  s.client.rpc('rd_closing', { p_request_id: uuid(), p_machine_id: w.machine.id, p_shift_id: shiftId, p_shift_date: date(), p_counter: 1250, p_good: 950, p_reject: 30, p_remarks: null, ...over });
const detail = (s: Session) => s.client.rpc('reading_detail', { p_machine_id: w.machine.id, p_shift_id: shiftId, p_shift_date: date() });

test.describe.configure({ mode: 'serial' });
test.beforeAll(async () => {
  requireApi();
  w = await setupIssueWorld(ORG, 'E2E Readings Plant');
  shiftId = w.running.session === w.sup2 ? w.shiftPm : w.shiftAm;
  uaOther = await signIn(FIXTURE_UA_U, FIXTURE_PASSWORD);
  productCode = `E2E-${run}`;
  const p = await w.ua.client.rpc('pm_save_product', { p_request_id: uuid(), p_id: null, p_code: productCode, p_description: 'E2E readings part', p_uom: 'pcs' });
  expect(p.data).toMatchObject({ ok: true });
  productId = p.data.id;
  const t = await w.ua.client.rpc('pm_set_target', { p_request_id: uuid(), p_machine_id: w.machine.id, p_product_id: productId, p_pieces: 1000, p_effective_from: w.today });
  expect(t.data).toMatchObject({ ok: true });
  // The counter counts shots, 4 cavities per shot (so pieces = shots x 4), set before the first reading (the unit locks with it).
  expect((await w.ua.client.rpc('rd_set_machine_counter', { p_request_id: uuid(), p_machine_id: w.machine.id, p_unit: 'shots', p_max: null })).data).toMatchObject({ ok: true });
  expect((await w.ua.client.rpc('rd_set_cavities', { p_request_id: uuid(), p_machine_id: w.machine.id, p_product_id: productId, p_cavities: 4, p_effective_from: w.today })).data).toMatchObject({ ok: true });
});
test.beforeEach(async () => {
  await saNow();
});
test.afterAll(() => teardownIssueWorld(w));

test.describe('Counter settings (AC-2, D3)', () => {
  test('a Unit Admin set shots and cavities; a supervisor and a Super Admin cannot', async () => {
    const m = await w.ua.client.from('machine').select('counter_unit, counter_max').eq('id', w.machine.id).single();
    expect(m.data).toEqual({ counter_unit: 'shots', counter_max: null });
    const sup = await w.running.session.client.rpc('rd_set_machine_counter', { p_request_id: uuid(), p_machine_id: w.machine.id, p_unit: 'pieces', p_max: null });
    expect(sup.data).toEqual(DENIED);
    const other = await sa.client.rpc('rd_set_cavities', { p_request_id: uuid(), p_machine_id: w.machine.id, p_product_id: productId, p_cavities: 2, p_effective_from: w.today });
    expect(other.data).toEqual(DENIED);
  });
});

test.describe('Opening and closing (AC-1, AC-3, AC-4, AC-5, AC-10)', () => {
  test('the state starts as opening due with the default product unknown', async () => {
    const s = await w.running.session.client.rpc('reading_state', {});
    expect(s.error).toBeNull();
    const m = s.data.occurrences.flatMap((o: { shift: { id: string }; machines: { machine_id: string }[] }) => (o.shift.id === shiftId ? o.machines : [])).find((x: { machine_id: string }) => x.machine_id === w.machine.id);
    expect(m).toMatchObject({ state: 'opening_due', can_open: true, can_close: false, counter_unit: 'shots' });
  });

  test('another supervisor, another tenant and a Super Admin cannot record, and the refusals are audited', async () => {
    expect((await opening(w.idle.session)).data).toEqual(DENIED);
    expect((await opening(uaOther)).data).toEqual(DENIED);
    expect((await opening(sa)).data).toEqual(DENIED);
    expect((await auditRows({ action: 'access.denied', actor: w.idle.session.userId, reason: 'not_owner' })).length).toBeGreaterThanOrEqual(1);
    expect((await auditRows({ action: 'access.denied', actor: sa.userId })).length).toBeGreaterThanOrEqual(1);
  });

  test('the owner records the opening; a replay is idempotent and a second opening is refused', async () => {
    const rid = uuid();
    const a = await opening(w.running.session, { p_request_id: rid });
    expect(a.error).toBeNull();
    expect(a.data).toMatchObject({ ok: true, entered_by_ua: false });
    expect(typeof a.data.late).toBe('boolean');
    const firstOpening = a.data.id as string;
    const b = await opening(w.running.session, { p_request_id: rid });
    expect(b.data).toMatchObject({ ok: true, id: firstOpening, already: true });
    const again = await opening(w.running.session);
    expect(again.error?.code).toBe('P0001');
    expect(JSON.parse(again.error!.details!).field).toBe('already_recorded');
  });

  test('a request id cannot be reused for another RPC', async () => {
    const rid = uuid();
    expect((await closing(w.running.session, { p_request_id: rid, p_counter: 5, p_good: 1, p_reject: 0 })).data).toMatchObject({ ok: true });
    // (that closing is recorded for real below; use a throwaway id on a different RPC)
    const clash = await w.running.session.client.rpc('rd_correct', { p_request_id: rid, p_reading_id: (await detail(w.running.session)).data.opening.id, p_counter: 1001, p_product_id: productId, p_good: null, p_reject: null, p_remarks: null, p_reason: 'clash' });
    expect(clash.error?.code).toBe('P0001');
  });

  test('validation: a counter below zero or above 10^12, and a negative quantity, are refused with the field', async () => {
    const bad = await closing(w.running.session, { p_counter: -1 });
    expect(bad.error?.code).toBe('P0001');
    expect(JSON.parse(bad.error!.details!).field).toBe('counter');
    const big = await closing(w.running.session, { p_good: 10_000_001 });
    expect(JSON.parse(big.error!.details!).field).toBe('good');
  });

  test('the summary of the closing uses shots x cavities and the target (AC-10)', async () => {
    // The closing recorded in the idempotency test (counter 5, good 1) is the current one; correct it to the intended numbers, which also proves AC-6.
    const d0 = await detail(w.running.session);
    closingId = d0.data.closing.id;
    const fix = await w.running.session.client.rpc('rd_correct', { p_request_id: uuid(), p_reading_id: closingId, p_counter: 1250, p_product_id: null, p_good: 950, p_reject: 30, p_remarks: null, p_reason: 'E2E recount' });
    expect(fix.data).toMatchObject({ ok: true });
    const d = await detail(w.running.session);
    expect(d.data.summary).toMatchObject({ movement_pieces: 1000, good: 950, reject: 30, unaccounted: 20, target: 1000, cavities: 4, counter_unit: 'shots', needs_review: false, rollover: false });
    expect(Number(d.data.summary.attainment_pct)).toBe(95);
    expect(d.data.summary_count).toBeGreaterThanOrEqual(2);
    expect(d.data.readings.some((r: { supersedes_id: string | null; correction_reason: string | null }) => r.supersedes_id && r.correction_reason === 'E2E recount')).toBe(true);
  });

  test('a Unit Admin sees every reading and may correct at any time; the correction is flagged as entered by a Unit Admin', async () => {
    const d = await detail(w.ua);
    expect(d.data).toMatchObject({ ok: true, allowed: { can_correct: true } });
    const cur = d.data.opening.id;
    const fix = await w.ua.client.rpc('rd_correct', { p_request_id: uuid(), p_reading_id: cur, p_counter: 1000, p_product_id: productId, p_good: null, p_reject: null, p_remarks: 'E2E UA check', p_reason: 'UA recheck' });
    expect(fix.data).toMatchObject({ ok: true, entered_by_ua: true });
    expect((await detail(w.ua)).data.opening.entered_by_ua).toBe(true);
  });

  test('the other supervisor, another tenant and a Super Admin cannot read the occurrence', async () => {
    expect((await detail(w.idle.session)).data).toEqual(DENIED);
    expect((await detail(uaOther)).data).toEqual(DENIED);
    expect((await detail(sa)).data).toEqual(DENIED);
    expect((await sa.client.rpc('reading_state', {})).data).toEqual(DENIED);
    expect((await sa.client.rpc('today_board', {})).data).toEqual(DENIED);
    expect((await sa.client.from('production_reading').select('id')).data ?? []).toEqual([]);
    expect((await sa.client.from('production_summary').select('id')).data ?? []).toEqual([]);
  });

  test('supervisors cannot read the reading tables directly; Unit Admins can, their own tenant only', async () => {
    expect((await w.running.session.client.from('production_reading').select('id')).data ?? []).toEqual([]);
    expect(((await w.ua.client.from('production_reading').select('id, tenant_id')).data ?? []).every((r) => r.tenant_id === w.org.id)).toBe(true);
    expect((await uaOther.client.from('production_reading').select('id').eq('machine_id', w.machine.id)).data ?? []).toEqual([]);
  });

  test('the public reads accept no client-supplied time', async () => {
    const r = await w.running.session.client.rpc('reading_state', { p_at: new Date(0).toISOString() });
    expect(r.error).not.toBeNull();
    const b = await w.ua.client.rpc('today_board', { p_at: new Date(0).toISOString() });
    expect(b.error).not.toBeNull();
  });
});

test.describe('Today board (AC-12)', () => {
  test('a Unit Admin sees the machine with target and actual; a supervisor is denied', async () => {
    const b = await w.ua.client.rpc('today_board', {});
    expect(b.error).toBeNull();
    const row = b.data.occurrences.flatMap((o: { shift: { id: string }; machines: { machine_id: string }[] }) => (o.shift.id === shiftId ? o.machines : [])).find((m: { machine_id: string }) => m.machine_id === w.machine.id);
    expect(row).toMatchObject({ code: w.machine.code, target: 1000, good: 950, closing_status: expect.stringMatching(/on_time|late/) });
    expect(Number(row.attainment_pct)).toBe(95);
    expect(b.data.occurrences.length).toBeLessThanOrEqual(4);
    expect((await w.running.session.client.rpc('today_board', {})).data).toEqual(DENIED);
    expect((await uaOther.client.rpc('today_board', {})).data.occurrences.flatMap((o: { machines: { machine_id: string }[] }) => o.machines).map((m: { machine_id: string }) => m.machine_id)).not.toContain(w.machine.id);
  });
});

test.describe('Photos on a reading (AC-14)', () => {
  let path: string;
  test('the owner attaches a photo with begin, upload and commit; replays are idempotent', async () => {
    const rid = uuid();
    // the opening was corrected above: attach to the current opening
    const cur = (await detail(w.running.session)).data.opening.id as string;
    const args = { p_request_id: rid, p_reading_id: cur, p_mime: 'image/jpeg', p_size: TINY_JPEG.length, p_sha256: sha256Hex(TINY_JPEG) };
    const a = await w.running.session.client.rpc('rd_attachment_begin', args);
    expect(a.data).toMatchObject({ ok: true, status: 'pending' });
    expect(a.data.path).toBe(`tenant/${w.org.id}/reading/${cur}/${a.data.id}.jpg`);
    expect((await w.running.session.client.rpc('rd_attachment_begin', args)).data).toMatchObject({ ok: true, id: a.data.id, already: true });
    const up = await w.running.session.client.storage.from('attachments').upload(a.data.path, TINY_JPEG, { contentType: 'image/jpeg', upsert: false });
    expect(up.error).toBeNull();
    const cid = uuid();
    expect((await w.running.session.client.rpc('rd_attachment_commit', { p_request_id: cid, p_attachment_id: a.data.id })).data).toMatchObject({ ok: true });
    expect((await w.running.session.client.rpc('rd_attachment_commit', { p_request_id: cid, p_attachment_id: a.data.id })).data).toMatchObject({ ok: true });
    path = a.data.path;
    const d = await detail(w.running.session);
    expect(d.data.photos).toEqual([expect.objectContaining({ id: a.data.id, reading_id: cur, path })]);
  });

  test('the owner and the Unit Admin download it; nobody else does', async () => {
    expect((await w.running.session.client.storage.from('attachments').download(path)).error).toBeNull();
    expect((await w.ua.client.storage.from('attachments').download(path)).error).toBeNull();
    expect((await w.idle.session.client.storage.from('attachments').download(path)).error).not.toBeNull();
    expect((await uaOther.client.storage.from('attachments').download(path)).error).not.toBeNull();
    expect((await sa.client.storage.from('attachments').download(path)).error).not.toBeNull();
    expect((await sa.client.storage.from('attachments').list(`tenant/${w.org.id}`)).data ?? []).toEqual([]);
    expect((await anon().storage.from('attachments').download(path)).error).not.toBeNull();
  });

  test('another supervisor and another tenant cannot begin a photo for the reading; Storage refuses a stray path', async () => {
    const cur = (await detail(w.running.session)).data.opening.id as string;
    const a = { p_request_id: uuid(), p_reading_id: cur, p_mime: 'image/jpeg', p_size: 10, p_sha256: sha256Hex(Buffer.from('x')) };
    expect((await w.idle.session.client.rpc('rd_attachment_begin', a)).data).toEqual(DENIED);
    expect((await uaOther.client.rpc('rd_attachment_begin', { ...a, p_request_id: uuid() })).data).toEqual(DENIED);
    expect((await sa.client.rpc('rd_attachment_begin', { ...a, p_request_id: uuid() })).data).toEqual(DENIED);
    const stray = await w.running.session.client.storage.from('attachments').upload(`tenant/${w.org.id}/reading/${cur}/${uuid()}.jpg`, TINY_JPEG, { contentType: 'image/jpeg' });
    expect(stray.error).not.toBeNull();
  });

  test('begin refuses a type that is not an image and a photo over 5 MB; commit refuses a missing object', async () => {
    const cur = (await detail(w.running.session)).data.opening.id as string;
    const pdf = await w.running.session.client.rpc('rd_attachment_begin', { p_request_id: uuid(), p_reading_id: cur, p_mime: 'application/pdf', p_size: 10, p_sha256: sha256Hex(Buffer.from('x')) });
    expect(pdf.error?.code).toBe('P0001');
    const big = await w.running.session.client.rpc('rd_attachment_begin', { p_request_id: uuid(), p_reading_id: cur, p_mime: 'image/jpeg', p_size: 5 * 1024 * 1024 + 1, p_sha256: sha256Hex(Buffer.from('x')) });
    expect(big.error?.code).toBe('P0001');
    const none = await w.running.session.client.rpc('rd_attachment_begin', { p_request_id: uuid(), p_reading_id: cur, p_mime: 'image/jpeg', p_size: 100, p_sha256: sha256Hex(Buffer.from('y')) });
    const miss = await w.running.session.client.rpc('rd_attachment_commit', { p_request_id: uuid(), p_attachment_id: none.data.id });
    expect(miss.error?.code).toBe('P0001');
  });
});
