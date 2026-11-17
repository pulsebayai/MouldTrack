# Intent: Issue lifecycle
Author: Sidambara Raja (drafted by Claude) · Status: approved · Date: 2026-11-17
Roadmap item: 07-issue-lifecycle · Release: R1 · Moves product metric: **Issue resolution time** (median report → close, by priority; for High/Critical, close = verified); enables **Handover compliance** (08 hands these issues over).

## Problem
Machine problems reported in one shift are lost or quietly dropped, nobody is visibly accountable, and a stopped machine may go unnoticed by the Unit Admin until the shift report — if there is one. Today nothing is recorded systematically [Certain — owner].

## Proposed outcome
- **Report (supervisor, Android-first; also web):** on a machine they own this shift (05's `machine_owner`), a supervisor reports an issue: category, priority (Low / Medium / High / Critical), description, impact incl. **"Machine stopped? yes/no"**, optional **photo evidence**. A stopped machine **forces priority Critical** (owner).
- **Categories:** a starter list (Mechanical, Electrical, Mould/Tool, Material, Quality, Safety, Other); each Unit Admin can add, rename and retire categories for their tenant (owner: option b).
- **Accountable owner is always a supervisor** (owner): initially the reporter. A free-text **technical assignee** (e.g. "Maintenance – Ravi", "Vendor: XYZ") records who is fixing it.
- **Lifecycle (PRD §5.4, owner 2026-11-17):** Open → In progress → **Resolved** → **Closed**. Actions are appended (note, status change, photo). The accountable supervisor **resolves** (resolution notes required).
  - **Low / Medium:** resolving closes the issue.
  - **High / Critical:** the issue waits for **verification by the supervisor who owns the machine on a later shift** (any occurrence that starts after the resolve time; never the resolver). They **confirm** (→ Closed) or **reject** with a reason (→ back to In progress, and they become the accountable owner). If no later-shift supervisor is assigned, a Unit Admin can verify instead.
  - **Escalate** (reason required) flags the issue to the Unit Admin and keeps the owner; the Unit Admin can **reassign** the accountable owner to another supervisor (reason, audited). A Unit Admin can **reopen** a closed issue with a reason.
- **History is append-only:** actions and ownership history are never overwritten; the full history stays visible after close.
- **Alerts to the Unit Admin (owner):** every open **High or Critical** issue (incl. every stopped machine, which is always Critical) is shown as an **alert** on the Unit Admin's Home and Issues screens (count + list, stopped machines first, newest first) until it is closed. When a High/Critical issue is **closed**, the Unit Admin is informed: it appears in a "Recently closed" list (last 7 days) with the resolution notes. In-app only in R1; push/SMS later.
- **Lists:** supervisors see issues on machines they own this shift plus issues they own; Unit Admins see all of the tenant's issues with filters (status, priority, category, machine, escalated, stopped).
- **Shared photo storage (owner: option 4 recommendation):** tenant-separated Storage for photos with metadata, checksum and size limits; 06 reuses it for counter photos.
- 08 builds on this: open and awaiting-verification issues carry forward to the next shift opening (08 will put "verify this fix" into the opening checklist); 07 does not change ownership at shift change.

## Users & systems affected
Supervisor (Android + web), Unit Admin (web). Postgres: issue, issue_action, issue_ownership_history, issue_category, attachment (tenant-owned, RLS, pgTAP, 022 coverage). **Supabase Storage** (new; bucket policies by tenant). Audit registry actions `issue.*`, `issue_category.*`, `attachment.*`.

## Success metrics
- A supervisor reports an issue with a photo in **≤ 60 s** on a mid-range Android phone (staging checklist).
- A High/Critical (incl. stopped-machine) issue appears in the Unit Admin's alert list within **≤ 60 s** of reporting, and its closure in "Recently closed" within ≤ 60 s (refresh interval; test).
- Issue resolution time is computable for 100 % of closed issues (report and close timestamps always present) — the R1 baseline for the metric.
- 100 % of lifecycle actions audited; history never changes (tests).

## Constraints
- Server decides (lifecycle transitions only via RPCs; D13 denials; idempotent request ids; `_pm_authorise` family; 022 coverage incl. a separate "Super Admin reads 0 Storage objects" test — architecture).
- **Architecture lock: 07** (Storage + attachment model is new and shared with 06). Schema: 07's tables, split with 05 while 05 is open (disjoint; logged). 07 merges after 05.
- Photos: JPEG/PNG/WebP, ≤ 5 MB after client-side compression, stored under `tenant/<tenant_id>/…`; never public URLs (signed URLs, short expiry). Free-tier Storage quota (1 GB) — size limits matter.
- Connectivity: local draft + retry, no offline sync (architecture).

## Behaviour that must not change
01–05 behaviour; full suite green.

## Out of scope
Push/SMS/email alerts; detailed downtime events (start/end times); maintenance role/accounts; SLA timers and overdue rules (R2 with notifications); shift handover/acknowledgement (08); counter photos (06 reuses the storage); issue analytics (09).

## Owner decisions (2026-11-17)
1. The accountable supervisor resolves (resolution notes required). Low/Medium close on resolve. **High/Critical are verified by the supervisor who owns the machine on a later shift** (not the resolver; a Unit Admin may verify if no later-shift supervisor is assigned); rejecting returns the issue to In progress with the verifier as owner. High/Critical issues alert the Unit Admin while open, and their closure is shown to the Unit Admin ("Recently closed"). A Unit Admin can reopen with a reason.
2. A supervisor may report on a machine they don't own this shift; the machine's current owner becomes accountable (the reporter if the machine is unassigned).
3. Photos are visible to everyone who can see the issue.
