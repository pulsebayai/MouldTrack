import { expect, test } from '../diagnostics';
import { USERS, expectOnSignIn, signIn } from './fixtures';

test.describe('Sign-in (01-walking-skeleton)', () => {
  test('AC-1: member sees their tenant and role', async ({ page }) => {
    await signIn(page, USERS.supA);
    await expect(page.getByTestId('home-tenant')).toHaveText('e2e org A');
    await expect(page.getByTestId('home-role')).toContainText('Supervisor');
    await expect(page).toHaveURL(/\/home$/);
  });

  test('AC-1: tenant B user sees only tenant B', async ({ page }) => {
    await signIn(page, USERS.supB);
    await expect(page.getByTestId('home-tenant')).toHaveText('e2e org B');
  });

  test('AC-2: wrong password shows a plain error and stays on sign-in', async ({ page }) => {
    await signIn(page, USERS.supA, 'definitely-wrong-password');
    await expect(page.getByTestId('sign-in-error')).toHaveText('Phone number or password is incorrect');
    await expectOnSignIn(page);
  });

  test('AC-3: sign-out returns to sign-in', async ({ page }) => {
    await signIn(page, USERS.adminA);
    await expect(page.getByTestId('home-role')).toContainText('Unit Admin');
    await page.getByTestId('sign-out').click();
    await expectOnSignIn(page);
  });

  test('AC-3: protected route without a session redirects to sign-in', async ({ page }) => {
    await page.goto('/home');
    await expectOnSignIn(page);
  });

  test('AC-4: user without membership sees no-access and no tenant data', async ({ page }) => {
    await signIn(page, USERS.noMember);
    await expect(page.getByTestId('no-access')).toBeVisible();
    await expect(page.getByTestId('home-tenant')).toHaveCount(0);
  });

  test('AC-4: user of a suspended tenant sees no-access', async ({ page }) => {
    await signIn(page, USERS.suspended);
    await expect(page.getByTestId('no-access')).toBeVisible();
    await expect(page.getByText('e2e org S')).toHaveCount(0);
  });

  test('AC-5: session survives a reload', async ({ page }) => {
    await signIn(page, USERS.supA);
    await expect(page.getByTestId('home-tenant')).toBeVisible();
    await page.reload();
    await expect(page.getByTestId('home-tenant')).toHaveText('e2e org A');
  });
});
