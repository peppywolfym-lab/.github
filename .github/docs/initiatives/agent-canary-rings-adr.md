# ADR: Agent releases roll out via host-relative canary rings with a health-gated promotion

- **Status:** Accepted (dev-lead pathfinder in production, 2026-06)
- **Initiative:** Safe Release Strategy for Agentic Workflows (epic petry-projects/.github-private#495)
- **Supersedes:** the "deploy by rewriting every consumer's `main` at once" model.

## Context

The org's reusable agent workflows (`dev-lead`, `pr-review`, …) are *self-hosting*:
the agent that validates and fixes PRs is itself shipped by a reusable workflow in
`petry-projects/.github-private`. Deploying a new version by clobbering all consumers'
files at once meant a bad version could break its own fix pipeline (the circular
dependency) with org-wide blast radius and no staged validation or fast rollback.

We need releases that (a) never touch caller repos, (b) validate a candidate on a
small blast radius before the fleet runs it, (c) keep production self-review duty on a
known-good version while the candidate soaks, and (d) roll back in one move.

## Decision

1. **Versioning = immutable releases + moving channel tags.** Cut `<agent>/vX.Y.Z`
   once (immutable, the rollback target); callers pin a **moving channel tag**
   `<agent>/<channel>` exactly once and are never edited again. Promotion/rollback is
   a central tag move. Channel pins are an accepted exception to the SHA-pin policy
   (first-party refs we own) and are protected by the `release-channel-tags` ruleset.

2. **Host-relative concentric rings.** Channels, innermost-first:
   `next` (the repo that *hosts* the reusable — dogfood) → `ring0` (the other
   org-infra repo) → `ring1` (named low-traffic consumers) → `stable` (everyone else).
   `next` + `ring0` always span `.github` + `.github-private`, partitioned by host.
   Production self-review duty stays on `stable` even within ring 0, breaking the
   circular dependency. Membership is declared in `standards/canary-rings.json`.

3. **Automated, health-gated promotion (one ring at a time).** A read-only `evaluate`
   runs every 4h and reports each ring's gate state; a dispatch-gated `promote`
   advances the next ring only when the rings already on the candidate pass the
   **soak gate**: volume `healthy_runs ≥ ceil(baseline_runs / 7)` **and** candidate
   failure-rate `≤` baseline. **No synthetic floor** — an unused reusable parks at
   the frontier until real volume accrues. A confirmed regression resets the rollout
   (all ring channels roll back to last known-good); a pre-existing failure is logged
   and does not block. Implemented in `scripts/canary-rollout.sh` (+ pure, unit-tested
   decision core) and `.github/workflows/canary-rollout.yml`.

## Consequences

- **Zero caller churn; bounded blast radius; <5-min rollback** (one tag move).
- The promotion workflow is the authorized tag mover, authenticated as the
  **`petry-projects-release-manager` GitHub App** (a bypass actor on each host repo's
  `release-channel-tags` ruleset). Its required repository permissions —
  **Contents:write, Workflows:write, Deployments:write, Issues:write, Actions:read,
  Metadata:read** — must be granted on the App *and* requested in the token-mint step;
  see the header of `.github/workflows/canary-rollout.yml` for the rationale (notably
  Workflows:write, without which `.github` tag moves 403 — #807).
- New cost: the membership SoT and gate thresholds must be maintained; an unused
  reusable never auto-promotes (acceptable — its version doesn't matter until used).
- `dev-lead` is the pathfinder (shipped `v1.4.0` this way); `pr-review` and other
  reusables adopt the same model incrementally (#499/#616/#688).

The authoritative operational detail lives in
[`docs/release/versioning.md` + `runbook.md`](https://github.com/petry-projects/.github-private/tree/main/docs/release)
in the host repo; this ADR records the decision and its rationale.
