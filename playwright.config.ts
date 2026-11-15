import { defineConfig, devices } from '@playwright/test';

const baseURL = process.env.BASE_URL ?? 'http://localhost:8081';
const isLocal = /localhost|127\.0\.0\.1/.test(baseURL);

export default defineConfig({
  testDir: './e2e/web',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: 0, // flaky tests get fixed, never retried into green
  workers: process.env.CI ? 2 : undefined,
  timeout: 30_000,
  reporter: [
    ['list'],
    ['junit', { outputFile: 'test-results/junit-e2e.xml' }],
    ['json', { outputFile: 'test-results/e2e.json' }],
    ['html', { outputFolder: 'playwright-report', open: 'never' }],
  ],
  use: { baseURL, trace: 'retain-on-failure', screenshot: 'only-on-failure' },
  projects: [
    { name: 'e2e', testIgnore: /smoke\.spec\.ts/, use: { ...devices['Pixel 7'] } },
    { name: 'smoke', testMatch: /smoke\.spec\.ts/, use: { ...devices['Desktop Chrome'] } },
  ],
  webServer: isLocal && !process.env.NO_WEB_SERVER
    ? { command: 'npm run serve:web', url: baseURL, reuseExistingServer: true, timeout: 60_000 }
    : undefined,
});
