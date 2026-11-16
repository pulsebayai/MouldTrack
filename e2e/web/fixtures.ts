import { expect, type Page } from '@playwright/test';
import { phoneToAuthEmail } from '../../supabase/functions/_shared/identity';

const baseURL = process.env.BASE_URL ?? 'http://localhost:8081';
const isLocal = /localhost|127\.0\.0\.1/.test(baseURL);

/** Local/ephemeral DBs use the non-secret seed password; hosted dev requires the CI secret. */
export const FIXTURE_PASSWORD =
  process.env.E2E_FIXTURE_PASSWORD ||
  (isLocal ? 'local-e2e-Passw0rd!' : (() => { throw new Error('E2E_FIXTURE_PASSWORD is required for non-local targets'); })());

/** Canonical fixture phones (D2): must match supabase/seed.sql and scripts/fixtures-reset.ts. */
export const USERS = {
  adminA: '+919000000001',
  supA: '+919000000002',
  supB: '+919000000003',
  suspended: '+919000000004',
  noMember: '+919000000005',
  u1: '+919000000006', // org U: Unit Admin
  u2: '+919000000007', // org U: Unit Admin
  u3: '+919000000008', // org U: Supervisor
  u4: '+919000000009', // org U: fresh, must change password
} as const;

/** Signs in with a fixture phone. */
export async function signIn(page: Page, phone: string, password = FIXTURE_PASSWORD) {
  await page.goto('/sign-in');
  // Until the sign-in screen takes a phone number (step 6) the Auth address derived from the phone goes in the email field.
  await page.getByTestId('email').fill(phoneToAuthEmail(phone));
  await page.getByTestId('password').fill(password);
  await page.getByTestId('sign-in-submit').click();
}

export async function expectOnSignIn(page: Page) {
  await expect(page.getByTestId('sign-in-submit')).toBeVisible();
  await expect(page).toHaveURL(/\/sign-in$/);
}
