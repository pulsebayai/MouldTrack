# Roadmap: MouldTrack
Updated: 2026-11-16 · Architecture lock: 02-tenancy-and-roles · Schema lock: 02-tenancy-and-roles

| # | Feature slug | One-line intent | Product metric | Depends on | Touches (entities / screens / shared code) | Arch change? | Batch | Release | Status |
|---|---|---|---|---|---|---|---|---|---|
| 01 | walking-skeleton | Expo app (Android + web) with sign-in, a tenant-scoped home screen, base tenant/membership schema + RLS, CI + regression workflow + evidence, deployed to dev | — | — | tenants, memberships, auth, app shell, CI | yes | — | R1 | shipped |
| 02 | tenancy-and-roles | Roles + RBAC; Unit Admin invites and deactivates supervisors; audit-event base; denied cross-tenant access is auditable (FR-02, AC-22) | enabler | 01 | users, memberships, audit_event, user-admin screens | yes | — | R1 | in-progress |
| 03 | tenant-console | Super Admin web console: register/activate/suspend tenants, create the first Unit Admin, plan status, platform audit; no routine access to tenant operational data (FR-01) | enabler (pilot + tenants 2–3) | 02 | tenants, platform admin screens, audit_event | no | — | R1 | planned |
| 04 | plant-masters | Unit Admin manages sites/lines, machines, products and benchmark targets with effective dates (FR-03). **Decides target basis + product changeover** | Target visibility | 02 | site, line, machine, product, benchmark, admin screens | no | — | R1 | planned |
| 05 | shifts-and-assignments | Shift master and schedules (incl. overnight), supervisor × machine assignments; supervisor sees only assigned work (FR-03, FR-04). **Decides supervisor:machine cardinality** | Reading capture | 04 | shift, shift_assignment, supervisor home | no | — | R1 | planned |
| 06 | shift-readings | Opening/closing counters, display photo to Storage, counter validation + rollover exception, good/reject entry, production summary calc, minimal Admin "today" list of target vs actual (FR-05, FR-10, AC-23). **Decides counter semantics** | Reading capture | 05 | production_reading, production_summary, attachment, storage, supervisor screens | no | — | R1 | planned |
| 07 | issue-lifecycle | Report, act on, assign, escalate, resolve and verify issues; append-only actions and ownership history (FR-11, FR-12, AC-20, AC-24) | Issue resolution time | 04 | machine_issue, issue_action, issue_ownership_history, attachment | no | — | R1 | planned |
| 08 | shift-handover-ack | Mandatory per-issue acknowledgement + declaration at shift opening, start blocked until complete, Admin exception, carry-forward (FR-06–09, FR-13, AC-16–19, AC-21) | Handover compliance | 06, 07 | shift_handover, ownership history, shift-open RPC, opening screen | no | — | R1 | planned |
| 09 | dashboards-reports | Full supervisor and Unit Admin dashboards with KPI calcs per PRD §7 (incl. supervisor performance adjusted for inherited issues); filters + CSV export (FR-14, FR-15) | Target visibility | 06, 07, 08 | read models/views, dashboard screens | no | — | R2 | planned |

Later: in-app notifications + overdue-acknowledgement alerts (FR-16) · detailed downtime events · maintenance role · iOS · push/WhatsApp · offline · regional languages · PLC/OCR (FR-17).

## Releases
Every release passes the Release & regression policy (architecture.md). Records and evidence live in `sdlc/releases/`.
- **R1 — Pilot unit end to end** (01–08): Super Admin console onboards the pilot tenant; masters, shifts, readings, issues and enforced handover in daily use. Starts the metric baselines; tenants 2–3 can be onboarded. · Status: planned
- **R2 — Visibility** (09 + notifications): full dashboards/reports, alerts. · Status: planned

## Batches
- 01-walking-skeleton shipped 2026-11-15 (PR #1). Evidence: PR CI run 43714726279, regression (dev) 43713831322, first scheduled nightly + this docs-only PR (AC-8) — see sdlc/features/01-walking-skeleton/plan.md.
- 02-tenancy-and-roles started 2026-11-16, **alone**: every other planned feature depends on it (directly or via 04), so no batch is possible. Holds architecture + schema locks. Checkpoint re-runs when 02 ships.
(Early candidates: 03 ∥ 04 and 06 ∥ 07; each pair conflicts only on the schema lock, so their migrations merge in order.)
