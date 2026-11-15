# MouldTrack — PR review instructions

Make three passes. Rank every finding **Important** (must fix before merge) or **Nit**. Give `file:line` and a suggested fix. Skip anything CI already enforces (lint, formatting, types).

## 1. Bugs
- Logic errors, missed edge cases, regressions in existing flows.
- Time handling: UTC storage, plant timezone for display/shift maths, overnight shifts.
- Counter logic: closing < opening, rollover/reset, counter movement ≠ good output.
- Duplicate submissions: shift open/close and acknowledgements must be idempotent.

## 2. Security
- **Every tenant-owned table has `tenant_id`, RLS enabled + forced, and a pgTAP isolation test.** Missing any of the three = Important.
- Workflow state changes (shift open/close, acknowledge, escalate, resolve, verify) only via RPC functions that write an AuditEvent in the same transaction. Direct client UPDATEs to these tables = Important.
- `security definer` functions pin `search_path` and check the caller's tenant/role.
- Append-only tables (ownership history, acknowledgements, audit) have no UPDATE/DELETE path.
- Authorization checks on the server, never only in the UI.
- **Public repo:** no secrets, keys, real plant data, real names/phones; fixtures only `@example.test`; no unencrypted database dumps or backups in artifacts.
- Injection, unsafe storage paths for photos (must be tenant-prefixed), PII in logs/Sentry.

## 3. Compliance
- Matches spec.md acceptance criteria and plan.md steps; changes outside plan "Files that change" are flagged.
- Follows architecture.md (stack, rules, release & regression policy).
- No test edited, weakened, skipped or deleted to pass. New behaviour has tests; bug fixes have a failing-first regression test.
- Docs updated in the same PR when a decision changed.
- PR description has the AC → test → result table and CI run URL.
