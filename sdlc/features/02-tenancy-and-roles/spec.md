# Spec: Tenancy and roles
Intent: ./intent.md · Status: approved · Date: 2026-11-16

Terms: **UA** = Unit Admin, **SUP** = Supervisor, **actor** = the signed-in caller. "Generic denial" = HTTP 403 / SQL error with the message "Not allowed", identical whether the target exists or not (no existence leak).

## User stories & acceptance criteria
**Accounts**
- **AC-1 Create.** Given a UA, when they submit name, employee ID, phone and role (`unit_admin` | `supervisor`), then a user and an active membership in the UA's tenant are created, the temporary password is shown **once**, the user is flagged `must_change_password`, and audit event `user.created` is written. A retry with the same request id does not create a second user.
- **AC-2 Validation.** Name 1–80 chars (trimmed). Employee ID 1–30 chars `[A-Za-z0-9-_/]`, unique per tenant (case-insensitive). Phone = Indian mobile, normalised to `+91` + 10 digits starting 6–9 (spaces, dashes, leading 0 or +91 accepted on input). Phone unique across the platform; the duplicate message is "This phone number is already registered" and never names the other tenant. Errors come from the server; the form shows them next to the field.
- **AC-3 First sign-in.** Given a user with a temporary password, when they sign in with phone + temporary password, then they see only the Change password screen; every data query returns nothing until the change completes (server-enforced). Entering current (temporary) password + a new password meeting the policy (≥ 10 chars, at least one letter and one digit, ≠ current) completes it, clears the flag, writes `user.password_changed`, and lands on Home.
- **AC-4 Expiry.** Given a temporary password older than 24 h, when the user tries to change it, then the server refuses with "Your temporary password has expired. Ask your Unit Admin to reset it." and writes nothing but `access.denied` (reason `temp_password_expired`).
- **AC-5 Reset.** Given a UA and an active user in their tenant (not themself), when they reset the password, then a new temporary password is shown once, `must_change_password` is set again with a fresh 24 h expiry, the user's existing sessions lose data access immediately (AC-3 gate), and `user.password_reset` is written.
- **AC-6 Deactivate / reactivate.** Given a UA, when they deactivate a user, then the user's next API call returns no data, their refresh token stops working, sign-in fails with the generic sign-in error, and `user.deactivated` is written. When reactivated, the user can sign in again with their existing password and `user.reactivated` is written.
- **AC-7 Edit.** A UA can change a user's name, employee ID, phone and role. After a phone change the user signs in with the new number and the old one fails. Each change writes `user.updated` with before/after (phone masked, see Data model).
- **AC-8 Guards.** A UA cannot deactivate, demote or reset themself (self-service password change is AC-3/AC-13). A change that would leave the tenant with zero active UAs is refused ("A unit must keep at least one active Unit Admin"), including two UAs demoting each other concurrently.

**Access control & audit**
- **AC-9 Role.** A SUP calling any user-admin operation gets a generic denial and an `access.denied` event (reason `role`). A SUP can read only their own membership and no audit events.
- **AC-10 Cross-tenant.** A UA of tenant A targeting a user of tenant B (by id) gets a generic denial and an `access.denied` event recorded under tenant A (reason `cross_tenant`). Covers PRD AC 7 for user-admin paths; later features reuse the same helper.
- **AC-11 Audit integrity.** No client role can update or delete `audit_event` rows, and even the service role cannot update/delete them (trigger). A UA reads only their tenant's events; nobody reads another tenant's.
- **AC-12 Deactivated/suspended in flight.** A user whose membership is inactive or whose tenant is suspended cannot perform any user-admin operation (generic denial, audited).

**Sign-in & screens**
- **AC-13 Sign-in.** Sign-in takes phone + password. Submitting with either field empty shows "Enter your phone number" / "Enter your password" and sends no request. Wrong phone or password shows one generic message. Signed-in users can change their own password from Home (current + new, same policy) → `user.password_changed`.
- **AC-14 Users screen (web, UA only).** List of the tenant's users: name, employee ID, phone, role, status as a text label (Active / Inactive / Must change password). Search by name, employee ID or phone; filter by role and status; 25 per page. Actions: Add, Edit, Deactivate/Reactivate (confirm dialog naming the person), Reset password (confirm dialog). The temporary-password panel shows the password with Copy and "Done" and the warning "Shown once. Hand it to the person directly." SUPs see no Users entry, and opening `/users` as a SUP shows "Not allowed".
- **AC-15 Hosted Auth policy.** On dev and staging: public sign-up disabled, minimum password length 10, letters+digits required. Checked by the nightly hosted-only checks.
- **AC-16 No regressions.** The full 01 suite stays green after the planned change of sign-in from email to phone (see Test strategy for which 01 tests change and why).

## Functional requirements
- FR-1 All user-admin writes go through the Edge Function `user-admin` (actions: `create`, `update`, `set_status`, `reset_password`); own password change goes through `account` (`change_password`). No client writes to `membership` or `audit_event`.
- FR-2 Edge Functions only: verify the caller's JWT → actor id; call service-only SQL functions that do **all** authorisation, validation, guards and auditing in one transaction; perform the Supabase Auth admin call; compensate on failure (create: delete the new auth user if the DB step fails; phone change: restore the old auth email if the DB step fails).
- FR-3 Temporary password: 12 characters from an unambiguous alphabet (no 0/O/1/l/I), at least one letter and one digit, generated server-side with a CSPRNG; never stored by us, never logged, never in audit events or Sentry.
- FR-4 Deactivation = membership `inactive` **and** Auth ban (long `ban_duration`); reactivation lifts both.
- FR-5 Idempotency: `create`, `update`, `set_status`, `reset_password` accept a client `request_id`; a repeat with the same actor + request id returns the first outcome (for `create`/`reset_password`: "Already done — reset the password if it was lost", never the password again).

## Non-functional requirements
- Security: service-role key only in Edge Function env; CORS limited to the app origins + localhost; responses never include auth internals. All denials generic. Masked phone in audit.
- Privacy: phone visible only to UAs of the same tenant and to the user themself. Sentry events for these screens/functions carry no name/phone/password (scrubbed fields).
- Performance: users list ≤ 1 s for 500 users (index on tenant_id + search columns).
- Accessibility: WCAG AA, 48dp targets, status as text, numeric keypad for phone, password fields with show/hide.
- Reliability: every operation safe to retry (FR-5); concurrent last-UA guard uses a row lock on the tenant.

## Data model changes (schema lock: 02)
- `membership` + columns: `full_name text not null`, `employee_id text not null`, `phone_e164 text not null` (check `^\+91[6-9][0-9]{9}$`), `must_change_password boolean not null default true`, `temp_password_expires_at timestamptz`, `created_by uuid null`, `updated_at timestamptz not null default now()`. Unique `(tenant_id, lower(employee_id))`; unique `phone_e164`. Existing rows (dev fixtures only) are backfilled by the migration with placeholders, then constrained.
- `app.current_tenant_id()` also requires `must_change_password = false`. New `app.current_role()` (same conditions). Both `security definer`, `stable`, empty search_path.
- RLS `membership`: own row (as today) **or** `tenant_id = app.current_tenant_id() and app.current_role() = 'unit_admin'`. Still no client insert/update/delete.
- New `audit_event` (tenant-owned, append-only): `id uuid pk`, `tenant_id uuid null` (null only for denials by callers with no tenant), `actor_user_id uuid null`, `actor_role text null`, `action text not null` (`user.created|updated|deactivated|reactivated|password_reset|password_changed|access.denied`), `entity_type text`, `entity_id uuid`, `before jsonb`, `after jsonb`, `reason text`, `source text not null` (`edge:user-admin`, `edge:account`, `rpc:<name>`), `request_id uuid null`, `occurred_at timestamptz not null default now()`. Unique `(actor_user_id, request_id)` where request_id not null. Index `(tenant_id, occurred_at desc)`. RLS: select for UA of the tenant; no client writes; UPDATE/DELETE revoked from all and blocked by trigger (incl. service role). Phone values in before/after stored masked `+91******1234`.
- Service-only SQL functions (`app.ua_create_user`, `app.ua_update_user`, `app.ua_set_status`, `app.ua_reset_password`, `app.account_password_changed`, `app.audit_denied`): take the actor id explicitly, executable by `service_role` only, raise generic denial + write `access.denied` on any authorisation failure.
- Auth identity: Supabase Auth user with email `<10 digits>@phone.mouldtrack.invalid` (RFC 2606, never deliverable) and `email_confirm: true`; the real phone lives in `membership.phone_e164`. The app maps phone → this address before `signInWithPassword`.

## Existing code affected
`supabase/migrations` (new migration), `supabase/config.toml` (signup off, password policy, edge runtime), new `supabase/functions/{user-admin,account,_shared}`, `src/lib/session.ts` + provider (must-change state, role), `src/app/sign-in.tsx`, `src/app/(app)/home.tsx`, new `src/app/(app)/users/*`, `src/app/(app)/change-password.tsx`, `scripts/fixtures-reset.ts`, `e2e/web/*`, `e2e/maestro/*`, `.github/workflows/{ci,deploy-dev,regression}.yml`. All have tests from 01.

## Backward compatibility & data migration
No real users exist (dev/staging fixtures only), so email sign-in is replaced, not kept alongside. The migration backfills existing membership rows; `fixtures-reset.ts` recreates fixture users with phone identities. Staging gets the migration at the R1 release like everything else.

## API / interfaces
- `POST /functions/v1/user-admin` body `{ action, request_id, ...}`:
  - `create {full_name, employee_id, phone, role}` → `{user_id, temp_password}`
  - `update {user_id, full_name?, employee_id?, phone?, role?}` → `{ok}`
  - `set_status {user_id, status: 'active'|'inactive'}` → `{ok}`
  - `reset_password {user_id}` → `{temp_password}`
  - Errors: `400 {field, message}` validation · `403 {message:"Not allowed"}` · `409 {field, message}` duplicate · `422 {message}` guard.
- `POST /functions/v1/account` `{action:'change_password', current_password, new_password}` → `{ok}`; `400` policy, `403` expired/wrong current.
- Reads: `membership` (and `audit_event` for a later admin view) via PostgREST under RLS.
- Shared TS: `normalisePhone(input) → +91XXXXXXXXXX | error`, `phoneToAuthEmail(e164)`, `passwordPolicy(pw)` — used by client (early feedback) and functions (authoritative).

## UX flows & screens
- **Sign-in:** "Phone number" with fixed `+91` prefix + numeric keypad, Password with show/hide, Sign in. States: empty-field errors, loading (button disabled + spinner), generic auth error, network error + retry.
- **Change password** (forced after sign-in when flagged; also from Home): current, new, confirm, live policy checklist (text, not colour only). Expired state → message from AC-4 + Sign out.
- **Users (web):** table/list with search + filters, empty state ("No users yet — add your first supervisor"), loading skeleton, error + retry. Add/Edit form (dialog on wide screens, full page on narrow). Temporary-password panel (AC-14). Confirm dialogs for deactivate/reactivate/reset.
- **Home:** UA sees a "Users" entry and "Change password"; SUP sees "Change password".

## Test strategy
| AC | Unit (Jest) | DB (pgTAP) | API (Playwright request, local stack) | Web e2e | Android (Maestro, nightly) |
|---|---|---|---|---|---|
| 1, 2, 5, 6, 7 | normalisePhone, passwordPolicy, form validation | ua_* functions: success + audit row | each action end to end incl. compensation, idempotent retry | Users screen flows | — |
| 3, 4, 13 | session must-change state | current_tenant_id gate, expiry | change_password | forced change, empty fields | sign-in (phone) + forced change |
| 8 | — | self + last-UA guards incl. concurrent demotion | 422 paths | — | — |
| 9, 10, 12 | — | RLS reads by role/tenant; denial audit rows | 403 + audit for SUP, cross-tenant, inactive | `/users` as SUP | — |
| 11 | — | update/delete blocked for every role incl. service | — | — | — |
| 14 | screen tests | — | — | list, search, filter, paginate, a11y scan | — |
| 15 | — | — | — | — | nightly hosted check |
| 16 | full suite | full suite | — | full suite | full suite |
- **01 tests that change, and why (requirement change, not weakening):** `e2e/web/auth.spec.ts` and the 4 Maestro flows sign in with email today; they switch to phone because sign-in by email no longer exists (AC-13). Assertions stay the same or get stricter; no test is deleted. `fixtures-reset.ts` safety tests keep every refusal and add the `.invalid` / fixture-phone checks.
- Fixture identities: phones in the block `+91 90000 00001–00099`, auth emails `@phone.mouldtrack.invalid`, invented names. Fixture users get `must_change_password = false` except dedicated "fresh" fixtures used by AC-3/4.
- **Smoke-safe for prod:** none of the new tests (they write data); the existing smoke suite gains only "sign-in page shows phone field".
- CI: the API + web e2e job runs the local stack **with** edge runtime (no longer excluded there); DB job unchanged.

## Proposed architecture changes (architecture lock: 02)
1. **Supabase Edge Functions** for privileged Auth operations; kept thin; all rules in service-only SQL functions (pgTAP-testable). Deployed by `deploy-dev.yml` (dev) and at releases; nightly checks the deployed functions exist.
2. **Identity = phone + password**, realised as a non-deliverable `@phone.mouldtrack.invalid` Auth email; the phone lives in `membership`. Reason: works the same locally and hosted with no SMS provider; when SMS arrives later, the real phone can be added to the Auth user without changing accounts.
3. **Audit-event model** as above: append-only (revokes + trigger), masked PII, denied attempts recorded via `app.audit_denied`, reused by all later features.
4. **Must-change-password gate** inside `app.current_tenant_id()`; deactivation = membership inactive + Auth ban.
5. **Fixture rule extended:** `.invalid` auth emails and the `+91 90000 000xx` phone block; any future SMS sender must refuse that block and refuse all sends outside prod.
6. **Password policy:** ≥ 10 chars, letters + digits, enforced by the `account` function and mirrored in hosted Auth settings.
7. **Later providers recorded:** AWS SES (email), AWS End User Messaging SMS (SMS, after DLT). Not built in 02.

## Risks & areas of concern
- **Auth ↔ DB two-step writes** can diverge if a compensation also fails. Mitigation: compensation + an `access`/`orphan` check in the nightly that lists auth users without membership (dev) and reports them.
- **Supabase phone sign-in not used** [Uncertain whether hosted phone+password needs an SMS provider configured]; the synthetic address avoids the question but is a design debt to revisit when SMS lands.
- UA sees each temporary password once; until the user changes it, the UA could sign in as them. Mitigation: 24 h expiry, forced change, audit of reset; accepted by owner (intent).
- Edge runtime in CI adds start-up time (~1 min) [Likely]; PR CI target stays ≤ 10 min.
- Changing 01's sign-in touches the Android flows, which run only nightly → first nightly after merge is the real Android proof.
- `access.denied` events could be spammed by a malicious signed-in user; acceptable at pilot scale, revisit with rate limits.

## Out of scope
SMS/email sending, self-service reset, OTP; Super Admin and tenant creation (03); bulk import; audit viewer screen (data is written and readable; the screen comes with 03/09); Users screen on Android (built with shared code, but only tested and linked on web); maintenance role.

## Owner decisions (2026-11-16)
1. Reactivated users keep their existing password (AC-6 as written).
2. Users screen is web-only in 02.
