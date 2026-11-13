# Intent: Walking skeleton
Author: Sidambara Raja (drafted by Claude) · Status: approved · Date: 2026-11-13
Roadmap item: 01-walking-skeleton · Release: R1 · Moves product metric: none directly (enabler for all)

## Problem
No code, pipeline or environments exist yet. Every later feature (08 features in R1) depends on a trustworthy loop: one codebase that builds for Android and web, a database whose tenant isolation is proven by tests, and a pipeline that runs the full regression suite and keeps evidence. If this foundation is skipped or weak, the cost lands on every later feature as flaky tests, unproven isolation, or prod changes without a gate.

## Proposed outcome
A thin vertical slice, deployed to **dev**, that exercises every layer:
- Expo (TypeScript, Expo Router) app running on an Android emulator/device **and** in a browser from one codebase.
- Email/password sign-in via Supabase Auth; signed-in user sees a home screen showing their tenant name and role; sign-out.
- Base schema: `tenant`, `membership` (user × tenant × role) with RLS; a pgTAP test proving user of tenant A cannot read tenant B.
- Verification scripts: lint, typecheck, test, test:db, test:e2e (web, Playwright), test:e2e:android (Maestro), build.
- CI on every PR: full suite except Android e2e (owner exception), each DB/e2e job on an ephemeral local Supabase from migrations; docs-only skip.
- Regression & evidence kit: `regression.yml` (nightly on dev incl. Android emulator; manual dispatch dev/staging/prod-smoke), summary script, prod-safe smoke suite, fixture hygiene (`@example.test`, reusable fixture users), `sdlc/releases/README.md`.
- REVIEW.md, production-gate hook, verifier / sdlc-reviewer / sdlc-planner subagents, `.claude/settings.json` model routing.
- New Supabase org (Free) in ap-south-1 with **dev** and **staging** projects; only dev used in 01. **prod** is created at the R1 release (see Constraints).
- Web build hosted on **EAS Hosting** (replaces Vercel). Sentry wired for app and web.

## Users & systems affected
Developer/owner only. Systems: GitHub (public repo pulsebayai/MouldTrack), Supabase, Expo/EAS (build, update, web hosting), Sentry.

## Success metrics
- Full PR CI ≤ ~10 min wall clock, green on main.
- One manual `regression.yml` run against dev passes and produces an evidence artifact; one nightly run (incl. Android) passes.
- Docs-only PR skips suites; code PR runs full suite (both proven).
- Cross-tenant read denied, proven by pgTAP.

## Constraints
- India data residency: all Supabase projects ap-south-1.
- No real plant data anywhere in dev/staging; fixture addresses `@example.test` only.
- Android first; iOS builds not configured.
- Local machine has no Docker/Supabase CLI [observed]: DB and e2e suites run in GitHub Actions; local runs are optional.
- **Cost: free tiers only until R1 go-live.**
  - Supabase Free = 2 active projects per org, paused after 7 days idle, no backups. dev is kept active by the nightly run; staging gets a weekly read-only keep-alive ping.
  - Vercel Hobby forbids commercial use, so the web build goes on EAS Hosting (Free includes 100k requests/month).
  - EAS Free = about 15 Android cloud builds/month in a low-priority queue. CI and nightly build the APK on the GitHub runner itself; EAS Build is used only for builds handed to people.
  - Sentry Free (Developer).
- **Public repo:** no secrets in git (CI on PRs needs none by design); secrets only in GitHub Actions secrets used by nightly/dispatch; pull requests from forks never receive secrets.

## Out of scope
Roles beyond the seeded fixture membership, invites, Super Admin screens (02/03); any manufacturing entity; staging/prod deploys (first used at R1 release); Play Store publishing (internal APK via EAS is enough).

## Decisions (2026-11-13, owner)
- Repo: public `github.com/pulsebayai/MouldTrack` (free Actions minutes; branch protection available).
- Supabase: separate new org on the Free plan. Expo, Sentry: new free accounts created by the owner. Vercel dropped (Hobby plan forbids commercial use) → EAS Hosting.
- Git author email: placeholder accepted.

- Prod stays on Supabase **Free** (separate org) until pilot completion (owner). Risk: Free has no backups. Required mitigation before R1 go-live (flag for architecture.md): nightly **encrypted** `pg_dump` + Storage export, encrypted to a key held only by the owner (repo artifacts are public), plus one restore drill recorded in the R1 release record.
- `Requirment desciption/` is local-only (gitignored, removed from history).

## Open questions
None.
