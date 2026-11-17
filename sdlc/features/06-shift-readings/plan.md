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
- [ ] 6. **Rebase on 07 (after 07 merges).** Resolve shared files; add attachment entity type `production_reading` + its visibility (owner in that occurrence, UAs) to 07's `can_see_attachment` path via 06's migration (additive redefinition); extend 07's Storage tests with additions for the new entity; full suite green. — proof: CI green
- [ ] 7. **Client (tests first).** readings.ts; My shift card states/actions (keeping 07's "Report issue"); opening form (product chips with default, counter, optional photo via 07's photo pipeline, remarks), closing form (counter, good, reject), summary card with flags as text; Counter panel in Plant; UA Today board + Home entry; drafts + refresh pattern. — proof: lint/typecheck/test/build
- [ ] 8. **E2E.** web `readings.spec.ts` (SUP opening → closing → summary; correction; UA Today board; counter panel; axe), api `readings.spec.ts` (other SUP denied + audited; UA on behalf; photo on a reading; SA denied), Maestro `opening-closing.yaml` (no photo, as 07 D8). — proof: CI `e2e-web` green
- [ ] 9. **Hosted proof (dev)** after 07's merge + step 8; then **docs** (architecture.md with the lock: readings model, versioned summary, counter semantics) — proof: run URLs, docs diff
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
- Blocked - needs Opus: 06's photo RPCs cannot be added without breaking 03's test 022 test 30 ("the platform audit lists them", `pa_audit(0)`). `pa_audit` returns one page of 50 rows; 022 expects one denial row per discovered client RPC plus one, and ~4 other platform events share the page, so the first page holds at most 46 RPC denials. Main plus 06's 9 `rd_*` RPCs is exactly 45; every further public RPC (I need `rd_attachment_begin` + `rd_attachment_commit` = 47) makes it fail (have 46, want 47). I may not edit 022 beyond fixture additions. Options for Opus: (a) allow 022 test 30 to read two `pa_audit` pages (a scaling fix in 03's test), (b) merge RPCs (e.g. fold `rd_end_cavities` into `rd_set_cavities`, and begin+commit into one) to stay under the limit, (c) skip photos on readings in R1. Everything else in step 6 is ready: the finished SQL (`rd_attachment_begin/commit`, `app._rd_can_see_reading`, additive `app_policy.can_see_attachment` redefinition, `photos` in `reading_detail`) is saved as `sdlc/features/06-shift-readings/step6-attachments.patch` (apply with `git apply`); its pgTAP additions (extension of 042, new 054) are not written yet.
- Steps 7 and 8 not started: the photo parts depend on this decision.
