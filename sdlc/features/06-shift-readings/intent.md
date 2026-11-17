# Intent: Shift readings
Author: Sidambara Raja (drafted by Claude) · Status: approved · Date: 2026-11-17
Roadmap item: 06-shift-readings · Release: R1 · Batch B (with 07; 06 merges after 07) · Moves product metrics: **Reading capture rate** (≥ 95 % of assigned machine-shifts with opening + closing readings within 30 min) and **Target visibility** (daily target vs actual without a spreadsheet).

## Problem
Production against target isn't measured per machine and shift. Nothing records the counter at the start and end of a shift, how many good and rejected parts came out, or how that compares with the target — so shortfalls are invisible and the Unit Admin's daily review needs a spreadsheet (or doesn't happen).

## Proposed outcome
- **Opening reading (supervisor, Android-first):** for each machine they own in the shift occurrence (05), the supervisor picks the **product** (defaults to the last product run on that machine — owner, 05 decision), enters the **opening counter**, optional **counter photo** (owner: optional), and submits. One opening per machine-shift.
- **Closing reading:** closing counter, **good** and **reject** quantities (owner: good + reject only in R1), optional photo, optional remarks. One closing per machine-shift.
- **Counter semantics vary by machine (owner):** each machine has a **counter unit** — *shots/cycles* (pieces = shots × cavities of the product's mould on that machine) or *pieces*. Cavities are set per machine × product by the Unit Admin (default 1).
- **Counter movement** = closing − opening (in the machine's unit) → converted to pieces. **Counter movement is not good output** (principle 5): good and reject are what the supervisor enters; the difference (movement pieces − good − reject) is shown as **"Unaccounted"**.
- **Rollover (owner: system records it):** if closing < opening and the machine has a **counter maximum**, the system records a rollover and computes movement across it; flagged "Rollover" for the Unit Admin. If no maximum is set, the reading is accepted and movement is marked **"Needs review"** (never guessed).
- **Late readings (owner):** accepted, **flagged "Late"** when submitted more than 30 min after the occurrence's start (opening) or end (closing). The reading-capture metric counts only on-time pairs.
- **Production summary** per machine-shift: product, effective target (05's `effective_target`), movement, good, reject, unaccounted, attainment % (good ÷ target), flags (late, rollover, needs review). Versioned calculation (`calc_version`) so later rule changes never rewrite history.
- **Unit Admin "Today" (web):** for the current and previous occurrence of each shift: every assigned machine with target vs actual, readings missing/late, flags; unassigned machines excluded (05 decision).
- **Corrections:** a reading is never edited; the supervisor (before the next occurrence starts) or a Unit Admin submits a **correction** with a reason, which supersedes the earlier value (append-only).

## Users & systems affected
Supervisor (Android + web), Unit Admin (web). Postgres: production_reading, production_summary (or a view), machine counter settings, cavities (tenant-owned, RLS, pgTAP, 022). Photos reuse 07's attachments/Storage.

## Success metrics
- Opening or closing reading for one machine captured in **≤ 60 s** (≤ 30 s without photo) on a mid-range Android phone (staging checklist).
- Reading capture rate and attainment computable for every assigned machine-shift from day one of the pilot (baseline for metric 1).
- The Unit Admin's "Today" view replaces the daily spreadsheet (owner confirms after week 1 of the pilot).

## Constraints
- Server decides (RPCs, D13, request ids, `_pm_authorise`, append-only readings, 022 coverage); only the machine's owner in that occurrence (or a Unit Admin) records its readings (05/07 rule: operational writes limited to assigned machines).
- Builds on 05 (occurrences, ownership, effective target) and 07 (attachments). **06's photo step waits for 07's attachments to merge.** Schema: 06's tables + new columns on 04's machine (counter unit, maximum) — split with 07 (disjoint), logged; 07 holds the architecture lock.
- No offline sync: local draft + retry.

## Behaviour that must not change
01–05 (and 07 once merged); 04's targets/05's overrides stay the target source.

## Out of scope
Rework, downtime events, scrap reasons, mid-shift product changes (one product per machine-shift — owner), PLC/OCR, dashboards and exports (09), notifications## Owner decisions (2026-11-17)
1. Optional **counter maximum** per machine; with it, closing < opening is recorded as a rollover; without it, the reading is accepted and movement is "Needs review".
2. A Unit Admin may record a reading on the supervisor's behalf; it is labelled "Entered by Unit Admin".
3. Supervisors can correct their readings until the next occurrence of that shift starts; after that only a Unit Admin can.
(Earlier answers: counter unit varies by machine; good + reject only; photo optional; late readings accepted and flagged.)
