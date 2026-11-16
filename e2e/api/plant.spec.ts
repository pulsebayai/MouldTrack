// 04 AC-5..12 through the real stack (PostgREST + RPC over HTTP): writes only via pm_* RPCs, role and tenant denials audited,
// cross-tenant reads empty, append-only targets, idempotent repeats. Org 8 "e2e api org 8" is the actor; the fixture orgs A and B
// (read-only plants from seed / fixtures-reset) are the other tenants. Plant rows are throwaway (E2E-<random> codes); rows that
// have targets cannot be deleted (append-only), so they are retired in afterAll.
import { expect, test } from '@playwright/test';
import { FIXTURE_PASSWORD, anon, auditRows, orgDef, provisionOrg, requireApi, service, signIn, uuid, type Session } from './helpers';

const R = orgDef(8, 'e2e api org 8');
let ua: Session;
let sup: Session;
let fresh: Session;
let today: string;
let victimMachine: string; // a machine of fixture org A
let victimProduct: string;
let victimTenant: string;
const code = () => `E2E-${Math.random().toString(36).slice(2, 10).toUpperCase()}`;
const addDays = (iso: string, n: number) => {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};
const rpc = (s: Session, fn: string, args: Record<string, unknown>) => s.client.rpc(fn, args);
const DENIED = { ok: false, code: 'not_allowed' };

test.beforeAll(async () => {
  requireApi();
  await provisionOrg(R);
  ua = await signIn(R.users.ua1.phone, FIXTURE_PASSWORD);
  sup = await signIn(R.users.sup.phone, FIXTURE_PASSWORD);
  fresh = await signIn(R.users.fresh.phone, FIXTURE_PASSWORD);
  const site = await rpc(ua, 'pm_save_site', { p_request_id: uuid(), p_name: 'E2E API Plant', p_timezone: 'Asia/Kolkata' });
  expect(site.error).toBeNull();
  const t = await ua.client.from('plant_today').select('plant_date').single();
  today = t.data!.plant_date as string;
  const sb = service();
  const m = await sb.from('machine').select('id, tenant_id').eq('code', 'FX-MA1').single();
  const p = await sb.from('product').select('id').eq('code', 'FX-PA1').single();
  victimMachine = m.data!.id as string;
  victimTenant = m.data!.tenant_id as string;
  victimProduct = p.data!.id as string;
});

test.afterAll(async () => {
  const sb = service();
  for (const table of ['machine', 'product'] as const) {
    const rows = (await sb.from(table).select('id').eq('tenant_id', R.id).like('code', 'E2E-%')).data ?? [];
    for (const r of rows) {
      const col = table === 'machine' ? 'machine_id' : 'product_id';
      const used = (await sb.from('target_version').select('id').eq(col, r.id).limit(1)).data ?? [];
      if (used.length) await sb.from(table).update({ retired_at: new Date().toISOString() }).eq('id', r.id);
      else await sb.from(table).delete().eq('id', r.id);
    }
  }
  await sb.from('line').delete().eq('tenant_id', R.id).like('name', 'E2E-%');
});

test.describe('AC-10 role', () => {
  test('a supervisor gets the generic denial from every write RPC, each audited as access.denied (role)', async () => {
    const before = (await auditRows({ action: 'access.denied', actor: sup.userId })).length;
    const calls: [string, Record<string, unknown>][] = [
      ['pm_save_site', { p_name: 'Nope', p_timezone: 'UTC' }],
      ['pm_save_line', { p_id: null, p_name: 'Nope' }],
      ['pm_archive_line', { p_id: uuid() }],
      ['pm_save_machine', { p_id: null, p_code: 'NOPE', p_name: 'Nope', p_asset_tag: '', p_make: '', p_model: '', p_controller: '', p_line_id: null, p_status: 'active' }],
      ['pm_set_machine_retired', { p_id: uuid(), p_retired: true }],
      ['pm_save_product', { p_id: null, p_code: 'NOPE', p_description: 'Nope', p_uom: 'pcs' }],
      ['pm_set_product_retired', { p_id: uuid(), p_retired: true }],
      ['pm_set_target', { p_machine_id: uuid(), p_product_id: uuid(), p_pieces: 5, p_effective_from: addDays(today, 5) }],
      ['pm_end_target', { p_machine_id: uuid(), p_product_id: uuid(), p_effective_from: addDays(today, 5) }],
    ];
    for (const [fn, args] of calls) {
      const r = await rpc(sup, fn, { p_request_id: uuid(), ...args });
      expect(r.error, fn).toBeNull();
      expect(r.data, fn).toEqual(DENIED);
    }
    const events = (await auditRows({ action: 'access.denied', actor: sup.userId })).slice(before);
    expect(events).toHaveLength(9);
    for (const e of events) expect(e).toMatchObject({ tenant_id: R.id, reason: 'role', actor_role: 'supervisor', request_id: null });
    expect((await service().from('machine').select('id').eq('tenant_id', R.id).eq('code', 'NOPE')).data).toEqual([]);
  });

  test('a supervisor reads the plant of their tenant but cannot change it directly', async () => {
    expect((await sup.client.from('site').select('id')).data).toHaveLength(1);
    expect((await sup.client.from('machine').select('id')).error).toBeNull();
    const ins = await sup.client.from('machine').insert({ tenant_id: R.id, site_id: uuid(), code: 'X', name: 'X' });
    expect(ins.error?.code).toBe('42501');
  });

  test('a user with a temporary password is denied and sees no plant data', async () => {
    const before = (await auditRows({ action: 'access.denied', actor: fresh.userId })).length;
    const r = await rpc(fresh, 'pm_save_product', { p_request_id: uuid(), p_id: null, p_code: code(), p_description: 'Nope', p_uom: 'pcs' });
    expect(r.data).toEqual(DENIED);
    const events = (await auditRows({ action: 'access.denied', actor: fresh.userId })).slice(before);
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ reason: 'must_change_password', tenant_id: R.id });
    expect((await fresh.client.from('site').select('id')).data).toEqual([]);
    expect((await fresh.client.from('machine').select('id')).data).toEqual([]);
  });

  test('without a session nothing is readable or callable', async () => {
    const a = anon();
    expect((await a.from('machine').select('id')).error).not.toBeNull();
    expect((await a.from('target_version').select('id')).error).not.toBeNull();
    expect((await a.rpc('pm_save_site', { p_request_id: uuid(), p_name: 'x', p_timezone: 'UTC' })).error).not.toBeNull();
  });
});

test.describe('AC-11 isolation', () => {
  test('cross-tenant reads return 0 rows and the site is only the caller\'s own', async () => {
    expect((await ua.client.from('machine').select('id').eq('id', victimMachine)).data).toEqual([]);
    expect((await ua.client.from('product').select('id').eq('id', victimProduct)).data).toEqual([]);
    expect((await ua.client.from('target_version').select('id').eq('machine_id', victimMachine)).data).toEqual([]);
    expect((await ua.client.from('current_target').select('machine_id').eq('machine_id', victimMachine)).data).toEqual([]);
    const sites = (await ua.client.from('site').select('tenant_id')).data ?? [];
    expect(sites).toEqual([{ tenant_id: R.id }]);
    // the victim fixture really has data (so "0 rows" is meaningful)
    expect(((await service().from('target_version').select('id').eq('machine_id', victimMachine)).data ?? []).length).toBeGreaterThan(0);
  });

  test('writing with another tenant\'s ids gets the same generic denial as an unknown id, audited under the caller\'s tenant', async () => {
    const mine = await rpc(ua, 'pm_save_machine', { p_request_id: uuid(), p_id: null, p_code: code(), p_name: 'Mine', p_asset_tag: '', p_make: '', p_model: '', p_controller: '', p_line_id: null, p_status: 'active' });
    expect(mine.data).toMatchObject({ ok: true });
    const myProduct = await rpc(ua, 'pm_save_product', { p_request_id: uuid(), p_id: null, p_code: code(), p_description: 'Mine', p_uom: 'pcs' });
    const before = (await auditRows({ action: 'access.denied', actor: ua.userId })).length;
    const unknown = uuid();
    const make = (id: string) => [
      ['pm_set_machine_retired', { p_id: id, p_retired: true }],
      ['pm_set_product_retired', { p_id: id, p_retired: true }],
      ['pm_set_target', { p_machine_id: id, p_product_id: myProduct.data.id, p_pieces: 5, p_effective_from: addDays(today, 5) }],
      ['pm_set_target', { p_machine_id: mine.data.id, p_product_id: id, p_pieces: 5, p_effective_from: addDays(today, 5) }],
      ['pm_end_target', { p_machine_id: id, p_product_id: myProduct.data.id, p_effective_from: addDays(today, 5) }],
      ['pm_save_machine', { p_id: id, p_code: 'HACK', p_name: 'Hacked', p_asset_tag: '', p_make: '', p_model: '', p_controller: '', p_line_id: null, p_status: 'active' }],
      ['pm_save_product', { p_id: id, p_code: 'HACK', p_description: 'Hacked', p_uom: 'pcs' }],
      ['pm_archive_line', { p_id: id }],
    ] as [string, Record<string, unknown>][];
    const victimIds = { machine: victimMachine, product: victimProduct };
    const run = async (id: string) => {
      const out = [];
      for (const [fn, args] of make(id)) out.push((await rpc(ua, fn, { p_request_id: uuid(), ...args })).data);
      return out;
    };
    const asMachine = await run(victimIds.machine);
    const asProduct = await run(victimIds.product);
    const asUnknown = await run(unknown);
    for (const r of [...asMachine, ...asProduct, ...asUnknown]) expect(r).toEqual(DENIED);
    const events = (await auditRows({ action: 'access.denied', actor: ua.userId })).slice(before);
    expect(events.length).toBeGreaterThan(0);
    for (const e of events) expect(e.tenant_id).toBe(R.id);
    expect(events.some((e) => e.reason === 'cross_tenant')).toBe(true);
    expect(events.some((e) => e.reason === 'not_found')).toBe(true);
    // nothing of the victim tenant changed
    const v = (await service().from('machine').select('retired_at, name, tenant_id').eq('id', victimMachine).single()).data!;
    expect(v).toMatchObject({ retired_at: null, tenant_id: victimTenant });
    expect(v.name).not.toBe('Hacked');
  });

  test('direct writes are refused for every table, for a Unit Admin too', async () => {
    for (const table of ['site', 'line', 'machine', 'product', 'target_version'] as const) {
      const ins = await ua.client.from(table).insert({ tenant_id: R.id });
      expect(ins.error?.code, `${table} insert`).toBe('42501');
      const upd = await ua.client.from(table).update({ tenant_id: R.id }).eq('tenant_id', R.id);
      expect(upd.error?.code, `${table} update`).toBe('42501');
      const del = await ua.client.from(table).delete().eq('tenant_id', R.id);
      expect(del.error?.code, `${table} delete`).toBe('42501');
    }
  });
});

test.describe('AC-5..8, AC-12 targets and idempotency over HTTP', () => {
  test('set, change, end; backdating refused; history is append-only; repeats record once', async () => {
    const mCode = code();
    const m = await rpc(ua, 'pm_save_machine', { p_request_id: uuid(), p_id: null, p_code: mCode, p_name: 'API press', p_asset_tag: '', p_make: '', p_model: '', p_controller: '', p_line_id: null, p_status: 'active' });
    const p = await rpc(ua, 'pm_save_product', { p_request_id: uuid(), p_id: null, p_code: code(), p_description: 'API cap', p_uom: 'pcs' });
    expect(m.data).toMatchObject({ ok: true });
    const machine = m.data.id as string;
    const product = p.data.id as string;

    // audit: one machine.created row for the actor
    const created = await auditRows({ action: 'machine.created', entity: machine });
    expect(created).toHaveLength(1);
    expect(created[0]).toMatchObject({ tenant_id: R.id, actor_user_id: ua.userId, actor_role: 'unit_admin' });
    expect(JSON.stringify(created[0])).not.toMatch(/\+91/);

    // set today; the same request id again is a replay
    const rid = uuid();
    const set = await rpc(ua, 'pm_set_target', { p_request_id: rid, p_machine_id: machine, p_product_id: product, p_pieces: 1200, p_effective_from: today });
    expect(set.data).toMatchObject({ ok: true });
    const replay = await rpc(ua, 'pm_set_target', { p_request_id: rid, p_machine_id: machine, p_product_id: product, p_pieces: 1200, p_effective_from: today });
    expect(replay.data).toEqual({ ok: true, id: set.data.id, already: true });
    expect(await auditRows({ action: 'target.set', requestId: rid })).toHaveLength(1);
    const versions = async () => (await ua.client.from('target_version').select('*').eq('machine_id', machine).order('recorded_at')).data ?? [];
    expect(await versions()).toHaveLength(1);
    expect((await versions())[0]).toMatchObject({ pieces_per_shift: 1200, effective_from: today, recorded_by: ua.userId, request_id: rid });

    // current_target reflects it
    const cur = await ua.client.from('current_target').select('pieces_per_shift').eq('machine_id', machine).eq('product_id', product);
    expect(cur.data).toEqual([{ pieces_per_shift: 1200 }]);

    // backdating and bad numbers are validation errors with the field named
    const past = await rpc(ua, 'pm_set_target', { p_request_id: uuid(), p_machine_id: machine, p_product_id: product, p_pieces: 1000, p_effective_from: addDays(today, -1) });
    expect(past.error?.code).toBe('P0001');
    expect(JSON.parse(past.error!.details!)).toMatchObject({ code: 'validation', field: 'effective_from' });
    expect(past.error?.message).toBe("Targets can't start in the past");
    for (const bad of [0, 1_000_001]) {
      const r = await rpc(ua, 'pm_set_target', { p_request_id: uuid(), p_machine_id: machine, p_product_id: product, p_pieces: bad, p_effective_from: today });
      expect(JSON.parse(r.error!.details!)).toMatchObject({ field: 'pieces' });
    }

    // change in the future and end it; the product is blocked from retiring while a target is in force
    const change = await rpc(ua, 'pm_set_target', { p_request_id: uuid(), p_machine_id: machine, p_product_id: product, p_pieces: 1300, p_effective_from: addDays(today, 4) });
    expect(change.data).toMatchObject({ ok: true });
    const blocked = await rpc(ua, 'pm_set_product_retired', { p_request_id: uuid(), p_id: product, p_retired: true });
    expect(JSON.parse(blocked.error!.details!)).toMatchObject({ code: 'guard', machines: [mCode] });
    expect((await rpc(ua, 'pm_end_target', { p_request_id: uuid(), p_machine_id: machine, p_product_id: product, p_effective_from: addDays(today, 4) })).data).toMatchObject({ ok: true });
    expect((await rpc(ua, 'pm_end_target', { p_request_id: uuid(), p_machine_id: machine, p_product_id: product, p_effective_from: today })).data).toMatchObject({ ok: true });
    expect((await ua.client.from('current_target').select('machine_id').eq('machine_id', machine)).data).toEqual([]);
    expect((await rpc(ua, 'pm_set_product_retired', { p_request_id: uuid(), p_id: product, p_retired: true })).data).toMatchObject({ ok: true, changed: true });
    expect(await versions()).toHaveLength(4);

    // append-only: neither the Unit Admin nor the service role can change or remove history
    const sb = service();
    const upd = await sb.from('target_version').update({ pieces_per_shift: 1 }).eq('machine_id', machine);
    expect(upd.error?.code).toBe('42501');
    const del = await sb.from('target_version').delete().eq('machine_id', machine);
    expect(del.error?.code).toBe('42501');
    expect(await versions()).toHaveLength(4);

    // every change was audited exactly once
    for (const [action, n] of [['target.set', 2], ['target.ended', 2], ['product.retired', 1]] as const) {
      const rows = await auditRows({ action, tenant: R.id });
      expect(rows.filter((r) => [set.data.id, change.data.id].includes(r.entity_id) || action !== 'target.set').length, action).toBeGreaterThanOrEqual(n);
    }
  });

  test('a repeated create returns the first outcome without a second row', async () => {
    const rid = uuid();
    const c = code();
    const args = { p_request_id: rid, p_id: null, p_code: c, p_description: 'Once', p_uom: 'pcs' };
    const first = await rpc(ua, 'pm_save_product', args);
    const second = await rpc(ua, 'pm_save_product', args);
    expect(first.data).toMatchObject({ ok: true });
    expect(second.data).toEqual({ ok: true, id: first.data.id, already: true });
    expect((await service().from('product').select('id').eq('tenant_id', R.id).eq('code', c)).data).toHaveLength(1);
    expect(await auditRows({ action: 'product.created', requestId: rid })).toHaveLength(1);
  });

  test('duplicate codes and an in-use line are refused with codes and fields', async () => {
    const c = code();
    const args = { p_id: null, p_code: c, p_name: 'Dup', p_asset_tag: '', p_make: '', p_model: '', p_controller: '', p_line_id: null, p_status: 'active' };
    expect((await rpc(ua, 'pm_save_machine', { p_request_id: uuid(), ...args })).data).toMatchObject({ ok: true });
    const dup = await rpc(ua, 'pm_save_machine', { p_request_id: uuid(), ...args, p_code: c.toLowerCase() });
    expect(JSON.parse(dup.error!.details!)).toMatchObject({ code: 'duplicate', field: 'code' });
    const line = await rpc(ua, 'pm_save_line', { p_request_id: uuid(), p_id: null, p_name: code() });
    const onLine = await rpc(ua, 'pm_save_machine', { p_request_id: uuid(), ...args, p_code: code(), p_line_id: line.data.id });
    expect(onLine.data).toMatchObject({ ok: true });
    const arch = await rpc(ua, 'pm_archive_line', { p_request_id: uuid(), p_id: line.data.id });
    expect(JSON.parse(arch.error!.details!)).toMatchObject({ code: 'guard', field: 'line' });
    expect(victimTenant).not.toBe(R.id);
  });
});
