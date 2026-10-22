# CI/CD Standards

Standard CI/CD configurations for all repositories in the **petry-projects** organization.
This document defines the required workflows, quality gates, and patterns that every
repository must implement.

---

## Using Templates from `standards/workflows/`

> **Rule:** When fixing a compliance finding by adding a workflow file, **copy
> the template from [`standards/workflows/`](workflows/) verbatim.** Do not
> generate the file from scratch, even if the change seems trivial. The
> templates are the source of truth — anything generated from scratch is, by
> definition, drift.

### Centralization tiers

Every standard workflow falls into one of three tiers. Knowing the tier tells
you how much of the file you may edit when adopting it in a new repo, and
where to send a fix when behavior needs to change.

| Tier | Examples | What lives in `standards/workflows/` | Where logic lives | Edits allowed in adopting repo |
|---|---|---|---|---|
| **1. Stub** | `dev-lead.yml`, `dependency-audit.yml`, `dependabot-automerge.yml`, `dependabot-rebase.yml`, `agent-shield.yml`, `feature-ideation.yml`, `pr-review-mention.yml` | A thin caller stub that delegates via `uses: …/<name>-reusable.yml@<name>/stable` — the reusable's moving `stable` channel tag ([Reusable workflow versioning](#reusable-workflow-versioning--the-stable-channel)). Reusables not yet migrated to a channel keep their current canonical pin in the interim; `check_centralized_workflow_stubs` in `scripts/compliance-audit.sh` enforces the expected pin per reusable. | The matching `*-reusable.yml` (single source of truth) | **None** in normal use. May tune `with:` inputs where the reusable exposes them (e.g. `agent-shield` accepts `min-severity`, `required-files`; `feature-ideation` requires `project_context`). To change behavior, open a PR against the reusable; a release is cut and promoted by moving the channel tag, never by editing callers. |
| **2. Per-repo template** | `ci.yml`, `sonarcloud.yml` | _(no template — see the patterns documented below)_ | In each repo, because the workflow is tech-stack-specific (language matrix, build tool, test framework) | **Limited.** Each adopting repo carries its own copy. Stay within the patterns in this document; do not change action SHAs, permission scopes, trigger events, or job names without raising a standards PR first. |
| **GitHub-managed** | CodeQL default setup | _(no workflow file — managed via repo Settings → Code security)_ | GitHub | None. Configured via `apply-repo-settings.sh`; per-repo `codeql.yml` files are treated as drift by the compliance audit. See [§2 CodeQL Analysis](#2-codeql-analysis-github-managed-default-setup). |
| **3. Free per-repo** | `release.yml`, project-specific automation | _(out of scope for this standard)_ | Per-repo | Free, but must still comply with the [Action Pinning Policy](#action-pinning-policy) and the [Required Workflows](#required-workflows) constraints. |

Tier 1 stubs all carry an identical `SOURCE OF TRUTH` header block telling
agents what they may and may not edit. If you're considering modifying a
file with that header, **stop and read the header first** — if the change
isn't allowed by the contract, the right move is a PR against the central
reusable, not a local edit.

**Full-file identity (Tier 1).** A Tier-1 stub is **full-file identical across
every adopting repo, modulo the tier channel pin** — the `uses:` ref and its
matching `agent_ref`, pinned to the reusable's moving `stable` channel tag
(`@<name>/stable`, or a canary-ring tag under the
[stable channel](#reusable-workflow-versioning--the-stable-channel)).
**Everything else is fixed: `on:`, `permissions:`, and `concurrency:` are
_not_ repo-adjustable.** Trimming a trigger, narrowing a permission, or adding a
`concurrency:` block when adopting the stub is drift, not a repo-specific
liberty — the behavior lives in the reusable. To change any of it, open a PR
against the reusable (or a standards PR that updates the template here) and let
the channel tag promote the change centrally; never edit a caller to adjust its
trigger, permission, or concurrency surface.

**Required-check stubs must support `merge_group`.** Any org-standard stub that
provides a **required status check** (e.g. `agent-shield.yml` →
`agent-shield / AgentShield`, `dependency-audit.yml` →
`dependency-audit / Detect ecosystems`) MUST include the **`merge_group`** event
in its `on:` trigger set, alongside `push`/`pull_request`:

```yaml
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  merge_group:
```

This is a property of the standard, not a per-repo patch. A GitHub **merge
queue** only merges a PR once its required checks report on the queue's temporary
`gh-readonly-queue/*` ref, and a workflow reports there only if it triggers on
`merge_group`. Because these stubs forbid consumers from editing trigger events
(the job name is a required-check context that must stay verbatim), a consumer
cannot add `merge_group` itself — so it lives in the template here and every
adopter inherits it verbatim. Any repo adopting a merge queue then needs **no
cross-repo change**. The reusables themselves are `workflow_call` and are
indifferent to the outer event, so they need no change. Do not strip
`merge_group` on a stub sync and do not flag it as trigger drift — the `on:`
surface-drift checks compare against this template, so the merge-queue trigger set
is the compliant baseline.

### Reusable workflow versioning — the `stable` channel

**Standard.** Every reusable workflow is versioned by a **moving `stable`
channel tag**, and every caller pins to it **once** —
`uses: …/<name>-reusable.yml@<name>/stable`. A caller must **never** pin a
reusable to `@main` (a branch) and **never** to a frozen `@vX.Y.Z` (a version).
This applies to **every** reusable workflow regardless of which repo hosts it
(public or private) or which repo calls it (a downstream consumer or the
reusable's own self-host duty).

**Why not `@main` (a branch).** `@main` has no version boundary: the instant a
commit lands on the reusable's default branch it is live for every caller at
once — no canary, no health gate, no rollback. For a *self-hosting* reusable
(one that gates changes to itself — e.g. an agent that reviews or merges its own
PRs) it is worse: a broken change becomes the very version that must approve its
own fix, so the fix is gated by the breakage — a circular dependency that fails
closed.

**Why not a frozen `@vX.Y.Z` (a version).** A bare version pin is immutable, so
rolling out a change means **editing every caller** to the new tag: a fan-out PR
per release, a partially-migrated fleet in between, and security fixes that wait
behind that churn.

**The `stable` channel gets both right.** It is a *moving* tag that always
points at the current known-good release. Callers pin it once and are never
edited again; a release is rolled out by **moving the tag centrally** and rolled
back by moving it back.

**Benefits.**

- **Version boundary** — `main` can move freely; callers only ever see what `stable` points at.
- **No caller churn** — pin once; promotion and rollback never touch caller repos.
- **Instant, uniform rollback** — one tag move restores the last good release fleet-wide; no caller edits, no file surgery.
- **Health-gated promotion** — a candidate is validated before `stable` advances, so callers never run an unvalidated version.
- **Breaks self-host circular dependencies** — production runs the pinned channel, so an in-development version can no longer gate its own fix.
- **Single source of version truth** — the `stable` tag is the one place that defines "what is in production"; immutable `vX.Y.Z` tags are the audit trail and rollback targets.
- **Bounded supply-chain risk** — channel tags are first-party refs the org owns; a tag-protection ruleset restricts who may move them (see [Action Pinning Policy](#action-pinning-policy)).

**Expected release process.**

1. **Develop & merge** the change to the reusable's `main` as normal (reviewed, CI-green).
2. **Cut** an immutable release tag `<name>/vX.Y.Z` at the merged commit — the audit trail and rollback target; never moved or deleted.
3. **Promote through concentric rings** — advance each ring's channel to the new
   `vX.Y.Z` from the innermost ring outward, moving to the next ring only after
   the inner one has run it healthy for a soak window (see
   [Staged promotion through concentric rings](#staged-promotion-through-concentric-rings)
   below). Each promotion is a single central tag move, gated to an authorized identity.
4. **`<name>/stable`** is the outermost ring and advances last — that is full-production rollout.
5. **Roll back** (if a regression surfaces in any ring) by moving that ring's
   channel back to the prior `vX.Y.Z` — the same move in reverse; callers recover
   on their next run with no change on their side.

Where a reusable also checks out its own scripts or prompts, thread an
`agent_ref`-style input pinned to the same channel, so logic **and** code run at
the one validated version.

#### Staged promotion through concentric rings

`stable` is not a single hop. A release reaches full production by passing
through a series of **concentric rings** — channels ordered from the smallest
blast radius to the whole fleet. A release is promoted **one ring at a time**,
advancing to the next ring only after it has run healthy in the inner ring for a
defined **soak window**:

| Ring | Channel | Members (host-relative) | Blast radius |
|---|---|---|---|
| canary | `<name>/next` | the repo that **hosts** the reusable (dogfood at the source) | the host's own self-host duty |
| 0 | `<name>/ring0` | the **other** org-infra repo (`.github` + `.github-private`, partitioned by host) | org infrastructure |
| 1 | `<name>/ring1` | named low-traffic consumers | a couple of real consumers |
| _n_ | `<name>/ring`_n_ | progressively more consumers | widening fleet |
| Production | `<name>/stable` | everyone else | the whole fleet |

`next` is **host-relative**: it resolves to whichever org-infra repo owns the reusable,
and `ring0` is the other — so `next` + `ring0` always span `.github` + `.github-private`.
For `dev-lead` (hosted in `.github-private`): `next` = `.github-private`, `ring0` = `.github`,
`ring1` = `{TalkTerm, bmad-bgreat-suite}`, `stable` = the rest. The machine-readable source
of truth is [`standards/canary-rings.json`](https://github.com/petry-projects/.github-private/blob/main/standards/canary-rings.json)
in the host repo, consumed by the promotion automation.

How it works:

- **One immutable release, many channels.** Cut `<name>/vX.Y.Z` once; promotion is moving each ring's channel forward to it, innermost ring first.
- **Callers stay put; the release moves.** A caller pins exactly one ring's
  channel (most pin `stable`) and is never edited — the *release* advances
  through the rings, the *callers* don't. Which ring a repo sits in is a
  deployment choice, set once.
- **Soak + health gate.** A ring's channel advances to the new release only
  after the inner ring has run it healthy for the soak window (no regressions,
  error budget intact). A failure in any ring **stops promotion** — the outer
  rings never receive the bad version.
- **Bounded blast radius + fast rollback.** A regression that slips past an inner ring is contained to that ring and rolled back with one tag move, long before it could reach `stable`.

The canary ring (`next`) is the reusable's **own self-host**: it dogfoods every release first, at
zero external blast radius. This is also what breaks the self-host circular
dependency — production callers keep running `stable` while the new version is
exercised on `next`, so a broken candidate can never gate its own fix.

> **Rollout status.** The full ring model — host-relative `next`/`ring`_n_/`stable`
> channels, immutable `<agent>/vX.Y.Z` releases, and promotion by a central tag move
> — is **implemented and in production** for `dev-lead` (the pathfinder; `v1.4.0`
> rolled out canary → rings → `stable` and verified). It is managed in
> `petry-projects/.github-private` (the canary/ring versioning initiative, epic #495):
>
> - `scripts/cut-release.sh` cuts immutable releases.
> - `standards/canary-rings.json` is the ring-membership source of truth.
> - `scripts/canary-rollout.sh` + `.github/workflows/canary-rollout.yml` run the
>   **automated, health-gated promotion**: a read-only `evaluate` every 4h reports
>   each ring's gate state, and a dispatch-gated `promote` advances **one ring at a
>   time** only when the rings already on the candidate pass the **soak gate** —
>   volume `healthy_runs ≥ ceil(baseline_runs / 7)` **and** candidate failure-rate
>   `≤` baseline (no synthetic floor; an unused reusable simply parks). Rollback is
>   the same single tag move in reverse against the prior `vX.Y.Z`.
> - The channel tags are protected by a `release-channel-tags` ruleset in the host repo
>   (`.github-private`); the promotion workflow is the authorized mover.
>
> The authoritative process lives in that repo's `docs/release/` (`versioning.md`,
> `runbook.md`); this section summarizes it. `pr-review` and the `.github`-hosted
> reusables (e.g. `feature-ideation`) are being brought under the same model next
> (#499/#616/#688). Until a given reusable has its ring channels cut, it may run on
> `stable` alone and promote in one gated hop — an interim state, not the target.

**Migration.** This is the target for all reusable workflows; they adopt it
incrementally. A reusable that has not yet published a `stable` channel keeps its
current pin until it migrates, at which point its callers re-pin once and the
compliance audit (`scripts/compliance-audit.sh`) tightens to the channel for
that reusable. The reference implementation and the full rationale live in the
release-strategy initiative
(`petry-projects/.github-private/docs/initiatives/agentic-release-strategy.md`).

#### The same model for the `standards/` artifact

The `standards/` directory is itself consumed by other repos as a versioned
artifact, and it is published with the **same channel-tag vocabulary** as a
reusable workflow — an immutable `standards/vX.Y.Z` release and a moving
`standards/v<major>-stable` channel — but per-repo, so there are no concentric
rings. See [`standards/standards-versioning.md`](./standards-versioning.md) for
the cut script, the N-1 policy, and who moves the tags.

#### Caller-stub input forwarding across channel pins

**Rule.** Never add or modify a `with:` forward on a channel-pinned caller stub
to pass an input the **pinned channel does not yet declare**. GitHub validates a
reusable's `with:` inputs against the workflow **as it exists at the pinned ref**,
and only at **run startup** — so forwarding an input the channel has not yet
published makes the stub fail closed with `startup_failure` the first time it is
triggered on `main`.

**Sequencing** — to add a new `workflow_call` input to a channel-pinned reusable
and forward it from the stub, land the three steps **in this order**:

1. **Land the input in the reusable** — merge the new `workflow_call` input into
   the reusable's `main` (and cut its release tag).
2. **Promote the pinned channel** to a commit that declares the input — move the
   channel tag forward (`cut-release.sh --channel`, or the ring promotion) so the
   ref the stub pins now includes the input.
3. **Then teach the stub to forward it** — only now add the `with:` forward to the
   caller stub.

Doing these in any other order — most easily, adding the `with:` forward first —
strands the stub on a channel that predates the input and breaks every trigger
at startup.

**Why PR CI does not catch this.** While a standard `pull_request` trigger
executes the PR-branch stub, workflows triggered by comments or reviews (such as
`pull_request_review` or `issue_comment`) always execute the **default-branch
(base)** stub. Because the base-branch stub does not carry the new forward, and
the pinned channel lags the PR, the new forward is exercised by **nothing** in
PR CI. The change is green pre-merge and only dies at `startup_failure` on
the **first real trigger after merge to `main`** (the failure mode behind
incident #1034: a channel-pinned pr-review caller stub was edited to forward a
`with:` input the pinned channel did not yet declare, breaking **every** review
with `startup_failure`).

**`actionlint` does not cover this.** `actionlint` input-checks only **local
`./` reusable refs** — it never resolves the pinned **remote** channel, so it
cannot see that the forwarded key is undeclared there. The dedicated guards below
are required **in addition to** `actionlint`.

**Reference guards** (landed in `.github-private` via #1052, companion to this
standard):

- `scripts/validate-caller-inputs.sh` — resolves each reusable `uses: …@<ref>`
  carrying a `with:` block **at the pinned ref** and fails on any forwarded key
  not declared there (includes an incident-#1034 regression test).
- `scripts/stub_freeze_drift.sh` — byte-identity freeze of the ring-0 caller
  stubs' forwarding block.
- `pr-review-trigger-canary.yml` — a dry-run canary that fails loud on
  `startup_failure` before a real trigger can.

### Pure reusable workflows must be disabled

**Standard.** A **pure reusable workflow** — one whose `on:` block declares
**`workflow_call` and nothing else** — MUST be set to `disabled_manually` in the
Actions UI, and MUST be named with a **`-reusable.yml`** suffix. Both apply to
the single-source-of-truth reusable definition files hosted in
`petry-projects/.github` and `petry-projects/.github-private`.

**Naming.** The `-reusable.yml` suffix makes the "this is a library, safe to
disable, never runnable on its own" property legible from the filename alone — a
reader (or an auditor) should not have to open the file and parse its `on:` block
to know it is a reusable. The suffix is a **readability aid, not the detection
mechanism**: compliance tooling classifies by triggers, never by name (a name can
lie — see the `pr-review.yml` engine, a pure reusable that predates this rule).
When you extract logic into a new reusable, name it `<purpose>-reusable.yml` from
the start. *Grandfathered exception:* `.github-private/.github/workflows/pr-review.yml`
is a pure reusable that keeps its legacy name until it can be renamed in lockstep
with its caller path and `pr-review/*` release-channel tags — tracked in
`petry-projects/.github-private#1127`.

**Why.** A pure reusable has no independent event triggers, so it can never run
on its own — it executes **only** when another workflow invokes it via `uses:`.
Left active, it clutters the Actions sidebar with an entry that never has its own
runs, and a lone active-vs-disabled mix reads as "something is broken" to anyone
auditing the repo. Disabling states plainly: *this is a library, not a runnable
workflow.*

**Disabling is safe — it has zero effect on callers.** GitHub **ignores** a
reusable workflow's enabled/disabled state when it is invoked through
`workflow_call`; the flag only suppresses a workflow's *own* event triggers, of
which a pure reusable has none. A disabled reusable is still fully callable, at
any ref, by any number of caller stubs. (Verified: `dev-lead-reusable.yml` sat
disabled while 8 caller repos ran it successfully.) Caller count is irrelevant —
a reusable with 0 callers and one with 8 are both disabled.

**Exemption — anything with a real trigger stays active.** A workflow that
declares `workflow_call` **alongside** a real trigger (`schedule`,
`workflow_dispatch`, `push`, `pull_request`, `repository_dispatch`, …) is **not**
a pure reusable: it runs on its own and MUST remain active. Example:
`actions-fleet-monitor.yml` (has `schedule` + `workflow_dispatch` + `workflow_call`).

Thin **caller / trigger stubs** are likewise not pure reusables — they carry the
real event triggers and stay active. Note the common engine-plus-stub split: an
**engine** that is `workflow_call`-only is a pure reusable and **is disabled**,
while its **trigger stub** carries the events and **stays active**. For example
`pr-review.yml` (the engine, `workflow_call`-only → disabled) is invoked by
`pr-review-trigger.yml` (the stub, `check_suite`/`pull_request`/… → active).
Disabling the engine does not stop reviews — the stub still fires and calls it.

**How to disable.**

```bash
gh workflow disable <name>-reusable.yml -R petry-projects/<repo>
# verify:
gh api repos/petry-projects/<repo>/actions/workflows/<name>-reusable.yml --jq '.state'  # -> disabled_manually
```

**Compliance.** `check_reusable_workflows_disabled` in
[`scripts/compliance-audit.sh`](../scripts/compliance-audit.sh) flags any pure
`workflow_call`-only workflow found in the `active` state as a `warning`
finding. Note that disabled state is **not** captured in git — a newly added
reusable is born `active` and must be disabled explicitly, which is exactly what
this check catches on the next audit.

It also flags, as a separate `warning` finding, any pure reusable whose
filename doesn't carry the `-reusable.yml` suffix (grandfathered exception:
`pr-review.yml`, tracked in `petry-projects/.github-private#1127`).

### Available templates

| Template | Tier | Purpose |
|----------|------|---------|
| [`agent-shield.yml`](workflows/agent-shield.yml) | 1 | Deep agent-config security scan via `ecc-agentshield` |
| [`dev-lead.yml`](workflows/dev-lead.yml) | 1 | Event-driven AI automation (PR fixes, CI relay, review responses, issue handling) — replaced `claude.yml` 2026-05 |
| ~~`claude.yml`~~ | ~~1~~ | **Deprecated 2026-05.** Replaced by `dev-lead.yml`. See [§5 Migration](#migration-from-claudeyml). |
| [`dependabot-automerge.yml`](workflows/dependabot-automerge.yml) | 1 | Auto-approve and squash-merge eligible Dependabot PRs |
| [`auto-rebase.yml`](workflows/auto-rebase.yml) | 1 | Keep non-Dependabot PRs up-to-date with the base branch on every push to `main` |
| [`dependabot-rebase.yml`](workflows/dependabot-rebase.yml) | 1 | Update and auto-merge eligible Dependabot PRs on every push to `main` |
| [`dependency-audit.yml`](workflows/dependency-audit.yml) | 1 | Multi-ecosystem audit (npm, pnpm, gomod, cargo, pip) |
| [`feature-ideation.yml`](workflows/feature-ideation.yml) | 1 | Weekly ideation pipeline — **required org-wide** (#844). Its `project_context` MUST be a real per-repo description, not the seed `TODO:`/`Example:` placeholder. |
| [`pr-auto-review.yml`](workflows/pr-auto-review.yml) | 1 | Automated AI code review on PRs — **required org-wide** (#844) |
| [`initiative-driver.yml`](workflows/initiative-driver.yml) | 1 | Dispatches the central initiative-driver to release ready sub-issues of `initiative:auto` epics to dev-lead — **required org-wide** (#844) |
| [`pr-review-mention.yml`](workflows/pr-review-mention.yml) | 1 | Trigger the pr-review agent when `@donpetry-bot` is mentioned or `donpetry-bot` is assigned as reviewer |
| [`persona-mention.yml`](workflows/persona-mention.yml) | 1 | Route `@petry-projects/<role>` mentions to the addressed persona — one router for **all** personas ([persona-standards.md §4.1](persona-standards.md)) |
| [`apply-repo-settings.yml`](workflows/apply-repo-settings.yml) | 1 | Weekly branch-policy compliance self-heal — applies standard repo settings + `pr-quality`/`code-quality` rulesets ([github-settings.md](github-settings.md), [ruleset-remediation-runbook.md](ruleset-remediation-runbook.md)). Requires org secret `GH_PAT_DON_PETRY`. |
| [`copilot-setup-steps.yml`](workflows/copilot-setup-steps.yml) | 2 | Pre-install tools and dependencies for Copilot cloud agent sessions |

**Adapt only when the template genuinely requires repo-specific content** (e.g., a
project name in a comment, a different cron schedule for a known reason). Anything
beyond surface adaptation indicates either a missing template or a missing standard
— file an issue against `petry-projects/.github` rather than diverging silently.

**Fetching a template programmatically** (e.g., from a Claude Code automation run):

```bash
gh api repos/petry-projects/.github/contents/standards/workflows/<file>.yml \
  --jq '.content' | base64 -d > .github/workflows/<file>.yml
```

### Deploying & syncing stubs

**Standard.** Caller stubs are deployed and re-synced to consumer repos **via
pull requests**, never by pushing directly to a repo's default branch.
`scripts/deploy-standard-workflows.sh` is the canonical mechanism: for each
target repo it creates a `standards-sync/<workflow>` branch off the default
branch, writes the verbatim template onto it, and opens a PR labeled
`standards-sync` (creating the label if the repo lacks it). It **never merges and
never uses `--admin`** — the opened PRs run the repo's own CI and are landed by
the normal review/auto-merge pipeline. The shared primitive lives in
`scripts/lib/standards-deploy.sh` (`sd_deploy_via_pr`).

**Why a PR, not a direct push.** A direct Contents-API push to the default
branch is rejected (HTTP 409 `Required status check … expected`) on any repo
whose ruleset enforces required status checks — the Contents API does **not**
honor the org-admin ruleset bypass. It also skips review and CI on the repos
where it *would* succeed. A PR works uniformly on protected and unprotected
repos, runs CI against the change (e.g. AgentShield scans the new workflow), and
leaves an auditable record. (Background: [#478](https://github.com/petry-projects/.github/issues/478).)

```bash
# Plan only — opens nothing:
scripts/deploy-standard-workflows.sh --dry-run [--workflow <name>.yml] [--repo <name>]
# Open the standards-sync PRs:
scripts/deploy-standard-workflows.sh [--workflow <name>.yml] [--repo <name>] [--force]
```

The script is idempotent: it skips a repo whose stub already pins the template's
`uses:` ref, and skips opening a second PR when a `standards-sync` one is already
open for that workflow. Deployment never edits a caller's `uses:`/`agent_ref`
pins by hand — a release is rolled out by moving the channel tag (see
[Reusable workflow versioning](#reusable-workflow-versioning--the-stable-channel)).

**Deploy identity (least-privilege).** The scheduled driver
([`standards-deploy.yml`](../.github/workflows/standards-deploy.yml)) writes stub content and
opens PRs **across the fleet**, so it must run under a cross-repo write identity —
`contents:write` + `pull_requests:write` on the target repos, and nothing more. It
uses `GH_PAT_DON_PETRY` (falling back to the legacy `GH_PAT_WORKFLOWS`), the same
identity `dev-lead.yml` / `pr-auto-review.yml` / `initiative-driver.yml` already
author cross-repo PRs with. It **must not** use `ORG_SCORECARD_TOKEN`: that is the
**audit** identity (a fine-grained PAT with **Contents: Read-only**), so its
content PUTs 422 and every deploy fails with an opaque `put-failed`
([#864](https://github.com/petry-projects/.github/issues/864)). The deploy identity
is also deliberately **not `donpetry-bot`** (it acts as `don-petry`): the PRs it
opens are authored by a distinct code-owner, so `donpetry-bot` can approve them via
the pr-review agent and they land through native auto-merge with **no `--admin`**. A
GitHub App carrying only those two scopes — non-author-blocked and not
`donpetry-bot` — is an acceptable substitute.

The deploy primitive also **preflights write access per repo** before touching any
branch and **never issues a sha-less content PUT against an existing file**: a
token-scope gap surfaces as a single `no-write-access` finding, and a genuine HTTP
error is reported with its status (e.g. `put-failed:… (HTTP 422)`) instead of being
swallowed.

#### Self-managing meta-repos: `SKIP_REPOS` + `SKIP_OVERRIDES`

`deploy-standard-workflows.sh` exempts a small set of **self-managing meta-repos**
from the blanket sweep via its `SKIP_REPOS` list — currently `.github` (the source
of truth; its callers use local `./` refs a channel-pinned stub must never
overwrite) and `.github-private` (self-manages its own workflow fleet). A `SKIP_REPO`
is exempt from the blanket sweep; explicit `SKIP_OVERRIDES` entries bypass that
exemption and may deploy an opted-in workflow stub.

But the compliance audit requires every **universal-required** workflow (see
[Required Workflows](#required-workflows)) on **every** repo — a `SKIP_REPO` is not
exempt from the audit. So a `SKIP_REPO` must still *satisfy* each
required-and-deployable workflow. There are exactly **two** canonical ways it may
do so, and every such workflow MUST use one of them:

1. **Self-manage it.** The repo hosts the workflow file in its own tree (present
   verbatim, or re-pinned in place as a channel consumer). Declare this in the
   deploy script's `SKIP_SELF_MANAGED` map so the config is a complete account of
   how the repo satisfies the standard.
2. **Opt into the sweep** for that one workflow via `SKIP_OVERRIDES` (keyed by
   workflow filename → space-separated repos). The sweep then deploys *that* stub
   — pinned at the repo's computed canary tier — while the repo stays exempt from
   all other stubs. This is how `.github-private` receives `pr-auto-review.yml`
   (reconciled in [#847](https://github.com/petry-projects/.github/issues/847))
   and `add-to-project.yml`.

A required-and-deployable workflow left in **neither** bucket is drift: the sweep
skips it and the audit flags it `missing-<workflow>` on that repo **forever**,
with no reconciliation path. `reconcile_skip_repo_required_workflows()` in
`deploy-standard-workflows.sh` is the codified guard for this invariant — it
fails (and its bats suite goes red) if any `SKIP_REPO` has a required-and-deployable
workflow that is neither self-managed nor opted-in. Promoting a new workflow to
universal-required therefore REQUIRES deciding, for each `SKIP_REPO`, which of the
two buckets it lands in. (Manual-only required workflows — `ci.yml`, `sonarcloud.yml`
— are not part of the sweep and so are outside this guard.)

---

## Required Workflows

Every repository MUST have these 10 workflows. Reusable templates for Dependabot
and AgentShield workflows are in [`standards/workflows/`](workflows/). The CI,
SonarCloud, and Dev-Lead Agent workflows are documented as patterns
below — copy and adapt the examples to each repo's tech stack. CodeQL is
**not** a workflow file: it is configured via GitHub-managed default setup
(see [§2](#2-codeql-analysis-github-managed-default-setup)).

| # | Workflow | Notes |
|---|----------|-------|
| 1 | `ci.yml` | Build-and-test pipeline (per tech stack) |
| 2 | `sonarcloud.yml` | SonarCloud analysis |
| 3 | `dev-lead.yml` | Dev-Lead Agent |
| 4 | `dependabot-automerge.yml` | Dependabot auto-merge |
| 5 | `dependency-audit.yml` | Multi-ecosystem dependency audit |
| 6 | `agent-shield.yml` | AgentShield agent-config scan |
| 7 | `pr-review-mention.yml` | pr-review agent mention/assignment trigger |
| 8 | `feature-ideation.yml` | Weekly ideation pipeline — see the `project_context` rule below |
| 9 | `pr-auto-review.yml` | Automated AI code review on PRs |
| 10 | `initiative-driver.yml` | Releases ready sub-issues of `initiative:auto` epics to dev-lead |

`feature-ideation.yml`, `pr-auto-review.yml`, and `initiative-driver.yml` were
promoted from optional/BMAD-conditional to **required org-wide** in
[#844](https://github.com/petry-projects/.github/issues/844). All three ship as
thin caller stubs deployed by `deploy-standard-workflows.sh`.

> **`feature-ideation.yml` — the `project_context` invariant.** Presence of the
> file is necessary but **not** sufficient. The seed stub ships a `TODO:`/`Example:`
> placeholder `project_context`; each adopting repo MUST replace it with a real
> 3-5 sentence per-repo description before the weekly run does anything useful.
> The audit raises a separate `feature-ideation-placeholder-context` **warning**
> for any repo whose stub is still on the seed placeholder. See
> [§9 Feature Ideation](#9-feature-ideation-feature-ideationyml--bmad-method-repos).

In addition, BMAD Method-enabled repositories MUST also include the conditional
[Feature Ideation workflow](#9-feature-ideation-feature-ideationyml--bmad-method-repos)
documented below — see [`standards/workflows/feature-ideation.yml`](workflows/feature-ideation.yml)
for the template.

### 1. CI Pipeline (`ci.yml`)

The primary build-and-test workflow. Structure varies by tech stack but must include:

| Stage | Purpose | Required |
|-------|---------|----------|
| **Lint** | Static analysis / style enforcement | Yes |
| **Format check** | Formatting verification | Yes |
| **Type check** | Type safety (where applicable) | Yes |
| **Unit tests** | Fast, deterministic tests | Yes |
| **Coverage** | Code coverage reporting | Yes |
| **Integration tests** | Backend/API integration | If applicable |
| **E2E tests** | End-to-end functional tests | If applicable |
| **Build / Docker build** | Verify the artifact builds | If applicable |

**Standard triggers:**

```yaml
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
```

**Standard configuration patterns:**

```yaml
permissions: {}   # Reset top-level; set per-job (see Permissions Policy below)

concurrency:
  group: ci-${{ github.ref }}-${{ github.sha }}
  cancel-in-progress: true
```

> **Why SHA-scoped concurrency?** Per-ref groups (`ci-${{ github.ref }}`) with
> `cancel-in-progress: true` create a race: if the final push arrives while the
> previous cancellation is in flight, GitHub may not fire a new
> `pull_request: synchronize` event, leaving the HEAD commit with no CI results
> and blocking the PR indefinitely. Scoping the group to the commit SHA gives
> every commit its own concurrency slot so CI always runs to completion.
>
> **Why keep `cancel-in-progress: true`?** With SHA-scoped groups, no two
> pushes share a slot, so the setting is a no-op in practice. It is kept
> explicitly to signal intent — if someone later changes the group formula back
> to a per-ref pattern, the cancellation behaviour they expect is already
> declared and will take effect immediately without a separate edit.

### 2. CodeQL Analysis (GitHub-managed default setup)

Static Application Security Testing (SAST) via GitHub's CodeQL, configured
through **default setup** (Settings → Code security → Code scanning), not via
a per-repo workflow file.

**Why default setup, not a `codeql.yml` workflow:**

Every prior version of this standard required each repo to carry an
`advanced` CodeQL workflow file. In practice the workflow we copied across
the fleet did nothing that default setup doesn't already do — no custom
query packs, no path filters, no build steps, no language matrix beyond a
single auto-detected ecosystem. The advanced setup gave us SHA-pinned
`github/codeql-action` references and an explicit `permissions: {}` block,
but `github/codeql-action` is a first-party GitHub action and the
permissions are managed by GitHub when default setup is enabled. The cost
of maintaining N copies of a workflow that re-derives what GitHub already
detects automatically outweighed the marginal supply-chain benefit.

**Default setup also gives us behavior the workflow file did not:**

- **Automatic language re-detection.** When a repo gains a new supported
  language (e.g. a Python utility lands in a TypeScript repo), default
  setup picks it up on the next scan. The static workflow file would
  silently miss it until somebody edited the YAML.
- **Managed analyzer versions.** No Dependabot bumps, no SHA churn, no
  drift between repos.
- **Lower CI surface area.** One fewer workflow file per repo to lint,
  audit, and centralize.

**Standard configuration (per repo):**

| Setting | Required value |
|---|---|
| Code scanning → Default setup | **Configured** (state = `"configured"`) |
| Languages | All CodeQL-supported languages auto-detected from the default branch |
| Query suite | `default` (use `extended` only when a documented threat model justifies the noise) |
| Schedule | Weekly (managed by GitHub; not configurable) |
| Triggers | Push to default branch and PRs targeting it (managed by GitHub) |

**Enabling default setup:**

```bash
# State the desired configuration. Languages may be omitted to let
# GitHub auto-detect, or enumerated explicitly.
gh api -X PATCH "repos/petry-projects/<repo>/code-scanning/default-setup" \
  -F state=configured \
  -F query_suite=default
```

> **Required token scope:** `repo` (classic) or `Administration: write` +
> `Code scanning alerts: write` (fine-grained). The org `apply-repo-settings.sh`
> script will run this automatically when onboarding new repos.

**`.github/workflows/codeql.yml` is now drift, not a requirement.** The
weekly compliance audit (`check_codeql_default_setup`) flags any repo whose
default setup is not in the `configured` state, **and** flags any repo that
still ships an inline `codeql.yml` workflow file as a remediation: delete
the file and enable default setup. The two configurations are mutually
exclusive at the GitHub level — leaving the workflow file behind after
flipping default setup on causes both to run and double-bills CI minutes.

**Status check name:** GitHub publishes default setup results under the
required-status-check context name **`CodeQL`** (single context, regardless
of how many languages are detected). The codified `code-quality` ruleset
([`standards/rulesets/code-quality.json`](rulesets/code-quality.json)) carries
the `CodeQL` context, applied to each repo by `apply-rulesets.sh`.

**Escape hatch — when advanced setup is justified:** A repo MAY revert to
an inline `codeql.yml` workflow only when it has a concrete need that
default setup cannot serve: a custom query pack, path filters to exclude
generated code, a build mode for a compiled language that needs a
non-default toolchain, or a language CodeQL supports only via manual
build. **Document the reason in the workflow file's header and open a
standards PR against this document** so the exception is recorded
alongside the rule.

### 3. SonarCloud Analysis (`sonarcloud.yml`)

Code quality, maintainability, security hotspots, and coverage tracking.

**Standard configuration:**

```yaml
name: SonarCloud Analysis

permissions: {}

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  sonarcloud:
    name: SonarCloud
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: read
    env:
      SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
    steps:
      - uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10 # v6.0.3
        with:
          fetch-depth: 0
      # First attempt. continue-on-error lets the retry step below recover from
      # transient 403/5xx responses from binaries.sonarsource.com (the scanner
      # CLI download), without failing the job on a single CDN blip.
      - name: SonarCloud Scan
        id: sonar
        if: env.SONAR_TOKEN != ''
        uses: SonarSource/sonarqube-scan-action@7006c4492b2e0ee0f816d36501671557c97f5995 # v8.1.0
        continue-on-error: true
      - name: SonarCloud Scan (retry)
        if: env.SONAR_TOKEN != '' && steps.sonar.outcome == 'failure'
        uses: SonarSource/sonarqube-scan-action@7006c4492b2e0ee0f816d36501671557c97f5995 # v8.1.0
```

**Required secrets:** `SONAR_TOKEN`

Each repo needs a `sonar-project.properties` file at root with project key and org.

**Why the retry?** `SonarSource/sonarqube-scan-action` first downloads the
SonarScanner CLI binary from `binaries.sonarsource.com`. That CDN occasionally
returns transient `403`/`5xx` responses unrelated to the workflow, secrets, or
runner — a single blip would otherwise fail the whole job and skew the fleet
failure-rate metric. The first scan step uses `continue-on-error: true` and an
`id`; the second step re-invokes the same pinned action only when the first
attempt reports `outcome == 'failure'`. The job fails only when both attempts
fail, so a single transient CDN error no longer trips the workflow.

#### SonarCloud Exemption: First-Party Reusable-Ref S7637

SonarCloud's GitHub Actions rule **`githubactions:S7637`** ("pin actions to a
full-length commit SHA") fires on first-party
`petry-projects/.github(-private)` reusable-workflow refs in thin caller stubs.
Those refs are **intentionally not SHA-pinned** — the org pins them to a moving
channel/tag (`@<name>/stable`, `@v1`/`@v2`) by design (see the
[Action Pinning Policy exemption](#exception-internal-reusable-workflow-references)).
The org compliance audit already exempts them via `check_action_pinning`, but
SonarCloud is an **external** gate that doesn't know about that exemption, so it
flags them as high-severity findings and can fail the quality gate.

**Standard (canonical — inline NOSONAR in the stub):** the first-party
channel-pinned `uses:` line in every caller stub MUST carry an inline
`# NOSONAR(githubactions:S7637)` marker, e.g.:

```yaml
jobs:
  dev-lead:
    # First-party channel tag — do NOT SHA-pin (AGENTS.md mutable-ref exception).
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/stable  # NOSONAR(githubactions:S7637) first-party channel ref
```

SonarCloud honors the inline comment and suppresses S7637 on exactly that line,
so the exemption travels **with the stub file** — adopters who copy the template
verbatim inherit it with **zero** per-repo `sonar-project.properties` entries and
**no file rename**. Spike-validated on `bmad-bgreat-suite#334` (`3cbfa005`):
Quality Gate ERROR → OK, `new_security_rating` C → A, required `SonarCloud`
check fail → pass.

The marker goes **only on first-party reusable-ref lines** pinned to a moving
channel/tag (`@<name>/stable`, `@v1`/`@v2`). A SHA-pinned ref (e.g.
`feature-ideation.yml`'s `@<sha> # v1`) already satisfies S7637 and gets **no**
marker. Third-party actions stay SHA-pinned and S7637-enforced; never add a
blanket glob or a file-wide disable.

Caller-stub templates carrying a channel-pinned first-party reusable ref (and
therefore the inline marker): `dev-lead.yml`, `agent-shield.yml`,
`pr-review-mention.yml`, `pr-auto-review.yml`, `auto-rebase.yml`,
`dependabot-rebase.yml`, `dependabot-automerge.yml`, `dependency-audit.yml`,
`add-to-project.yml`, `idea-triage.yml`, `idea-enhancer.yml`,
`initiative-planner.yml`. Copy each template verbatim from
[`standards/workflows/`](https://github.com/petry-projects/.github/tree/main/standards/workflows)
and the marker comes with it.

**Legacy (per-file `sonar-project.properties` — optional, transitional):** the
older mechanism suppressed S7637 **only on the individual caller-stub workflow
files** via one `sonar.issue.ignore.multicriteria` criterion per file path. It
still works and is **accepted during the transition**, but is no longer required
once the stubs carry the inline marker — the inline marker is the canonical
mechanism and auto-covers any newly added channel-pinned stub without a per-repo
edit. A blanket `resourceKey` such as `**/.github/workflows/*.yml`, `*.yml`, or
`**` remains **forbidden**: it would also drop S7637 on `ci.yml` /
`sonarcloud.yml`, leaving third-party actions un-enforced.

```properties
# Legacy / optional — only needed for stubs not yet carrying the inline marker.
sonar.issue.ignore.multicriteria=s7637_agentshield,…
sonar.issue.ignore.multicriteria.s7637_agentshield.ruleKey=githubactions:S7637
sonar.issue.ignore.multicriteria.s7637_agentshield.resourceKey=**/agent-shield.yml
# …one ruleKey/resourceKey pair per caller-stub file
```

The compliance audit's `check_sonar_s7637_exemption` enforces this org-wide: a
repo is compliant when every channel-pinned first-party caller stub carries the
inline marker **or** (during transition) the legacy per-file properties
exemption is present. It files `sonar-s7637-exemption-missing` (warning) when a
SonarCloud-gated repo has neither, and `sonar-s7637-exemption-too-broad` (error)
when the legacy exemption uses a blanket workflow-path `resourceKey`.

#### SonarCloud Exemption: First-Party `secrets: inherit` S7635

SonarCloud's rule **`githubactions:S7635`** ("only pass required secrets to this
workflow") fires on the **`secrets: inherit`** line of a first-party caller stub.
Caller stubs pass `secrets: inherit` **by design** so the central reusable
receives every secret it needs (e.g. `GH_PAT_WORKFLOWS` + `CLAUDE_CODE_OAUTH_TOKEN` + more) without each caller enumerating — and re-enumerating on every reusable
change. The reusable is **first-party and fully trusted**, the same trust boundary
that exempts the channel ref from S7637 above.

**Standard (canonical — inline NOSONAR on the `secrets:` line):** every
first-party caller stub that uses `secrets: inherit` MUST carry an inline
`# NOSONAR(githubactions:S7635)` marker on that line, e.g.:

```yaml
jobs:
  idea-triage:
    uses: petry-projects/.github/.github/workflows/idea-triage-reusable.yml@idea-triage/stable  # NOSONAR(githubactions:S7637) first-party channel ref
    secrets: inherit  # NOSONAR(githubactions:S7635) first-party trusted reusable
```

Like the S7637 marker, SonarCloud suppresses S7635 on exactly that line, so the
exemption travels **with the stub file** — verbatim adopters inherit it with
**zero** per-repo `sonar-project.properties` entries. The grandfathered existing
deployments pass because they are not "new code"; the rule only bites a stub the
first time it is **added** to a SonarCloud-gated repo. (The legacy per-file
`sonar.issue.ignore.multicriteria` mechanism with `ruleKey=githubactions:S7635`
also works and is accepted during transition, but the inline marker is canonical.)

Caller-stub templates that use `secrets: inherit` and therefore carry the S7635
marker: `initiative-planner.yml`, `idea-triage.yml`, `idea-enhancer.yml`,
`persona-mention.yml`, `dev-lead.yml`, `auto-rebase.yml`,
`dependabot-automerge.yml`. Every template with a `secrets: inherit` line now
carries the marker; the
[`s7635-secrets-inherit.bats`](https://github.com/petry-projects/.github/blob/main/test/scripts/standards-templates/s7635-secrets-inherit.bats)
template guard fails CI if any such line drops it (mirrors the S7637 v-form pin
guard).

Stubs that pass secrets **explicitly** (least privilege — no `secrets: inherit`
line, e.g. `add-to-project.yml`, `pr-review-mention.yml`) never trip S7635 and
carry **no** marker. Do not add one, as the marker is only necessary for `secrets: inherit` lines, which these stubs lack.

### 4. Secret Scanning (`ci.yml` — gitleaks job)

Secret detection via the gitleaks action. This job **must be added to the CI pipeline**
for all organization repositories. The job scans commit history for hardcoded secrets,
API keys, and other sensitive data.

**Why a separate job?** Gitleaks requires a license key when scanning organization
repositories (free for open-source). The job is part of the main `ci.yml` pipeline
but documented separately to clarify the licensing requirement.

**Standard configuration:** See the canonical job specification in
[`push-protection.md` — Layer 3: CI Secret Scanning](push-protection.md#layer-3--ci-secret-scanning-secondary-defense).

**Organization repos only — GITLEAKS_LICENSE requirement:**

When adding the `secret-scan` job to an organization repository's `ci.yml`, you **must**
pass the `GITLEAKS_LICENSE` secret to the gitleaks action:

```yaml
      env:
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        GITLEAKS_LICENSE: ${{ secrets.GITLEAKS_LICENSE }}
```

Without this environment variable, gitleaks will fail with "missing gitleaks license"
when scanning in an organization context.

**Required secrets:** `GITLEAKS_LICENSE` (org-level, organization repositories only)

**License requirement:** Gitleaks is free for open-source, but organization scans
require a valid license. Obtain a free license at [gitleaks.io](https://gitleaks.io).

**License setup:**

1. Create or log into your account at [gitleaks.io](https://gitleaks.io)
2. Generate a free license key for your organization
3. Add the license as the org-level secret `GITLEAKS_LICENSE`:

   ```bash
   gh secret set GITLEAKS_LICENSE --org petry-projects --body "<license-key>"
   ```

**For personal/user repos:** The `GITLEAKS_LICENSE` environment variable is optional.
If omitted, gitleaks runs in open-source mode (free, no license needed).

**CI failure — common causes and fixes:**

| Failure | Root cause | Fix |
|---------|-----------|-----|
| `missing gitleaks license` | License not passed to action | Ensure env includes `GITLEAKS_LICENSE: ${{ secrets.GITLEAKS_LICENSE }}` |
| Secrets found | Legitimate secrets in the code | Use `.gitleaksignore` to allowlist false positives, or remove the secret |

### 5. Claude Code (`claude.yml`) — *Deprecated 2026-05*

> **Deprecated.** `claude.yml` has been removed from all `petry-projects` repos and replaced by
> `dev-lead.yml`. See [Adopting the Dev-Lead Agent](#adopting-the-dev-lead-agent) and
> [Migration from `claude.yml`](#migration-from-claudeyml). The content below is preserved for
> historical reference only.

AI-assisted code review on PRs and issue automation via Claude Code Action.
The template has been removed; see [Migration from `claude.yml`](#migration-from-claudeyml) below for the historical reference and migration path.

> **OIDC security constraint — `claude.yml` is immutable on PR branches.**
> Anthropic's token endpoint validates that `.github/workflows/claude.yml` on
> a PR branch is byte-for-byte identical to the same file on the default branch.
> Any diff — including SHA-pinning the `uses:` line, adding a trigger, or
> changing a comment — causes the OIDC token exchange to fail:
>
> ```text
> App token exchange failed: 401 Unauthorized — Workflow validation failed.
> The workflow file must exist and have identical content to the version
> on the repository's default branch.
> ```
>
> Claude Code will not run on that PR. Agents must not open PRs that modify
> `.github/workflows/claude.yml`. The caller stub template now includes a
> `paths-ignore` guard that prevents this workflow from triggering on PRs that
> only change this file. See also [Action Pinning Policy](#action-pinning-policy)
> for the reusable workflow ref exemption.
>
> **All three jobs require a checkout step.** The `claude` job (PR reviews), the
> `claude-issue` job (issue automation), and the `claude-ci-fix` job (CI failure
> response) each need `actions/checkout` **before** the `claude-code-action` step.
> Without it, `claude-code-action` cannot read `CLAUDE.md` or `AGENTS.md` and
> will error on every trigger. The weekly compliance audit
> (`check_claude_workflow_checkout`) detects repos missing the checkout step or
> the `check_run` trigger and creates a labeled issue to drive remediation.

The workflow has three jobs:

- **`claude`** (interactive mode) — reviews PRs and responds to `@claude`
  mentions in comments. No `prompt` input; runs in interactive mode.
- **`claude-issue`** (automation mode) — triggered when the `claude` label is
  applied to an issue. Uses a `prompt` to drive the full lifecycle:
  implement the fix, create a PR, self-review, resolve review comments,
  monitor CI, and tag the maintainer when ready for human review.
- **`claude-ci-fix`** (CI failure response) — triggered by `check_run:
  completed` when a non-Claude check fails on an open PR. Looks up the
  associated PR (falling back to the GitHub API when the webhook payload
  omits `pull_requests`), checks out the branch, reads the failure logs,
  applies the minimal fix, pushes, and comments with a summary. Requires
  the `check_run` trigger in the caller's `on:` block — the compliance audit
  verifies this is present.

**Billing:** This workflow uses Anthropic credits via `CLAUDE_CODE_OAUTH_TOKEN`,
not GitHub Copilot premium requests. This is distinct from the "Assign to Agent"
UI feature which consumes Copilot premium requests.

**Archived configuration — do not adopt.** The YAML below is a read-only historical reference;
`claude.yml` is no longer deployed in org repos. For the current AI-automation implementation,
see [Adopting the Dev-Lead Agent](#adopting-the-dev-lead-agent).

```yaml
name: Claude Code

on:
  pull_request:
    branches: [main]
    types: [opened, reopened, synchronize]
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]
  issues:
    types: [labeled]
  check_run:          # enables claude-ci-fix — do not remove
    types: [completed]

permissions: {}

jobs:
  # Interactive mode: PR reviews and @claude mentions
  claude:
    if: >-
      (github.event_name == 'pull_request' &&
        github.event.pull_request.head.repo.full_name == github.repository) ||
      (github.event_name == 'issue_comment' && github.event.issue.pull_request &&
        contains(github.event.comment.body, '@claude') &&
        contains(fromJson('["OWNER","MEMBER","COLLABORATOR"]'), github.event.comment.author_association)) ||
      (github.event_name == 'pull_request_review_comment' &&
        contains(github.event.comment.body, '@claude') &&
        contains(fromJson('["OWNER","MEMBER","COLLABORATOR"]'), github.event.comment.author_association))
    runs-on: ubuntu-latest
    timeout-minutes: 60
    permissions:
      contents: write
      id-token: write
      pull-requests: write
      issues: write
      actions: read
      checks: read
    steps:
      - name: Checkout repository
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          # Full history so Claude can rebase / pull / resolve conflicts against main
          # when the remote branch advances mid-run (e.g. auto-rebase merges).
          fetch-depth: 0
      - name: Run Claude Code
        if: github.event_name != 'pull_request' || github.event.pull_request.user.login != 'dependabot[bot]'
        uses: anthropics/claude-code-action@51ea8ea73a139f2a74ff649e3092c25a904aed7e # v1.0.123
        with:
          claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          additional_permissions: |
            actions: read
            checks: read
          # claude_args.--allowedTools replaces the action defaults — keep this
          # list broad enough to cover interactive workflows (rebases, conflict
          # resolution, gh CLI usage). Narrowing it has caused regressions.
          claude_args: |
            --allowedTools "Bash(git:*),Bash(gh:*),Bash(grep:*),Bash(find:*),Bash(jq:*),Bash(sed:*),Bash(awk:*),Bash(cat:*),Bash(ls:*),Bash(head:*),Bash(tail:*),Bash(wc:*),Bash(test:*),Edit,Write,Read,Grep,Glob,LS,MultiEdit,WebFetch,WebSearch,Task,TodoWrite,BashOutput,KillBash"

  # Automation mode: issue-triggered work — implement, open PR, review, and notify
  claude-issue:
    if: >-
      github.event_name == 'issues' && github.event.action == 'labeled' &&
        github.event.label.name == 'claude'
    concurrency:
      group: claude-issue-${{ github.event.issue.number }}
      cancel-in-progress: true
    runs-on: ubuntu-latest
    timeout-minutes: 60
    permissions:
      contents: write
      id-token: write
      pull-requests: write
      issues: write
      actions: read
      checks: read
    steps:
      - name: Checkout repository
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          fetch-depth: 1
      - name: Run Claude Code
        uses: anthropics/claude-code-action@51ea8ea73a139f2a74ff649e3092c25a904aed7e # v1.0.123
        with:
          claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          label_trigger: "claude"
          track_progress: "true"
          additional_permissions: |
            actions: read
            checks: read
          claude_args: |
            --allowedTools "Bash(git:*),Bash(gh pr create:*),Bash(gh pr view:*),Bash(gh pr comment:*),Bash(gh issue comment:*),Bash(gh run view:*),Bash(gh run watch:*),Edit,Write"
          prompt: |
            Implement a fix for issue #${{ github.event.issue.number }}.

            After implementing:
            1. Create a pull request with a clear title and description.
               Include "Closes #${{ github.event.issue.number }}" in the PR body.
            2. Self-review your own PR — look for bugs, style issues,
               missed edge cases, and test gaps. If you find problems, push fixes.
            3. Review all comments and review threads on the PR. For each one:
               - If you can address the feedback, make the fix, push, and
                 mark the conversation as resolved.
               - If the comment requires human judgment, leave a reply
                 explaining what you need.
            4. Check CI status. If CI fails, read the logs, fix the issues,
               and push again. Repeat until CI passes.
            5. When CI is green, all actionable review comments are resolved,
               and the PR is ready, read the CODEOWNERS file and leave a
               comment tagging the relevant code owners to review and merge.
```

*Historical secrets: `CLAUDE_CODE_OAUTH_TOKEN`*

*Historical labels: `claude` (color: `7c3aed`) — was required on every repo for issue-triggered automation.*

**How Claude followed org standards:** `claude-code-action` read `CLAUDE.md` from the repository
root. The org-level `.github/CLAUDE.md` was inherited by repos without their own. Each repo's
`CLAUDE.md` referenced `AGENTS.md` for cross-cutting standards. The `claude-issue` job added an
automation `prompt` for the issue-to-PR lifecycle. These behaviors are now handled by `dev-lead.yml`.

**Permissions note:** Both jobs used the same permission set: `contents: write` for branch/push
operations, `actions: read` and `checks: read` for CI monitoring via GitHub MCP tools.

**Dependabot behavior:** The Claude Code step in the `claude` job was skipped
for Dependabot PRs. The job still ran and reported SUCCESS to satisfy required
status checks. See [AGENTS.md](../AGENTS.md#claude-code-workflow-on-dependabot-prs).

**Issue trigger security:** The `issues: [labeled]` event fired when any user
with triage or write access applied a label. Only the `claude` label triggered
the workflow — other labels were ignored.

**Maintainer notification:** The `claude-issue` prompt read `CODEOWNERS` at
runtime to determine who to tag.

### 6. Dependabot Auto-Merge (`dependabot-automerge.yml`)

Automatically approves and squash-merges eligible Dependabot PRs.
See [`workflows/dependabot-automerge.yml`](workflows/dependabot-automerge.yml)
and the [Dependabot Policy](dependabot-policy.md) for full details.

### 7. Dependency Audit (`dependency-audit.yml`)

Vulnerability scanning for all package ecosystems.
See [`workflows/dependency-audit.yml`](workflows/dependency-audit.yml)
and the [Dependabot Policy](dependabot-policy.md).

### 8. AgentShield (`agent-shield.yml`)

Agent configuration security validation. Checks that CLAUDE.md and
AGENTS.md exist and follow standards, scans for secrets in agent config
files, validates SKILL.md frontmatter, and detects permission bypasses.
See [`workflows/agent-shield.yml`](workflows/agent-shield.yml) and the
[Agent Configuration Standards](agent-standards.md) for full details.

### 8. Auto-Rebase (`auto-rebase.yml`)

Keeps open non-Dependabot PRs up-to-date with the base branch.
A copy-paste ready template is available at [`standards/workflows/auto-rebase.yml`](workflows/auto-rebase.yml).

**Trigger:** every `push` to `main` (i.e., every merged PR) plus manual `workflow_dispatch`.

On each run the workflow:

1. Lists all open same-repo PRs excluding `dependabot[bot]` and fork PRs.
2. Keeps only the PRs that are **eligible** under the `eligibility` input (see below),
   then for each eligible PR that is behind the base branch, calls
   `PUT /pulls/{n}/update-branch` with `merge` method to fast-forward it.
   The `merge` method is used (never `rebase`) so existing approvals are not invalidated.
3. On `workflows` permission error: posts an idempotent comment (sentinel `<!-- auto-rebase-blocked -->`) asking the author to rebase manually.
4. On merge conflict (422): deletes any prior sentinel and posts a fresh comment
   (sentinel `<!-- auto-rebase-conflict -->`), which triggers the `claude-rebase`
   job in `claude-code-reusable.yml` to automatically resolve the conflict.
   If Claude cannot resolve it, it posts a clear failure comment with manual instructions.

**Eligibility:** Which behind PRs to update is selectable via a tunable
`eligibility` input:

| `eligibility` | Updates a behind PR when… |
|---------------|---------------------------|
| `all` (default) | always — every behind PR, including drafts |

The predicate lives in `.github/scripts/auto-rebase/lib/eligibility.sh` and is
unit-tested via bats; new modes (e.g. a future "front-of-queue N") can be added
there and selected through the `eligibility` input with no change to the
workflow file.

**Secrets:** `GH_PAT_WORKFLOWS` is optional but **required for `claude-rebase` to be triggered** —
comments posted with `GITHUB_TOKEN` do not fire `issue_comment` workflow runs (GitHub limitation).
Without it the sentinel comment still appears but no automatic resolution will run.
Dependabot PRs are excluded because `dependabot-rebase.yml` handles those.

**Compliance:** The compliance audit (`check_centralized_workflow_stubs`) verifies that repos adopting `auto-rebase.yml` use the canonical thin caller stub delegating to `petry-projects/.github/.github/workflows/auto-rebase-reusable.yml@v1`.

### 10. PR Review Mention (`pr-review-mention.yml`)

Triggers the pr-review agent whenever `@donpetry-bot` is mentioned in a PR
comment or review comment, or when `donpetry-bot` is assigned as a reviewer.
A copy-paste ready template is available at [`standards/workflows/pr-review-mention.yml`](workflows/pr-review-mention.yml).

**Trigger:** `issue_comment` (created), `pull_request_review_comment` (created),
`pull_request` (review_requested).

On each trigger the workflow:

1. Guards against non-PR issue comments. For the `review_requested` trigger, also guards
   against fork PRs (which cannot receive org secrets); comment-based triggers fire only
   in the base repo's context and are protected by the trust check below.
2. Verifies the actor is an OWNER, MEMBER, or COLLABORATOR — prevents external contributors
   from consuming review quota.
3. Posts an acknowledgement comment so the requester knows the agent is starting.
4. Fires a `repository_dispatch` event to `petry-projects/.github-private` with
   `event_type=pr-review-mention` and `client_payload.pr_url`, which triggers the
   review cascade.

**Required secrets:** `GH_PAT_WORKFLOWS` (classic PAT with `repo` scope) — already
present as an org-level secret; no per-repo setup needed.

**Compliance:** The compliance audit (`check_centralized_workflow_stubs`) verifies that
repos have `pr-review-mention.yml` as a thin caller stub delegating to
`petry-projects/.github/.github/workflows/pr-review-mention-reusable.yml@v2`.

### 11. Copilot Cloud Agent Setup (`copilot-setup-steps.yml`)

**Recommended for all repos.** Pre-installs tools and dependencies in the Copilot
cloud agent's ephemeral environment before the agent begins working. This is a
**Tier 2 per-repo template** because the setup steps are inherently tech-stack-specific.

**Why this matters:** Without a setup file Copilot discovers and installs dependencies
itself via trial and error — slow, non-deterministic, and impossible for repos with
private packages. Pre-installing dependencies via a deterministic setup file:

- Speeds up every agent session (no discovery phase)
- Ensures exact tool versions that match CI
- Makes internal/private packages available to the agent
- Surfaces missing instruction files (`AGENTS.md`, `copilot-instructions.md`) at
  session start so the agent is fully oriented before it touches any code

**Adoption:** Copy [`standards/workflows/copilot-setup-steps.yml`](workflows/copilot-setup-steps.yml)
verbatim to `.github/workflows/copilot-setup-steps.yml` in the target repo, then uncomment
the stack block(s) matching the repo's tech stack and delete the rest.

> **Important:** The file must be merged to the default branch before it takes effect —
> GitHub does not pick it up from feature branches.

**Constraints enforced by GitHub (not configurable):**

| Constraint | Value |
|---|---|
| Job name | Must be exactly `copilot-setup-steps` |
| `timeout-minutes` | Max 59 |
| `fetch-depth` on checkout | Always overridden by the agent |
| Customizable job keys | `steps`, `permissions`, `runs-on`, `services`, `snapshot`, `timeout-minutes` |
| Default branch required | Workflow only triggers when present on the default branch |

**Workflow trigger pattern** (standard — validates the file on change):

```yaml
on:
  workflow_dispatch:
  push:
    paths:
      - .github/workflows/copilot-setup-steps.yml
  pull_request:
    paths:
      - .github/workflows/copilot-setup-steps.yml
```

**Stack blocks** (see template for full commented examples with SHA-pinned actions):

| Stack | Actions used | Cache strategy |
|---|---|---|
| Node.js / npm | `actions/setup-node@v4` | Built-in npm cache via `cache: "npm"` |
| Node.js / pnpm | `pnpm/action-setup@v4` + `actions/setup-node@v4` | Built-in pnpm cache via `cache: "pnpm"` |
| Go | `actions/setup-go@v5` | Built-in module cache via `cache-dependency-path` |
| Python / pip | `actions/setup-python@v5` | Built-in pip cache via `cache: "pip"` |

**Optional additions** (uncomment in the template as needed):

| Optional step | Use when |
|---|---|
| Build step (`npm run build`) | Agent needs pre-built artifacts (generated types, dist files) to run tests |
| `gh-aw` MCP extension | Repo does heavy GitHub platform work (PR management, issue triage, release automation) |
| `services:` block | Agent needs a database or queue service running during tests (see Elasticsearch example in `github/docs`, SQL Server in `dotnet/efcore`) |

**Verify step** (required — always runs last): Prints tool versions and confirms
`AGENTS.md` exists. **Fails the job if `AGENTS.md` is missing** — a repo without
`AGENTS.md` violates agent-standards.md and the agent won't be properly oriented.

**Fetching the template programmatically:**

```bash
gh api repos/petry-projects/.github/contents/standards/workflows/copilot-setup-steps.yml \
  --jq '.content' | base64 -d > .github/workflows/copilot-setup-steps.yml
```

**Real-world inspiration** for advanced patterns (services, custom runners, Docker caching):

- Multi-language monorepo: `github/copilot-sdk`
- Node.js + Electron + custom runner pool: `microsoft/vscode`
- SQL Server + CosmosDB services: `dotnet/efcore`
- Docker image pre-pull with parallel caching: `Significant-Gravitas/AutoGPT`

---

## Conditional Workflows

These workflows are required only when a specific ecosystem is detected.

> **Note:** `feature-ideation.yml` (§9) is **no longer** ecosystem-conditional —
> it was promoted to **required org-wide** in
> [#844](https://github.com/petry-projects/.github/issues/844) and is listed in
> [Required Workflows](#required-workflows) above. The `initiative-driver.yml`
> stub in §10 was likewise promoted to required org-wide. The remaining §10 stubs
> (`initiative-planner.yml`, `idea-triage.yml`, `idea-enhancer.yml`) stay
> conditional. These sections are retained for their design detail.

### 9. Feature Ideation (`feature-ideation.yml`) — BMAD Method repos

**Status:** **Required org-wide** as of [#844](https://github.com/petry-projects/.github/issues/844)
(previously BMAD-conditional). Every repo MUST carry the stub, and its
`project_context` MUST be a real per-repo description — a stub still on the seed
`TODO:`/`Example:` placeholder is flagged `feature-ideation-placeholder-context`
(warning) by the audit. The BMAD Method framing below reflects the original
pilot; the pipeline itself is not BMAD-specific.

Scheduled weekly workflow that runs the BMAD Analyst (Mary) on **Claude Opus 4.6**
through a 5-phase multi-skill ideation pipeline, producing evidence-grounded
feature proposals as GitHub Discussions in the **Ideas** category. Each proposal
is a separate Discussion, updated by subsequent runs as the market and project
evolve.

**Triggers:** the weekly `schedule`, manual `workflow_dispatch`, **and
`discussion: created`**. `claude-code-action` aborts on `discussion` event
contexts, so the stub does **not** call the reusable inline on that event.
Instead a `redispatch` job — gated to new Discussions in the **Ideas** category,
skipping the bot's own creations — re-invokes the workflow via
`workflow_dispatch` (using `GH_PAT_WORKFLOWS`), forwarding the Discussion number
as the `target_discussion` input. The re-dispatched run puts the reusable in
**single-idea enhancement mode**: it researches and refines that one new idea and
posts a single enhancement comment, rather than running the broad scan.
Enhancement is a comment (which does not re-fire `created`), so there is no
trigger loop. This mirrors `initiative-planner.yml`'s redispatch bridge.

> **#571 — never reference the `inputs` context in the reusable `with:`.** A
> reusable-workflow call graph (`uses:` + `with:`) is validated at **workflow
> setup**, before and regardless of the calling job's `if:`. The `inputs`
> context is only populated for `workflow_dispatch` / `workflow_call`, so a
> `with:` value referencing `${{ inputs.* }}` fails the whole run (zero jobs,
> "Invalid workflow file") on the `discussion` trigger even though the `ideate`
> job is gated off it. The stub therefore resolves dispatch inputs in an
> ordinary `prep` job (whose step expressions run at job time and are skipped on
> `discussion`) and passes them to `ideate` via `needs.prep.outputs.*` — an
> always-valid context that defers the `with:` evaluation to run time. This is
> enforced by [`lint-caller.sh`](../.github/scripts/feature-ideation/lint-caller.sh)
> in the feature-ideation test suite.

**Backlog enhancement (backfill) + dry-run.** Beyond enhancing *newly-created*
Ideas, the reusable can **backfill the existing Ideas backlog**: dispatch with
`enhance_backlog: true` to sweep this repo's open, **human-authored**,
not-yet-enhanced Ideas and post **exactly one** enhancement comment on each
(bots and already-enhanced Ideas are skipped). Combine with `dry_run: true` to
**preview** — the intended per-Discussion comments are logged to the JSONL
artifact and nothing is posted:

```bash
# Preview the backfill (posts nothing):
gh workflow run feature-ideation.yml -R <owner>/<repo> -f enhance_backlog=true -f dry_run=true
# Run it for real:
gh workflow run feature-ideation.yml -R <owner>/<repo> -f enhance_backlog=true
```

Idempotency is **marker-continuous**: a Discussion is treated as already-enhanced
if it carries **either** `<!-- feature-ideation:enhanced -->` **or** the legacy
`<!-- idea-enhancer:enhanced -->`, so re-runs are no-ops and the cutover from the
former standalone `idea-enhancer` never double-enhances. `target_discussion`
(single-idea mode) takes precedence over `enhance_backlog` when both are set.

**Backlog enhancement (backfill) + dry-run.** Beyond enhancing *newly-created*
Ideas, the reusable can **backfill the existing Ideas backlog**: dispatch with
`enhance_backlog: true` to sweep this repo's open, **human-authored**,
not-yet-enhanced Ideas and post **exactly one** enhancement comment on each
(bots and already-enhanced Ideas are skipped). Combine with `dry_run: true` to
**preview** — the intended per-Discussion comments are logged to the JSONL
artifact and nothing is posted:

```bash
# Preview the backfill (posts nothing):
gh workflow run feature-ideation.yml -R <owner>/<repo> -f enhance_backlog=true -f dry_run=true
# Run it for real:
gh workflow run feature-ideation.yml -R <owner>/<repo> -f enhance_backlog=true
```

Idempotency is **marker-continuous**: a Discussion is treated as already-enhanced
if it carries **either** `<!-- feature-ideation:enhanced -->` **or** the legacy
`<!-- idea-enhancer:enhanced -->`, so re-runs are no-ops and the cutover from the
former standalone `idea-enhancer` never double-enhances. `target_discussion`
(single-idea mode) takes precedence over `enhance_backlog` when both are set.

**The pipeline (the reason this workflow exists):**

| Phase | Skill | Purpose |
|------:|-------|---------|
| 1 | Load Context | Read signals JSON, planning artifacts, README, codebase extension points |
| 2 | **Market Research** | Iterative evidence gathering — competitor moves, emerging capabilities, user-need signals. Loops until evidence base feels solid. |
| 3 | **Brainstorming** | Divergent ideation — 8-15 raw ideas, builds on Phase 2 evidence. Loops back to research if gaps appear. |
| 4 | **Party Mode** | Collaborative refinement — amplify, connect synergies, ground in feasibility, score on Feasibility/Impact/Urgency. Top 5 advance. |
| 5 | **Adversarial** | 5-question stress test ("So what?", "Who else?", "At what cost?", "What breaks?", "Prove it."). Only survivors are proposed. |
| 6-7 | Publish | Resolve Discussion category, then create new Discussions or comment on existing ones with deltas. |

The adversarial pass is the load-bearing part: ideas that survive it are
**robust and defensible**, with a documented rebuttal to the strongest objection.

| Setting | Value |
|---------|-------|
| **Model** | `claude-opus-4-6` (set via `ANTHROPIC_MODEL` env var on the step) |
| **Schedule** | Weekly (template uses Friday 07:00 UTC) |
| **Output** | GitHub Discussions in the Ideas category, one per proposal |
| **Inputs** | `focus_area` (optional), `research_depth` (quick/standard/deep) |
| **Permissions** | `contents: read`, `discussions: write`, `id-token: write` |
| **Required secrets** | `CLAUDE_CODE_OAUTH_TOKEN` (org-level) |
| **Typical cost** | ~$2-3 per run on Opus 4.6, standard depth, 25-40 turns |

**Prerequisite:** Discussions must be enabled with an "Ideas" category
(see [Discussions Configuration](github-settings.md#discussions-configuration)).

#### Architecture: reusable workflow + thin caller stub

To avoid duplicating ~600 lines of prompt logic across every BMAD repo —
and to let us tune the multi-skill pipeline in one place — the workflow is
split into two parts:

1. **Reusable workflow** (single source of truth, hosted in this repo):
   [`.github/workflows/feature-ideation-reusable.yml`](../.github/workflows/feature-ideation-reusable.yml).
   Contains both jobs (signal collection + analyst), the full prompt with
   the 5-phase pipeline, and the four critical gotchas (model selection,
   token override, etc.) hard-coded so they cannot regress.

2. **Caller stub** (copied into each adopting repo, ~60 lines):
   [`standards/workflows/feature-ideation.yml`](workflows/feature-ideation.yml).
   Defines the schedule, the `workflow_dispatch` inputs, and calls the
   reusable workflow with a single required parameter: `project_context`.

3. **Reputable Source List** (repo-local, per-repo):
   Each adopting repo maintains its own copy at `.github/feature-ideation-sources.md`
   (or the path passed via the `sources_file` workflow input).
   Use [`standards/feature-ideation-sources.md`](feature-ideation-sources.md)
   as a starter template, then customise it for your project. The Phase 2 prompt
   instructs Mary to read that file as her **starting set** for market research —
   vendor blogs, RSS feeds, podcasts, and YouTube channels organised by category.
   If the file is absent Mary falls back to open web search automatically.
   Each repo owns its own copy; add or remove entries via PR in that repo.

When we tune the prompt, the model, or the gotchas, we change one file in
this repo. Repos tracking `@main` pick up the change on their next scheduled
run; repos pinned to `@v1` pick it up only after the `v1` tag is updated and
then on their next scheduled run. The source list is repo-local and propagates
only within the repo that owns it.

#### Adopting in a new repo

1. Copy [`standards/workflows/feature-ideation.yml`](workflows/feature-ideation.yml)
   to `.github/workflows/feature-ideation.yml` in the target repo.
2. Replace the `project_context` value with a 3-5 sentence description of
   what the project is, who it serves, and the competitive landscape Mary
   should research. This is the **only** required edit.
3. (Optional) Copy [`standards/feature-ideation-sources.md`](feature-ideation-sources.md)
   to `.github/feature-ideation-sources.md` in the target repo and customise
   it for your project. Mary reads YOUR copy — not the central template — so
   each repo controls its own source list.
4. (Optional) Adjust the cron schedule, focus area choices, or pin to a
   tag instead of `@main` if you want change isolation.
5. Ensure GitHub Discussions is enabled with an "Ideas" category — see
   [Discussions Configuration](github-settings.md#discussions-configuration).
6. Confirm the org-level secret `CLAUDE_CODE_OAUTH_TOKEN` is accessible.

#### Critical gotchas (baked into the reusable workflow)

These were discovered during the TalkTerm pilot. They live in the reusable
workflow with inline warning comments — **do not remove them without
understanding why they exist:**

1. **`github_token: ${{ secrets.GITHUB_TOKEN }}` is passed explicitly.**
   The `claude-code-action` auto-generates its own GitHub App installation
   token (`claude[bot]`), which lacks the `discussions: write` scope.
   Without an explicit `github_token` input, every `createDiscussion` and
   `addDiscussionComment` mutation fails silently with `FORBIDDEN: Resource
   not accessible by integration` — the run reports success and produces
   no Discussions. Passing the workflow's `GITHUB_TOKEN` makes the job-level
   `permissions: discussions: write` grant apply.

2. **`ANTHROPIC_MODEL: claude-opus-4-6` is set as a step env var.**
   The action does not expose model selection as an input — it reads the
   `ANTHROPIC_MODEL` environment variable. Opus is required for the depth
   the multi-skill pipeline expects; Sonnet runs cheaper but produces
   noticeably shallower adversarial passes. The reusable workflow exposes
   this as the optional `model` input for callers that need an override.

3. **`show_full_output: true` is NOT enabled.**
   It echoes raw tool results to public action logs, which can leak secrets.
   The reusable workflow intentionally omits it.

4. **The Phase 2-5 sequence is structural, not cosmetic.**
   Each phase explicitly switches the agent's mindset ("skill"), which is
   what produces *defensible* ideas instead of plausible ones. Keep this
   structure when tuning the prompt.

#### Reusable workflow inputs

| Input | Required | Default | Notes |
|-------|----------|---------|-------|
| `project_context` | yes | — | 3-5 sentence project description; the only required input |
| `focus_area` | no | `''` | Optional research focus, typically wired to `workflow_dispatch` input |
| `research_depth` | no | `'standard'` | `quick` / `standard` / `deep` |
| `model` | no | `'claude-opus-4-6'` | Override only for cost experiments — see gotcha #2 |
| `timeout_minutes` | no | `60` | Analyst job timeout (signal collection has its own short timeout) |

| Secret | Required | Notes |
|--------|----------|-------|
| `CLAUDE_CODE_OAUTH_TOKEN` | yes | Org-level secret, must be passed explicitly by the caller |

#### Reference implementation

[`petry-projects/TalkTerm`](https://github.com/petry-projects/TalkTerm/blob/main/.github/workflows/feature-ideation.yml)
is the pilot adopter. The TalkTerm workflow is the standard caller stub
with `project_context` set to a TalkTerm-specific paragraph — no other
customisation.

---

### 10. Idea → Initiative pipeline (`initiative-planner.yml`, `idea-triage.yml`, `idea-enhancer.yml`) — BMAD Method repos

**Condition:** BMAD Method-enabled repos that want approved ideas turned into
tracked initiatives (epic + story DAG) automatically. Builds on
[Feature Ideation](#9-feature-ideation-feature-ideationyml--bmad-method-repos) —
ideation produces ideas; this pipeline triages, enriches, and (on human approval)
plans them.

**Prerequisite:** Discussions enabled with an "Ideas" category, and the
`idea:approved` label present on the repo.

#### Architecture: thin caller stub → dispatch reusable → central planner

Unlike feature-ideation (which runs the analyst inline), the BMAD Scrum Master
planner and the vendored BMAD frameworks live **once** in
`petry-projects/.github-private`. `claude-code-action` aborts on `discussion`
event contexts, so each stub's reusable **re-dispatches** the central
`workflow_dispatch` with the host repo passed as `target_repo`, rather than
planning inline. Three stub + reusable pairs, all pinned to their `<name>/stable`
channel:

| Stub (`standards/workflows/`) | Reusable (`.github/workflows/`) | Trigger → action |
|---|---|---|
| [`initiative-planner.yml`](workflows/initiative-planner.yml) | [`initiative-planner-reusable.yml`](../.github/workflows/initiative-planner-reusable.yml) | `discussion [labeled] idea:approved` (trusted actor) → central planner builds an **inert** epic + story DAG (`initiative`, **not** `initiative:auto`) in the host repo |
| [`idea-triage.yml`](workflows/idea-triage.yml) | [`idea-triage-reusable.yml`](../.github/workflows/idea-triage-reusable.yml) | weekly + dispatch → refresh the host repo's "Idea Promotion Queue" issue |
| [`idea-enhancer.yml`](workflows/idea-enhancer.yml) | [`idea-enhancer-reusable.yml`](../.github/workflows/idea-enhancer-reusable.yml) | new Ideas Discussion + weekly → enrich the host repo's un-enhanced ideas |
| [`initiative-driver.yml`](workflows/initiative-driver.yml) | _(none — direct `gh workflow run`)_ | `issues [closed, labeled] initiative:auto` + off-peak `schedule` → dispatches the central `initiative-driver` with `target_repo=<host>`; the central driver releases ready sub-issues of the host's `initiative:auto` epics to dev-lead |

Two human gates keep judgement with a maintainer: adding `idea:approved` to a
Discussion fires the planner; adding `initiative:auto` to the resulting epic
hands it to `initiative-driver` for auto-implementation.

#### Project-board funnel (hybrid)

Where a planner-created epic lands depends on the repo:

- **Consumer (fleet) repos** → the repo's **own** project board. Point the repo's
  [`add-to-project`](workflows/add-to-project.yml) at its repo-level project.
- **`petry-projects/.github` and `petry-projects/.github-private`** → the
  **org-level** project (`orgs/petry-projects/projects/1`, "Initiatives").

#### Adopting in a new repo

1. Copy [`standards/workflows/initiative-planner.yml`](workflows/initiative-planner.yml)
   and [`standards/workflows/initiative-driver.yml`](workflows/initiative-driver.yml)
   to `.github/workflows/` (and, optionally,
   [`standards/workflows/idea-triage.yml`](workflows/idea-triage.yml) and
   [`standards/workflows/idea-enhancer.yml`](workflows/idea-enhancer.yml)) in the
   target repo. Copy **verbatim** — the templates carry the inline
   `# NOSONAR(githubactions:S7637)` and `# NOSONAR(githubactions:S7635)` markers,
   so a SonarCloud-gated repo needs **no** `sonar-project.properties` edits (see
   [SonarCloud Exemption: First-Party Reusable-Ref S7637](#sonarcloud-exemption-first-party-reusable-ref-s7637)
   and [First-Party `secrets: inherit` S7635](#sonarcloud-exemption-first-party-secrets-inherit-s7635)).
2. Ensure Discussions is enabled with an "Ideas" category, and **create the gate
   labels** the pipeline relies on. The driver's `initiative:auto` gate **cannot be
   armed if its label is missing** (the driver pilot hit exactly this — see #888),
   so create them all up front:

   ```bash
   gh label create "idea:approved"      -R <owner>/<repo> -c 0E8A16 -d "Approved ideas ready for planning" 2>/dev/null || true
   gh label create "initiative"         -R <owner>/<repo> -c 1D76DB -d "Tracked initiatives (epics)" 2>/dev/null || true
   gh label create "initiative:auto"    -R <owner>/<repo> -c 0E8A16 -d "Armed initiatives for auto-implementation" 2>/dev/null || true
   gh label create "dev-lead"           -R <owner>/<repo> -c 5319E7 -d "Issues assigned to the dev-lead agent" 2>/dev/null || true
   gh label create "dev-lead:hands-off" -R <owner>/<repo> -c FBCA04 -d "Exclude from dev-lead agent automation" 2>/dev/null || true
   gh label create "initiative:hold"    -R <owner>/<repo> -c FBCA04 -d "Initiatives on hold" 2>/dev/null || true
   ```

3. Confirm the org-level secret `GH_PAT_WORKFLOWS` is accessible **and its owner
   has write access to the target repo** (the central planner writes the epic +
   sub-issues cross-repo with that PAT).
4. Point `add-to-project` per the hybrid funnel above.
5. Approve an idea: add `idea:approved` to an Ideas Discussion. The central
   planner materializes an inert epic + story DAG in the repo; review it and add
   `initiative:auto` to the epic to begin auto-implementation.

The cross-repo trigger is watched by the central
`initiative-planner-canary.yml` and Fleet Monitor stub-drift checks, so a silent
regression (e.g. the [#655](https://github.com/petry-projects/.github-private/issues/655)
stale-base revert class) surfaces on the first approval rather than going unnoticed.

---

## Scheduled Workflow Timing

**Origin.** This is the org-wide promotion of the repo-local "Scheduled
workflows" convention first established in
[`petry-projects/.github-private`](https://github.com/petry-projects/.github-private)
(epic `#722`, story `#726`), where it took that repo from a fleet-worst offender
to **0 minute-0 crons out of 20**. This section is the canonical, fleet-wide
statement of the rule; the `.github-private` repo-local section defers to it, and
so does every downstream repo. (Precedent: the same repo-local → org promotion
path the Cost-reporting section followed.)

### The standard

Every `schedule:` cron in a workflow MUST be offset **off the top of the hour**:

1. **No `0 * * * *`.** An hourly job pinned to minute 0 stacks the whole fleet's
   hourly load onto `:00`. If a job must run hourly, pick any other minute
   (`11 * * * *`, `37 * * * *`, …).
2. **No minute-0 starts at all.** The minute field of a `schedule:` cron MUST NOT
   be `0` — this applies to daily, weekly, and every-N-hours crons alike
   (`0 7 * * *`, `0 8 * * 1`, `0 */4 * * *` are all non-compliant). The top of
   the hour is GitHub's most contended slot; scheduled workflows there are the
   most likely to be **delayed or dropped** under load.
3. **Spread minutes across the hour.** Two workflows in the same repo MUST NOT
   share an identical cron expression. Choosing a distinct minute per workflow
   both de-collides them and smooths the repo's own load.
4. **Higher-frequency idempotent sweeps.** A safety-net sweep that only needs to
   run *eventually* (an every-N-hours reconciler, a chain-stall backstop) SHOULD
   use a coarse interval (`*/15`, `*/4h`) with a non-zero minute — never
   `0 * * * *`. Because these sweeps are idempotent, the exact minute is
   immaterial to correctness; picking a non-zero one keeps them off the
   contended slot at zero behavioural cost. Do **not** change a sweep's
   *frequency* to satisfy this rule — only its minute.

> **Change the minute field only.** When bringing an existing workflow into
> compliance, edit **only** the cron minute; never the hour, day-of-week, or
> frequency. Retiming *when* or *how often* a workflow runs changes its
> behaviour and is out of scope for a timing-compliance change.

### Picking the minute deterministically

Choose the offset by **hashing the workflow filename**, not by hand, so the CI
check and the chosen value always agree and a newly added workflow gets a
defensible, collision-resistant minute automatically. The canonical recipe lives
in [`scripts/lib/cron-timing.sh`](../scripts/lib/cron-timing.sh)
(`cron_offset_minute`): `cksum` of the basename, `% 59 + 1`, yielding a minute in
**1–59**. Distinct filenames hash to distinct minutes, which is what
de-collides workflows that previously shared a cron.

### CI enforcement

[`scripts/check-cron-timing.sh`](../scripts/check-cron-timing.sh) scans a repo's
`.github/workflows/*.yml`, fails on any cron whose minute field is `0`, and
prints the suggested replacement minute alongside a pointer to this section. It
is wired into this repo's `ci.yml` **Lint** job and its
`.dev-lead/scripts/dev-lead-lint.sh`, and is unit-tested by
[`test/scripts/cron-timing/`](../test/scripts/cron-timing). Downstream repos
adopting the check point it at their own `.github/workflows/` — the rule is the
same everywhere and defers to this section for its rationale.

> **Templates in `standards/workflows/` are deliberately not swept by this
> repo's check.** Retiming a template's cron changes what every consumer repo
> receives, i.e. downstream fan-out — tracked separately in
> [`petry-projects/.github-private#726`](https://github.com/petry-projects/.github-private/issues/726),
> not folded into a source-of-truth timing fix.

---

## Workflow Patterns by Tech Stack

### TypeScript / Node.js (npm)

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: actions/setup-node@v4
    with:
      node-version: '24'       # or 'lts/*'
      cache: npm
  - run: npm ci
  - run: npm run check         # lint + format
  - run: npm run typecheck     # tsc --noEmit
  - run: npm test              # unit tests + coverage
```

**Repos using this pattern:** google-app-scripts, ContentTwin

### TypeScript / Node.js (pnpm)

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: pnpm/action-setup@v4
  - uses: actions/setup-node@v4
    with:
      node-version: 24
      cache: pnpm
  - run: pnpm install --frozen-lockfile
  - run: pnpm run lint
  - run: pnpm run typecheck
  - run: pnpm run test
```

**Repos using this pattern:** broodly (TypeScript layer)

### Go

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: actions/setup-go@v5
    with:
      go-version: 'stable'   # Or pin to specific version (e.g., '1.24') matching go.mod
      cache-dependency-path: apps/api/go.sum
  - run: go vet ./...
  - uses: golangci/golangci-lint-action@v6
  - run: go test ./... -race -coverprofile=coverage.out
```

**Repos using this pattern:** broodly (Go API)

### TypeScript + Electron (npm)

```yaml
strategy:
  matrix:
    os: [ubuntu-latest, macos-latest, windows-latest]
steps:
  - uses: actions/checkout@v4
  - uses: actions/setup-node@v4
    with:
      node-version: 24
      cache: npm
  - run: npm ci
  - run: npm run typecheck
  - run: npm run lint
  - run: npm run format:check
  - run: npm test
  - run: npm run test:coverage
```

**Additional jobs for Electron:**

- Mutation testing (`npm run test:mutate`) — `continue-on-error: true`
- E2E tests via Playwright (`npx playwright test`) on macOS — `continue-on-error: true`

**Repos using this pattern:** TalkTerm

### Python

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: actions/setup-python@v5
    with:
      python-version: '3.x'
  # Project-specific: pip install, pytest, etc.
```

**Repos using this pattern:** _(none currently)_

---

## Action Pinning Policy

All GitHub Actions MUST be pinned to a specific commit SHA, not a tag or branch.

```yaml
# CORRECT — pinned to SHA
- uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2

# WRONG — mutable tag
- uses: actions/checkout@v4
```

**Rationale:** SHA pinning prevents supply-chain attacks where a tag is
force-pushed to a malicious commit. The comment after the SHA documents the
version for human readability.

Dependabot keeps pinned SHAs up to date via the `github-actions` ecosystem
entry in `dependabot.yml`.

### Looking Up the Correct SHA

> **Never guess or fabricate a SHA.** A SHA that doesn't exist in the upstream
> repo will fail at runtime — and worse, may "pass CI" if the job that uses it
> is conditionally skipped, leaving a latent failure waiting to bite the next
> developer.

Use the GitHub API to resolve a tag or branch to its current commit SHA:

```bash
# For a tag (e.g., v6.0.2)
gh api repos/actions/checkout/git/refs/tags/v6.0.2 --jq '.object.sha'

# For a branch (e.g., stable)
gh api repos/dtolnay/rust-toolchain/branches/stable --jq '.commit.sha'

# Verify a SHA exists in the upstream repo before pinning
gh api repos/actions/checkout/commits/de0fac2e4500dabe0009e67214ff5f5447ce83dd --jq '.sha'
```

**If the lookup fails or the network is unavailable, do not pin.** Leave the
action with its tag reference and document the blocker in the PR body so a
human can complete the fix. A correct unpinned reference is better than an
incorrect pinned one.

> **Note on examples in this document:** The "Workflow Patterns by Tech Stack"
> section uses tag references (e.g., `@v4`) for readability since those are
> illustrative patterns, not copy-paste templates. The "Required Workflows"
> section above uses SHA-pinned references where possible. When copying any
> example to a repository, always look up the current SHA for each action and
> pin to it with a version comment.

### Exception: Internal Reusable Workflow References

Calls to first-party `petry-projects/*` reusable workflows are **exempt from
SHA-pinning** — they are refs to workflows the org owns, not third-party
actions. Per [Reusable workflow versioning](#reusable-workflow-versioning--the-stable-channel),
pin them to the reusable's moving `stable` channel tag (a reusable still being
migrated keeps its current canonical tag in the interim). Never `@main`, never a
SHA.

```yaml
# CORRECT — pin a reusable workflow to its moving `stable` channel tag (pin once)
uses: petry-projects/<repo>/.github/workflows/<name>-reusable.yml@<name>/stable

# WRONG — a branch ref has no version boundary; a bad commit is instantly live for all callers
uses: petry-projects/<repo>/.github/workflows/<name>-reusable.yml@main

# WRONG — do not SHA-pin first-party reusable workflow refs (and a frozen pin needs a per-caller edit to roll out)
uses: petry-projects/<repo>/.github/workflows/<name>-reusable.yml@ee22b427cbce9ecadcf2b436acb57c3adf0cb63d
```

**Why:** Pinning the `uses:` line in a Tier 1 caller stub creates a diff from
the default branch. Anthropic's OIDC token endpoint validates that the
workflow file on a PR branch is identical to the default branch — any diff
causes `401 Workflow validation failed` and the agent cannot run on that PR.

The canonical tags (e.g. `@v1`, `@v2`) on `petry-projects/.github` are managed
deliberately (bumped only on backward-compatible releases) and are not subject
to tag-force-push risk because the org controls the tag. **Do not open
compliance PRs to pin these references.**

> **SonarCloud agrees via a scoped exemption, not a blanket disable.**
> SonarCloud's external `githubactions:S7637` gate doesn't know about this
> exemption, so each SonarCloud-gated repo suppresses S7637 *only on the
> first-party caller-stub files* — see
> [SonarCloud Exemption: First-Party Reusable-Ref S7637](#sonarcloud-exemption-first-party-reusable-ref-s7637).
> Third-party actions stay SHA-pinned.

---

## Permissions Policy

All workflows MUST follow the principle of least privilege:

```yaml
# Multi-job workflows: reset at top, set per-job
permissions: {}

jobs:
  my-job:
    permissions:
      contents: read          # Only what this job needs
```

For single-job workflows, top-level least-privilege permissions are acceptable
(e.g., `permissions: contents: read`) since there is only one job to scope.

**Common permission sets:**

| Workflow | Permissions |
|----------|------------|
| CI (build/test) | `contents: read` |
| SonarCloud | `contents: read`, `pull-requests: read` |
| Claude Code | `contents: write`, `id-token: write`, `pull-requests: write`, `issues: write`, `actions: read`, `checks: read` |
| Dependabot auto-merge | `contents: read`, `pull-requests: read` (+ app token for merge) |

> **CodeQL is not in this table** because it is configured via GitHub
> default setup, not a workflow file. GitHub manages the analyzer's
> permissions internally; no `permissions:` block exists in this repo to
> audit. See [§2 CodeQL Analysis](#2-codeql-analysis-github-managed-default-setup).
>
> **Note on admin operations from Claude Code:** GitHub Actions does **not**
> expose an `administration` permission scope. The valid set is documented at
> [docs.github.com](https://docs.github.com/en/actions/using-jobs/assigning-permissions-to-jobs).
> Admin-level operations the `claude-issue` job needs — creating repository
> rulesets, enabling Discussions, modifying repo settings — must be performed
> with a token that already carries the right scope. The reusable workflow
> passes `GH_PAT_WORKFLOWS` to `claude-code-action` for exactly this reason:
> as long as that org-level secret is a classic PAT with `repo` scope (which
> includes admin capability for the authenticated user's repos) or a
> fine-grained PAT with `Administration: Read and write`, admin calls
> succeed. Granting a non-existent workflow permission has no effect and
> will fail `actionlint`.

---

## Organization-Level Secrets for Standard CI

All secrets required by the standard CI workflows are configured at the
**organization level** and inherited by all repos automatically:

| Secret | Purpose |
|--------|---------|
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code Action authentication |
| `SONAR_TOKEN` | SonarCloud analysis authentication |
| `GITLEAKS_LICENSE` | Gitleaks secret scanning (organization repositories only) |
| `APP_ID` | GitHub App ID for Dependabot auto-merge |
| `APP_PRIVATE_KEY` | GitHub App private key for Dependabot auto-merge |

New repositories inherit these secrets with no additional configuration.
Repos with infrastructure beyond standard CI (e.g., GCP deployment) may
require additional repo-specific secrets.

---

## CI Job Naming Convention

CI job names become the GitHub status check names that branch protection
references. Use consistent, descriptive names:

| Pattern | Example | Notes |
|---------|---------|-------|
| Language / tool name | `TypeScript`, `Go`, `SonarCloud` | For multi-language repos |
| `build-and-test` | `build-and-test` | For single-language repos |
| `CodeQL` | `CodeQL` | Default-setup CodeQL — single context regardless of language count |
| `Analyze (actions)` | `Analyze (actions)` | Manual `codeql.yml` with `jobs.analyze.name: Analyze` — the language is appended in parentheses by `codeql-action`. Use `Analyze ({language})` (e.g. `Analyze (javascript-typescript)`) in required-check configs for repos with a per-repo `codeql.yml`. |
| `claude` | `claude` | Claude Code Action |

These names are referenced in branch protection required status checks.
Changing a job name requires updating the branch protection configuration.

> **Default vs manual CodeQL check names:** repos using GitHub-managed default
> setup (the org standard — see [§2](#2-codeql-analysis-github-managed-default-setup))
> produce a single `CodeQL` check. Repos with a hand-authored `codeql.yml` produce
> one `Analyze ({language})` check per language. If a ruleset was configured with
> `Analyze` (no language suffix), it will never be satisfied — use the language-qualified
> name that actually appears in the PR check list.

---

## Org-Level Workflows

The [`.github` repository](https://github.com/petry-projects/.github) contains
org-level workflows that run across all repositories:

### OpenSSF Scorecard (`org-scorecard.yml`)

- **Schedule:** Weekly (Monday 09:06 UTC — offset off the top of the hour per [Scheduled Workflow Timing](#scheduled-workflow-timing))
- **Purpose:** Security posture scoring for all public repos
- **Token Requirements (`ORG_SCORECARD_TOKEN`):** Must be a Fine-Grained Personal Access
  Token with **Repository access** set to "All repositories" (or specific audit targets).
  It requires **Administration: Read-only**, **Metadata: Read-only**, **Contents: Read-only**,
  and **Issues: Read and write**. Additionally, it requires **Organization: Metadata (Read-only)**
  to list repositories in the organization.
- **Behavior:** Creates/updates GitHub Issues with findings, auto-closes resolved findings
- **Skip list:** CII-Best-Practices, Contributors, Fuzzing, Maintained, Packaging, Signed-Releases
- **Pinned-Dependencies — first-party exemption:** Our first-party reusable refs
  deliberately use moving channel tags (see [Action Pinning Policy](#action-pinning-policy)),
  so Scorecard permanently docks `Pinned-Dependencies` and that finding can never
  reach 10/10. Third-party **action** pinning is already enforced by
  `check_action_pinning` in `scripts/compliance-audit.sh` (which exempts first-party),
  so an Actions-only Pinned-Dependencies finding is fully covered elsewhere and is
  suppressed (no issue) rather than looping forever. A finding is **still raised**
  when it includes a non-Actions gap (container image / pip / npm / go) that nothing
  else tracks — the suppression keys off Scorecard's per-detail dependency type.

---

## CI Auto-Fix Pattern

Some repositories implement automatic formatting fixes on PRs:

```yaml
autofix:
  needs: build-and-test
  if: >
    github.event_name == 'pull_request' &&
    github.event.pull_request.head.repo.full_name == github.repository
  runs-on: ubuntu-latest
  permissions:
    contents: write
  steps:
    - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
      with:
        ref: ${{ github.event.pull_request.head.ref }}
    - run: npm run format && npm run lint -- --fix
    - name: Commit fixes
      run: |
        if ! git diff --quiet; then
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add -A
          git commit -m "chore(ci): apply prettier/eslint auto-fixes"
          git push
        fi
```

**Repos using this pattern:** google-app-scripts

> **Note:** Auto-fix only runs on same-repo PRs (not forks) since it needs
> write access to the PR branch.

---

## Applying CI to a New Repository

1. **Determine tech stack** and select the matching workflow patterns above
2. **Create `ci.yml`** with lint, format, typecheck, and test stages
3. **Enable CodeQL default setup** via `apply-repo-settings.sh` (or `gh api -X PATCH repos/<org>/<repo>/code-scanning/default-setup -F state=configured`) — do **not** add a `codeql.yml` workflow file
4. **Add `sonarcloud.yml`** and configure `sonar-project.properties`
5. **Add `dev-lead.yml`** from [`standards/workflows/`](workflows/) for AI-driven PR automation
6. **Add `dependabot.yml`** from the appropriate template in [`standards/dependabot/`](dependabot/)
7. **Add `dependabot-automerge.yml`** from [`standards/workflows/`](workflows/)
8. **Add `dependency-audit.yml`** from [`standards/workflows/`](workflows/)
9. **Add `agent-shield.yml`** from [`standards/workflows/`](workflows/)
10. **Add `copilot-setup-steps.yml`** from [`standards/workflows/`](workflows/) — uncomment the
    stack block(s) that match the repo's tech stack, delete the rest, then merge to `main` and
    run manually from the Actions tab to verify
11. **Configure secrets** in the repository settings
12. **Set required status checks** in branch protection (see [GitHub Settings](github-settings.md))
13. **Pin all action references** to commit SHAs

---

## Current Repository CI Status

All five check categories are **required on every repository** (see
[GitHub Settings — code-quality ruleset](github-settings.md#code-quality--required-checks-ruleset-all-repositories)).
The specific ecosystems configured in each check depend on the repo's stack.

The **CodeQL** column reflects GitHub default setup state (`configured` vs
`not-configured`), not the presence of a workflow file. Repos still
carrying a per-repo `codeql.yml` after this standard lands are flagged as
drift, not as compliant.

| Repository | CI | CodeQL† | SonarCloud | Claude | Coverage | Dep Auto-merge | Dep Audit | Dependabot Config | Copilot Setup |
|------------|:--:|:------:|:----------:|:------:|:--------:|:--------------:|:---------:|:-----------------:|:-------------:|
| **broodly** | Yes | Pending | Yes | Yes | Yes | Yes | Yes | Yes | — |
| **markets** | — | Pending | Yes | Yes | — | Yes | Yes | Partial | — |
| **google-app-scripts** | Yes | Pending | Yes | Yes | Yes | Yes (older) | — | Non-standard | — |
| **TalkTerm** | Yes | Pending | — | — | Yes | — | — | — | — |
| **ContentTwin** | — | Pending | Yes | — | — | — | — | — | — |
| **bmad-bgreat-suite** | — | Pending | — | — | — | — | — | — | — |

† **CodeQL** values are listed as `Pending` for every repo because the
default-setup migration is the work this standard introduces; the next
weekly compliance audit (after `apply-repo-settings.sh` runs against the
fleet) will flip the cells to `Yes` or surface specific failures via the
`codeql-default-setup-not-configured` finding category. There is no
`codeql.yml` workflow column anymore — that file is drift, not signal.

### Gaps to Address

Every `—` in the table above is a gap that must be remediated. Priority order:

1. **bmad-bgreat-suite:** Missing all CI workflows — needs full onboarding (CodeQL default setup will be enabled as part of onboarding)
2. **ContentTwin:** Missing CI, Claude, Coverage, Dependabot — 4 of 8 categories missing
3. **TalkTerm:** Missing SonarCloud, Claude, Dependabot — 3 of 8 categories missing
4. **markets:** Missing CI pipeline and Coverage; Dependabot config only covers `github-actions` (missing `npm` ecosystem)
5. **google-app-scripts:** Missing dependency audit; Dependabot npm `limit:10` (should be `0` per policy); auto-merge uses older `--admin` bypass pattern
6. **All repos:** Enable CodeQL default setup via `apply-repo-settings.sh` and remove any pre-existing `codeql.yml` workflow file
7. **All repos:** Add `copilot-setup-steps.yml` — copy from [`standards/workflows/`](workflows/copilot-setup-steps.yml), uncomment the matching stack block, and merge to `main`

### Version Inconsistencies

All repos MUST align to the latest version of each action:

| Action | Target Version | Repos Needing Update |
|--------|---------------|---------------------|
| **SonarCloud action** | v7.0.0 | ContentTwin, google-app-scripts (currently v6) |
| **Claude Code Action** | v1.0.123 (`51ea8ea7`) | All repos should use the same pinned SHA |

> **`github/codeql-action` is no longer pinned per repo** because the
> standard no longer ships a `codeql.yml` workflow. GitHub manages the
> analyzer version internally for default-setup repos.

---

## Dev-Lead Agent

The dev-lead agent is a reactive, write-enabled automation that keeps pull requests in a clean, approvable, and mergeable state.
It responds to CI failures, bot reviews, human `@mentions`, and labeled issues.

### Concurrency, pinning, and the permission contract

The dev-lead stub is a **Tier-1 caller** ([Centralization tiers](#centralization-tiers)):
it is **full-file identical across every adopting repo, modulo the tier channel
pin** on its `uses:` ref and matching `agent_ref` (`@dev-lead/stable`, or a
canary-ring tag — see
[Reusable workflow versioning](#reusable-workflow-versioning--the-stable-channel)).
Its **`on:`, `permissions:`, and `concurrency:` surface is _not_
repo-adjustable**: editing a trigger, permission scope, or concurrency block on a
PR branch is drift, not a repo-specific liberty. Behavior changes go through the
reusable (or a standards PR that updates the template), promoted by moving the
channel tag centrally — never by editing this caller.

Three things are deliberately **not** tuned in the caller stub — they are owned
centrally so they cannot drift per repo:

- **Concurrency.** The stub carries **no `concurrency:` block**. Concurrency is
  centralized in `dev-lead-reusable.yml` with per-issue / per-PR / ci-relay
  lanes (`dev-lead-issue-<n>`, `dev-lead-pr-<n>`, `dev-lead-ci-relay-<sha>`,
  `cancel-in-progress: false`). This keeps a labeled-issue pickup from being
  cancelled by unrelated PR follow-up traffic — per-stub concurrency previously
  drifted into three incompatible variants and starved issue pickups
  (petry-projects/.github#402). Running lanes in parallel is safe because the
  agent checks out PR branches in an isolated worktree (petry-projects/.github-private#448).
- **Pin.** The stub pins the reusable's moving `stable` channel tag —
  `petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/stable`
  — and passes `with: { agent_ref: dev-lead/stable }` so dev-lead's own
  scripts/prompts checkout runs at the same pinned channel (it defaults to `main`
  when omitted). This is the org reusable-workflow versioning standard; see
  [Reusable workflow versioning](#reusable-workflow-versioning--the-stable-channel)
  for the policy, benefits, and release process.
- **Permissions.** The stub's `jobs.dev-lead.permissions` must grant the **full
  set that the reusable requests**:

  ```yaml
  permissions:
    contents: write
    pull-requests: write
    issues: write
    actions: read
    checks: read
    statuses: read
  ```

  A reusable workflow can only use permissions its caller grants; if the
  reusable requests a scope the stub lacks, **every consumer fails at startup**
  (`startup_failure`, with no runtime error). When the reusable needs a new
  scope, add it to the template **and** every shim *before* the reusable
  requests it — the `caller-permissions` CI guard in `.github-private` enforces
  that ordering.

To exclude a specific PR or issue from the agent — e.g. a PR that edits the
dev-lead workflow itself, so the agent doesn't pile commits onto its own infra
change — add the **`dev-lead:hands-off`** label; the classifier then skips every
event on it.

### Failed issue implementations: visibility & bounded auto-retry

When a labeled-issue implementation fails at the engine step **before a PR
exists** (e.g. a transient timeout — `124` — or a one-off engine error), the
agent no longer fails silently (petry-projects/.github-private#781):

- The failure is classified (`rate-limited` / `missing-binary` / `engine-error`)
  and surfaced **on the issue** with the cause, a run deep-link, and a redacted
  tail of the session output — plus a machine-readable marker
  `<!-- dev-lead-issue <N> status=<failed|rate-limited> attempt=<K> … -->`.
- The scheduled `dev-lead-retry` cron scans open `dev-lead`-labeled issues for
  that marker and re-dispatches a **`dev-lead-issue-retry`** `repository_dispatch`
  (honouring any rate-limit `reset=` window), up to **3 attempts**. A consumer's
  caller stub must therefore list `dev-lead-issue-retry` in
  `on.repository_dispatch.types` (the template does — see [Adopting](#adopting-the-dev-lead-agent)).
- After 3 attempts — or immediately for a deterministic `missing-binary` infra
  failure — the agent labels the issue **`dev-lead:needs-human`** and stops
  retrying it. The cron skips any issue carrying that label. Remove the label
  (and re-apply `dev-lead`) to re-engage.

The cron's three `repository_dispatch` retry types — `dev-lead-ci-failure`,
`dev-lead-reviews-retry`, and `dev-lead-issue-retry` — are all centrally owned in
`dev-lead-reusable.yml` (issue retries route to the issue lane via
`client_payload.issue_number`).

### Adopting the Dev-Lead Agent

1. Copy `standards/workflows/dev-lead.yml` verbatim to `.github/workflows/dev-lead.yml` in your repo.
2. Set `CLAUDE_CODE_OAUTH_TOKEN` as an org or repo secret (required).
3. Set `GH_PAT_WORKFLOWS` — a PAT with read access to `petry-projects/.github-private` — as an org or repo secret (required for cross-repo script access).
4. Optionally set `vars.DEV_LEAD_ENGINE` to `claude` (default), `gemini`, or `copilot`.
5. Optionally set `vars.DEV_LEAD_DRY_RUN=true` during the initial rollout period.
6. **If the repo is SonarCloud-gated**, the S7637 exemption is already baked
   into the stub: `dev-lead.yml`'s `uses:` line carries the inline
   `# NOSONAR(githubactions:S7637)` marker, so copying the template verbatim
   (step 1) is all that is required. `dev-lead.yml` is a first-party
   reusable-ref caller stub pinned to a moving channel tag — `@dev-lead/stable`,
   or a canary-ring tag (`@dev-lead/ring0` | `@dev-lead/ring1` | `@dev-lead/next`)
   under the [canary-rings rollout](#reusable-workflow-versioning--the-stable-channel).
   That mutable ref is intentionally **not** SHA-pinned, so without the marker
   SonarCloud's `githubactions:S7637` would flag it at HIGH severity, drive
   `new_security_rating` to **C**, and fail the Quality Gate — blocking the
   required `SonarCloud` check. The inline marker suppresses S7637 on exactly
   that line and travels with the file. **No `sonar-project.properties` entry is
   needed.** (The legacy per-file `s7637_devlead` criterion keyed to
   `**/dev-lead.yml` still works and is accepted during the transition, but is
   optional once the stub carries the marker.) See
   [SonarCloud Exemption: First-Party Reusable-Ref S7637](#sonarcloud-exemption-first-party-reusable-ref-s7637);
   `check_sonar_s7637_exemption` files `sonar-s7637-exemption-missing` only when
   a repo has neither the inline marker nor the legacy entry.

### Required secrets

| Secret | Required | Purpose |
|--------|----------|---------|
| `CLAUDE_CODE_OAUTH_TOKEN` | Yes | Primary LLM engine |
| `GH_PAT_WORKFLOWS` | Yes (cross-repo) | Read access to `.github-private` scripts; push workflow files |
| `GOOGLE_API_KEY` | No | Gemini engine fallback |
| `GH_PAT` | No | Copilot engine — **must be a fine-grained PAT.** Classic tokens (`ghp_…`) are rejected at runtime |

### Failure-mode runbook

When Fleet Monitor flags a `dev-lead.yml` stub as DEGRADED (failure rate > 10%),
the fix is almost never in the stub itself — the stub is a Tier-1 caller and
the centralized contract makes it byte-equivalent across repos. Match the
failed-run log line against the table below and act in the indicated repo.

| Log signature in failing run | Root cause | Where to fix |
|------------------------------|-----------|--------------|
| `Process completed with exit code 124` after a long-running `dispatch` step | Engine call timed out inside the reusable (per-tier `timeout`). For a **labeled-issue** run this now posts a cause-bearing marker and is auto-retried up to 3× before escalating to `dev-lead:needs-human` (see [Failed issue implementations](#failed-issue-implementations-visibility--bounded-auto-retry)) | `petry-projects/.github-private` — engine timeout / step-level `timeout-minutes` in `dev-lead-reusable.yml` |
| `_ApiError ... code:429 ... Resource has been exhausted` / `RetryableQuotaError` | `GOOGLE_API_KEY` project is out of quota or prepayment credits | Google AI Studio billing for the project backing `GOOGLE_API_KEY`; until refilled, the Gemini step of the engine-fallback cascade will keep failing |
| `Error: Classic Personal Access Tokens (ghp_) are not supported by Copilot` | `GH_PAT` is a Classic PAT and the engine cascade fell through to Copilot | Rotate `GH_PAT` to a fine-grained PAT at the org-secret level |
| `startup_failure` with no step logs | Stub is missing a permission the reusable now requests | Update **the template** in `standards/workflows/dev-lead.yml` and every adopting stub *before* the reusable starts requesting the scope (see [Concurrency, pinning, and the permission contract](#concurrency-pinning-and-the-permission-contract)) |

High cancellation counts on the run history are expected and not a defect:
the reusable uses per-issue / per-PR / ci-relay lanes with
`cancel-in-progress: false`, so queued events that another lane preempts still
register as cancelled runs in the metrics window.

When triage points at the reusable or an external secret, **close the Fleet
Monitor issue with a comment linking to the upstream fix** rather than editing
the stub — local edits to a Tier-1 stub are drift.

### Migration from `claude.yml`

The dev-lead agent supersedes `claude.yml`. Migration steps:

1. Add `dev-lead.yml` (from this standard).
2. Run both in parallel for at least 2 weeks (shadow period).
3. Confirm no regressions via the Actions run history.
4. Delete `claude.yml`.

See tracking issue petry-projects/.github-private#180 for the shadow period status of `.github-private` itself.

### Key differences from `claude.yml`

| Feature | `claude.yml` | `dev-lead.yml` |
|---------|-------------|----------------|
| OIDC byte-for-byte constraint | Yes | No |
| Engine-agnostic | No (Claude only) | Yes (claude/gemini/copilot) |
| Dry-run mode | No | Yes (`vars.DEV_LEAD_DRY_RUN`) |
| Anti-loop guard | No | Yes |
| Idempotency markers | No | Yes (SHA-based) |
| CI relay deduplication | No | Yes |
