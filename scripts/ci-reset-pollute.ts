/**
 * CI only (reset-roundtrip, dev-reset D10): leaves behind the kinds of data a hosted run creates, so that the next dev-reset has something to
 * clear: a throwaway Auth user (throwaway phone range), a Storage object in `attachments`, an issue, a reading and a Console-style test tenant.
 * It also writes one audit_event row (a supervisor's denied pm_* call), which the reset must remove (S7).
 * Refuses anything but the LOCAL stack. Env: APP_ENV=local, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY, E2E_FIXTURE_PASSWORD.
 */
import { createClient } from '@supabase/supabase-js';
import { assertResetTarget } from './dev-guard';
import { addDays, plantToday } from './dev-demo-spec';

// 1x1 transparent PNG
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64');

function must<T>(what: string, r: { data: T; error: { message: string } | null }): NonNullable<T> {
  if (r.error) throw new Error(`pollute: ${what}: ${r.error.message}`);
  if (r.data === null || r.data === undefined) throw new Error(`pollute: ${what}: no row`);
  return r.data as NonNullable<T>;
}

async function main() {
  if (assertResetTarget(process.env, { needDb: false }).mode !== 'local') throw new Error('Refusing: pollute runs on the local stack only');
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false, autoRefreshToken: false } });
  const password = process.env.E2E_FIXTURE_PASSWORD!;

  // Auth user in the throwaway phone range.
  const { error: uErr } = await admin.auth.admin.createUser({ email: '9000010001@phone.mouldtrack.invalid', password, email_confirm: true });
  if (uErr) throw new Error(`pollute: auth user: ${uErr.message}`);

  // Storage object.
  const up = await admin.storage.from('attachments').upload(`tenant/rt/roundtrip/${crypto.randomUUID()}.png`, PNG, { contentType: 'image/png' });
  if (up.error) throw new Error(`pollute: storage: ${up.error.message}`);

  // A test tenant, an issue and a reading in the fixture org U.
  must('tenant', await admin.from('tenant').insert({ name: 'e2e t3 roundtrip', status: 'suspended' }).select('id'));
  const org = must('org U', await admin.from('tenant').select('id').eq('name', 'e2e org U').single());
  const tid = org.id as string;
  const machine = must('machine', await admin.from('machine').select('id').eq('tenant_id', tid).eq('code', 'FX-MU3').single());
  const product = must('product', await admin.from('product').select('id').eq('tenant_id', tid).eq('code', 'FX-PU3').single());
  const shift = must('shift', await admin.from('shift').select('id').eq('tenant_id', tid).eq('name', 'Fixture Morning').single());
  const sup = must('supervisor', await admin.from('membership').select('user_id').eq('tenant_id', tid).eq('employee_id', 'FX-U3').single());
  const cat = must('category', await admin.from('issue_category').select('id').eq('tenant_id', tid).eq('name', 'Mechanical').single());
  const by = sup.user_id as string;
  const issueId = crypto.randomUUID();
  must('issue', await admin.from('machine_issue').insert({
    id: issueId, tenant_id: tid, machine_id: machine.id, category_id: cat.id, priority: 'low', description: 'E2E round-trip issue', machine_stopped: false, status: 'open',
    accountable_owner_id: by, reported_by: by,
  }).select('id'));
  must('action', await admin.from('issue_action').insert({ tenant_id: tid, issue_id: issueId, actor_id: by, actor_role: 'supervisor', type: 'report', status_after: 'open' }).select('id'));
  must('ownership', await admin.from('issue_ownership_history').insert({ tenant_id: tid, issue_id: issueId, new_owner: by, source: 'report', actor_id: by }).select('id'));
  must('reading', await admin.from('production_reading').insert({
    tenant_id: tid, machine_id: machine.id, shift_id: shift.id, shift_date: addDays(plantToday(), -3), kind: 'opening', product_id: product.id, counter_value: 1, good: null, reject: null,
    late: false, early: false, entered_by_ua: false, recorded_by: by, counter_max: null,
  }).select('id'));
  // S7: a denied call writes an access.denied audit row (denials are returned, not raised).
  const anon = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_ANON_KEY!, { auth: { persistSession: false, autoRefreshToken: false } });
  const signed = await anon.auth.signInWithPassword({ email: '9000000008@phone.mouldtrack.invalid', password });
  if (signed.error) throw new Error(`pollute: supervisor sign-in: ${signed.error.message}`);
  const denied = await anon.rpc('pm_save_line', { p_request_id: crypto.randomUUID(), p_id: null, p_name: 'E2E-RT-DENIED' });
  if (denied.error || (denied.data as { ok?: boolean } | null)?.ok !== false) throw new Error('pollute: expected the supervisor call to be denied');
  const audit = await admin.from('audit_event').select('*', { count: 'exact', head: true });
  if (audit.error || !audit.count) throw new Error('pollute: the denied call left no audit_event row');

  console.log('pollute: left an Auth user, a Storage object, a test tenant, an issue, a reading and an audit event');
}

main().catch((e) => {
  console.error(`ci-reset-pollute failed: ${e instanceof Error ? e.message : String(e)}`.replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g, '<jwt>'));
  process.exit(1);
});
