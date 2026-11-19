import { defineConfig, devices } from '@playwright/test';
import { evidenceSettings } from './e2e/evidence';

const baseURL = process.env.BASE_URL ?? 'http://localhost:8081';
const isLocal = /localhost|127\.0\.0\.1/.test(baseURL);

export default defineConfig({
  testDir: './e2e/web',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: 0, // flaky tests get fixed, never retried into green
  workers: process.env.CI ? 2 : undefined,
  timeout: 30_000,
  // Owner-approved 2026-11-19 (test-reliability): hosted targets wait up to 10 s per expectation (GitHub's US runners -> Mumbai
  // adds ~0.4-0.9 s per call, so multi-call screens exceeded 5 s). Local/PR CI keeps the 5 s default, so slow screens still fail there.
  expect: { timeout: isLocal ? 5_000 : 10_000 },
  reporter: [
    ['list'],
    ['./e2e/failure-reporter.ts'],
    ['junit', { outputFile: 'test-results/junit-e2e.xml' }],
    ['json', { outputFile: 'test-results/e2e.json' }],
    ['html', { outputFolder: 'playwright-report', open: 'never' }],
  ],
  // No traces/screenshots/video on hosted targets: they would contain typed credentials (R3). The `use` block applies to every project.
  use: { baseURL, ...evidenceSettings(baseURL) },
  projects: [
    // API tests: Edge Functions + RLS through HTTP, no browser (02, D10).
    // D16: hosted dev is slower (Edge Function cold starts, cleanup RPCs): 60 s per API test on a non-local target, config only.
    { name: 'api', testDir: './e2e/api', fullyParallel: false, testIgnore: /platform-setup\.spec\.ts/, ...(isLocal ? {} : { timeout: 60_000 }) },
    // One-time setup endpoint (03): empties platform_admin, so it runs alone after every project that uses Super Admins. Local stack only.
    { name: 'api-setup', testDir: './e2e/api', testMatch: /platform-setup\.spec\.ts/, fullyParallel: false, dependencies: ['api', 'e2e'] },
    { name: 'e2e', testDir: './e2e/web', testIgnore: /smoke\.spec\.ts/, use: { ...devices['Pixel 7'] } },
    { name: 'smoke', testDir: './e2e/web', testMatch: /smoke\.spec\.ts/, use: { ...devices['Desktop Chrome'] } },
  ],
  webServer: isLocal && !process.env.NO_WEB_SERVER
    ? { command: 'npm run serve:web', url: baseURL, reuseExistingServer: true, timeout: 60_000 }
    : undefined,
});
