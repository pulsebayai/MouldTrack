# Plan: chore/screen-speed — screens load with fewer, parallel calls
Status: approved 2026-11-19 (owner: "please proceed with screen speed fix") · Author: Opus · Executor: Sonnet
Branched from chore/test-reliability (PR #23); rebases on main once #23 merges. No migrations unless Opus approves one.

## Why
Hosted dev run 44482609153: plant, readings and users screens took > 10 s. Diagnostics show 13–15 API calls per screen,
mostly sequential (~0.3–0.7 s each from US runners), and `rest/v1/membership` fetched twice per session load. Real users on
4G in India pay the same round trips (shorter, but many). Also carries test-reliability's unmet AC-3.

## Rules
Never edit, weaken, skip or delete tests (01–08, chores). No timeout changes. Fix the app. Tests first (Jest/RNTL asserting
call counts / parallelism where practical). If a fix needs a new or changed SQL function (e.g. one combined read), log
`Blocked - needs Opus` — no migration without Opus.

## Steps
- [ ] 1. Measure: from the hosted logs and the code, list per screen (session load, Home, Plant, Readings, Users, Today) every
  call in order and which wait on others. Fix the network summary truncation (it cuts after 4 lines) so all API calls print.
  Record the table in this plan.
- [ ] 2. Session load: remove the duplicate membership fetch; run independent reads in parallel; one load per sign-in (keep the
  coalescing from #23). Jest: call count per sign-in.
- [ ] 3. Screens: start independent reads in parallel instead of chained awaits; don't refetch what the session already holds;
  keep server-driven `allowed_actions`. RNTL tests per screen changed.
- [ ] 4. PR CI green; then STOP for the Opus-run hosted proof: 3 consecutive dev runs + 3 PR CI runs green on first attempt.
- [ ] 5. Docs (known debt if anything remains), PR body with before/after call counts.

## Acceptance
- AC-1 Membership fetched once per session load; each changed screen's independent reads run in parallel (tests).
- AC-2 Before/after call table per screen recorded.
- AC-3 3 consecutive hosted dev runs + 3 PR CI runs green on first attempt (carries test-reliability AC-3).
- AC-4 No test weakened, no timeout changed.

## Session log
