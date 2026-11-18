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
  (cancel-in-progress false). Cost: a merge during a nightly waits for it (≈ 1 h worst case).
- **D7 Hosted proofs on feature branches** use the same workflow, so they reset dev to the **branch's** migrations; the
  next nightly resets it back to main's. This also ends the "nightly drift red while an unmerged migration sits on dev"
  problem (drift may still be red on the first nightly after an unmerged proof — documented, expected).
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
- [ ] 1. **Spike (D10: proven by the CI job `reset-roundtrip`, no local stack in the builder sandbox):** confirm CLI 3.1.0 `supabase db reset --db-url <local>` behaviour:
  are `auth.users` and `storage.objects` kept or cleared; is the `attachments` bucket row recreated by the migration;
  exit codes; any prompt. Record findings in the session log; if `--db-url` reset is unsupported → `Blocked - needs Opus`.
- [ ] 2. Tests first: Jest for `dev-reset.ts` guard (wrong ref, missing env, non-fixture phone → refuse; no secret in output)
  and `dev-size-check.ts` (baseline from fixture lists; mismatch → non-zero with a readable diff).
- [ ] 3. Implement `scripts/dev-reset.ts` (D3, D4) and `scripts/dev-size-check.ts` (D5); `npm run dev:reset`, `dev:size-check`.
- [ ] 3a. Demo tenant (D9): tests first — a pgTAP or Jest test that loads the demo seed on the local stack and asserts it is
  internally consistent (every summary matches `_rd_compute_summary`, issues pass `issue_can_verify` rules, UA sees it, other
  tenants and SAs don't), then the seed; `dev-reset.ts` runs it after `fixtures:reset`.
- [ ] 4. Workflows: `reset` job per D2 (TAP output + artifact like drift), size check after fixtures in the reset job,
  `web`/`android` need `reset`; concurrency group `dev-db` in both workflows (D6).
- [ ] 5. Docs (architecture lock): policy item 2 (nightly reset order, size check, D7), remove the five "accumulates on dev"
  known-debt items (03 console tenants, 04 target history, 05/07 append-only, 06 readings), add D8 debt, decision-log row.
- [ ] 6. Proof on dev: dispatch `regression` (target dev) on this branch **twice**; both green on the first attempt;
  size-check counts identical in both; record run ids. Any web failure → diagnose, no blind re-run.
- [ ] 7. Review (Opus) → PR with AC table → owner merge.

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
