/**
 * Demo tenant "Demo Plastics (fixture)" (dev-reset D9): a deterministic specification, pure functions only (no I/O).
 * `buildDemo(today)` returns every row the seed inserts; history is dated relative to `today` (the plant date of the reset), so the
 * row COUNTS are identical on every run while the dates move with the calendar. Everything here is invented fixture data:
 * invented names, phones only in the canonical block +91 90000 00001-00099 (00010-00012 were unused anywhere else), no real plant data.
 *
 * The summary arithmetic mirrors app._rd_compute_summary (calc_version 1); scripts/demo-checks.sql proves the equality against the
 * server's own function in CI, so a drift between the two fails the build.
 */

export const DEMO_TENANT_NAME = 'Demo Plastics (fixture)';
export const DEMO_SITE_NAME = 'Demo Plant';
export const DEMO_PLAN_FROM = '2026-01-01';

export type DemoUserKey = 'ua' | 's1' | 's2';
export type DemoUser = { key: DemoUserKey; phone: string; name: string; employeeId: string; role: 'unit_admin' | 'supervisor' };
export const DEMO_USERS: DemoUser[] = [
  { key: 'ua', phone: '+919000000010', name: 'Demo Admin', employeeId: 'DM-UA', role: 'unit_admin' },
  { key: 's1', phone: '+919000000011', name: 'Demo Supervisor One', employeeId: 'DM-S1', role: 'supervisor' },
  { key: 's2', phone: '+919000000012', name: 'Demo Supervisor Two', employeeId: 'DM-S2', role: 'supervisor' },
];

export const DEMO_LINES = ['Demo Line A', 'Demo Line B'];

export type DemoProduct = { code: string; description: string };
export const DEMO_PRODUCTS: DemoProduct[] = [
  { code: 'DP-1', description: 'Demo bottle cap 28 mm' },
  { code: 'DP-2', description: 'Demo container lid' },
  { code: 'DP-3', description: 'Demo pipe fitting' },
  { code: 'DP-4', description: 'Demo toy part' },
];

export type DemoMachine = {
  code: string;
  name: string;
  line: string;
  unit: 'pieces' | 'shots';
  max: number | null; // counter maximum (rollover)
  product: string; // the product it runs all week
  target: number; // pieces per shift
  cavities: number | null; // effective-dated cavity row (shots machines), null = none set
  startCounter: number;
};
const m = (n: number, o: Omit<DemoMachine, 'code' | 'name' | 'line'>): DemoMachine => ({
  code: `DM-${String(n).padStart(2, '0')}`,
  name: `Demo Press ${String(n).padStart(2, '0')}`,
  line: n <= 5 ? DEMO_LINES[0] : DEMO_LINES[1],
  ...o,
});
export const DEMO_MACHINES: DemoMachine[] = [
  m(1, { unit: 'pieces', max: null, product: 'DP-1', target: 1200, cavities: null, startCounter: 12000 }),
  m(2, { unit: 'pieces', max: null, product: 'DP-1', target: 1200, cavities: null, startCounter: 22000 }),
  m(3, { unit: 'pieces', max: 999999, product: 'DP-2', target: 900, cavities: null, startCounter: 999000 }), // rolls over during the week
  m(4, { unit: 'pieces', max: null, product: 'DP-2', target: 900, cavities: null, startCounter: 42000 }),
  m(5, { unit: 'pieces', max: null, product: 'DP-3', target: 600, cavities: null, startCounter: 52000 }),
  m(6, { unit: 'pieces', max: null, product: 'DP-3', target: 600, cavities: null, startCounter: 62000 }),
  m(7, { unit: 'shots', max: null, product: 'DP-4', target: 1000, cavities: 4, startCounter: 7000 }),
  m(8, { unit: 'shots', max: null, product: 'DP-1', target: 1100, cavities: 2, startCounter: 8000 }),
  m(9, { unit: 'shots', max: null, product: 'DP-2', target: 500, cavities: null, startCounter: 9000 }), // shots with no cavities set: counts 1 piece per shot
  m(10, { unit: 'shots', max: 99999, product: 'DP-4', target: 1600, cavities: 8, startCounter: 99300 }), // rolls over during the week
];

export type DemoShift = { name: 'Day' | 'Night'; start: string; end: string; startMin: number; endMin: number };
export const DEMO_SHIFTS: DemoShift[] = [
  { name: 'Day', start: '06:00', end: '18:00', startMin: 360, endMin: 1080 },
  { name: 'Night', start: '18:00', end: '06:00', startMin: 1080, endMin: 1800 }, // overnight: ends 06:00 the next plant date
];

/** The recurring plan: s1 runs machines 1-5 by day and 6-10 by night; s2 the other way round. */
export function planOwner(shift: DemoShift['name'], machineIndex: number): DemoUserKey {
  const first = machineIndex < 5;
  return shift === 'Day' ? (first ? 's1' : 's2') : first ? 's2' : 's1';
}
export const DEMO_ASSIGNMENTS = DEMO_SHIFTS.flatMap((s) => DEMO_MACHINES.map((mm, i) => ({ shift: s.name, machine: mm.code, supervisor: planOwner(s.name, i) })));

// ---- date helpers (plant dates are plain YYYY-MM-DD in Asia/Kolkata, +05:30, no DST) ----
export const addDays = (date: string, n: number): string => {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};
export const plantToday = (now: Date = new Date()): string => new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Kolkata' }).format(now);
/** A timestamp `minutes` after 00:00 of the plant date (may exceed 1440 for an overnight shift), with the Kolkata offset. */
export const stamp = (date: string, minutes: number): string => {
  const day = Math.floor(minutes / 1440);
  const rem = minutes - day * 1440;
  const hh = String(Math.floor(rem / 60)).padStart(2, '0');
  const mm = String(rem % 60).padStart(2, '0');
  return `${addDays(date, day)}T${hh}:${mm}:00+05:30`;
};

// ---- the production summary calculation (calc_version 1), identical to app._rd_compute_summary ----
export type SummaryInput = {
  unit: 'pieces' | 'shots';
  cavities: number; // multiplier already resolved (1 when unset); ignored for a pieces counter
  max: number | null;
  opening: number;
  closing: number;
  good: number;
  reject: number;
  target: number | null;
};
export type SummaryOut = {
  cavities: number;
  movementUnits: number | null;
  movementPieces: number | null;
  unaccounted: number | null;
  attainmentPct: number | null;
  rollover: boolean;
  needsReview: boolean;
  overReported: boolean;
};
export function summarise(i: SummaryInput): SummaryOut {
  const cav = i.unit === 'shots' ? i.cavities : 1;
  let units: number | null = null;
  let rollover = false;
  let needsReview = false;
  if (i.closing >= i.opening) units = i.closing - i.opening;
  else if (i.max !== null && i.opening <= i.max) {
    units = i.max + 1 - i.opening + i.closing;
    rollover = true;
  } else needsReview = true;
  const pieces = units === null ? null : units * cav;
  // round(good * 100.0 / target, 2) in exact integer arithmetic (half up), so JS floats cannot differ from numeric
  const attainmentPct = i.target === null ? null : Math.floor((i.good * 20000 + i.target) / (2 * i.target)) / 100;
  return {
    cavities: cav,
    movementUnits: units,
    movementPieces: pieces,
    unaccounted: pieces === null ? null : pieces - i.good - i.reject,
    attainmentPct,
    rollover,
    needsReview,
    overReported: pieces !== null && i.good + i.reject > pieces,
  };
}

// ---- readings ----
export type DemoOccurrence = {
  machine: string;
  shift: DemoShift['name'];
  date: string;
  product: string;
  actor: DemoUserKey; // who recorded both readings
  opening: number;
  closing: number;
  good: number;
  reject: number;
  lateOpening: boolean;
  lateClosing: boolean;
  earlyClosing: boolean;
  enteredByUa: boolean;
  openingAt: string;
  closingAt: string;
  summary: SummaryOut;
};

/** Small deterministic generator (mulberry32): same sequence on every run. */
function rng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const NIGHT_MACHINES = ['DM-01', 'DM-02', 'DM-06', 'DM-07'];
export const DEMO_DAY_COUNT = 7;

/**
 * Day shift on each of the last 7 plant days (D-7..D-1) for all machines, Night shift on D-7..D-2 for four machines (a Night occurrence that
 * started on D-1 may still be running when the reset happens at 02:30, so none is created). Counters continue from one occurrence to the next.
 */
export function buildOccurrences(today: string): DemoOccurrence[] {
  const out: DemoOccurrence[] = [];
  const counter = new Map(DEMO_MACHINES.map((mm) => [mm.code, mm.startCounter]));
  const rand = rng(20261118);
  let idx = 0;
  for (let back = DEMO_DAY_COUNT; back >= 1; back--) {
    const date = addDays(today, -back);
    for (const shift of DEMO_SHIFTS) {
      if (shift.name === 'Night' && back < 2) continue;
      DEMO_MACHINES.forEach((mm, mi) => {
        if (shift.name === 'Night' && !NIGHT_MACHINES.includes(mm.code)) return;
        idx++;
        const cav = mm.unit === 'shots' ? (mm.cavities ?? 1) : 1;
        const opening = counter.get(mm.code)!;
        const factor = 0.72 + rand() * 0.36;
        const units = Math.round((mm.target * factor) / cav);
        const pieces = units * cav;
        let reject = Math.round(pieces * (0.005 + rand() * 0.02));
        let good = pieces - reject - Math.round(pieces * rand() * 0.015);
        let closing: number;
        if (mm.max !== null && opening + units > mm.max) closing = opening + units - (mm.max + 1); // wraps once
        else closing = opening + units;

        // Deliberate exceptions so the owner sees every state the product shows.
        if (mm.code === 'DM-02' && shift.name === 'Day' && back === 3) closing = opening - 40; // no maximum: Needs review
        if (mm.code === 'DM-05' && shift.name === 'Day' && back === 5) { reject = Math.round(pieces * 0.02); good = pieces - reject + 20; } // Over-reported

        const lateOpening = idx % 17 === 3;
        const lateClosing = idx % 19 === 5;
        const earlyClosing = !lateClosing && idx % 23 === 7;
        const enteredByUa = idx % 29 === 11;
        const actor: DemoUserKey = enteredByUa ? 'ua' : planOwner(shift.name, mi);
        const openingAt = stamp(date, shift.startMin + (lateOpening ? 50 : 5));
        const closingAt = stamp(date, shift.endMin + (lateClosing ? 45 : earlyClosing ? -45 : 5));
        const summary = summarise({ unit: mm.unit, cavities: cav, max: mm.max, opening, closing, good, reject, target: mm.target });
        out.push({ machine: mm.code, shift: shift.name, date, product: mm.product, actor, opening, closing, good, reject, lateOpening, lateClosing, earlyClosing, enteredByUa, openingAt, closingAt, summary });
        counter.set(mm.code, closing);
      });
    }
  }
  return out;
}

// ---- issues ----
export type DemoIssueEvent = {
  type: 'report' | 'start' | 'resolve' | 'verify_confirm';
  actor: DemoUserKey;
  at: string;
  before: 'open' | 'in_progress' | 'resolved' | null;
  after: 'open' | 'in_progress' | 'resolved' | 'closed';
  notes?: string;
};
export type DemoIssue = {
  key: string;
  machine: string;
  category: string; // starter category name
  priority: 'low' | 'medium' | 'high' | 'critical';
  stopped: boolean;
  status: 'open' | 'in_progress' | 'resolved' | 'closed';
  reporter: DemoUserKey; // also the accountable owner
  description: string;
  reportedAt: string;
  reportedShift: DemoShift['name'];
  reportedDate: string;
  resolvedBy?: DemoUserKey;
  resolvedAt?: string;
  resolution?: string;
  closedBy?: DemoUserKey;
  closedAt?: string;
  technicalAssignee?: string;
  events: DemoIssueEvent[];
};

export function buildIssues(today: string): DemoIssue[] {
  const d = (back: number) => addDays(today, -back);
  const at = (back: number, hhmm: string) => {
    const [h, mi] = hhmm.split(':').map(Number);
    return stamp(d(back), h * 60 + mi);
  };
  const report = (actor: DemoUserKey, when: string): DemoIssueEvent => ({ type: 'report', actor, at: when, before: null, after: 'open' });
  return [
    // Open Critical "machine stopped": the alert a Unit Admin sees first.
    { key: 'stopped', machine: 'DM-04', category: 'Mechanical', priority: 'critical', stopped: true, status: 'open', reporter: 's1',
      description: 'Demo issue: clamping unit jammed, machine stopped', reportedAt: at(1, '14:20'), reportedShift: 'Day', reportedDate: d(1),
      events: [report('s1', at(1, '14:20'))] },
    // Resolved High awaiting verification by the Night owner of DM-02 (s2), never by the resolver (s1).
    { key: 'verify', machine: 'DM-02', category: 'Mould/Tool', priority: 'high', stopped: false, status: 'resolved', reporter: 's1',
      description: 'Demo issue: mould cooling line leaking', reportedAt: at(1, '10:15'), reportedShift: 'Day', reportedDate: d(1),
      resolvedBy: 's1', resolvedAt: at(1, '15:30'), resolution: 'Demo resolution: cooling hose replaced',
      events: [report('s1', at(1, '10:15')), { type: 'resolve', actor: 's1', at: at(1, '15:30'), before: 'open', after: 'resolved', notes: 'Demo resolution: cooling hose replaced' }] },
    { key: 'open-high', machine: 'DM-07', category: 'Electrical', priority: 'high', stopped: false, status: 'open', reporter: 's2',
      description: 'Demo issue: heater band tripping intermittently', reportedAt: at(2, '11:00'), reportedShift: 'Day', reportedDate: d(2),
      events: [report('s2', at(2, '11:00'))] },
    { key: 'in-progress', machine: 'DM-09', category: 'Material', priority: 'medium', stopped: false, status: 'in_progress', reporter: 's2',
      description: 'Demo issue: hopper dryer not reaching temperature', reportedAt: at(3, '09:40'), reportedShift: 'Day', reportedDate: d(3),
      technicalAssignee: 'Demo maintenance vendor',
      events: [report('s2', at(3, '09:40')), { type: 'start', actor: 's2', at: at(3, '10:10'), before: 'open', after: 'in_progress' }] },
    { key: 'closed-low', machine: 'DM-01', category: 'Other', priority: 'low', stopped: false, status: 'closed', reporter: 's1',
      description: 'Demo issue: guard door sticks', reportedAt: at(6, '08:30'), reportedShift: 'Day', reportedDate: d(6),
      resolvedBy: 's1', resolvedAt: at(6, '11:00'), resolution: 'Demo resolution: hinge oiled', closedBy: 's1', closedAt: at(6, '11:00'),
      events: [report('s1', at(6, '08:30')), { type: 'resolve', actor: 's1', at: at(6, '11:00'), before: 'open', after: 'closed', notes: 'Demo resolution: hinge oiled' }] },
    { key: 'closed-medium', machine: 'DM-05', category: 'Quality', priority: 'medium', stopped: false, status: 'closed', reporter: 's1',
      description: 'Demo issue: flash on cap rim', reportedAt: at(5, '13:00'), reportedShift: 'Day', reportedDate: d(5),
      resolvedBy: 's1', resolvedAt: at(4, '09:00'), resolution: 'Demo resolution: mould vents cleaned', closedBy: 's1', closedAt: at(4, '09:00'),
      events: [report('s1', at(5, '13:00')), { type: 'resolve', actor: 's1', at: at(4, '09:00'), before: 'open', after: 'closed', notes: 'Demo resolution: mould vents cleaned' }] },
    // High closed through verification by a different supervisor (s1 verifies s2's resolution).
    { key: 'closed-high', machine: 'DM-06', category: 'Safety', priority: 'high', stopped: false, status: 'closed', reporter: 's2',
      description: 'Demo issue: light curtain fault', reportedAt: at(6, '16:00'), reportedShift: 'Day', reportedDate: d(6),
      resolvedBy: 's2', resolvedAt: at(5, '10:00'), resolution: 'Demo resolution: sensor realigned', closedBy: 's1', closedAt: at(5, '18:30'),
      events: [report('s2', at(6, '16:00')),
        { type: 'resolve', actor: 's2', at: at(5, '10:00'), before: 'open', after: 'resolved', notes: 'Demo resolution: sensor realigned' },
        { type: 'verify_confirm', actor: 's1', at: at(5, '18:30'), before: 'resolved', after: 'closed' }] },
  ];
}

// ---- counts the size check expects ----
export type DemoCounts = {
  tenant: number; site: number; line: number; machine: number; product: number; target_version: number; cavity_version: number; shift: number;
  assignment_version: number; production_reading: number; production_summary: number; machine_issue: number; issue_action: number;
  issue_ownership_history: number; membership: number; authUsers: number;
};
export function demoCounts(today: string): DemoCounts {
  const occ = buildOccurrences(today);
  const issues = buildIssues(today);
  return {
    tenant: 1, site: 1, line: DEMO_LINES.length, machine: DEMO_MACHINES.length, product: DEMO_PRODUCTS.length, target_version: DEMO_MACHINES.length,
    cavity_version: DEMO_MACHINES.filter((x) => x.cavities !== null).length, shift: DEMO_SHIFTS.length, assignment_version: DEMO_ASSIGNMENTS.length,
    production_reading: occ.length * 2, production_summary: occ.length, machine_issue: issues.length,
    issue_action: issues.reduce((n, i) => n + i.events.length, 0), issue_ownership_history: issues.length,
    membership: DEMO_USERS.length, authUsers: DEMO_USERS.length,
  };
}
