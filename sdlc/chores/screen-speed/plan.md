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
- [x] 1. Measure: from the hosted logs and the code, list per screen (session load, Home, Plant, Readings, Users, Today) every
  call in order and which wait on others. Fix the network summary truncation (it cuts after 4 lines) so all API calls print.
  Record the table in this plan.
- [x] 2. Session load: remove the duplicate membership fetch; run independent reads in parallel; one load per sign-in (keep the
  coalescing from #23). Jest: call count per sign-in.
- [x] 3. Screens: start independent reads in parallel instead of chained awaits; don't refetch what the session already holds;
  keep server-driven `allowed_actions`. RNTL tests per screen changed.
- [x] 3b. (D1, owner 2026-11-19, after hosted proof run 1: a read stalled 9.3 s on dev) Fetch wrapper on the Supabase client: reads (GET/HEAD to rest/v1 and Storage downloads) with no response after 6 s are aborted and retried once; never writes, rpc, auth or functions; caller's AbortSignal honoured; Sentry breadcrumb only. Jest with fake timers. Architecture note added.
- [x] 3c. D2 (Opus, after proof run 1b: `my_shift` never called on supervisor Home while `handover_checklist` was in flight): `my_shift` and the handover banner read must start independently. RNTL test `home-parallel.test.tsx`.
- [x] 3d. D3 (Opus): D1's retry extended to an allowlist of read-only RPCs (default deny); architecture note updated.
- [ ] 4. PR CI green; then STOP for the Opus-run hosted proof: 3 consecutive dev runs + 3 PR CI runs green on first attempt.
- [ ] 5. Docs (known debt if anything remains), PR body with before/after call counts.

## Acceptance
- AC-1 Membership fetched once per session load; each changed screen's independent reads run in parallel (tests).
- AC-2 Before/after call table per screen recorded.
- AC-3 3 consecutive hosted dev runs + 3 PR CI runs green on first attempt (carries test-reliability AC-3).
- AC-4 No test weakened, no timeout changed.

## Session log

### Calls per screen (before from hosted run 44482609153 and the code; after from the new Jest tests)
Depth = longest chain of calls that wait on each other, counted from a signed-in start. `tz` = plant timezone read (site, plus tenant when no site).
| Screen / step | Before: calls (depth) | After: calls (depth) |
|---|---|---|
| Sign-in session load | token + membership x2 (3: refresh() and SIGNED_IN each loaded) | token + membership x1 (2) |
| Repeated SIGNED_IN / TOKEN_REFRESHED, same session | one full load each | no load |
| Unit Admin Home | tz x2 (site x2, +tenant x2 with no site) + issue_alerts + handover_alerts | tz x1 + 2 alerts |
| Supervisor readings | tz asked by several cards, each its own site read | one shared site read per session |
| Plant layout (site exists) | site -> plant_today (+ tenant when no site): 2 calls, depth 2 | site and plant_today together: 2 calls, depth 1 |
| Plant layout (no site) | site -> plant_today + tenant: 3 calls, depth 2 | site + plant_today, then tenant: 3 calls, depth 2 (tenant is only needed then) |
| Plant first visit (log, 15 calls) | membership x2, site x3, tenant x3, plant_today x2 ... | membership x1, site x2, tenant x2, plant_today x2 ... (-4 calls) |
| Plant > Assignments | shift -> membership -> shift_board (depth 3) | shift + membership, then shift_board (depth 2) |
| Users | session membership x2 + list x1 | session membership x1 + list x1 |
| Today | unchanged (one read) | unchanged |
Unchanged on purpose: `handover_checklist` (Home banner and readings card) because the read writes the session snapshot (architecture 08), and the plant tab loaders that depend on earlier answers.

## Session log
- 2026-11-19 Sonnet: steps 1-3 done. Step 1: the failing logs actually printed all API calls (13-15), so the real gap was the order (listed by finish time, no start time): `formatNetwork` now sorts by start and prints `+<ms>` start offsets (new test file, existing tests untouched). Step 2: sign-in cost two membership reads because `refresh()` and the SIGNED_IN event each loaded; the provider now skips an auth event whose session fingerprint equals the running or last loaded one (SIGNED_OUT never skipped; refresh() contract kept). Step 3: shared plant timezone (reset on every session load and after the site is saved), plant layout and assignments reads started together. Lint, typecheck and Jest (981) green locally. Next: step 4 (PR CI, then Opus-run hosted proof).
- 2026-11-19 Sonnet: step 3b done (`src/lib/fetch-retry.ts`, wired in `src/lib/supabase.ts`; tests `fetch-retry.test.ts`, `retry-breadcrumb.test.ts`; architecture Connectivity note). Maestro `my-shift` failure of run 44498408583: flow 1/9, failed after 19 s at `tapOn id: phone` right after `launchApp clearState`, i.e. the sign-in screen was not shown in time on the first flow after emulator boot (cold start); the diagnostic re-run showed a normal signed-in Home (handover banner, My shift, Readings), so sign-in and data were fine. With no session there is no membership read, so this is not a network stall; the failure screenshot is not readable from the log, so not fixed. Lint, typecheck, Jest (996) green.
- 2026-11-19 Sonnet, D2: I could not find any serialisation in the app. `MyShiftCard` and `HandoverBanner` each start their own `useLoad` in the same commit, share no loader or gate, and the new RNTL test (`home-parallel.test.tsx`, both directions) passes without any source change: `my_shift` is called while `handover_checklist` never resolves. So the missing `my_shift` request in run 44511040580 was held below the app: before the browser issued it, i.e. inside supabase-js's `fetchWithAuth` (it awaits `auth.getSession()`, which takes the shared auth lock) or in the browser. Not proven; no code change made for D2 (tests only). The retry wrapper cannot help if the wait is before `fetch` is called. Evidence to gather in the next failing run: whether `auth/v1/token` refresh or any `auth/v1` call was in flight.
- 2026-11-19 Sonnet, D3: `READ_RPCS` verified in the migrations (public wrapper and `app.*_at` helper contain no insert/update/delete; the only write is `handover_checklist_at`'s `handover_session` insert, `on conflict do nothing` in both definitions). My D1 test that said "rpc POST is never retried, even a read RPC" encoded the superseded decision; it now uses a write rpc and an unknown rpc (it is my own test from this chore, not an 01-08 test).
