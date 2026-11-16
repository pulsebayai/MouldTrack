// 02 AC-3, AC-4, AC-13 (web): forced change after a temporary password, expiry, empty sign-in fields, self-service change.
// Users and Change-password screens must have 0 serious/critical accessibility violations (D11).
import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { FIXTURE_PASSWORD as API_PASSWORD, cleanupCreated, createUserVia, makeActiveUser, requireApi, service, signIn as apiSignIn } from '../api/helpers';
import { USERS, expectOnSignIn, signIn } from './fixtures';

async function expectNoSeriousViolations(page: Page) {
  const results = await new AxeBuilder({ page }).analyze();
  const bad = results.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(' | ')}`)).toEqual([]);
}

test.afterAll(async () => {
  await cleanupCreated();
});

test.describe('AC-13 sign-in fields', () => {
  test('empty fields show the messages and send no request; a11y scan of the sign-in page', async ({ page }) => {
    let authRequests = 0;
    page.on('request', (r) => /\/auth\/v1\/token/.test(r.url()) && authRequests++);
    await page.goto('/sign-in');
    await expectNoSeriousViolations(page);
    await page.getByTestId('sign-in-submit').click();
    await expect(page.getByText('Enter your phone number')).toBeVisible();
    await expect(page.getByText('Enter your password')).toBeVisible();
    await page.getByTestId('phone').fill('9876543210');
    await page.getByTestId('sign-in-submit').click();
    await expect(page.getByText('Enter your password')).toBeVisible();
    expect(authRequests).toBe(0);
    await expectOnSignIn(page);
  });
});

test.describe('AC-3 first sign-in (fresh fixture U4)', () => {
  test('a temporary-password user sees only Change password until the change is done, then lands on Home', async ({ page }) => {
    await signIn(page, USERS.u4);
    await expect(page).toHaveURL(/\/change-password$/);
    await expect(page.getByTestId('home-tenant')).toHaveCount(0);
    await page.goto('/home'); // typing the address does not get past the gate
    await expect(page).toHaveURL(/\/change-password$/);
    await expectNoSeriousViolations(page);

    await page.getByLabel('Current password', { exact: true }).fill(API_PASSWORD);
    await page.getByLabel('New password', { exact: true }).fill('abcdefghi');
    await expect(page.getByTestId('rule-digit')).toContainText('Not met');
    await page.getByLabel('New password', { exact: true }).fill('Fresh-start-2026');
    await expect(page.getByTestId('rule-digit')).toContainText('Met');
    await page.getByLabel('Confirm new password', { exact: true }).fill('Fresh-start-2026');
    await page.getByTestId('change-password-submit').click();

    await expect(page).toHaveURL(/\/home$/);
    await expect(page.getByTestId('home-tenant')).toHaveText('e2e org U');
    await page.getByTestId('sign-out').click();
    await expectOnSignIn(page);
    await signIn(page, USERS.u4, 'Fresh-start-2026');
    await expect(page).toHaveURL(/\/home$/);
  });

  test('a wrong current password is shown next to the field and nothing changes', async ({ page }) => {
    requireApi();
    const ua = await apiSignIn(USERS.u1, API_PASSWORD);
    const made = await createUserVia(page.request, ua.token);
    expect(made.res.status).toBe(200);
    await signIn(page, made.phone, made.res.body.temp_password);
    await expect(page).toHaveURL(/\/change-password$/);
    await page.getByLabel('Current password', { exact: true }).fill('Not-the-password-1');
    await page.getByLabel('New password', { exact: true }).fill('Another-pass-2026');
    await page.getByLabel('Confirm new password', { exact: true }).fill('Another-pass-2026');
    await page.getByTestId('change-password-submit').click();
    await expect(page.getByTestId('current-password-error')).toHaveText('Current password is incorrect');
    await expect(page).toHaveURL(/\/change-password$/);
  });
});

test.describe('AC-4 expiry', () => {
  test('an expired temporary password shows the message and only Sign out', async ({ page }) => {
    requireApi();
    const ua = await apiSignIn(USERS.u1, API_PASSWORD);
    const made = await createUserVia(page.request, ua.token);
    expect(made.res.status).toBe(200);
    await service().from('membership').update({ temp_password_expires_at: new Date(Date.now() - 60_000).toISOString() }).eq('user_id', made.res.body.user_id);

    await signIn(page, made.phone, made.res.body.temp_password);
    await expect(page.getByTestId('password-expired')).toHaveText('Your temporary password has expired. Ask your Unit Admin to reset it.');
    await expect(page.getByLabel('New password', { exact: true })).toHaveCount(0);
    await expectNoSeriousViolations(page);
    await page.getByTestId('sign-out').click();
    await expectOnSignIn(page);
  });
});

test.describe('AC-13 self-service change from Home', () => {
  test('a signed-in member changes their own password and can sign in with it', async ({ page }) => {
    requireApi();
    const ua = await apiSignIn(USERS.u1, API_PASSWORD);
    const u = await makeActiveUser(page.request, ua.token);
    await signIn(page, u.phone, u.password);
    await expect(page.getByTestId('home-tenant')).toHaveText('e2e org U');
    await page.getByTestId('change-password-link').click();
    await expect(page).toHaveURL(/\/change-password$/);
    await page.getByLabel('Current password', { exact: true }).fill(u.password);
    await page.getByLabel('New password', { exact: true }).fill('Self-service-2026');
    await page.getByLabel('Confirm new password', { exact: true }).fill('Self-service-2026');
    await page.getByTestId('change-password-submit').click();
    await expect(page.getByTestId('password-changed')).toBeVisible();
    await page.getByTestId('change-password-done').click();
    await expect(page).toHaveURL(/\/home$/);
    await page.getByTestId('sign-out').click();
    await signIn(page, u.phone, 'Self-service-2026');
    await expect(page.getByTestId('home-tenant')).toHaveText('e2e org U');
  });
});
