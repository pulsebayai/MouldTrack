# Spec: Issue lifecycle
Intent: ./intent.md · Status: approved · Date: 2026-11-17

Terms: **UA**, **SUP**, **SA** as before. **Accountable owner** = the supervisor accountable for an issue. **Running occurrence** = 05's shift occurrence whose window contains now. **Owner of a machine now** = `app.machine_owner(machine, shift, date)` for the earliest-started running occurrence of any shift (null if none / unassigned). All prior patterns apply: client write RPCs authorise via `app._pm_authorise` (022), D13 denials, request ids tied to the RPC, append-only history (revokes + trigger incl. service_role), audit registry, composite tenant FKs, 022 fixture additions.

## User stories & acceptance criteria
**Report**
- **AC-1 Report.** An active SUP or UA reports an issue on a non-retired machine of their tenant: category (active), priority (Low/Medium/High/Critical), description (1–1000), **machine stopped (yes/no)**, optional photo(s) (AC-12). **Machine stopped = yes forces priority Critical** (server-side; the form shows it locked). Status starts **Open**. Audited `issue.reported`.
- **AC-2 Accountable owner at report.** If the reporter is a SUP who owns the machine now → reporter. Otherwise → the machine's owner now; if none (or the reporter is a UA and the machine is unassigned) → the reporter if a SUP, else **unassigned** (shown to UAs as "Needs owner"). An ownership-history row records it (source `report`).
- **AC-3 Categories.** Each tenant starts with Mechanical, Electrical, Mould/Tool, Material, Quality, Safety, Other (new tenants get them automatically). A UA can add (1–40, unique per tenant, case-insensitive), rename and retire/reinstate categories; a retired category isn't offered for new issues but keeps its history. Audited `issue_category.*`.

**Work the issue**
- **AC-4 Actions.** Anyone who can see an issue can add a **note** (1–1000) or **photo**. The accountable owner or a UA can **start work** (Open → In progress) and set the free-text **technical assignee** (≤ 80). Each is an appended action; nothing is edited or deleted.
- **AC-5 Escalate.** The accountable owner escalates with a reason (1–200): the issue is flagged **Escalated** (owner unchanged) and appears in the UA's escalations. A UA clears the flag by **reassigning** (AC-6) or **acknowledging** it with a note. Audited `issue.escalated|escalation_acknowledged`.
- **AC-6 Reassign.** A UA reassigns the accountable owner to another active SUP of the tenant (reason 1–200). Ownership-history row (source `reassign`). Audited `issue.reassigned`.

**Resolve, verify, close**
- **AC-7 Resolve.** The accountable owner or a UA resolves an Open/In-progress issue with **resolution notes** (1–1000). The occurrence in which it was resolved (shift + date, if any) and the time are recorded.
  - **Low/Medium:** status → **Closed** at once.
  - **High/Critical:** status → **Resolved – awaiting verification**.
- **AC-8 Verify (High/Critical).** A SUP may **confirm** or **reject** a Resolved issue only if they **own the machine in an occurrence that started after the resolve time** and they are **not the resolver**. A UA may verify only if the machine has **no assigned supervisor** in the first occurrence of every shift that starts after the resolve time. Confirm → **Closed** (`issue.verified`). Reject (reason 1–200) → **In progress**, the rejecting SUP becomes accountable owner (ownership row, source `verification_rejected`) (`issue.verification_rejected`).
- **AC-9 Reopen.** A UA reopens a Closed issue with a reason (1–200) → In progress, owner unchanged (`issue.reopened`).
- **AC-10 Timestamps.** Every issue keeps `reported_at`, and when applicable `resolved_at` and `closed_at` (closed = verified for High/Critical); a reopen keeps the history and clears `closed_at` until the next close. Resolution time (`closed_at − reported_at`) is computable for every closed issue.

**Alerts & lists**
- **AC-11 UA alerts.** UA Home and Issues show **Alerts**: every not-closed High/Critical issue, **stopped machines first**, then Critical, then High, newest first, with machine, category, age and owner. And **Recently closed**: High/Critical closed in the last 7 days with resolution notes. Both refresh on focus and every 60 s.
- **AC-12 Photos.** JPEG/PNG/WebP, compressed on the device to ≤ 1600 px and ≤ 5 MB (server-enforced limit). Up to 5 photos per action. Stored privately per tenant; viewed only through short-lived signed URLs (≤ 5 min). Visible to everyone who can see the issue (owner). Audited `attachment.added`.
- **AC-13 Who sees what.**
  - **SUP:** issues they are accountable for; issues on machines they own now; issues awaiting **their** verification (AC-8); issues they reported (they keep read access and, per AC-4, may still add notes/photos).
  - **UA:** all issues of the tenant, filters status / priority / category / machine / escalated / stopped / "Needs owner", 25 per page.
  - **SA:** nothing (022 + a Storage test).
- **AC-14 Screens.** SUP (Android + web): from My shift a machine row → **Report issue**; **My issues** list; issue detail with history timeline (actions, ownership changes, photos) and the actions they may take. UA (web): Issues list + detail + Alerts on Home. 48dp targets, text status labels, axe 0 serious/critical.
- **AC-15 Denials, idempotency, isolation** as before (cross-tenant ids → generic denial; must-change/suspended/SA denied + audited; request id repeats return the first outcome).
- **AC-16 No regressions.** 01–05 green.

## Functional requirements
- FR-1 RPCs (`public.iss_*`, `_pm_authorise`): `iss_report`, `iss_note`, `iss_start`, `iss_set_assignee`, `iss_escalate`, `iss_ack_escalation`, `iss_reassign`, `iss_resolve`, `iss_verify(confirm bool, reason?)`, `iss_reopen`, `iss_category_save`, `iss_category_set_retired`, `iss_attachment_begin`, `iss_attachment_commit`.
- FR-2 Reads: `public.issue_list(filters, page)`, `public.issue_detail(id)` (incl. allowed actions for the caller — the client renders what the server allows), `public.issue_alerts()` (UA only). Tables under RLS for UAs; SUPs read only through these functions.
- FR-3 Photo upload is two-phase: `iss_attachment_begin(issue, mime, size, sha256)` → pending attachment row + storage path `tenant/<tenant_id>/issue/<issue_id>/<attachment_id>.<ext>`; client uploads to bucket `attachments`; `iss_attachment_commit(id)` checks the object exists with the declared size/type and marks it ready + appends the action. Storage policies: insert only into a path that matches a pending attachment row created by the same user within 10 min; select only if `app.can_see_attachment(object name)`; no update/delete for clients. Pending rows older than 1 h are ignored (and cleaned by fixtures-reset on dev).
- FR-4 For 06/08/09: `app.can_see_issue(issue)`, `app.issue_open_for_machine(machine)`, the attachment model (linked entity type/id) reused by 06's counter photos.

## Non-functional requirements
- Report with one photo in ≤ 60 s on a mid-range Android phone over 4G (staging checklist); alerts appear ≤ 60 s.
- Storage: Free tier 1 GB → ~300 KB per photo target after compression; dev fixtures upload tiny images only.
- Privacy: photos may show people — note in the report form ("Photograph the machine, not people"). No personal data in descriptions is enforced (guidance only).
- Accessibility as before; camera/photo buttons ≥ 48dp with text labels.

## Data model changes (schema lock: 07's tables; split with 05 while open, logged)
- `issue_category` (id, tenant_id, name, retired_at, sort, …); starter rows inserted for existing tenants by the migration and for new tenants by an after-insert trigger on `tenant`.
- `machine_issue` (id, tenant_id, machine_id, category_id, priority, description, machine_stopped, status `open|in_progress|resolved|closed`, escalated_at null, accountable_owner_id null, technical_assignee, reported_by, reported_at, reported_shift_id/date null, resolved_by, resolved_at, resolved_shift_id/date, closed_at, updated_at). Current-state row changed **only** by `iss_*` RPCs; check `machine_stopped → priority = 'critical'`.
- `issue_action` (append-only): id, tenant_id, issue_id, actor_id, actor_role, type, notes, status_before/after, request_id, at.
- `issue_ownership_history` (append-only): id, tenant_id, issue_id, previous_owner, new_owner, source `report|reassign|verification_rejected|handover` (08), reason, actor_id, at.
- `attachment` (id, tenant_id, entity_type `issue_action` (06 adds its own), entity_id, storage_path, mime, size_bytes, sha256, status `pending|ready`, uploaded_by, created_at). Append-only except the single pending→ready transition (trigger allows only that).
- Storage bucket `attachments` (private, `file_size_limit` 5 MB, allowed MIME types) + policies (FR-3). 022 fixture rows for the five tables; new pgTAP for Storage policies ("SA reads 0 objects", cross-tenant path refused, insert only for own pending row).
- Registry: `issue.*`, `issue_category.*`, `attachment.added`.

## Existing code affected
Home (UA Alerts card; SUP My shift machine rows gain "Report issue"), `src/lib/*` (new `issues.ts`), seed + fixtures-reset (categories, a few issues incl. a stopped-machine Critical and one awaiting verification), e2e fixtures, Maestro (new `report-issue.yaml`), 022 fixture block (additions), `package.json` (`expo-image-picker`, `expo-image-manipulator` via `npx expo install` for the pinned SDK), app.json (camera permission text for Android).

## Backward compatibility & data migration
Additive. Existing tenants get starter categories. No change to 05's ownership rules.

## API / interfaces
As FR-1/FR-2; all writes return `{ok, id?}` / D13 denials; `issue_detail.allowed_actions` lists what the caller may do now.

## UX flows & screens
- **Report (SUP, Android):** machine → Report issue → category chips → priority chips (Critical locked when "Machine stopped" is on) → description → Add photo (camera / gallery) → Submit; local draft kept until success.
- **Issue detail:** header (status label, priority label, machine, owner, escalated/stopped badges as text), timeline, action bar limited to `allowed_actions`; verify panel ("Confirm fixed" / "Not fixed – reason").
- **UA Issues (web):** list with filters; Alerts card on Home (stopped first); Recently closed.

## Test strategy
| AC | Unit | DB (pgTAP) | API | Web e2e | Android |
|---|---|---|---|---|---|
| 1–3 | form rules (stopped → Critical) | report rules, owner resolution at report (owned / not owned / unassigned / UA), categories + starter trigger | SUP report on own and other machine | report + categories | `report-issue.yaml` (report on own machine, with photo from gallery fixture) |
| 4–6 | action bar from allowed_actions | each action appended, escalate/ack/reassign, append-only incl. service_role | — | escalate → UA alert → reassign | — |
| 7–10 | verify panel | resolve paths by priority, verify eligibility (later occurrence, not resolver, UA fallback only if unassigned), confirm/reject, reopen, timestamps | resolver can't verify; later-shift owner can | resolve → verify (as next-shift SUP) | — |
| 11 | alerts ordering | `issue_alerts` content/order, recently closed window | SUP denied | Home alerts + refresh | — |
| 12 | compression util | attachment two-phase, Storage policies (own pending only, cross-tenant refused, SA 0 objects, no update/delete) | upload → commit → signed URL works; other tenant can't read | add photo, view | photo in report flow |
| 13 | — | visibility matrix SUP/UA/SA via read functions | other SUP can't see | — | — |
| 14 | screen tests | — | — | axe | — |
| 15–16 | full suite | full suite | full suite | full suite | nightly |
- Mutating tests in org U / dedicated test orgs (no orgDef 1–9 reuse; check fixture phone ranges). Storage tests use tiny generated PNGs.

## Proposed architecture changes (architecture lock: 07)
1. **Attachments:** private bucket, tenant-prefixed paths, two-phase upload (pending row → upload → commit), Storage RLS through `app.can_see_attachment`, signed URLs ≤ 5 min, size/type limits server-side; reusable by 06.
2. **Issue model:** current-state row changed only by RPCs + append-only actions and ownership history; ownership source enum shared with 08's handover.
3. **Read functions with `allowed_actions`** for workflow screens (client renders only what the server allows).
4. **In-app alerts by polling** (60 s) until notifications (R2).

## Risks & areas of concern
- **Storage RLS** is new territory (policies on `storage.objects`); tests must prove cross-tenant and SA refusal, and the hosted check must confirm bucket settings on dev.
- **Verification eligibility** depends on 05's occurrence maths; edge cases (overnight, unassigned next shift, resolver also next owner) need explicit tests.
- New native modules (image picker/manipulator) change the Android build; nightly Android + a real phone at the R1 gate.
- Free-tier Storage quota; compression is mandatory.
- 05 open in parallel: shared Home/My shift card, seed, fixtures-reset, 022 → 07 rebases after 05 merges.

## Out of scope
Push/SMS/email; SLA/overdue timers; downtime events with times; maintenance accounts; handover acknowledgement (08); issue analytics (09); counter photos (06 reuses attachments); editing or deleting issues/actions/photos.

## Clarifications (Opus, 2026-11-17, after review)
- AC-8: if no supervisor other than the resolver can verify (e.g. a single-shift unit where the resolver owns every shift), a Unit Admin may verify — including their own resolution in that case. Verification eligibility looks at most 60 days ahead.
- AC-12: photos are fetched with the user's session on every view (no long-lived signed links); access is re-checked on every request **except** that hosted Storage's CDN may re-serve an object the same user already downloaded until their access token expires (≤ 1 h) — accepted residual risk (D14).
- AC-2: "owner now" = the owner of the first running occurrence that has an assigned supervisor.
