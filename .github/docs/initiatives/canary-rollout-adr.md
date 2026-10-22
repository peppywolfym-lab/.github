# ADR: Ring-staged, health-gated canary rollout of agent releases

**Status:** Accepted — records the *implemented* model (initiative [#495](https://github.com/petry-projects/.github-private/issues/495),
issues #499–#502, #868). Supersedes the aspirational "rings" sketch and the "Rollout status / next phase" caveat in
`petry-projects/.github` → `standards/ci-standards.md`.
**Author:** dev-lead / Claude Code
**Date:** 2026-07-01
**Scope (confirmed):** The delivery path for the versioned agents (`dev-lead`, `pr-review`, and the cross-repo `feature-ideation`) — how a new
immutable release is promoted from the host repo out to the whole fleet, and how it is rolled back. Records decisions; does not re-derive
the initiative analysis (see [`agentic-release-strategy.md`](./agentic-release-strategy.md)).
**Constraints (confirmed):** GitHub-native only — moving **channel tags** on first-party reusables, no external infrastructure.
The machine-readable ring map is `standards/canary-rings.json`; the gate logic is `scripts/lib/canary-rollout.sh`; the orchestrator is
`scripts/canary-rollout.sh` driven by `.github/workflows/canary-rollout.yml`. This ADR mirrors those artifacts — it does not restate their contents as a second source of truth.

---

## 1. Context

The release-strategy initiative ([#495](https://github.com/petry-projects/.github-private/issues/495)) replaced a floating-`@main` deploy —
where a merge was instantly live across the agents' own self-review duty *and* every consumer repo, with no canary and no rollback —
with a **versioned-release model**: immutable `<agent>/vX.Y.Z` releases plus **moving channel tags** (`<agent>/next`, `/ring0`, `/ring1`, `/stable`) that callers pin to.
See [`agentic-release-strategy.md`](./agentic-release-strategy.md) for the full analysis and
[`docs/release/versioning.md`](https://github.com/petry-projects/.github-private/blob/main/docs/release/versioning.md) for the tag mechanics.

Once #499–#502 and #868 landed, the concentric rings, the soak gate, and the promotion/rollback workflow were **built and machine-backed** — no longer aspirational.
This ADR records the decisions those artifacts encode so the public-repo standard can be promoted to match (and link here) instead of carrying a "not yet built" note.

## 2. Decision 1 — the ring map is host-relative and data-driven

[`standards/canary-rings.json`](../../standards/canary-rings.json) is the single source of truth read by
[`scripts/canary-rollout.sh`](../../scripts/canary-rollout.sh). Ring membership is **host-relative**, resolved from three member tokens rather than hard-coded repo lists:

| Channel | Order | Members (token) | Resolves to (for `dev-lead`, host = `.github-private`) |
|---|---|---|---|
| `next`  | 0 | `$host` — the repo that owns the reusable | `petry-projects/.github-private` |
| `ring0` | 1 | `$org_infra` — `org_infra_repos` **minus** the host | `petry-projects/.github` |
| `ring1` | 2 | explicit list | `petry-projects/TalkTerm`, `petry-projects/bmad-bgreat-suite` |
| `stable`| 3 | `*` — every other consumer not named in an earlier ring | the rest of the fleet |

Rationale for host-relative tokens: an agent's reusable can live in either org-infra repo (`dev-lead`/`pr-review` are hosted here; `feature-ideation`'s reusable is hosted in the public `.github`).
`next` always means "the host dogfoods first," and `ring0` always means "the *other* org-infra repo next" — so `next` + `ring0`
together always cover both org-infra repos, whichever hosts the agent. Hard-coding `ring0 = .github + .github-private` would be wrong for a host that is already sitting in `next`.

## 3. Decision 2 — soak / health gate rules

The promotion gate is a pure, unit-tested decision core ([`scripts/lib/canary-rollout.sh`](../../scripts/lib/canary-rollout.sh);
tests [`tests/canary_rollout.bats`](../../tests/canary_rollout.bats)), whose definitive spec is **#548**. A candidate `vX.Y.Z`
advances one ring only when the source tier (the tier currently running it) clears, evaluated per transition against EXECUTED runs
(success+failure; skipped/cancelled excluded) since the candidate's **own** cut:

- **Dwell floor:** the candidate has held the source tier a minimum time — `next→ring0` ≥ 4h, `ring0→ring1` ≥ 8h,
  `ring1→stable` ≥ 12h (registry-configurable per transition in `standards/canary-rings.json` `.gate`).
- **Sample floor:** a graduated `clamp(round(0.25·avg), 3, 15)` over a robust, spike-capped baseline. `next→ring0` is dwell-only
  when the source tier has no caller; `ring0→ring1` **waives** a fresh sample and rides cumulative health; `ring1→stable` needs ≥ 1 ring1 run.
- **Cumulative health (ALWAYS):** ZERO failures and ZERO startup-failures across EVERY tier since the candidate's first cut. A failure
  whose reusable blob is **unchanged** from the prior release is triaged as PRE_EXISTING, not a candidate regression.

Two properties keep the gate safe under low traffic: it never advances on an arbitrary synthetic floor (no volume → the candidate
parks at the frontier), and any in-window failure is triaged before promotion, so a real regression is never masked by "not enough runs yet."

### Gate states

| State | Meaning | Follow-up |
|---|---|---|
| `PROMOTE` | Dwell + sample floors met and cumulative health is clean | Advance the next ring (innermost-out). |
| `SOAKING` | Health clean but the dwell/sample floor isn't met yet | Wait — no action. |
| `BLOCKED` + `REGRESSION` | In-window failure whose reusable blob **changed** vs the prior release | Fix + cut a new `vX.Y.Z`, which **RESETs** the rollout. |
| `BLOCKED` + `PRE_EXISTING` | In-window failure whose reusable is **unchanged** (pre-dates the candidate) | A **human** classifies; may `promote --allow-pre-existing` to advance past it. |
| `COMPLETE` | Candidate is already on every ring | Fully rolled out — no action. |

### Cadence

[`.github/workflows/canary-rollout.yml`](../../.github/workflows/canary-rollout.yml) runs every **4 hours** (`cron: "33 */4 * * *"`, offset off the top of the hour),
ordering **autocut → promote-all → sync-issues**. `autocut` (#1069, gated by the `CANARY_AUTO_CUT` variable) cuts a new
`<agent>/vX.Y.Z` + moves `next` whenever a registered reusable's blob on its host `main` HEAD differs from the current candidate.
Timer promotion is **arm-gated**: when `CANARY_AUTO_PROMOTE == 'true'` the run advances every PROMOTE-ready agent one ring (BLOCKED
agents untouched; human approval is OVERRIDE-only), otherwise it runs read-only `evaluate-all`, emitting each agent's gate + health
report (#502). `sync-issues` then upserts one blocker issue per BLOCKED agent and renders the fleet-status table to the job summary.
Per-agent `promote` / `rollback` remain `workflow_dispatch`-only (default `--dry-run`).

## 4. Decision 3 — promotion is a single gated channel-tag move; rollback moves the tag back

The **channel tags are the rollout state.** There is no separate state store:

- **Promotion** = advancing one ring by **moving one channel tag** to the candidate `vX.Y.Z`, innermost-out along the ordered list
  `next → ring0 → ring1 → stable` (`next_channel_in_order`). The **only** mutation the orchestrator performs is a `gh api` ref update
  (PATCH/POST `repos/<host>/git/refs/tags/…`) on the agent's host repo — never a local `git push`; it never writes consumer files.
- **Rollback** = moving a channel tag **back** to a prior immutable release (`rollback <agent> <ring> --to vX.Y.Z`). Because immutable
  `vX.Y.Z` tags never move, they are the audit trail and the rollback targets.

The mover credential is a **GitHub App installation token** (`release-manager`, minted at runtime via
`actions/create-github-app-token`): the App is a bypass actor on the `release-channel-tags` ruleset (#868), so its `gh api` ref
updates are authorized to move protected channel tags. Minting is a HARD requirement — the job fails rather than fall back to
`github.token`, which cannot move `.github` tags.
This is the sanctioned, documented exception to the SHA-pin standard for **first-party** channel tags (see
[AGENTS.md → "Release channel tags & the mutable-ref exception"](../../AGENTS.md)); compliance audits must not flag `@<agent>/<channel>` pins
on first-party callers as unpinned.

## 5. Decision 4 — inner-ring repos pin to their ring channel, not `stable`

For soak to observe a candidate, a ring's repos must actually *run* it. So stub-pin guidance is:

| Repo class | Pins to |
|---|---|
| Host repo (dogfood) | `<agent>/next` |
| Other org-infra repo (`ring0`) | `<agent>/ring0` |
| `ring1` repos (`TalkTerm`, `bmad-bgreat-suite`) | `<agent>/ring1` |
| Everything else (`stable`) | `<agent>/stable` |

An inner-ring repo pinned to `<agent>/stable` would only ever see a version *after* it reached the outermost ring, contributing **zero** soak
signal to the gate that is supposed to protect the fleet — defeating the ring model.
The public-repo audit's `check_centralized_workflow_stubs` expected-pin map must therefore expect `<agent>/ring0|ring1` for inner-ring repos,
matching the ring map in [`standards/canary-rings.json`](../../standards/canary-rings.json).

## 6. Consequences

- Blast radius shrinks from "whole fleet, instantly" to "one ring at a time," and rollback is a single pointer flip.
- The public `petry-projects/.github` → `standards/ci-standards.md` can now describe the **implemented** model and drop its "Rollout status / next phase" caveat, linking here for the decision rationale.
  **That edit lands in the public repo** and is out of scope for a `.github-private` dev-lead run — this ADR is its in-repo counterpart and prerequisite.
  **A separate pull request against `petry-projects/.github` is still required to complete that public-repo update; issue #869 should be closed by that PR, not by this one.**
- The ring map, gate thresholds, and cadence are data/code ([`standards/canary-rings.json`](../../standards/canary-rings.json),
  [`scripts/lib/canary-rollout.sh`](../../scripts/lib/canary-rollout.sh), [`.github/workflows/canary-rollout.yml`](../../.github/workflows/canary-rollout.yml))
  — changing them is a reviewed diff, not a doc edit.

## 7. References

- Initiative [#495](https://github.com/petry-projects/.github-private/issues/495) — safe release strategy for agentic workflows.
- [`docs/initiatives/agentic-release-strategy.md`](./agentic-release-strategy.md) — the initiative analysis (rings, channels, health-gated promotion); §5.1 mutable-ref exception.
- [`docs/initiatives/agentic-release-strategy-orchestration.md`](./agentic-release-strategy-orchestration.md) — how the child issues (#496–#503) were delivered; the dependency DAG.
- [`docs/release/versioning.md`](https://github.com/petry-projects/.github-private/blob/main/docs/release/versioning.md) —
  immutable-release vs. moving-channel-tag mechanics; cross-repo reusables (canonical copy in `.github-private`).
- [`standards/canary-rings.json`](../../standards/canary-rings.json) — machine-readable ring map (source of truth).
- [`scripts/lib/canary-rollout.sh`](../../scripts/lib/canary-rollout.sh) / [`scripts/canary-rollout.sh`](../../scripts/canary-rollout.sh) /
  [`.github/workflows/canary-rollout.yml`](../../.github/workflows/canary-rollout.yml) — gate core, orchestrator, and scheduler.
- Decisions context: [petry-projects/.github#516](https://github.com/petry-projects/.github/issues/516).
