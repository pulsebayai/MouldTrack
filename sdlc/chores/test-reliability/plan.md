# Plan: chore/test-reliability — every hosted and CI e2e failure gets a cause, not a re-run
Status: approved 2026-11-18 (owner: "yes point 2 once reset is merged"; diagnostics first: "yes let us do that") · Author: Opus · Executor: Sonnet
Starts after chore/dev-reset (PR #22) merges (shared workflow files). Holds: no locks unless a step needs a migration (then Opus decides).

## Why
Failures on 5 s waits move between tests across runs (dev runs 44236613663, 44283493922, 44285781648; PR CI runs on the
dev-reset branch). Data growth is ruled out [Certain: they fail on a freshly reset dev and on ephemeral CI stacks].
Two fail every time on dev: web `readings.spec.ts:104` (3 reading entries expected after a correction, 2 shown) and
Maestro `opening-closing.yaml` ("Both readings recorded" on FX-MA1). Policy: flaky tests get fixed, never retried into green.

## Rules
- Never edit, weaken, skip or delete a test to make it pass. Changing **how a test waits** for the same outcome (e.g. wait
  for the save response before asserting the list) is allowed only when the step shows the old wait was wrong, and each
  such change is listed in the PR with the evidence. Raising a global timeout needs the owner's explicit approval.
- App bug → fix the app (new tests first). Server bug → Opus decides (migration = schema lock question).

## Steps
- [x] 1. **Diagnostics first.** On any e2e failure, CI and regression print to the job log: Playwright's `error-context.md`
  (page snapshot), the failing step's last network calls (URL path + status + duration, never bodies or headers), and console
  errors; Maestro prints the hierarchy dump + last screenshot name. Proxy-safe: everything goes to the log, not only artifacts.
  Unit-test the log formatter (redaction: no tokens, phones masked).
- [ ] 2. **Reproduce.** One dispatched dev regression + PR CI runs with step 1 in place; list every failure with its printed cause.
- [ ] 3. **The two consistent failures first** (readings correction list; Maestro opening-closing on FX-MA1): root cause, fix, tests.
- [ ] 4. **The moving failures** (change-password, console, issues escalate, plant "No target set", shifts, Today board,
  Maestro my-shift): classify each as app refresh bug / test wait bug / hosted latency, fix per Rules.
- [ ] 5. **Proof:** 3 consecutive dev regressions + 3 PR CI runs, each green on the first attempt (no re-runs). Record run ids.
- [ ] 6. Docs (known debt if anything is accepted), Opus review, PR with the failure → cause → fix table, owner merge.

## Acceptance
- AC-1 Every e2e failure in CI/regression logs its page state, network summary and console errors (redacted).
- AC-2 Each failure from step 2 has a recorded root cause and fix (or an owner-accepted exception).
- AC-3 3 + 3 consecutive first-attempt green runs (step 5).
- AC-4 No assertion weakened; any wait change listed with evidence.

## Session log
### 2026-11-18 (Opus)
- Plan written; waits for PR #22 merge.

### 2026-11-18 (Sonnet) - step 1
- `e2e/diagnostics-format.ts` (redaction + formatters), `e2e/diagnostics.ts` (drop-in `@playwright/test` replacement: auto fixture records network path/status/ms and console errors per context, attaches them only on failure), `e2e/failure-reporter.ts` (prints error-context.md + the attachments to stdout), registered in playwright.config.ts (applies to ci.yml e2e-web and regression web).
- Only change to existing specs: the module specifier of the `@playwright/test` import in the 10 `e2e/web/*.spec.ts` files now points at `../diagnostics` (re-exports everything; no assertion touched).
- Maestro: `scripts/ci-maestro.sh` (used by regression.yml android) prints hierarchy, failed commands, maestro.log tail and screenshot names through `scripts/redact-log.ts` on failure.
- Redaction unit test: scripts/__tests__/diagnostics-format.test.ts. Local: jest, lint, typecheck green; DB/e2e not run locally.
