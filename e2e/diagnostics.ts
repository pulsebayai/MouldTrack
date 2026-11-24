/**
 * Drop-in replacement for `@playwright/test` in e2e/web specs: same exports, but `test` also records, for every browser context,
 * the network calls (path, status, duration only) and the console errors, and attaches them to the result when the test fails.
 * `e2e/failure-reporter.ts` prints them (with Playwright's error-context.md) into the job log. Nothing is stored for passing tests.
 */
import { test as base, type Request } from '@playwright/test';
import { formatConsole, formatNetwork, pathOf, type NetCall } from './diagnostics-format';

export * from '@playwright/test';

export const test = base.extend<{ _diagnostics: void }>({
  _diagnostics: [
    async ({ context }, use, testInfo) => {
      const calls: NetCall[] = [];
      const errors: string[] = [];
      const started = new Map<unknown, number>();
      let first = 0;
      const inflight = new Set<Request>();
      context.on('request', (r) => {
        started.set(r, Date.now());
        first ||= Date.now();
        inflight.add(r);
      });
      context.on('requestfinished', async (r) => {
        inflight.delete(r);
        const res = await r.response().catch(() => null);
        calls.push({ method: r.method(), path: pathOf(r.url()), status: res ? res.status() : 'failed', ms: Date.now() - (started.get(r) ?? Date.now()), at: (started.get(r) ?? first) - first });
      });
      context.on('requestfailed', (r) => {
        inflight.delete(r);
        calls.push({ method: r.method(), path: pathOf(r.url()), status: 'failed', ms: Date.now() - (started.get(r) ?? Date.now()), at: (started.get(r) ?? first) - first });
      });
      context.on('console', (m) => {
        if (m.type() === 'error') errors.push(`console.error: ${m.text()}`);
      });
      context.on('weberror', (w) => errors.push(`pageerror: ${w.error().message}`));
      await use();
      if (testInfo.status !== testInfo.expectedStatus) {
        const pending = [...inflight].map((r) => `${r.method()} ${pathOf(r.url())} (no answer yet, ${Date.now() - (started.get(r) ?? Date.now())} ms)`);
        await testInfo.attach('diag-network', { body: `${formatNetwork(calls)}${pending.length ? `\nIN FLIGHT at failure:\n${pending.join('\n')}` : ''}`, contentType: 'text/plain' });
        await testInfo.attach('diag-console', { body: formatConsole(errors), contentType: 'text/plain' });
      }
    },
    { auto: true },
  ],
});
