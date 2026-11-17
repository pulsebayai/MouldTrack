# Releases — procedure and record template

Every release Rn follows architecture.md §Release & regression policy. Run on `main`, after every feature in the release is shipped.

## Procedure (Stage 5b)
1. Scope: list the features; confirm `main` CI is green. Note the commit SHA and the CI run URL (a **code** commit's full run, never a docs-only skipped run).
2. Deploy `main` to **staging** (migrations, Edge Functions `user-admin`, `account`, `platform`, `platform-setup`, secret `ALLOWED_ORIGINS`, web alias `staging`, EAS Update `preview`) and run `node scripts/auth-config.mjs --apply --ref staging` (hosted Auth settings; the nightly check only verifies them). Run `regression.yml` with `target=staging`. It must pass.
3. Manual checklist on staging (below), including one **real Android phone**.
4. Write `sdlc/releases/<Rn>.md` from the template; copy the regression summary and result files into `sdlc/releases/<Rn>/evidence/`. Commit via PR.
5. **Owner sign-off in chat (Sidambara Raja).** Only then promote to prod (the production-gate hook blocks it until the owner runs/approves it).
6. After the prod deploy run `regression.yml` with `target=prod` (**smoke only**, read-only) and append its summary. Pass → mark the release `released` in roadmap.md. Fail → roll back, record the incident, add a roadmap item.

## Runbook: first Super Admin on an environment (prod at R1; staging if it has no fixture SA)
Run from the **owner's own terminal**, never from CI (the repo and its logs are public).
1. `TOKEN=$(openssl rand -hex 32)` (≥ 32 hex chars; the endpoint refuses short tokens and the local literal).
2. `supabase secrets set PLATFORM_SETUP_TOKEN="$TOKEN" --project-ref <ref>`
3. `curl -sS -X POST "https://<ref>.supabase.co/functions/v1/platform-setup" -H "x-setup-token: $TOKEN" -H 'content-type: application/json' -d '{"full_name":"<name>","phone":"<10-digit mobile>"}'` → note the temporary password (shown once), sign in on the web app, change it.
4. `supabase secrets unset PLATFORM_SETUP_TOKEN --project-ref <ref>`; `unset TOKEN`. A second call must now return 403.
5. Record the `platform_admin.created` audit event id in the release record. Then create the pilot tenant and its first Unit Admin **in the Console** (no SQL).

R1 extra blockers (prod on Supabase Free): nightly **encrypted** DB + Storage backup running, and one **restore drill** recorded below.

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
- [ ] No console/CSP errors (browser devtools)
- [ ] Mobile width check (web) and one mid-range Android device (cold start ≤ 3 s)
## Backups (R1 and while prod is on Free)
- [ ] Encrypted nightly backup ran (run URL) · [ ] Restore drill done (date, restored row counts)
## Prod smoke (after deploy)
| Suite | Run | Passed | Failed |
|---|---|---|---|
## Known issues / waivers
```
