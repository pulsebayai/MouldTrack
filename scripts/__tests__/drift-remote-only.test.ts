import { spawnSync } from 'node:child_process';
import path from 'node:path';

const SCRIPT = path.resolve(__dirname, '..', 'drift-check.sh');
const remoteOnly = (input: string) => spawnSync('bash', [SCRIPT, '--remote-only'], { input, encoding: 'utf8' }).stdout.trim();
const header = '\n   Local            | Remote           | Time (UTC)\n  ------------------|------------------|---------------------\n';

describe('drift-check --remote-only (dev-reset S8)', () => {
  it('is empty when both sides match', () => {
    expect(remoteOnly(header + '   `20261115000000` | `20261115000000` | t\n')).toBe('');
  });
  it('ignores a migration only the branch has (deploy-dev will push it)', () => {
    expect(remoteOnly(header + '   `20261115000000` | `20261115000000` | t\n   `20261120000000` |                  | t\n')).toBe('');
  });
  it('lists a version only dev has (an unmerged branch proof)', () => {
    expect(remoteOnly(header + '   `20261115000000` | `20261115000000` | t\n                    | `20261121000000` | t\n')).toBe('20261121000000');
  });
  it('works without backticks and ignores header lines', () => {
    expect(remoteOnly(header + '                | 20261121000000 | t\n')).toBe('20261121000000');
  });
});
