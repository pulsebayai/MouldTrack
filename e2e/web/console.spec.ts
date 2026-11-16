// 03 (web): the Super Admin console. Sign-in lands on the console, tenant users and Super Admins stay on their own side,
// register tenant -> create Unit Admin -> that Unit Admin signs in, suspend blocks them, activate restores them.
import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { FIXTURE_PASSWORD as API_PASSWORD, SA_FIXTURES, cleanupCreated, created, provisionSuperAdmin, requireApi, service, tenantNameOf, throwawayEmpId, throwawayPhone } from '../api/helpers';
import { USERS, SUPER_ADMINS, signIn } from './fixtures';

async function expectNoSeriousViolations(page: Page) {
  await expect(page).toHaveTitle('MouldTrack');
  const results = await new AxeBuilder({ page }).analyze();
  const bad = results.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(' | ')}`)).toEqual([]);
}

// The navigator keeps earlier screens mounted, so only visible elements count.
const tid = (page: Page, id: string) => page.locator(`[data-testid="${id}"]:visible`);
const national = (e164: string) => e164.replace(/^\+91/, '');

async function signOut(page: Page) {
  await tid(page, 'sign-out').click();
  await expect(page).toHaveURL(/\/sign-in$/);
}

test.beforeAll(async () => {
  requireApi();
  await provisionSuperAdmin(SA_FIXTURES.sa1);
  await provisionSuperAdmin(SA_FIXTURES.sa2);
});

test.afterAll(async () => {
  await cleanupCreated();
});

test.describe('Super Admin routing', () => {
  test('sign-in lands on the console and the tenant areas are out of reach', async ({ page }) => {
    await signIn(page, SUPER_ADMINS.sa1);
    await expect(page).toHaveURL(/\/console$/);
    await expect(tid(page, 'tenants-screen')).toBeVisible();
    for (const path of ['/home', '/users']) {
      await page.goto(path);
      await expect(page).toHaveURL(/\/console$/);
    }
  });

  test('a tenant user cannot open the console', async ({ page }) => {
    await signIn(page, USERS.u1, API_PASSWORD);
    await expect(page).toHaveURL(/\/home$/);
    await page.goto('/console');
    await expect(page).toHaveURL(/\/home$/);
    await expect(tid(page, 'tenants-screen')).toHaveCount(0);
  });
});

test.describe('Console screens', () => {
  test('every console screen has 0 serious or critical accessibility violations', async ({ page }) => {
    await signIn(page, SUPER_ADMINS.sa1);
    await expect(tid(page, 'tenants-screen')).toBeVisible();
    await expect(tid(page, 'tenants-loading')).toHaveCount(0);
    await expectNoSeriousViolations(page);

    await tid(page, 'tenants-add').click();
    await expect(page).toHaveURL(/\/console\/tenants\/new$/);
    await expect(tid(page, 'tenant-form')).toBeVisible();
    await expectNoSeriousViolations(page);

    await tid(page, 'nav-admins').click();
    await expect(tid(page, 'admins-screen')).toBeVisible();
    await expect(tid(page, 'admins-loading')).toHaveCount(0);
    await expectNoSeriousViolations(page);

    await tid(page, 'nav-audit').click();
    await expect(tid(page, 'audit-screen')).toBeVisible();
    await expect(tid(page, 'audit-loading')).toHaveCount(0);
    await expectNoSeriousViolations(page);
  });
});

test.describe('Tenant lifecycle', () => {
  test('register, create a Unit Admin, sign in as them, suspend, activate', async ({ page }) => {
    test.setTimeout(120_000);
    const name = tenantNameOf();
    const uaName = `E2E Admin ${throwawayEmpId()}`;
    const uaPhone = throwawayPhone();

    // Register the tenant.
    await signIn(page, SUPER_ADMINS.sa1);
    await tid(page, 'tenants-add').click();
    await tid(page, 'tenant-name').fill(name);
    await tid(page, 'tenant-save').click();
    await expect(page).toHaveURL(/\/console\/tenants\/[0-9a-f-]+$/);
    await expect(tid(page, 'tenant-detail-name')).toHaveText(name);
    await expect(tid(page, 'tenant-detail-status')).toHaveText('Active');
    await expect(tid(page, 'ua-empty')).toBeVisible();
    await expectNoSeriousViolations(page);

    // Create the first Unit Admin: the temporary password is shown once.
    await tid(page, 'ua-add').click();
    await tid(page, 'person-name').fill(uaName);
    await tid(page, 'person-employee').fill(throwawayEmpId());
    await tid(page, 'person-phone').fill(national(uaPhone));
    await tid(page, 'person-save').click();
    await expect(tid(page, 'temp-password-panel')).toBeVisible();
    const temp = ((await tid(page, 'temp-password').textContent()) ?? '').trim();
    expect(temp.length).toBeGreaterThanOrEqual(10);
    const { data, error } = await service().from('membership').select('user_id').eq('phone_e164', uaPhone).single();
    if (error) throw error;
    created.push(data.user_id as string);
    await tid(page, 'temp-password-done').click();
    await expect(page.getByText(temp)).toHaveCount(0);
    await expect(tid(page, `ua-status-${data.user_id}`)).toHaveText('Must change password');
    await signOut(page);

    // The new Unit Admin: forced change, sign in again, Home.
    await signIn(page, uaPhone, temp);
    await expect(page).toHaveURL(/\/change-password$/);
    await page.getByLabel('Current password', { exact: true }).fill(temp);
    await page.getByLabel('New password', { exact: true }).fill('Fresh-start-2026');
    await page.getByLabel('Confirm new password', { exact: true }).fill('Fresh-start-2026');
    await page.getByTestId('change-password-submit').click();
    await expect(page.getByTestId('sign-in-submit')).toBeVisible();
    await signIn(page, uaPhone, 'Fresh-start-2026');
    await expect(page).toHaveURL(/\/home$/);
    await expect(page.getByTestId('home-tenant')).toHaveText(name);
    await page.goto('/console');
    await expect(page).toHaveURL(/\/home$/);
    await signOut(page);

    // Suspend with a required reason: the Unit Admin is blocked.
    await signIn(page, SUPER_ADMINS.sa1);
    await tid(page, 'tenants-search').fill(name);
    await tid(page, 'tenants-search').press('Enter');
    await tid(page, `tenant-open-${await rowId(page, name)}`).click();
    await tid(page, 'tenant-suspend').click();
    await tid(page, 'suspend-confirm').click();
    await expect(tid(page, 'suspend-dialog')).toBeVisible(); // no reason, nothing happens
    await tid(page, 'suspend-reason').fill('E2E suspension');
    await tid(page, 'suspend-confirm').click();
    await expect(tid(page, 'tenant-detail-status')).toHaveText('Suspended');
    await expect(tid(page, 'tenant-detail-reason')).toContainText('E2E suspension');
    await signOut(page);
    await signIn(page, uaPhone, 'Fresh-start-2026');
    await expect(page.getByTestId('no-access')).toBeVisible();
    await signOut(page);

    // Activate: the Unit Admin is back.
    await signIn(page, SUPER_ADMINS.sa1);
    await tid(page, 'tenants-search').fill(name);
    await tid(page, 'tenants-search').press('Enter');
    await tid(page, `tenant-open-${await rowId(page, name)}`).click();
    await tid(page, 'tenant-activate').click();
    await tid(page, 'confirm-ok').click();
    await expect(tid(page, 'tenant-detail-status')).toHaveText('Active');
    await signOut(page);
    await signIn(page, uaPhone, 'Fresh-start-2026');
    await expect(page).toHaveURL(/\/home$/);
  });
});

async function rowId(_page: Page, name: string): Promise<string> {
  const { data, error } = await service().from('tenant').select('id').eq('name', name).single();
  if (error) throw error;
  return data.id as string;
}
