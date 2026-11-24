import { formatNetwork, type NetCall } from '../../e2e/diagnostics-format';

const call = (i: number, at: number, ms = 300): NetCall => ({ method: 'GET', path: `x.supabase.co/rest/v1/t${i}`, status: 200, ms, at });

describe('network summary (chore/screen-speed step 1)', () => {
  it('prints every API call of a screen (15 calls, no cut after a few lines)', () => {
    const calls = Array.from({ length: 15 }, (_, i) => call(i, i * 100));
    const out = formatNetwork(calls);
    for (let i = 0; i < 15; i++) expect(out).toContain(`rest/v1/t${i}\n`.trim());
    expect(out.split('\n')).toHaveLength(16);
  });
  it('lists calls in start order with a start offset, so parallel and chained calls can be told apart', () => {
    // recorded in finish order: t1 started first but finished last
    const out = formatNetwork([call(2, 50, 100), call(1, 0, 900), call(3, 1000)]);
    const lines = out.split('\n').slice(1);
    expect(lines[0]).toMatch(/^\+\s+0 GET .*t1$/);
    expect(lines[1]).toMatch(/^\+\s+50 GET .*t2$/);
    expect(lines[2]).toMatch(/^\+ 1000 GET .*t3$/);
  });
});
