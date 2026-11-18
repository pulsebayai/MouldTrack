import {
  DEMO_ASSIGNMENTS, DEMO_MACHINES, DEMO_PRODUCTS, DEMO_SHIFTS, DEMO_USERS, DEMO_LINES, addDays, buildIssues, buildOccurrences, demoCounts, planOwner, stamp, summarise,
} from '../dev-demo-spec';
import { USERS, SUPER_ADMINS, isCanonicalPhone } from '../fixtures-reset';

const TODAY = '2026-11-18';

describe('demo spec: identities', () => {
  it('uses unused canonical fixture phones with derived .invalid addresses', () => {
    const taken = new Set([...USERS, ...SUPER_ADMINS].map((u) => u.phone));
    for (const u of DEMO_USERS) {
      expect(isCanonicalPhone(u.phone)).toBe(true);
      expect(taken.has(u.phone)).toBe(false);
    }
    expect(new Set(DEMO_USERS.map((u) => u.phone)).size).toBe(DEMO_USERS.length);
    expect(DEMO_USERS.map((u) => u.role)).toEqual(['unit_admin', 'supervisor', 'supervisor']);
  });
  it('has the agreed shape', () => {
    expect(DEMO_MACHINES).toHaveLength(10);
    expect(DEMO_PRODUCTS).toHaveLength(4);
    expect(DEMO_LINES).toHaveLength(2);
    expect(DEMO_SHIFTS.map((s) => s.name)).toEqual(['Day', 'Night']);
    expect(DEMO_ASSIGNMENTS).toHaveLength(20);
    expect(DEMO_MACHINES.some((x) => x.unit === 'pieces')).toBe(true);
    expect(DEMO_MACHINES.some((x) => x.unit === 'shots')).toBe(true);
    expect(DEMO_MACHINES.some((x) => x.max !== null)).toBe(true);
    expect(DEMO_MACHINES.some((x) => x.cavities !== null)).toBe(true);
    for (const x of DEMO_MACHINES) expect(DEMO_PRODUCTS.some((p) => p.code === x.product)).toBe(true);
  });
  it('plan owners differ between Day and Night so a verifier exists for every machine', () => {
    for (let i = 0; i < 10; i++) expect(planOwner('Day', i)).not.toBe(planOwner('Night', i));
  });
});

describe('demo spec: dates', () => {
  it('adds days and stamps with the Kolkata offset, overnight rolls to the next date', () => {
    expect(addDays('2026-11-30', 1)).toBe('2026-12-01');
    expect(stamp('2026-11-10', 365)).toBe('2026-11-10T06:05:00+05:30');
    expect(stamp('2026-11-10', 1800)).toBe('2026-11-11T06:00:00+05:30');
  });
});

describe('summarise mirrors app._rd_compute_summary (06 fixtures pinned by pgTAP 052)', () => {
  it('shots x cavities', () => {
    const s = summarise({ unit: 'shots', cavities: 4, max: null, opening: 1000, closing: 1250, good: 950, reject: 30, target: 1200 });
    expect([s.movementUnits, s.movementPieces, s.unaccounted, s.attainmentPct, s.rollover, s.needsReview]).toEqual([250, 1000, 20, 79.17, false, false]);
  });
  it('rollover with a maximum', () => {
    const s = summarise({ unit: 'pieces', cavities: 1, max: 999999, opening: 999900, closing: 100, good: 150, reject: 10, target: 800 });
    expect([s.movementUnits, s.movementPieces, s.unaccounted, s.attainmentPct, s.rollover]).toEqual([200, 200, 40, 18.75, true]);
  });
  it('closing below opening without a maximum needs review and is never guessed', () => {
    const s = summarise({ unit: 'pieces', cavities: 1, max: null, opening: 500, closing: 100, good: 10, reject: 1, target: 100 });
    expect([s.movementUnits, s.movementPieces, s.unaccounted, s.needsReview, s.overReported]).toEqual([null, null, null, true, false]);
  });
  it('a pieces counter ignores cavities', () => expect(summarise({ unit: 'pieces', cavities: 8, max: null, opening: 0, closing: 10, good: 10, reject: 0, target: null }).movementPieces).toBe(10));
  it('over-reported when good + reject exceeds the movement', () =>
    expect(summarise({ unit: 'pieces', cavities: 1, max: null, opening: 0, closing: 100, good: 90, reject: 20, target: 100 }).overReported).toBe(true));
  it('rounds half up like numeric', () => {
    expect(summarise({ unit: 'pieces', cavities: 1, max: null, opening: 0, closing: 1, good: 1, reject: 0, target: 8 }).attainmentPct).toBe(12.5);
    expect(summarise({ unit: 'pieces', cavities: 1, max: null, opening: 0, closing: 1, good: 1, reject: 0, target: 3 }).attainmentPct).toBe(33.33);
    expect(summarise({ unit: 'pieces', cavities: 1, max: null, opening: 0, closing: 1, good: 79165, reject: 0, target: 100000 }).attainmentPct).toBe(79.17);
  });
  it('null target gives null attainment', () => expect(summarise({ unit: 'pieces', cavities: 1, max: null, opening: 0, closing: 1, good: 1, reject: 0, target: null }).attainmentPct).toBeNull());
});

describe('demo spec: history', () => {
  const occ = buildOccurrences(TODAY);
  it('covers the last 7 plant days; Night never starts on the last day', () => {
    const dates = new Set(occ.map((o) => o.date));
    expect([...dates].sort()).toEqual([-7, -6, -5, -4, -3, -2, -1].map((n) => addDays(TODAY, n)));
    expect(occ.filter((o) => o.shift === 'Night').every((o) => o.date < addDays(TODAY, -1))).toBe(true);
    expect(occ.filter((o) => o.shift === 'Day')).toHaveLength(70);
    expect(occ.filter((o) => o.shift === 'Night')).toHaveLength(24);
  });
  it('has one opening and closing per machine-occurrence and nothing in the future', () => {
    const keys = occ.map((o) => `${o.machine}|${o.shift}|${o.date}`);
    expect(new Set(keys).size).toBe(keys.length);
    for (const o of occ) expect(new Date(o.closingAt).getTime()).toBeLessThanOrEqual(new Date(stamp(TODAY, 360)).getTime());
  });
  it('shows every state the product has', () => {
    expect(occ.some((o) => o.summary.rollover)).toBe(true);
    expect(occ.some((o) => o.summary.needsReview)).toBe(true);
    expect(occ.some((o) => o.summary.overReported)).toBe(true);
    expect(occ.some((o) => o.lateOpening)).toBe(true);
    expect(occ.some((o) => o.lateClosing)).toBe(true);
    expect(occ.some((o) => o.earlyClosing)).toBe(true);
    expect(occ.some((o) => o.enteredByUa)).toBe(true);
    expect(occ.some((o) => o.lateClosing && o.earlyClosing)).toBe(false);
  });
  it('continues each machine counter from one occurrence to the next, within its maximum', () => {
    for (const mm of DEMO_MACHINES) {
      const rows = occ.filter((o) => o.machine === mm.code);
      expect(rows[0].opening).toBe(mm.startCounter);
      rows.slice(1).forEach((o, i) => expect(o.opening).toBe(rows[i].closing));
      if (mm.max !== null) for (const o of rows) { expect(o.opening).toBeLessThanOrEqual(mm.max); expect(o.closing).toBeLessThanOrEqual(mm.max); }
      for (const o of rows) expect(o.opening).toBeGreaterThanOrEqual(0);
    }
  });
  it('keeps the readings valid for the table constraints', () => {
    for (const o of occ) {
      expect(o.good).toBeGreaterThanOrEqual(0);
      expect(o.reject).toBeGreaterThanOrEqual(0);
      expect(o.good + o.reject).toBeLessThan(10_000_000);
      expect(o.summary.cavities).toBeGreaterThanOrEqual(1);
      expect(o.summary.cavities).toBeLessThanOrEqual(256);
    }
  });
  it('records by the plan owner unless the Unit Admin entered it', () => {
    occ.forEach((o) => {
      const i = DEMO_MACHINES.findIndex((x) => x.code === o.machine);
      expect(o.actor).toBe(o.enteredByUa ? 'ua' : planOwner(o.shift, i));
    });
  });
  it('is deterministic and the counts do not depend on the date', () => {
    expect(buildOccurrences(TODAY)).toEqual(occ);
    expect(demoCounts('2027-02-03')).toEqual(demoCounts(TODAY));
    expect(buildOccurrences('2027-02-03').map((o) => [o.machine, o.opening, o.closing, o.good])).toEqual(occ.map((o) => [o.machine, o.opening, o.closing, o.good]));
  });
});

describe('demo spec: issues', () => {
  const issues = buildIssues(TODAY);
  it('has 5-8 issues covering the required states', () => {
    expect(issues.length).toBeGreaterThanOrEqual(5);
    expect(issues.length).toBeLessThanOrEqual(8);
    expect(issues.some((i) => i.status === 'open' && i.priority === 'critical' && i.stopped)).toBe(true);
    expect(issues.some((i) => i.status === 'resolved' && ['high', 'critical'].includes(i.priority))).toBe(true);
    expect(issues.filter((i) => i.status === 'closed').length).toBeGreaterThanOrEqual(2);
  });
  it('satisfies the table checks', () => {
    for (const i of issues) {
      if (i.stopped) expect(i.priority).toBe('critical');
      if (i.status === 'closed') expect(i.closedAt).toBeDefined();
      else expect(i.closedAt).toBeUndefined();
      if (['resolved', 'closed'].includes(i.status)) { expect(i.resolvedAt).toBeDefined(); expect(i.resolvedBy).toBeDefined(); }
      expect(i.description.length).toBeLessThanOrEqual(1000);
      expect(DEMO_MACHINES.some((x) => x.code === i.machine)).toBe(true);
    }
  });
  it('closes Low/Medium on resolve and High/Critical only by verification of another supervisor', () => {
    for (const i of issues.filter((x) => x.status === 'closed')) {
      const types = i.events.map((e) => e.type);
      if (['low', 'medium'].includes(i.priority)) expect(types).toEqual(['report', 'resolve']);
      else { expect(types).toEqual(['report', 'resolve', 'verify_confirm']); expect(i.closedBy).not.toBe(i.resolvedBy); }
    }
  });
  it('a resolved High/Critical has an eligible verifier: the owner of a later occurrence differs from the resolver', () => {
    for (const i of issues.filter((x) => x.status === 'resolved')) {
      const idx = DEMO_MACHINES.findIndex((x) => x.code === i.machine);
      expect(planOwner('Night', idx)).not.toBe(i.resolvedBy);
    }
  });
  it('events are chronological and consistent', () => {
    for (const i of issues) {
      expect(i.events[0].type).toBe('report');
      const times = i.events.map((e) => new Date(e.at).getTime());
      expect([...times].sort((a, b) => a - b)).toEqual(times);
      expect(i.events.at(-1)!.after).toBe(i.status);
    }
  });
  it('lies in the past', () => {
    for (const i of issues) for (const e of i.events) expect(new Date(e.at).getTime()).toBeLessThan(new Date(stamp(TODAY, 0)).getTime() + 86_400_000);
  });
});
