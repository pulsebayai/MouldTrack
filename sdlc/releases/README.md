# Releases — procedure and record template

Every release Rn follows architecture.md §Release & regression policy. Run on `main`, after every feature in the release is shipped.

## Procedure (Stage 5b)
1. Scope: list the features; confirm `main` CI is green. Note the commit SHA and the CI run URL (a **code** commit's full run, never a docs-only skipped run).
2. Deploy `main` to **staging** (migrations, Edge Functions `user-admin`, `account`, `platform`, `platform-setup`, secret `ALLOWED_ORIGINS`, web alias `staging`, EAS Update `preview`) and run `node scripts/auth-config.mjs --apply --ref staging` (hosted Auth settings; the nightly check only verifies them). Run `regression.yml` with `target=staging`. It must pass. The deploy must end with the **setup-token check**: `supabase secrets list --project-ref <ref> -o json | jq -e '[.[] | select(.name=="PLATFORM_SETUP_TOKEN")] | length == 0'` succeeds (no `PLATFORM_SETUP_TOKEN` unless the first-Super-Admin runbook below is in progress; if present and not in progress, unset it and investigate who set it). Never put the token in `config.toml` (the deploy CLI pushes `[edge_runtime.secrets]` to the hosted project; D11).
3. Manual checklist on staging (below), including one **real Android phone**.
4. Write `sdlc/releases/<Rn>.md` from the template; copy the regression summary and result files into `sdlc/releases/<Rn>/evidence/`. Commit via PR.
5. **Owner sign-off in chat (Sidambara Raja).** Only then promote to prod (the production-gate hook blocks it until the owner runs/approves it).
6. After the prod deploy run the same **setup-token check** against prod (read-only), then run `regression.yml` with `target=prod` (**smoke only**, read-only) and append its summary. Pass → mark the release `released` in roadmap.md. Fail → roll back, record the incident, add a roadmap item.

## R1 pre-release items (open; each must be done or waived in `R1.md` before step 2)
- [ ] **Separate Supabase token for prod.** Prod lives in the **Pulsebay Ai** Pro org; create a dedicated token in that account (secret `PROD_SUPABASE_ACCESS_TOKEN`) (secret `PROD_SUPABASE_ACCESS_TOKEN` or an environment-scoped secret). Never reuse the dev/staging token (`SUPABASE_ACCESS_TOKEN`, MouldTrack org, renewed 2026-11-24 with no expiry: delete and replace it if a leak is suspected).
- [ ] **Three environments (owner, 2026-11-24):** dev + staging Free in the MouldTrack org, prod Pro in the Pulsebay Ai org (ap-south-1). Set secrets `STAGING_SUPABASE_PROJECT_REF` and `PROD_SUPABASE_PROJECT_REF` (the dev-reset guard refuses a dev URL pointing at either).
- [ ] **Staging fixture tenants vs handover enforcement (08, OPEN).** Console-created staging tenants are enforced, so 06's e2e openings hit `handover_pending`; Opus decides the fix before the staging regression.
- [ ] **Deep links on EAS Hosting.** Fixed in code (`scripts/web-deep-links.ts`, curl smoke in every web deploy); tick this when a staging deploy shows `/users` ... `/console` -> 200.
- [ ] **Seeded-volume speed check** (policy 2(b)): build or waive.
- [ ] **Prod backups:** confirm Pro daily backups are on; one recorded restore drill (daily backup → throwaway project → read-only smoke); a Storage export routine for photos (not covered by database backups).
- [ ] **Prod APK (no Play Store, owner 2026-11-24):** `eas.json` production profile builds an APK; signing keystore downloaded (`eas credentials`) and stored in the owner's password manager; install guide for supervisors ("install unknown apps", Play Protect warning); the download link is shared only with the pilot plant; record which app version each phone runs (Android build number) so old APKs can be chased.
- [ ] **Token health:** a red nightly `hosted-checks` with `HTTP 401` / "Invalid access token" means the Supabase token expired or was revoked; renew it the same day.

## Prod deploy: what the owner creates (r1-release-prep D5)
Nothing below is created by CI. Names are exact.
1. **Prod Supabase project** in the Pulsebay Ai org (Pro, ap-south-1). Prod token from that account.
2. **GitHub repo secrets:** `PROD_SUPABASE_PROJECT_REF` (20 chars), `PROD_SUPABASE_URL` (`https://<ref>.supabase.co`), `PROD_SUPABASE_ANON_KEY`, `PROD_SUPABASE_DB_URL` (session pooler URL, `postgres.<ref>` user), `PROD_SUPABASE_ACCESS_TOKEN` (never the dev/staging token). Already needed and unchanged: `EXPO_TOKEN`, `DEV_SUPABASE_PROJECT_REF`, `STAGING_SUPABASE_PROJECT_REF`, `STAGING_SUPABASE_URL`, `STAGING_SUPABASE_ANON_KEY`, `SENTRY_DSN`.
3. **GitHub environment `production`** (Settings > Environments > New environment > name `production`): tick **Required reviewers** and add the owner; set **Deployment branches** to `main` only. `deploy-prod.yml` and the `production` job of `build-android-eas.yml` wait for that approval. Do not put secrets in the environment: repo secrets are used.
4. **Optional repo variable** `PROD_WEB_ORIGIN` (Settings > Variables), e.g. `https://mouldtrack.expo.app`. Empty = the first `deploy-prod` reads the origin from the EAS deploy output (unverified until the first run; if it fails, set the variable and rerun). Pass the same URL as `base_url` to `regression.yml target=prod` if it differs from `https://mouldtrack.expo.app`.
5. **First-Super-Admin runbook** (below) after the first successful `deploy-prod`; rerun `deploy-prod` with `first_sa_in_progress` ticked while the token exists.
6. Then dispatch `regression.yml target=prod` (smoke only).

## Installing the staging APK on a phone
1. Owner: Actions > build-android-eas > Run workflow > profile `preview` (main). First time only, EAS may need an Android keystore: if the job fails asking for credentials, run `eas credentials -p android` once locally (profile preview) and rerun.
2. The "Build page" (expo.dev) needs an Expo login, so never send it to a phone. On a signed-in laptop open the build page, copy the **APK download link** (`https://expo.dev/artifacts/eas/....apk`, no login) or download the `.apk`, and send the link or file to the phone (e.g. WhatsApp). Install it ("install unknown apps" allowed for the app that opens it). It talks to **staging** (fixture data only). Company-managed (MDM) phones may block sideloading.
3. `profile: production` builds the prod APK (approval needed); same install steps, pilot plant only.

## Runbook: first Super Admin on an environment (prod at R1; staging if it has no SA)
Run from the **owner's own terminal**, never from CI (the repo and its logs are public). Needs the Supabase CLI logged in (`supabase login`). In zsh, `setopt HIST_IGNORE_SPACE` and start the sensitive lines with a space so they stay out of shell history.
1. ` TOKEN=$(openssl rand -hex 32)` (≥ 32 characters; the endpoint refuses short tokens and the public local literal).
2. ` supabase secrets set PLATFORM_SETUP_TOKEN="$TOKEN" --project-ref <ref>`
3. ` read -r NAME; read -r PHONE` (type them; nothing lands in history), then
   ` printf 'x-setup-token: %s\n' "$TOKEN" | curl -sS -X POST "https://<ref>.supabase.co/functions/v1/platform-setup" -H @- -H 'content-type: application/json' -d "{\"full_name\":\"$NAME\",\"phone\":\"$PHONE\"}"`
   → note `user_id` and the temporary password (shown once). Don't redirect the output to a file.
4. Immediately ` supabase secrets unset PLATFORM_SETUP_TOKEN --project-ref <ref>; unset TOKEN NAME PHONE`.
5. **Sign in on the web app right away and change the password** (the temporary one expires in 24 h). If it was lost or expired before the first change, repeat steps 1–4: setup re-issues a temporary password for a setup-created SA that never completed a change (audited). Once the change is done, setup is closed for good. Clear the terminal scrollback.
6. In the release record, note the `user_id` and that the Console's Platform audit shows "Super Admin created · By System setup". Then create the pilot tenant and its first Unit Admin **in the Console** (no SQL).

R1 extra blockers (prod on Supabase Free): nightly **encrypted** DB + Storage backup running, and one **restore drill** recorded below.

## Demo tenant on dev (manual testing)
After every dev run dev holds the tenant "Demo Plastics (fixture)" (invented data, 10 machines, Day and Night shifts, seven plant days of readings and issues). Sign in on the dev web app with phone number + the fixture password (`E2E_FIXTURE_PASSWORD`, held only in GitHub secrets and with the owner; never written here):
- Unit Admin: `+91 90000 00010` (Demo Admin)
- Supervisor: `+91 90000 00018` (Demo Supervisor One: machines 1-5 by day, 6-10 by night)
- Supervisor: `+91 90000 00019` (Demo Supervisor Two: machines 6-10 by day, 1-5 by night)
The tenant is deleted and recreated on every dev run; do not keep anything on it. It never exists on staging or prod.

## Record template — copy to `sdlc/releases/<Rn>.md`
```markdown
# Release Rn — <name>
Date: · Commit: <sha> · Features: · Approved by: Sidambara Raja, <date>
## Automated regression
| Suite | Env | Run | Passed | Failed | Skipped |
|---|---|---|---|---|---|
## Acceptance criteria covered (new in this release)
| Feature | AC | Test | Result |
|---|---|---|---|
## Manual checklist (staging)
- [ ] Sign in/out (web + Android phone)
- [ ] Key screens vs design / prototype
- [ ] One real end-to-end path
- [ ] Photo on a real Android phone: report an issue with a camera photo; view it as the Unit Admin (07 D8)
- [ ] No console/CSP errors (browser devtools)
- [ ] Mobile width check (web) and one mid-range Android device (cold start ≤ 3 s)
## Backups (R1 and while prod is on Free)
- [ ] Encrypted nightly backup ran (run URL) · [ ] Restore drill done (date, restored row counts)
## Prod smoke (after deploy)
| Suite | Run | Passed | Failed |
|---|---|---|---|
## Known issues / waivers
```
