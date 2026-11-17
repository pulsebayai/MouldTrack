import {
  PlantError, fetchActiveSupervisors, fetchMyShift, fetchOverrideVersions, fetchShiftBoard, fetchShifts, formatDuration, groupBoard, hhmm, isOvernight, shiftApi, shiftMinutes,
  summariseOverrides, timeWindow, validateAssignForm, validateCoverForm, validateShiftForm, whoLoses, type BoardMachine, type OverrideVersion,
} from '@/lib/plant';
import { fakeDb } from '@/test/fake-db';

describe('shift times (AC-1)', () => {
  it('shows HH:MM from the database time', () => {
    expect(hhmm('06:00:00')).toBe('06:00');
    expect(hhmm('22:15')).toBe('22:15');
  });
  it('writes the window with an en dash and flags overnight shifts', () => {
    expect(timeWindow('22:00:00', '06:00:00')).toBe('22:00 – 06:00');
    expect(isOvernight('22:00', '06:00')).toBe(true);
    expect(isOvernight('06:00', '14:00')).toBe(false);
  });
  it.each([['06:00', '14:00', 480], ['22:00', '06:00', 480], ['23:45', '00:00', 15], ['00:00', '23:45', 1425], ['12:00', '00:00', 720]])(
    'duration of %s to %s is %i minutes', (s, e, m) => expect(shiftMinutes(s, e)).toBe(m));
  it('formats a duration', () => {
    expect(formatDuration(480)).toBe('8 h');
    expect(formatDuration(465)).toBe('7 h 45 min');
    expect(formatDuration(15)).toBe('15 min');
  });
});

describe('validateShiftForm mirrors the server', () => {
  const ok = { name: 'Morning', start: '06:00', end: '14:00' };
  it('accepts a day and an overnight shift', () => {
    expect(validateShiftForm(ok)).toEqual({});
    expect(validateShiftForm({ name: 'Night', start: '22:00', end: '06:00' })).toEqual({});
  });
  it('refuses a blank or over-long name', () => {
    expect(validateShiftForm({ ...ok, name: '  ' }).name).toBe('Enter a name of 1 to 40 characters');
    expect(validateShiftForm({ ...ok, name: 'x'.repeat(41) }).name).toBeDefined();
  });
  it.each([['6:00'], ['24:00'], ['ab:cd'], [''], ['06:60']])('refuses the time %p', (t) => {
    expect(validateShiftForm({ ...ok, start: t }).start_time).toBe('Enter a time as HH:MM (24-hour)');
    expect(validateShiftForm({ ...ok, end: t }).end_time).toBe('Enter a time as HH:MM (24-hour)');
  });
  it('refuses times that are not on a 15-minute step', () => {
    expect(validateShiftForm({ ...ok, start: '06:10' }).start_time).toBe('Use 15-minute steps: :00, :15, :30 or :45');
    expect(validateShiftForm({ ...ok, end: '14:05' }).end_time).toBe('Use 15-minute steps: :00, :15, :30 or :45');
  });
  it('refuses an end equal to the start', () => expect(validateShiftForm({ ...ok, end: '06:00' }).end_time).toBe('The end time must differ from the start time'));
});

describe('assign and cover validation', () => {
  it('assign needs a supervisor, machines and a valid date not in the past; until must not precede from', () => {
    const base = { supervisorId: 's1', machineIds: ['m1'], from: '2026-11-18', until: '' };
    expect(validateAssignForm(base, '2026-11-18')).toEqual({});
    expect(validateAssignForm({ ...base, supervisorId: '' }, '2026-11-18').supervisor).toBe('Choose a supervisor');
    expect(validateAssignForm({ ...base, machineIds: [] }, '2026-11-18').machine_ids).toBe('Choose at least one machine');
    expect(validateAssignForm({ ...base, from: '2026-11-17' }, '2026-11-18').from).toBe("Assignments can't start in the past");
    expect(validateAssignForm({ ...base, from: '18/11/2026' }, '2026-11-18').from).toBe('Enter a date as YYYY-MM-DD');
    expect(validateAssignForm({ ...base, until: '2026-11-17' }, '2026-11-18').until).toBe("The end date can't be before the start date");
    expect(validateAssignForm({ ...base, until: 'x' }, '2026-11-18').until).toBe('Enter a date as YYYY-MM-DD');
    expect(validateAssignForm({ ...base, until: '2026-12-01' }, '2026-11-18')).toEqual({});
  });
  it('cover needs machines and a reason of 1 to 200 characters; unassigned (null supervisor) is allowed', () => {
    expect(validateCoverForm({ machineIds: ['m1'], reason: 'Sick leave' })).toEqual({});
    expect(validateCoverForm({ machineIds: [], reason: 'x' }).machine_ids).toBe('Choose at least one machine');
    expect(validateCoverForm({ machineIds: ['m1'], reason: '   ' }).reason).toBe('Enter a reason of 1 to 200 characters');
    expect(validateCoverForm({ machineIds: ['m1'], reason: 'x'.repeat(201) }).reason).toBeDefined();
  });
});

const bm = (i: number, over: Partial<BoardMachine> = {}): BoardMachine => ({
  machine_id: `m-${i}`, code: `M-${i}`, name: `Press ${i}`, line: null, status: 'active', owner_id: null, owner_name: null, owner_inactive: false, source: 'none', reason: null, ...over,
});

describe('board grouping (AC-9)', () => {
  const machines = [
    bm(1, { owner_id: 's2', owner_name: 'Sup Two', source: 'plan' }),
    bm(2),
    bm(3, { owner_id: 's1', owner_name: 'Sup One', source: 'plan' }),
    bm(4, { owner_id: 's2', owner_name: 'Sup Two', source: 'cover', reason: 'Leave' }),
    bm(5, { source: 'cover', reason: 'Machine down' }),
    bm(6, { owner_id: 's9', owner_name: 'Gone Person', owner_inactive: true, source: 'plan' }),
  ];
  it('puts unassigned machines first (cover to unassigned included) and groups the rest by supervisor name', () => {
    const g = groupBoard(machines);
    expect(g.unassigned.map((m) => m.code)).toEqual(['M-2', 'M-5']);
    expect(g.groups.map((x) => [x.ownerId, x.name, x.inactive, x.machines.map((m) => m.code)])).toEqual([
      ['s9', 'Gone Person', true, ['M-6']],
      ['s1', 'Sup One', false, ['M-3']],
      ['s2', 'Sup Two', false, ['M-1', 'M-4']],
    ]);
  });
  it('names who loses machines when they move to another supervisor, ignoring machines already theirs and unassigned ones', () => {
    expect(whoLoses(machines, ['m-1', 'm-3', 'm-2', 'm-4'], 's2')).toEqual([{ name: 'Sup One', codes: ['M-3'] }]);
    expect(whoLoses(machines, ['m-1', 'm-3', 'm-6'], null)).toEqual([{ name: 'Gone Person', codes: ['M-6'] }, { name: 'Sup One', codes: ['M-3'] }, { name: 'Sup Two', codes: ['M-1'] }]);
    expect(whoLoses(machines, ['m-2'], 's1')).toEqual([]);
  });
});

describe('summariseOverrides groups per product and shift', () => {
  const ov = (id: string, p: string, sh: string, from: string, pieces: number | null, rec: string): OverrideVersion => ({
    id, machine_id: 'm-1', product_id: p, shift_id: sh, effective_from: from, pieces_per_shift: pieces, recorded_by: 'u-1', recorded_at: rec,
  });
  it('gives current, next and history for each (product, shift) pair', () => {
    const s = summariseOverrides([
      ov('a', 'p-1', 'night', '2026-01-01', 800, '1'), ov('b', 'p-1', 'night', '2026-12-01', 900, '2'), ov('c', 'p-1', 'day', '2026-01-01', 1100, '3'), ov('d', 'p-1', 'night', '2026-02-01', null, '4'),
    ], '2026-11-18');
    const night = s.find((x) => x.shiftId === 'night')!;
    expect(night.productId).toBe('p-1');
    expect(night.current).toBeNull(); // ended 1 Feb
    expect(night.next).toEqual({ pieces: 900, from: '2026-12-01' });
    expect(night.history.map((v) => v.id)).toEqual(['b', 'd', 'a']);
    expect(s.find((x) => x.shiftId === 'day')!.current).toEqual({ pieces: 1100, from: '2026-01-01' });
  });
});

describe('shiftApi sends the right RPC and arguments', () => {
  const rpc = (res: unknown = { data: { ok: true, id: 'x' }, error: null, status: 200 }) => ({ rpc: jest.fn(async () => res) }) as never as Parameters<typeof shiftApi.saveShift>[0] & { rpc: jest.Mock };
  const rid = '11111111-1111-4111-8111-111111111111';
  it('saves and retires shifts', async () => {
    const c = rpc();
    await shiftApi.saveShift(c, null, { name: 'Night', start: '22:00', end: '06:00' }, rid);
    expect(c.rpc).toHaveBeenCalledWith('sh_save_shift', { p_request_id: rid, p_id: null, p_name: 'Night', p_start: '22:00', p_end: '06:00' });
    await shiftApi.setShiftRetired(c, 's-1', true, rid);
    expect(c.rpc).toHaveBeenCalledWith('sh_set_shift_retired', { p_request_id: rid, p_id: 's-1', p_retired: true });
  });
  it('assigns, unassigns and covers', async () => {
    const c = rpc();
    await shiftApi.assign(c, { shiftId: 'sh', supervisorId: 's1', machineIds: ['m1', 'm2'], from: '2026-11-18', until: null }, rid);
    expect(c.rpc).toHaveBeenCalledWith('sh_assign', { p_request_id: rid, p_shift_id: 'sh', p_supervisor_id: 's1', p_machine_ids: ['m1', 'm2'], p_from: '2026-11-18', p_until: null });
    await shiftApi.unassign(c, { shiftId: 'sh', machineIds: ['m1'], from: '2026-11-20' }, rid);
    expect(c.rpc).toHaveBeenCalledWith('sh_unassign', { p_request_id: rid, p_shift_id: 'sh', p_machine_ids: ['m1'], p_from: '2026-11-20' });
    await shiftApi.cover(c, { shiftId: 'sh', shiftDate: '2026-11-18', machineIds: ['m1'], supervisorId: null, reason: 'Down' }, rid);
    expect(c.rpc).toHaveBeenCalledWith('sh_cover', { p_request_id: rid, p_shift_id: 'sh', p_shift_date: '2026-11-18', p_machine_ids: ['m1'], p_supervisor_id: null, p_reason: 'Down' });
  });
  it('sets and ends a per-shift target', async () => {
    const c = rpc();
    await shiftApi.setOverride(c, { machineId: 'm', productId: 'p', shiftId: 'sh', pieces: 900, effectiveFrom: '2026-11-20' }, rid);
    expect(c.rpc).toHaveBeenCalledWith('sh_set_target_override', { p_request_id: rid, p_machine_id: 'm', p_product_id: 'p', p_shift_id: 'sh', p_pieces: 900, p_effective_from: '2026-11-20' });
    await shiftApi.endOverride(c, { machineId: 'm', productId: 'p', shiftId: 'sh', effectiveFrom: '2026-11-20' }, rid);
    expect(c.rpc).toHaveBeenCalledWith('sh_end_target_override', { p_request_id: rid, p_machine_id: 'm', p_product_id: 'p', p_shift_id: 'sh', p_effective_from: '2026-11-20' });
  });
  it('maps a later_change guard with the machines and dates it lists', async () => {
    const c = rpc({ data: null, status: 400, error: { code: 'P0001', message: 'A later change is already scheduled for these machines', details: '{"code":"guard","field":"later_change","machines":["M-1"],"dates":["2026-11-25"]}' } });
    const err = await shiftApi.assign(c, { shiftId: 'sh', supervisorId: 's1', machineIds: ['m1'], from: '2026-11-18', until: null }, rid).catch((e) => e);
    expect(err).toBeInstanceOf(PlantError);
    expect(err).toMatchObject({ field: 'later_change', code: 'guard', machines: ['M-1'], dates: ['2026-11-25'] });
  });
  it('maps the generic denial to a 403 PlantError', async () => {
    const c = rpc({ data: { ok: false, code: 'not_allowed' }, error: null, status: 200 });
    const err = await shiftApi.cover(c, { shiftId: 'sh', shiftDate: '2026-11-18', machineIds: ['m1'], supervisorId: 's1', reason: 'x' }, rid).catch((e) => e);
    expect(err).toMatchObject({ status: 403, code: 'not_allowed' });
  });
});

describe('reads', () => {
  const rows = (table: string, data: unknown) => fakeDb((q) => (q.table === table ? { data, error: null } : { data: [], error: null }));
  it('lists shifts, hiding retired ones unless asked', async () => {
    const db = rows('shift', [{ id: 's', name: 'Day', start_time: '06:00:00', end_time: '14:00:00', retired_at: null }]);
    expect(await fetchShifts(db.client as never, { includeRetired: false })).toHaveLength(1);
    expect(db.queries[0].filters).toContainEqual(['is', 'retired_at', null]);
    await fetchShifts(db.client as never, { includeRetired: true });
    expect(db.queries[1].filters.some((f) => f[0] === 'is')).toBe(false);
  });
  it('lists active supervisors who can be assigned (no temporary password)', async () => {
    const db = rows('membership', [{ user_id: 's1', full_name: 'Sup One', employee_id: 'S1' }]);
    expect(await fetchActiveSupervisors(db.client as never)).toEqual([{ user_id: 's1', full_name: 'Sup One', employee_id: 'S1' }]);
    expect(db.queries[0].filters).toEqual(expect.arrayContaining([['eq', 'role', 'supervisor'], ['eq', 'status', 'active'], ['eq', 'must_change_password', false]]));
  });
  it('reads a machine\'s overrides newest first', async () => {
    const db = rows('target_override_version', []);
    await fetchOverrideVersions(db.client as never, 'm-1');
    expect(db.queries[0].filters).toContainEqual(['eq', 'machine_id', 'm-1']);
  });
  const rpcClient = (res: unknown) => ({ rpc: jest.fn(async () => res) }) as never as Parameters<typeof fetchMyShift>[0] & { rpc: jest.Mock };
  it('reads my shift through the RPC (never the tables)', async () => {
    const c = rpcClient({ data: { ok: true, state: 'none' }, error: null, status: 200 });
    expect(await fetchMyShift(c)).toEqual({ ok: true, state: 'none' });
    expect(c.rpc).toHaveBeenCalledWith('my_shift');
  });
  it('reads the board through the RPC', async () => {
    const c = rpcClient({ data: { ok: true, machines: [], unassigned_count: 0 }, error: null, status: 200 });
    await fetchShiftBoard(c, 'sh', '2026-11-18');
    expect(c.rpc).toHaveBeenCalledWith('shift_board', { p_shift_id: 'sh', p_date: '2026-11-18' });
  });
  it('turns the generic denial of a read into a 403 PlantError', async () => {
    const c = rpcClient({ data: { ok: false, code: 'not_allowed' }, error: null, status: 200 });
    await expect(fetchMyShift(c)).rejects.toMatchObject({ status: 403, code: 'not_allowed' });
    await expect(fetchShiftBoard(c, 'sh', null)).rejects.toBeInstanceOf(PlantError);
  });
  it('rethrows a network failure untouched', async () => {
    const boom = new TypeError('Failed to fetch');
    const c = rpcClient({ data: null, status: 0, error: boom });
    await expect(fetchMyShift(c)).rejects.toBe(boom);
  });
});
