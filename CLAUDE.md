# MouldTrack — working rules for Claude
@sdlc/product/product.md
@sdlc/product/architecture.md
@sdlc/product/roadmap.md

Requirements baseline: `Requirment desciption/MouldTrack_High_Level_PRD.docx`. The prototype HTML in the same folder is a UI reference only.

## Active feature
Determined by branch: a branch containing <NN-slug> → `sdlc/features/<NN-slug>/`. At session start, read its plan.md (checkboxes + latest session log). On main: product-level work only.

## Verification commands (must all pass before a step is done)
- `npm run lint` → 0 errors
- `npm run typecheck` → 0 errors
- `npm run test` → all pass (Jest + RNTL)
- `npm run test:db` → all pass (pgTAP / RLS, local Supabase; needs Docker — on the owner's Mac it runs in CI)
- `npm run test:e2e` → all pass (Playwright: projects `e2e` (web build), `api` (Edge Functions + RLS over HTTP), `api-setup` (local stack only, runs last), `smoke`; local Supabase with edge runtime)
- `npm run test:e2e:android` → all pass (Maestro, Android emulator; nightly + release only, not on PRs)
- `npm run build` → exits 0 (`expo export` web + Android prebuild check on a throwaway copy; set `WEB_DIST` outside the iCloud folder for local runs)
- Hosted checks (GitHub Actions only): `secrets-check`, `deploy-dev`, `regression` (dispatch: target dev | staging | prod-smoke)

## Model routing
Opus: intent, spec, plan, architecture, security/RLS design, blockers, review. Sonnet: executing approved plan steps. Sonnet escalates design questions (logs `Blocked - needs Opus` in plan.md) instead of deciding them. Handoff = plan.md.

## Rules
- Follow the AI-native SDLC session start/end routines.
- Never edit, weaken or delete a test to make it pass; fix the code.
- Never work directly on main except roadmap/product docs (with user OK).
- On a feature branch, do not edit roadmap.md, and edit architecture.md only if this feature holds the architecture lock.
- Only the feature holding the schema lock may add database migrations.
- Every tenant-owned table has `tenant_id` + RLS and a pgTAP isolation test. Workflow state changes go only through RPC functions.
- Every PR runs the full suite. Every release follows the Release & regression policy (staging gate, manual checklist, evidence in `sdlc/releases/`). Never run data-writing tests against prod.
