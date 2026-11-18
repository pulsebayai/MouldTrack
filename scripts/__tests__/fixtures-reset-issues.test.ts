import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { ISSUES, PLANT, USERS, needsFreshCopy } from '../fixtures-reset';

// 07 (D12): fixture issues. The seed file (local/CI) and ISSUES (hosted dev) must agree.
const seed = readFileSync(join(__dirname, '../../supabase/seed.sql'), 'utf8');

describe('fixtures-reset 07 issue fixtures (D12)', () => {
  it('covers orgs U and A: a stopped Critical, a High awaiting verification, a closed Low, and one open issue for supA', () => {
    // owner-approved 2026-11-18 (08 option A): e2e org H added
    expect(ISSUES.map((i) => `${i.tenant}:${i.priority}:${i.status}`).sort()).toEqual([
      'e2e org A:medium:open', 'e2e org H:high:open', 'e2e org H:medium:open', 'e2e org U:critical:open', 'e2e org U:high:resolved', 'e2e org U:low:closed',
    ]);
    const stopped = ISSUES.filter((i) => i.stopped);
    expect(stopped).toHaveLength(1);
    expect(stopped[0].priority).toBe('critical'); // a stopped machine is always Critical
  });
  it('uses unique ids, existing fixture machines and supervisors of the same tenant', () => {
    expect(new Set(ISSUES.map((i) => i.id)).size).toBe(ISSUES.length);
    for (const i of ISSUES) {
      expect(i.id).toMatch(/^60000000-0000-4000-a000-[0-9a-f]{12}$/);
      const plant = PLANT.find((p) => p.tenant === i.tenant)!;
      expect(plant.machines.map((m) => m.code)).toContain(i.machine);
      const user = USERS.find((u) => u.key === i.reporter)!;
      expect(user.tenant).toBe(i.tenant);
      expect(user.role).toBe('supervisor');
    }
  });
  it('resolved and closed issues carry a resolve time and notes; open ones do not; every description is distinct fixture text', () => {
    for (const i of ISSUES) {
      if (i.status === 'open') expect(i.resolvedAt).toBeUndefined();
      else { expect(i.resolvedAt && i.resolvedAt > i.reportedAt).toBe(true); expect(i.resolution).toMatch(/^Fixture resolution/); }
      expect(i.description).toMatch(/^Fixture issue: /);
    }
    expect(new Set(ISSUES.map((i) => i.description)).size).toBe(ISSUES.length);
  });
  it('the High awaiting verification sits on a machine no shift assigns, so a Unit Admin can verify it', () => {
    const high = ISSUES.find((i) => i.status === 'resolved')!;
    expect(high.machine).toBe('FX-MU3');
  });
  it('the seed file defines every fixture issue (id, description, times, resolution)', () => {
    for (const i of ISSUES) {
      expect(seed).toContain(`'${i.id}'`);
      expect(seed).toContain(`'${i.description}'`);
      expect(seed).toContain(`timestamptz '${i.reportedAt}'`);
      if (i.resolvedAt) { expect(seed).toContain(`timestamptz '${i.resolvedAt}'`); expect(seed).toContain(`'${i.resolution}'`); }
      expect(seed).toContain(`'${i.priority}', '${i.status}', ${i.stopped}`);
    }
  });
});

describe('N-14: the awaiting-verification fixture is recreated when it was consumed', () => {
  const awaiting = ISSUES.find((i) => i.status === 'resolved')!;
  const open = ISSUES.find((i) => i.status === 'open')!;
  it('a fresh copy only when the seeded one is no longer resolved and no resolved copy exists', () => {
    expect(needsFreshCopy(awaiting, { status: 'closed' }, 0)).toBe(true);
    expect(needsFreshCopy(awaiting, { status: 'in_progress' }, 0)).toBe(true);
    expect(needsFreshCopy(awaiting, { status: 'closed' }, 1)).toBe(false);
    expect(needsFreshCopy(awaiting, { status: 'resolved' }, 0)).toBe(false);
    expect(needsFreshCopy(awaiting, null, 0)).toBe(false); // missing: the normal insert path
  });
  it('the other fixtures are never copied', () => {
    expect(needsFreshCopy(open, { status: 'closed' }, 0)).toBe(false);
  });
});
