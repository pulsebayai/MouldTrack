import { alerts, checklist, hMachine, item, occurrence } from '@/test/handover-fixtures';
import {
  bannerText, fetchHandoverAlerts, fetchHandoverChecklist, handoverApi, openingBlocked, pendingOccurrences, validateExceptionReason, validateMinutes, validateNote, validateRefusal, validateRemark,
} from '../handover';

const rpc = (data: unknown) => jest.fn(async () => ({ data, error: null, status: 200 }));
const client = (fn: jest.Mock) => ({ rpc: fn }) as never;

describe('handover validation (limits equal the server)', () => {
  it('remark is optional, at most 200 characters', () => {
    expect(validateRemark('')).toBeNull();
    expect(validateRemark('   ')).toBeNull();
    expect(validateRemark('x'.repeat(200))).toBeNull();
    expect(validateRemark('x'.repeat(201))).toBe('Remark: up to 200 characters');
  });
  it('a refusal and an exception need 1 to 200 characters', () => {
    for (const f of [validateRefusal, validateExceptionReason]) {
      expect(f('')).toBe('Enter a reason of 1 to 200 characters');
      expect(f('  ')).toBe('Enter a reason of 1 to 200 characters');
      expect(f('a')).toBeNull();
      expect(f('x'.repeat(200))).toBeNull();
      expect(f('x'.repeat(201))).toBe('Enter a reason of 1 to 200 characters');
    }
  });
  it('a note needs 1 to 300 characters', () => {
    expect(validateNote('')).toBe('Enter a note of 1 to 300 characters');
    expect(validateNote('x'.repeat(300))).toBeNull();
    expect(validateNote('x'.repeat(301))).toBe('Enter a note of 1 to 300 characters');
  });
  it('overdue minutes are whole numbers from 15 to 480', () => {
    for (const bad of ['', 'abc', '14', '481', '1.5', '-20', '10000']) expect(validateMinutes(bad)).toBe('Enter 15 to 480 minutes');
    for (const good of ['15', ' 60 ', '480']) expect(validateMinutes(good)).toBeNull();
  });
});

describe('banner and gate decisions', () => {
  const pending = checklist([occurrence([hMachine([item(1), item(2)])])]);
  const ready = checklist([occurrence([hMachine([item(1, { state: 'acknowledged', allowed_actions: [] })])])]);
  const declared = checklist([occurrence([hMachine([item(1, { state: 'acknowledged', allowed_actions: [] })])], { declared: true, allowed_actions: [] })]);
  it('counts what is still to answer, then asks to declare, then says nothing', () => {
    expect(bannerText(pending)).toBe('Handover: 2 to acknowledge');
    expect(bannerText(ready)).toBe('Handover: ready to declare');
    expect(bannerText(declared)).toBeNull();
    expect(bannerText(null)).toBeNull();
    expect(bannerText(checklist([]))).toBeNull();
  });
  it('the opening waits only while the occurrence is enforced and not declared', () => {
    expect(openingBlocked(pending, 'sh-1', '2026-11-18')).toBe(true);
    expect(openingBlocked(declared, 'sh-1', '2026-11-18')).toBe(false);
    expect(openingBlocked(checklist([occurrence([], { enforced: false })]), 'sh-1', '2026-11-18')).toBe(false);
    expect(openingBlocked(pending, 'sh-9', '2026-11-18')).toBe(false); // another shift: not on the checklist
    expect(openingBlocked(pending, 'sh-1', '2026-11-19')).toBe(false);
    expect(openingBlocked(null, 'sh-1', '2026-11-18')).toBe(false);
  });
  it('lists the occurrences still to complete', () => {
    expect(pendingOccurrences(declared)).toHaveLength(0);
    expect(pendingOccurrences(pending)).toHaveLength(1);
  });
});

describe('reads', () => {
  it('the checklist is a POST rpc without arguments and fills missing arrays', async () => {
    const fn = rpc({ ok: true, id: 'new-id' });
    expect(await fetchHandoverChecklist(client(fn))).toEqual({ ok: true, occurrences: [], pending_total: 0, verify: [] });
    expect(fn).toHaveBeenCalledWith('handover_checklist');
  });
  it('alerts fill missing arrays and keep the totals', async () => {
    expect(await fetchHandoverAlerts(client(rpc({ ok: true })))).toEqual({ ok: true, exceptions: [], exceptions_total: 0, overdue: [], overdue_total: 0, alert_count: 0 });
    const a = alerts([]);
    expect(await fetchHandoverAlerts(client(rpc(a)))).toEqual(a);
  });
  it('a denial is an error, not data', async () => {
    await expect(fetchHandoverChecklist(client(rpc({ ok: false, code: 'not_allowed' })))).rejects.toMatchObject({ code: 'not_allowed' });
  });
});

describe('writes send the server parameter names', () => {
  const issueArgs = { issueId: 'i-1', shiftId: 'sh-1', shiftDate: '2026-11-18' };
  it('acknowledge trims and sends null for an empty remark', async () => {
    const fn = rpc({ ok: true, id: 'x' });
    await handoverApi.acknowledge(client(fn), { ...issueArgs, remark: '  ' }, 'r1');
    await handoverApi.acknowledge(client(fn), { ...issueArgs, remark: ' seen ' }, 'r2');
    expect(fn).toHaveBeenNthCalledWith(1, 'ho_acknowledge', { p_request_id: 'r1', p_issue_id: 'i-1', p_shift_id: 'sh-1', p_shift_date: '2026-11-18', p_remark: null });
    expect(fn).toHaveBeenNthCalledWith(2, 'ho_acknowledge', expect.objectContaining({ p_remark: 'seen' }));
  });
  it('refuse, note, declare, exception and overdue', async () => {
    const fn = rpc({ ok: true, id: 'x' });
    const c = client(fn);
    await handoverApi.refuse(c, { ...issueArgs, reason: ' not mine ' }, 'r1');
    await handoverApi.addNote(c, { ...issueArgs, note: ' watch the oil ' }, 'r2');
    await handoverApi.declare(c, { shiftId: 'sh-1', shiftDate: '2026-11-18' }, 'r3');
    await handoverApi.exception(c, { ...issueArgs, reason: ' keep ', ownerId: 's-1' }, 'r4');
    await handoverApi.setOverdue(c, ' 45 ', 'r5');
    expect(fn.mock.calls).toEqual([
      ['ho_refuse', { p_request_id: 'r1', p_issue_id: 'i-1', p_shift_id: 'sh-1', p_shift_date: '2026-11-18', p_reason: 'not mine' }],
      ['ho_add_note', { p_request_id: 'r2', p_issue_id: 'i-1', p_shift_id: 'sh-1', p_shift_date: '2026-11-18', p_note: 'watch the oil' }],
      ['ho_declare', { p_request_id: 'r3', p_shift_id: 'sh-1', p_shift_date: '2026-11-18' }],
      ['ho_exception', { p_request_id: 'r4', p_issue_id: 'i-1', p_shift_id: 'sh-1', p_shift_date: '2026-11-18', p_reason: 'keep', p_owner_id: 's-1' }],
      ['ho_set_overdue', { p_request_id: 'r5', p_minutes: 45 }],
    ]);
  });
  it('a refusal by the server surfaces its code', async () => {
    const fn = jest.fn(async () => ({ data: { ok: false, code: 'not_allowed' }, error: null, status: 200 }));
    await expect(handoverApi.declare(client(fn), { shiftId: 's', shiftDate: 'd' }, 'r')).rejects.toMatchObject({ code: 'not_allowed' });
  });
});
