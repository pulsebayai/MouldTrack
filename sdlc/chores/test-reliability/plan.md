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
- [x] 2. **Reproduce.** One dispatched dev regression + PR CI runs with step 1 in place; list every failure with its printed cause.
- [x] 3. **The two consistent failures first** (readings correction list; Maestro opening-closing on FX-MA1): root cause, fix, tests.
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

### 2026-11-18 (Sonnet) - step 2 (PR #23 draft; PR CI 44315379124 green on d4ad7d6; dev regression 44315387557)
PR CI (ephemeral stacks): every job green, including e2e-web, so both consistent failures are hosted-only (latency).
Dev regression: drift, reset, hosted-checks green; web 1 failed / 162 passed (the moving failures of earlier runs did not recur); android: opening-closing failed, the other 7 flows passed.

| Failure | Printed cause |
|---|---|
| web readings.spec.ts:51 (line 104 `toHaveCount(3)`) got 2 | Network summary shows **no `rd_correct` call at all** after `reading_detail`; the last request in the log is `GET /rest/v1/product` (the correction form's product list, 276 ms). No console errors. So the second click on "Save correction" sent nothing: the form's product is null until that list has loaded, the test clicks within milliseconds, client validation fails with "Choose the product" and no RPC goes out. On ephemeral CI the list answers in a few ms, on hosted dev in ~300 ms. |
| Maestro opening-closing: no visible "Both readings recorded" for FX-MA1 | maestro.log: closing form filled and `record-submit` tapped, `readings` visible right after, then 9 scroll attempts without the element. Step 1's hierarchy was taken after the later flows ran (useless: wrong screen), so the on-screen state is NOT yet known. Step 1 fixed to dump the hierarchy right after the failing flow (flows now run one at a time by `scripts/ci-maestro.sh`). |

### 2026-11-18 (Sonnet) - step 3 (in progress)
- **Web readings (app bug, fixed, test first):** `CorrectForm` derived `productId` from the loaded product list, so it was null until the list loaded. Now the original product stays chosen while the list is loading and is dropped only when the list has loaded and the product is retired (N7 unchanged). New RNTL test `test-reliability: the original product stays chosen while the product list is still loading...` failed before the fix (no `rd_correct`), passes after; all 904 unit tests, lint, typecheck green. No e2e assertion or wait changed.
- Diagnostics improved after the first read: the page snapshot is printed first (the 6000-char cut had kept only the test source), in-flight requests at failure are listed, Maestro hierarchy is summarised per on-screen element.

### 2026-11-18 (Sonnet) - step 2 second read (regression 44322545094 on 8478dbe; PR CI 44322413486 green; 44319198472 on bc30f04 had one red e2e, below)
- **web readings.spec.ts:51 failed again, identically (no `rd_correct` in the network summary).** Expected: the regression runs this branch's *tests* against the *deployed dev web build, which is main's* (deploy-dev publishes on main only), so the app fix is not in the build under test. The web fix can be proven hosted only by deploying the branch to dev (`deploy-dev` workflow_dispatch on the branch; no migrations in this chore). Not done: outside the hosted calls allowed. Proof today: RNTL test red-then-green + ephemeral PR CI.
- **Maestro opening-closing failed again** (APK is built from the branch). Hierarchy right after the failing flow: the screen DOES show FX-MA1 "Both readings recorded" (occurrence-1, Fixture Shift A2) and a closed occurrence-0, i.e. the data was right by the time the dump was taken, but the 15 s scroll search never saw it. maestro.log of run 1: after `record-submit` the "Record closing" button stayed visible for ~7 s. Root cause: `ReadingsCard` refreshed only on mount, every 60 s and on AppState change, never on focus; on native the Stack keeps the readings screen mounted under the record form, so the saved reading appeared only at the next 60 s tick. (Web remounts, which is why web passes.) Fix: `useRefreshOnFocus(reload)` in `ReadingsCard`, same as Today/issues/occurrence. New test `readings-card-focus.test.tsx` failed before the fix (no focus callback registered), passes after. Not yet proven on Android: needs the next regression (the APK is built from the branch).
- The hierarchy summary masked the long testIDs as [token] (ids >= 40 chars); fixed: ids are kept whole, text and labels stay redacted.
- **PR CI 44319198472 (bc30f04) e2e-web: `readings.spec.ts:111` (Unit Admin Today board) failed once** on the ephemeral stack: `today-target-` `.filter({hasText:'Target: 1,000'}).first()` resolved to a row "Target: 1,000 (default product) - Good: - - Attainment: Not closed yet" (an occurrence of the same machine with no readings) instead of the one with Good: 240. Selector depends on the clock/row order; the re-run on 8478dbe passed. Classified for step 4 (test selector bug, time-of-day dependent). Not changed here.
- Step 3 status: both fixes are in with tests; hosted proof of each is pending (web: needs a branch deploy to dev; Maestro: next regression). Step 5 proof not started.
