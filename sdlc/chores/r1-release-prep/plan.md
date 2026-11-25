# Plan: chore/r1-release-prep — staging APK, deep links, prod deploy workflow
Status: approved 2026-11-25 (owner: "Yes please start") · Author: Opus · Executor: Sonnet · Holds: architecture lock (docs)
No migrations.

## Decisions
- **D1 Staging APK for a real phone = EAS Build `preview` profile** (arm64, EAS-managed keystore, internal-distribution link/QR).
  The CI APK is x86_64 + debug-signed (emulator only) and must never be given to a phone. Workflow `build-android-eas.yml`
  (dispatch, input `profile: preview|production`, main only) runs `eas build -p android --profile <p> --non-interactive`.
  Supabase URL / anon key reach the EAS build as **EAS environment variables** (`preview` = staging values, `production` = prod
  values) set from GitHub secrets by the workflow (`eas env:create … --force`, plaintext visibility: both values are public by
  design) — never committed. Output: the build page / install URL in the job summary. If EAS needs interactive credential setup
  the first time, log `Blocked - needs Opus` with the exact message (owner may have to run one `eas credentials` command).
- **D2 Production profile builds an APK** (`buildType: apk`, owner decision 2026-11-24); keep `autoIncrement`.
- **D3 Deep links:** EAS Hosting returns 404 for `/users` while the export has `users/index.html`. Fix after `expo export` in every
  web deploy (dev, staging, prod): for each `<dir>/index.html` (not the root) also write `<dir>.html`, unless it exists. Unit-test the
  helper; deploy-dev/staging smoke `curl` asserts 200 for `/users`, `/plant`, `/issues`, `/readings`, `/console`.
- **D4 `deploy-prod.yml`:** dispatch only, from main, GitHub **environment `production` with the owner as required reviewer**
  (the production gate). Guard: target ref = `PROD_SUPABASE_PROJECT_REF`, differs from dev and staging refs; uses
  `PROD_SUPABASE_ACCESS_TOKEN`, `PROD_SUPABASE_DB_URL`, `PROD_SUPABASE_URL`, `PROD_SUPABASE_ANON_KEY`. Steps mirror
  deploy-staging (migrations, functions, ALLOWED_ORIGINS = prod web origin, auth-config, web `eas deploy --prod`, setup-token check
  with `first_sa_in_progress`). Never runs fixtures, never runs data-writing tests. Then `regression.yml target=prod` (smoke only)
  must exist and stay read-only.
- **D5 Owner prerequisites recorded** in `sdlc/releases/README.md` (prod project in Pulsebay Ai, secrets list, environment reviewer).

## Steps (tests first)
- [x] 1. D3 helper + tests; wire into deploy-dev and deploy-staging (+ smoke curls).
- [ ] 2. D1/D2: eas.json production apk; `build-android-eas.yml`.
- [ ] 3. D4: guard (extend deploy-target-guard for prod, tests), `deploy-prod.yml`.
- [ ] 4. Docs: architecture (deploy paths), releases README (owner prerequisites, how to install the staging APK).
- [ ] 5. Opus: merge → deploy-staging (deep links proven) → EAS preview build → APK link to the owner.

## Session log
### 2026-11-25 (Opus) — plan written.
