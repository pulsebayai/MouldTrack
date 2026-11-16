# Intent: Plant masters
Author: Sidambara Raja (drafted by Claude) · Status: approved · Date: 2026-11-16
Roadmap item: 04-plant-masters · Release: R1 · Batch A (with 03; merges first) · Moves product metric: **Target visibility** (secondary), and enables Reading capture (05/06) and Issue resolution time (07).

## Problem
Nothing in the system describes the plant: there are no machines to assign, no products to make and no target to compare a reading against. Without a known target per machine, the "target vs actual" review (product metric: target visibility) is impossible and supervisors' output can't be judged in context (principle 3). Today targets live in people's heads or spreadsheets [Uncertain — owner said nothing is recorded systematically].

## Proposed outcome
A Unit Admin (web) maintains, for their tenant:
- **Site:** one per tenant in the pilot (name, timezone; the tenant's timezone by default). The model allows more later; the UI shows one.
- **Lines (optional grouping):** name only. A machine may belong to a line or to none; nothing is tracked per line (owner: tracking is per machine).
- **Machines:** code (unique per tenant), name, asset tag, make, model, controller, optional line, status (Active / Under maintenance / Retired, shown as text).
- **Products:** code (unique per tenant), description, unit of measure (default "pcs").
- **Benchmark targets:** **pieces per shift** for a machine × product, with an effective-from date (and optional effective-to). One product per machine per shift (owner), so a machine's target for a shift = the benchmark of the product it runs that shift. Changing a target creates a new version from a date; history is never overwritten (principle 2). Every create/edit/retire is audited.
- Supervisors can **read** machines, products and current targets of their tenant (needed by 05–07); only Unit Admins change them. (Restricting supervisors to assigned machines comes with 05 assignments.)

## Users & systems affected
Unit Admin (web: new "Plant" screens). Supervisor (read access only, no new screens). Postgres: new tenant-owned tables with RLS + pgTAP isolation tests; writes via RPC functions with audit (architecture rule). No Edge Functions, no external systems.

## Success metrics
- A Unit Admin sets up the pilot plant (1 site, its machines, products and a target for each machine-product pair in use) in **≤ 60 min** without a spreadsheet — timed on the staging checklist. [Baseline: impossible today]
- For any machine and date, the system returns exactly one current target per product (or "no target"), proven by tests including the day a target changes.
- 100 % of master-data changes produce an audit event (tests).

## Constraints
- Server decides: every rule (uniqueness, non-overlapping target periods, role checks) in Postgres; screens only render. Writes only through RPC functions with idempotent request ids and audit in the same transaction (02's D13 denial pattern).
- Tenant isolation: every new table carries `tenant_id` + RLS + a pgTAP cross-tenant test.
- Batch A: 04 owns the schema for site, line, machine, product, benchmark (split schema lock, logged exception); 03 owns tenant/platform tables. 04 merges first and gets the first hosted-dev proof.
- Targets are whole pieces (integer > 0). Dates are plant-local calendar dates (site timezone).

## Behaviour that must not change
Everything from 01–02 (sign-in, user admin, audit, isolation); the full suite stays green.

## Out of scope
- Shift-specific targets (e.g. a different target for a shorter night shift) and shifts themselves → 05. 04's target is "per shift" independent of which shift; see open question 1.
- Pieces-per-hour or cycle-time maths; target approval workflow (a UA's change takes effect; audit records who).
- Bulk import (CSV) of machines/products; machine downtime/maintenance tracking; multiple sites in the UI.

## Owner decisions (2026-11-16)
1. Shifts may differ in length → 04 stores one target per machine × product (pieces per shift); 05 adds an optional per-shift override.
2. A machine may run without a target; readings (06) show "No target set" and are not blocked.
3. Retiring hides a machine/product from pickers and keeps its history; a product with an active target can't be retired until the target is ended.
