import { spawnSync } from 'node:child_process';
import path from 'node:path';

const SCRIPT = path.resolve(__dirname, '..', 'drift-check.sh');
const parse = (input: string) => spawnSync('bash', [SCRIPT, '--parse'], { input, encoding: 'utf8' }).stdout.trim();

const header = '\n   Local            | Remote           | Time (UTC)\n  ------------------|------------------|---------------------\n';

describe('drift-check parser (AC-12)', () => {
  it('reports nothing when every migration is on both sides', () => {
    expect(parse(header + '   `20261115000000` | `20261115000000` | `2026-11-15 00:00:00`\n')).toBe('');
  });
  it('detects a migration that dev is missing (local only)', () => {
    expect(parse(header + '   `20261115000000` | `20261115000000` | t\n   `20261120000000` |                  | t\n')).toContain('20261120000000');
  });
  it('detects a migration only on dev (remote only)', () => {
    expect(parse(header + '                    | `20261121000000` | t\n')).toContain('20261121000000');
  });
  it('detects mismatched versions on one row', () => {
    expect(parse(header + '   `20261115000000` | `20261115000001` | t\n')).not.toBe('');
  });
  it('works without backticks (older CLI output)', () => {
    expect(parse(header + '   20261115000000 |                | t\n')).toContain('20261115000000');
  });
});
