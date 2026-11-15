import { expect, type Page } from '@playwright/test';

const baseURL = process.env.BASE_URL ?? 'http://localhost:8081';
const isLocal = /localhost|127\.0\.0\.1/.test(baseURL);

/** Local/ephemeral DBs use the non-secret seed password; hosted dev requires the CI secret. */
export const FIXTURE_PASSWORD =
  process.env.E2E_FIXTURE_PASSWORD ||
  (isLocal ? 'local-e2e-Passw0rd!' : (() => { throw new Error('E2E_FIXTURE_PASSWORD is required for non-local targets'); })());

export const USERS = {
  adminA: 'e2e-admin-a@example.test',
  supA: 'e2e-sup-a@example.test',
  supB: 'e2e-sup-b@example.test',
  noMember: 'e2e-nomember@example.test',
  suspended: 'e2e-suspended-s@example.test',
} as const;

export async function signIn(page: Page, email: string, password = FIXTURE_PASSWORD) {
  await page.goto('/sign-in');
  await page.getByTestId('email').fill(email);
  await page.getByTestId('password').fill(password);
  await page.getByTestId('sign-in-submit').click();
}

export async function expectOnSignIn(page: Page) {
  await expect(page.getByTestId('sign-in-submit')).toBeVisible();
  await expect(page).toHaveURL(/\/sign-in$/);
}
