# Product: MouldTrack
Owner: Sidambara Raja · Mode: new · Status: approved · Updated: 2026-11-13
Source requirements: `Requirment desciption/MouldTrack_High_Level_PRD.docx` (v1.0), `MouldTrack_Interactive_Prototype.html` (UI reference only)

## Vision
Every machine-shift in a plastic moulding unit has a recorded opening and closing reading, a known target, and a named, accountable supervisor, so that production gaps and machine issues are visible the same day and can never be lost at a shift change.

## Target users
- **Supervisor** (primary, phone on the factory floor): records readings, acknowledges inherited issues, reports issues.
- **Unit Admin** (web/tablet): configures plant masters, targets, shifts and assignments; watches dashboards; handles escalations.
- **Platform Super Admin** (web): onboards and suspends manufacturing tenants. No routine access to tenant operational data.
- Maintenance user: future extension, not in R1–R3.

## Core problem
- **Pain:** production against target per machine/shift isn't measured reliably. Machine issues reported in one shift are lost or quietly dropped at handover, so nobody is accountable. Inherited problems get blamed on the incoming supervisor.
- **Current workaround:** [Certain — owner] nothing is recorded systematically today. Production against target, handovers and issue follow-up are untracked.
- **Cost:** unseen shortfalls and downtime, repeat breakdowns, disputes over who is accountable.

## Product metrics
No data exists today, so the baseline for metrics 1–2 is effectively 0 and their targets are absolute. The baseline for metric 3 = the first 4 weeks of the R1 pilot.
1. **Reading capture rate:** % of assigned machine-shifts with both opening and closing readings recorded within 30 min of the shift boundary. Target ≥ 95%.
2. **Handover compliance:** % of shift openings where every inherited issue is individually acknowledged (or covered by an Admin exception) before the shift starts. Target ≥ 98%. Overdue acknowledgements are reported separately.
3. **Issue resolution time:** median time from report to verified close, split by priority. Target set after the 4-week pilot baseline (e.g. −30% by end of R2).
- Secondary: **Target visibility.** The Unit Admin produces the daily target-vs-actual review from the app with no spreadsheet.

## Principles
1. **The server decides.** All permissions, tenant isolation, validation and handover rules are enforced in the database or backend. The client only renders them.
2. **History is append-only.** Ownership, acknowledgement and audit records are never overwritten. A correction is a new event.
3. **Accountability with context.** Never judge a supervisor on raw output. Inherited issues and the assigned target are always shown next to the numbers.
4. **Floor-first UX.** Large touch targets, as few steps as possible, and a reading captured in under a minute. Status is never shown by colour alone.
5. **No inferred data.** Counter movement is not good output, and a photo is not a reading, unless that has been verified for the machine.

## Non-goals (MVP)
PLC/SCADA/IoT integration and telemetry · OCR/AI reading of counters · predictive maintenance and advanced OEE · payroll/HR/attendance/inventory/ERP · guaranteed offline sync · iOS app (Android first) · languages other than English.

## Current state
Greenfield. Requirements and a browser prototype exist. No code, no repo. R1 = one pilot unit end to end, including the Super Admin console; 2–3 tenants committed afterwards; no hard go-live date.
