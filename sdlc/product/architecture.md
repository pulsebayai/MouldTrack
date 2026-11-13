# Architecture: MouldTrack
Status: approved · Updated: 2026-11-13

## Stack
- **App:** Expo (React Native) + TypeScript + Expo Router, one codebase for Android (supervisors) and web (admins and Super Admin, via react-native-web). Android first; iOS later. Exact Expo SDK version pinned in 01.
- **Backend:** Supabase. Postgres with row-level security (RLS) for tenant isolation, Auth (email/password; phone OTP later), Storage for photos, Postgres functions (RPC) for workflow transitions so the rules and idempotency sit on the server.
- **Builds/deploy:** EAS Build (Android) + EAS Update channels `development` / `staging` / `production`. Web build (`expo export`) on Vercel.
- **Quality:** ESLint · `tsc` · Jest + React Native Testing Library (unit) · pgTAP via `supabase test db` (DB/RLS) · Playwright against the web build (e2e) · Maestro on an Android emulator (mobile e2e) · GitHub Actions.
- **Monitoring:** Sentry (app + web), Supabase logs.

## Core entities
Tenant → Site → Line → Machine · Product · MachineProductBenchmark (machine/product/shift, effective dates) · Shift (+ schedule) · ShiftAssignment (shift × machine × supervisor) · ProductionReading · ProductionSummary (versioned calculation) · MachineIssue → IssueAction, IssueOwnershipHistory · ShiftHandover · Attachment · AuditEvent · User/Membership (user × tenant × role).

## Auth & permissions model
- Roles: `platform_admin`, `unit_admin`, `supervisor` (`maintenance` reserved).
- Every tenant-owned row carries `tenant_id`. RLS checks it against the caller's membership. A supervisor additionally sees only assigned machines and shifts.
- `platform_admin` manages tenants and memberships only. Access to tenant operational data needs an explicit, audited grant.
- Denied cross-tenant access attempts on RPC paths are recorded as audit events (PRD AC-22).

## Cross-cutting rules
- UUID primary keys. All timestamps are `timestamptz` in UTC. Tenant and site keep an IANA timezone for display and shift-boundary maths (overnight shifts supported).
- State changes (shift open/close, acknowledge, escalate, resolve, verify) go **only** through RPC functions. They are idempotent (client request id) and write an AuditEvent in the same transaction.
- Ownership, acknowledgement and audit tables are append-only, enforced by revoking UPDATE/DELETE and by triggers.
- Photos live in tenant-prefixed Storage paths with RLS. Database rows hold metadata, checksum and the storage key only.
- Accessibility: WCAG AA contrast, touch targets ≥ 48dp, status shown as a label and not by colour alone.
- Connectivity: [Assumed] reliable Wi-Fi/4G. Each form keeps a local draft and retries submission; there is no offline sync.

## External integrations
None in MVP. Notifications are in-app (R3). Push/email/WhatsApp come later.

## Environments & deploy
- Three Supabase projects: **dev**, **staging**, **prod**. Region: ap-south-1 (Mumbai) for all three, for India data residency (owner-confirmed).
- Real plant data only in **prod**. dev and staging hold fixture tenants only.
- Path to prod: PR → main (deploys to dev: migrations + web preview + EAS Update `development`) → release Rn to **staging** → gate → prod (migrations, web prod, EAS Update/Build `production`). Every prod step is behind the production-gate hook.

## Release & regression policy (every release)
Regression = the whole suite (unit, DB/RLS, web e2e, Android e2e). Tests accumulate and are never edited to pass.
1. **Every PR:** the full suite runs in CI, and a PR merges only when green. The PR carries the AC → test → result table. Target is about 10 min or less: lint/typecheck/unit/build, DB tests and e2e shards run as parallel jobs. Each DB/e2e job gets its **own ephemeral Supabase (`supabase start`) built only from migration files**, with no shared database and no secrets. A schema change that works only on dev fails PR CI; that is intended.
   - **Accepted exception (owner, 2026-11-13):** Android Maestro e2e runs **only nightly and at the release gate, not on PRs**. PRs still compile the Android build (`npm run build`). Risk: a bug specific to native rendering can reach main and is caught at the next nightly. Mitigation: all workflow logic sits in the shared TS + RPC layer that the web e2e covers on every PR; a red nightly is the top priority the next day.
2. **Nightly:** full suite against dev, and the owner is notified on failure. It also covers what PR CI can't: (a) dev has every migration (apply, then diff the live schema against the files); (b) dashboard and query speed on a seeded volume tenant (e.g. 200 machines × 90 days); (c) hosted-only behaviour (Auth settings, Storage policies, EAS Update channel reachable).
   - **Docs-only skip:** PRs or pushes touching only `sdlc/**` or `*.md` run a "what changed" job and skip the suites. A code PR's last commit before merge must have a full green run. Release evidence cites a code commit's green run only.
3. **Every release (R1, R2 …), gate before prod:** (a) main green · (b) regression passes against **staging** (web URL + staging EAS channel build) · (c) manual checklist signed off on staging, including one real Android device · (d) owner approval. After the prod deploy: **smoke tests only**, read-only. Data-writing tests never run against prod.
4. **Evidence:** every CI or regression run uploads JUnit XML, Playwright JSON/HTML and Maestro reports, kept ≥ 90 days. Each release commits `sdlc/releases/<Rn>.md` and copies the summaries to `sdlc/releases/<Rn>/evidence/`.

Release sign-off: Sidambara Raja · Evidence retention: 90 days · Regulated data never in fixtures: real names/phone numbers of plant staff, real customer production data. Fixtures use `@example.test` addresses only, and the app never sends mail or SMS to `.test`.

## Known debt & fragile areas
None yet (greenfield).

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
