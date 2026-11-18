# Plan: Shift readings
Spec: ./spec.md · Status: approved · Date: 2026-11-17
Batch B with 07 (**07 merges first**). Locks: schema — 06's share (production_reading, cavity_version, production_summary, machine counter columns; split with 07, logged). Architecture flags go to the session log; applied by whoever holds the lock at 06's merge (07 releases it on merge → 06 takes it for its docs step via a roadmap PR).

## Decisions (Opus)
- D1 Files: migration `20261117400000_readings.sql` (after 07's `20261117300000`); pgTAP `050_reading_tables.test.sql`, `051_reading_rpcs.test.sql`, `052_summary_calc.test.sql`, `053_reading_reads.test.sql`.
- D2 Write RPCs `public.rd_*` (spec FR), authorise via `app._pm_authorise`, D13 denials, idempotency scoped by source; reuse of a request id across RPCs → `validation`.
- D3 Counter settings: `rd_set_machine_counter(machine, unit, max)` (UA only). Unit change refused (`counter_unit_locked`) once any `production_reading` exists for the machine; max may change. New machine columns default `pieces` / null.
- D4 Cavities: `cavity_version` append-only, effective-dated from plant date ≥ today, "end means end" (04's R1 rule; null = ended → default 1); `app.cavities_for(machine, product, date)`.
- D5 Windows (05's `shift_window`): opening allowed while `now() ∈ [start − 30 min, end)`; closing allowed once a current opening exists and `now() ≤ end + 12 h`. `late` stored at insert: opening `recorded_at > start + 30 min`, closing `recorded_at > end + 30 min`. The occurrence's late flag for the metric = the **earliest** submission of that kind.
- D6 Who: `app.machine_owner(machine, shift, date) = auth.uid()` or caller is UA (`entered_by_ua = true`). Corrections (`rd_correct`): SUP owner while `now() < lower(shift_window(shift, date + 1))`; UA any time; reason 1–200; supersedes by `supersedes_id`.
- D7 Summary: `app._rd_compute_summary(machine, shift, date)` runs in the same transaction as a closing or a correction of either kind (only when a current closing exists) and appends one `production_summary` row (`calc_version = 1`, input snapshot incl. `app.effective_target` and `app.cavities_for` on the occurrence date). Flags: `late_opening`, `late_closing`, `rollover`, `needs_review`, `over_reported`, `entered_by_ua`.
- D8 Reads (lesson from 07 I-1: **no client-supplied time**): `public.reading_state()`, `public.reading_detail(machine, shift, date)`, `public.today_board()` use `now()`; bodies are `app.*_at(p_at)` helpers that tests call directly. `reading_state` returns the caller's My-shift machines with state + default product (latest opening/closing product on that machine). `today_board` UA only.
- D9 `app.reading_capture(tenant, from_date, to_date)` (service_role/app-only; 09 consumes): expected = assigned machine-occurrences (owner not null) with window end < now; on time = both kinds present and earliest of each not late.
- D10 Step order to avoid churn with 07 (shared My shift card, Home, seed, fixtures-reset, 022): **DB first** (steps 1–5 now); **step 6 = rebase on 07 after 07 merges**; client + photos (07's attachments with entity type `production_reading`) after that.
- D11 Fixtures: org U — one Shots machine (cavities 4 for its product), one Pieces machine with max 999999; a past occurrence with opening + closing (normal) and one with rollover; org A — the Android SUP's machine with an opening due in the current occurrence. Throwaway readings accumulate on dev (append-only) → known debt.
- D12 Time-dependent write tests build shifts relative to `now()` (05/07 rule); no clock override in production code.
- D13 Limits: counter `bigint` 0–10^12; good/reject `int` 0–10,000,000; remarks ≤ 500.

- D14 **(Opus, resolves step 6 blocker, 2026-11-18)** 03's `022_platform_boundary.test.sql` test 30 reads only `pa_audit(0)` (one page of 50) yet asserts every discovered client RPC's Super Admin denial is listed — an implicit cap that breaks any feature adding RPCs (a test defect, not product behaviour). **Authorised edit to 022 (beyond its fixture block, this one assertion only):** collect `pa_audit` pages 0..9 (bounded) and assert the same condition over their union (one denial row per discovered RPC, plus the extra event, all `actor_role = 'platform_admin'`). The assertion's meaning and strength are unchanged; log it under Deviations citing D14. Then apply `step6-attachments.patch`, write its pgTAP additions (042 extension, new 054), delete the patch file, and continue with steps 7–8 including photos on readings.

## Files that change
- `supabase/migrations/20261117400000_readings.sql`; `supabase/tests/050–053_*.test.sql` — new; `supabase/tests/022_platform_boundary.test.sql` — fixture-block additions only; 07's Storage/attachment tests — additions only for entity `production_reading` (after step 6)
- `supabase/seed.sql`, `scripts/fixtures-reset.ts` (+ tests, additions only)
- `src/lib/readings.ts` (+ tests); `src/components/my-shift-card.tsx` (reading states/actions); `src/app/(app)/readings/[machine].tsx` (opening/closing forms + summary); `src/app/(app)/today.tsx` (UA board) + Home entry; Plant machine detail "Counter" panel (`src/components/plant/counter-panel.tsx`)
- `e2e/web/readings.spec.ts`, `e2e/api/readings.spec.ts`, `e2e/maestro/opening-closing.yaml`; e2e fixtures/helpers — additions
- Step 9 (docs, with the lock): `sdlc/product/architecture.md`

## Migrations
`20261117400000_readings.sql`. Additive (new columns with defaults on `machine`).

## Steps
- [x] 1. **Tables + counter settings + cavities (tests first).** 050: RLS (UA reads all; SUP no direct table select; SA nothing), composite FKs, append-only readings/summaries/cavities incl. service_role + trigger, machine columns + `rd_set_machine_counter` (unit lock, max change), cavities set/end/`cavities_for`, registry, audit. — proof: CI `db`
- [x] 2. **Reading RPCs (tests first).** 051: opening/closing windows (D5 incl. overnight), late flag at boundary + 30 min (just before/after), one current reading per kind, corrections (SUP window, UA any time, earliest-late rule), who (owner, cover, UA → entered_by_ua, other SUP, unassigned → UA only, must-change, suspended, SA), idempotency, isolation, audit. — proof: CI `db`
- [x] 3. **Summary calculation (tests first).** 052: every spec AC-10 case + snapshot contents + versioning (correction appends a new summary; old stays). — proof: CI `db`
- [x] 4. **Reads (tests first).** 053: `reading_state_at` states (opening due / done late / closing due / closed) and default product; `today_board_at` (assigned only, current + previous occurrence, totals, flags; UA only); `reading_capture` (on time, late, missing, unassigned excluded, open occurrences excluded). — proof: CI `db`
- [x] 5. **Fixtures + 022** per D11 (additions only). — proof: CI green
- [x] 6. **Rebase on 07 (after 07 merges).** Resolve shared files; add attachment entity type `production_reading` + its visibility (owner in that occurrence, UAs) to 07's `can_see_attachment` path via 06's migration (additive redefinition); extend 07's Storage tests with additions for the new entity; full suite green. — proof: CI green
- [x] 7. **Client (tests first).** readings.ts; My shift card states/actions (keeping 07's "Report issue"); opening form (product chips with default, counter, optional photo via 07's photo pipeline, remarks), closing form (counter, good, reject), summary card with flags as text; Counter panel in Plant; UA Today board + Home entry; drafts + refresh pattern. — proof: lint/typecheck/test/build
- [x] 8. **E2E.** web `readings.spec.ts` (SUP opening → closing → summary; correction; UA Today board; counter panel; axe), api `readings.spec.ts` (other SUP denied + audited; UA on behalf; photo on a reading; SA denied), Maestro `opening-closing.yaml` (no photo, as 07 D8). — proof: CI `e2e-web` green
- [x] 8a. **Review fixes (Opus decisions, sdlc-reviewer 2026-11-18).** Tests first.
  - **R1 UA on-behalf from the UI (I-1):** OccurrenceView renders Record opening / Record closing from `reading_detail.allowed`; RecordForm takes its context (unit, default product, allowed actions) from `reading_detail`, not `reading_state`; gate the form on server-allowed actions (N-9). Web e2e: UA records on behalf → "Entered by Unit Admin".
  - **R2 Photo on closing too (I-2)** + RNTL case.
  - **R3 Today board columns (I-3):** show movement, reject, unaccounted (and counters in the detail); attainment shows "Not closed yet" when a target exists but no closing; "No target set" only when target is null. Totals exclude assumed targets or show them separately labelled (N-2). Closing status "Not due yet" while the occurrence runs (N-3).
  - **R4 Late opening allowed (I-4; owner rule "late readings accepted and flagged"):** opening window becomes [start − 30 min, **end + 12 h**] for the owner and for UAs; after start + 30 min it is Late. Closing still requires an opening. Fix the message. Amend 051's own (unmerged) window tests accordingly; log.
  - **R5 Early closing flagged (I-5):** a closing submitted before **end − 30 min** is accepted and flagged **Early** (stored, shown); `reading_capture_at` counts a closing as on time only within [end − 30 min, end + 30 min] and counts occurrences only once `upper(w) + 30 min <= p_at` (N-4). New summary flag `early_closing`.
  - **R6 D14 extended (I-6):** 022 lines ~186 and ~201 use the same bounded `pa_audit` pages 0..9 union; meaning and strength unchanged; log citing D14.
  - **R7 Opening time + Late on the readings list (I-7 part):** readings screen shows the opening time in plant time and "Late" for opening_done / closing_due. (The separate-screen deviation itself goes to the owner.)
  - **R8 Nits:** N-1 default product by occurrence order; N-5 null product → validation; N-6 retired machine/shift checks in closing/correct; N-7 photos only on current readings, 3-photo cap re-checked at commit; N-8 clear draft once saved; N-10 counter unit lock mapped to the field + chips disabled when readings exist; N-11 Maestro pinned to a specific machine/occurrence and fails if no step ran; N-12 list extra files.
  - Proof: CI green on PR #18.
- [x] 9. **Hosted proof (dev)** after 07's merge + step 8; then **docs** (architecture.md with the lock: readings model, versioned summary, counter semantics) — proof: run URLs, docs diff
- [ ] 10. **Review + PR.** sdlc-reviewer, fixes, AC table. — proof: PR CI green

## Risks
- Overnight windows and the late boundary (explicit `_at` helpers in tests; writes relative to now).
- Rollover vs mistyped low closing (flag + corrections; never guessed without a maximum).
- Rebase on 07 (shared card, Home, seed, fixtures-reset, 022, attachment visibility) — its own step.
- `today_board` performance (300 machines × 3 shifts × 2 occurrences) — set-based query; sanity pgTAP case with volume.
- Rollback: additive; machine columns have defaults.

## Proof of done
AC-1–16 → tests (spec table); full suite green after rebase on 07; dev regression green incl. Android `opening-closing.yaml`.

## Deviations from plan
- Step 4 migration fix found by 053: `reading_capture_at` treats an occurrence as ended when `upper(window) <= p_at` (end is exclusive), not `<`.
- 052's last test (summaries carry their tenant) is scoped to the test's own machines because seed.sql (step 5) adds fixture summaries; this is 06's own new test, not an 01-05 test.
- Board rule pinned by 053: a retired machine appears on the board only when it has a reading in that occurrence (so M5-style rows show on the day they have data, not on days without).

- D14 applied: 022 test 30 now reads `pa_audit` pages 0..9 and asserts the same condition over the union (only assertion touched). Step 6 photos: `rd_attachment_begin/commit`, `app._rd_can_see_reading`, additive `app_policy.can_see_attachment`, `photos` in `reading_detail`; tests in new 054 (07's 042 untouched, its two-policy and app_policy-count pins still hold).
- Step 7 deviation: the supervisor's readings live on their own screen `/readings` (button "Readings" on Home) instead of inside the My shift card, because 05's `my-shift.test.tsx` pins the total rpc call count of Home (a second per-minute `reading_state` call would break it) and those tests may not be edited. My shift keeps 07's "Report issue" rows untouched. `src/test/fake-db.ts` has no `.limit()`, so the cavity history uses `.range(0, 99)`.

- **8a (review fixes) test edits, all 06's own unmerged tests, each forced by an Opus decision:** 051: the two window cases that expected `window_closed` for an opening after the end now use the >12 h machine (R4, message text pinned); 053: the `can_open` case after the end now expects true (R4) and the "ends exactly at the moment" capture case moved to end + 30 min with a 14:29 case (R5/N-4); Jest `readings-forms.test.tsx` helper `record()` supplies `reading_detail` instead of `reading_state` (R1); `counter-panel.test.tsx` "locked unit" asserts `counter-unit-error` instead of `counter-save-error` (N-10); e2e api `closing_status` regex adds `early` (R5); e2e web Counter panel case asserts the disabled unit chips + explanation instead of clicking them (N-10). No 01-05/07/006 assertion changed.
- **8a D14 extension (R6):** 022 lines 186 and 201 (`pa_audit(0)` with `tenant_name is not null` / `user.deactivated`) read the same bounded `pa_audit` pages 0..9 union; meaning and strength unchanged. Cites D14.
- **8a design notes:** `production_reading.early` and `production_summary.early_closing` (default false, `early` only on closings by CHECK) are part of the single migration (unmerged); a correction carries `early` like `late`. `reading_detail` gained `default_product_id` so the form needs no `reading_state` (R1); `today_board` occurrences gained `assumed_target` next to `totals` (totals unchanged: N-2); board `closing_status` gained `early`. `reading_capture_at` counts an occurrence only once `end + 30 min <= p_at` and a closing is on time only when neither late nor early. Default product follows occurrence order over current openings (N-1). Photos: `not_current` refused at begin and commit, 3-photo cap re-checked at commit (N-7). N-6 guards (`machine_retired`, `shift_retired`) in `rd_closing` / `rd_correct`.
- **N-12 extra files changed by 8a (beyond the Files list):** `src/components/readings/{summary-block,today-board,readings-card,occurrence-view,record-form}.tsx`, `src/components/plant/counter-panel.tsx`, `src/lib/readings.ts`, `src/lib/__tests__/readings.test.ts`, `e2e/maestro/opening-closing.yaml`, `supabase/tests/022_platform_boundary.test.sql` (R6 lines), `supabase/tests/05{1,2,3,4}_*.test.sql`.

- 626bcc9 (Opus docs commit) also contains part of step 8a's client changes (R1–R3, R7, N-8, N-10) by accident; content is correct, message is not.

## Session log
### 2026-11-17
- Done: intent + spec approved (counter unit per machine, optional max, rollover recorded, good + reject only, photo optional, late accepted + flagged, UA may enter on behalf, SUP correction window until the next occurrence).
- Next step: owner approves plan; Sonnet executes steps 1–5 now; 6+ after 07 merges.

### 2026-11-17 (Sonnet, steps 1-5)
- Done: steps 1-5 (b059467, 9389a76, 148aef7 [052 tests], 7a86645 [step 4], 947bb0f [step 5]). One migration `20261117400000_readings.sql`; tests 050-053; 022 fixture-block additions; seed.sql + `scripts/fixtures-reset.ts` (READINGS, resetReadings) + Jest additions.
- Local: pgTAP 23 files / 1699 tests green (also with seed applied); lint, typecheck clean; Jest 47 suites / 638 tests.
- CI on 947bb0f (run 44121134776): changes, static, db, e2e-web, ci-ok green (earlier step pushes were cancelled by newer pushes; step 1 db/static had been green).
- Blockers: none. Next: step 6 after 07 merges.

### 2026-11-17 (Sonnet, step 6 rebase)
- Done: rebased onto origin/main (70b7957, 07 merged). Conflicts resolved keeping both features: 022 fixture block (06's ids moved to ...0016/...0017 to avoid 07's ...06/...07), seed.sql, fixtures-reset.ts (resetIssues then resetReadings). 06's migration `20261117400000` sorts after 07's `20261117300000`. Local after rebase: pgTAP 27 files / 2134 tests green (also with seed), lint, typecheck, Jest 59 suites / 768 tests.
- Resolved by Opus (D14) — was: Blocked - needs Opus: 06's photo RPCs cannot be added without breaking 03's test 022 test 30 ("the platform audit lists them", `pa_audit(0)`). `pa_audit` returns one page of 50 rows; 022 expects one denial row per discovered client RPC plus one, and ~4 other platform events share the page, so the first page holds at most 46 RPC denials. Main plus 06's 9 `rd_*` RPCs is exactly 45; every further public RPC (I need `rd_attachment_begin` + `rd_attachment_commit` = 47) makes it fail (have 46, want 47). I may not edit 022 beyond fixture additions. Options for Opus: (a) allow 022 test 30 to read two `pa_audit` pages (a scaling fix in 03's test), (b) merge RPCs (e.g. fold `rd_end_cavities` into `rd_set_cavities`, and begin+commit into one) to stay under the limit, (c) skip photos on readings in R1. Everything else in step 6 is ready: the finished SQL (`rd_attachment_begin/commit`, `app._rd_can_see_reading`, additive `app_policy.can_see_attachment` redefinition, `photos` in `reading_detail`) is saved as `sdlc/features/06-shift-readings/step6-attachments.patch` (apply with `git apply`); its pgTAP additions (extension of 042, new 054) are not written yet.
- Steps 7 and 8 not started: the photo parts depend on this decision.

### 2026-11-18 (Sonnet, step 6 finished)
- Done: D14 edit to 022; photo RPCs + visibility (patch applied, patch file removed); 054 (44 tests). Local pgTAP 28 files / 2178 tests green (with and without seed).
- Step 7 done: `src/lib/readings.ts` (+`reading-draft.ts`, `uploadReadingPhoto` in photos.ts), screens `/readings`, `/readings/record`, `/readings/occurrence`, `/today`, Counter panel in the machine form, Home buttons (Readings for supervisors, Today for web Unit Admins). Jest 63 suites / 800 tests; lint, typecheck clean. Local `npm run build` needs EXPO_PUBLIC_SUPABASE_URL (CI has it).
- CI proof: run 44228982578 on 75aee72 (steps 6 + 7): changes, db, static, e2e-web, ci-ok, summary all green.
- Step 8 written: `e2e/api/readings.spec.ts`, `e2e/web/readings.spec.ts`, `e2e/maestro/opening-closing.yaml` (no photo; each step runs only when the server offers it, so a same-day re-run on dev passes). Both specs reuse 07's clock-derived world (`setupIssueWorld`), unique tenant ids `...0b9` / `...0ba` and phones 77741-44 / 77751-54, per-run product and machine codes. Playwright cannot run locally here: proof is PR CI.
- Step 8 CI proof: run 44231298033 on fb6cbd2: changes, db, static, e2e-web (166 passed, incl. api + the new readings specs), ci-ok, summary all green. The first step 8 run (44229684579, 39fa3a2) failed twice: the api spec re-provisioned the shared Super Admin concurrently with platform.spec (its tenant_create got 401), and the web Counter panel test opened `/plant/machines/<id>` directly (now opened through the Plant list with a longer wait). Fixed in code, not by editing existing tests.
- Not done by design: step 9 (hosted proof, architecture docs) and step 10. Maestro `opening-closing.yaml` is written but only runs nightly/release (not on PRs).

### 2026-11-18 (Opus)
- Owner accepted the separate /readings screen for R1 (spec AC-11 note) and approved R4 (late opening) and R5 (early closing flag). Flag for roadmap (main, after R1): re-scope 05's Home RPC-count test; move readings onto My shift; UA alerts on native. 08 must not rely on adding RPC calls to Home (put its entry on the Readings/handover screen).

### 2026-11-18 (Sonnet, step 8a)
- Done: R1 (RecordForm context from `reading_detail`, gated on `allowed`; Record opening/closing buttons on the occurrence view; web e2e: Unit Admin records on behalf and the history says "Entered by a Unit Admin"), R2 (photo on closing), R3 (Today: movement, reject, unaccounted, "Not closed yet", "Not due yet", assumed target shown separately), R4 (late opening until end + 12 h), R5 (Early flag, capture rule), R6, R7 (opening time in plant time + Late on `/readings`), R8 N-1, N-5, N-6, N-7, N-8, N-10, N-11, N-12.
- Local: pgTAP 28 files / 2217 tests green with and without seed; Jest 63 suites / 814 tests; lint, typecheck clean. Playwright and Maestro cannot run here: proof is PR CI (Maestro nightly/release only).

### 2026-11-18 (Sonnet, step 9)
- Hosted proof on dev with the temporary dev-only pull_request triggers (a7153ea, removed in 6a1510f): deploy-dev run 44236613494 green (06's migration applied); regression run 44236613663: setup, drift, hosted-checks green, android green (Maestro incl. `opening-closing.yaml`), web green on attempt 3 (full suite incl. api and the new readings specs). Attempt 1 web: 2 failures in other features' specs (04 `plant.spec` "No target set" not visible within 5 s; 07 `issues.spec` still "Awaiting verification"); attempt 2 web: 1 failure (02 `change-password.spec:37`, sign-in not visible within 5 s after the password change); attempt 3: 0 failures. Each attempt failed in a different, unrelated test and the same tests passed in the other attempts and in PR CI on the local stack (e2e-web green on f704891); 06 changes no session, layout or sign-out code (its only shared-route change is two buttons on Home). Assessed as hosted-dev latency (5 s expects), not a 06 defect. Artifacts could not be downloaded (blob host blocked by the proxy), so the diagnosis rests on the job logs.
- Docs: `sdlc/product/architecture.md` (06 holds the lock): Readings model rule, counter semantics, versioned summary, capture metric, photo reuse, six known-debt items, four decision-log rows. The docs edit was committed inside 6a1510f together with the trigger removal (message mentions only the removal).
