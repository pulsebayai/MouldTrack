// AC-10 smoke suite: READ-ONLY and safe for production. Never sign in, never write data.
import { expect, test } from '../diagnostics';

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

  test('sign-in shows the phone field with the +91 prefix', async ({ page }) => {
    await page.goto('/sign-in');
    await expect(page.getByTestId('phone')).toBeVisible();
    await expect(page.getByLabel('Phone number')).toBeVisible();
    await expect(page.getByText('+91', { exact: true })).toBeVisible();
    await expect(page.getByLabel('Email')).toHaveCount(0);
  });

  test('protected route redirects to sign-in when signed out', async ({ page }) => {
    await page.goto('/home');
    await expect(page.getByTestId('sign-in-submit')).toBeVisible();
    await expect(page).toHaveURL(/\/sign-in$/);
  });

  // Security headers come from EAS Hosting (expo-router plugin `headers` in app.json, static output).
  // The local static server used in PR CI doesn't send them, so this runs against hosted targets only.
  test('security headers are present on hosted targets', async ({ request, baseURL }) => {
    test.skip(/localhost|127\.0\.0\.1/.test(baseURL ?? ''), 'headers are set by EAS Hosting, not the local static server');
    const res = await request.get('/');
    const h = res.headers();
    expect(h['x-content-type-options']).toBe('nosniff');
    expect(h['content-security-policy']).toContain("default-src 'self'");
    expect(h['content-security-policy']).toContain("frame-ancestors 'none'");
    expect(h['referrer-policy']).toBe('strict-origin-when-cross-origin');
    // EAS Hosting converts X-Frame-Options into the CSP frame-ancestors directive (asserted above).
    expect(h['permissions-policy']).toContain('microphone=()');
    expect(h['strict-transport-security']).toContain('max-age=');
  });
});
