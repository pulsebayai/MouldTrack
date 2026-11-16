# Intent: Tenancy and roles
Author: Sidambara Raja (drafted by Claude) · Status: approved · Date: 2026-11-16
Roadmap item: 02-tenancy-and-roles · Release: R1 · Moves product metric: none directly (enabler). Every R1 metric needs a named, accountable supervisor account per tenant.

## Problem
After 01, accounts exist only as fixtures written with the service role. Nobody in a plant can add a supervisor, remove a leaver, or reset a forgotten password, so the pilot cannot run. Accountability (product principle 3) is meaningless if accounts are shared or a departed supervisor can still sign in. Nothing records who changed access, and PRD AC 7 requires denied cross-tenant attempts to be auditable.

## Proposed outcome
- **Admin-created accounts only.** A Unit Admin creates a user (name, employee ID — required, unique per tenant — phone number, role: `unit_admin` or `supervisor`) in their own tenant. No self sign-up.
- **Sign-in = phone number + password** for every tenant user (Unit Admins included). Phone number is unique across the platform (one tenant per user).
- **Temporary password, handed over in person.** On create and on reset, the server generates a temporary password and shows it **once** to the Unit Admin. It expires after 24 h and must be changed at first sign-in. No SMS or email is sent in 02 (owner, 2026-11-16: SMS later).
- **Unit Admin manages people:** create Unit Admins and supervisors, change role, edit name / employee ID / phone, deactivate and reactivate, reset a password (new temporary password, forced change). The last Unit Admin's own password is reset by the Super Admin (03). Guards: a Unit Admin can't deactivate or demote themselves, and a tenant always keeps at least one active Unit Admin.
- **Deactivation takes effect immediately:** data access stops on the next request (RLS already checks membership status) and the user's sessions are revoked.
- **Role-based access** enforced on the server: helper functions for "caller's role", used by RLS and RPCs. Supervisors cannot see or call user management.
- **Audit-event base:** append-only `audit_event` (tenant, actor, action, entity, entity id, before/after, source, timestamp), written in the same transaction as every user-management change. Denied cross-tenant / wrong-role calls on RPC and Edge Function paths are recorded.
- **Screens (web, Unit Admin):** user list (search by name / employee ID / phone, status shown as a label), create, edit, deactivate/reactivate, reset password. **Android/web:** forced change-password screen.
- Leftovers from 01: hosted Auth password policy (dev + staging), sign-in blocks empty fields.

## Users & systems affected
Unit Admin (web), Supervisor (Android: first sign-in, password change). Systems: Supabase Auth (admin API), Postgres (membership, user profile, audit_event, RLS), **new: Supabase Edge Functions** for operations that need the service role (create user, reset password, revoke sessions). No external integration in 02. For later features: AWS SES = email provider; AWS End User Messaging SMS = SMS provider (needs DLT registration in India).

## Success metrics
- A Unit Admin creates a working supervisor account in ≤ 2 min (timed on the staging checklist).
- 100% of user-management actions produce an audit event (pgTAP + e2e prove each action).
- A deactivated user's next API call is denied (test), and their refresh token no longer works (test).
- Cross-tenant and wrong-role attempts on every new RPC / Edge Function are denied **and** audited (tests per endpoint).

## Constraints
- Server decides (principle 1): every rule above lives in Postgres/Edge Functions; screens only render.
- Service-role key never reaches the client; Edge Functions check the caller's JWT, tenant and role themselves.
- Personal data: phone number and name are plant-staff personal data. Fixtures use invented names and non-dialable numbers only. Phone visible to Unit Admins of the same tenant, and to the user themself.
- One tenant per user (architecture). Free tiers. PR CI stays secret-free (Edge Functions run on the local Supabase in CI).
- Bootstrapping: until 03 ships, each tenant's first Unit Admin exists only as a dev/staging fixture; in prod, 03 creates it.

## Out of scope
- Sending any SMS or email: SMS (temporary password delivery, later OTP/self-service reset) becomes a roadmap "Later" item, added on main at the next roadmap commit. Self sign-up.
- Super Admin / platform console, tenant creation (03).
- Bulk import of users (CSV). Maintenance role screens (role stays reserved).
- Site/machine-level scoping of supervisors (05 assignments).

## Open questions
Resolved 2026-11-16 (owner): sign-in = phone + password; employee ID required + unique per tenant; Super Admin resets the last Unit Admin's password (03); SMS deferred to later (AWS End User Messaging SMS; SES for email).
1. Spec (technical): Supabase phone+password sign-in normally needs the Phone provider enabled; the spec decides between that and an internal non-deliverable auth address keyed by phone, so that no SMS provider is needed now and adding SMS later doesn't change accounts.

- Fixture phone numbers (`+91 90000 …`) are real-format numbers reserved for tests; no SMS, call or message is ever sent to them (nothing in the app contacts a phone number in 02).
