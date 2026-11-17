# Plan: Shifts and assignments
Spec: ./spec.md · Status: approved · Date: 2026-11-17
Locks: schema — 05's tables only (shift, assignment_version, assignment_cover, target_override_version; split with 03 while 03 is open, logged). Architecture flags (spec "Proposed architecture changes") go into the session log and are applied on main at merge (03 holds the architecture lock until it merges).
Branches from main (01–04). **03 merges first**; 05 rebases on it in step 8 (022 fixture additions, `_pm_authorise` with the SA branch).

## Decisions (Opus)
- D1 Files: migration `20261117200000_shifts_assignments.sql` (after 03's `20261117100000`); pgTAP `030_shifts.test.sql`, `031_assignments.test.sql`, `032_target_overrides.test.sql`, `033_shift_reads.test.sql`.
- D2 Write RPCs are `public.pm_*` per spec FR-1, authorised by `app._pm_authorise` (UA only), D13 denials, request id tied to the RPC (04 pattern: idempotency lookup matches `source`). Registry inserts: `shift.created|updated|retired|reinstated`, `assignment.set|ended|covered`, `target_override.set|ended`.
- D3 Time model: `start_time`/`end_time` are `time` with check `extract(minute)` ∈ {0,15,30,45} and seconds 0; overnight when `end_time < start_time`; `end_time = start_time` is refused. `app.shift_window(shift_id, d)` = `[(d + start_time) at time zone tz, (d + (case when end_time < start_time then 1 else 0 end) + end_time) at time zone tz)` with tz = the site's timezone. Every time-dependent function takes `p_at timestamptz default now()` so tests pass explicit moments.
- D4 Time lock: `pm_save_shift` refuses a start/end change once any `assignment_version` or `assignment_cover` references the shift (guard `shift_times_locked`); name edits allowed.
- D5 Plan writes: `pm_assign(shift, supervisor, machines[], from, until?)` appends one version per machine at `from` (supervisor) and, if `until`, one null version at `until + 1`; refuse (guard `later_change`, listing dates) if any of those machines already has a version after `from` on that shift (no silent overwrite of a scheduled change). `pm_unassign` appends null versions at `from`. `from >= plant_date`. One audit row per call with `machines`, previous owners and new owner.
- D6 Cover: `pm_cover(shift, shift_date, machines[], supervisor|null, reason)` allowed while `p_at < upper(shift_window)`; appends one row per machine; one audit row.
- D7 Supervisor validity: target supervisor must have an active, not-must-change `supervisor` membership in the actor's tenant (else validation `supervisor`); unknown/foreign ids → generic denial (04 rule).
- D8 Resolution: `app.machine_owner(machine, shift, d)` = latest `assignment_cover` for (shift, d, machine) by `recorded_at desc, id desc` (its supervisor, possibly null = explicitly unassigned) else latest `assignment_version` with `effective_from <= d` else null. Tenant check like `target_for` (skip only for service_role).
- D9 Target overrides mirror 04: append-only, ≥ plant date, end cancels later scheduled overrides; `app.effective_target(machine, product, shift, d)` = latest non-null override in force (an ended override = fall back), else `app.target_for`.
- D10 Reads: `public.shift_board(shift_id, d)` (UA only; denial audited for others) returns every non-retired machine with owner id/name, source `plan|cover|none`, cover reason, owner status (inactive flag). `public.my_shift(p_at default now())` (any active member) returns the caller's occurrence: the running occurrence where the caller owns ≥ 1 machine, else the next one starting within 36 h, with shift name, window and the caller's machines (code, name, line). SUPs get **no** select on the three version tables.
- D11 UI: Plant tabs gain **Shifts** and **Assignments** (`src/app/(app)/plant/shifts.tsx`, `plant/assignments.tsx`); overrides in `src/components/plant/targets-panel.tsx`; SUP Home card `src/components/my-shift-card.tsx` in `home.tsx`. Data layer additions in `src/lib/plant.ts` (request-id rule as before). Reuse `src/lib/use-load.ts` (after 03's move; before the rebase use 04's path and fix the import at step 8).
- D12 Fixtures: org U — shifts Morning 06:00–14:00 and Night 22:00–06:00, U3 (SUP) owns two machines on both from a fixed past-safe date via the service role; org A — shifts covering the day so `my_shift` always has a current or next occurrence for the Android/web SUP fixture. fixtures-reset recreates them idempotently (version rows are append-only: reset appends a fresh plan version rather than deleting; throwaway e2e shifts are retired).

## Files that change
- `supabase/migrations/20261117200000_shifts_assignments.sql`, `supabase/tests/030–033_*.test.sql` — new
- `supabase/seed.sql`, `scripts/fixtures-reset.ts` (+ tests, additions only) — modified
- `src/lib/plant.ts` (+ tests), `src/app/(app)/plant/_layout.tsx` (tabs), `plant/shifts.tsx`, `plant/assignments.tsx`, `src/components/plant/targets-panel.tsx`, `src/components/plant/*` (shift form, assign/cover dialogs), `src/components/my-shift-card.tsx`, `src/app/(app)/home.tsx` — new/modified; screen tests new
- `e2e/web/shifts.spec.ts`, `e2e/api/shifts.spec.ts`, `e2e/maestro/my-shift.yaml` — new; `e2e/web/fixtures.ts` — additions
- Step 8 only: `supabase/tests/022_platform_boundary.test.sql` — fixture-block additions only (architecture extension point)
- Step 9 only: temporary dev-only triggers (removed before ready)

## Steps
- [x] 1. **Shifts (tests first).** 030: RLS (members read, no client writes), name uniqueness, 15-minute rule, end ≠ start, overnight windows, `shift_window`/`current_occurrences` at boundaries (start minute in, end minute out, 23:59, midnight, overnight started yesterday), time lock after an assignment, retire/reinstate, audit, denials (SUP, must-change, suspended), isolation. Then migration part 1 + `pm_save_shift`, `pm_set_shift_retired`. — proof: CI `db`
- [ ] 2. **Assignments (tests first).** 031: `pm_assign` (multi-machine, replaces owner from date, until → null version at until+1, `later_change` guard, no backdating), `pm_unassign`, `pm_cover` (running occurrence allowed, ended occurrence refused, re-cover latest wins, cover to unassigned), supervisor validity (UA/inactive/must-change/foreign refused), `machine_owner` cases (spec AC-5 list), append-only on both tables incl. service_role, audit rows, idempotency, isolation. — proof: CI `db`
- [ ] 3. **Target overrides (tests first).** 032: set/end/cancel-later, ≥ plant date, `effective_target` fallback chain, tenant rule (service-role only skip), audit. — proof: CI `db`
- [ ] 4. **Reads (tests first).** 033: `shift_board` (UA only, sources, unassigned grouping data, inactive supervisor flag, denial audited for SUP), `my_shift` (current vs next within 36 h, cover in/out, other SUP sees only their own, SUP has no select on version tables). — proof: CI `db`
- [ ] 5. **Fixtures** per D12 (+ fixtures-reset tests; existing refusals unchanged). — proof: CI green
- [ ] 6. **Client (tests first).** plant.ts calls + error mapping; screen tests for Shifts tab, Assignments board (pickers, grouping, multi-select, assign/cover dialogs naming who loses machines, reason required), override rows in the targets panel, My shift card states (running, next, nothing assigned, no shifts). Then implement D11. — proof: lint/typecheck/test
- [ ] 7. **E2E.** `e2e/web/shifts.spec.ts` (org U: create shift, assign, cover, board, override; SUP Home card; axe), `e2e/api/shifts.spec.ts` (SUP can't read version tables; `my_shift` isolation; SUP writes denied + audited), `e2e/maestro/my-shift.yaml` (proven in step 9's Android run). — proof: CI `e2e-web` green
- [ ] 8. **Rebase on 03 (after 03 merges).** Rebase; switch imports to `src/lib/use-load.ts`; add 05's four tables to 022's fixture block (additions only); confirm 022 discovers 05's RPCs and tables and SAs are denied; full suite green. — proof: CI green
- [ ] 9. **Hosted proof (dev)** after step 8: temporary dev-only triggers; deploy-dev + regression (web incl. api, Android incl. `my-shift.yaml`, hosted-checks, drift); remove triggers; green PR CI. — proof: run URLs
- [ ] 10. **Review + PR.** sdlc-reviewer, fixes, AC table, session log with architecture flags. — proof: PR CI green

## Risks
- Time/timezone/overnight maths — explicit `p_at` everywhere, boundary pgTAP.
- `later_change` guard may block a UA re-planning a week ahead; message lists the dates (they unassign those first). Revisit if annoying.
- Append-only fixtures accumulate versions on dev (as 04) — noted debt.
- Shared files with 03 → step 8.
- Rollback: additive; reverting removes screens; tables stay empty.

## Proof of done
AC-1–13 → tests (spec table); full suite green after rebase on 03; dev regression green incl. Android `my-shift.yaml`.

## Deviations from plan
- **RPC prefix `sh_*`, not `pm_*`** (D2/FR-1): 04's pgTAP test 011 asserts exactly nine `public.pm_*` functions and may not be edited, so 05's RPCs are `sh_save_shift`, `sh_set_shift_retired`, `sh_assign`, `sh_unassign`, `sh_cover`, `sh_set_target_override`, `sh_end_target_override` (audit `source` = `rpc:sh_*`). Helpers `app._sh_*`; 04's `app._pm_authorise/_pm_fail/_pm_audit/_pm_deny/_pm_len` are reused unchanged.
- Step 1 creates all four tables, RLS, append-only triggers and the nine registry actions (the time-lock test needs `assignment_version`/`assignment_cover`); steps 2-4 only add functions.
- `app.current_occurrences(p_at)` returns `(tenant_id, shift_id, shift_date, span)`; caller's tenant, or every tenant for the service role. Retired shifts are never current. No FK on `supervisor_id` (history outlives membership); trigger `app.sh_supervisor_same_tenant` checks the tenant.

## Session log
### 2026-11-17
- Done: intent approved (owner decisions 1–3), spec approved (supervisor picks the product in 06); plan drafted.
- Next step: owner approves plan → Sonnet executes steps 1–7 while 03 finishes; step 8 after 03 merges.
