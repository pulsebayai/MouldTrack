import { spawnSync } from 'node:child_process';
import path from 'node:path';

const HOOK = path.resolve(__dirname, '..', 'production-gate.sh');

function run(command: string, env: Record<string, string> = {}) {
  const res = spawnSync('bash', [HOOK], {
    input: JSON.stringify({ tool_name: 'Bash', tool_input: { command } }),
    env: { ...process.env, DEV_SUPABASE_PROJECT_REF: '', CLAUDE_PROJECT_DIR: '/nonexistent', ...env },
    encoding: 'utf8',
  });
  return { code: res.status, stderr: res.stderr };
}

describe('production gate hook (AC-11)', () => {
  it.each([
    'git push origin main',
    'git push -u origin main',
    'git push origin HEAD:main',
    'git push --force origin main',
    'git push origin --all',
    'cd x && git push origin main',
    'eas update --channel production --message x',
    'eas update --branch staging',
    'eas deploy --prod',
    'npx eas build --profile production -p android',
    'eas submit --profile production',
    'npx supabase db push',
    'supabase migration up --linked',
    'supabase db push --db-url postgres://u:p@db.prod.example:5432/postgres',
  ])('blocks: %s', (cmd) => {
    const r = run(cmd);
    expect(r.code).toBe(2);
    expect(r.stderr).toContain('BLOCKED by production gate');
  });

  it.each([
    'git push origin feat/01-walking-skeleton',
    'git push -u origin feat/maintenance-mainline',
    'git status',
    'eas update --channel development',
    'eas deploy',
    'eas build --profile development -p android',
    'npx supabase db push --local',
    'supabase db push --db-url postgresql://postgres:postgres@127.0.0.1:54322/postgres',
    'ls -la',
  ])('allows: %s', (cmd) => {
    expect(run(cmd).code).toBe(0);
  });

  it('allows supabase db push only when linked to the dev project ref', () => {
    const fs = require('node:fs');
    const os = require('node:os');
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gate-'));
    fs.mkdirSync(path.join(dir, 'supabase', '.temp'), { recursive: true });
    fs.writeFileSync(path.join(dir, 'supabase', '.temp', 'project-ref'), 'devref123');
    expect(run('npx supabase db push', { CLAUDE_PROJECT_DIR: dir, DEV_SUPABASE_PROJECT_REF: 'devref123' }).code).toBe(0);
    expect(run('npx supabase db push', { CLAUDE_PROJECT_DIR: dir, DEV_SUPABASE_PROJECT_REF: 'otherref' }).code).toBe(2);
  });

  it('passes through malformed input', () => {
    const res = spawnSync('bash', [HOOK], { input: 'not json', encoding: 'utf8' });
    expect(res.status).toBe(0);
  });
});
