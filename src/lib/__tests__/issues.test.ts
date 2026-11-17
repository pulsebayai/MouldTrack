import AsyncStorage from '@react-native-async-storage/async-storage';
import {
  PlantError,
} from '@/lib/plant';
import {
  effectivePriority, fetchCategories, fetchIssueAlerts, fetchIssueDetail, fetchIssueList, formatAge, issueApi, validateReport, validateText,
} from '@/lib/issues';
import { clearDraft, loadDraft, saveDraft } from '@/lib/issue-draft';
import { fakeDb } from '@/test/fake-db';

jest.mock('@react-native-async-storage/async-storage', () => {
  const store = new Map<string, string>();
  const api = {
    getItem: jest.fn(async (k: string) => store.get(k) ?? null),
    setItem: jest.fn(async (k: string, v: string) => void store.set(k, v)),
    removeItem: jest.fn(async (k: string) => void store.delete(k)),
    clear: jest.fn(async () => store.clear()),
  };
  return { __esModule: true, default: api };
});

const rpcClient = (data: unknown, error: unknown = null, status = 200) => {
  const rpc = jest.fn().mockResolvedValue({ data, error, status });
  return { rpc, client: { rpc } as never };
};

describe('report form rules mirror the server', () => {
  it('a stopped machine forces Critical', () => {
    expect(effectivePriority('low', true)).toBe('critical');
    expect(effectivePriority('low', false)).toBe('low');
    expect(effectivePriority(null, false)).toBeNull();
  });
  it('requires category, description and priority', () => {
    expect(validateReport({ categoryId: null, priority: null, description: ' ', stopped: false })).toEqual({
      category_id: 'Choose a category', description: 'Describe the problem in 1 to 1000 characters', priority: 'Choose a priority',
    });
    expect(validateReport({ categoryId: 'c', priority: null, description: 'Leak', stopped: true })).toEqual({});
    expect(validateReport({ categoryId: 'c', priority: 'low', description: 'x'.repeat(1001), stopped: false }).description).toBeDefined();
  });
  it('validates a free-text field', () => {
    expect(validateText('  ', 500, 'bad')).toBe('bad');
    expect(validateText('ok', 500, 'bad')).toBeNull();
    expect(validateText('x'.repeat(501), 500, 'bad')).toBe('bad');
  });
  it.each([[0, 'just now'], [5, '5 min'], [75, '1 h 15 min'], [60 * 49, '2 days']])('formats age %i', (m, s) => expect(formatAge(m)).toBe(s));
});

describe('issue RPC wrappers', () => {
  it('report sends the named arguments and trims the description', async () => {
    const { rpc, client } = rpcClient({ ok: true, id: 'i1' });
    await issueApi.report(client, { machineId: 'm', categoryId: 'c', priority: 'high', description: '  Leak  ', stopped: false }, 'r1');
    expect(rpc).toHaveBeenCalledWith('iss_report', { p_request_id: 'r1', p_machine_id: 'm', p_category_id: 'c', p_priority: 'high', p_description: 'Leak', p_machine_stopped: false });
  });
  it.each([
    ['note', (c: never) => issueApi.note(c, 'i', ' n ', 'r'), 'iss_note', { p_request_id: 'r', p_issue_id: 'i', p_notes: 'n' }],
    ['start', (c: never) => issueApi.start(c, 'i', 'r'), 'iss_start', { p_request_id: 'r', p_issue_id: 'i' }],
    ['assignee', (c: never) => issueApi.setAssignee(c, 'i', 'Ravi', 'r'), 'iss_set_assignee', { p_request_id: 'r', p_issue_id: 'i', p_assignee: 'Ravi' }],
    ['escalate', (c: never) => issueApi.escalate(c, 'i', 'why', 'r'), 'iss_escalate', { p_request_id: 'r', p_issue_id: 'i', p_reason: 'why' }],
    ['ack', (c: never) => issueApi.ackEscalation(c, 'i', 'seen', 'r'), 'iss_ack_escalation', { p_request_id: 'r', p_issue_id: 'i', p_note: 'seen' }],
    ['reassign', (c: never) => issueApi.reassign(c, 'i', 'u', 'cover', 'r'), 'iss_reassign', { p_request_id: 'r', p_issue_id: 'i', p_new_owner: 'u', p_reason: 'cover' }],
    ['resolve', (c: never) => issueApi.resolve(c, 'i', 'fixed', 'r'), 'iss_resolve', { p_request_id: 'r', p_issue_id: 'i', p_notes: 'fixed' }],
    ['confirm', (c: never) => issueApi.verify(c, 'i', true, null, 'r'), 'iss_verify', { p_request_id: 'r', p_issue_id: 'i', p_confirm: true, p_reason: null }],
    ['reject', (c: never) => issueApi.verify(c, 'i', false, ' still leaking ', 'r'), 'iss_verify', { p_request_id: 'r', p_issue_id: 'i', p_confirm: false, p_reason: 'still leaking' }],
    ['reopen', (c: never) => issueApi.reopen(c, 'i', 'back', 'r'), 'iss_reopen', { p_request_id: 'r', p_issue_id: 'i', p_reason: 'back' }],
    ['cat save', (c: never) => issueApi.saveCategory(c, null, ' Moulds ', 'r'), 'iss_category_save', { p_request_id: 'r', p_id: null, p_name: 'Moulds' }],
    ['cat retire', (c: never) => issueApi.setCategoryRetired(c, 'c', true, 'r'), 'iss_category_set_retired', { p_request_id: 'r', p_id: 'c', p_retired: true }],
  ])('%s calls its RPC', async (_n, run, fn, args) => {
    const { rpc, client } = rpcClient({ ok: true });
    await run(client);
    expect(rpc).toHaveBeenCalledWith(fn, args);
  });
  it('a denial becomes a not-allowed error', async () => {
    const { client } = rpcClient({ ok: false, code: 'not_allowed' });
    await expect(issueApi.start(client, 'i', 'r')).rejects.toMatchObject({ name: 'PlantError', status: 403, code: 'not_allowed' });
  });
  it('a validation error carries the server message and field', async () => {
    const { client } = rpcClient(null, { code: 'P0001', message: 'Choose a category', details: '{"code":"validation","field":"category_id"}' }, 400);
    await expect(issueApi.report(client, { machineId: 'm', categoryId: 'c', priority: 'low', description: 'x', stopped: false }, 'r')).rejects.toBeInstanceOf(PlantError);
    await expect(issueApi.report(client, { machineId: 'm', categoryId: 'c', priority: 'low', description: 'x', stopped: false }, 'r')).rejects.toMatchObject({ field: 'category_id' });
  });
});

describe('issue reads', () => {
  it('list, detail and alerts call their RPCs', async () => {
    const list = rpcClient({ ok: true, items: [], total: 0, page: 1, page_size: 25 });
    await fetchIssueList(list.client, { status: 'not_closed', stopped: true }, 2);
    expect(list.rpc).toHaveBeenCalledWith('issue_list', { p_filters: { status: 'not_closed', stopped: true }, p_page: 2 });
    const det = rpcClient({ ok: true });
    await fetchIssueDetail(det.client, 'i1');
    expect(det.rpc).toHaveBeenCalledWith('issue_detail', { p_id: 'i1' });
    const al = rpcClient({ ok: true, alert_count: 0, alerts: [], recently_closed: [] });
    await fetchIssueAlerts(al.client);
    expect(al.rpc).toHaveBeenCalledWith('issue_alerts');
  });
  it('a denied read throws', async () => {
    const { client } = rpcClient({ ok: false, code: 'not_allowed' });
    await expect(fetchIssueDetail(client, 'i1')).rejects.toMatchObject({ code: 'not_allowed' });
  });
  it('categories hide retired ones unless asked', async () => {
    const db = fakeDb(() => ({ data: [{ id: 'c1', name: 'Hydraulics', retired_at: null }], error: null }));
    expect(await fetchCategories(db.client as never)).toHaveLength(1);
    expect(db.queries[0].filters).toContainEqual(['is', 'retired_at', null]);
    await fetchCategories(db.client as never, { includeRetired: true });
    expect(db.queries[1].filters).toEqual([]);
  });
});

describe('local draft', () => {
  beforeEach(() => AsyncStorage.clear());
  it('round-trips and clears per machine', async () => {
    const d = { categoryId: 'c', priority: 'high' as const, description: 'Leak', stopped: false };
    await saveDraft('m1', d);
    expect(await loadDraft('m1')).toEqual(d);
    expect(await loadDraft('m2')).toBeNull();
    await clearDraft('m1');
    expect(await loadDraft('m1')).toBeNull();
  });
});
