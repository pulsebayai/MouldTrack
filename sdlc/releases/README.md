# Releases — procedure and record template

Every release Rn follows architecture.md §Release & regression policy. Run on `main`, after every feature in the release is shipped.

## Procedure (Stage 5b)
1. Scope: list the features; confirm `main` CI is green. Note the commit SHA and the CI run URL (a **code** commit's full run, never a docs-only skipped run).
2. Deploy `main` to **staging** (migrations, Edge Functions `user-admin`, `account`, `platform`, `platform-setup`, secret `ALLOWED_ORIGINS`, web alias `staging`, EAS Update `preview`) and run `node scripts/auth-config.mjs --apply --ref staging` (hosted Auth settings; the nightly check only verifies them). Run `regression.yml` with `target=staging`. It must pass. The deploy must end with the **setup-token check**: `supabase secrets list --project-ref <ref> -o json | jq -e '[.[] | select(.name=="PLATFORM_SETUP_TOKEN")] | length == 0'` succeeds (no `PLATFORM_SETUP_TOKEN` unless the first-Super-Admin runbook below is in progress; if present and not in progress, unset it and investigate who set it). Never put the token in `config.toml` (the deploy CLI pushes `[edge_runtime.secrets]` to the hosted project; D11).
3. Manual checklist on staging (below), including one **real Android phone**.
4. Write `sdlc/releases/<Rn>.md` from the template; copy the regression summary and result files into `sdlc/releases/<Rn>/evidence/`. Commit via PR.
5. **Owner sign-off in chat (Sidambara Raja).** Only then promote to prod (the production-gate hook blocks it until the owner runs/approves it).
6. After the prod deploy run the same **setup-token check** against prod (read-only), then run `regression.yml` with `target=prod` (**smoke only**, read-only) and append its summary. Pass → mark the release `released` in roadmap.md. Fail → roll back, record the incident, add a roadmap item.

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
