// 05 AC-1..12 through the real stack (PostgREST + RPC over HTTP). Org "e2e api org shifts" (own tenant, phones in the throwaway block) is
// the actor; the fixture orgs A and U supply the other tenants (read-only here). Throwaway shifts/machines are named E2E-<random> and are
// retired in afterAll (history is append-only, so they cannot be deleted).
import { expect, test } from '@playwright/test';
import { FIXTURE_PASSWORD, anon, auditRows, customOrg, provisionOrg, requireApi, service, signIn, uuid, type Session } from './helpers';

const S = customOrg('20000000-0000-4000-a000-0000000000b5', 'e2e api org shifts', ['+919000077701', '+919000077702', '+919000077703', '+919000077704']);
const FIXTURE_SUP_A = '+919000000002';
const FIXTURE_UA_U = '+919000000006';
const FIXTURE_SUP_U = '+919000000008';
const DENIED = { ok: false, code: 'not_allowed' };
const name = () => `E2E-${Math.random().toString(36).slice(2, 10).toUpperCase()}`;
const addDays = (iso: string, n: number) => {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};
const rpc = (s: Session, fn: string, args: Record<string, unknown>) => s.client.rpc(fn, args);

let ua: Session;
let sup: Session;
let uaOther: Session; // Unit Admin of fixture org U (a different tenant)
let supA: Session;
let supU: Session;
let today: string;
let tomorrow: string;
let shiftAm: string; // 00:00-12:00
let shiftPm: string; // 12:00-00:00 (together they cover the whole day)
let m1: { id: string; code: string };
let m2: { id: string; code: string };
let productId: string;
const createdMachines: string[] = [];
const createdShifts: string[] = [];

async function newShift(start: string, end: string): Promise<string> {
  const r = await rpc(ua, 'sh_save_shift', { p_request_id: uuid(), p_id: null, p_name: name(), p_start: start, p_end: end });
  expect(r.error).toBeNull();
  expect(r.data).toMatchObject({ ok: true });
  createdShifts.push(r.data.id);
  return r.data.id as string;
}
async function newMachine(): Promise<{ id: string; code: string }> {
  const code = name();
  const r = await rpc(ua, 'pm_save_machine', { p_request_id: uuid(), p_id: null, p_code: code, p_name: 'E2E machine', p_asset_tag: '', p_make: '', p_model: '', p_controller: '', p_line_id: null, p_status: 'active' });
  expect(r.data).toMatchObject({ ok: true });
  createdMachines.push(r.data.id);
  return { id: r.data.id as string, code };
}
const assign = (shift: string, machines: string[], from: string, requestId = uuid(), supervisor = sup.userId) =>
  rpc(ua, 'sh_assign', { p_request_id: requestId, p_shift_id: shift, p_supervisor_id: supervisor, p_machine_ids: machines, p_from: from, p_until: null });
/** Codes of every machine across the occurrences my_shift returned (R3), each once. */
const codesOf = (data: { occurrences: { machines: { code: string }[] }[] }) => [...new Set(data.occurrences.flatMap((o) => o.machines.map((m) => m.code)))].sort();
/**
 * R1: a plan change can't start on an occurrence that has already started, and these shifts (00:00-12:00, 12:00-00:00) always have one started today.
 * So the standing plan is seeded directly as service role (like fixtures-reset does), dated today; the RPC is then exercised from tomorrow.
 */
async function seedPlan(shift: string, machine: string, from: string) {
  const r = await service().from('assignment_version').insert({ tenant_id: S.id, shift_id: shift, machine_id: machine, supervisor_id: sup.userId, effective_from: from, recorded_by: ua.userId }).select('id');
  expect(r.error).toBeNull();
}

test.beforeAll(async () => {
  requireApi();
  await provisionOrg(S);
  ua = await signIn(S.users.ua1.phone, FIXTURE_PASSWORD);
  sup = await signIn(S.users.sup.phone, FIXTURE_PASSWORD);
  uaOther = await signIn(FIXTURE_UA_U, FIXTURE_PASSWORD);
  supA = await signIn(FIXTURE_SUP_A, FIXTURE_PASSWORD);
  supU = await signIn(FIXTURE_SUP_U, FIXTURE_PASSWORD);
  const site = await rpc(ua, 'pm_save_site', { p_request_id: uuid(), p_name: 'E2E Shifts Plant', p_timezone: 'Asia/Kolkata' });
  expect(site.error).toBeNull();
  // Leftovers of an aborted run must not decide which shift is "running".
  const old = await ua.client.from('shift').select('id').is('retired_at', null);
  for (const row of old.data ?? []) await rpc(ua, 'sh_set_shift_retired', { p_request_id: uuid(), p_id: row.id, p_retired: true });
  const t = await ua.client.from('plant_today').select('plant_date').single();
  today = t.data!.plant_date as string;
  tomorrow = addDays(today, 1);
  shiftAm = await newShift('00:00', '12:00');
  shiftPm = await newShift('12:00', '00:00');
  m1 = await newMachine();
  m2 = await newMachine();
  const prod = await rpc(ua, 'pm_save_product', { p_request_id: uuid(), p_code: name(), p_id: null, p_description: 'E2E product', p_uom: 'pcs' });
  expect(prod.data).toMatchObject({ ok: true });
  productId = prod.data.id;
  for (const s of [shiftAm, shiftPm]) await seedPlan(s, m1.id, today);
});

test.afterAll(async () => {
  if (!ua) return;
  for (const id of createdShifts) await rpc(ua, 'sh_set_shift_retired', { p_request_id: uuid(), p_id: id, p_retired: true });
  for (const id of createdMachines) await rpc(ua, 'pm_set_machine_retired', { p_request_id: uuid(), p_id: id, p_retired: true });
  await rpc(ua, 'pm_set_product_retired', { p_request_id: uuid(), p_id: productId, p_retired: true });
});

test.describe('Supervisor sees only their own work (AC-9, AC-11)', () => {
  test('my_shift returns the machines of the caller and no other tenant or supervisor', async () => {
    const mine = await rpc(sup, 'my_shift', {});
    expect(mine.error).toBeNull();
    expect(mine.data).toMatchObject({ ok: true, state: 'running' });
    expect(mine.data.occurrences).toHaveLength(1); // only one of the two shifts runs at a time
    expect([shiftAm, shiftPm]).toContain(mine.data.occurrences[0].shift.id);
    expect(mine.data.occurrences[0].running).toBe(true);
    expect(codesOf(mine.data)).toEqual([m1.code]); // m2 has no plan

    const a = await rpc(supA, 'my_shift', {});
    expect(a.data).toMatchObject({ ok: true, state: 'running' });
    expect(codesOf(a.data)).toEqual(['FX-MA1']);

    const u = await rpc(supU, 'my_shift', {});
    expect(u.data).toMatchObject({ ok: true });
    expect(codesOf(u.data)).not.toContain(m1.code);
    for (const c of codesOf(u.data)) expect(c).not.toBe('FX-MA1');
  });

  test('a supervisor reads shifts but none of the planning tables, and cannot write any of them', async () => {
    expect((await sup.client.from('shift').select('id').in('id', [shiftAm, shiftPm])).data).toHaveLength(2);
    for (const table of ['assignment_version', 'assignment_cover', 'target_override_version']) {
      const r = await sup.client.from(table).select('*');
      expect(r.data ?? [], table).toEqual([]);
    }
    expect((await ua.client.from('assignment_version').select('id').eq('machine_id', m1.id)).data).toHaveLength(2); // the Unit Admin does see the plan
    const row = { tenant_id: S.id, shift_id: shiftAm, machine_id: m2.id, supervisor_id: sup.userId, effective_from: today };
    expect((await sup.client.from('assignment_version').insert(row)).error?.code).toBe('42501');
    expect((await sup.client.from('shift').insert({ tenant_id: S.id, name: 'Nope' })).error?.code).toBe('42501');
    expect((await ua.client.from('assignment_version').insert(row)).error?.code).toBe('42501'); // writes only through the RPCs
  });

  test('every shift RPC denies a supervisor with the generic answer, each audited as access.denied (role)', async () => {
    const before = (await auditRows({ action: 'access.denied', actor: sup.userId })).length;
    const calls: [string, Record<string, unknown>][] = [
      ['sh_save_shift', { p_request_id: uuid(), p_id: null, p_name: 'Nope', p_start: '06:00', p_end: '14:00' }],
      ['sh_set_shift_retired', { p_request_id: uuid(), p_id: shiftAm, p_retired: true }],
      ['sh_assign', { p_request_id: uuid(), p_shift_id: shiftAm, p_supervisor_id: sup.userId, p_machine_ids: [m2.id], p_from: today, p_until: null }],
      ['sh_unassign', { p_request_id: uuid(), p_shift_id: shiftAm, p_machine_ids: [m1.id], p_from: tomorrow }],
      ['sh_cover', { p_request_id: uuid(), p_shift_id: shiftAm, p_shift_date: tomorrow, p_machine_ids: [m1.id], p_supervisor_id: null, p_reason: 'Nope' }],
      ['sh_set_target_override', { p_request_id: uuid(), p_machine_id: m1.id, p_product_id: productId, p_shift_id: shiftAm, p_pieces: 5, p_effective_from: tomorrow }],
      ['sh_end_target_override', { p_request_id: uuid(), p_machine_id: m1.id, p_product_id: productId, p_shift_id: shiftAm, p_effective_from: tomorrow }],
      ['shift_board', { p_shift_id: shiftAm, p_date: null }],
    ];
    for (const [fn, args] of calls) {
      const r = await rpc(sup, fn, args);
      expect(r.error, fn).toBeNull();
      expect(r.data, fn).toEqual(DENIED);
    }
    const events = (await auditRows({ action: 'access.denied', actor: sup.userId })).slice(before);
    expect(events).toHaveLength(8);
    for (const e of events) expect(e).toMatchObject({ tenant_id: S.id, reason: 'role', actor_role: 'supervisor' });
    expect(events.map((e) => e.source).sort()).toEqual(calls.map(([fn]) => `rpc:${fn}`).sort());
    expect((await service().from('assignment_version').select('id').eq('machine_id', m2.id)).data).toEqual([]);
    expect((await service().from('shift').select('id').eq('tenant_id', S.id).eq('name', 'Nope')).data).toEqual([]);
  });
});

test.describe('Unit Admin plans their own tenant only (AC-5..10)', () => {
  test('assign is idempotent per request id and the board shows plan, cover and unassigned', async () => {
    // R1: today's occurrence of this shift has started, so a plan change from today is refused and nothing is written.
    const late = await assign(shiftAm, [m2.id], today);
    expect(late.error?.message ?? JSON.stringify(late.data)).toContain('already started');
    expect((await service().from('assignment_version').select('id').eq('machine_id', m2.id)).data).toEqual([]);

    const rid = uuid();
    const first = await assign(shiftAm, [m2.id], tomorrow, rid);
    expect(first.data).toMatchObject({ ok: true });
    const again = await assign(shiftAm, [m2.id], tomorrow, rid);
    expect(again.data).toMatchObject({ ok: true });
    expect((await service().from('assignment_version').select('id').eq('machine_id', m2.id)).data).toHaveLength(1);

    const board = await rpc(ua, 'shift_board', { p_shift_id: shiftAm, p_date: tomorrow });
    expect(board.data).toMatchObject({ ok: true, shift_date: tomorrow });
    const row = (code: string) => board.data.machines.find((m: { code: string }) => m.code === code);
    expect(row(m1.code)).toMatchObject({ owner_id: sup.userId, source: 'plan', plan_owner_id: sup.userId });
    expect(row(m2.code)).toMatchObject({ owner_id: sup.userId, source: 'plan' });

    // R2: no date = the current occurrence of a running shift (today's, for 00:00-12:00 and 12:00-00:00).
    const dflt = await rpc(ua, 'shift_board', { p_shift_id: shiftAm, p_date: null });
    expect(dflt.data).toMatchObject({ ok: true, shift_date: today });

    // Cover tomorrow only: m1 goes to nobody; the plan is untouched (R5: the board still names the plan owner).
    const cover = await rpc(ua, 'sh_cover', { p_request_id: uuid(), p_shift_id: shiftAm, p_shift_date: tomorrow, p_machine_ids: [m1.id], p_supervisor_id: null, p_reason: 'E2E leave' });
    expect(cover.data).toMatchObject({ ok: true });
    const next = await rpc(ua, 'shift_board', { p_shift_id: shiftAm, p_date: tomorrow });
    expect(next.data.machines.find((m: { code: string }) => m.code === m1.code)).toMatchObject({ owner_id: null, source: 'cover', reason: 'E2E leave', plan_owner_id: sup.userId });
    expect(next.data.unassigned_count).toBeGreaterThanOrEqual(1);
    const now = await rpc(ua, 'shift_board', { p_shift_id: shiftAm, p_date: today });
    expect(now.data.machines.find((m: { code: string }) => m.code === m1.code)).toMatchObject({ owner_id: sup.userId, source: 'plan' });
  });

  test('R4: re-planning supersedes a scheduled change instead of being refused', async () => {
    const later = addDays(tomorrow, 10);
    expect((await assign(shiftPm, [m2.id], later, uuid(), sup.userId)).data).toMatchObject({ ok: true });
    const other = await assign(shiftPm, [m2.id], tomorrow, uuid(), sup.userId);
    expect(other.data).toMatchObject({ ok: true });
    const rows = await service().from('assignment_version').select('effective_from, supervisor_id').eq('machine_id', m2.id).eq('shift_id', shiftPm).order('effective_from');
    expect((rows.data ?? []).map((r) => r.effective_from)).toEqual([tomorrow, later, later]); // the later version is re-appended, so it still resolves to the new supervisor
  });

  test('a shift target override is stored per shift, and ending it is a new row (append-only)', async () => {
    const set = await rpc(ua, 'sh_set_target_override', { p_request_id: uuid(), p_machine_id: m1.id, p_product_id: productId, p_shift_id: shiftPm, p_pieces: 777, p_effective_from: tomorrow });
    expect(set.data).toMatchObject({ ok: true });
    const end = await rpc(ua, 'sh_end_target_override', { p_request_id: uuid(), p_machine_id: m1.id, p_product_id: productId, p_shift_id: shiftPm, p_effective_from: addDays(tomorrow, 5) });
    expect(end.data).toMatchObject({ ok: true });
    const rows = await ua.client.from('target_override_version').select('pieces_per_shift, effective_from').eq('machine_id', m1.id).eq('shift_id', shiftPm).order('effective_from');
    expect(rows.data).toEqual([{ pieces_per_shift: 777, effective_from: tomorrow }, { pieces_per_shift: null, effective_from: addDays(tomorrow, 5) }]);
    const upd = await service().from('target_override_version').update({ pieces_per_shift: 1 }).eq('machine_id', m1.id);
    expect(upd.error).not.toBeNull(); // append-only, even for the service role
  });

  test('a Unit Admin of another tenant is denied (cross_tenant, audited under their own tenant) and reads none of this plan', async () => {
    const before = (await auditRows({ action: 'access.denied', actor: uaOther.userId })).length;
    const a = await rpc(uaOther, 'sh_assign', { p_request_id: uuid(), p_shift_id: shiftAm, p_supervisor_id: supU.userId, p_machine_ids: [m1.id], p_from: today, p_until: null });
    const b = await rpc(uaOther, 'shift_board', { p_shift_id: shiftAm, p_date: null });
    const c = await rpc(uaOther, 'sh_set_shift_retired', { p_request_id: uuid(), p_id: shiftAm, p_retired: true });
    for (const r of [a, b, c]) expect(r.data).toEqual(DENIED);
    const events = (await auditRows({ action: 'access.denied', actor: uaOther.userId })).slice(before).filter((e) => e.entity_id === shiftAm);
    expect(events.length).toBeGreaterThanOrEqual(2);
    for (const e of events) expect(e).toMatchObject({ reason: 'cross_tenant', actor_role: 'unit_admin' });
    for (const e of events) expect(e.tenant_id).not.toBe(S.id);

    expect((await uaOther.client.from('shift').select('id').eq('tenant_id', S.id)).data).toEqual([]);
    for (const table of ['assignment_version', 'assignment_cover', 'target_override_version']) {
      expect((await uaOther.client.from(table).select('id').eq('tenant_id', S.id)).data ?? [], table).toEqual([]);
    }
    // nothing changed
    expect((await service().from('shift').select('retired_at').eq('id', shiftAm).single()).data!.retired_at).toBeNull();
  });

  test('a user with a temporary password is denied and a signed-out caller cannot call the RPCs', async () => {
    const fresh = await signIn(S.users.fresh.phone, FIXTURE_PASSWORD);
    expect((await rpc(fresh, 'my_shift', {})).data).toEqual(DENIED);
    const anonCall = await anon().rpc('my_shift', {});
    expect(anonCall.error).not.toBeNull();
  });
});
