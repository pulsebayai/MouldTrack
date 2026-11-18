// 06 AC-1..15 (web): a supervisor records an opening (with a photo through the file chooser) and a closing for the machine they own in the running
// shift, sees the summary next to the target, corrects the opening with a reason and sees the summary recalculated; the Unit Admin reads the same
// occurrence on the Today board and in the Counter panel. Own tenant "e2e web org readings" with a throwaway E2E-<random> machine, product and shifts
// (07's clock-derived world); every code is unique per run because the dev database persists between runs.
import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { TINY_PNG, customOrg, requireApi, service, setupIssueWorld, teardownIssueWorld, uuid, type IssueWorld } from '../api/helpers';
import { FIXTURE_PASSWORD, signIn } from './fixtures';

const ORG = customOrg('20000000-0000-4000-a000-0000000000ba', 'e2e web org readings', ['+919000077751', '+919000077752', '+919000077753', '+919000077754']);

async function expectNoSeriousViolations(page: Page) {
  await expect(page).toHaveTitle('MouldTrack');
  const results = await new AxeBuilder({ page }).analyze();
  const bad = results.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(' | ')}`)).toEqual([]);
}
// The Stack keeps earlier screens mounted (hidden), so only visible elements count.
const tid = (page: Page, id: string) => page.locator(`[data-testid="${id}"]:visible`);
const prefix = (page: Page, p: string) => page.locator(`[data-testid^="${p}"]:visible`);

let w: IssueWorld;
let productId: string;
let machine2: { id: string; code: string };
const run = Math.random().toString(36).slice(2, 8).toUpperCase();
const productCode = `E2E-${run}`;

test.describe.configure({ mode: 'serial' });
test.beforeAll(async () => {
  requireApi();
  w = await setupIssueWorld(ORG, 'E2E Web Readings Plant');
  const p = await w.ua.client.rpc('pm_save_product', { p_request_id: uuid(), p_id: null, p_code: productCode, p_description: 'E2E web part', p_uom: 'pcs' });
  expect(p.data).toMatchObject({ ok: true });
  productId = p.data.id;
  const t = await w.ua.client.rpc('pm_set_target', { p_request_id: uuid(), p_machine_id: w.machine.id, p_product_id: productId, p_pieces: 1000, p_effective_from: w.today });
  expect(t.data).toMatchObject({ ok: true });
  // A second machine owned by the running supervisor with no reading yet: the Unit Admin records its opening on their behalf (R1).
  const code2 = `E2E-${Math.random().toString(36).slice(2, 10).toUpperCase()}`;
  const mk = await w.ua.client.rpc('pm_save_machine', { p_request_id: uuid(), p_id: null, p_code: code2, p_name: 'E2E on-behalf machine', p_asset_tag: '', p_make: '', p_model: '', p_controller: '', p_line_id: null, p_status: 'active' });
  expect(mk.data).toMatchObject({ ok: true });
  machine2 = { id: mk.data.id, code: code2 };
  w.cleanup.push(machine2.id);
  const runningShift = w.running.session === w.sup2 ? w.shiftPm : w.shiftAm;
  const plan = await service().from('assignment_version').insert({ tenant_id: w.org.id, shift_id: runningShift, machine_id: machine2.id, supervisor_id: w.running.session.userId, effective_from: w.today, recorded_by: w.ua.userId }).select('id');
  expect(plan.error).toBeNull();
});
test.afterAll(() => teardownIssueWorld(w));

test('a supervisor records an opening with a photo and a closing, sees the summary, and corrects the opening (AC-1..6, AC-10, AC-14, AC-15)', async ({ page }) => {
  test.setTimeout(240_000);
  await signIn(page, w.running.user.phone, FIXTURE_PASSWORD);
  await tid(page, 'readings-link').click();
  await expect(tid(page, 'readings')).toBeVisible();
  await expectNoSeriousViolations(page);

  // Opening: client validation first, then the numbers.
  await prefix(page, 'reading-open-').filter({ hasText: w.machine.code }).first().click();
  await expect(tid(page, 'record-opening-screen')).toBeVisible();
  await expect(tid(page, 'record-machine')).toContainText(w.machine.code);
  await expect(tid(page, 'record-unit')).toHaveText('Counter counts: Pieces');
  await tid(page, 'record-submit').click();
  await expect(tid(page, 'record-counter-error')).toHaveText('Counter: enter a whole number from 0 to 1,000,000,000,000');
  await expect(tid(page, 'record-product-error')).toHaveText('Choose the product');
  await prefix(page, 'record-product-').filter({ hasText: productCode }).click();
  await tid(page, 'record-counter').fill('1000');
  await tid(page, 'record-remarks').fill('E2E opening');
  const chooser = page.waitForEvent('filechooser');
  await tid(page, 'record-photo-library').click();
  await (await chooser).setFiles({ name: 'counter.png', mimeType: 'image/png', buffer: TINY_PNG });
  await expect(tid(page, 'record-photo-ready')).toContainText('Photo ready');
  await expectNoSeriousViolations(page);
  await tid(page, 'record-submit').click();

  await expect(tid(page, 'readings')).toBeVisible();
  await expect(prefix(page, 'reading-state-').first()).toContainText('Opening recorded');
  await expect(prefix(page, 'reading-open-')).toHaveCount(0);

  // Closing: good + reject.
  await prefix(page, 'reading-close-').filter({ hasText: w.machine.code }).first().click();
  await expect(tid(page, 'record-closing-screen')).toBeVisible();
  await tid(page, 'record-counter').fill('1250');
  await tid(page, 'record-good').fill('240');
  await tid(page, 'record-reject').fill('5');
  await tid(page, 'record-submit').click();
  await expect(prefix(page, 'reading-state-').first()).toContainText('Both readings recorded');
  await expect(page.locator('[data-testid$="-attainment"]:visible').first()).toContainText('Attainment: 24.00%');
  await expect(page.locator('[data-testid$="-target"]:visible').first()).toContainText('Target: 1,000');
  await expect(page.locator('[data-testid$="-unaccounted"]:visible').first()).toContainText('Unaccounted: 5');

  // Details: history, photo, and a correction with a reason.
  await prefix(page, 'reading-details-').first().click();
  await expect(tid(page, 'occurrence-screen')).toBeVisible();
  await expect(prefix(page, 'reading-entry-')).toHaveCount(2);
  await expect(prefix(page, 'reading-photo-').first()).toBeVisible();
  await expectNoSeriousViolations(page);
  await tid(page, 'correct-opening').click();
  await tid(page, 'correct-counter').fill('900');
  await tid(page, 'correct-submit').click();
  await expect(tid(page, 'correct-reason-error')).toHaveText('Enter a reason of 1 to 200 characters');
  await tid(page, 'correct-reason').fill('E2E misread');
  await tid(page, 'correct-submit').click();
  await expect(prefix(page, 'reading-entry-')).toHaveCount(3);
  await expect(tid(page, 'occurrence-summary-movement')).toHaveText('Counter movement: 350 pieces');
  await expect(tid(page, 'occurrence-summary-unaccounted')).toHaveText('Unaccounted: 105');
  await expect(tid(page, 'occurrence-summary-count')).toBeVisible();
  await expect(prefix(page, 'reading-entry-').filter({ hasText: 'Reason: E2E misread' })).toHaveCount(1);
});

test('the Unit Admin sees the machine on the Today board and reads its occurrence (AC-12, AC-15)', async ({ page }) => {
  test.setTimeout(180_000);
  await signIn(page, w.org.users.ua1.phone, FIXTURE_PASSWORD);
  await tid(page, 'today-link').click();
  await expect(tid(page, 'today-screen')).toBeVisible();
  const row = prefix(page, 'today-machine-').filter({ hasText: w.machine.code });
  await expect(row.first()).toBeVisible();
  await expect(row.first()).toContainText('Opening:');
  await expect(prefix(page, 'today-target-').filter({ hasText: 'Target: 1,000' }).first()).toContainText('Good: 240');
  await expect(prefix(page, 'today-target-').filter({ hasText: 'Target: 1,000' }).first()).toContainText('Attainment: 24.00%');
  await expectNoSeriousViolations(page);
  await prefix(page, 'today-open-').filter({ hasText: w.machine.code }).first().click();
  await expect(tid(page, 'occurrence-owner')).toContainText('Supervisor:');
  await expect(prefix(page, 'reading-entry-')).toHaveCount(3);
  await expect(tid(page, 'correct-opening')).toBeVisible(); // a Unit Admin may correct at any time
});

test('a Unit Admin records an opening on behalf of the supervisor from the occurrence view (R1)', async ({ page }) => {
  test.setTimeout(180_000);
  await signIn(page, w.org.users.ua1.phone, FIXTURE_PASSWORD);
  await tid(page, 'today-link').click();
  const runningShift = w.running.session === w.sup2 ? w.shiftPm : w.shiftAm;
  await tid(page, `today-open-${runningShift}-${w.today}-${machine2.id}`).click();
  await expect(tid(page, 'occurrence-screen')).toBeVisible();
  await tid(page, 'occurrence-record-opening').click();
  await expect(tid(page, 'record-opening-screen')).toBeVisible();
  await expect(tid(page, 'record-machine')).toContainText(machine2.code);
  await prefix(page, 'record-product-').filter({ hasText: productCode }).click();
  await tid(page, 'record-counter').fill('50');
  await tid(page, 'record-submit').click();
  await expect(tid(page, 'readings')).toBeVisible();
  // The history names who entered it.
  await page.goto('/home');
  await tid(page, 'today-link').click();
  await tid(page, `today-open-${runningShift}-${w.today}-${machine2.id}`).click();
  await expect(prefix(page, 'reading-entry-').first()).toContainText('Entered by a Unit Admin');
  await expect(tid(page, 'occurrence-record-opening')).toHaveCount(0); // recorded: only the closing is offered now
  await expect(tid(page, 'occurrence-record-closing')).toBeVisible();
});

test('the Counter panel: a locked unit is disabled and explained, rollover value and cavities follow the unit (D3, N-10)', async ({ page }) => {
  test.setTimeout(180_000);
  await signIn(page, w.org.users.ua1.phone, FIXTURE_PASSWORD);
  await tid(page, 'plant-link').click();
  await tid(page, 'machines-search').fill(w.machine.code);
  await tid(page, `machine-open-${w.machine.id}`).click();
  await expect(tid(page, 'counter-panel')).toBeVisible({ timeout: 15_000 });
  await expect(tid(page, 'cavities-section')).toHaveCount(0); // a pieces counter has no cavities
  await tid(page, 'counter-max').fill('5');
  await tid(page, 'counter-save').click();
  await expect(tid(page, 'counter-max-error')).toHaveText('Enter a whole number from 9 to 1,000,000,000,000, or leave it empty');
  await tid(page, 'counter-max').fill('999999');
  await tid(page, 'counter-save').click();
  await expect(tid(page, 'counter-saved')).toBeVisible();
  // N-10: readings exist, so the unit chips are disabled and the reason is shown (the server's counter_unit_locked refusal stays covered by pgTAP and Jest)
  await expect(tid(page, 'counter-unit-locked')).toContainText('Readings already use this unit');
  await expect(tid(page, 'counter-unit-shots')).toHaveAttribute('aria-disabled', 'true');
  await expectNoSeriousViolations(page);
});
