# Plan: chore/explicit-grants — every Data API privilege is written in a migration
Status: approved 2026-11-24 (owner: "yes i approve") · Author: Opus · Executor: Sonnet · Holds: schema + architecture locks
Found by the first staging run (45420921688): `42501 permission denied for table tenant` for service_role.

## Why
Supabase stopped auto-granting `anon`/`authenticated`/`service_role` on new `public` objects for new projects (from 2026-05-30;
existing projects from 2026-10-30, changelog 45329). dev (older) still has the old default privileges; staging (new) does not; prod
(new, Pulsebay Ai) would fail on go-live day. Our migrations relied on the implicit grants.

## Decisions
- **D1 Exact parity, never "grant all".** The target privilege set = what the migrations produce today on a stack WITH the old
  defaults (= dev = current PR CI). Append-only revokes, `app`/`app_policy` rules and function EXECUTE revokes must survive.
- **D2 Snapshot, then codify.** A query lists, for schemas `public` and `app_policy` (and any other schema a client role can reach),
  every table/view/sequence privilege and every function EXECUTE for `anon`, `authenticated`, `service_role` (and PUBLIC for
  functions). Run it in PR CI on the old-defaults stack, print it to the job log, and turn it into
  `supabase/migrations/20261124900000_explicit_grants.sql` of explicit `grant` statements (idempotent; a no-op on dev).
- **D3 CI behaves like a new project.** `supabase/config.toml` `[api] auto_expose_new_tables = false` (or the CLI 3.1.0 equivalent),
  so PR CI and the reset round-trip start without implicit grants and a missing grant fails PR CI.
- **D4 Privilege contract test** (new pgTAP file): the full privilege set equals the expected snapshot (exact, both directions),
  so a new table without its grants — or an extra grant such as UPDATE on an append-only table — fails. Every later feature adds its
  grants in its own migration and extends the snapshot (additions only), like 022's fixture block.
- **D5 Carry the small staging fixes** already on this branch (fixtures-reset error fields; 5-minute wait for a new web alias).

## Steps (tests first)
- [ ] 1. Snapshot query + a temporary CI step that prints the privilege set from the current (old-defaults) stack. Commit the
  printed set as the D4 expected snapshot.
- [ ] 2. D4 test (fails on a stack without implicit grants until step 3) + D3 config flip.
- [ ] 3. The D2 migration; PR CI green with D3 on (db, e2e, reset-roundtrip).
- [ ] 4. Docs: architecture rule "every new public object states its grants in its migration; the privilege contract test is the
  extension point"; known debt; decision log.
- [ ] 5. Opus: merge → deploy-staging → staging regression; dev nightly unaffected (no-op).

## Acceptance
- AC-1 Staging fixtures + full regression run on a new-style project.
- AC-2 PR CI runs without implicit grants and stays green.
- AC-3 The privilege contract test fails on any missing or extra grant.
- AC-4 No existing test edited; no privilege broader than today's.

## Session log
### 2026-11-24 (Opus) — plan written after the staging 42501.
