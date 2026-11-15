// AC-10 smoke suite: READ-ONLY and safe for production. Never sign in, never write data.
import { expect, test } from '@playwright/test';

test.describe('Smoke (prod-safe)', () => {
  test('app responds 200 and renders sign-in without console errors', async ({ page }) => {
    const errors: string[] = [];
    page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
    page.on('pageerror', (e) => errors.push(e.message));
    const res = await page.goto('/');
    expect(res?.status()).toBe(200);
    await expect(page.getByTestId('sign-in-submit')).toBeVisible();
    expect(errors, errors.join('\n')).toEqual([]);
  });

  test('protected route redirects to sign-in when signed out', async ({ page }) => {
    await page.goto('/home');
    await expect(page.getByTestId('sign-in-submit')).toBeVisible();
    await expect(page).toHaveURL(/\/sign-in$/);
  });

  // Header expectations depend on what EAS Hosting supports (plan step 9 decision point).
  test.fixme('security headers are present (enabled after plan step 9)', async ({ request }) => {
    const res = await request.get('/');
    const h = res.headers();
    expect(h['x-content-type-options']).toBe('nosniff');
    expect(h['content-security-policy']).toBeTruthy();
    expect(h['referrer-policy']).toBeTruthy();
    expect(h['strict-transport-security']).toBeTruthy();
  });
});
