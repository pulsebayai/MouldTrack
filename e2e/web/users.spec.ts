// 02 AC-1, AC-5, AC-6, AC-7, AC-9, AC-14 (web): the Users screen for a Unit Admin; blocked for a Supervisor.
// Throwaway users are created through the UI and removed afterwards (D2 phone block 90000 10000-99999).
import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { FIXTURE_PASSWORD as API_PASSWORD, created, cleanupCreated, requireApi, service, throwawayEmpId, throwawayPhone } from '../api/helpers';
import { USERS, signIn } from './fixtures';

async function expectNoSeriousViolations(page: Page) {
  await expect(page).toHaveTitle('MouldTrack');
  const results = await new AxeBuilder({ page }).analyze();
  const bad = results.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(' | ')}`)).toEqual([]);
}

const national = (e164: string) => e164.replace(/^\+91/, '');

async function userIdByPhone(phone: string): Promise<string> {
  const { data, error } = await service().from('membership').select('user_id').eq('phone_e164', phone).single();
  if (error) throw error;
  return data.user_id as string;
}

test.afterAll(async () => {
  await cleanupCreated();
});

test.describe('Unit Admin manages users', () => {
  test('add, edit the phone, deactivate, reactivate and reset the password', async ({ page }) => {
    requireApi();
    const phone = throwawayPhone();
    const phone2 = throwawayPhone();
    const emp = throwawayEmpId();
    const name = `E2E Person ${emp}`;

    await signIn(page, USERS.u1, API_PASSWORD);
    await page.getByTestId('users-link').click();
    await expect(page).toHaveURL(/\/users$/);
    await expect(page.getByRole('heading', { name: 'Users' })).toBeVisible();
    await expectNoSeriousViolations(page);

    // Add (AC-1): the temporary password is shown once.
    await page.getByTestId('users-add').click();
    await expect(page).toHaveURL(/\/users\/new$/);
    await expectNoSeriousViolations(page);
    await page.getByTestId('full-name').fill(name);
    await page.getByTestId('employee-id').fill(emp);
    await page.getByTestId('phone').fill(national(phone));
    await page.getByTestId('user-save').click();
    await expect(page.getByTestId('temp-password-panel')).toBeVisible();
    await expect(page.getByTestId('temp-password-warning')).toHaveText('Shown once. Hand it to the person directly.');
    const temp = (await page.getByTestId('temp-password').textContent()) ?? '';
    expect(temp.length).toBeGreaterThanOrEqual(10);
    created.push(await userIdByPhone(phone));
    await page.getByTestId('temp-password-done').click();
    await expect(page).toHaveURL(/\/users$/);
    await expect(page.getByText(temp)).toHaveCount(0);

    // Found by search; shown with text status labels (AC-14).
    await page.getByTestId('users-search').fill(emp);
    const id = await userIdByPhone(phone);
    const row = page.getByTestId(`user-row-${id}`);
    await expect(row).toBeVisible();
    await expect(page.getByTestId(`user-status-${id}`)).toHaveText('Must change password');
    await expect(page.getByTestId(`user-role-${id}`)).toHaveText('Supervisor');
    await expect(page.getByTestId(`user-phone-${id}`)).toHaveText(`+91 ${national(phone)}`);

    // Edit the phone (AC-7).
    await page.getByTestId(`user-edit-${id}`).click();
    await expect(page.getByTestId('full-name')).toHaveValue(name);
    await page.getByTestId('user-save').click();
    await expect(page.getByTestId('user-form-error')).toHaveText('No changes to save');
    await page.getByTestId('phone').fill(national(phone2));
    await page.getByTestId('user-save').click();
    await expect(page).toHaveURL(/\/users$/);
    await page.getByTestId('users-search').fill(national(phone2));
    await expect(page.getByTestId(`user-phone-${id}`)).toHaveText(`+91 ${national(phone2)}`);

    // Deactivate, then reactivate (AC-6), each behind a confirmation naming the person.
    await page.getByTestId(`user-toggle-${id}`).click();
    await expect(page.getByTestId('confirm-title')).toHaveText(`Deactivate ${name}?`);
    await page.getByTestId('confirm-cancel').click();
    await expect(page.getByTestId(`user-status-${id}`)).toHaveText('Must change password');
    await page.getByTestId(`user-toggle-${id}`).click();
    await page.getByTestId('confirm-ok').click();
    await expect(page.getByTestId(`user-status-${id}`)).toHaveText('Inactive');
    await page.getByTestId(`user-toggle-${id}`).click();
    await expect(page.getByTestId('confirm-title')).toHaveText(`Reactivate ${name}?`);
    await page.getByTestId('confirm-ok').click();
    await expect(page.getByTestId(`user-status-${id}`)).toHaveText('Must change password');

    // Reset password (AC-5): a new password in the once-only panel.
    await page.getByTestId(`user-reset-${id}`).click();
    await expect(page.getByTestId('confirm-title')).toHaveText(`Reset password for ${name}?`);
    await page.getByTestId('confirm-ok').click();
    await expect(page.getByTestId('temp-password-panel')).toBeVisible();
    const temp2 = (await page.getByTestId('temp-password').textContent()) ?? '';
    expect(temp2).not.toBe(temp);
    await expectNoSeriousViolations(page);
    await page.getByTestId('temp-password-done').click();
    await expect(page.getByTestId('temp-password-panel')).toHaveCount(0);
    await expect(page.getByText(temp2)).toHaveCount(0);
  });

  test('the Unit Admin has no deactivate or reset buttons on their own row', async ({ page }) => {
    requireApi();
    await signIn(page, USERS.u1, API_PASSWORD);
    await page.getByTestId('users-link').click();
    const me = await userIdByPhone(USERS.u1);
    await expect(page.getByTestId(`user-row-${me}`)).toBeVisible();
    await expect(page.getByTestId(`user-edit-${me}`)).toBeVisible();
    await expect(page.getByTestId(`user-toggle-${me}`)).toHaveCount(0);
    await expect(page.getByTestId(`user-reset-${me}`)).toHaveCount(0);
  });
});

test.describe('Supervisor is blocked (AC-9)', () => {
  test('no Users link on Home, and typing the address shows Not allowed with no user data', async ({ page }) => {
    requireApi();
    await signIn(page, USERS.u3, API_PASSWORD);
    await expect(page.getByTestId('home-tenant')).toHaveText('e2e org U');
    await expect(page.getByTestId('users-link')).toHaveCount(0);
    await page.goto('/users');
    await expect(page.getByTestId('not-allowed')).toHaveText('Not allowed');
    await expect(page.getByTestId('users-add')).toHaveCount(0);
    await page.goto('/users/new');
    await expect(page.getByTestId('not-allowed')).toBeVisible();
    await expect(page.getByTestId('user-form')).toHaveCount(0);
  });
});
