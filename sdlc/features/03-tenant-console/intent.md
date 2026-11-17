# Intent: Tenant console (Platform Super Admin)
Author: Sidambara Raja (drafted by Claude) · Status: approved · Date: 2026-11-16
Roadmap item: 03-tenant-console · Release: R1 · Batch A (with 04; merges after 04) · Moves product metric: enabler — the pilot tenant and tenants 2–3 can only be onboarded through it (decision log 2026-11-13: tenants via an audited UI, never a script against prod).

## Problem
Tenants exist only as fixtures written with the service role. There is no way to create the pilot tenant or its first Unit Admin in prod, no way to suspend a tenant that stops paying or leaves, and no way to rescue a tenant whose only Unit Admin forgot their password (02 decision). Doing any of this by SQL against prod would break the release policy and leave no audit trail.

## Proposed outcome
A web console for the **Platform Super Admin** (a separate identity, not a tenant member):
- **Tenants:** list (name, status, plan label, created date, number of active users and Unit Admins), register (name, timezone — default Asia/Kolkata, plan label), edit name/timezone/plan label, **activate / suspend**. Suspension takes effect immediately for every user of that tenant (already enforced by 01–02 helpers) and is reversible.
- **Plan label:** **Trial / Active** — a label only (owner), no limits enforced. "Suspended" is the tenant **status** and blocks access.
- **First Unit Admin:** create a Unit Admin for a tenant (name, employee ID, phone) with a temporary password shown once — same rules and same server code path as 02.
- **Rescue:** reset the password of a tenant's **Unit Admin** (not supervisors) — temporary password, forced change, sessions ended (02 rules).
- **Platform audit:** every console action writes an audit event; the Super Admin sees a platform audit list (who, what, which tenant, when). Tenant Unit Admins also see platform actions on their own tenant in their audit trail.
- **No routine access to tenant operational data:** the Super Admin sees tenant-level facts only (above) and the tenant's Unit Admins (name, masked phone, status). No supervisors' details, machines, readings or issues — enforced in the database, not the UI.
- **More than one Super Admin:** a Super Admin can add and deactivate other Super Admins (audited); the last active Super Admin can't be deactivated.
- **Sign-in:** the same phone + password screen; a platform admin is routed to the console.
- **First Super Admin:** created once per environment by a **one-time, audited setup step that refuses to run once any Super Admin exists** (owner, 2026-11-16). dev/staging get a fixture Super Admin.

## Users & systems affected
Platform Super Admin (web, new console). Unit Admins (see platform actions on their tenant in audit). Postgres: new platform-admin table, tenant columns (plan label), RLS for the Super Admin, audit changes. Edge Functions: reuse/extend 02's `user-admin` path for "create first UA" and "reset UA password"; a new platform function for tenant actions and the one-time setup.

## Success metrics
- The pilot tenant and its first Unit Admin are created in prod through the console, with audit events, and **no SQL run against prod** (checked at the R1 release).
- Suspending a tenant blocks its users' next request (test) and is reversed by activation (test).
- 100 % of console actions audited; 0 tenant operational rows readable by the Super Admin (pgTAP per table, including 04's new tables once merged).

## Constraints
- Server decides; same patterns as 02 (service-only SQL, D13 denials, idempotent request ids, masked phones, append-only audit).
- **Architecture lock: 03** (new identity type + platform audit). **Schema lock split** with 04 (03: tenant, platform tables; 04: plant tables) — logged exception. 03 merges after 04 and rebases.
- The one-time setup must not print a password into public CI logs (public repo).
- Free tiers; no external systems.

## Behaviour that must not change
01–02 behaviour (sign-in, user admin, isolation, audit) and 04's once merged; full suite green.

## Out of scope
Billing, plan limits, invoices; Super Admin access to tenant operational data (the "explicit, audited grant" in architecture stays future); deleting tenants (suspend only); managing supervisors from the console; multiple Super Admin roles/permissions; platform health dashboards beyond the counts above.

## Owner decisions (2026-11-16)
1. Super Admin signs in on the same phone + password screen and is routed to the console.
2. More than one Super Admin allowed; the last active one can't be removed.
3. Unit Admins see platform actions on their own tenant in their audit trail.
4. Plan label = Trial / Active; Suspended is the tenant status only.
