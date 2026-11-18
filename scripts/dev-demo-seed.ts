/**
 * Seeds the demo tenant "Demo Plastics (fixture)" (dev-reset D9) through the service role, the same way fixtures-reset.ts writes its
 * past-dated fixture readings and issues: every row satisfies the table CHECKs, composite FKs and append-only triggers as they are
 * (no trigger is disabled and no bypass exists). Past-dated rows cannot go through the RPCs (they use now()), so the production
 * summaries are calculated by dev-demo-spec.ts, and scripts/demo-checks.sql proves in CI that they equal app._rd_compute_summary.
 *
 * Runs only on an empty demo tenant (it refuses a second run) and only against the local stack or the exact dev project.
 * Env: APP_ENV, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, E2E_FIXTURE_PASSWORD, DEV_SUPABASE_PROJECT_REF (hosted).
 */
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  DEMO_ASSIGNMENTS, DEMO_LINES, DEMO_MACHINES, DEMO_PLAN_FROM, DEMO_PRODUCTS, DEMO_SHIFTS, DEMO_SITE_NAME, DEMO_TENANT_NAME, DEMO_USERS,
  buildIssues, buildOccurrences, plantToday, type DemoUserKey,
} from './dev-demo-spec';
import { assertResetTarget } from './dev-guard';

const AUTH_DOMAIN = 'phone.mouldtrack.invalid';

function must<T>(what: string, r: { data: T; error: { message: string } | null }): T {
  if (r.error) throw new Error(`demo seed: ${what}: ${r.error.message}`);
  return r.data;
}
/** Like must, for a single-row insert that has to return its row. */
function one<T>(what: string, r: { data: T; error: { message: string } | null }): NonNullable<T> {
  const d = must(what, r);
  if (d === null) throw new Error(`demo seed: ${what}: no row returned`);
  return d as NonNullable<T>;
}
async function insertAll(admin: SupabaseClient, table: string, rows: Record<string, unknown>[], chunk = 100): Promise<void> {
  for (let i = 0; i < rows.length; i += chunk) {
    const r = await admin.from(table).insert(rows.slice(i, i + chunk)).select('id');
    must(`insert into ${table}`, r);
  }
}

export async function seedDemo(admin: SupabaseClient, password: string, today: string = plantToday()): Promise<void> {
  const existing = must('look up tenant', await admin.from('tenant').select('id').eq('name', DEMO_TENANT_NAME).maybeSingle());
  if (existing) throw new Error('demo seed: the demo tenant already exists (history is append-only; run dev-reset first)');

  // Tenant (the starter issue categories come from the tenant trigger).
  const tenantId = one('create tenant', await admin.from('tenant').insert({ name: DEMO_TENANT_NAME, status: 'active' }).select('id').single()).id as string;
  must('plan label', await admin.from('tenant').update({ plan_label: 'active' }).eq('id', tenantId).select('id'));

  // People: Auth users with the reserved .invalid addresses, then memberships.
  const uid = new Map<DemoUserKey, string>();
  for (const u of DEMO_USERS) {
    const { data, error } = await admin.auth.admin.createUser({ email: `${u.phone.slice(3)}@${AUTH_DOMAIN}`, password, email_confirm: true });
    if (error) throw new Error(`demo seed: create Auth user: ${error.message}`);
    uid.set(u.key, data.user.id);
    must('membership', await admin.from('membership').insert({
      user_id: data.user.id, tenant_id: tenantId, role: u.role, status: 'active', full_name: u.name, employee_id: u.employeeId, phone_e164: u.phone,
      must_change_password: false, temp_password_expires_at: null,
    }).select('user_id'));
  }
  const ua = uid.get('ua')!;

  // Plant masters.
  const siteId = one('site', await admin.from('site').insert({ tenant_id: tenantId, name: DEMO_SITE_NAME, timezone: 'Asia/Kolkata' }).select('id').single()).id as string;
  const lineId = new Map<string, string>();
  for (const name of DEMO_LINES) lineId.set(name, one('line', await admin.from('line').insert({ tenant_id: tenantId, site_id: siteId, name }).select('id').single()).id as string);
  const machineId = new Map<string, string>();
  for (const x of DEMO_MACHINES) {
    machineId.set(x.code, one('machine', await admin.from('machine').insert({
      tenant_id: tenantId, site_id: siteId, line_id: lineId.get(x.line)!, code: x.code, name: x.name, status: 'active', counter_unit: x.unit, counter_max: x.max,
    }).select('id').single()).id as string);
  }
  const productId = new Map<string, string>();
  for (const p of DEMO_PRODUCTS) productId.set(p.code, one('product', await admin.from('product').insert({ tenant_id: tenantId, code: p.code, description: p.description, uom: 'pcs' }).select('id').single()).id as string);
  await insertAll(admin, 'target_version', DEMO_MACHINES.map((x) => ({
    tenant_id: tenantId, machine_id: machineId.get(x.code)!, product_id: productId.get(x.product)!, effective_from: DEMO_PLAN_FROM, pieces_per_shift: x.target, recorded_by: ua,
  })));
  await insertAll(admin, 'cavity_version', DEMO_MACHINES.filter((x) => x.cavities !== null).map((x) => ({
    tenant_id: tenantId, machine_id: machineId.get(x.code)!, product_id: productId.get(x.product)!, effective_from: DEMO_PLAN_FROM, cavities: x.cavities, recorded_by: ua,
  })));

  // Shifts and the recurring plan.
  const shiftId = new Map<string, string>();
  for (const s of DEMO_SHIFTS) shiftId.set(s.name, one('shift', await admin.from('shift').insert({ tenant_id: tenantId, site_id: siteId, name: s.name, start_time: s.start, end_time: s.end }).select('id').single()).id as string);
  await insertAll(admin, 'assignment_version', DEMO_ASSIGNMENTS.map((a) => ({
    tenant_id: tenantId, shift_id: shiftId.get(a.shift)!, machine_id: machineId.get(a.machine)!, supervisor_id: uid.get(a.supervisor)!, effective_from: DEMO_PLAN_FROM, recorded_by: ua,
  })));

  // Readings (openings first, then closings) and their summaries.
  const occ = buildOccurrences(today);
  const ids = occ.map(() => ({ opening: crypto.randomUUID(), closing: crypto.randomUUID() }));
  const key = (o: (typeof occ)[number]) => ({ tenant_id: tenantId, machine_id: machineId.get(o.machine)!, shift_id: shiftId.get(o.shift)!, shift_date: o.date });
  const maxOf = (code: string) => DEMO_MACHINES.find((x) => x.code === code)!.max;
  await insertAll(admin, 'production_reading', occ.map((o, i) => ({
    id: ids[i].opening, ...key(o), kind: 'opening', product_id: productId.get(o.product)!, counter_value: o.opening, good: null, reject: null, late: o.lateOpening, early: false,
    entered_by_ua: o.enteredByUa, recorded_by: uid.get(o.actor)!, recorded_at: o.openingAt, counter_max: null,
  })));
  await insertAll(admin, 'production_reading', occ.map((o, i) => ({
    id: ids[i].closing, ...key(o), kind: 'closing', product_id: null, counter_value: o.closing, good: o.good, reject: o.reject, late: o.lateClosing, early: o.earlyClosing,
    entered_by_ua: o.enteredByUa, recorded_by: uid.get(o.actor)!, recorded_at: o.closingAt, counter_max: maxOf(o.machine),
  })));
  await insertAll(admin, 'production_summary', occ.map((o, i) => {
    const mm = DEMO_MACHINES.find((x) => x.code === o.machine)!;
    const s = o.summary;
    return {
      ...key(o), calc_version: 1, product_id: productId.get(o.product)!, counter_unit: mm.unit, cavities: s.cavities, counter_max: mm.max,
      opening_reading_id: ids[i].opening, closing_reading_id: ids[i].closing, opening_counter: o.opening, closing_counter: o.closing, good: o.good, reject: o.reject,
      target: mm.target, movement_units: s.movementUnits, movement_pieces: s.movementPieces, unaccounted: s.unaccounted, attainment_pct: s.attainmentPct,
      rollover: s.rollover, needs_review: s.needsReview, over_reported: s.overReported, late_opening: o.lateOpening, late_closing: o.lateClosing,
      early_closing: o.earlyClosing, entered_by_ua: o.enteredByUa, recorded_by: uid.get(o.actor)!, recorded_at: o.closingAt,
    };
  }));

  // Issues with their append-only actions and ownership rows.
  const categories = must('categories', await admin.from('issue_category').select('id, name').eq('tenant_id', tenantId)) ?? [];
  const catId = (name: string) => {
    const c = categories.find((x) => x.name === name);
    if (!c) throw new Error(`demo seed: starter category "${name}" missing`);
    return c.id as string;
  };
  for (const i of buildIssues(today)) {
    const issueId = crypto.randomUUID();
    const by = uid.get(i.reporter)!;
    must('issue', await admin.from('machine_issue').insert({
      id: issueId, tenant_id: tenantId, machine_id: machineId.get(i.machine)!, category_id: catId(i.category), priority: i.priority, description: i.description,
      machine_stopped: i.stopped, status: i.status, accountable_owner_id: by, technical_assignee: i.technicalAssignee ?? null, reported_by: by, reported_at: i.reportedAt,
      reported_shift_id: shiftId.get(i.reportedShift)!, reported_shift_date: i.reportedDate,
      resolved_by: i.resolvedBy ? uid.get(i.resolvedBy)! : null, resolved_at: i.resolvedAt ?? null, resolution_notes: i.resolution ?? null,
      closed_at: i.closedAt ?? null, closed_by: i.closedBy ? uid.get(i.closedBy)! : null,
    }).select('id'));
    await insertAll(admin, 'issue_action', i.events.map((e) => ({
      tenant_id: tenantId, issue_id: issueId, actor_id: uid.get(e.actor)!, actor_role: e.actor === 'ua' ? 'unit_admin' : 'supervisor', type: e.type, notes: e.notes ?? null,
      status_before: e.before, status_after: e.after, at: e.at,
    })));
    must('ownership', await admin.from('issue_ownership_history').insert({ tenant_id: tenantId, issue_id: issueId, new_owner: by, source: 'report', actor_id: by, at: i.reportedAt }).select('id'));
  }
}

async function main() {
  assertResetTarget(process.env, { needDb: false });
  const password = process.env.E2E_FIXTURE_PASSWORD;
  if (!password || password.length < 16) throw new Error('E2E_FIXTURE_PASSWORD missing or shorter than 16 chars');
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false, autoRefreshToken: false } });
  await seedDemo(admin, password);
  console.log(`demo seed: tenant "${DEMO_TENANT_NAME}" created (${DEMO_USERS.length} users, ${DEMO_MACHINES.length} machines, 7 plant days of history)`);
}

if (require.main === module) {
  main().catch((e) => {
    console.error(`dev-demo-seed failed: ${e instanceof Error ? e.message : String(e)}`);
    process.exit(1);
  });
}
