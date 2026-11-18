# Intent: Shift handover and acknowledgement
Author: Sidambara Raja (drafted by Claude) · Status: draft · Date: 2026-11-18
Roadmap item: 08-shift-handover-ack · Release: R1 · Moves product metric: **Handover compliance** (≥ 98 % of shift openings where every inherited issue is individually acknowledged, or covered by an Admin exception, before the shift starts; overdue acknowledgements reported separately).

## Problem
Machine issues reported in one shift are lost or quietly dropped at handover, and inherited problems get blamed on the incoming supervisor (product: core problem). 07 records issues and their owner, but nothing makes the incoming supervisor see, accept and own them before work starts, so accountability still breaks at every shift change — the core reason MouldTrack exists.

## Proposed outcome
- **Opening checklist (incoming supervisor, Android-first):** when their shift occurrence starts (05), the supervisor sees, for **all machines they own in it**, every **unresolved issue** (Open, In progress, Resolved-awaiting-verification) with its context: description, priority, reported time, previous owner, previous actions, current status and the **outgoing supervisor's note** if any (PRD §5.2 step 7).
- **Per-issue acknowledgement:** they acknowledge **each issue individually** (optional remark). Acknowledging transfers **operational follow-up ownership** to them (07's ownership history, source `handover`) — not necessarily technical repair responsibility (PRD rule).
- **Can't accept → escalate:** for an issue they can't accept, they escalate with a reason (07's escalate). They **may still start** (owner decision b): the shift opening is recorded as **"Started – exception pending"**, the issue stays escalated, and the Unit Admin is alerted to record an **exception** (reason) or **reassign**. Until that happens the opening counts as **non-compliant** in the handover metric.
- **One declaration per supervisor per shift** (owner): after the acknowledgements, an overall declaration ("I have reviewed all open issues on my machines and accept responsibility for follow-up during this shift"). **Opening readings (06) on any of their machines are blocked until the declaration is done** (server-enforced).
- **Overdue:** an acknowledgement still missing **60 minutes** after the occurrence starts (owner: default 60, **configurable per tenant by the Unit Admin**) is **Overdue**: shown in the Unit Admin's alerts and reported separately in the handover metric.
- **Outgoing note (optional, owner):** at closing, the outgoing supervisor may add a short handover note per open issue on their machines; the incoming supervisor sees it in the checklist.
- **"Verify this fix" (07):** High/Critical issues awaiting verification by the incoming supervisor appear in the checklist as a **non-blocking** section (owner); they can verify now or later in the shift.
- **Carry-forward (FR-13):** unresolved issues stay open across shifts and appear again at the next opening; a shift change never closes or drops an issue.
- **Handover compliance function** for 09: per occurrence and supervisor — compliant / non-compliant (exception pending or not acknowledged before start) / overdue acknowledgements.

## Users & systems affected
Supervisor (Android + web), Unit Admin (web: alerts for exceptions pending and overdue acknowledgements; exception action; overdue setting). Postgres: shift_handover (declaration per supervisor-occurrence), issue_acknowledgement (append-only), handover notes, tenant setting; extends 07's ownership history and 06's opening rule.

## Success metrics
- Handover compliance computable for every shift opening from day one of the pilot (baseline; target ≥ 98 %).
- An incoming supervisor completes the checklist for 3 inherited issues in **≤ 90 s** on a mid-range Android phone (staging checklist).
- No unresolved issue ever disappears at a shift change (tests across overnight occurrences).

## Constraints
- Server decides: the reading block, ownership transfer, overdue and compliance are computed in Postgres; the client renders `allowed_actions` (architecture).
- Builds on 05 (occurrences, ownership), 06 (opening readings — **08's code starts after 06 merges**) and 07 (issues, escalate, verify, ownership history, alerts). Schema: 08's tables; lock after 06 releases it.
- Append-only acknowledgements and declarations; idempotent; audited.

## Behaviour that must not change
01–07 behaviour; 07's lifecycle rules (08 only adds the `handover` ownership source and the checklist).

## Out of scope
Push/SMS notifications; supervisor-requested shift swaps; maintenance team accounts; the full compliance dashboard (09).

## Owner decisions (2026-11-18)
1. A supervisor covering a machine after the occurrence started gets its checklist items at the cover time; their overdue deadline counts from the cover time.
2. A Unit Admin exception = **reason + choose the owner** (reassign, or explicitly keep it with the refusing supervisor).
3. A supervisor with no inherited issues still makes the one-tap declaration before readings.
(Earlier: one declaration per supervisor per occurrence covering all their machines; refusing doesn't block the start — "Started – exception pending", non-compliant until the exception; overdue after 60 min by default, configurable per tenant, reported separately; optional outgoing note; "verify this fix" shown but not blocking.)
