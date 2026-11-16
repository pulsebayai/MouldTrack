# Plan: Plant masters
Spec: ./spec.md · Status: approved · Date: 2026-11-16
Batch A with 03 (04 merges first). Locks: schema split — 04 owns site, line, machine, product, target_version (logged in roadmap at launch). No architecture lock: architecture items are flagged in the session log and applied on main at merge.
**Prerequisite (PR #6, merged before both builds):** `20261116200000_audit_action_registry.sql` — audit actions are registered in `app.audit_action`; `audit_event` checks `app.is_known_audit_action(action)` (unknown → 23514, so 02's "unknown action rejected" test is unchanged). **04 registers its actions** (`site.*`, `line.*`, `machine.*`, `product.*`, `target.*`) with inserts in its own migration.

## Decisions (Opus)
- D1 Files: migration `20261117000000_plant_masters.sql`; pgTAP `010_plant_tables.test.sql`, `011_plant_rpcs.test.sql` (03 uses 02x numbers — no clashes).
- D2 RPCs are `public.pm_*`, `security definer`, `search_path=''`, `grant execute to authenticated`, revoked from anon/public. Shared helper `app._pm_authorise(p_request_id uuid, p_source text)` → `{ok, tenant_id, actor}` or a committed `access.denied` (reasons `no_membership|inactive|must_change_password|role`) using the same rules as `app._ua_authorise` but keyed on `auth.uid()`. Cross-tenant ids → `access.denied` reason `cross_tenant`. Idempotency: `audit_event` unique `(actor_user_id, request_id)` — a repeat returns `{ok:true, id, already:true}` from the stored audit row's `entity_id`.
- D3 Plant date: `app.plant_date(p_tenant uuid)` = `(now() at time zone s.timezone)::date` from the tenant's site (falls back to tenant timezone if no site).
- D4 `target_version` append-only: revoke UPDATE/DELETE/TRUNCATE from every role incl. service_role + trigger (copy 02's audit pattern). `app.target_for(machine, product, d)`: `select pieces_per_shift from target_version where machine_id=… and product_id=… and effective_from <= d order by effective_from desc, recorded_at desc, id desc limit 1` (null if none or ended). View `public.current_target` (security invoker; RLS applies) = latest version per pair as of plant date, excluding ended.
- D5 Composite FKs: every child has `unique (tenant_id, id)` on the parent and `foreign key (tenant_id, x_id) references parent (tenant_id, id)`.
- D6 Timezones: fixed list in `src/lib/timezones.ts` (Asia/Kolkata first + ~20 common IANA zones); server validates with `now() at time zone p_tz` inside an exception block → `validation`.
- D7 UI: `src/app/(app)/plant/_layout.tsx` (tabs, UA-only guard), `plant/index.tsx` (machines), `plant/machines/[id].tsx` (detail + targets panel), `plant/products.tsx`, `plant/site.tsx`; forms in `src/components/plant/*`. Reuse `ui.tsx`, `not-allowed.tsx`, confirm dialog, status labels from 02. Data access `src/lib/plant.ts` (request ids: new id after 5xx, reuse after network error — 02 R2 rule).
- D8 Fixtures: org U gets a site, 2 lines, 3 machines, 3 products and targets (mutating e2e); orgs A and B get 1 machine + 1 product each (read-only isolation fixtures). Throwaway e2e rows use codes `E2E-<random>`. `target_version` is append-only, so `fixtures-reset` can't delete targets: it **retires** throwaway machines/products (and deletes throwaway rows that have no targets). Dev accumulates a few retired rows per run — accepted, noted as debt.

- D9 **(Opus, resolves step 1 blocker)** Test 006 (prerequisite, written by Opus) wrongly used `machine.created` — an action 04 owns — as its example of an unregistered action. Authorised change: in `supabase/tests/006_audit_action_registry.test.sql` replace the literal `machine.created` (all occurrences) with `tap_example.created`; nothing else in that file changes. Every assertion keeps its meaning and strength; the test just no longer depends on a name a feature owns. Logged as a deviation when made (first commit of step 1).
- D10 Builder design points accepted: `recorded_at default clock_timestamp()`; read view `public.plant_today`; `pm_end_target` with no target in force → guard `no_target`; reinstating a machine whose line is archived clears `line_id`; unknown and foreign ids both → generic denial; API fixture orgs use `orgDef(8|9, …)` (03 avoids 8 and 9).

## Files that change
- `supabase/migrations/20261117000000_plant_masters.sql` — new
- `supabase/tests/010_plant_tables.test.sql`, `011_plant_rpcs.test.sql` — new
- `supabase/seed.sql`, `scripts/fixtures-reset.ts` (+ `scripts/__tests__/fixtures-reset.test.ts` additions only) — modified
- `src/lib/plant.ts`, `src/lib/timezones.ts` (+ tests) — new
- `src/app/(app)/plant/**`, `src/components/plant/**` — new; `src/app/(app)/home.tsx` — modified (Plant entry for UA)
- `src/__tests__/screens/plant-*.test.tsx` — new; `src/__tests__/screens/home.test.tsx` — additions only
- `e2e/web/plant.spec.ts`, `e2e/api/plant.spec.ts` — new; `e2e/web/fixtures.ts` — additions
- `.github/workflows/deploy-dev.yml`, `regression.yml` — temporary dev-only `pull_request` triggers for the hosted proof only (removed before PR ready)

## Migrations
`20261117000000_plant_masters.sql` (after the prerequisite). Additive.

## Steps
- [x] 1. **Tables, RLS, append-only targets, `target_for` (tests first).** `010`: per table — RLS enabled+forced, member of A reads A only (UA and SUP), B invisible, anon nothing, no client insert/update/delete; composite FK rejects cross-tenant parent; one site per tenant; uniqueness rules (case-insensitive); target_version UPDATE/DELETE fail for every role incl. service_role; `target_for` cases of spec AC-7; `plant_date` at 23:30 IST vs UTC date; `current_target` view hides ended. Then the migration (tables, indexes incl. `(machine_id, product_id, effective_from desc, recorded_at desc)`, helpers, view). — proof: CI `db`
- [ ] 2. **Write RPCs (tests first).** `011`: each `pm_*` success + exactly one audit row (actions per spec), validation/duplicate/guard codes with field, denials audited for SUP / must-change / suspended tenant / no membership / cross-tenant id, idempotent repeat, no backdating (`effective_from < plant_date` → validation `effective_from`), product retire blocked with current or future target (detail lists machine codes), line archive blocked with non-retired machines, retired machine/product can't get a target, reinstate. Then implement per D2–D4. — proof: CI `db`
- [ ] 3. **Fixtures.** seed + fixtures-reset per D8; extend fixtures-reset tests (new tables only refused outside local/dev — existing refusals unchanged). — proof: `npm run test`, CI green
- [ ] 4. **Client data layer (tests first).** `src/lib/plant.ts` typed reads + RPC calls, error → field mapping, request-id rule; `timezones.ts`. — proof: lint/typecheck/test
- [ ] 5. **Screens (tests first).** Screen tests: site setup gate, tabs, lists (search, status/line filters, 25/page, empty/loading/error), machine form + retire/reinstate confirm, product form + retire blocked message, site & lines (archive blocked), targets panel (current, next, history, "No target set"), set/end target forms (date ≥ today, integer), SUP → Not allowed, Home shows Plant for UA only. Then implement D7. — proof: lint/typecheck/test
- [ ] 6. **E2E.** `e2e/web/plant.spec.ts` (org U: set up flow, add machine/product, set → change → end target and see history, retire guard, axe 0 serious/critical on each tab and detail) and `e2e/api/plant.spec.ts` (over HTTP: SUP write → `{ok:false, code:'not_allowed'}` + audit row; cross-tenant read returns 0 rows). — proof: CI `e2e-web` green
- [ ] 7. **Hosted proof (dev).** Re-add temporary dev-only `pull_request` triggers (as 02 867773a); green deploy-dev (migration) + regression (web incl. api, Android 5/5 unchanged, hosted-checks, drift); remove triggers; green PR CI on the last commit. **Only after the prerequisite PR is merged, and before 03's hosted proof.** — proof: run URLs
- [ ] 8. **Review + PR.** sdlc-reviewer, fix Important, AC table in PR, session log incl. architecture flags (spec "Proposed architecture changes" 2–3 + "known actions" list). — proof: PR CI green

## Risks
- Plant-date maths at midnight (pgTAP edge cases; server-only computation).
- Append-only targets accumulate throwaway rows on dev (D8) — acceptable, noted.
- Shared files with 03 (seed, fixtures-reset, home, fixtures.ts): keep 04's changes additive and grouped so 03's rebase is mechanical.
- Rollback: additive migration; reverting the PR removes screens; tables can stay empty.

## Proof of done
AC-1–14 → tests (spec table); full suite green on PR CI; dev regression green incl. Android.

## Deviations from plan
- The audit-action change moved from 04 to prerequisite PR #6, and became a **registry** instead of a format rule (a format rule would accept `user.exploded`, breaking 02's test). Spec "Proposed architecture changes" 1 is superseded accordingly.

- (Sonnet, step 1) D9 applied: `supabase/tests/006_audit_action_registry.test.sql` — only the literal `machine.created` → `tap_example.created` (3 lines). Otherwise unchanged.
- (Sonnet, step 1) Added helper `app.plant_date_at(tenant, timestamptz)` (plant_date = plant_date_at(…, now())) so the 23:30/00:30 IST edge can be tested deterministically; revoked from clients like the other helpers. Extra view `public.plant_today` per D10.

## Session log
### 2026-11-16
- Done: intent + spec approved; plan drafted.
- Next step: owner approves plan (+ prerequisite PR); Sonnet executes steps 1–6.

### 2026-11-17 (Sonnet, steps 1–6)
- Done: read CLAUDE.md, product docs, intent/spec/plan, and 02's migrations, tests, screens, e2e and fixtures; `npm ci` ok. No code written yet (stopped at step 1 before the migration).
- **Resolved by Opus (D9) — was: Blocked - needs Opus:** the plan makes 04 register `machine.*` actions (AC-3: `machine.created|updated|retired|reinstated`), but the prerequisite's `supabase/tests/006_audit_action_registry.test.sql` uses **`machine.created` as its example of an unregistered action** (it expects the insert to fail with 23514, then registers it itself with `insert into app.audit_action`). Once 04's migration registers `machine.created`, 006 fails on two counts: test 5 ("an unregistered action is refused") and the later `insert into app.audit_action ... 'machine.created'` (duplicate key). Reproduced locally: apply all migrations + `insert into app.audit_action values ('machine.created','04')` → 006 fails 5/9. I may not edit 006 and may not rename spec'd actions. Options:
  1. Owner/Opus authorises a one-line change to 006 (use a neutral name such as `widget.created`, test intent unchanged), and 04 registers `machine.*` as specified. Same hazard applies to 03 if it registers any name 006 uses (only `machine.created` is used).
  2. Rename 04's machine actions (e.g. `plant_machine.created`) and amend spec AC-3; 006 stays untouched.
  Recommendation: option 1 (006 should not depend on a name a later feature owns).
- Everything else in steps 1–6 is unblocked by this decision except the migration's registry inserts and the audit-action assertions in `011`/`e2e/api/plant.spec.ts`. Once decided, re-launch Sonnet for steps 1–6.
- Notes for the next session (no decision needed, flagged so they are not rediscovered):
  - A faithful local pgTAP loop exists on this box without Docker: Postgres 16 + pgtap are installed (`/usr/lib/postgresql/16`, `pg_prove`). Bootstrap = roles anon/authenticated/service_role, schemas `auth` (users, sessions, identities, `uid()` reading `request.jwt.claims`) and `extensions` (pgcrypto, pgtap), then all migrations, then `pg_prove`. Existing 001–006 pass there (208 tests). It is a convenience, not proof: CI `db` remains the proof.
  - Small design points the plan leaves open, which I intend to implement as follows unless told otherwise: (a) `target_version.recorded_at` defaults to `clock_timestamp()` so same-transaction same-day corrections order correctly; (b) an extra read view `public.plant_today` (tenant_id, plant_date) so the UI can compute "current/next" without doing date maths itself; (c) `pm_end_target` with no target in force on the date → guard error `no_target`; (d) reinstating a machine whose line was archived clears `line_id`; (e) unknown or foreign ids in RPCs both return the generic denial (reason `not_found` / `cross_tenant`), no existence leak, as 02 does.
