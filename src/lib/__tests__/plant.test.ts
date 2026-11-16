import { ApiError } from '@/lib/api';
import {
  PLANT_PAGE_SIZE, PlantError, RequestIds, fetchActiveProducts, fetchLines, fetchMachine, fetchMachines, fetchPlantToday, fetchProducts, fetchRecorderNames,
  fetchProductsByIds, fetchSite, fetchTargetVersions, fetchTenantTimezone, formatPieces, formatPlantDate, isValidDate, machineStatusLabel, parsePieces, plantApi, productStatusLabel, sanitiseSearch,
  summariseTargets, validateMachineForm, validateProductForm, validateTargetForm, type MachineQuery, type TargetVersion,
} from '@/lib/plant';
import { fakeDb } from '@/test/fake-db';

describe('labels and formats (status is text)', () => {
  it('labels machines and products', () => {
    expect(machineStatusLabel({ status: 'active', retired_at: null })).toBe('Active');
    expect(machineStatusLabel({ status: 'under_maintenance', retired_at: null })).toBe('Under maintenance');
    expect(machineStatusLabel({ status: 'active', retired_at: '2026-11-01T00:00:00Z' })).toBe('Retired');
    expect(machineStatusLabel({ status: 'under_maintenance', retired_at: '2026-11-01T00:00:00Z' })).toBe('Retired');
    expect(productStatusLabel({ retired_at: null })).toBe('Active');
    expect(productStatusLabel({ retired_at: 'x' })).toBe('Retired');
  });
  it('formats plant dates without any timezone shift', () => {
    expect(formatPlantDate('2026-11-18')).toBe('18 Nov 2026');
    expect(formatPlantDate('2027-01-01')).toBe('1 Jan 2027');
    expect(formatPlantDate('not a date')).toBe('not a date');
  });
  it('formats pieces with thousands separators', () => {
    expect(formatPieces(1200)).toBe('1,200');
    expect(formatPieces(1000000)).toBe('1,000,000');
    expect(formatPieces(7)).toBe('7');
  });
  it('sanitises search text', () => expect(sanitiseSearch(' a,b(c)%*\\"d ')).toBe('abcd'));
});

describe('client validation mirrors the server', () => {
  const machine = { code: 'M-1', name: 'Press 1', asset_tag: '', make: '', model: '', controller: '' };
  it('accepts a valid machine', () => expect(validateMachineForm(machine)).toEqual({}));
  it.each([['bad code!'], [''], ['A'.repeat(21)]])('refuses machine code %p', (code) => expect(validateMachineForm({ ...machine, code }).code).toBe('Code: 1 to 20 letters, digits, - _ or /'));
  it('refuses an empty or too long name and over-long optional fields', () => {
    expect(validateMachineForm({ ...machine, name: '  ' }).name).toBe('Enter a name of 1 to 80 characters');
    expect(validateMachineForm({ ...machine, name: 'x'.repeat(81) }).name).toBeDefined();
    expect(validateMachineForm({ ...machine, make: 'm'.repeat(81) }).make).toBe('Make: up to 80 characters');
    expect(validateMachineForm({ ...machine, controller: 'c'.repeat(81) }).controller).toBe('Controller: up to 80 characters');
  });
  it('accepts a code with slash, dash and underscore', () => expect(validateMachineForm({ ...machine, code: 'a_b/c-9' })).toEqual({}));
  it('validates products (blank unit means the default)', () => {
    expect(validateProductForm({ code: 'P-1', description: 'Cap', uom: '' })).toEqual({});
    expect(validateProductForm({ code: '', description: 'Cap', uom: 'pcs' }).code).toBeDefined();
    expect(validateProductForm({ code: 'P-1', description: '', uom: 'pcs' }).description).toBeDefined();
    expect(validateProductForm({ code: 'P-1', description: 'x'.repeat(121), uom: 'pcs' }).description).toBeDefined();
    expect(validateProductForm({ code: 'P-1', description: 'Cap', uom: 'abcdefghijk' }).uom).toBe('Unit of measure: 1 to 10 characters');
  });
});

describe('number and date input', () => {
  it.each([['1200', 1200], ['1,200', 1200], ['1 200', 1200], ['1', 1], ['1000000', 1000000]])('parses pieces %p', (t, n) => expect(parsePieces(t)).toBe(n));
  it.each([[''], ['0'], ['-5'], ['12.5'], ['1000001'], ['abc'], ['1e3'], ['12345678']])('refuses pieces %p', (t) => expect(parsePieces(t)).toBeNull());
  it('checks real calendar dates', () => {
    expect(isValidDate('2026-11-18')).toBe(true);
    expect(isValidDate('2028-02-29')).toBe(true);
    expect(isValidDate('2027-02-29')).toBe(false);
    expect(isValidDate('2026-13-01')).toBe(false);
    expect(isValidDate('18/11/2026')).toBe(false);
    expect(isValidDate('')).toBe(false);
  });
  it('target form: date must be today or later (the server\'s plant date), pieces whole 1 to 1 000 000', () => {
    expect(validateTargetForm({ pieces: '1200', date: '2026-11-18' }, '2026-11-18')).toEqual({});
    expect(validateTargetForm({ pieces: '1200', date: '2026-11-17' }, '2026-11-18').effective_from).toBe("Targets can't start in the past");
    expect(validateTargetForm({ pieces: '0', date: '2026-11-19' }, '2026-11-18').pieces).toBe('Enter a whole number from 1 to 1,000,000');
    expect(validateTargetForm({ pieces: '5', date: 'tomorrow' }, '2026-11-18').effective_from).toBe('Enter a date as YYYY-MM-DD');
    expect(validateTargetForm({ pieces: '', date: '2026-11-19' }, '2026-11-18', { needPieces: false })).toEqual({});
    expect(validateTargetForm({ pieces: '5', date: '2020-01-01' }, null)).toEqual({}); // unknown plant date: the server decides
  });
});

describe('reads', () => {
  const machineQuery = (over: Partial<MachineQuery> = {}): MachineQuery => ({ search: '', status: 'all', line: 'all', showRetired: false, page: 0, ...over });
  const run = async (over: Partial<MachineQuery> = {}) => {
    const db = fakeDb(() => ({ data: [], count: 60, error: null }));
    await fetchMachines(db.client as never, machineQuery(over));
    return db.queries[0];
  };

  it('pages machines 25 at a time ordered by code, hiding retired by default', async () => {
    expect(PLANT_PAGE_SIZE).toBe(25);
    const q = await run({ page: 2 });
    expect(q.table).toBe('machine');
    expect(q.select?.[1]).toEqual({ count: 'exact' });
    expect(q.range).toEqual([50, 74]);
    expect(q.order).toEqual(['code', { ascending: true }]);
    expect(q.filters).toEqual([['is', 'retired_at', null]]);
  });
  it('shows retired machines on request', async () => expect((await run({ showRetired: true })).filters).toEqual([]));
  it('searches code and name, sanitised', async () => expect((await run({ search: ' m,1 ', showRetired: true })).filters).toEqual([['or', 'code.ilike.%m1%,name.ilike.%m1%']]));
  it('filters by status and by line (none / a specific line)', async () => {
    expect((await run({ status: 'under_maintenance', showRetired: true })).filters).toEqual([['eq', 'status', 'under_maintenance']]);
    expect((await run({ line: 'none', showRetired: true })).filters).toEqual([['is', 'line_id', null]]);
    expect((await run({ line: 'l-1', showRetired: true })).filters).toEqual([['eq', 'line_id', 'l-1']]);
  });
  it('returns rows and the exact total', async () => {
    const db = fakeDb(() => ({ data: [{ id: 'm1' }], count: 1, error: null }));
    expect(await fetchMachines(db.client as never, machineQuery())).toEqual({ rows: [{ id: 'm1' }], total: 1 });
  });
  it('throws read errors so the screen can show Try again', async () => {
    const db = fakeDb(() => ({ data: null, count: null, error: new TypeError('Failed to fetch') }));
    await expect(fetchMachines(db.client as never, machineQuery())).rejects.toThrow('Failed to fetch');
  });
  it('reads one machine, the site, the plant date, lines, products and versions', async () => {
    const db = fakeDb((q) => ({ data: q.table === 'site' ? { id: 's1', name: 'P', timezone: 'Asia/Kolkata' } : q.table === 'plant_today' ? { plant_date: '2026-11-18' } : q.single ? { id: 'x' } : [], count: 0, error: null }));
    expect(await fetchSite(db.client as never)).toEqual({ id: 's1', name: 'P', timezone: 'Asia/Kolkata' });
    expect(await fetchPlantToday(db.client as never)).toBe('2026-11-18');
    expect(await fetchMachine(db.client as never, 'm1')).toEqual({ id: 'x' });
    expect(await fetchLines(db.client as never)).toEqual([]);
    expect(db.queries.find((q) => q.table === 'line')!.filters).toEqual([['is', 'archived_at', null]]);
    await fetchLines(db.client as never, { includeArchived: true });
    expect(db.queries.filter((q) => q.table === 'line')[1].filters).toEqual([]);
    await fetchActiveProducts(db.client as never);
    expect(db.queries.filter((q) => q.table === 'product')[0].filters).toEqual([['is', 'retired_at', null]]);
    await fetchProducts(db.client as never, { search: 'cap', showRetired: false, page: 1 });
    const pq = db.queries.filter((q) => q.table === 'product')[1];
    expect(pq.filters).toEqual([['or', 'code.ilike.%cap%,description.ilike.%cap%'], ['is', 'retired_at', null]]);
    expect(pq.range).toEqual([25, 49]);
    await fetchTargetVersions(db.client as never, 'm1');
    const tq = db.queries.find((q) => q.table === 'target_version')!;
    expect(tq.filters).toEqual([['eq', 'machine_id', 'm1']]);
  });
  it('returns null for a missing site, plant date or machine', async () => {
    const db = fakeDb(() => ({ data: null, error: null }));
    expect(await fetchSite(db.client as never)).toBeNull();
    expect(await fetchPlantToday(db.client as never)).toBeNull();
    expect(await fetchMachine(db.client as never, 'x')).toBeNull();
  });
  it('maps recorder ids to names, skipping the query when empty', async () => {
    const db = fakeDb(() => ({ data: [{ user_id: 'u1', full_name: 'Asha' }], error: null }));
    expect(await fetchRecorderNames(db.client as never, [])).toEqual({});
    expect(db.queries).toHaveLength(0);
    expect(await fetchRecorderNames(db.client as never, ['u1', 'u1'])).toEqual({ u1: 'Asha' });
    expect(db.queries[0].filters).toEqual([['in', 'user_id', ['u1']]]);
  });
});

describe('more reads', () => {
  it('reads the tenant timezone', async () => {
    const db = fakeDb(() => ({ data: { timezone: 'Asia/Tokyo' }, error: null }));
    expect(await fetchTenantTimezone(db.client as never)).toBe('Asia/Tokyo');
    expect(db.queries[0].table).toBe('tenant');
    expect(await fetchTenantTimezone(fakeDb(() => ({ data: null, error: null })).client as never)).toBeNull();
  });
  it('reads products by id (deduplicated, retired included) and skips the query for no ids', async () => {
    const db = fakeDb(() => ({ data: [{ id: 'p1' }], error: null }));
    expect(await fetchProductsByIds(db.client as never, [])).toEqual([]);
    expect(db.queries).toHaveLength(0);
    expect(await fetchProductsByIds(db.client as never, ['p1', 'p1'])).toEqual([{ id: 'p1' }]);
    expect(db.queries[0].filters).toEqual([['in', 'id', ['p1']]]);
  });
});

describe('summariseTargets (AC-7, AC-9)', () => {
  const v = (id: string, from: string, pieces: number | null, rec: string, product = 'p1'): TargetVersion => ({
    id, machine_id: 'm1', product_id: product, effective_from: from, pieces_per_shift: pieces, recorded_by: 'u1', recorded_at: rec,
  });
  const today = '2026-11-18';

  it('has no rows for a machine without versions', () => expect(summariseTargets([], today)).toEqual([]));
  it('current is the latest version on or before today; next is the earliest later one', () => {
    const [s] = summariseTargets([v('3', '2026-12-01', 1300, 't3'), v('2', '2026-11-18', 1200, 't2'), v('1', '2026-01-01', 1000, 't1')], today);
    expect(s.current).toEqual({ pieces: 1200, from: '2026-11-18' });
    expect(s.next).toEqual({ pieces: 1300, from: '2026-12-01' });
    expect(s.history.map((h) => h.id)).toEqual(['3', '2', '1']);
  });
  it('a version starting tomorrow is not current yet', () => {
    const [s] = summariseTargets([v('2', '2026-11-19', 1300, 't2'), v('1', '2026-01-01', 1000, 't1')], today);
    expect(s.current?.pieces).toBe(1000);
    expect(s.next?.from).toBe('2026-11-19');
  });
  it('same-day correction: the latest recorded wins', () => {
    const [s] = summariseTargets([v('1', '2026-11-18', 1000, 't1'), v('2', '2026-11-18', 950, 't2')], today);
    expect(s.current?.pieces).toBe(950);
  });
  it('an ended target has no current; a future end is shown as the next change with null pieces', () => {
    const ended = summariseTargets([v('2', '2026-11-10', null, 't2'), v('1', '2026-01-01', 1000, 't1')], today)[0];
    expect(ended.current).toBeNull();
    const ending = summariseTargets([v('2', '2026-12-31', null, 't2'), v('1', '2026-01-01', 1000, 't1')], today)[0];
    expect(ending.current?.pieces).toBe(1000);
    expect(ending.next).toEqual({ pieces: null, from: '2026-12-31' });
  });
  it('re-set after end applies again', () => {
    const [s] = summariseTargets([v('3', '2026-11-15', 900, 't3'), v('2', '2026-11-10', null, 't2'), v('1', '2026-01-01', 1000, 't1')], today);
    expect(s.current).toEqual({ pieces: 900, from: '2026-11-15' });
  });
  it('only future versions: no current, next shown', () => {
    const [s] = summariseTargets([v('1', '2026-12-01', 500, 't1')], today);
    expect(s.current).toBeNull();
    expect(s.next).toEqual({ pieces: 500, from: '2026-12-01' });
  });
  it('a scheduled change cancelled by a same-day end is not a next change', () => {
    const [s] = summariseTargets([
      v('4', '2026-11-18', null, 't4'), v('3', '2026-11-21', null, 't3'), v('2', '2026-11-21', 1300, 't2'), v('1', '2026-01-01', 1000, 't1'),
    ], today);
    expect(s.current).toBeNull(); // ended today
    expect(s.next).toBeNull();
  });
  it('skips cancelled changes and reports the next real one', () => {
    const [s] = summariseTargets([
      v('5', '2026-12-10', 900, 't5'), v('4', '2026-11-18', null, 't4'), v('3', '2026-11-21', null, 't3'), v('2', '2026-11-21', 1300, 't2'), v('1', '2026-01-01', 1000, 't1'),
    ], today);
    expect(s.current).toBeNull();
    expect(s.next).toEqual({ pieces: 900, from: '2026-12-10' });
  });
  it('a re-set to the same amount is not a change', () => {
    const [s] = summariseTargets([v('2', '2026-11-25', 1000, 't2'), v('1', '2026-01-01', 1000, 't1')], today);
    expect(s.next).toBeNull();
  });
  it('keeps products apart', () => {
    const out = summariseTargets([v('1', '2026-01-01', 10, 't1', 'pA'), v('2', '2026-01-01', 20, 't2', 'pB')], today);
    expect(out.map((s) => [s.productId, s.current?.pieces])).toEqual([['pA', 10], ['pB', 20]]);
  });
});

describe('RPC wrappers', () => {
  const rpc = (res: unknown) => ({ rpc: jest.fn(async () => res) }) as never as Parameters<typeof plantApi.saveSite>[0] & { rpc: jest.Mock };
  const rid = '11111111-1111-4111-8111-111111111111';

  it('sends named parameters and returns the server outcome', async () => {
    const c = rpc({ data: { ok: true, id: 's1' }, error: null, status: 200 });
    await expect(plantApi.saveSite(c, { name: 'Plant', timezone: 'Asia/Kolkata' }, rid)).resolves.toEqual({ ok: true, id: 's1' });
    expect(c.rpc).toHaveBeenCalledWith('pm_save_site', { p_request_id: rid, p_name: 'Plant', p_timezone: 'Asia/Kolkata' });
  });
  it.each([
    ['saveLine', (c: never) => plantApi.saveLine(c, 'l1', 'Line', rid), 'pm_save_line', { p_request_id: rid, p_id: 'l1', p_name: 'Line' }],
    ['archiveLine', (c: never) => plantApi.archiveLine(c, 'l1', rid), 'pm_archive_line', { p_request_id: rid, p_id: 'l1' }],
    ['setMachineRetired', (c: never) => plantApi.setMachineRetired(c, 'm1', true, rid), 'pm_set_machine_retired', { p_request_id: rid, p_id: 'm1', p_retired: true }],
    ['saveProduct', (c: never) => plantApi.saveProduct(c, null, { code: 'P', description: 'D', uom: 'pcs' }, rid), 'pm_save_product', { p_request_id: rid, p_id: null, p_code: 'P', p_description: 'D', p_uom: 'pcs' }],
    ['setProductRetired', (c: never) => plantApi.setProductRetired(c, 'p1', false, rid), 'pm_set_product_retired', { p_request_id: rid, p_id: 'p1', p_retired: false }],
    ['setTarget', (c: never) => plantApi.setTarget(c, { machineId: 'm1', productId: 'p1', pieces: 5, effectiveFrom: '2026-11-18' }, rid), 'pm_set_target',
      { p_request_id: rid, p_machine_id: 'm1', p_product_id: 'p1', p_pieces: 5, p_effective_from: '2026-11-18' }],
    ['endTarget', (c: never) => plantApi.endTarget(c, { machineId: 'm1', productId: 'p1', effectiveFrom: '2026-11-18' }, rid), 'pm_end_target',
      { p_request_id: rid, p_machine_id: 'm1', p_product_id: 'p1', p_effective_from: '2026-11-18' }],
  ])('%s calls %s', async (_n, fn, name, args) => {
    const c = rpc({ data: { ok: true }, error: null, status: 200 });
    await fn(c as never);
    expect(c.rpc).toHaveBeenCalledWith(name, args);
  });
  it('sends every machine field', async () => {
    const c = rpc({ data: { ok: true }, error: null, status: 200 });
    await plantApi.saveMachine(c, 'm1', { code: 'M', name: 'N', asset_tag: 'a', make: 'b', model: 'c', controller: 'd', line_id: 'l1', status: 'under_maintenance' }, rid);
    expect(c.rpc).toHaveBeenCalledWith('pm_save_machine', {
      p_request_id: rid, p_id: 'm1', p_code: 'M', p_name: 'N', p_asset_tag: 'a', p_make: 'b', p_model: 'c', p_controller: 'd', p_line_id: 'l1', p_status: 'under_maintenance',
    });
  });
  it('maps a validation error to a PlantError with field, code and message', async () => {
    const c = rpc({ data: null, status: 400, error: { code: 'P0001', message: 'This code is already in use', details: '{"code": "duplicate", "field": "code"}' } });
    const err = await plantApi.saveMachine(c, null, { code: 'M', name: 'N', asset_tag: '', make: '', model: '', controller: '', line_id: null, status: 'active' }, rid).catch((e) => e);
    expect(err).toBeInstanceOf(PlantError);
    expect(err).toBeInstanceOf(ApiError);
    expect(err).toMatchObject({ field: 'code', code: 'duplicate', message: 'This code is already in use' });
  });
  it('carries the blocking machine codes of a guard error', async () => {
    const c = rpc({ data: null, status: 400, error: { code: 'P0001', message: 'End its targets first', details: '{"code":"guard","field":"product","machines":["M-1","M-2"]}' } });
    const err = await plantApi.setProductRetired(c, 'p1', true, rid).catch((e) => e);
    expect(err).toMatchObject({ code: 'guard', field: 'product', machines: ['M-1', 'M-2'] });
  });
  it('survives unreadable error details', async () => {
    const c = rpc({ data: null, status: 400, error: { code: 'P0001', message: 'Something', details: 'not json' } });
    await expect(plantApi.archiveLine(c, 'l1', rid)).rejects.toMatchObject({ field: undefined, message: 'Something' });
  });
  it('maps the generic denial to Not allowed (403) with no detail', async () => {
    const c = rpc({ data: { ok: false, code: 'not_allowed' }, error: null, status: 200 });
    await expect(plantApi.saveSite(c, { name: 'x', timezone: 'UTC' }, rid)).rejects.toMatchObject({ status: 403, code: 'not_allowed', message: 'Not allowed' });
  });
  it('never shows raw server text for 5xx or other errors', async () => {
    const c = rpc({ data: null, status: 502, error: { code: '', message: '<html>bad gateway</html>' } });
    const err = await plantApi.saveSite(c, { name: 'x', timezone: 'UTC' }, rid).catch((e) => e);
    expect(err).toMatchObject({ status: 502, message: 'Something went wrong. Please try again.' });
    const c2 = rpc({ data: null, status: 401, error: { code: 'PGRST301', message: 'JWT expired' } });
    expect(await plantApi.saveSite(c2, { name: 'x', timezone: 'UTC' }, rid).catch((e) => e)).toMatchObject({ status: 401, message: 'Something went wrong. Please try again.' });
  });
  it('re-throws network failures (no status) untouched', async () => {
    const boom = new TypeError('Failed to fetch');
    const c = rpc({ data: null, status: 0, error: boom });
    await expect(plantApi.saveSite(c, { name: 'x', timezone: 'UTC' }, rid)).rejects.toBe(boom);
  });
});

describe('RequestIds (02 R2)', () => {
  it('returns the same id for the same action until it succeeds', () => {
    const r = new RequestIds();
    const a = r.get('save:m1');
    expect(r.get('save:m1')).toBe(a);
    expect(r.get('save:m2')).not.toBe(a);
    r.succeeded('save:m1');
    expect(r.get('save:m1')).not.toBe(a);
  });
  it('keeps the id after a network error and after a 4xx (the first attempt may have succeeded)', () => {
    const r = new RequestIds();
    const a = r.get('k');
    r.failed('k', new TypeError('Failed to fetch'));
    expect(r.get('k')).toBe(a);
    r.failed('k', new ApiError(401, undefined, 'x'));
    expect(r.get('k')).toBe(a);
  });
  it('replaces the id after a 5xx and after a server refusal (nothing was recorded)', () => {
    const r = new RequestIds();
    const a = r.get('k');
    r.failed('k', new ApiError(502, undefined, 'x'));
    const b = r.get('k');
    expect(b).not.toBe(a);
    r.failed('k', new PlantError(400, 'code', 'dup', 'duplicate'));
    expect(r.get('k')).not.toBe(b);
  });
});
