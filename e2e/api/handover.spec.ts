// 08 through the real stack (PostgREST RPC over HTTP). Own tenant "e2e api org handover" with the handover gate switched on (a directly inserted tenant is not
// gated) and throwaway E2E-<random> machine, product and shifts (07's clock-derived world: the running shift's supervisor owns the machine and inherits the
// issues the idle supervisor reported before the last shift boundary). The enforced fixture tenant org H supplies the cross-tenant attacker (denied calls only
// write audit rows; its checklist is left for the Android flow).
import { expect, test } from '@playwright/test';
import {
  FIXTURE_PASSWORD, SA_FIXTURES, auditRows, customOrg, enforceHandover, requireApi, seedInheritedIssue, service, setupIssueWorld, signIn, teardownIssueWorld, uuid,
  type IssueWorld, type Session,
} from './helpers';

const ORG = customOrg('20000000-0000-4000-a000-0000000000bc', 'e2e api org handover', ['+919000077771', '+919000077772', '+919000077773', '+919000077774']);
const FIXTURE_SUP_H = '+919000000022';
const DENIED = { ok: false, code: 'not_allowed' };

let w: IssueWorld;
let shiftId: string;
let productId: string;
let outsider: Session; // a supervisor of the fixture tenant org H
// A Super Admin session is signed in right before it is used: platform.spec re-provisions the shared fixture SA, which invalidates older sessions.
let sa: Session;
const saNow = async () => (sa = await signIn(SA_FIXTURES.sa2.phone, FIXTURE_PASSWORD));
let issue1: string; // acknowledged
let issue2: string; // refused
let issue3: string; // answered after the others (replay checks)
const run = Math.random().toString(36).slice(2, 8).toUpperCase();

const sup = () => w.running.session;
const other = () => w.idle.session;
const date = () => w.today;
const args = (issue: string, over: Record<string, unknown> = {}) => ({ p_request_id: uuid(), p_issue_id: issue, p_shift_id: shiftId, p_shift_date: date(), ...over });
const ack = (s: Session, issue: string, over: Record<string, unknown> = {}) => s.client.rpc('ho_acknowledge', { ...args(issue), p_remark: null, ...over });
const refuse = (s: Session, issue: string, over: Record<string, unknown> = {}) => s.client.rpc('ho_refuse', { ...args(issue), p_reason: 'Not handed over to me', ...over });
const declare = (s: Session, over: Record<string, unknown> = {}) => s.client.rpc('ho_declare', { p_request_id: uuid(), p_shift_id: shiftId, p_shift_date: date(), ...over });
const opening = (s: Session) =>
  s.client.rpc('rd_opening', { p_request_id: uuid(), p_machine_id: w.machine.id, p_shift_id: shiftId, p_shift_date: date(), p_product_id: productId, p_counter: 1000, p_remarks: null });
const guardField = (e: { details?: string } | null) => JSON.parse(e!.details!).field;

test.describe.configure({ mode: 'serial' });
test.beforeAll(async () => {
  requireApi();
  w = await setupIssueWorld(ORG, 'E2E Handover Plant');
  shiftId = w.running.session === w.sup2 ? w.shiftPm : w.shiftAm;
  await enforceHandover(w);
  outsider = await signIn(FIXTURE_SUP_H, FIXTURE_PASSWORD);
  issue1 = await seedInheritedIssue(w, 'high', `E2E api inherited leak ${run}`);
  issue2 = await seedInheritedIssue(w, 'medium', `E2E api inherited noise ${run}`);
  issue3 = await seedInheritedIssue(w, 'low', `E2E api inherited guard ${run}`);
  const p = await w.ua.client.rpc('pm_save_product', { p_request_id: uuid(), p_id: null, p_code: `E2E-${run}`, p_description: 'E2E handover part', p_uom: 'pcs' });
  expect(p.data).toMatchObject({ ok: true });
  productId = p.data.id;
  const t = await w.ua.client.rpc('pm_set_target', { p_request_id: uuid(), p_machine_id: w.machine.id, p_product_id: productId, p_pieces: 1000, p_effective_from: w.today });
  expect(t.data).toMatchObject({ ok: true });
});
test.afterAll(() => teardownIssueWorld(w));

test.describe('The checklist (AC-1)', () => {
  test('the running supervisor sees the three inherited issues, the idle supervisor none, and only a supervisor may read it', async () => {
    const c = await sup().client.rpc('handover_checklist', {});
    expect(c.error).toBeNull();
    const occ = c.data.occurrences.find((o: { shift: { id: string } }) => o.shift.id === shiftId);
    expect(occ).toMatchObject({ enforced: true, declared: false, pending_count: 3, allowed_actions: [] });
    const items = occ.machines.flatMap((m: { items: { id: string; state: string; allowed_actions: string[] }[] }) => m.items);
    expect(items.map((i: { id: string }) => i.id).sort()).toEqual([issue1, issue2, issue3].sort());
    for (const i of items) expect(i).toMatchObject({ state: 'pending', allowed_actions: expect.arrayContaining(['acknowledge', 'refuse']) });
    expect(c.data.pending_total).toBeGreaterThanOrEqual(3);

    const idle = await other().client.rpc('handover_checklist', {});
    const idleOcc = idle.data.occurrences.find((o: { shift: { id: string } }) => o.shift.id === shiftId);
    expect(idleOcc).toBeUndefined();

    expect((await w.ua.client.rpc('handover_checklist', {})).data).toEqual(DENIED);
    await saNow();
    expect((await sa.client.rpc('handover_checklist', {})).data).toEqual(DENIED);
  });
});

test.describe('The opening waits for the declaration (AC-3, AC-11)', () => {
  test('rd_opening is refused with handover_pending before the declaration, for the owner only', async () => {
    const r = await opening(sup());
    expect(r.error?.code).toBe('P0001');
    expect(r.error?.message).toBe('Complete your handover checklist first');
    expect(guardField(r.error)).toBe('handover_pending');
    expect((await service().from('production_reading').select('id').eq('machine_id', w.machine.id)).data).toEqual([]);
  });
});

test.describe('Answering (AC-2, AC-4, AC-5, AC-7, AC-13)', () => {
  test('declaring is refused while issues are unanswered', async () => {
    const r = await declare(sup());
    expect(r.error?.code).toBe('P0001');
    expect(guardField(r.error)).toBe('items_pending');
  });

  test('another supervisor, a Unit Admin, a Super Admin and another tenant are denied; denials are audited', async () => {
    await saNow();
    expect((await ack(other(), issue1)).data).toEqual(DENIED); // not the owner of the machine in this occurrence (AC-13)
    expect((await ack(w.ua, issue1)).data).toEqual(DENIED);
    expect((await ack(sa, issue1)).data).toEqual(DENIED);
    expect((await ack(outsider, issue1)).data).toEqual(DENIED);
    expect((await refuse(outsider, issue1)).data).toEqual(DENIED);
    expect((await declare(w.ua)).data).toEqual(DENIED);
    expect((await auditRows({ action: 'access.denied', actor: outsider.userId })).length).toBeGreaterThanOrEqual(2);
    expect((await auditRows({ action: 'access.denied', actor: sa.userId })).length).toBeGreaterThanOrEqual(1);
    expect((await service().from('issue_acknowledgement').select('id').eq('issue_id', issue1)).data).toEqual([]);
  });

  test('acknowledge is idempotent by request id, tied to its RPC, and recorded once', async () => {
    const rid = uuid();
    const a = await ack(sup(), issue1, { p_request_id: rid, p_remark: 'Seen' });
    expect(a.data).toMatchObject({ ok: true });
    const again = await ack(sup(), issue1, { p_request_id: rid, p_remark: 'Seen' });
    expect(again.data).toMatchObject({ ok: true, already: true, id: a.data.id });
    const clash = await refuse(sup(), issue2, { p_request_id: rid });
    expect(clash.error?.code).toBe('P0001'); // a request id belongs to one RPC
    const second = await ack(sup(), issue1);
    expect(second.error?.code).toBe('P0001');
    expect(guardField(second.error)).toBe('already_recorded');
    expect((await service().from('issue_acknowledgement').select('id').eq('issue_id', issue1)).data).toHaveLength(1);
    expect((await auditRows({ action: 'handover.acknowledged', requestId: rid })).length).toBe(1);
  });

  test('a refusal needs a reason and escalates the issue without changing the owner', async () => {
    const empty = await refuse(sup(), issue2, { p_reason: '  ' });
    expect(empty.error?.code).toBe('P0001');
    const before = await service().from('machine_issue').select('accountable_owner_id').eq('id', issue2).single();
    const r = await refuse(sup(), issue2);
    expect(r.data).toMatchObject({ ok: true });
    const after = await service().from('machine_issue').select('accountable_owner_id, escalated_at').eq('id', issue2).single();
    expect(after.data?.accountable_owner_id).toBe(before.data?.accountable_owner_id);
    expect(after.data?.escalated_at).not.toBeNull();
  });

  test('notes are limited to 300 characters and stored for the next shift', async () => {
    expect((await sup().client.rpc('ho_add_note', { ...args(issue3), p_note: 'x'.repeat(301) })).error?.code).toBe('P0001');
    const n = await sup().client.rpc('ho_add_note', { ...args(issue3), p_note: 'Check the guard door hinge' });
    expect(n.data).toMatchObject({ ok: true });
    const c = await sup().client.rpc('handover_checklist', {});
    const item = c.data.occurrences.find((o: { shift: { id: string } }) => o.shift.id === shiftId).machines[0].items.find((i: { id: string }) => i.id === issue3);
    expect(item.note).toMatchObject({ note: 'Check the guard door hinge' });
  });

  test('declaring works once every issue is answered, and the opening is then accepted', async () => {
    expect((await ack(sup(), issue3)).data).toMatchObject({ ok: true });
    const rid = uuid();
    const d = await declare(sup(), { p_request_id: rid });
    expect(d.data).toMatchObject({ ok: true });
    expect(await declare(sup(), { p_request_id: rid })).toMatchObject({ data: { ok: true, already: true } });
    const again = await declare(sup());
    expect(guardField(again.error)).toBe('already_declared');
    const o = await opening(sup());
    expect(o.error).toBeNull();
    expect(o.data).toMatchObject({ ok: true });
    const c = await sup().client.rpc('handover_checklist', {});
    expect(c.data.occurrences.find((x: { shift: { id: string } }) => x.shift.id === shiftId)).toMatchObject({ declared: true, pending_count: 0 });
  });
});

test.describe('The Unit Admin: exceptions and settings (AC-5, AC-8, AC-9)', () => {
  test('the refusal is an alert, a supervisor cannot record the exception, the Unit Admin can, and the alert clears', async () => {
    const a = await w.ua.client.rpc('handover_alerts', {});
    expect(a.data.exceptions.map((e: { issue_id: string }) => e.issue_id)).toContain(issue2);
    expect(a.data.alert_count).toBeGreaterThanOrEqual(1);
    expect((await sup().client.rpc('handover_alerts', {})).data).toEqual(DENIED);

    const body = { ...args(issue2), p_reason: 'Reassigned to the running supervisor', p_owner_id: sup().userId };
    expect((await sup().client.rpc('ho_exception', body)).data).toEqual(DENIED);
    expect((await outsider.client.rpc('ho_exception', body)).data).toEqual(DENIED);
    expect((await w.ua.client.rpc('ho_exception', { ...body, p_reason: '' })).error?.code).toBe('P0001');
    expect((await w.ua.client.rpc('ho_exception', { ...body, p_owner_id: w.ua.userId })).error?.code).toBe('P0001'); // not a supervisor
    const ok = await w.ua.client.rpc('ho_exception', body);
    expect(ok.data).toMatchObject({ ok: true, kept: false });
    expect((await w.ua.client.rpc('ho_exception', { ...body, p_request_id: uuid() })).error?.code).toBe('P0001'); // nothing is waiting any more

    const own = await service().from('issue_ownership_history').select('new_owner, source').eq('issue_id', issue2).order('at', { ascending: true });
    expect(own.data?.map((r) => r.source)).toEqual(['report', 'reassign']);
    const after = await w.ua.client.rpc('handover_alerts', {});
    expect(after.data.exceptions.map((e: { issue_id: string }) => e.issue_id)).not.toContain(issue2);
  });

  test('the overdue minutes are 15 to 480, set by a Unit Admin only, and audited', async () => {
    const set = (s: Session, minutes: number) => s.client.rpc('ho_set_overdue', { p_request_id: uuid(), p_minutes: minutes });
    expect((await set(w.ua, 14)).error?.code).toBe('P0001');
    expect((await set(w.ua, 481)).error?.code).toBe('P0001');
    expect((await set(sup(), 30)).data).toEqual(DENIED);
    await saNow();
    expect((await set(sa, 30)).data).toEqual(DENIED);
    expect((await set(outsider, 30)).data).toEqual(DENIED);
    const ok = await set(w.ua, 30);
    expect(ok.data).toMatchObject({ ok: true, overdue_minutes: 30 });
    const row = await w.ua.client.from('handover_setting').select('overdue_minutes, required').single();
    expect(row.data).toEqual({ overdue_minutes: 30, required: true });
    expect((await auditRows({ action: 'handover.setting_updated', tenant: w.org.id })).length).toBeGreaterThanOrEqual(1);
    // A supervisor reads the setting only through the checklist: no table access.
    expect((await sup().client.from('handover_setting').select('*')).data).toEqual([]);
    expect((await outsider.client.from('handover_setting').select('*')).data).toEqual([]);
  });

  test('the append-only tables cannot be changed by a client', async () => {
    await w.ua.client.from('issue_acknowledgement').delete().eq('issue_id', issue1); // refused by privileges or filtered by RLS: either way nothing is removed
    expect((await service().from('issue_acknowledgement').select('id').eq('issue_id', issue1)).data).toHaveLength(1);
    const upd = await service().from('issue_acknowledgement').update({ remark: 'changed' }).eq('issue_id', issue1).select('id');
    expect(upd.error).not.toBeNull();
  });
});
