# Spec: Shift readings
Intent: ./intent.md · Status: approved · Date: 2026-11-17

Terms: **occurrence** (05), **owner** = `app.machine_owner(machine, shift, date)`, **boundary** = occurrence start (opening) / end (closing). All prior patterns apply (`_pm_authorise`, D13, request ids tied to RPC, append-only + trigger incl. service_role, registry, composite FKs, 022 fixture additions, write RPCs use `now()`, read helpers take `p_at`).

## User stories & acceptance criteria
**Machine counter settings (UA, web)**
- **AC-1 Counter unit and maximum.** On a machine a UA sets **counter unit** (Pieces | Shots/cycles; default Pieces) and an optional **counter maximum** (integer ≥ 9). The unit can't change once the machine has any reading ("Readings already use this unit"); the maximum can change (affects only readings submitted afterwards). Audited `machine_counter.updated`.
- **AC-2 Cavities.** For a Shots machine a UA sets **cavities** per product (integer 1–256, default 1 when unset), effective from a plant date ≥ today, append-only (04's target pattern incl. "end means end"). `app.cavities_for(machine, product, date)` → cavities or 1. Audited `cavities.set`.

**Readings (SUP on Android/web; UA on web on behalf)**
- **AC-3 Opening.** The owner of the machine in an occurrence (or a UA) submits the opening: **product** (active; default = product of the machine's latest closing or opening reading), **counter** (integer ≥ 0), optional photo, optional remarks. Allowed from 30 min before the occurrence start until its end. One current opening per machine-occurrence (a second one is a correction, AC-6). Audited `reading.opening`.
- **AC-4 Closing.** After an opening exists, the owner (or a UA) submits the closing: **counter** (integer ≥ 0), **good** and **reject** (integers ≥ 0), optional photo, remarks. Allowed from the opening until 12 h after the occurrence end. Audited `reading.closing`.
- **AC-5 Late flag.** A reading submitted more than **30 min after its boundary** (opening: start; closing: end) is accepted and flagged **Late**; the flag is stored with the reading, never recomputed.
- **AC-6 Corrections.** A reading is never changed. A correction (same machine-occurrence-kind, reason 1–200) supersedes the current one: the SUP owner may correct until the **next occurrence of that shift starts**; a UA may correct any time. The superseded reading stays in history. The occurrence keeps the **Late** flag of its earliest submission (correcting a typo later doesn't make it late). Audited `reading.corrected`.
- **AC-7 Entered by Unit Admin.** A reading submitted by a UA is labelled "Entered by Unit Admin" (stored).
- **AC-8 Who.** Only the occurrence's owner or a UA; another SUP, a SUP for an unassigned machine, must-change/suspended users, SAs → generic denial + audit. An unassigned machine-occurrence can only be recorded by a UA.

**Calculation**
- **AC-9 Summary.** When a closing exists (or is corrected), a **production summary** row is appended with `calc_version = 1` and a snapshot of its inputs: product, unit, cavities, counter maximum, opening, closing, effective target (05's `effective_target`), good, reject. Derived:
  - movement (units) = closing − opening if ≥ 0;
  - if closing < opening and a maximum is set → **Rollover**: (max + 1 − opening) + closing;
  - if closing < opening and no maximum → movement null, flag **Needs review**;
  - movement pieces = movement × cavities (Shots) or movement (Pieces);
  - **unaccounted** = movement pieces − good − reject (null if movement null);
  - **attainment** = good ÷ target × 100 (null if no target → "No target set").
  The latest summary per machine-occurrence is current; older ones stay (versioned; a rule change in a later feature adds `calc_version = 2` rows, never rewrites).
- **AC-10 Proven cases.** pgTAP for: normal; zero movement; rollover with max; closing < opening without max; Shots × cavities (cavity change effective on the date); no target; override target (05); correction of opening then closing; good + reject > movement (negative unaccounted, flag **Over-reported**).

**Views**
- **AC-11 Supervisor flow.** My shift lists each machine with its reading state: **Opening due / Opening done (time, Late?) / Closing due / Closed (good, target, attainment)**. Tapping opens the opening or closing form; after closing, the summary (target vs good, unaccounted, flags) is shown. Local draft kept until submitted.
- **AC-12 Unit Admin Today (web).** For each shift, the current and previous occurrence: every **assigned** machine (unassigned excluded) with owner, product, target, opening and closing status (missing / on time / late), movement, good, reject, unaccounted, attainment, flags (Late, Rollover, Needs review, Over-reported, Entered by UA). Totals per occurrence: target, good, attainment, readings on time / expected. Refresh on focus + 60 s.
- **AC-13 Capture metric function.** `app.reading_capture(tenant, from_date, to_date)` returns expected assigned machine-occurrences and those with **both** readings on time — the definition of product metric 1 (09 builds the report).
- **AC-14 Photos.** Optional counter photo on opening/closing via 07's attachments (entity type `production_reading`); visible to whoever can see the reading (owner in that occurrence, UAs). SA sees nothing (022 + 07's Storage test extended).
- **AC-15 Visibility & isolation.** SUPs see readings of machine-occurrences they own (incl. past ones they owned); UAs all; cross-tenant nothing; SA nothing. Denials, idempotency as before.
- **AC-16 No regressions.** 01–05, 07 green.

## Functional requirements
- RPCs `public.rd_*`: `rd_set_machine_counter(machine, unit, max)`, `rd_set_cavities(machine, product, cavities, from)`, `rd_end_cavities(machine, product, from)`, `rd_opening(machine, shift, date, product, counter, remarks?)`, `rd_closing(machine, shift, date, counter, good, reject, remarks?)`, `rd_correct(reading_id, …, reason)`, attachments via 07's `iss_attachment_*`-style begin/commit for entity `production_reading` (07 provides the generic helper; 06 adds the entity type).
- Reads: `public.reading_state(p_at)` (SUP: their machines in My shift occurrences, with state + last product default), `public.reading_detail(machine, shift, date)`, `public.today_board(p_at)` (UA only).

## Non-functional requirements
Reading in ≤ 30 s without photo / ≤ 60 s with (staging). `today_board` ≤ 1 s for 300 machines × 3 shifts. No personal data added.

## Data model changes (schema lock: 06's share, split with 07, logged)
- `machine` + `counter_unit` (enum `pieces|shots`, default pieces), `counter_max bigint null` — new columns on 04's table, changed only via `rd_set_machine_counter`.
- `cavity_version` (append-only, effective-dated; null = ended → default 1).
- `production_reading` (append-only): id, tenant_id, machine_id, shift_id, shift_date, kind `opening|closing`, product_id (opening), counter_value, good, reject (closing), remarks, late, entered_by_ua, supersedes_id, correction_reason, recorded_by, recorded_at, request_id. Composite FKs.
- `production_summary` (append-only): one row per calculation with `calc_version`, input snapshot, derived values, flags, `reading_ids`.
- Registry: `machine_counter.updated`, `cavities.set|ended`, `reading.opening|closing|corrected`.

## Existing code affected
My shift card (reading state + actions), Home (UA Today entry), Plant machine detail (counter settings + cavities), seed + fixtures-reset, 022 fixture block, 07's attachment entity types (after 07 merges), Maestro (`opening-closing.yaml`).

## Backward compatibility & data migration
Additive; existing machines default to Pieces with no maximum.

## UX flows & screens
- **SUP (Android):** My shift → machine → **Opening**: product chips (default selected), big numeric counter field, "Add photo (optional)", Submit. **Closing**: counter, good, reject (numeric), remarks, photo, Submit → summary card. Late/rollover/needs-review shown as text labels.
- **UA (web):** Today board (per shift: current + previous occurrence tables); Plant → machine → "Counter" panel (unit, maximum, cavities per product).

## Test strategy
| AC | Unit | DB (pgTAP) | API | Web e2e | Android |
|---|---|---|---|---|---|
| 1–2 | forms | unit lock, max change, cavities append-only/end/`cavities_for` | — | counter panel | — |
| 3–8 | forms, drafts | windows (30 min before start … end; closing until end+12 h), late flag at boundary+30 min ±1 s, one current reading, corrections (SUP window, UA any time, late flag of earliest), entered-by-UA, who (owner/cover/UA/other SUP/unassigned/SA) | SUP of another machine denied + audited | opening → closing as SUP; correction | `opening-closing.yaml` (opening + closing without photo) |
| 9–10 | summary card | every AC-10 case | — | summary shown | — |
| 11–12 | states + board | `reading_state`, `today_board` content, unassigned excluded, totals | SUP denied `today_board` | Today board + axe | — |
| 13 | — | `reading_capture` (on time, late, missing, unassigned excluded) | — | — | — |
| 14 | — | photo entity + visibility; SA 0 objects | upload on a reading | photo on opening | (real phone at R1) |
| 15–16 | full suite | isolation, denials, idempotency, 022 | full suite | full suite | nightly |

## Proposed architecture changes (flag for 07 / main)
1. **Readings model:** append-only readings with corrections that supersede; occurrence-level late flag from the earliest submission.
2. **Versioned production summary** with input snapshots (`calc_version`) — history never recalculated in place.
3. **Counter semantics per machine** (unit + optional maximum; cavities effective-dated) and the explicit "Needs review" instead of inferred movement (principle 5).

## Risks & areas of concern
- Rollover vs typing mistake: without a maximum the system never guesses; with a maximum a mistyped low closing looks like a rollover → mitigated by the Rollover flag on the UA board and corrections.
- Time windows around overnight occurrences (05 helpers, explicit `p_at` in read tests; write tests built relative to now).
- Dependence on 07 (attachments) for photos → photo step after 07 merges.
- Shared files with 07 (My shift card, Home, seed, fixtures-reset, 022) → 06 rebases after 07.

## Out of scope
Rework, downtime, scrap reasons, product change mid-shift, OCR/PLC, dashboards/exports (09), notifications, approval of rollovers.

## Clarifications (Opus, 2026-11-18, after review)
- AC-3: the opening may be recorded until **12 h after the occurrence ends** (Late after start + 30 min), by the owner or a UA — the owner's rule "late readings are accepted and flagged"; a missed opening no longer makes the occurrence impossible to complete.
- AC-4/AC-13: a closing submitted **more than 30 min before the end** is accepted and flagged **Early**; for metric 1 a closing is on time only within 30 min either side of the end, and an occurrence is counted once its end + 30 min has passed.
- AC-12: attainment shows "Not closed yet" when a target exists but no closing; assumed targets are labelled.
