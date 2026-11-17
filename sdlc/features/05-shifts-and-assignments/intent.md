# Intent: Shifts and assignments
Author: Sidambara Raja (drafted by Claude) · Status: draft · Date: 2026-11-17
Roadmap item: 05-shifts-and-assignments · Release: R1 · Moves product metric: **Reading capture rate** (the denominator — "assigned machine-shifts" — is defined here) and **Handover compliance** (08 needs to know who owns each machine-shift).

## Problem
There is no notion of a shift or of who is responsible for which machine when. Without that, the reading-capture metric has no denominator, a supervisor can't be shown "your machines this shift", accountability at handover (08) has no owner to hand over from or to, and a shorter night shift is judged against a full-shift target.

## Proposed outcome
A Unit Admin (web) maintains:
- **Shifts:** name (e.g. Morning), start and end time in the site's timezone, active/retired. Overnight shifts (end before start, e.g. 22:00–06:00) are supported; the **shift date** is the plant date on which the shift starts. The same pattern applies every day (owner); no calendar of holidays in R1.
- **Recurring assignments (mostly recurring — owner):** "supervisor S covers machines M1…Mn on shift X from date D (until changed / until date E)". One supervisor may cover **many machines** in a shift (owner); a machine has **at most one** responsible supervisor per shift occurrence.
- **Day-level reassignment (owner):** for one shift occurrence (date + shift) the Unit Admin can move machines to another supervisor (cover for absence) with a reason. The recurring plan is unchanged; the change is audited.
- **Per-shift target override (owner):** for a machine × product the Unit Admin can set a different pieces-per-shift target for a specific shift (e.g. shorter night shift), effective-dated and append-only like 04's targets. The effective target for a machine-shift = the shift override if present, else 04's target.
- **Supervisor view (Android + web):** Home lists "My shift today": the current or next shift occurrence with the machines they are responsible for, and each machine's effective target (or "No target set").
- A server function answers, for any date + shift: which supervisor owns each machine (recurring plan + day overrides), and the effective target — used by 06–09.

## Users & systems affected
Unit Admin (web: Shifts and Assignments screens), Supervisor (Android/web: Home "My shift today"). Postgres: new tenant-owned tables with RLS + pgTAP; writes via `pm_*`-style RPCs with audit (registry actions `shift.*`, `assignment.*`, `target_override.*`).

## Success metrics
- A Unit Admin sets up the pilot's shifts and recurring assignments for all machines in ≤ 30 min (staging checklist).
- For every date + shift, every machine resolves to exactly one supervisor or "unassigned" (tests incl. overnight shifts, an override, a plan change on day D).
- A supervisor opens the app and sees their machines for the current shift in ≤ 2 taps (Android flow).

## Constraints
- Server decides; same patterns as 02/04 (RPCs, D13 denials, request ids, append-only/effective-dated history, no backdating, audit registry).
- Overnight shifts and the plant timezone (site) are computed on the server only.
- Schema lock: 05's tables only (03 still holds its share until it merges; disjoint tables → split, logged). No architecture lock needed unless open question 1 changes RLS on 04's tables.

## Behaviour that must not change
01–04 behaviour; 04's targets remain the default when no override exists.

## Out of scope
Holiday calendars and day-of-week patterns; shift swaps requested by supervisors; attendance; readings (06), issues (07), handover (08); notifications.

## Open questions (resolve before the spec)
1. **What can a supervisor see?** Recommendation: master data (machines, products, targets) stays readable by every tenant member as today; 05 restricts **shifts' assignments and the "my machines" list** to the supervisor's own, and 06/07 restrict operational writes (readings, issues) to assigned machines. Alternative: hide unassigned machines from supervisors entirely (stricter; changes 04's read rules).
2. **During cover, does the original supervisor still see the moved machines for that shift?** Recommendation: no — only the covering supervisor sees and owns them for that occurrence (one accountable person).
3. **Unassigned machines:** if a machine has no supervisor for a shift, should it count in the reading-capture metric (as "missed") or be excluded? Recommendation: excluded, but listed for the Unit Admin as "Unassigned this shift".
