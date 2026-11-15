// AC-13 (web): the dev build reports errors to Sentry and Sentry accepts them.
// Hosted DEV only: the button exists only when APP_ENV=development, and local CI has no DSN.
import { expect, test } from '@playwright/test';
import { USERS, signIn } from './fixtures';

test('dev build sends a test error that Sentry accepts', async ({ page, baseURL }) => {
  test.skip(!/--dev\.expo\.app/.test(baseURL ?? ''), 'runs against the hosted dev deployment only');
  const cspErrors: string[] = [];
  page.on('console', (m) => m.type() === 'error' && /Content Security Policy|CSP/i.test(m.text()) && cspErrors.push(m.text()));

  await signIn(page, USERS.adminA);
  await expect(page.getByTestId('home-role')).toContainText('Unit Admin');

  const accepted = page.waitForResponse((r) => /sentry\.io\/api\/\d+\/envelope/.test(r.url()) && r.request().method() === 'POST', {
    timeout: 20_000,
  });
  await page.getByTestId('send-test-error').click();
  await expect(page.getByTestId('test-error-sent')).toHaveText('Test error sent to Sentry');
  expect((await accepted).status()).toBe(200);
  expect(cspErrors, cspErrors.join('\n')).toEqual([]);
});
