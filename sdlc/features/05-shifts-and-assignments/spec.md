# Spec: Shifts and assignments
Intent: ./intent.md · Status: approved · Date: 2026-11-17

Terms: **UA**, **SUP** as before. **Shift occurrence** = (shift, shift date); shift date = plant date on which it starts; its window = [start, end) in the site timezone, end on the next day for overnight shifts. All 02/04 patterns apply: `pm_*`-style RPCs via `app._pm_authorise`, D13 denials, request ids tied to the RPC, append-only effective-dated history, audit registry, plant date on the server.

## User stories & acceptance criteria
**Shifts**
- **AC-1 Shift master.** A UA creates a shift: name (1–40, unique per site, case-insensitive), start and end time (HH:MM, 15-minute steps; end ≠ start; end < start = overnight). Duration is shown. A UA can rename and retire/reinstate. **Times can't change once the shift has any assignment** ("Retire it and create a new shift") — so past occurrences never change meaning. Audited `shift.*`.
- **AC-2 Occurrence maths.** `app.shift_window(shift, date)` returns the right UTC range for day and overnight shifts in the site timezone; `app.current_occurrences(at)` returns the occurrences running at a moment (an overnight shift that started yesterday is "current" this morning). Proven at boundaries (start minute, end minute, midnight, 23:59).

**Assignments**
- **AC-3 Recurring plan.** A UA assigns one active **supervisor** to one or more machines on a shift **from** a plant date ≥ today, optionally **until** a date. Each (shift, machine) has at most one supervisor per date; assigning a machine already covered on that shift replaces the previous owner from that date (the confirm dialog names who loses it). Ending = machine unassigned from that date. History is append-only. Audited `assignment.set|ended` (one row per call, listing machines).
- **AC-4 Cover for one occurrence.** For an occurrence that hasn't ended yet (including one running now), a UA moves selected machines to another active supervisor — or to "unassigned" — with a reason (1–200). Only that occurrence changes; the plan doesn't. A later cover for the same machine and occurrence replaces the earlier one (append-only, latest wins). Audited `assignment.covered`.
- **AC-5 Resolution.** `app.machine_owner(machine, shift, date)` = latest cover for that occurrence if any, else the plan version in force on that date, else null (unassigned). Proven for: plan only, plan change on day D, until-date, cover, cover then re-cover, cover to unassigned, overnight occurrence.
- **AC-6 Only active supervisors.** Assigning a UA, an inactive or must-change user, or another tenant's user is refused (validation `supervisor`). If an assigned supervisor is later deactivated, the board shows "Inactive supervisor" for their machines (still counted as assigned until the UA changes it).

**Per-shift targets**
- **AC-7 Override.** On a machine's targets panel a UA can set, for a product and a shift, a different pieces-per-shift target from a plant date ≥ today, or end the override (falls back to the base target). Append-only, effective-dated; ending cancels later scheduled overrides (04's R1 rule). Audited `target_override.set|ended`.
- **AC-8 Effective target.** `app.effective_target(machine, product, shift, date)` = the override in force, else `app.target_for(machine, product, date)`, else null. Same tenant/service-role rule as `target_for`.

**Views**
- **AC-9 Shift board (web, UA).** Pick a shift and a date (default: current or next occurrence): every non-retired machine with its owner, the source ("Plan" / "Cover: reason"), and **"Unassigned this shift"** machines grouped at the top with a count. Actions: assign, cover, end. 48dp, text labels, axe 0 serious/critical.
- **AC-10 My shift (SUP, Android + web Home).** Shows the current occurrence the supervisor owns machines in (or the next one today/tomorrow if none is running): shift name, window ("22:00 – 06:00"), and their machines (code, name, line). Machines moved away by a cover don't appear; machines covered to them do. Nothing assigned → "No machines assigned for your next shift". Reached from sign-in in ≤ 2 taps (Home itself).
- **AC-11 Visibility.** SUPs have **no** direct read on assignment tables; they see only their own resolved machines via `my_shift()`. UAs read everything of their tenant. Cross-tenant: nothing. SAs: nothing (022 picks up the new tables and RPCs automatically).
- **AC-12 Denials, idempotency, isolation** as 04 (SUP/must-change/suspended/SA writes → generic denial + audit; cross-tenant ids → denial; request id repeats return the first outcome).
- **AC-13 No regressions.** 01–04 (and 03 once merged) green.

## Functional requirements
- FR-1 RPCs: `pm_save_shift(id?, name, start, end)`, `pm_set_shift_retired(id, bool)`, `pm_assign(shift_id, supervisor_id, machine_ids[], from, until?)`, `pm_unassign(shift_id, machine_ids[], from)`, `pm_cover(shift_id, shift_date, machine_ids[], supervisor_id|null, reason)`, `pm_set_target_override(machine, product, shift, pieces, from)`, `pm_end_target_override(machine, product, shift, from)`.
- FR-2 Reads: tables under RLS for UAs; `public.shift_board(shift_id, date)` (UA only, security definer); `public.my_shift()` (any active member; returns only the caller's machines).
- FR-3 Functions for later features: `app.shift_window`, `app.current_occurrences`, `app.machine_owner`, `app.effective_target` (service-role or tenant-checked like `target_for`).

## Non-functional requirements
`my_shift()` ≤ 100 ms for 300 machines; `shift_board` ≤ 500 ms. Indexes on (tenant, shift, machine, effective_from desc, recorded_at desc) and (shift, shift_date, machine, recorded_at desc). Accessibility and privacy as before (no new personal data; supervisor names shown to UAs only).

## Data model changes (schema lock: 05's tables)
- `shift` (id, tenant_id, site_id, name, start_time, end_time, retired_at, …); composite FKs; unique (site_id, lower(name)).
- `assignment_version` (id, tenant_id, shift_id, machine_id, supervisor_id null = unassigned, effective_from date, recorded_by, recorded_at, request_id) — append-only.
- `assignment_cover` (id, tenant_id, shift_id, shift_date, machine_id, supervisor_id null, reason, recorded_by, recorded_at, request_id) — append-only.
- `target_override_version` (id, tenant_id, machine_id, product_id, shift_id, effective_from, pieces_per_shift null = override ended, recorded_by, recorded_at, request_id) — append-only.
- RLS: `shift` readable by all active members; the three version tables readable by UAs only. No client writes. Registry inserts for `shift.*`, `assignment.*`, `target_override.*`. 022 fixture rows for the four tables (additions only, per the architecture extension point).

## Existing code affected
`src/app/(app)/home.tsx` (My shift card for SUPs), plant screens (Shifts tab; per-shift overrides in the targets panel), `src/lib/plant.ts`, seed + fixtures-reset (shifts + assignments for orgs A, U; a covered occurrence), e2e fixtures, Maestro flow (new `my-shift.yaml`), 022 fixture block (additions).

## Backward compatibility & data migration
Additive. Without shifts, Home shows "No shifts set up yet" for SUPs; UAs see the Shifts tab empty state.

## UX flows & screens
- **Plant → Shifts** (UA web): list + form; retired filter.
- **Plant → Assignments** (UA web): shift + date pickers, board grouped Unassigned / by supervisor; multi-select machines → "Assign to…" (supervisor picker, from/until) or "Cover this shift…" (supervisor or Unassigned, reason).
- **Machine detail → Targets panel:** per product, base target plus a row per shift override ("Night: 900 pcs from 20 Nov") with set/end.
- **Home (SUP):** "My shift" card first; large touch targets; status text.

## Test strategy
| AC | Unit | DB (pgTAP) | API | Web e2e | Android |
|---|---|---|---|---|---|
| 1–2 | time input, duration | shift rules, time lock, `shift_window`/`current_occurrences` boundaries incl. overnight | — | shifts CRUD | — |
| 3–6 | multi-select, dialogs | plan/cover append-only, resolution cases (AC-5 list), supervisor validity, no backdating, cover only before occurrence end | SUP write denied + audit; SUP can't read tables | assign, cover, board updates | — |
| 7–8 | targets panel | override set/end/cancel, `effective_target` fallback, tenant rule | — | set/end override | — |
| 9 | board rendering | `shift_board` UA-only | — | board + axe | — |
| 10–11 | My shift card states | `my_shift` returns only own machines incl. cover in/out | other SUP sees nothing of mine | SUP Home card | `my-shift.yaml`: sign in → see machines |
| 12 | — | denials, idempotency, isolation, SA via 022 | — | — | — |
| 13 | full suite | full suite | full suite | full suite | nightly |

## Proposed architecture changes
1. **Shift occurrence model** (shift + shift date = start date; window in site tz) and ownership resolution "cover > plan > unassigned" via `app.machine_owner` — the contract for 06–09.
2. **Effective target** = per-shift override > base target (`app.effective_target`).
3. SUP access to planning data only through resolved functions (`my_shift`), never raw tables.
(05 doesn't hold the architecture lock while 03 is open; flagged for architecture.md at merge.)

## Risks & areas of concern
- Overnight and timezone maths (server-only; boundary tests).
- Shift time lock may surprise a UA who mis-typed a time after assigning; mitigation: clear message + "retire and recreate" flow keeps assignments easy to redo (copy assignments from the old shift — out of scope unless cheap).
- 03 is still open: shared files (seed, fixtures-reset, 022, home.tsx). 05 branches from main and rebases after 03 merges.

## Out of scope
Holiday calendars, weekday patterns, shift swaps, attendance, planned product per machine-shift (product is chosen at reading time in 06), copy-assignments tool, notifications.

## Owner decisions (2026-11-17)
1. The **supervisor picks the product** when recording the opening reading (06), defaulting to the last product run on that machine. 05's "My shift" lists machines without targets; 06 shows the effective target once the product is picked.
