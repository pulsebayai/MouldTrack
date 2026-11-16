# Architecture: MouldTrack
Status: approved · Updated: 2026-11-16

## Stack
- **App:** Expo (React Native) + TypeScript + Expo Router, one codebase for Android (supervisors) and web (admins and Super Admin, via react-native-web). Android first; iOS later. Exact Expo SDK version pinned in 01.
- **Backend:** Supabase. Postgres with row-level security (RLS) for tenant isolation, Auth (phone number + password, see Identity), Storage for photos, Postgres functions (RPC) for workflow transitions so the rules and idempotency sit on the server. **Edge Functions** (Deno) only for operations that need the service role (Auth admin calls); they stay thin and call service-only SQL functions that hold every rule (02).
- **Builds/deploy:** EAS Build (Android, distributable builds only) + EAS Update channels `development` / `preview` (staging) / `production`. Web: `expo export` with `web.output: "static"` on **EAS Hosting** (Vercel Hobby forbids commercial use). CI/nightly Android APKs are built on the GitHub runner (`scripts/build-android-ci.sh`), not EAS (Free ≈ 15 Android builds/month).
- **Quality:** ESLint · `tsc` · Jest + React Native Testing Library (unit) · pgTAP via `supabase test db` (DB/RLS) · Playwright against the web build (e2e) · Maestro on an Android emulator (mobile e2e) · GitHub Actions.
- **Monitoring:** Sentry Free/Developer (errors only: no tracing, no replay, `sendDefaultPii: false`; 1 user, ~5k errors/month), Supabase logs.

## Core entities
Tenant → Site → Line → Machine · Product · MachineProductBenchmark (machine/product/shift, effective dates) · Shift (+ schedule) · ShiftAssignment (shift × machine × supervisor) · ProductionReading · ProductionSummary (versioned calculation) · MachineIssue → IssueAction, IssueOwnershipHistory · ShiftHandover · Attachment · AuditEvent · User/Membership (user × tenant × role).

## Auth & permissions model
- Roles: `platform_admin`, `unit_admin`, `supervisor` (`maintenance` reserved).
- Every tenant-owned row carries `tenant_id`. RLS checks it against the caller's membership. A supervisor additionally sees only assigned machines and shifts.
- `platform_admin` manages tenants and memberships only. Access to tenant operational data needs an explicit, audited grant.
- Denied cross-tenant access attempts on RPC paths are recorded as audit events (PRD AC-22).
- Helpers `app.current_tenant_id()` / `app.current_role()` return null unless the caller's membership is active, the tenant is active **and** `must_change_password = false`; every RLS policy builds on them, so a user with a temporary password sees no tenant data.
- Unit Admins manage people (create UA/SUP, edit, role change, deactivate/reactivate, reset password) only via the `user-admin` Edge Function. Guards: no self-deactivate/demote/reset; a tenant always keeps ≥ 1 active UA (tenant row lock). The last UA's password is reset by the Super Admin (03). Deactivation = membership `inactive` + Auth ban. Accounts are admin-created only (public sign-up disabled).
- **Denials are returned, not raised** in service SQL functions: an authorisation denial commits an `access.denied` audit row and returns `{ok:false, code}`; validation/duplicate/guard errors raise P0001 (nothing to audit). Later features use the same pattern and `app.audit_denied`.

## Cross-cutting rules
- UUID primary keys. All timestamps are `timestamptz` in UTC. Tenant and site keep an IANA timezone for display and shift-boundary maths (overnight shifts supported).
- State changes (shift open/close, acknowledge, escalate, resolve, verify) go **only** through RPC functions. They are idempotent (client request id) and write an AuditEvent in the same transaction.
- Ownership, acknowledgement and audit tables are append-only, enforced by revoking UPDATE/DELETE and by triggers.
- Photos live in tenant-prefixed Storage paths with RLS. Database rows hold metadata, checksum and the storage key only.
- Accessibility: WCAG AA contrast, touch targets ≥ 48dp, status shown as a label and not by colour alone.
- Connectivity: [Assumed] reliable Wi-Fi/4G. Each form keeps a local draft and retries submission; there is no offline sync.
- Web security headers come from the `expo-router` plugin `headers` in app.json (EAS Hosting applies them for static/server output): CSP `default-src 'self'`, `script-src 'self'` + sha256 of Expo's single inline hydration script, `style-src 'unsafe-inline'` (react-native-web), `connect-src` Supabase + Sentry, `frame-ancestors 'none'`; nosniff; Referrer-Policy; Permissions-Policy; HSTS (EAS default). EAS converts X-Frame-Options into `frame-ancestors`. An Expo upgrade that changes the hydration script breaks the hash → caught by the smoke console-error check.
- Identity: one tenant per user in MVP (`membership.user_id` unique). Platform Super Admin is not a tenant member (separate model, feature 03).
- **Sign-in = phone number + password.** The Auth user's email is the non-deliverable `<10 digits>@phone.mouldtrack.invalid` (RFC 2606); the real phone (Indian mobile, unique platform-wide), name and employee ID (unique per tenant) live on `membership`. Temporary passwords: 12 chars, CSPRNG, shown once to the UA, 24 h expiry, forced change at first sign-in. Password policy ≥ 10 chars with letters + digits (enforced by the `account` function, mirrored in hosted Auth settings). When SMS arrives, the real phone can be added to the Auth user without changing accounts.
- **Audit:** `audit_event` is append-only (UPDATE/DELETE/TRUNCATE revoked from every role incl. service_role, plus a trigger). Phones are stored masked (`+91******1234`); passwords never appear in audit, logs or Sentry (Sentry scrubs phone/password/name/employee-ID keys and function request bodies).

## External integrations
None in MVP. Notifications are in-app (R3). Push/email/WhatsApp come later. **Chosen providers for later:** email = AWS SES (as Supabase custom SMTP when the first email flow is needed); SMS = AWS End User Messaging SMS (needs DLT registration in India). Any future SMS sender must refuse the fixture phone block and refuse every send outside prod.

## Environments & deploy
- Supabase, all ap-south-1 (Mumbai, India data residency): org **MouldTrack** (Free) holds **dev** and **staging**; **prod** goes in a second Free org, created at the R1 release (Free = 2 active projects per org). Separate from the owner's Pulsebay account. Staging is kept from pausing by `keepalive.yml` (weekly, read-only); dev by the nightly run.
- **Prod on Free until pilot completion (owner).** Free has no backups → R1 release blockers: nightly **encrypted** `pg_dump` + Storage export (key held only by the owner; this repo is public, so artifacts are public) and one recorded restore drill.
- Edge Functions + hosted Auth settings are deployed as code: `deploy-dev.yml` runs `supabase functions deploy`, sets `ALLOWED_ORIGINS`, and `scripts/auth-config.mjs --apply` (sign-up off, password policy) on dev; staging/prod get the same at release. The nightly `hosted-checks` job verifies Auth config, functions deployed, no orphan Auth users (Auth user without membership), and CORS (dev origin allowed, foreign origin never reflected).
- Web: dev = https://mouldtrack--dev.expo.app (alias `dev`), staging alias `staging`, prod = production deployment. CI talks to hosted dev only through GitHub Actions secrets; the database is reached via the **session pooler** (GitHub runners are IPv4-only).
- Real plant data only in **prod**. dev and staging hold fixture tenants only.
- Path to prod: PR → main (`deploy-dev.yml`: migrations + web on EAS Hosting alias `dev`) → release Rn to **staging** → gate → prod (migrations, web prod, EAS Update/Build `production`). Every prod step is behind the production-gate hook and the owner's explicit OK.
- Repo is **public** (`pulsebayai/MouldTrack`, free Actions minutes): requirement docs stay local-only (gitignored); no secrets in git; `pull_request` workflows get no secrets (PR CI needs none); hosted secrets are used only by `deploy-dev`, `regression`, `secrets-check`, `keepalive`. The owner's Mac and the Claude workspace cannot reach Expo's servers, so every EAS command runs in GitHub Actions.

## Release & regression policy (every release)
Regression = the whole suite (unit, DB/RLS, web e2e, Android e2e). Tests accumulate and are never edited to pass.
1. **Every PR:** the full suite runs in CI, and a PR merges only when green. The PR carries the AC → test → result table. Target is about 10 min or less: lint/typecheck/unit/build, DB tests and e2e shards run as parallel jobs. Each DB/e2e job gets its **own ephemeral Supabase (`supabase start`) built only from migration files**, with no shared database and no secrets. A schema change that works only on dev fails PR CI; that is intended.
   - **Accepted exception (owner, 2026-11-13):** Android Maestro e2e runs **only nightly and at the release gate, not on PRs**. PRs still compile the Android build (`npm run build`). Risk: a bug specific to native rendering can reach main and is caught at the next nightly. Mitigation: all workflow logic sits in the shared TS + RPC layer that the web e2e covers on every PR; a red nightly is the top priority the next day.
2. **Nightly** (`regression.yml`, 02:30 IST): full suite against dev incl. Android Maestro on an API 34 emulator; failure opens/updates a GitHub issue "Nightly regression failing" for the owner. Shared-DB isolation: N = 1 lane — one run per target (concurrency group); PR CI never touches hosted databases; fixtures reset by `scripts/fixtures-reset.ts` (refuses anything but local/dev). It also covers what PR CI can't: (a) dev has every migration (apply, then diff the live schema against the files); (b) dashboard and query speed on a seeded volume tenant (e.g. 200 machines × 90 days); (c) hosted-only behaviour (Auth settings, Storage policies, EAS Update channel reachable).
   - **Docs-only skip:** PRs or pushes touching only `sdlc/**` or `*.md` run a "what changed" job and skip the suites. A code PR's last commit before merge must have a full green run. Release evidence cites a code commit's green run only.
3. **Every release (R1, R2 …), gate before prod:** (a) main green · (b) regression passes against **staging** (web URL + staging EAS channel build) · (c) manual checklist signed off on staging, including one real Android device · (d) owner approval. After the prod deploy: **smoke tests only**, read-only. Data-writing tests never run against prod.
4. **Evidence:** every CI or regression run uploads JUnit XML, Playwright JSON/HTML and Maestro reports, kept ≥ 90 days. Each release commits `sdlc/releases/<Rn>.md` and copies the summaries to `sdlc/releases/<Rn>/evidence/`.

Release sign-off: Sidambara Raja · Evidence retention: 90 days · Regulated data never in fixtures: real names/phone numbers of plant staff, real customer production data. Fixture Auth addresses use `@phone.mouldtrack.invalid` (never deliverable); fixture phones use `+91 90000 00001–00099` (canonical) and `+91 90000 10000–99999` (throwaway, created by tests and removed by `fixtures-reset`); names are invented. Mutating tests run in their own fixture tenant (`e2e org U`). Local/CI Supabase ports live in 15320–15329, below the Linux ephemeral range, so `supabase start` never races outgoing connections for a port.

## Known debt & fragile areas
- **Synthetic Auth identity (02):** sign-in uses `<10 digits>@phone.mouldtrack.invalid` as the Auth email. It never receives mail; when SMS/OTP or email arrives (roadmap "Later") the mapping is replaced by a real phone/email identity and a data migration.
- **Users search has no index (02):** the Users list filters with `ilike` on name, employee ID and phone. Fine up to about 500 users per tenant; add a trigram index when a tenant approaches that.
- **Staging hosted checks (02, R4):** the nightly `hosted-checks` job runs the Auth config check on staging only; the Edge Function, orphan, consistency and CORS checks are dev-only. The staging `auth-config.mjs --apply` and a first full staging run happen at the R1 release gate, so AC-15 for staging is proven there, not in feature 02.

## Decision log
| Date | Decision | Reason | Feature |
|---|---|---|---|
| 2026-11-13 | Native Expo app (Android first) with web for admins from the same codebase | Owner choice; one codebase and one test stack; Android dominates factory phones | — |
| 2026-11-13 | Schema multi-tenant from day one; R1 = one pilot unit end to end, **including the Super Admin console** (tenants created through an audited UI, not a script) | Owner decision; avoids running scripts against prod; tenants 2–3 can onboard without waiting for R2 | — |
| 2026-11-13 | Android e2e nightly + release only, not per PR | Owner choice; emulator cost/flakiness; logic covered by web e2e | — |
| 2026-11-13 | Supabase region ap-south-1 (Mumbai) | India data residency | — |
| 2026-11-13 | Supabase with RLS for tenant isolation; workflow transitions as RPC | Server-side enforcement (PRD §15); atomic audit | — |
| 2026-11-13 | English only; no offline sync; in-app notifications only in MVP | PRD scope + owner answers | — |
| 2026-11-13 | Model routing: Opus plans/designs/reviews; Sonnet executes approved plan steps and escalates design questions | AI-native SDLC default | — |
| 2026-11-15 | Web hosting on EAS Hosting, `web.output: static`, security headers via expo-router plugin | Vercel Hobby forbids commercial use; static is the simplest mode that supports headers | 01 |
| 2026-11-15 | Supabase: own MouldTrack org (dev+staging), prod in a 2nd Free org at R1; prod Free until pilot end with encrypted backups + restore drill as R1 blockers | Owner: free tiers until pilot completion | 01 |
| 2026-11-15 | Android CI/nightly APKs built on GitHub runners; EAS Build only for distributable builds | EAS Free build quota | 01 |
| 2026-11-15 | Public repo; requirement docs local-only; secrets only in Actions secrets | Owner: free Actions minutes | 01 |
| 2026-11-15 | One tenant per user (MVP); Super Admin modelled separately (03) | Simplest correct isolation rule; PRD: no routine platform access to tenant data | 01 |
| 2026-11-15 | Sentry errors only (no tracing/replay/PII) | Free quota (5k errors/mo, 1 user) + privacy | 01 |
| 2026-11-16 | Edge Functions for service-role Auth operations; all rules in service-only SQL functions reached via `public.svc_*` wrappers (service_role only) | Service-role key never on clients; rules stay pgTAP-testable; PostgREST exposes only `public` | 02 |
| 2026-11-16 | Sign-in = phone + password via non-deliverable `.invalid` Auth email; admin-created accounts only; temp password shown once (no SMS/email in 02) | Works identically locally and hosted with no SMS provider; owner deferred SMS | 02 |
| 2026-11-16 | Audit model: append-only `audit_event`, masked PII, denials committed + returned (not raised) | Denial and its audit stay atomic | 02 |
| 2026-11-16 | Must-change-password gate inside `current_tenant_id()`/`current_role()`; deactivation = inactive membership + Auth ban | One gate every RLS policy inherits; ban also blocks refresh tokens | 02 |
| 2026-11-16 | Later providers: AWS SES (email), AWS End User Messaging SMS (after DLT) | Owner choice; not built yet | 02 |
| 2026-11-16 | Local/CI Supabase ports 15320–15329 | 54xxx/55xxx sit in the runner's ephemeral range → port-bind flakes (01, 02) | 02 |
