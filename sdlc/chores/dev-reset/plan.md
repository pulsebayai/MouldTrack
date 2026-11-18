# Plan: chore/dev-reset — hosted dev is rebuilt clean before every run
Status: approved 2026-11-18 (owner: approach "Yes I approve"; demo tenant option (a) "yes let us go with a") · Author: Opus · Executor: Sonnet
Holds: architecture lock (docs only). No migrations. No test from 01–07 or 006 is edited.

## Why
Append-only history (targets, assignments, covers, issues, readings, audit, Console test tenants) can't be deleted, so
`fixtures-reset` can only retire/close, and dev grows every nightly and hosted proof. [Likely] this growth causes the 5 s
timeouts seen in 06's and 07's hosted proofs. Owner: "clean the test data and don't allow it to increase for every run".

## Decisions
- **D1 Reset, never bypass.** Dev is rebuilt from the migration files; no delete path around append-only rules is added to
  the schema (it would ship to prod).
- **D2 Order in `regression.yml` (dev only):** `drift` runs **first, on the un-reset database** (keeps the proof that
  deploy-dev applied main's migrations incrementally) → new `reset` job → `web` → `android` → `hosted-checks`.
  staging/prod never get the reset job (job `if: target == 'dev'` **and** the script's own guard).
- **D3 What the reset clears:** (1) every object in Storage bucket `attachments` (Storage API, service role); (2) every
  Auth user (Auth admin API; dev holds fixtures only); (3) the database, via `supabase db reset --db-url "$DEV_SUPABASE_DB_URL"`
  with no seed (applies the checked-out migration files); (4) then `npm run fixtures:reset` recreates canonical fixtures.
  Edge Functions, function secrets and hosted Auth settings are untouched (deploy-dev / hosted-checks own them).
- **D4 Guard (script `scripts/dev-reset.ts`):** refuses unless `APP_ENV=development`, `DEV_SUPABASE_PROJECT_REF` is set,
  and both `SUPABASE_URL` and the DB URL contain that ref; refuses if any Auth user has a phone outside the fixture blocks
  (+91 90000 00001–00099, 10000–99999) — real data on dev is a stop, not a wipe. Never logs secrets or URLs.
- **D5 Growth check (fails the run):** after reset + fixtures, `scripts/dev-size-check.ts` asserts exact baseline counts
  (Auth users = canonical fixtures; tenants, audit_event, issue/reading/assignment/target rows = what fixtures-reset
  creates; Storage objects = 0). The baseline lives in the script, computed from `fixtures-reset.ts`'s fixture lists.
  A non-baseline count = red run, so growth can't come back silently.
- **D6 One writer at a time on dev:** `deploy-dev.yml` and `regression.yml` (dev) share concurrency group `dev-db`
  (cancel-in-progress false). Cost: a deploy triggered by a merge during a nightly queues behind it (≈ 1 h worst case). GitHub keeps only
  ONE pending run per group (a newer pending run replaces an older one), so a deploy can be lost: the regression's last job `redeploy` (S1) dispatches
  deploy-dev on main when the newest successful deploy-dev run is not main's head.
- **D7 Hosted proofs on feature branches** use the same workflow, so they reset dev to the **branch's** migrations; the
  next nightly resets it back to main's. This also ends the "nightly drift red while an unmerged migration sits on dev"
  problem (drift may still be red on the first nightly after an unmerged proof — documented, expected).
- **S8 (Opus review) deploy-dev after an unmerged proof:** before `db push`, deploy-dev compares `supabase migration list`; if dev holds a version main
  lacks it runs `npm run dev:reset` (fixtures + demo included) first, so a merge never fails on remote-only migrations.
- **D9 Demo tenant (owner option a, 2026-11-18).** After every reset, `scripts/dev-demo-seed` rebuilds one tenant
  **"Demo Plastics (fixture)"** for the owner's manual testing: 1 site (Asia/Kolkata), 2 lines, ~10 machines (mix of pieces/shots,
  one with a counter maximum, one with cavities), ~4 products with targets, Day + Night (overnight) shifts, 1 UA + 2 supervisors
  on **unused canonical fixture phones** (+91 90000 000xx, listed in the plan), invented names, password = the fixture password.
  History dated **relative to the reset date** (last 7 plant days): readings incl. some Late, Early, Rollover, Needs review and
  UA-entered; summaries; 5–8 issues incl. one open Critical "machine stopped", one awaiting verification, some closed; no photos.
  Rules: dev only (runs only inside `dev-reset.ts` after its guard; also runnable on the local stack for tests); never in seed.sql
  for CI, never staging/prod. Past-dated rows can't go through the RPCs (they use `now()`), so the seed inserts as the DB owner
  **through the same internal helpers where they exist** (e.g. `app._rd_compute_summary`) and must satisfy every CHECK, FK and
  append-only trigger without disabling them. If a rule blocks past-dated inserts (e.g. no-backdating of targets), stop and log
  `Blocked - needs Opus` — do not disable triggers or add a bypass to the schema. Audit rows: the seed writes none, except
  through helpers that already write them. The size check (D5) includes the demo tenant's exact counts.
  Login details for the owner go in `sdlc/releases/README.md` (phones only; never the password).
- **D10 The spike is a permanent CI test (Opus, 2026-11-18; the builder sandbox cannot pull Supabase images).** Job `reset-roundtrip` in
  `ci.yml` (own ephemeral stack incl. Storage, no secrets): fixtures -> demo seed -> throwaway data (Auth user in the throwaway phone range, a
  Storage object in `attachments`, an issue, a reading) -> size check must FAIL -> `dev-reset.ts` in LOCAL mode (APP_ENV=local, local URLs only;
  the guard allows local or the exact dev ref, nothing else) -> size check exact baseline (0 throwaway Auth users, 0 Storage objects) -> repeat
  once more and diff the printed counts (AC-2 in CI). This proves `db reset` behaviour, prompts (`--yes`) and bucket recreation. If the CLI does
  not clear something, the script's explicit Auth/Storage clearing (D3) covers it and CI proves that too. pgTAP-style and demo-seed checks are
  written here and run by PR CI only (not runnable in the builder sandbox: no local DB results are claimed).
- **D8 Out of scope (flag only):** policy item 2(b) seeded-volume speed check is not implemented today; recorded as known
  debt for the R1 gate, not built here.

## Steps
- [x] 1. **Spike (D10: proven by the CI job `reset-roundtrip`, no local stack in the builder sandbox):** confirm CLI 3.1.0 `supabase db reset --db-url <local>` behaviour:
  are `auth.users` and `storage.objects` kept or cleared; is the `attachments` bucket row recreated by the migration;
  exit codes; any prompt. Record findings in the session log; if `--db-url` reset is unsupported → `Blocked - needs Opus`.
- [x] 2. Tests first: Jest for `dev-reset.ts` guard (wrong ref, missing env, non-fixture phone → refuse; no secret in output)
  and `dev-size-check.ts` (baseline from fixture lists; mismatch → non-zero with a readable diff).
- [x] 3. Implement `scripts/dev-reset.ts` (D3, D4) and `scripts/dev-size-check.ts` (D5); `npm run dev:reset`, `dev:size-check`.
- [x] 3a. Demo tenant (D9): tests first — a pgTAP or Jest test that loads the demo seed on the local stack and asserts it is
  internally consistent (every summary matches `_rd_compute_summary`, issues pass `issue_can_verify` rules, UA sees it, other
  tenants and SAs don't), then the seed; `dev-reset.ts` runs it after `fixtures:reset`.
- [x] 4. Workflows: `reset` job per D2 (TAP output + artifact like drift), size check after fixtures in the reset job,
  `web`/`android` need `reset`; concurrency group `dev-db` in both workflows (D6).
- [x] 5. Docs (architecture lock): policy item 2 (nightly reset order, size check, D7), remove the five "accumulates on dev"
  known-debt items (03 console tenants, 04 target history, 05/07 append-only, 06 readings), add D8 debt, decision-log row.
- [x] 6. Proof on dev (run by Opus, see log): dispatch `regression` (target dev) on this branch **twice**; both green on the first attempt;
  size-check counts identical in both; record run ids. Any web failure → diagnose, no blind re-run.
- [ ] 7. Review (Opus) → PR with AC table → owner merge.

## Files that change (N7)
- Workflows: `.github/workflows/ci.yml` (job `reset-roundtrip`), `regression.yml` (jobs `reset`, `redeploy`, gating of `web`/`android`/`hosted-checks`, `notify`), `deploy-dev.yml` (group `dev-db`, rebuild when dev holds remote-only migrations).
- Scripts (new): `scripts/dev-guard.ts`, `dev-reset.ts`, `dev-size-check.ts`, `dev-demo-spec.ts`, `dev-demo-seed.ts`, `ci-reset-pollute.ts`, `demo-checks.sql`, `dev-bounds.sql`; (edited, additive) `scripts/drift-check.sh` (`--remote-only`), `package.json` (`dev:reset`, `dev:size-check`, `dev:demo-seed`).
- Tests (new only): `scripts/__tests__/dev-reset.test.ts`, `dev-size-check.test.ts`, `dev-demo-spec.test.ts`, `drift-remote-only.test.ts`. No test from 01-07 or 006 is touched.
- Docs: `sdlc/product/architecture.md` (policy item 2, environments, known debt, decision log), `sdlc/releases/README.md` (demo logins), this plan. Not touched: `roadmap.md`, `supabase/migrations`, `supabase/seed.sql`, app code.

## Acceptance
- AC-1 After any dev run, the next run starts from migrations + canonical fixtures only (size check green with baseline counts).
- AC-2 Two consecutive dev runs report identical counts (no growth).
- AC-3 The reset refuses any non-dev project and any non-fixture phone on dev (unit tests + guard in CI).
- AC-4 Drift still proves deploy-dev's incremental apply (drift runs before reset).
- AC-6 After every dev run the owner can sign in to the demo tenant and see 7 recent plant days of readings and issues; its counts are identical across runs.
- AC-5 Full suite green, no 01–07/006 test edited.

## Session log

### 2026-11-18 (Opus)
- Plan drafted; owner approved approach and chose option (a) demo tenant (D9). Next: step 1 spike (Sonnet).

### 2026-11-18 (Sonnet) - step 1 blocked
- Blocked - needs Opus: the step 1 spike cannot run in this sandbox. `npx supabase start` (CLI 3.1.0) fails with ImagePrepullError:
  the egress proxy answers 403 to every container registry (ghcr.io, public.ecr.aws, registry-1.docker.io), so no Supabase image
  (postgres, gotrue, storage-api, ...) can be pulled. dockerd itself starts (I launched it manually; it was not running), `npm ci`
  works, but there is no local stack: no spike, no `npm run test:db`, and no local run of the step 3a seed test.
  Per the proxy README a 403 is a policy denial; I did not try to route around it. No hosted calls were made. No code changed; steps 2-5 not started.
- Options for Opus / owner:
  (a) Allow ghcr.io, public.ecr.aws and registry-1.docker.io for this session, then I run the spike and continue as planned.
  (b) Run the spike where Docker works (owner's Mac, per CLAUDE.md "needs Docker") and paste findings (does `supabase db reset --db-url`
      clear `auth.users` and `storage.objects`, is the `attachments` bucket row recreated, any prompt, exit code); I then do steps 2-5.
  (c) Proceed on D3 as written (Auth users and Storage objects cleared via the admin APIs, DB via `db reset --db-url --no-seed`) with the
      spike unanswered, and let PR CI (ephemeral stack) be the first place the demo-seed test and pgTAP run. Risk: a wrong
      assumption about `db reset --db-url` is found in CI or at step 6 rather than now.
  Recommendation: (a) or (b); (c) only if the owner accepts slower feedback.

### 2026-11-18 (Sonnet) - steps 1-5 done, D10 applied
- Step 1 (spike) became CI job `reset-roundtrip` (D10). Findings from PR CI run 44281328292 (attempt 2 all green; head 5488573):
  - `supabase db reset --db-url` is deprecated in CLI 3.1.0 ("use --remote=<db-url>"); the script uses `--remote=<url> --no-seed --yes`. `--yes` answers the prompts; stdin is closed, nothing hangs.
  - Both CLI paths were exercised. Host 127.0.0.1 (the stack's own DB port) takes the CLI's LOCAL path ("Resetting local database... Recreating database... Restarting containers"); host 0.0.0.0 on the same port takes the REMOTE path ("Resetting remote database..."), the one hosted dev uses.
  - After either path: 0 Auth users and 0 Storage objects were left (our explicit clearing found nothing to remove after the reset; it removed the 1 object before). `auth.users` and `storage.objects` are cleared by the reset itself on the local stack. The bucket row `attachments` exists afterwards (size check asserts it).
  - NOT proven by CI: hosted dev behind the session pooler (permissions of the pooler role on the system schemas). Step 6 is the first hosted proof; the explicit Auth/Storage clearing in `dev-reset.ts` covers a CLI that leaves them.
  - D3 order deviation: Storage is cleared before the reset and Auth users are deleted after it (deleting them first could hit FKs from history tables to auth.users); both are also re-checked after the reset.
- Tests first: `scripts/__tests__/dev-reset.test.ts`, `dev-size-check.test.ts`, `dev-demo-spec.test.ts` (60 tests; guard cases, no secret in any message, baseline derived from fixture lists, demo spec invariants). No 01-07/006 test edited.
- Implemented: `scripts/dev-guard.ts` (guard, identity check, redaction, Storage helpers), `dev-reset.ts`, `dev-size-check.ts`, `dev-demo-spec.ts` + `dev-demo-seed.ts`, `ci-reset-pollute.ts`, `demo-checks.sql`; npm scripts `dev:reset`, `dev:size-check`, `dev:demo-seed`. Guard also allows 0.0.0.0 as the local DB host (CI remote-path proof).
- Demo tenant (3a): "Demo Plastics (fixture)", site "Demo Plant", 2 lines, 10 machines (6 pieces, 4 shots; DM-03 max 999999 and DM-10 max 99999 roll over; cavities on DM-07/08/10), 4 products, Day 06-18 + Night 18-06, 20 plan versions, UA `+91 90000 00010`, supervisors `+91 90000 00011` (S1: 1-5 day, 6-10 night) and `+91 90000 00012` (S2); phones were unused anywhere in the repo. 94 machine-occurrences (Day D-7..D-1 x 10, Night D-7..D-2 x 4 machines) with Late/Early/Rollover/Needs review/Over-reported/UA-entered cases; 7 issues (open Critical stopped DM-04, resolved High awaiting verification DM-02, open High, in-progress Medium, 3 closed incl. one High closed by verification). No photos, no audit rows. Inserted by the service role (no trigger disabled, no schema change; no past-dating rule blocked it).
- Summaries are computed in TS (`summarise`); `demo-checks.sql` proves in CI that all 94 equal `app._rd_compute_summary` (2 rollovers), that the other supervisor can verify the resolved High and its resolver cannot, and RLS: demo UA sees the data, another tenant's UA and a Super Admin see none. The plan said "through the same internal helpers where they exist": from the service-role client the `app` schema is unreachable, so equality with the helper is asserted instead.
- Size-check baseline (CI, identical in rounds 1 and 2): tenant 5, site 4, line 4, machine 15, product 9, target_version 14, cavity_version 4, shift 6, assignment_version 32, assignment_cover 0, target_override_version 0, production_reading 192, production_summary 96, machine_issue 11, issue_action 19, issue_ownership_history 11, issue_category 35, attachment 0, audit_event 0, membership 11, platform_admin 2, auth_users 14, storage_objects 0.
- Workflows (4): `reset` job in regression.yml after `drift`, before `web`/`android` (web needs reset; android skips when web was skipped; hosted-checks unchanged), size check + `reset.tap` + artifact; the old per-job fixtures step in `web` removed (the reset job creates them), the Android re-reset stays (U4's password). `deploy-dev.yml` and the dev regression share concurrency group `dev-db`; non-dev targets keep `regression-<target>`. No temporary triggers.
- Docs (5): architecture policy item 2, environments line, removed the four "accumulates on dev" debt items (03, 04, 05/07, 06), added D8 and "dev rewritten every run" debt, three decision-log rows; demo logins (phones only) in `sdlc/releases/README.md`.
- Local results: `npm run lint` 0 problems, `npm run typecheck` clean, `npm test` 66 suites / 874 tests + 60 new green. `npm run test:db` and the demo seed test could NOT run locally (no Supabase images in the sandbox); they ran in PR CI only (db job green, reset-roundtrip green).
- PR CI: draft PR #22. Run 44281328292 head 5488573: attempt 1 failed in e2e-web on one spec (`shifts.spec.ts` 5 s timeout); the earlier run 44280359241 failed in e2e-web on `readings.spec.ts` (5 s timeout, Today board). Different specs each time, no app/seed/test change in this branch; attempt 2 of the same run: all jobs green. Read as the known 5 s UI-timeout flakiness (not caused by this branch), flagged for Opus.
- Not done (by instruction): step 6 (hosted proof) and step 7.
