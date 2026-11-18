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
- [x] 4. Reads + compliance (D7); pgTAP 063: checklist contents/order/bounds, alerts, AC-12 cases (compliant, late, no
  declaration, refusal without exception, unassigned excluded, overdue count); timing check for AC NFRs on seeded volume.
- [x] 5. Fixtures: `e2e org H` in seed + fixtures-reset; demo tenant declarations; size-check baseline; hosted check D1.
- [x] 6. Client lib + screens (D9) with Jest/RNTL; axe on web (axe runs with the web e2e in step 7, which waits for the H decision).
- [x] 7. Web e2e `handover.spec.ts` (SUP checklist → declare → opening; refuse → UA exception; cover re-declare; note shown)
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

### 2026-11-18 (Sonnet) step 4
- Reads: `app.handover_checklist_at` / `public.handover_checklist()` (SUP only; occurrences from start - 30 min until end, and until end + 12 h while the declaration is missing; machines by code, issues by reported time, previous owner, last 3 actions, latest note, `allowed_actions`, occurrence `allowed_actions` = `declare`, `deadline`, `overdue_minutes`, `verify` section via 07's `_iss_row` + `issue_can_verify`), `app.handover_alerts_at` / `public.handover_alerts()` (UA; exceptions pending oldest first + overdue acknowledgements most overdue first, each bounded to 50 with `*_total`), `app.handover_compliance_at` / `app.handover_compliance` (app-only; per supervisor x occurrence: compliant, reason `no_declaration | late | exception_missing`, deadline, counts, `overdue_acks`). No client time anywhere.
- The checklist read is the only read that writes (`handover_session` snapshot(s): the window start and every cover time that gave the supervisor a machine; `on conflict do nothing`). It is therefore volatile: clients must call it with POST (supabase-js `rpc` default); a read-only GET would fail. Flag for the architecture step.
- Compliance interpretation (flag for review): the deadline for the declaration = the latest item deadline (cover time + minutes) or window start + minutes; an unanswered issue already closed at its deadline drops out; a refusal counts as answered, and is non-compliant until a Unit Admin exception exists (recorded at any time up to the evaluation moment); overdue acknowledgements = items unanswered or answered after their deadline.
- Alerts only list overdue items of occurrences running or ended < 12 h ago (older ones belong to the compliance report).
- pgTAP 063 (103 tests). Timing on a plain PostgreSQL 16 rig with 300 machines / 200 issues: checklist 35 ms, alerts 109 ms (NFR 500 ms); the test asserts the NFR and prints the measured value.

### 2026-11-18 (Sonnet) step 5 (partial) - Blocked - needs Opus
- Done: demo tenant is enforced (`handover_setting` row, required) and gets one declaration per (supervisor, occurrence) that the supervisor opened themselves (`buildDeclarations` in `dev-demo-spec.ts`, seeded in `dev-demo-seed.ts`, counted in `demoCounts`); size-check baseline counts the six new tables (`COUNT_KEYS`, `expectedCounts`); hosted check 10 ("every tenant except the four fixture tenants A/B/S/U has `required = true`", read-only REST, TAP plan 1..10). Jest in `scripts/` passes (173).
- **Blocked - needs Opus: `e2e org H` cannot be added without breaking pinned earlier tests.** The reset chore's and 04/05's Jest tests pin the fixture lists exactly: `fixtures-reset.test.ts:48` `TENANTS.map(name)` equals the four names; the 04/05 tests pin `PLANT` tenants to A, B, U and `SHIFTS` tenants to A, U; `dev-size-check.test.ts` pins `tenant = TENANTS.length + 1`, `site = PLANT.length + 1`, `shift = SHIFTS.length + d.shift`, `machine`, `product`, `target_version`, `membership` and `auth_users` to the same arrays. Putting H in the arrays breaks the first group; keeping H outside them and counting it breaks the second group. I did not touch those tests, `seed.sql` or `fixtures-reset.ts` for H.
  Options: (A) approve editing exactly those pinned assertions (add H to `TENANTS` / `PLANT` / `SHIFTS` / `USERS`, list updated) - the fixture lists stay the single source for seed, reset and baseline; (B) H lives in its own export `HANDOVER_FIXTURE` (like `READINGS`) outside the arrays, and `expectedCounts` adds it - needs the size-check assertions edited anyway; (C) no fixture tenant: 08's web/API e2e and Maestro register their own enforced tenant through the Console (SA + `platform` Edge Function: registration always enforces, D1) and create UA/SUPs, accumulating like the `e2e t3` tenants (known debt, suspended after the run); (D) enforce org U (breaks 06's e2e openings: rejected). Recommendation: (A), the smallest edit and the baseline keeps working; phones +91 90000 00020 (UA), 00021, 00022 (supervisors) are free.
- Hosted note: `deploy-dev` applies the migration to a dev that still holds tenants, so the backfill makes org A/B/U enforced until the next `dev-reset` (every nightly and hosted proof starts with one; `db reset` re-applies the migrations on an empty database, so afterwards only registered tenants and the demo tenant are enforced).

### Session log - step 6 (Sonnet, 2026-11-18)
- Environment: replaced the shared node_modules symlink with this branch's `npm ci` (expo-image-* now resolve). One more trap: `expo lint` keeps a cache in `.expo/cache/eslint/` that held stale
  unresolved-import results; deleting it fixed lint. Local result: lint 0, typecheck 0, Jest 70 suites / 949 tests green (was 897; +52 for step 6).
- Added `src/lib/handover.ts` (types, labels, validation equal to the server limits: remark 200, refusal/exception reason 200, note 300, overdue 15-480; `bannerText`, `openingBlocked`,
  reads that tolerate missing arrays, `handoverApi`), `src/components/handover/{checklist,handover-banner,handover-alerts-card,overdue-setting}.tsx`, route `(app)/handover.tsx`.
  `handover_checklist` is called through supabase-js `rpc`, which is a POST, so the read that writes the session snapshot never runs as a GET.
- Interpretations, flag for review:
  1. **No handover calls inside existing screens' pinned paths.** 07's `IssueAlertsCard` and the Issues screen have tests that pin their exact rpc calls (count and last call), so the handover
     alerts are a separate `HandoverAlertsCard` on UA Home (web) beside the issue alerts, not a section inside 07's card or the Issues -> Alerts tab as D9 words it. Each list shows 5 with
     "Show all" expanding to the server's 50, instead of a link to a tab. No earlier test touched.
  2. **Opening gate in the UI** is in `ReadingsCard` only (the list that offers "Record opening"): it also reads the checklist and replaces the button by a disabled one plus "Complete your handover
     checklist first" and a link to the checklist when the server says the occurrence is enforced and not declared. 06's `reading_state` is unchanged, so the client cannot know this from it;
     if the checklist read fails the button stays and the server (D6) decides. My shift has no opening action, so it only got the Home banner.
  3. **Exception owner**: `ho_exception` requires an active supervisor (p_owner_id is never null), so "keep" = choose the current owner (preselected, labelled "current owner"); the server records kept = true.
  4. **Overdue setting** is its own card (`OverdueSetting`) at the bottom of Plant -> Site & lines; it reads `handover_setting` under RLS (no rpc on load) so 04's site tests are unchanged.
- Not done here: axe checks and the e2e/Maestro flows (step 7, after the H decision); the Console tenant-detail "Handover: enforced" label from D1 is not built (03's Console screens and tests are
  untouched; needs a `pa_*` read change in a later step, ask Opus whether it is still wanted).

### Session log - step 5 finished, option A (Sonnet, 2026-11-18)
- Owner decision (via Opus): option A. `e2e org H` added; **edited earlier-test lines (additions to expected fixture lists only, each carries the comment "owner-approved 2026-11-18 (08 option A): e2e org H added")**:
  - `scripts/__tests__/fixtures-reset.test.ts`: the `TENANTS` name list (was line 48); the PLANT tenants list (test title also now reads "orgs A, B, U and H"); the SHIFTS tenants list (title "orgs A, U and H"); the seed plan-row regex recorded_by group `(a1|e1)` -> `(a1|e1|c2)` (H's plan is recorded by its UA c2).
  - `scripts/__tests__/fixtures-reset-issues.test.ts`: the sorted `tenant:priority:status` list gained `e2e org H:high:open`, `e2e org H:medium:open`.
  - `scripts/__tests__/dev-size-check.test.ts`: no edit needed (formula-driven from the lists; the `handover_setting` baseline is in `dev-size-check.ts`: demo + `HANDOVER_ENFORCED.length`).
- H: tenant `e2e org H` (id ...00f); UA `+91 90000 00020` (Fixture Admin H1, FX-H1), supervisors `...00021` (Fixture Supervisor H2) and `...00022` (Fixture Supervisor H3); site Fixture Plant H; machines FX-MH1, FX-MH2; product FX-PH1; targets 900/700; shifts Fixture Shift H1 00:00-12:00 and H2 12:00-00:00 (24 h, like org A); h2 owns FX-MH1 and h3 owns FX-MH2 on both shifts; two open issues (High on FX-MH1 reported by h3, Medium on FX-MH2 reported by h2), so each supervisor always has an inherited issue. `handover_setting` (required true, 60 min) is inserted by `seed.sql` and `fixtures-reset.ts` (`HANDOVER_ENFORCED`). Hosted-check D1 already covers it.
- CI note: the first CI run on step 6 failed once, twice on re-run, then passed on attempt 3 in `readings.spec.ts:111` (06's Today board test takes `.first()` of the target rows, and `today_board` orders occurrences by shift name, which the throwaway world makes random: roughly a coin flip). Pre-existing, not touched; flagged for chore/test-reliability.

### Session log - step 7 (Sonnet, 2026-11-18)
- Added `e2e/web/handover.spec.ts` (4 tests), `e2e/api/handover.spec.ts` (10 tests) and `e2e/maestro/handover.yaml`; helpers `enforceHandover` and `seedInheritedIssue` appended to `e2e/api/helpers.ts` (additions only).
- Design: the mutating flows run in their own tenants ("e2e web org handover", "e2e api org handover": the gate switched on by a service-role `handover_setting` row, issues seeded as inherited by the clock-derived world of 07). Org H is used where it can be stable: web test 4 reads the Unit Admin's setting view (read-only), the API spec uses an org H supervisor as the cross-tenant attacker (denied calls only write audit rows), and the Maestro flow signs in as supervisor H2 and acknowledges the fixture issue (the only flow that answers org H's checklist; dev is rebuilt every run). Reason: web, API and Android can run in parallel against the same dev database, and a declaration or acknowledgement in org H is append-only and would break whichever flow runs second.
- Covered: banner, checklist, blocked opening, acknowledge/refuse (reason required), declare, opening offered, UA alert + exception reassigning the owner (ownership rows report, reassign), overdue setting 15-480 and `Handover: enforced`, axe on checklist, UA Home alerts and Site tab (serious/critical = 0); API: denials (other supervisor, UA, SA, cross-tenant org H, with audit rows), idempotent replay and request id tied to its RPC, items_pending, already_declared, gate handover_pending then accepted opening, notes limit, exception guards, setting bounds, append-only.
- Not run locally (no Supabase stack in the sandbox): these run in PR CI (e2e-web, which includes the `api` project) and Maestro in the nightly. The cover-re-declare flow of the step list (cover after the handover makes the earlier declaration stale) is proven by pgTAP 061/062 only; a clock-independent e2e needs a cover recorded during the running occurrence and is left for Opus to decide (listed in the report).

