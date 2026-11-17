import { closeThrowawayIssues, nextCall, selectThrowaway } from '../close-throwaway-issues';

const it_ = (id: string, description: string, status: string) => ({ id, description, status });

describe('close-throwaway-issues (07 D16)', () => {
  it('selects only open, non-fixture issues whose description starts with "E2E "', () => {
    const rows = [
      it_('1', 'E2E hydraulic leak abc', 'open'),
      it_('2', 'Fixture issue: guard door sticks', 'open'),
      it_('3', 'E2E done', 'closed'),
      it_('4', 'Maestro guard door sticks', 'open'),
      it_('5', 'E2E waiting', 'resolved'),
      it_('6', 'e2e lower case', 'open'),
    ];
    expect(selectThrowaway(rows).map((r) => r.id)).toEqual(['1', '5']);
  });

  it('resolves open work, verifies what awaits verification, and leaves the rest', () => {
    expect(nextCall('open')).toBe('iss_resolve');
    expect(nextCall('in_progress')).toBe('iss_resolve');
    expect(nextCall('resolved')).toBe('iss_verify');
    expect(nextCall('closed')).toBeNull();
  });

  it('closes through the RPCs (resolve, then verify for a High) and counts what it could not close', async () => {
    const calls: string[] = [];
    const rpc = jest.fn(async (fn: string, args: Record<string, unknown>) => {
      calls.push(`${fn}:${String(args.p_issue_id ?? '')}`);
      if (fn === 'issue_list') {
        return { error: null, data: { ok: true, total: 3, page_size: 25, items: [it_('a', 'E2E low', 'open'), it_('b', 'E2E high', 'in_progress'), it_('c', 'E2E stuck', 'open')] } };
      }
      if (fn === 'iss_resolve') return { error: null, data: args.p_issue_id === 'c' ? { ok: false, code: 'not_allowed' } : { ok: true, status: args.p_issue_id === 'b' ? 'resolved' : 'closed' } };
      return { error: null, data: { ok: true } };
    });
    const r = await closeThrowawayIssues({ rpc } as never);
    expect(r).toEqual({ closed: 2, left: 1 });
    expect(calls).toEqual(['issue_list:', 'iss_resolve:a', 'iss_resolve:b', 'iss_verify:b', 'iss_resolve:c']);
  });

  it('pages through the whole list', async () => {
    const rpc = jest.fn(async (_fn: string, args: Record<string, unknown>) => ({
      error: null, data: { ok: true, total: 30, page_size: 25, items: args.p_page === 1 ? [it_('x', 'Fixture issue', 'open')] : [] },
    }));
    await closeThrowawayIssues({ rpc } as never);
    expect(rpc).toHaveBeenCalledTimes(2);
  });
});
