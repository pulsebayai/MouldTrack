/** Prints the failure context of every failed test into the job log (artifacts cannot be downloaded from every workspace). */
import { readFileSync } from 'node:fs';
import type { Reporter, TestCase, TestResult } from '@playwright/test/reporter';
import { formatFailure } from './diagnostics-format';

export default class FailureReporter implements Reporter {
  printsToStdio(): boolean {
    return false;
  }
  onTestEnd(test: TestCase, result: TestResult): void {
    if (result.status === 'passed' || result.status === 'skipped' || result.status === test.expectedStatus) return;
    const parts: { name: string; body: string }[] = [];
    for (const a of result.attachments) {
      if (a.name === 'diag-network' || a.name === 'diag-console') {
        parts.push({ name: a.name === 'diag-network' ? 'network (method status ms host/path)' : 'console errors', body: a.body?.toString() ?? '' });
      } else if (a.name === 'error-context') {
        let body = a.body?.toString();
        if (!body && a.path) {
          try {
            body = readFileSync(a.path, 'utf8');
          } catch {
            body = '(error-context file unreadable)';
          }
        }
        parts.push({ name: 'error-context.md (page snapshot)', body: (body ?? '').slice(0, 6000) });
      }
    }
    const errs = result.errors.map((e) => (e.message ?? '').split('\n').slice(0, 12).join('\n')).join('\n');
    parts.unshift({ name: 'error', body: errs });
    process.stdout.write(`${formatFailure(`${test.titlePath().slice(1).join(' > ')} (${test.location.file.split('/').pop()}:${test.location.line})`, parts)}\n`);
  }
}
