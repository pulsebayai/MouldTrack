# Spec: Plant masters
Intent: ./intent.md · Status: approved · Date: 2026-11-16

Terms: **UA** Unit Admin, **SUP** Supervisor. "Plant date" = calendar date in the site's timezone. Denials follow 02's D13 (committed `access.denied` + `{ok:false, code:'not_allowed'}`); validation/duplicate/guard errors raise P0001 with `detail {code, field?}`.

## User stories & acceptance criteria
**Site & lines**
- **AC-1 Site.** Given a UA whose tenant has no site, when they open Plant, they are asked for the site name (timezone defaults to the tenant's, editable from a fixed IANA list). One site per tenant in R1 (a second is refused). Name/timezone edits are audited (`site.created`, `site.updated`).
- **AC-2 Lines.** A UA can add a line (name 1–60, unique per site, case-insensitive), rename it, and archive it only when no non-retired machine uses it ("Move or retire its machines first"). Audited (`line.*`).

**Machines & products**
- **AC-3 Machine.** A UA creates/edits a machine: code (1–20 `[A-Za-z0-9-_/]`, unique per tenant, case-insensitive), name (1–80), asset tag, make, model, controller (each optional, ≤ 80), optional line, status Active / Under maintenance. Retire is a separate action (confirm dialog naming the machine). Retired machines are hidden from lists by default (filter "Show retired") and can't be edited except "Reinstate". Audited (`machine.created|updated|retired|reinstated`).
- **AC-4 Product.** A UA creates/edits a product: code (same rule, unique per tenant), description (1–120), unit of measure (default `pcs`, ≤ 10). Retire/reinstate as for machines. **A product with a current or future target can't be retired** ("End its targets first", lists the machines). Audited (`product.*`).

**Targets (pieces per shift)**
- **AC-5 Set target.** Given an active machine and an active product, when a UA sets *N pieces per shift* (integer 1–1 000 000) **effective from** a plant date ≥ today, then a new target version is recorded; it applies from that date until a later version. Earlier versions are never changed (append-only). Audited `target.set` with before/after.
- **AC-6 End target.** A UA can end a machine × product target from a plant date ≥ today (records an "ended" version). After that date the pair has no target. Audited `target.ended`.
- **AC-7 Current target.** For any machine, product and plant date, `app.target_for(machine, product, date)` returns exactly the pieces of the latest version with `effective_from ≤ date` (ties: latest recorded), or null if none / ended. Proven for: no versions, one version, change on day D (D-1 old, D new), end, re-set after end, same-day correction.
- **AC-8 No backdating.** An effective date before today (plant date) is refused ("Targets can't start in the past"). This protects history that readings (06) depend on.
- **AC-9 Target view.** For a machine, the UA sees each product with a target: current pieces, next scheduled change (if any) and history (date, pieces or "Ended", who). Machines without any target show "No target set".

**Access & integrity**
- **AC-10 Roles.** All active members of the tenant (UA and SUP) can read site, lines, machines, products and target versions of their tenant; only a UA can change them. A SUP (or a UA with a temporary password, or of a suspended tenant) calling any write RPC gets a generic denial and an `access.denied` audit row.
- **AC-11 Isolation.** Nobody reads or writes another tenant's plant data; cross-tenant ids in RPCs → generic denial + audit (reason `cross_tenant`). pgTAP per table.
- **AC-12 Idempotency.** Every write RPC takes a client `request_id`; a repeat returns the first outcome without a second row or audit event.
- **AC-13 Screens (web, UA).** Home shows **Plant** for UAs. Plant has tabs Machines · Products · Site & lines. Lists: search by code/name, filters (status, line), 25 per page, empty/loading/error states, status as text labels, 48dp targets, axe 0 serious/critical. Machine detail shows the targets panel (AC-9). SUPs opening `/plant` see "Not allowed".
- **AC-14 No regressions.** 01–02 suites stay green.

## Functional requirements
- FR-1 Writes only via RPC functions in `public` (`pm_*`), `security definer`, `search_path=''`, executable by `authenticated`; each authorises with `app.current_tenant_id()` / `app.current_role()` (so must-change and suspended users are denied), validates, writes, and audits in one transaction.
- FR-2 Clients read tables directly under RLS (select only).
- FR-3 `app.target_for(machine_id, product_id, plant_date)` (stable, security definer, tenant-checked) and a view `public.current_target` (per machine × product as of today's plant date) for later features.
- FR-4 Plant date = `(now() at time zone site.timezone)::date`, computed on the server only.

## Non-functional requirements
- Performance: lists ≤ 1 s for 300 machines / 1 000 products; `target_for` ≤ 5 ms with 50 versions per pair (index `(machine_id, product_id, effective_from desc, recorded_at desc)`).
- Accessibility and UX as 02 (labels, 48dp, text status). Privacy: no personal data added.

## Data model changes (schema lock: 04's tables — split with 03, logged)
- `site` (id, tenant_id, name, timezone, created_at, updated_at); unique `(tenant_id)` for R1.
- `line` (id, tenant_id, site_id, name, archived_at null, …); unique `(site_id, lower(name))` where not archived.
- `machine` (id, tenant_id, site_id, line_id null, code, name, asset_tag, make, model, controller, status `active|under_maintenance`, retired_at null, …); unique `(tenant_id, lower(code))`.
- `product` (id, tenant_id, code, description, uom default 'pcs', retired_at null, …); unique `(tenant_id, lower(code))`.
- `target_version` (id, tenant_id, machine_id, product_id, effective_from date, pieces_per_shift int null — null = ended, recorded_by, recorded_at, request_id) — **append-only** (UPDATE/DELETE revoked + trigger, like audit_event). Check `pieces_per_shift between 1 and 1000000` when not null.
- Composite FKs `(tenant_id, id)` so a machine/line/target can never reference another tenant's row.
- RLS on all five: select for active members of the tenant; no client insert/update/delete.
- `audit_event.action` check: replaced by a format rule `^[a-z_]+\.[a-z_]+$` (so 03 and later features add actions without altering the constraint again). Known actions documented in architecture.

## Existing code affected
`audit_event` constraint (02 migration, replaced by a new migration — never edited), `src/app/(app)/home.tsx` (Plant entry), `src/components/ui.tsx` (reuse; add Tabs if missing), `supabase/seed.sql`, `scripts/fixtures-reset.ts` (fixture plant for orgs A, B, U), `e2e/web/fixtures.ts`. All covered by 01–02 tests.

## Backward compatibility & data migration
Additive tables. Existing tenants (fixtures only) get no site until a UA creates one; seed/fixtures create one for e2e tenants. The audit constraint change only widens what is allowed.

## API / interfaces
RPCs (all `(request_id uuid, …) → jsonb {ok, id?} | {ok:false, code}`): `pm_save_site(name, timezone)`, `pm_save_line(id?, name)`, `pm_archive_line(id)`, `pm_save_machine(id?, code, name, asset_tag?, make?, model?, controller?, line_id?, status)`, `pm_set_machine_retired(id, retired bool)`, `pm_save_product(id?, code, description, uom)`, `pm_set_product_retired(id, retired bool)`, `pm_set_target(machine_id, product_id, pieces, effective_from)`, `pm_end_target(machine_id, product_id, effective_from)`. Client wrapper `src/lib/plant.ts` maps errors to fields (like `src/lib/api.ts`).

## UX flows & screens
- **Plant** (web, UA): tabs; list → detail/edit (dialog on wide, page on narrow). Machine detail: fields + **Targets** panel: per product row "Current: 1 200 pcs/shift · from 18 Nov · Next: 1 300 from 1 Dec", actions Set target / End target; "Add product target" picker (active products only). History list below.
- First visit with no site: a single "Set up your site" form, then tabs.
- States: empty ("No machines yet — add your first machine"), loading, error + retry, field errors from the server.

## Test strategy
| AC | Unit (Jest) | DB (pgTAP) | Web e2e (Playwright) |
|---|---|---|---|
| 1–4 | form validation, error mapping | each `pm_*` success + audit, uniqueness, retire/archive guards | create site, line, machine, product; retire/reinstate |
| 5–8 | date/number input | append-only, `target_for` cases (AC-7 list), no backdating, plant-date maths incl. timezone edge (23:30 IST) | set, change, end target; history shows |
| 9 | targets panel rendering | — | machine detail targets |
| 10–12 | — | role/must-change/suspended denials + audit, cross-tenant per table, idempotent repeats | SUP sees Not allowed |
| 13 | screen tests | — | lists, filters, paging, axe |
| 14 | full suite | full suite | full suite |
- Mutating e2e runs in `e2e org U`; A/B get read-only fixture plants for isolation tests. No Android flow changes (no supervisor screens). No new smoke tests (all write data).
- **Regression joins:** all of the above; `target_for` cases are the contract for 06.

## Proposed architecture changes
1. `audit_event.action` becomes a format rule instead of a fixed list (owned by 04, merged first; 03 relies on it).
2. Rule: master/config history that later calculations depend on is **append-only with effective dates** (target_version) and never backdated; reads go through `app.target_for`.
3. Composite `(tenant_id, id)` foreign keys for every tenant-owned child table (pattern for later features).
(04 does not hold the architecture lock; these are flagged for architecture.md and applied at merge on main.)

## Risks & areas of concern
- **Plant-date maths** around midnight and timezone — mitigated by server-only computation + pgTAP edge cases.
- Seed/fixtures and Home are also edited by 03 → small merge conflicts; 04 merges first.
- "No backdating" may annoy during the very first setup (wanting targets "from yesterday"); readings don't exist yet, so today is fine. Revisit if the owner needs corrections of past targets — that would be a separate, audited correction flow.

## Out of scope
Per-shift target overrides (05), shifts, assignments, readings; bulk import; multiple sites in UI; target approval workflow; Android screens.
