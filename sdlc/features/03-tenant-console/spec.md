# Spec: Tenant console (Platform Super Admin)
Intent: ./intent.md · Status: approved · Date: 2026-11-16

Terms: **SA** Platform Super Admin, **UA** Unit Admin. All 02 patterns apply: Edge Functions for Auth admin calls, rules in service-only SQL (`app.*` via `public.svc_*`), D13 denials (committed `access.denied` + `{ok:false, code}`), idempotent `request_id`, masked phones in audit, temporary passwords shown once (12 chars, 24 h, forced change, then sign in again — D14).

## User stories & acceptance criteria
**Identity**
- **AC-1 SA sign-in.** An active SA signs in on the normal phone + password screen and lands on the **Console**; tenant screens (Home, Users, Plant) are not reachable ("Not allowed"). A user can't be both an SA and a tenant member (phone unique across both).
- **AC-2 First SA (one-time setup).** Calling the setup endpoint with the correct one-time token creates the first SA (name, phone) and returns a temporary password **once** in the HTTP response; audited `platform_admin.created` (source `setup`). Once any SA exists, the endpoint refuses (403, audited), with or without a token. A wrong/missing token → 403. Nothing is written to CI logs.
- **AC-3 More SAs.** An SA can add another SA (name, phone → temp password once), deactivate/reactivate one (sessions ended, Auth ban as 02), and reset an SA's password. An SA can't deactivate themself; the last active SA can't be deactivated. Audited.

**Tenants**
- **AC-4 Register.** An SA registers a tenant: name (1–80, unique case-insensitive), timezone (IANA list, default Asia/Kolkata), plan label **Trial | Active** (default Trial). Status starts **Active**. Audited `tenant.created`.
- **AC-5 Edit.** Name, timezone and plan label can be changed. Audited `tenant.updated` (before/after).
- **AC-6 Suspend / activate.** Suspending (confirm dialog naming the tenant, reason required 1–200) blocks every user of that tenant from tenant data on their next request and from all write RPCs; activation restores access (sessions are not ended — suspension is organisational, not a credential issue). Audited `tenant.suspended|activated` with reason.
- **AC-7 Tenant list.** Name, status (text), plan label, created date, active users, active UAs. Search by name, filter by status/plan, 25 per page.

**Tenant Unit Admins (only)**
- **AC-8 Create UA.** For a tenant, an SA creates a Unit Admin (name, employee ID, phone) — same validation and uniqueness as 02 — temp password once. Works for the first UA and later ones. Audited under the tenant (`user.created`, actor role `platform_admin`).
- **AC-9 Reset UA password.** An SA resets the password of a tenant's **UA** (never a supervisor): new temp password once, forced change, sessions ended. Audited under the tenant (`user.password_reset`).
- **AC-10 UA list.** For a tenant the SA sees its UAs only: name, masked phone, status, "Must change password". No other member is visible.

**Boundaries & audit**
- **AC-11 No operational access.** An SA can read **no** tenant operational rows: memberships (except via AC-10's function), audit events of tenant users, and every tenant-owned table (incl. 04's site/line/machine/product/target_version). pgTAP per table. Write RPCs of tenants (`pm_*`, user-admin) deny an SA (generic + audit).
- **AC-12 Platform audit.** The SA sees a platform audit list: events whose actor is an SA, plus denials of SA calls — who, action, tenant (name), when; 50 per page, newest first. Tenant users' own events are not shown.
- **AC-13 UA sees platform actions.** A UA sees platform actions on their own tenant (suspend/activate, UA created/reset) in their tenant's audit rows (already readable by UAs; proven by test).
- **AC-14 Role checks.** A tenant user (UA/SUP) calling any platform endpoint → generic 403 + audit. An SA with a temporary password or deactivated → denied.
- **AC-15 Screens (web).** Console: Tenants list → tenant detail (fields, status, UAs, actions) · Super Admins · Platform audit. States: empty/loading/error, confirm dialogs, temp-password panel (02 component), 48dp, text status, axe 0 serious/critical.
- **AC-16 No regressions.** 01, 02 and (after rebase) 04 suites stay green.

## Functional requirements
- FR-1 New Edge Function `platform` (JWT required): actions `tenant_create|tenant_update|tenant_set_status|ua_create|ua_reset_password|sa_create|sa_set_status|sa_reset_password`. New Edge Function `platform-setup` (`verify_jwt=false`): header `x-setup-token` compared in constant time with secret `PLATFORM_SETUP_TOKEN`; refuses when the token is unset.
- FR-2 `account` (02) supports SAs for change_password (reads `platform_admin` when no membership).
- FR-3 Read functions (security definer, SA only): `pa_tenant_summaries(search, status, plan, page)`, `pa_tenant_unit_admins(tenant_id)`, `pa_audit(page)`. SAs get **no** RLS select on membership/audit_event/tenant-owned tables; `tenant` gets an SA select policy.
- FR-4 Session routing (client): no active membership → check own `platform_admin` row → console; else no-access screen.

## Non-functional requirements
Security: the setup token never in git/CI logs; constant-time compare; endpoint rate-limited by the "only while no SA exists" rule. Privacy: SA sees masked UA phones only. Performance: tenant list ≤ 1 s for 200 tenants.

## Data model changes (schema lock: tenant + platform tables — split with 04, logged)
- `tenant` + `plan_label` enum `trial|active` (default trial), `updated_at`, `suspended_reason text null`; unique `lower(name)`.
- `platform_admin` (user_id pk → auth.users, full_name, phone_e164, status active|inactive, must_change_password, temp_password_expires_at, created_by, created_at, updated_at). RLS: own row only.
- `phone_claim` (phone_e164 pk, user_id unique, kind membership|platform_admin) maintained by triggers on membership and platform_admin → one phone per person across both (AC-1).
- `app.is_platform_admin()` (active, not must-change). `audit_event`: SA-actor rows use `actor_role = 'platform_admin'`; tenant actions carry the tenant's id, SA-only actions carry `tenant_id null`. New actions rely on 04's format rule (see Proposed architecture changes).

## Existing code affected
02's `account` and `_shared` Edge code, `app._ua_authorise` (must deny SAs), `src/lib/session.ts` + provider + `_layout.tsx` (routing), `sign-in.tsx` (unchanged UI), seed/fixtures (fixture SA, tenant plan labels), `e2e/web/fixtures.ts`, `deploy-dev.yml` (deploy 2 new functions; `PLATFORM_SETUP_TOKEN` only on environments where setup is pending), `regression.yml` hosted checks (functions list). All have 01–02 tests.

## Backward compatibility & data migration
Additive. Existing tenants get `plan_label = trial`. Existing membership phones are copied into `phone_claim` by the migration (dev fixtures).

## API / interfaces
- `POST /functions/v1/platform {action, request_id, …}` → `{ok, …}`; errors as 02 (`400/403/409/422` with `code`).
- `POST /functions/v1/platform-setup` header `x-setup-token`, body `{full_name, phone}` → `{user_id, temp_password}` or 403.
- Owner runbook (docs): set `PLATFORM_SETUP_TOKEN` for the target project, run one `curl` from the owner's own terminal, store nothing, unset the secret.

## UX flows & screens
Console (web): left nav Tenants · Super Admins · Platform audit · Change password · Sign out. Tenant detail: header with status label + plan label, actions Edit, Suspend/Activate, "Unit Admins" card (list + Add Unit Admin + Reset password). Temp-password panel reused from 02.

## Test strategy
| AC | Unit | DB (pgTAP) | API (Playwright request) | Web e2e |
|---|---|---|---|---|
| 1 | session routing | phone_claim uniqueness both ways | — | SA → console; SA blocked from /home, /users, /plant |
| 2 | — | setup refuses when SA exists | token missing/wrong/right; second call refused | — |
| 3 | — | last-SA + self guards | SA create/deactivate/reset | Super Admins screen |
| 4–7 | forms | pa_* tenant functions + audit | each action incl. idempotent retry | register, edit, suspend → tenant user blocked, activate |
| 8–10 | — | UA-only target check (supervisor refused) | create UA, reset UA, reset SUP refused | tenant detail UA card |
| 11 | — | SA reads 0 rows from every tenant-owned table (incl. 04's after rebase) | SA calls user-admin/pm_* → 403 + audit | — |
| 12–13 | — | audit visibility SA vs UA | — | platform audit list |
| 14 | — | denials audited | UA/SUP → platform 403 | — |
| 15 | screen tests | — | — | axe on console screens |
| 16 | full suite | full suite | full suite | full suite |
Mutating tests use dedicated fixture tenants created by the tests (prefix `e2e t3 …`) and a fixture SA (`+91 90000 00090`). Setup-endpoint tests run on the **local stack only** (a hosted dev already has an SA); hosted checks assert the setup endpoint refuses.

## Proposed architecture changes (architecture lock: 03)
1. **Platform identity:** `platform_admin` separate from membership; phone unique across both via `phone_claim`; same sign-in, routed by identity type.
2. **SA data boundary:** SAs read tenants and only the facts exposed by `pa_*` functions; no RLS access to tenant-owned tables; every new tenant-owned table gets an "SA reads 0 rows" pgTAP test.
3. **Platform audit:** SA actions are audit events (`actor_role = platform_admin`), tenant-scoped when they act on a tenant, visible to that tenant's UAs.
4. **One-time setup endpoint** per environment, token from a secret set only while setup is pending; used once for prod at the R1 release.

## Risks & areas of concern
- **Setup endpoint** is the only unauthenticated write path. Mitigation: refuses once any SA exists, token required, constant-time compare, secret unset after use, hosted check asserts refusal.
- **Shared code with 02** (`account`, `_ua_authorise`) — regressions in user admin. Mitigation: 02's API/pgTAP suites run unchanged.
- **Batch overlap with 04:** seed/fixtures, Home/session routing, audit action rule. 04 merges first; 03 rebases and adds "SA reads 0 rows" tests for 04's tables.

## Out of scope
Billing/limits, deleting tenants, SA access grants to operational data, managing supervisors, platform health beyond counts, email/SMS.
