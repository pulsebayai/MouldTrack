# Plan: chore/staging-setup — staging becomes a real release rehearsal
Status: approved 2026-11-24 (owner) · Author: Opus · Executor: Sonnet · Starts building after PR #27 (screen-speed) merges
Holds: architecture lock (docs). No migrations.

## Why
R1 gate = full suite on staging + manual checklist (real Android phone) + owner sign-off, then prod (Pro, Pulsebay Ai org).
Today staging has a project and a keep-alive only: no deploy workflow, no test data, no secrets for writes.

## Decisions (owner approves at the gate)
- **D1 Staging is never wiped automatically.** Unlike dev, staging keeps its database between releases, so each release
  proves that migrations apply to a long-lived database, the way prod will. (Append-only test data grows only per release
  run — a few runs a release; a manual rebuild stays possible and is documented.)
- **D2 Staging test data = the same fixtures as dev, inserted directly** by `fixtures:reset` extended to accept
  `APP_ENV=staging` **only** with the exact `STAGING_SUPABASE_PROJECT_REF` (never prod; `dev-reset` and the demo seed stay dev-only).
  Fixture tenants A/B/S/U are inserted directly, so they are **not handover-gated** (same as dev) and 06's tests behave the same;
  org H is enforced on purpose. **This closes the open 08 item.** The Console path (registration ⇒ enforced) is still proven on
  staging by `console.spec` and by one manual checklist step (register a tenant, see handover required).
- **D3 Deploy workflow `deploy-staging.yml`**, manual dispatch only, from `main` (or a release tag): migrations (`db push` to the
  staging DB), Edge Functions, `ALLOWED_ORIGINS` = staging web origin, `auth-config.mjs --apply --ref staging`, web on EAS Hosting
  alias `staging`, then the setup-token check. Refuses unless the target ref equals `STAGING_SUPABASE_PROJECT_REF` and differs
  from the dev and prod refs. Shares concurrency group `staging-db` with the staging regression.
- **D4 First Super Admin on staging via the runbook** (`platform-setup`, canonical phone `+91 90000 00097`, invented name) —
  the rehearsal of prod's first step. Fixture SAs `…00098/00099` are created afterwards by `fixtures:reset`.
- **D5 Regression on staging** = everything dev runs except `drift`'s dev-only parts and the reset: fixtures reset → web (incl. api)
  → Android (staging build) → hosted checks extended to staging (Auth config, functions deployed, CORS for the staging origin,
  no orphan Auth users, platform-setup refuses, no setup token left, bucket, handover check 10).
- **D6 Prod guard everywhere:** every script that writes (fixtures, deploy) refuses the prod ref (`PROD_SUPABASE_PROJECT_REF`).

## Owner tasks (before step 2)
Secrets: `STAGING_SUPABASE_PROJECT_REF`, `STAGING_SUPABASE_DB_URL` (session pooler), `STAGING_SUPABASE_SERVICE_ROLE_KEY`,
`PROD_SUPABASE_PROJECT_REF` (once prod exists). `STAGING_SUPABASE_URL`/`_ANON_KEY` already exist (keep-alive).

## Steps (tests first)
- [x] 1. Guards: `fixtures-reset` staging mode + prod refusal; deploy-target guard script. Jest for every refusal.
- [x] 2. `deploy-staging.yml` (D3) + its setup-token check; dry-run-safe parts unit-tested.
- [x] 3. `regression.yml target=staging` (D5): fixtures step, hosted checks parameterised by target, Android staging build.
- [ ] 4. Opus runs: deploy-staging → runbook first SA (D4, owner present for the one-time token) → staging regression. Record runs.
- [ ] 5. Docs: architecture (staging rules D1–D6), releases README (procedure step 2 uses `deploy-staging.yml`), known debt.

## Acceptance
- AC-1 One dispatch deploys main to staging end to end; it refuses any other project.
- AC-2 Staging's first SA exists via the runbook; no setup token remains afterwards.
- AC-3 Full regression on staging green (web incl. api, Android, hosted checks) on the first attempt.
- AC-4 Nothing in this chore can write to dev's reset path or to prod (tests).

## Session log
### 2026-11-24 (Opus) — plan drafted for owner approval.
- Owner created the staging project (MouldTrack org, ap-south-1) and set the five STAGING_* secrets; plan approved.

### 2026-11-24 (Sonnet) - steps 1-3 built (no hosted calls)
- Step 1: `assertSafeTarget` (scripts/fixtures-reset.ts) now allows local, dev and staging (`APP_ENV=staging` only with the exact `STAGING_SUPABASE_PROJECT_REF` and a URL equal to that project);
  the prod ref is refused in every mode (an empty `PROD_SUPABASE_PROJECT_REF` = no prod yet, not an error); dev == staging ref refused. `dev-reset`/demo seed untouched (already dev/local only; tests added).
  New `scripts/deploy-target-guard.ts` (main only; staging ref exact; dev ref required and different; prod ref different when set; API and DB URLs belong to staging). Jest: `staging-guards.test.ts`, `staging-workflow.test.ts`, `staging-regression.test.ts`.
  Behaviour change: assertSafeTarget now requires APP_ENV=development for the dev URL (previously any allowed APP_ENV); local URL still allowed for local/development.
- Step 2: `.github/workflows/deploy-staging.yml` (dispatch only, main, group `staging-db`, repo secrets, no environment). Input `first_sa_in_progress` lets the setup-token check pass while the runbook token exists; otherwise a stray token FAILS the deploy (never auto-unset, unlike dev).
- Step 3: `regression.yml`: staging group `staging-db`; new `fixtures` job (staging only); web API env, hosted-checks and the Android U4 re-reset work for staging; `hosted-checks.sh` takes TARGET dev|staging and runs all ten checks per target (checks the URL is the target's project).
- Not run here: actionlint (unavailable; YAML parsed with PyYAML), local Supabase, hosted. Step 4 (Opus) pending.
