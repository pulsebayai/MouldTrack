# Spec: Shift handover and acknowledgement
Intent: ./intent.md · Status: draft · Date: 2026-11-18

Terms: **occurrence**, **owner** (05), **issue lifecycle** (07), **opening reading** (06). **Inherited issue** for supervisor S in occurrence O = an issue in status Open / In progress / Resolved-awaiting-verification on a machine S owns in O, reported before S's **handover start** (= O's start, or the cover time if S got the machine by a later cover). **Deadline** = handover start + the tenant's overdue minutes (default 60). All prior patterns apply (`_pm_authorise`, D13, request ids tied to the RPC, append-only + trigger, registry, 022 fixture additions, `allowed_actions`, no client-supplied time in public reads, bounded lists).

## User stories & acceptance criteria
**Checklist**
- **AC-1 Checklist.** From 30 min before O's start until O's end, S sees a checklist for O: every inherited issue on their machines (grouped by machine) with description, priority, reported time, previous owner, last 3 actions, status, escalation flag, and the latest **outgoing note**. Plus a non-blocking **"Verify this fix"** section (07's `issue_can_verify` for S). An issue that gets closed/resolved before S acknowledges it drops out (no longer required).
- **AC-2 Acknowledge.** S acknowledges an inherited issue (optional remark ≤ 200): appends an acknowledgement, makes S the **accountable owner** (07 ownership history, source `handover`; no row if S already owns it), appends an issue action "Acknowledged at handover". Audited `handover.acknowledged`.
- **AC-3 Refuse → escalate.** S refuses an issue with a reason (1–200): appends a refusal, escalates the issue (07, owner unchanged), and the issue counts as **exception pending** for O. Audited `handover.refused`.
- **AC-4 Declaration.** When every inherited issue is acknowledged or refused, S makes the declaration (fixed text, version 1): one per (S, O). With no inherited issues the declaration is a single tap. Audited `handover.declared`. A refusal does **not** block the declaration (owner decision b).
- **AC-5 Opening block.** `rd_opening` (06) by a SUP is refused with guard `handover_pending` ("Complete your handover checklist first") until S has declared for O. A UA entering on S's behalf is not blocked (the occurrence then shows "No declaration" and is non-compliant).
- **AC-6 Covers.** A machine S receives by a cover after O started adds its inherited issues to S's checklist at the cover time, and requires a new declaration covering them (the earlier declaration stays; S declares again). Deadline counts from the cover time.

**Unit Admin**
- **AC-7 Exception.** For an exception-pending issue in O, a UA records an exception: reason (1–200) **and** the owner — another active SUP (07 reassign) or explicitly "keep with <refusing supervisor>". Clears exception pending for O. Audited `handover.exception`.
- **AC-8 Overdue setting.** A UA sets the tenant's overdue minutes (15–480, default 60). Audited `handover.setting_updated`. Changes apply to occurrences starting afterwards (the value is snapshotted when the checklist first opens for O).
- **AC-9 UA alerts.** UA Home/Issues alerts gain **Handover**: exceptions pending (oldest first) and overdue acknowledgements (supervisor, machine, issue, minutes overdue); ≤ 5 on Home + "View all" (07's bounded pattern); refresh on focus + 60 s.

**Outgoing note & carry-forward**
- **AC-10 Outgoing note.** The owner of a machine in an occurrence may add a note (1–300) to an unresolved issue on that machine until 2 h after their occurrence ends; the latest note per issue is shown in the next checklists. Append-only. Audited `handover.note_added`.
- **AC-11 Carry-forward.** No shift change closes, resolves or hides an issue: an unresolved issue appears in every following occurrence's checklist until closed (pgTAP across day, overnight and a cover).

**Metric & integrity**
- **AC-12 Compliance.** `app.handover_compliance(tenant, from, to)` per (S, O) for occurrences that have ended: **compliant** = declared before the deadline, every inherited issue acknowledged before the deadline or refused with an exception recorded; **non-compliant** otherwise (reasons: no declaration, late, exception never recorded); plus the count of **overdue acknowledgements**. Machine-occurrences that were unassigned are excluded.
- **AC-13 Who.** Only S (for their own O) acknowledges, refuses and declares; only UAs record exceptions and settings; other SUPs, must-change/suspended users and SAs → generic denial + audit. Cross-tenant ids → denial.
- **AC-14 Screens.** SUP (Android + web): Home shows "Handover: N to acknowledge" before readings; checklist screen (issue cards with Acknowledge / Can't accept, notes, the declaration button enabled when ready, Verify section); My shift's opening actions stay disabled until declared. UA (web): Handover alerts, exception dialog (reason + owner), setting in Plant → Site & lines. 48dp, text labels, axe 0 serious/critical.
- **AC-15 No regressions.** 01–07 (and 06 once merged) green.

## Functional requirements
- RPCs `public.ho_*`: `ho_acknowledge(issue, shift, date, remark?)`, `ho_refuse(issue, shift, date, reason)`, `ho_declare(shift, date)`, `ho_add_note(issue, shift, date, note)`, `ho_exception(issue, shift, date, reason, owner_id)`, `ho_set_overdue(minutes)`. `rd_opening` gains the declaration check (additive redefinition in 08's migration).
- Reads (no client time): `public.handover_checklist()` (caller's running/next occurrences, like `my_shift`), `public.handover_alerts()` (UA). App-only: `app.handover_checklist_at`, `app.handover_compliance`.

## Non-functional requirements
Checklist for 20 issues ≤ 500 ms; `handover_alerts` ≤ 500 ms for 300 machines. No new personal data.

## Data model changes (schema lock: 08 after 06 releases it)
- `handover_setting` (tenant_id pk, overdue_minutes default 60).
- `handover_session` (append-only): tenant, shift_id, shift_date, supervisor_id, opened_at (first checklist view), overdue_minutes snapshot, handover_start.
- `issue_acknowledgement` (append-only): tenant, issue_id, shift_id, shift_date, supervisor_id, kind `acknowledged|refused`, remark/reason, at, request_id.
- `handover_declaration` (append-only): tenant, shift_id, shift_date, supervisor_id, text_version, covered_issue_ids, at, request_id.
- `handover_exception` (append-only): tenant, issue_id, shift_id, shift_date, ua_id, reason, owner_id, at.
- `handover_note` (append-only): tenant, issue_id, author_id, shift_id, shift_date, note, at.
- 07's ownership-history source `handover` (already allowed); registry `handover.*`; 022 fixture additions.

## Existing code affected
06's `rd_opening` (additive check), 07's alerts card + Issues alerts tab (Handover section), Home (SUP handover banner), My shift card (opening disabled state), seed + fixtures-reset, 022, Maestro (`handover.yaml`).

## UX flows & screens
- **SUP:** sign in → Home banner "Handover: 3 to acknowledge" → checklist → per issue Acknowledge (remark optional) / Can't accept (reason) → Declaration → readings unlocked. Verify section below.
- **UA:** Home alerts → Handover → exception dialog (reason, owner picker: active SUPs + "Keep with <name>") → done.

## Test strategy
| AC | Unit | DB (pgTAP) | API | Web e2e | Android |
|---|---|---|---|---|---|
| 1–4 | checklist states | inherited set (before start, cover time, reported during O excluded, closed drops out), ack/refuse effects incl. ownership row, declaration rules | other SUP denied | checklist → declare | `handover.yaml`: acknowledge + declare → opening enabled |
| 5–6 | disabled opening | `rd_opening` guard; UA bypass flag; cover adds items + re-declare | SUP opening refused before declaring | opening blocked then allowed | (same flow) |
| 7–9 | dialog, alerts | exception (reason + owner, keep-with), setting snapshot, alerts content/order, bounded | SUP denied exception | UA exception flow + axe | — |
| 10–11 | note form | notes window, latest note, carry-forward across day/overnight/cover | — | note shown in next checklist | — |
| 12 | — | compliance cases: compliant, late, no declaration, refusal without exception, unassigned excluded, overdue count | — | — | — |
| 13–15 | full suite | denials, isolation, idempotency, 022 | full suite | full suite | nightly |

## Proposed architecture changes (flag; 08 may hold the lock after 06)
1. **Handover model:** checklist derived from 05 ownership + 07 issue state; acknowledgements, refusals, declarations, exceptions and notes append-only; ownership transfer source `handover`.
2. **Cross-feature gate:** a feature may add a server-side precondition to another feature's write RPC (here 06's `rd_opening`) only by additive redefinition in its own migration, with the earlier feature's tests unchanged.
3. **Handover compliance** as the single definition of product metric 2.

## Risks & areas of concern
- Gating 06's opening touches the reading-capture metric: a supervisor who never declares can't record readings → both metrics show the gap (intended); UA on-behalf entry is the escape hatch.
- Time windows (cover-time deadlines, overnight) → `_at` helpers with explicit times in tests.
- Shared files with 06/07 (alerts card, Home, My shift card, seed, fixtures-reset, 022) → 08 branches after 06 merges.

## Out of scope
Push/SMS; shift swaps; the compliance dashboard and exports (09); editing acknowledgements.
