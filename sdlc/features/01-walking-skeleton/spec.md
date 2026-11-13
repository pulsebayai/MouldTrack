# Spec: Walking skeleton
Intent: ./intent.md · Status: approved

## User stories & acceptance criteria
**US-1 Sign in (Android + web).** As a tenant user I sign in with email/password and see which tenant and role I am working in.
- **AC-1** Given a fixture user with an active membership in tenant A, when they sign in with valid credentials (Android or web), then the home screen shows tenant A's name and their role.
- **AC-2** Given invalid credentials, when they submit, then a non-technical error ("Email or password is incorrect") appears, no session is created, and the screen stays on sign-in.
- **AC-3** Given a signed-in user, when they sign out, then the session is cleared and they return to sign-in. Given no session, any protected route redirects to sign-in.
- **AC-4** Given a signed-in user with **no** active membership (or a suspended tenant), then they see a "No access — contact your administrator" screen and no tenant data.
- **AC-5** Given the app is restarted while a session is valid, then the user lands on home without signing in again.

**US-2 Tenant isolation (proven, not assumed).**
- **AC-6** Given users in tenants A and B, when user A selects `tenant` / `membership`, then only A's rows are returned; anonymous callers get none; no client role can insert/update/delete these tables. (pgTAP)

**US-3 Trustworthy pipeline (developer).**
- **AC-7** Every code PR runs lint, typecheck, unit, build (web export + Android compile), DB tests and web e2e as parallel jobs, each DB/e2e job on its own ephemeral local Supabase built from migrations; wall clock ≈ ≤ 10 min; JUnit/JSON/HTML uploaded (`if: always()`, 90 days); Markdown summary in the job summary.
- **AC-8** A docs-only PR (`sdlc/**`, `*.md`) runs only the "what changed" job and passes.
- **AC-9** `regression.yml`: nightly (02:30 IST) against dev = full suite **including Android Maestro on an emulator** using an APK built on the runner; `workflow_dispatch` with `target` = dev | staging | prod (prod ⇒ smoke only) and `base_url`; one run at a time per target; evidence artifact `regression-evidence-<target>`; failure notifies the owner (GitHub issue + email via GitHub notifications).
- **AC-10** Smoke suite (prod-safe, read-only): web app responds 200; sign-in screen renders; unauthenticated protected route redirects; security headers present (see NFR); zero console errors.
- **AC-11** Production-gate hook blocks (exit 2, reason on stderr): `git push … main`, `supabase db push` / `supabase migration up` against a non-dev project ref, `eas update --channel production`, `eas deploy --prod`, `eas build --profile production`.
- **AC-12** Nightly also checks dev drift: every migration file is applied on dev (`supabase migration list` diff = empty).
- **AC-13** A deliberate test error from the dev web build and the Android build appears in Sentry with environment = `development`.

## Functional requirements
- Expo Router app with routes: `/sign-in`, `/(app)/home`, `/no-access`. Route guard from the session + membership query.
- Supabase client: `@supabase/supabase-js`; session persisted with AsyncStorage on Android, localStorage on web; auto token refresh.
- Home shows tenant name, role label, user email, app version + environment label (DEV/STAGING), sign-out button.
- Fixture provisioning script `scripts/fixtures-reset.ts` (service role, **refuses to run unless target is local or dev**): idempotently ensures tenants `e2e org A`, `e2e org B`, users `e2e-admin-a@example.test`, `e2e-sup-a@example.test`, `e2e-sup-b@example.test`, `e2e-nomember@example.test`; resets their passwords from a CI secret.

## Non-functional requirements
- **Security:** no secrets in git (public repo); PR CI uses only local Supabase default keys; dev URL/anon key/service key, Sentry DSN/token, Expo token live in GitHub Actions secrets, used only by `regression.yml` (never on `pull_request` from forks). Web responses send `Content-Security-Policy`, `X-Content-Type-Options: nosniff`, `Referrer-Policy`, `Strict-Transport-Security` — **[Uncertain] whether EAS Hosting supports custom headers; plan step 1 verifies. If it can't, the gap is recorded in architecture.md and the smoke check asserts what the host can do.**
- **Accessibility:** touch targets ≥ 48dp; WCAG AA contrast; every input labelled (also for screen readers); errors announced as text.
- **Performance:** Android cold start to sign-in ≤ 3 s on a mid-range device (e.g. 4 GB RAM) — measured manually once, recorded in plan.
- **Privacy:** fixtures only `@example.test`; Supabase Auth email sending disabled for dev/staging (users created confirmed via admin API), so no mail ever goes to `.test`.

## Data model changes (schema lock: 01)
- `tenant` (id uuid pk default gen_random_uuid(), name text not null, status `tenant_status` enum('active','suspended') default 'active', timezone text not null default 'Asia/Kolkata', created_at timestamptz default now()).
- `membership` (id uuid pk, tenant_id uuid fk → tenant, user_id uuid fk → auth.users, role `member_role` enum('unit_admin','supervisor','maintenance'), status enum('active','inactive') default 'active', created_at timestamptz). **unique(user_id)** — one tenant per user in MVP.
- Helper `app.current_tenant_id()` (SQL, stable, security definer, `search_path` pinned): tenant of the caller's active membership in an active tenant, else null.
- RLS enabled + forced on both tables. `tenant`: select where `id = app.current_tenant_id()`. `membership`: select where `user_id = auth.uid()`. No insert/update/delete policies for `authenticated`/`anon` (writes only via service role in 01; RPCs arrive in 02).
- Platform Super Admin identity is **not** a membership role; it is modelled in 03 (separate table), so platform staff never appear as tenant members.

## API / interfaces
- Client reads only: `from('membership').select('role, status, tenant:tenant(name, status)').single()`.
- `src/lib/session.ts`: `getSessionContext(): Promise<{ user, tenant, role } | { noAccess: true } | null>` — the single function the route guard uses (unit-tested with a mocked client).

## UX flows & screens
- Sign-in: email, password (show/hide), primary button full-width; states: idle, submitting (button disabled + spinner), error text.
- Home: header (tenant name), role chip with text label, environment banner on non-prod, sign-out.
- No-access: message + sign-out. Loading state: splash until session resolved. Network error: "Can't reach MouldTrack. Check your connection and try again." + retry.

## Test strategy
| AC | Unit (Jest+RNTL) | DB (pgTAP) | Web e2e (Playwright) | Android e2e (Maestro, nightly) | Smoke-safe |
|---|---|---|---|---|---|
| AC-1 | session context mapping | — | sign-in → home | sign-in → home | — |
| AC-2 | error mapping | — | bad password | bad password | — |
| AC-3 | guard redirects | — | sign-out; deep link redirect | sign-out | redirect only ✓ |
| AC-4 | noAccess branch | `current_tenant_id` null for nomember / suspended | nomember user | — | — |
| AC-5 | — | — | reload keeps session | relaunch keeps session | — |
| AC-6 | — | A≠B, anon none, writes denied | — | — | — |
| AC-7/8 | — | — | proven by two PRs (CI run URLs in plan) | — | — |
| AC-9/12 | — | — | proven by one dispatch + one nightly run | — | — |
| AC-10 | — | — | `smoke.spec` | — | ✓ |
| AC-11 | hook script tests (bats or Jest on fixtures of commands) | — | — | — | — |
| AC-13 | — | — | manual, screenshot in plan | manual | — |
All of the above join the regression suite permanently.

## Proposed architecture changes (architecture lock: 01)
1. Web hosting: Vercel → **EAS Hosting** (Vercel Hobby forbids commercial use).
2. Environments: Supabase org A (Free): dev + staging; org B (Free): prod, created at R1. Staging weekly keep-alive ping (read-only).
3. Prod on Free until pilot completion: **encrypted** nightly backup (DB + Storage) and one restore drill are R1 release blockers. Backups never stored unencrypted in this public repo's artifacts.
4. Android APKs for CI/nightly are built on the GitHub runner (`expo prebuild` + Gradle); EAS Build only for distributable builds (Free ≈ 15 Android builds/month).
5. Shared-database isolation: only `regression.yml` touches hosted dev (concurrency group per target, N = 1 lane); PR CI never touches hosted databases; local runs use local Supabase only.
6. One tenant per user in MVP (`unique(user_id)`); Super Admin modelled separately (03).
7. Repo is public: requirement docs local-only; all secrets in GitHub Actions secrets; workflows on `pull_request` get no secrets.

## Risks & areas of concern
- **[Likely] Android emulator in GitHub Actions is the flakiest part** (boot time, KVM availability on runners). Mitigation: `reactivecircus/android-emulator-runner` on ubuntu with KVM, cached AVD, one retry of the *boot* only (never of tests); if still unstable, logged and escalated.
- **[Uncertain] EAS Hosting custom headers** (see NFR).
- **Expo SDK / React Native version churn:** pin exact versions; Dependabot off for major versions until after R1.
- Supabase Free dev pausing if nightly fails for 7 days in a row.

## Out of scope
Invites, password reset, role management (02); Super Admin (03); any manufacturing entity; staging/prod deploys and prod org creation (R1 release); iOS; Play Store listing; the backup job itself (built before the R1 release, tracked in plan of the release prep).
