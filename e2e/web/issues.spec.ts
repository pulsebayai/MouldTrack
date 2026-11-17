// 07 AC-1..13 (web): a supervisor reports an issue with a photo (file chooser), escalates it; the Unit Admin sees it in the Home alerts,
// acknowledges and reassigns it; the new owner resolves it; the supervisor of the shift that started since verifies a fix (confirm / not
// fixed); a Low issue closes on resolve; the Unit Admin manages categories. Own tenant "e2e web org issues" with throwaway E2E-<random>
// machine and shifts (the fixture issues stay untouched); the clock decides who owns the running shift (see setupIssueWorld).
import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { TINY_PNG, customOrg, requireApi, seedResolvedIssue, setupIssueWorld, teardownIssueWorld, type IssueWorld } from '../api/helpers';
import { FIXTURE_PASSWORD, signIn } from './fixtures';

const ORG = customOrg('20000000-0000-4000-a000-0000000000b8', 'e2e web org issues', ['+919000077731', '+919000077732', '+919000077733', '+919000077734']);

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
const description = `E2E hydraulic leak ${Math.random().toString(36).slice(2, 8)}`;

test.describe.configure({ mode: 'serial' });
test.beforeAll(async () => {
  requireApi();
  w = await setupIssueWorld(ORG, 'E2E Web Issues Plant');
});
test.afterAll(() => teardownIssueWorld(w));

test('a supervisor reports a High issue with a photo and escalates it (AC-1, AC-2, AC-4, AC-12)', async ({ page }) => {
  test.setTimeout(180_000);
  await signIn(page, w.running.user.phone, FIXTURE_PASSWORD);
  await expect(tid(page, 'my-shift')).toBeVisible();
  await prefix(page, 'report-issue-').filter({ hasText: w.machine.code }).first().click();
  await expect(tid(page, 'report-screen')).toBeVisible();

  // Client validation first, then a stopped machine locks Critical, then back to High.
  await tid(page, 'report-submit').click();
  await expect(tid(page, 'report-category-error')).toHaveText('Choose a category');
  await expect(tid(page, 'report-priority-error')).toHaveText('Choose a priority');
  await tid(page, 'report-stopped-yes').click();
  await expect(tid(page, 'report-priority-note')).toHaveText('A stopped machine is always Critical.');
  await expect(tid(page, 'report-priority-critical')).toContainText('✓');
  await tid(page, 'report-stopped-no').click();
  await expectNoSeriousViolations(page);

  await prefix(page, 'report-category-').filter({ hasText: 'Mechanical' }).click();
  await tid(page, 'report-priority-high').click();
  await tid(page, 'report-description').fill(description);
  const chooser = page.waitForEvent('filechooser');
  await tid(page, 'report-photo-library').click();
  await (await chooser).setFiles({ name: 'leak.png', mimeType: 'image/png', buffer: TINY_PNG });
  await expect(tid(page, 'report-photo-ready')).toContainText('Photo ready');
  await tid(page, 'report-submit').click();

  await expect(tid(page, 'issue-title')).toContainText(w.machine.code);
  await expect(tid(page, 'issue-status')).toHaveText('Open');
  await expect(tid(page, 'issue-priority')).toHaveText('High');
  await expect(tid(page, 'issue-description')).toHaveText(description);
  await expect(tid(page, 'issue-owner')).toContainText('Fixture');
  await expect(prefix(page, 'timeline-').filter({ hasText: 'Photo added' })).toHaveCount(1);
  await expect(prefix(page, 'photo-').first()).toBeVisible();
  await expectNoSeriousViolations(page);

  // The owner escalates with a reason.
  await tid(page, 'action-escalate').click();
  await tid(page, 'action-submit').click();
  await expect(page.getByText('Enter a reason of 1 to 500 characters')).toBeVisible();
  await tid(page, 'action-text').fill('Need maintenance on the pump');
  await tid(page, 'action-submit').click();
  await expect(tid(page, 'issue-escalated')).toHaveText('Escalated');
  await expect(tid(page, 'action-escalate')).toHaveCount(0);
});

test('the Unit Admin sees the alert, acknowledges the escalation and reassigns the issue (AC-3, AC-5)', async ({ page }) => {
  test.setTimeout(180_000);
  await signIn(page, w.org.users.ua1.phone, FIXTURE_PASSWORD);
  await expect(tid(page, 'issue-alerts')).toBeVisible();
  const alert = prefix(page, 'alert-').filter({ hasText: description });
  await expect(alert.first()).toBeVisible();
  await expect(alert.first()).toContainText('Escalated');
  await expect(alert.first()).toContainText('High');
  await expectNoSeriousViolations(page);
  await alert.first().click();

  await tid(page, 'action-ack_escalation').click();
  await tid(page, 'action-text').fill('Seen, sending the idle shift lead');
  await tid(page, 'action-submit').click();
  await expect(prefix(page, 'timeline-').filter({ hasText: 'Escalation acknowledged' })).toHaveCount(1);

  await tid(page, 'action-reassign').click();
  await tid(page, 'action-submit').click();
  await expect(page.getByText('Enter a reason of 1 to 500 characters')).toBeVisible();
  await tid(page, 'action-text').fill('Shift cover');
  await tid(page, 'action-submit').click();
  await expect(page.getByText('Choose the new owner')).toBeVisible();
  await prefix(page, 'reassign-').filter({ hasText: `FX-${w.org.id.slice(-2)}-${w.idle.user.key}`.toUpperCase() }).click();
  await tid(page, 'action-submit').click();
  await expect(prefix(page, 'ownership-')).toHaveCount(2);
  await expect(tid(page, 'issue-owner')).toContainText('Fixture');
  await expect(prefix(page, 'timeline-').filter({ hasText: 'Owner changed' })).toHaveCount(1);
  await expectNoSeriousViolations(page);
});

test('the new owner resolves it; a High issue then awaits verification and the resolver cannot verify it (AC-6, AC-7)', async ({ page }) => {
  test.setTimeout(180_000);
  await signIn(page, w.idle.user.phone, FIXTURE_PASSWORD);
  await tid(page, 'issues-link').click();
  await expect(prefix(page, 'issue-row-').filter({ hasText: description })).toHaveCount(1);
  await prefix(page, 'issue-row-').filter({ hasText: description }).click();
  await expect(tid(page, 'issue-owner')).toBeVisible();
  await tid(page, 'action-resolve').click();
  await tid(page, 'action-text').fill('Replaced the hydraulic seal');
  await tid(page, 'action-submit').click();
  await expect(tid(page, 'issue-status')).toHaveText('Awaiting verification');
  await expect(tid(page, 'verify-panel')).toHaveCount(0);
  await expect(tid(page, 'action-resolve')).toHaveCount(0);
});

test('the supervisor of the shift that started since verifies: not fixed with a reason, then confirm fixed (AC-6, AC-8)', async ({ page }) => {
  test.setTimeout(180_000);
  const rejected = await seedResolvedIssue(w, 'high', 'E2E fix to be sent back');
  const confirmed = await seedResolvedIssue(w, 'critical', 'E2E fix to be confirmed');
  await signIn(page, w.running.user.phone, FIXTURE_PASSWORD);
  await page.goto(`/issues/${rejected}`);
  await expect(tid(page, 'verify-panel')).toBeVisible();
  await expect(tid(page, 'issue-status')).toHaveText('Awaiting verification');
  await expectNoSeriousViolations(page);
  await tid(page, 'verify-reject').click();
  await tid(page, 'action-submit').click();
  await expect(page.getByText('Enter a reason of 1 to 500 characters')).toBeVisible();
  await tid(page, 'action-text').fill('Still leaking at the seal');
  await tid(page, 'action-submit').click();
  await expect(tid(page, 'issue-status')).toHaveText('In progress');
  await expect(tid(page, 'issue-owner')).toContainText('Fixture');
  await expect(prefix(page, 'timeline-').filter({ hasText: 'Fix rejected' })).toHaveCount(1);

  await page.goto(`/issues/${confirmed}`);
  await expect(tid(page, 'verify-panel')).toBeVisible();
  await tid(page, 'verify-confirm').click();
  await expect(tid(page, 'issue-status')).toHaveText('Closed');
  await expect(prefix(page, 'timeline-').filter({ hasText: 'Fix confirmed' })).toHaveCount(1);
});

test('a Low issue closes as soon as its owner resolves it (AC-7)', async ({ page }) => {
  test.setTimeout(180_000);
  await signIn(page, w.running.user.phone, FIXTURE_PASSWORD);
  await prefix(page, 'report-issue-').filter({ hasText: w.machine.code }).first().click();
  await prefix(page, 'report-category-').filter({ hasText: 'Other' }).click();
  await tid(page, 'report-priority-low').click();
  await tid(page, 'report-description').fill('E2E guard door sticks');
  await tid(page, 'report-submit').click();
  await expect(tid(page, 'issue-status')).toHaveText('Open');
  await tid(page, 'action-start').click();
  await expect(tid(page, 'issue-status')).toHaveText('In progress');
  await tid(page, 'action-resolve').click();
  await tid(page, 'action-text').fill('Oiled the hinge');
  await tid(page, 'action-submit').click();
  await expect(tid(page, 'issue-status')).toHaveText('Closed');
});

test('the Unit Admin sees the whole list and its filters, and manages categories (AC-9, AC-14)', async ({ page }) => {
  test.setTimeout(180_000);
  const catName = `E2E Cat ${Math.random().toString(36).slice(2, 7)}`;
  await signIn(page, w.org.users.ua1.phone, FIXTURE_PASSWORD);
  await tid(page, 'issue-alerts-all').click();
  await expect(prefix(page, 'issue-row-').first()).toBeVisible();
  await tid(page, 'issues-tab-closed').click();
  await expect(prefix(page, 'issue-row-').filter({ hasText: 'E2E guard door sticks' })).toHaveCount(1);
  await expect(prefix(page, 'issue-row-').filter({ hasText: description })).toHaveCount(0);
  await tid(page, 'issues-tab-escalated').click();
  await expect(prefix(page, 'issue-row-').filter({ hasText: description })).toHaveCount(1);
  await expectNoSeriousViolations(page);

  await page.goto('/plant/categories');
  await expect(tid(page, 'categories-tab')).toBeVisible();
  await tid(page, 'category-add').click();
  await expect(page.getByText('Enter a name of 1 to 60 characters')).toBeVisible();
  await tid(page, 'category-new-name').fill(catName);
  await tid(page, 'category-add').click();
  await expect(page.getByText(catName).first()).toBeVisible();
  await tid(page, 'category-new-name').fill(catName.toLowerCase());
  await tid(page, 'category-add').click();
  await expect(page.getByText(/already|exists/i).first()).toBeVisible();
  await expectNoSeriousViolations(page);
});
