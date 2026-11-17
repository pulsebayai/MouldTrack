# Plan: Issue lifecycle
Spec: ./spec.md · Status: draft · Date: 2026-11-17
Locks: **architecture: 07** (attachments/Storage model). Schema: 07's tables + Storage bucket (05 has shipped, so no split is needed unless 06 starts in parallel — then split with 06, logged). Branch is on main incl. 01–05.

## Decisions (Opus)
- D1 Files: migration `20261117300000_issues.sql`; pgTAP `040_issue_tables.test.sql`, `041_issue_rpcs.test.sql`, `042_attachments_storage.test.sql`, `043_issue_reads.test.sql`.
- D2 Write RPCs are `public.iss_*` (spec FR-1), authorise via `app._pm_authorise` (any active member for report/note/photo; owner-or-UA / UA-only checks inside), D13 denials, idempotency scoped by source. Never `pm_*` or `sh_*` (pinned by 04/05 tests).
- D3 `app.machine_owner_now(machine, p_at default now())` = `machine_owner` for the earliest-started running occurrence (05's `current_occurrences`), else null. Used at report (spec AC-2) and in SUP visibility.
- D4 `app.issue_can_verify(issue, user, p_at default now())`: issue status `resolved`, priority high/critical; a SUP qualifies if they own the machine in an occurrence with `lower(window) > resolved_at` that is running or has started, and `user <> resolved_by`; a UA qualifies only if, for every shift, the first occurrence starting after `resolved_at` has `machine_owner = null`. Pure function, tested with explicit `p_at`.
- D5 Status transitions (server table in the migration comment + enforced in each RPC): open→in_progress (start), open|in_progress→closed (resolve, low/medium), open|in_progress→resolved (resolve, high/critical), resolved→closed (verify confirm), resolved→in_progress (verify reject), closed→in_progress (reopen). Anything else → guard `invalid_status`.
- D6 Storage: migration inserts bucket `attachments` (`public=false`, `file_size_limit=5242880`, `allowed_mime_types={image/jpeg,image/png,image/webp}`); policies on `storage.objects` for `authenticated`: INSERT `with check (bucket_id='attachments' and app.attachment_upload_ok(name))` (a `pending` attachment row with `storage_path = name`, `uploaded_by = auth.uid()`, created < 10 min ago); SELECT `using (bucket_id='attachments' and app.can_see_attachment(name))`; no UPDATE/DELETE policy. `iss_attachment_commit` checks `storage.objects` has `name`, and `metadata->>'size'` = declared size and `metadata->>'mimetype'` = declared mime, then pending→ready + `issue_action` type `photo`. The attachment trigger allows only that one transition.
- D7 Client photos: `npx expo install expo-image-picker expo-image-manipulator` (SDK-pinned versions); resize to max 1600 px, JPEG quality 0.7; SHA-256 via `expo-crypto` if present, else WebCrypto on web and a small TS fallback — **if hashing needs a new native module beyond these, escalate**. Signed URLs via `supabase.storage.from('attachments').createSignedUrl(path, 300)`. app.json: Android camera permission text.
- D8 Android test scope: `e2e/maestro/report-issue.yaml` reports an issue **without** a photo (emulator camera/gallery automation is unreliable); the photo path is proven by API + web e2e (file input) and on a real phone at the R1 gate (staging checklist). Logged as a deviation from the spec's test table.
- D9 Reads: `public.issue_list(p_filters jsonb, p_page int)`, `public.issue_detail(p_id)` (with `allowed_actions` computed by the same helpers the RPCs use), `public.issue_alerts()` (UA only) — security definer, authorise via `_pm_authorise` (022's static check), deny SAs. UAs also read the tables under RLS; SUPs get no table select.
- D10 Time: read helpers take `p_at`; write RPCs use `now()` (05 rule). Tests build shifts relative to `now()` so every case is constructible at any time of day (no window-dependent skips — if impossible, escalate).
- D11 UI: SUP — "Report issue" on each My shift machine row → `src/app/(app)/issues/new.tsx`; `issues/index.tsx` (My issues / all for UA); `issues/[id].tsx` (timeline + action bar from `allowed_actions`); UA Home Alerts card `src/components/issue-alerts-card.tsx` (stopped first; Recently closed); categories in Plant tabs (`plant/categories.tsx`). Refresh on focus + 60 s (05's AppState pattern). Local draft for the report form (AsyncStorage if already a dependency, else in-memory + retry — escalate before adding a new storage lib).
- D12 Fixtures: org U — categories (starter), one Critical stopped-machine issue, one High resolved awaiting verification (resolver U3, verifiable by the next-shift owner fixture), one closed Low; org A — one open issue for the Android SUP. Throwaway e2e issues on dev accumulate (append-only history) → known debt like 04/05.
- D13 Architecture (lock held): step 9 updates architecture.md (attachments model, issue model, allowed_actions pattern, polling alerts, `machine_owner_now`, `issue_can_verify`) and the Known debt list.

## Files that change
- `supabase/migrations/20261117300000_issues.sql`; `supabase/tests/040–043_*.test.sql` — new; `supabase/tests/022_platform_boundary.test.sql` — fixture-block additions only
- `supabase/seed.sql`, `scripts/fixtures-reset.ts` (+ tests, additions only); `scripts/hosted-checks.sh` (bucket private + size/mime limits on dev)
- `package.json` / lockfile (image picker/manipulator), `app.json` (permission text)
- `src/lib/issues.ts`, `src/lib/photos.ts` (+ tests); `src/app/(app)/issues/**`; `src/components/issue-*.tsx`; `src/components/my-shift-card.tsx` (Report issue action); `src/app/(app)/home.tsx` (Alerts card); `src/app/(app)/plant/categories.tsx` + plant tabs
- `e2e/web/issues.spec.ts`, `e2e/api/issues.spec.ts`, `e2e/maestro/report-issue.yaml`; `e2e/web/fixtures.ts`, `e2e/api/helpers.ts` — additions
- `sdlc/product/architecture.md` (lock), step 9

## Migrations
`20261117300000_issues.sql` (after 05's `20261117200000`). Additive.

## Steps
- [ ] 1. **Tables (tests first).** 040: RLS (UA reads tenant rows; SUP no direct select; SA nothing), composite FKs, append-only actions/ownership/attachment (only pending→ready), `machine_stopped → critical` check, starter categories for existing tenants + trigger for new tenants, category uniqueness/retire, registry. Then migration part 1. — proof: CI `db`
- [ ] 2. **Write RPCs (tests first).** 041: report (owner resolution cases spec AC-2 incl. UA on unassigned → "Needs owner"), note/start/assignee/escalate/ack/reassign, resolve by priority, verify (D4 cases: later occurrence owner ok; resolver refused; earlier/same occurrence refused; UA only when unassigned; overnight), reject → owner = verifier, reopen, invalid transitions, timestamps, audit rows, denials (SUP not allowed actions, must-change, suspended, SA), idempotency, isolation. — proof: CI `db`
- [ ] 3. **Attachments + Storage (tests first).** 042: bucket settings; insert policy (own pending row only, expired pending refused, other tenant's path refused, wrong user refused); select policy via `can_see_attachment` (UA, owning SUP, other SUP refused, SA refused — "SA reads 0 objects"); no update/delete; commit checks size/mime; trigger blocks other transitions. — proof: CI `db`
- [ ] 4. **Reads (tests first).** 043: `issue_list` visibility matrix (spec AC-13) + filters + paging, `issue_detail.allowed_actions` per role/status, `issue_alerts` (order: stopped, critical, high; recently closed 7 days; UA only). — proof: CI `db`
- [ ] 5. **Fixtures + 022** per D12 (022 fixture additions only). — proof: CI green
- [ ] 6. **Client (tests first).** issues.ts, photos.ts (resize/compress/hash with mocks), screen tests: report form (stopped locks Critical, category/priority chips, draft kept on failure), My issues, detail timeline + action bar driven by `allowed_actions`, verify panel, UA alerts card ordering + refresh, categories screen, My shift "Report issue". Then implement D11 + deps. — proof: lint/typecheck/test/build
- [ ] 7. **E2E.** web `issues.spec.ts` (report with photo via file input → UA alert → escalate → reassign → resolve → verify as next-shift SUP; Low closes on resolve; axe), api `issues.spec.ts` (Storage upload/commit/signed URL; other tenant/SUP can't read object; SA denied; resolver can't verify), Maestro `report-issue.yaml` (D8). — proof: CI `e2e-web` green
- [ ] 8. **Hosted proof (dev).** temporary dev-only triggers; deploy-dev (migration incl. bucket) + regression (web incl. api, Android incl. `report-issue.yaml`, hosted-checks + new bucket check, drift); remove triggers; green PR CI. — proof: run URLs
- [ ] 9. **Docs (lock).** architecture.md per D13; releases README: real-phone photo check on the R1 checklist. — proof: docs diff
- [ ] 10. **Review + PR.** sdlc-reviewer (focus Storage policies, verify eligibility, visibility matrix), fixes, AC table. — proof: PR CI green

## Risks
- **Storage RLS** (new): dedicated pgTAP 042 + API tests over real Storage + hosted bucket check.
- **Verification eligibility** across overnight/unassigned shifts (D4 with explicit `p_at`).
- **New native modules** change the Android build (prebuild check in PR CI, Android nightly, real phone at R1).
- **Free Storage quota** (1 GB): compression mandatory; dev fixtures tiny.
- Shared files with 06 if it starts in parallel (Home, My shift card, seed, fixtures-reset, 022) — 07 merges first; 06 rebases.
- Rollback: additive; bucket can stay empty.

## Proof of done
AC-1–16 → tests (spec table, with D8's Android scope); full suite green; dev regression green incl. Android.

## Deviations from plan
- D8: Android flow without photo (spec's table listed "with photo from gallery fixture").

## Session log
### 2026-11-17
- Done: intent + spec approved (owner: categories extendable; High/Critical verified by later-shift owner, UA fallback when unassigned; reporting on non-owned machines; photos visible to all who see the issue; stopped → Critical + UA alerts).
- Next step: owner approves plan; Sonnet executes steps 1–7.
