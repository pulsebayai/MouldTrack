# Plan: 08 Shift handover and acknowledgement
Spec: ./spec.md (approved 2026-11-18) · Status: approved 2026-11-18 (owner: late declaring OK, 08 test data OK, Q1 OK) · Author: Opus · Executor: Sonnet
Locks: **schema** (08 tables + additive redefinitions) and **architecture** (handover model, cross-feature gate, compliance) when approved.
Branch: feat/08-shift-handover-ack, rebased on main 9978d02 (06 + dev reset merged). Builds alongside chore/test-reliability
(which touches app/e2e waits, not migrations); 08 rebases on it before step 9.

## Decisions
- **D1 Enforcement scope (owner question Q1).** The `rd_opening` gate applies to tenants that have a `handover_setting` row with
  `required = true`. **Every tenant registered through the Console** (`app.pa_register_tenant`, 03) gets that row in the same
  transaction, and the migration backfills `required = true` for every tenant that exists when it runs (on staging/prod: all
  real tenants). Tenants inserted directly by tests (pgTAP fixtures, `seed.sql`, `fixtures-reset`) have no row and are not
  gated, so 06's tests, which record supervisor openings in such tenants, stay unchanged (no test edit). There is **no RPC or
  screen to switch enforcement off** in R1. Guards: pgTAP "registration always enforces"; nightly hosted check
  "every non-fixture tenant has required = true"; Console tenant detail shows "Handover: enforced".
  Fixtures: a new fixture tenant **`e2e org H`** (enforced) with its own UA + 2 SUPs (unused canonical phones) for 08's e2e and
  Maestro; the demo tenant is enforced and gets declarations for its past occurrences (demo seed additions; size-check baseline
  updated, which is the reset chore's intended extension point).
- **D2 "Declared for O"** = a `handover_declaration` for (S, O) whose `at` ≥ S's latest handover start in O (O's start, or the
  latest cover time that gave S a machine). A later cover makes the earlier declaration stale (AC-6); it stays in history.
- **D3 Windows.** Checklist visible and acknowledge/refuse/declare allowed from O's start − 30 min until **O's end + 12 h**
  (aligned with 06's late-opening window, so a late supervisor can still declare and then open; anything after the deadline is
  non-compliant). Notes: until 2 h after O's end (spec AC-10).
- **D4 Inherited set** = `app.handover_items_at(S, O, p_at)`: issues in Open / In progress / Resolved-awaiting-verification on
  machines whose `app.machine_owner` for O is S, `reported_at` < S's handover start for that machine, not closed at `p_at`.
  Uses 05's `app.machine_owner` / `app.shift_window` (no new window maths; if a set-based copy is needed, pin it to the
  original as 053 does).
- **D5 RPCs** `public.ho_acknowledge|ho_refuse|ho_declare|ho_add_note|ho_exception|ho_set_overdue` authorise via
  `app._ho_authorise` (copy of `_pm_authorise` admitting SUP + UA, non-members routed through `_pm_authorise`, as 06/07).
  D13 denials, request ids tied to the RPC, audit in the same transaction, registry rows `handover.*`.
  Acknowledge on an issue S already owns → acknowledgement row, no ownership row. Refuse → 07's escalate path (`iss_escalate`
  internals, owner unchanged). Exception owner = another active SUP (07 reassign internals) or "keep" (no ownership change).
- **D6 Gate** = additive redefinition of `public.rd_opening` in 08's migration: when the tenant is enforced and the caller is a
  SUP and not declared for O → P0001 guard `handover_pending`. UA on-behalf is not gated. 06's tests unchanged (D1).
- **D7 Reads** `public.handover_checklist()` (SUP; running + next occurrence like `my_shift`; items grouped by machine, last 3
  actions, latest note, verify section from `app.issue_can_verify`, `allowed_actions`) and `public.handover_alerts()` (UA;
  exceptions pending oldest first, overdue acknowledgements; bounded 5 + total). `app.handover_compliance(tenant, from, to)`
  app-only (09 wraps it). `handover_session` row is written on the first checklist read (snapshot of overdue minutes) by
  a `SECURITY DEFINER` read that inserts at most once per (S, O) — the only write from a read; flagged in architecture.
- **D8 Tables** per spec, all append-only (revoke + trigger) except `handover_setting` (UA updates via `ho_set_overdue`, audited);
  composite `(tenant_id, id)` FKs; RLS UA-read only (SUPs read through functions); 022 fixture block additions.
- **D9 Client.** SUP Home banner "Handover: N to acknowledge" (Home RPC allowed since PR #20); checklist screen
  `/(app)/handover`; My shift / Readings opening actions show "Complete your handover checklist first" and are disabled when
  the server says so. UA: Handover section in 07's alerts card + Issues → Alerts tab; exception dialog; overdue setting in
  Plant → Site & lines. Server-driven `allowed_actions` only.

## Steps (tests first in each)
- [x] 1. Migration part 1: tables, RLS, append-only triggers, registry, `handover_setting` backfill + registration hook (D1, D8);
  pgTAP 060 (tables, isolation, append-only, backfill, registration enforces). 022 fixture additions.
- [x] 2. Helpers: `app.handover_items_at`, `app._ho_declared_at`, windows (D2–D4); pgTAP 061 incl. cover time, reported during O
  excluded, closed drops out, carry-forward across day / overnight / cover (AC-11).
- [x] 3. Write RPCs (D5) + gate (D6); pgTAP 062: AC-2–8, AC-10, AC-13 (denials, idempotency, SA denied, cross-tenant),
  `rd_opening` refused then allowed, UA bypass, unenforced tenant unaffected.
- [ ] 4. Reads + compliance (D7); pgTAP 063: checklist contents/order/bounds, alerts, AC-12 cases (compliant, late, no
  declaration, refusal without exception, unassigned excluded, overdue count); timing check for AC NFRs on seeded volume.
- [ ] 5. Fixtures: `e2e org H` in seed + fixtures-reset; demo tenant declarations; size-check baseline; hosted check D1.
- [ ] 6. Client lib + screens (D9) with Jest/RNTL; axe on web.
- [ ] 7. Web e2e `handover.spec.ts` (SUP checklist → declare → opening; refuse → UA exception; cover re-declare; note shown)
  + API e2e (SUP opening refused before declaring; other SUP denied). Maestro `handover.yaml`.
- [ ] 8. Docs under the locks: architecture (handover model, cross-feature gate rule, compliance = metric 2, D1 enforcement,
  the read that writes `handover_session`), known debt.
- [ ] 9. Rebase on chore/test-reliability, full PR CI, hosted dev proof (dispatch, after the reset), Opus review, AC table, PR.

## Files that change
`supabase/migrations/20261118500000_handover.sql` (new), `supabase/tests/060–063_*.sql` (new), `022_platform_boundary.test.sql`
(fixture block additions only), `supabase/seed.sql`, `scripts/fixtures-reset.ts`, `scripts/dev-demo-seed.ts`,
`scripts/dev-size-check.ts` (baseline), `scripts/hosted-checks.sh` (D1 check), `src/lib/handover.ts`,
`src/app/(app)/handover.tsx`, Home, My shift card, Readings opening form, 07 alerts card + Issues alerts tab, Plant → Site &
lines, Console tenant detail (label), Jest tests, `e2e/web/handover.spec.ts`, `e2e/api/handover.spec.ts`,
`e2e/maestro/handover.yaml`, architecture.md.

## Owner questions (plan gate)
- **Q1 (D1) — owner: approved 2026-11-18.** handover is mandatory for every tenant created through the Console, with no off switch in R1; tenants that
  tests insert directly are exempt so earlier tests stay untouched. OK?

## Session log
### 2026-11-18 (Opus)
- Plan drafted after rebasing on main 9978d02.
- Owner approved the plan, D3 (declare until end + 12 h), D1 test data and Q1. 08 takes the schema and architecture locks.

### 2026-11-18 (Sonnet) step 1
- `20261118500000_handover.sql` part 1: six tables (`handover_setting`, `handover_session`, `issue_acknowledgement`, `handover_declaration`, `handover_exception`, `handover_note`), RLS (UA read only), append-only triggers, member-same-tenant trigger, registry `handover.*` (6), `app._ho_backfill` (run once in the migration), `app._ho_enforced`, `app.pa_tenant_create` redefined to insert the setting row.
- 07's `issue_action.type` CHECK widened with `handover_ack` and `handover_refuse` (additive; 040/041 unchanged).
- pgTAP 060 (47 tests) + 022 fixture-block additions (additions only).
- Verification aid (not an official result): migrations + tests also run on a plain PostgreSQL 16 with stubbed Supabase schemas; 060 and 022 pass there; CI is the authority. 013/030/031/032/042/050/054 show stub-related errors on that rig with and without 08 (identical counts), so they are not evidence either way.

### 2026-11-18 (Sonnet) step 2
- Helpers: `app._ho_upto` (moment handling: a moment that is not in the past means "no upper bound", because rows written in the same transaction carry `clock_timestamp()` later than `now()`), `app._ho_owners` (set-based owner resolution: cover > plan, unassigned and retired excluded, `since` = cover time when recorded after the start, handover start; bounded to 93 days; copy of 05's rule pinned to `app.machine_owner` / `app.shift_window` by 061), `app._ho_status_at` (issue status as of a moment from 07's append-only actions; current row when the moment is not in the past), `app.handover_items_at`, `app._ho_declared_at`.
- Interpretation recorded: a declaration or acknowledgement made in the 30 minutes before the start counts; only a later **cover time** makes earlier ones stale (D2/AC-6). Declaration with no inherited items is valid at any time within the windows (enforced by the RPC in step 3).
- pgTAP 061 (51 tests): inherited set incl. before/after start, resolved included, closed drops out as of a moment, cover recorded before/after the start, overnight and cover carry-forward, stale acknowledgement/declaration, exception pending, pins to 05.

### 2026-11-18 (Sonnet) step 3
- RPCs `public.ho_acknowledge | ho_refuse | ho_declare | ho_add_note | ho_exception | ho_set_overdue`; helpers `app._ho_authorise` (supervisor | unit_admin), `_ho_scope`, `_ho_window`, `_ho_owns`, `_ho_pending_item`. `rd_opening` redefined (`create or replace`, 06's body unchanged + the `handover_pending` guard after the owner check; 06 migrations untouched).
- Interpretations (flag for review): (1) **"keep with <refusing supervisor>"** = `ho_exception` with `owner_id` equal to the issue's current accountable owner (`kept = true`, no ownership row); any other active supervisor is a 07 reassign. The dialog should label the keep option with the current owner's name. (2) A refusal of an issue **awaiting verification** (resolved) writes the refusal and a `handover_refuse` action but does not escalate (07 only escalates open/in-progress). (3) Another supervisor / non-owner acting on an issue or occurrence gets the generic audited denial (`not_owner`); a Unit Admin gets `role`.
- 07's `issue_action.type` rows added by 08: `handover_ack` (notes "Acknowledged at handover[: remark]"), `handover_refuse`; the refusal also appends 07's `escalate`.
- pgTAP 062 (136 tests): AC-2..AC-8, AC-10, AC-13, windows (-30 min / +12 h; notes start..+2 h), idempotency, gate (enforced / unenforced / UA on behalf / stale declaration after a cover). Earlier suites unchanged; 022 discovers the six new RPCs automatically.
