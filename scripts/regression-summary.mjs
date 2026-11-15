#!/usr/bin/env node
// Turns JUnit XML (*.xml) and pgTAP output (*.tap) under a directory into a Markdown evidence summary.
// Usage: node scripts/regression-summary.mjs <results-dir> [--env dev] [--target-url URL] [--title "PR CI"]
import { readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { XMLParser } from 'fast-xml-parser';

const args = process.argv.slice(2);
const dir = args.find((a) => !a.startsWith('--')) ?? 'test-results';
const opt = (name, def = '') => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : def;
};

function walk(d) {
  let out = [];
  for (const f of readdirSync(d)) {
    const p = path.join(d, f);
    if (statSync(p).isDirectory()) out = out.concat(walk(p));
    else out.push(p);
  }
  return out;
}

const parser = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: '' });
const asArray = (x) => (x == null ? [] : Array.isArray(x) ? x : [x]);

export function junitCounts(xml) {
  const doc = parser.parse(xml);
  const suites = doc.testsuites ? asArray(doc.testsuites.testsuite) : asArray(doc.testsuite);
  let tests = 0, failed = 0, skipped = 0;
  for (const s of suites) {
    tests += Number(s.tests ?? 0);
    failed += Number(s.failures ?? 0) + Number(s.errors ?? 0);
    skipped += Number(s.skipped ?? s.disabled ?? 0);
  }
  return { passed: tests - failed - skipped, failed, skipped };
}

export function tapCounts(tap) {
  let passed = 0, failed = 0, skipped = 0;
  for (const line of tap.split('\n')) {
    const m = line.match(/^\s*(not ok|ok)\s+\d+/);
    if (!m) continue;
    if (/#\s*(skip|todo)/i.test(line)) skipped++;
    else if (m[1] === 'ok') passed++;
    else failed++;
  }
  if (passed + failed + skipped === 0) {
    // pg_prove summary format (what `supabase test db` prints): "Files=1, Tests=18, ..." + optional "Failed 2/18 subtests"
    const total = Number(tap.match(/Tests=(\d+)/)?.[1] ?? 0);
    const failedSub = tap.match(/Failed (\d+)\/(\d+) subtests/g) ?? [];
    failed = failedSub.reduce((a, m) => a + Number(m.match(/Failed (\d+)/)[1]), 0);
    if (!total && /Result: FAIL/.test(tap)) failed = Math.max(failed, 1);
    passed = Math.max(total - failed, 0);
  }
  return { passed, failed, skipped };
}

function main() {
  const rows = [];
  let files = [];
  try { files = walk(dir); } catch { /* no results */ }
  for (const f of files.sort()) {
    const suite = path.relative(dir, f);
    if (f.endsWith('.xml')) rows.push({ suite, ...junitCounts(readFileSync(f, 'utf8')) });
    else if (f.endsWith('.tap')) rows.push({ suite, ...tapCounts(readFileSync(f, 'utf8')) });
  }
  const e = process.env;
  const runUrl = e.GITHUB_RUN_ID ? `${e.GITHUB_SERVER_URL}/${e.GITHUB_REPOSITORY}/actions/runs/${e.GITHUB_RUN_ID}` : 'local';
  const total = rows.reduce((a, r) => ({ passed: a.passed + r.passed, failed: a.failed + r.failed, skipped: a.skipped + r.skipped }), { passed: 0, failed: 0, skipped: 0 });
  const lines = [
    `## ${opt('title', 'Regression evidence')}`,
    '',
    `- Env: ${opt('env', 'ci-ephemeral')}`,
    `- Commit: ${e.GITHUB_SHA ?? 'local'}`,
    `- Target URL: ${opt('target-url', 'n/a')}`,
    `- Run: ${runUrl}`,
    `- Date (UTC): ${new Date().toISOString()}`,
    '',
    '| Suite | Passed | Failed | Skipped |',
    '|---|---|---|---|',
    ...rows.map((r) => `| ${r.suite} | ${r.passed} | ${r.failed} | ${r.skipped} |`),
    `| **Total** | **${total.passed}** | **${total.failed}** | **${total.skipped}** |`,
  ];
  if (!rows.length) lines.push('', '> No result files found — treat as FAILED evidence.');
  process.stdout.write(lines.join('\n') + '\n');
  if (process.argv.includes('--fail-on-failure') && (total.failed > 0 || !rows.length)) process.exit(1);
}

if (import.meta.url === `file://${process.argv[1]}`) main();
