# Plan: chore/dev-reset — hosted dev is rebuilt clean before every run
Status: draft · Owner approval of approach: 2026-11-18 ("Yes I approve") · Author: Opus · Executor: Sonnet
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
- **D8 Out of scope (flag only):** policy item 2(b) seeded-volume speed check is not implemented today; recorded as known
  debt for the R1 gate, not built here.

## Steps
- [ ] 1. **Spike (local stack, no hosted calls):** confirm CLI 3.1.0 `supabase db reset --db-url <local>` behaviour:
  are `auth.users` and `storage.objects` kept or cleared; is the `attachments` bucket row recreated by the migration;
  exit codes; any prompt. Record findings in the session log; if `--db-url` reset is unsupported → `Blocked - needs Opus`.
- [ ] 2. Tests first: Jest for `dev-reset.ts` guard (wrong ref, missing env, non-fixture phone → refuse; no secret in output)
  and `dev-size-check.ts` (baseline from fixture lists; mismatch → non-zero with a readable diff).
- [ ] 3. Implement `scripts/dev-reset.ts` (D3, D4) and `scripts/dev-size-check.ts` (D5); `npm run dev:reset`, `dev:size-check`.
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
- AC-5 Full suite green, no 01–07/006 test edited.

## Session log
