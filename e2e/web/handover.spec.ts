// 08 (web): a supervisor with two inherited issues sees the Home banner, finds the opening blocked ("Complete your handover checklist first"), answers one
// issue (acknowledge) and refuses the other with a reason, declares the handover and the opening is offered; the Unit Admin sees the refusal in the Home
// handover alerts and records an exception that hands the issue to the new owner; the Unit Admin changes the overdue minutes. Own tenant
// "e2e web org handover" with the handover gate switched on (a directly inserted tenant is not gated) and throwaway E2E-<random> machine and shifts (07's
// clock-derived world: the running shift's supervisor owns the machine). A last, read-only test checks the enforced fixture tenant "e2e org H" as its
// Unit Admin (the supervisors of org H belong to the Android flow, which consumes their checklist).
import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '../diagnostics';
import { customOrg, enforceHandover, requireApi, seedInheritedIssue, service, setupIssueWorld, teardownIssueWorld, type IssueWorld } from '../api/helpers';
import { FIXTURE_PASSWORD, signIn } from './fixtures';

const ORG = customOrg('20000000-0000-4000-a000-0000000000bb', 'e2e web org handover', ['+919000077761', '+919000077762', '+919000077763', '+919000077764']);
const FIXTURE_UA_H = '+919000000015';

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
let ackIssue: string;
let refuseIssue: string;
const run = Math.random().toString(36).slice(2, 8);
const key = () => `${w.running.session === w.sup2 ? w.shiftPm : w.shiftAm}-${w.machine.id}-${w.today}`;

test.describe.configure({ mode: 'serial' });
test.beforeAll(async () => {
  requireApi();
  w = await setupIssueWorld(ORG, 'E2E Web Handover Plant');
  await enforceHandover(w);
  ackIssue = await seedInheritedIssue(w, 'high', `E2E inherited leak ${run}`);
  refuseIssue = await seedInheritedIssue(w, 'medium', `E2E inherited noise ${run}`);
});
test.afterAll(() => teardownIssueWorld(w));

test('a supervisor answers the inherited issues, declares, and the opening is offered (AC-1, AC-2, AC-3, AC-6)', async ({ page }) => {
  test.setTimeout(240_000);
  await signIn(page, w.running.user.phone, FIXTURE_PASSWORD);
  await expect(tid(page, 'handover-banner-text')).toHaveText('Handover: 2 to acknowledge');

  // The opening waits for the declaration.
  await tid(page, 'readings-link').click();
  await expect(tid(page, `reading-open-blocked-text-${key()}`)).toHaveText('Complete your handover checklist first');
  await expect(tid(page, `reading-open-${key()}`)).toBeDisabled();
  await tid(page, `reading-handover-${key()}`).click();

  // The checklist: both issues unanswered, no declare yet.
  await expect(tid(page, 'handover-screen')).toBeVisible();
  await expect(tid(page, `ho-state-${ackIssue}`)).toHaveText('Not answered yet');
  await expect(tid(page, `ho-state-${refuseIssue}`)).toHaveText('Not answered yet');
  await expect(prefix(page, 'ho-declare-')).toHaveCount(0);
  await expect(prefix(page, 'ho-blocked-')).toHaveCount(1);
  await expectNoSeriousViolations(page);

  // Acknowledge one issue (the remark is optional).
  await tid(page, `ho-ack-${ackIssue}`).click();
  await tid(page, `ho-input-${ackIssue}`).fill('Seen, oil topped up');
  await tid(page, `ho-submit-${ackIssue}`).click();
  await expect(tid(page, `ho-state-${ackIssue}`)).toHaveText('Acknowledged');
  await expect(prefix(page, 'ho-declare-')).toHaveCount(0);

  // Refuse the other: a reason is required.
  await tid(page, `ho-refuse-${refuseIssue}`).click();
  await tid(page, `ho-submit-${refuseIssue}`).click();
  await expect(tid(page, `ho-input-${refuseIssue}-error`)).toHaveText('Enter a reason of 1 to 200 characters');
  await tid(page, `ho-input-${refuseIssue}`).fill('Not handed over to me, the noise is from the previous shift');
  await tid(page, `ho-submit-${refuseIssue}`).click();
  await expect(tid(page, `ho-state-${refuseIssue}`)).toHaveText('Refused - waiting for the Unit Admin');

  // Everything answered: declare.
  await prefix(page, 'ho-declare-').first().click();
  await expect(prefix(page, 'ho-occ-status-').first()).toHaveText('Handover declared');
  await expect(prefix(page, 'ho-declare-')).toHaveCount(0);

  // The opening is offered again.
  await tid(page, 'handover-back').click();
  await expect(tid(page, `reading-open-${key()}`)).toBeEnabled();
  await expect(prefix(page, 'reading-open-blocked-text-')).toHaveCount(0);
  await tid(page, `reading-open-${key()}`).click();
  await expect(tid(page, 'record-opening-screen')).toBeVisible();
});

test('the Unit Admin sees the refusal on Home and records an exception that hands the issue over (AC-9, AC-5)', async ({ page }) => {
  test.setTimeout(180_000);
  await signIn(page, w.org.users.ua1.phone, FIXTURE_PASSWORD);
  await expect(tid(page, 'handover-alerts')).toBeVisible();
  await expect(tid(page, `ho-exc-reason-${refuseIssue}`)).toContainText('refused: Not handed over to me, the noise is from the previous shift');
  await expectNoSeriousViolations(page);

  await tid(page, `ho-exc-record-${refuseIssue}`).click();
  await expect(tid(page, 'ho-exc-panel')).toBeVisible();
  await tid(page, 'ho-exc-submit').click();
  await expect(tid(page, 'ho-exc-reason-error')).toHaveText('Enter a reason of 1 to 200 characters');
  await tid(page, `ho-exc-owner-${w.running.session.userId}`).click();
  await tid(page, 'ho-exc-reason').fill('Runs on the current shift machine, reassigned');
  await tid(page, 'ho-exc-submit').click();
  await expect(tid(page, 'handover-alerts')).toHaveCount(0);

  // The owner is now the running supervisor (a new ownership row, source reassign); nothing was overwritten.
  const own = await service().from('issue_ownership_history').select('new_owner, source').eq('issue_id', refuseIssue).order('at', { ascending: true });
  expect(own.data?.map((r) => r.source)).toEqual(['report', 'reassign']);
  expect(own.data?.[1].new_owner).toBe(w.running.session.userId);
});

test('the Unit Admin reads and changes the overdue minutes on the Site tab (AC-8)', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, w.org.users.ua1.phone, FIXTURE_PASSWORD);
  await tid(page, 'plant-link').click();
  await tid(page, 'plant-tab-site').click();
  await expect(tid(page, 'handover-enforced')).toHaveText('Handover: enforced');
  await expect(tid(page, 'handover-minutes')).toHaveValue('60');
  await tid(page, 'handover-minutes').fill('10');
  await tid(page, 'handover-setting-save').click();
  await expect(tid(page, 'handover-minutes-error')).toHaveText('Enter 15 to 480 minutes');
  await tid(page, 'handover-minutes').fill('45');
  await tid(page, 'handover-setting-save').click();
  await expect(tid(page, 'handover-setting-saved')).toHaveText('Saved');
  const row = await service().from('handover_setting').select('overdue_minutes, required').eq('tenant_id', w.org.id).single();
  expect(row.data).toEqual({ overdue_minutes: 45, required: true });
  await expectNoSeriousViolations(page);
});

test('the fixture tenant org H is enforced and its Unit Admin sees the setting (read-only)', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, FIXTURE_UA_H, FIXTURE_PASSWORD);
  await expect(tid(page, 'home-tenant')).toHaveText('e2e org H');
  await tid(page, 'plant-link').click();
  await tid(page, 'plant-tab-site').click();
  await expect(tid(page, 'handover-enforced')).toHaveText('Handover: enforced');
  await expect(tid(page, 'handover-minutes')).toHaveValue('60');
});
