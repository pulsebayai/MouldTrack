import { spawnSync } from 'node:child_process';
import path from 'node:path';

const filter = path.join(__dirname, '..', 'handover-unenforced.jq');
const hasJq = spawnSync('jq', ['--version']).status === 0;
const run = (rows: unknown[]) => JSON.parse(spawnSync('jq', ['-c', '-f', filter], { input: JSON.stringify(rows) }).stdout.toString());
const d = hasJq ? describe : describe.skip;

d('hosted-checks 10: tenants without handover enforcement', () => {
  it('exempts throwaway e2e / E2E tenants', () => {
    expect(run([{ name: 'e2e org A', handover_setting: null }, { name: 'e2e web org issues', handover_setting: null }, { name: 'E2E t3 ...', handover_setting: null }])).toEqual([]);
  });
  it('flags a real tenant without a setting or with required = false, and names it', () => {
    expect(run([
      { name: 'Acme Plastics', handover_setting: null },
      { name: 'Beta Moulds', handover_setting: { required: false } },
      { name: 'Gamma', handover_setting: { required: true } },
    ])).toEqual(['Acme Plastics', 'Beta Moulds']);
  });
  it('does not exempt look-alike names (no trailing space, lowercase prefix inside)', () => {
    expect(run([{ name: 'e2eorg', handover_setting: null }, { name: 'My e2e org', handover_setting: null }])).toEqual(['e2eorg', 'My e2e org']);
  });
  it('accepts the enforced demo tenant', () => {
    expect(run([{ name: 'Demo Plastics (fixture)', handover_setting: { required: true } }])).toEqual([]);
  });
});
