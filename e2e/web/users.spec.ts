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

// The Stack keeps earlier screens mounted (hidden), so a list reached by router.replace exists twice: only visible elements count.
const tid = (page: Page, id: string) => page.locator(`[data-testid="${id}"]:visible`);

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
    await tid(page, 'users-link').click();
    await expect(page).toHaveURL(/\/users$/);
    await expect(page.getByRole('heading', { name: 'Users' })).toBeVisible();
    await expectNoSeriousViolations(page);

    // Add (AC-1): the temporary password is shown once.
    await tid(page, 'users-add').click();
    await expect(page).toHaveURL(/\/users\/new$/);
    await expectNoSeriousViolations(page);
    await tid(page, 'full-name').fill(name);
    await tid(page, 'employee-id').fill(emp);
    await tid(page, 'phone').fill(national(phone));
    await tid(page, 'user-save').click();
    await expect(tid(page, 'temp-password-panel')).toBeVisible();
    await expect(tid(page, 'temp-password-warning')).toHaveText('Shown once. Hand it to the person directly.');
    const temp = (await tid(page, 'temp-password').textContent()) ?? '';
    expect(temp.length).toBeGreaterThanOrEqual(10);
    created.push(await userIdByPhone(phone));
    await tid(page, 'temp-password-done').click();
    await expect(page).toHaveURL(/\/users$/);
    await expect(page.getByText(temp)).toHaveCount(0);

    // Found by search; shown with text status labels (AC-14).
    await tid(page, 'users-search').fill(emp);
    const id = await userIdByPhone(phone);
    const row = tid(page, `user-row-${id}`);
    await expect(row).toBeVisible();
    await expect(tid(page, `user-status-${id}`)).toHaveText('Must change password');
    await expect(tid(page, `user-role-${id}`)).toHaveText('Supervisor');
    await expect(tid(page, `user-phone-${id}`)).toHaveText(`+91 ${national(phone)}`);

    // Edit the phone (AC-7).
    await tid(page, `user-edit-${id}`).click();
    await expect(tid(page, 'full-name')).toHaveValue(name);
    await tid(page, 'user-save').click();
    await expect(tid(page, 'user-form-error')).toHaveText('No changes to save');
    await tid(page, 'phone').fill(national(phone2));
    await tid(page, 'user-save').click();
    await expect(page).toHaveURL(/\/users$/);
    await tid(page, 'users-search').fill(national(phone2));
    await expect(tid(page, `user-phone-${id}`)).toHaveText(`+91 ${national(phone2)}`);

    // Deactivate, then reactivate (AC-6), each behind a confirmation naming the person.
    await tid(page, `user-toggle-${id}`).click();
    await expect(tid(page, 'confirm-title')).toHaveText(`Deactivate ${name}?`);
    await tid(page, 'confirm-cancel').click();
    await expect(tid(page, `user-status-${id}`)).toHaveText('Must change password');
    await tid(page, `user-toggle-${id}`).click();
    await tid(page, 'confirm-ok').click();
    await expect(tid(page, `user-status-${id}`)).toHaveText('Inactive');
    await tid(page, `user-toggle-${id}`).click();
    await expect(tid(page, 'confirm-title')).toHaveText(`Reactivate ${name}?`);
    await tid(page, 'confirm-ok').click();
    await expect(tid(page, `user-status-${id}`)).toHaveText('Must change password');

    // Reset password (AC-5): a new password in the once-only panel.
    await tid(page, `user-reset-${id}`).click();
    await expect(tid(page, 'confirm-title')).toHaveText(`Reset password for ${name}?`);
    await tid(page, 'confirm-ok').click();
    await expect(tid(page, 'temp-password-panel')).toBeVisible();
    const temp2 = (await tid(page, 'temp-password').textContent()) ?? '';
    expect(temp2).not.toBe(temp);
    await expectNoSeriousViolations(page);
    await tid(page, 'temp-password-done').click();
    await expect(tid(page, 'temp-password-panel')).toHaveCount(0);
    await expect(page.getByText(temp2)).toHaveCount(0);
  });

  test('the Unit Admin has no deactivate or reset buttons on their own row', async ({ page }) => {
    requireApi();
    await signIn(page, USERS.u1, API_PASSWORD);
    await tid(page, 'users-link').click();
    const me = await userIdByPhone(USERS.u1);
    await expect(tid(page, `user-row-${me}`)).toBeVisible();
    await expect(tid(page, `user-edit-${me}`)).toBeVisible();
    await expect(tid(page, `user-toggle-${me}`)).toHaveCount(0);
    await expect(tid(page, `user-reset-${me}`)).toHaveCount(0);
  });
});

test.describe('Supervisor is blocked (AC-9)', () => {
  test('no Users link on Home, and typing the address shows Not allowed with no user data', async ({ page }) => {
    requireApi();
    await signIn(page, USERS.u3, API_PASSWORD);
    await expect(tid(page, 'home-tenant')).toHaveText('e2e org U');
    await expect(tid(page, 'users-link')).toHaveCount(0);
    await page.goto('/users');
    await expect(tid(page, 'not-allowed')).toHaveText('Not allowed');
    await expect(tid(page, 'users-add')).toHaveCount(0);
    await page.goto('/users/new');
    await expect(tid(page, 'not-allowed')).toBeVisible();
    await expect(tid(page, 'user-form')).toHaveCount(0);
  });
});
