# GitHub Repository Settings Standards

Standard configurations for all repositories in the **petry-projects** organization.
These settings are enforced via the GitHub UI, API, and repository rulesets.

---

## Organization-Level Settings

| Setting | Value | Notes |
|---------|-------|-------|
| **Default repository permission** | `read` | Least privilege; grant write/admin via teams |
| **Organization profile** | `petry-projects` | Public org (free plan) |
| **Default branch name** | `main` | Org-wide default for new repos |
| **Members can create repos** | Yes (public + private) | |
| **Two-factor requirement** | **Required** | All org members must have 2FA enabled |

---

## Repository Settings — Standard Defaults

All new repositories MUST be created with these settings. Existing repositories
SHOULD be audited and brought into compliance.

### General

| Setting | Standard Value | Rationale |
|---------|---------------|-----------|
| **Default branch** | `main` | All repos use `main` |
| **Visibility** | `public` | Default for org repos; private repos require justification |
| **Has Issues** | `true` | Issue tracking enabled on all repos |
| **Has Projects** | `true` | Currently enabled on all repos |
| **Has Wiki** | `false` | Disabled — documentation lives in the repo |
| **Has Discussions** | `true` | **Required** — enables Discussions for ideation, feedback, and community engagement (see [Discussions Configuration](#discussions-configuration)) |

### Security & Analysis

All repositories MUST have the following security features enabled. These are
the enforcement primitives behind the [Push Protection Standard](push-protection.md).
They are enabled org-wide via the "GitHub recommended" code security
configuration — see the [Advanced Security (GHAS) Standard](advanced-security.md).

| Setting | Standard Value | Rationale |
|---------|---------------|-----------|
| **Secret scanning** | `enabled` | Detect leaked credentials in history and new commits |
| **Secret scanning push protection** | `enabled` | Block pushes containing known secret patterns at the server side |
| **Secret scanning AI detection** | `enabled` | Catch generic secrets missed by regex patterns |
| **Secret scanning non-provider patterns** | `enabled` | Private keys, HTTP basic auth, high-entropy strings |
| **Dependabot security updates** | `enabled` | Automated patches for known-vulnerable dependencies |

> See the full requirements, custom patterns, CI job, incident response flow,
> and compliance audit checks in [`push-protection.md`](push-protection.md).

### Merge Settings

| Setting | Standard Value | Rationale |
|---------|---------------|-----------|
| **Allow squash merging** | `true` | **Primary merge method** — enforced by `pr-quality` ruleset |
| **Allow merge commits** | `true` | Enabled to avoid conflicts with admin overrides; `pr-quality` ruleset enforces squash-only |
| **Allow rebase merging** | `true` | Enabled to avoid conflicts with admin overrides; `pr-quality` ruleset enforces squash-only |
| **Allow auto-merge** | `true` | Required for Dependabot auto-merge workflow |
| **Automatically delete head branches** | `true` | Clean up merged branches automatically |
| **Default squash merge commit title** | `PR_TITLE` | Clean, descriptive commit history |
| **Default squash merge commit message** | Commit messages (`COMMIT_MESSAGES`) | Preserves individual commit messages |

> **Note:** While merge commits and rebase merging are enabled at the repository
> level, the `pr-quality` ruleset enforces **squash-only** merges. The repo-level
> settings are permissive to avoid conflicts with admin overrides when needed.

---

## Discussions Configuration

GitHub Discussions MUST be enabled on all repositories. Discussions serve as the
durable, threaded home for feature ideation, design proposals, and community
feedback — distinct from Issues (which track actionable work).

### Required Discussion Categories

All repositories MUST have the following categories configured:

| Category | Format | Emoji | Description |
|----------|--------|-------|-------------|
| **Ideas** | Open-ended | `💡` | Feature proposals, ideation threads, and innovation exploration |
| **General** | Open-ended | `💬` | General project discussions and questions |

Additional categories MAY be added per project needs (e.g., "Q&A", "Show and Tell",
"Polls"). The two above are the required minimum.

### Automated Ideation Workflow

Repositories with the [BMAD Method](https://github.com/bmad-code-org/BMAD-METHOD)
installed (`_bmad/` directory) MUST have the `feature-ideation.yml` workflow,
which uses the **Ideas** category to post and maintain feature proposal
Discussions. Each proposal is a separate Discussion thread, updated by subsequent
workflow runs as market signals and project context evolve. See
[CI Standards § Feature Ideation](ci-standards.md#8-feature-ideation-feature-ideationyml-bmad-method-repos)
for requirements.

### Setup

To enable and configure Discussions on an existing repository:

```bash
# Enable Discussions
gh api -X PATCH repos/<owner>/<repo> -f has_discussions=true

# Discussion categories are managed via the GitHub UI:
# Settings → General → Features → Discussions → Set up discussions
# Or via GraphQL after initial setup.
```

> **Note:** Discussion categories cannot currently be created via the REST API.
> Use the GitHub UI or GraphQL `createDiscussionCategory` mutation. The compliance
> audit checks that Discussions are enabled; category configuration is verified
> manually during onboarding.

---

## Repository Rulesets

Rulesets are the primary enforcement mechanism for branch policies. All
repositories MUST use rulesets on the default branch. Classic branch protection
rules are deprecated — migrate existing classic rules to rulesets.

### Source of truth & repo boundary

The codified ruleset JSONs are the source of truth for all rulesets;
`scripts/apply-rulesets.sh` (and any org automation consuming it) applies them to each repo.
As **org-wide compliance policy they are owned by `petry-projects/.github`**, and
their canonical home is `standards/rulesets/`. Do **not** author rulesets in
`petry-projects/.github-private` — that repo is scoped to agents/skills and their
reusable assets. All rulesets, including targeted ones like `release-channel-tags`,
are defined in `.github/standards/rulesets/`.
See the repo-boundary rule in [`AGENTS.md`](../AGENTS.md).

> **In transit:** `code-quality.json` and `pr-quality.json` currently still live
> in `.github-private/.github/rulesets/` and are being relocated to
> `standards/rulesets/` here — see
> [petry-projects/.github#575](https://github.com/petry-projects/.github/issues/575).

**`pr-quality` and `code-quality` are the only sanctioned rulesets.** Legacy
`protect-branches` rulesets and ad-hoc `main` rulesets are deprecated: they
duplicate protections and, because GitHub evaluates bypass eligibility per
ruleset, they are a second place every bypass actor must be kept in sync (the
trap that produced inconsistent `OrganizationAdmin` / `RepositoryAdmin` bypass
state across the fleet). They MUST be migrated into the two sanctioned rulesets
and removed. Deletion is only safe once every required status check the legacy
ruleset carries is ALSO required by a sanctioned ruleset — otherwise deletion
silently drops a merge gate. `check_legacy_rulesets()` in
[`scripts/compliance-audit.sh`](../scripts/compliance-audit.sh) flags each
legacy ruleset and reports the exact migration delta (checks to move into
`code-quality` first, or "safe to delete").

**Source of truth.** All ruleset JSONs — `pr-quality`, `code-quality`, and
`release-channel-tags` — live in this repo at [`standards/rulesets/`](rulesets/).
`.github` owns org-wide compliance policy (see [`AGENTS.md`](../AGENTS.md#organization-standards)
for the repo-boundary rule, codified in #576). Run `apply-rulesets.sh` to converge each
repo's live ruleset to the desired state documented here.

**Compliance check — contents, not just presence (#766).** The weekly audit does
not merely verify that a ruleset with the right *name* exists.
`check_ruleset_contents()` in [`scripts/compliance-audit.sh`](../scripts/compliance-audit.sh)
compares each live `pr-quality` / `code-quality` ruleset against its codified
source in [`standards/rulesets/`](rulesets/) and raises a finding **per drifted
parameter** — naming the parameter, the expected value, and the actual value.
It covers `required_approving_review_count`, `require_code_owner_review`,
`required_review_thread_resolution`, `dismiss_stale_reviews_on_push`,
`require_last_push_approval`, `allowed_merge_methods`, and (for `code-quality`)
`required_status_checks`. Only codified parameters are compared, so API-only
fields never produce noise. `required_status_checks` uses **subset** semantics —
every codified context must be present, but repo-specific *additional* checks are
allowed (see [`code-quality`](#code-quality--required-checks-ruleset-all-repositories)
below); a *missing* codified context is drift. The check **fails closed**: a
ruleset that cannot be fetched or parsed is a finding, never a silent pass. This
means flipping `required_review_thread_resolution` to `false`, lowering the
review count, dropping `require_code_owner_review`, or widening
`allowed_merge_methods` is now caught — previously the audit passed as long as a
ruleset by that name existed.

> **Remediating ruleset findings is a manual, admin-token procedure** —
> `compliance-remediate.sh` skips the `rulesets` category. Follow the
> [Ruleset Remediation Runbook](ruleset-remediation-runbook.md) (snapshot →
> bypass actors → migrate-then-delete legacy → verify → rollback).

### Bypass Actors — Required on Every Ruleset Targeting `main`

**The `dependabot-automerge-petry` GitHub App MUST be a bypass actor on every
ruleset that targets the default branch**, not only on `pr-quality`. GitHub
evaluates bypass eligibility independently per ruleset — having bypass in
`pr-quality` does NOT grant bypass in `protect-branches`, `main`, or any other
ruleset applied to the same branch. Every such ruleset must include:

| Actor | Type | `bypass_mode` | Reason |
|-------|------|--------------|--------|
| `dependabot-automerge-petry` | GitHub App | `always` | Merges Dependabot PRs via API; rejected without bypass in every active ruleset |
| `OrganizationAdmin` | Role | `always` | Emergency admin override |

**Why `bypass_mode: always`:** `pull_request` bypass mode only works when the
bypass actor *opens* the PR. Dependabot opens its own PRs, so the
`dependabot-automerge-petry` app cannot use that mode — its merge API calls are
rejected. `always` mode is safe here because the rebase workflow explicitly
verifies CI pass and `MERGEABLE` state before calling the merge API.

**Remediation — `scripts/fix-ruleset-bypass.sh`:** normalizes bypass actors on
**every** ruleset targeting the default branch (including legacy
`protect-branches` / `main` rulesets that `apply-rulesets.sh` does not manage).
Existing actors are preserved; the two required actors are added/normalized to
`bypass_mode: always`. Dry-run emits ready-to-PUT payloads for review without
mutating live rulesets:

```bash
# Preview payloads for one repo (or --all):
GH_TOKEN=<admin-token> ./scripts/fix-ruleset-bypass.sh <repo> --dry-run

# Apply:
GH_TOKEN=<admin-token> ./scripts/fix-ruleset-bypass.sh --all
```

> `apply-rulesets.sh` full-replaces `pr-quality` / `code-quality` with the two
> canonical bypass actors. `fix-ruleset-bypass.sh` is the least-destructive,
> any-ruleset complement used to remediate audit findings.

**Compliance check:** enforced automatically by the weekly audit —
`check_ruleset_bypass_actors()` in [`scripts/compliance-audit.sh`](../scripts/compliance-audit.sh)
verifies that every ruleset targeting the default branch grants `bypass_mode:
always` to both required actors, and flags the `Repository admin` role
(`RepositoryRole` id 5) as a non-conforming substitute for `OrganizationAdmin`.

### `pr-quality` — Standard Ruleset (All Repositories)

| Setting | Value |
|---------|-------|
| **Target branches** | Default branch (`main`) |
| **Enforcement** | Active |
| **Required approving reviews** | 1 |
| **Dismiss stale reviews on push** | **Yes** — prevents merging unreviewed code after approval |
| **Required review thread resolution** | **Yes** — all threads must be Resolved before merge |
| **Require code owner review** | **Yes** — requires approval from a CODEOWNERS-defined owner |
| **Require last push approval** | **Yes** — ensures different people review substantive code changes; Dependabot rebase workflow re-approves after branch updates to maintain approval validity |
| **Allow auto-merge** | **Yes** — enables automatic merge when all status checks pass and requirements are satisfied |
| **Allowed merge methods** | **Squash only** |
| **Allow force pushes** | No |
| **Allow deletions** | No |

> **CODEOWNERS:** All repos MUST have a `CODEOWNERS` file. Without one, the
> "Require code owner review" setting has no effect. See the
> [CODEOWNERS Standard](#codeowners-standard) below for the required format.

#### Auto-Merge Configuration

The **Allow auto-merge** setting enables PRs to merge automatically once all status checks pass and review requirements are satisfied. This is required for:

- **Dependabot auto-merge workflows** — enables `gh pr merge --auto` API calls
- **Agentic PR automation** — CI/CD agents can queue PRs for automatic merge after approval and check passage
- **Efficient CI workflows** — avoids manual merge steps when all quality gates have passed

Auto-merge is a **safe setting** because the ruleset still enforces all approval and review requirements before
the merge occurs — the automation only handles the final merge step after human review and all CI checks pass.
See [GitHub's auto-merge documentation](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/automatically-merging-a-pull-request)
for more details.

##### `standards-sync` PRs — clearing the reviewer deadlock without `--admin`

`standards-sync` / dev-lead remediation PRs cannot satisfy `pr-quality`
unaided: with CODEOWNERS = `* @petry-projects/org-leads` = `{don-petry,
donpetry-bot}`, an author=one-lead / last-pusher=other-lead PR disqualifies
**both** code-owners (author can't self-approve; the last pusher's approval is
voided by `require_last_push_approval`), so historically only an `--admin` bypass
merged them. [`scripts/automerge-standards-sync.sh`](../scripts/automerge-standards-sync.sh)
resolves this **through** the ruleset: it approves as the code-owner that is
neither the author nor the last pusher (a legitimate code-owner + last-push +
not-own-PR approval), then enables **native auto-merge** so GitHub merges on
required-checks-green — no `--admin`, no human click, required-check gates
unchanged. See the [Ruleset Remediation Runbook §6](ruleset-remediation-runbook.md#6-merging-standards-sync-prs-through-protection-no---admin).

#### Bypass Actors

See [Bypass Actors — Required on Every Ruleset Targeting `main`](#bypass-actors--required-on-every-ruleset-targeting-main) above.
The same `dependabot-automerge-petry` + `OrganizationAdmin` bypass actors MUST appear in `pr-quality` and in every other ruleset that targets `main`.

#### CODEOWNERS Approval Timing

GitHub evaluates code owner status **at the time an approval is submitted**, not
retroactively. If `CODEOWNERS` is updated (e.g., adding bot accounts), approvals
already on open PRs from those accounts are not retroactively credited as code
owner approvals.

**Recovery:** comment `@dependabot rebase` on blocked PRs. This triggers
Dependabot to push a new commit, which fires the automerge workflow and submits
a fresh approval under the current CODEOWNERS.

### `code-quality` — Required Checks Ruleset (All Repositories)

The **codified** [`standards/rulesets/code-quality.json`](rulesets/code-quality.json)
is the source of truth for the required-check set; `apply-rulesets.sh` reads it and
PUTs it to each repo. (The detection-based in-code builder that dynamically probed
workflow files was **retired** in #580 — it diverged from this file.) The table below
reconciles to `code-quality.json`; keep the two in sync. Note: `apply-rulesets.sh`
manages only the `pr-quality` and `code-quality` branch rulesets — the
`release-channel-tags` ruleset is managed in `.github-private` (see
[§Source of truth & repo boundary](#source-of-truth--repo-boundary)).

#### Required Check Categories

The four contexts below are the **unconditional fleet-wide required checks** codified
in `code-quality.json`. `Dev-Lead Agent` is intentionally excluded, and
`Secret scan (gitleaks)` + `coverage` are staged (template / new repos first) — see
the reclassification table and sequencing note that follow.

| Check | Status | Check Name(s) | Notes |
|-------|--------|---------------|-------|
| **SonarCloud** | ✅ Required (codified) | `SonarCloud` | Code quality, maintainability, security hotspots. The context is exactly as codified in `code-quality.json`; verify with `gh pr checks <PR>` if a repo's SonarCloud workflow reports under a different name |
| **CodeQL** | ✅ Required (codified) | `CodeQL` | SAST via GitHub-managed default setup — auto-detects all supported languages (see [ci-standards.md §2](ci-standards.md#2-codeql-analysis-github-managed-default-setup)) |
| **AgentShield** | ✅ Required (codified) | `agent-shield / AgentShield` | Deep agent-config security scan on every PR |
| **Dependency Audit** | ✅ Required (codified) | `dependency-audit / Detect ecosystems` | Only the unconditional `Detect ecosystems` job is required; per-ecosystem audit jobs are gated on lockfile presence and would fail as required-but-skipped |

The following are **intentionally NOT** in `code-quality.json` today:

| Check | Status | Check Name(s) | Why |
|-------|--------|---------------|-----|
| **Secret Scan** | ⏳ Template / new repos; not yet fleet-wide | `Secret scan (gitleaks)` | Produced by the template [`ci.yml`](workflows/ci.yml) (see [Push Protection Standard](push-protection.md#layer-3--ci-secret-scanning-secondary-defense)). Added to the ruleset fleet-wide only once existing repos produce it |
| **Coverage** | ⏳ Template / new repos; not yet fleet-wide | `coverage` | **Not produced by the template [`ci.yml`](workflows/ci.yml) out of the box** — the template ships a single `build-and-test` job; a separate `coverage` check must be explicitly configured when adopting the template (see [ci-standards.md](ci-standards.md)). Requiring it fleet-wide before repos produce it would brick every PR — backfill first, then add the context |
| **Dev-Lead Agent** | ❌ Not a required context | `Dev-Lead Agent / dev-lead` | Per-PR AI review, not a merge gate: the agent's GitHub App refuses to mint a token for any PR touching workflow files, so requiring it would deadlock every workflow-modifying PR |
| **CI Pipeline** | Repo-specific (not a fixed org context) | e.g. `build-and-test`, `TypeScript`, `Go` | Lint/format/typecheck/test; the job name is repo-defined, so it is required per-repo (via branch protection), not as a codified org-wide context |

**Sequencing (why Secret Scan + Coverage are staged).** Adding a required context
to `code-quality.json` makes it a merge gate on **every** repo the ruleset targets;
a repo that does not *produce* that check is bricked. Neither context is produced by
the template `ci.yml` out of the box — repos must explicitly add a coverage job and
the gitleaks secret-scan step before those check names appear. Both are added to the
shared ruleset only **after** a fleet backfill. Until then, keep them scoped to repos
that already produce them. See [petry-projects/.github#575](https://github.com/petry-projects/.github/issues/575).

> **Check names must match exactly.** GitHub-managed CodeQL produces a check named
> `CodeQL` — **not** `Analyze (actions)`, `Analyze (javascript-typescript)`, or
> `CodeQL / Analyze (go)`. Requiring a check name that no job produces permanently
> blocks every PR. Verify check names against actual workflow runs:
>
> ```bash
> gh pr checks <PR-number> --repo petry-projects/<repo>
> ```

#### Ecosystem-Specific Configuration

The ecosystems scanned by each check depend on which languages/tools the repo
contains. If a repo contains an ecosystem, that ecosystem MUST be configured
in the relevant checks:

| Ecosystem Detected | CodeQL Language | SonarCloud | CI Pipeline | Dependency Audit |
|--------------------|----------------|------------|-------------|------------------|
| `package.json` / `package-lock.json` | `javascript-typescript` | JS/TS analysis | npm/pnpm lint, typecheck, test | `npm audit` or `pnpm audit` |
| `go.mod` | `go` | Go analysis | `go vet`, `golangci-lint`, `go test` | `govulncheck` |
| `Cargo.toml` | `rust` (if supported) | Rust analysis | `cargo fmt`, `cargo check`, `cargo test` | `cargo audit` |
| `pyproject.toml` / `requirements.txt` | `python` | Python analysis | pytest, coverage | `pip-audit` |
| `.github/workflows/*.yml` | `actions` | — | — | — |
| `*.tf` (Terraform) | — | — | `terraform validate` | Dependabot security updates |
| `_bmad/` (BMAD Method) | — | — | `feature-ideation.yml` (weekly) | — |

Multi-language repos (e.g., TypeScript + Go) MUST configure all applicable
ecosystems in each check.

#### Additional Settings

| Setting | Value |
|---------|-------|
| **Require branches to be up to date** | Yes (`strict: true`) |
| **Enforce for admins** | Yes |

See [CI Standards](ci-standards.md) for workflow templates and patterns.

---

## GitHub Apps & Integrations

### Installed GitHub Apps (org-wide, all repos)

| App | Purpose | Installed |
|-----|---------|-----------|
| **Claude** | AI code review and PR assistance via Claude Code Action (default dev-lead engine) | 2026-03-20 |
| **dependabot-automerge-petry** | Provides approving review for Dependabot auto-merge | 2026-03-23 |
| **petry-projects-pr-review-agent** | (deprecated) GitHub App formerly used for PR review — replaced by `donpetry-bot` machine user in `@petry-projects/org-leads` because Apps cannot be CODEOWNERS | 2026-04-01 |
| **donpetry-bot** | Machine-user account in `@petry-projects/org-leads`; satisfies CODEOWNERS for automated PR review | 2026-05-04 |
| **SonarQube Cloud (SonarCloud)** | Code quality, security hotspots, coverage tracking | 2026-03-25 |
| **CodeRabbit AI** | AI-powered code review on PRs | 2026-03-25 |

### AI Engine Support — Dev-Lead Workflow

The **dev-lead agent** workflow (`dev-lead.yml`) supports multiple AI engines for PR review and automation.
Set `vars.DEV_LEAD_ENGINE` per-repo to choose the engine; defaults to `claude`.

| Engine | Engine ID | Required Secrets | Purpose | Status |
|--------|-----------|-----------------|---------|--------|
| **Claude** | `claude` | `CLAUDE_CODE_OAUTH_TOKEN` | Anthropic Claude models for code review | Active (default) |
| **Gemini** | `gemini` | `CLAUDE_CODE_OAUTH_TOKEN`, `GOOGLE_API_KEY` | Google Gemini for code review (fallback if Claude unavailable) | Supported |
| **Copilot** | `copilot` | `CLAUDE_CODE_OAUTH_TOKEN`, `GH_PAT` | GitHub Copilot for code review (GitHub-native alternative) | Supported |

**Configuration per-repo (set as a repository variable):**

```bash
# GitHub does not propagate caller workflow env: values into called reusable
# workflows, so setting env: in the caller stub has no effect. Use a repository
# variable instead, which the reusable workflow reads as vars.DEV_LEAD_ENGINE.
gh variable set DEV_LEAD_ENGINE --body "gemini" --repo petry-projects/<repo>
# Alternatively: Settings → Secrets and variables → Actions → Variables → New variable
```

**Secret requirements by engine:**

- **Claude**: requires `CLAUDE_CODE_OAUTH_TOKEN` only
- **Gemini**: requires `CLAUDE_CODE_OAUTH_TOKEN` + `GOOGLE_API_KEY`
- **Copilot**: requires `CLAUDE_CODE_OAUTH_TOKEN` + `GH_PAT` (GitHub token with Copilot scope)

### Check-Suite Auto-Trigger Preferences

GitHub automatically creates a check suite for any app that has previously created check runs in a repo, on every push.
Some apps (Claude, CodeRabbit, and alternative AI engines) create these suites proactively but only complete them when they have real work to do.
When they have nothing to do, the suite stays in `queued` state indefinitely —
**GitHub auto-merge waits for all check suites to reach a terminal state before merging**,
so these orphaned suites permanently block auto-merge.

**Required configuration** (enforced by `scripts/apply-repo-settings.sh` and detected by `scripts/compliance-audit.sh`):

| App | app_id | Setting |
|-----|--------|---------|
| Claude (`anthropics/claude-code-action`) | `1236702` | `auto_trigger_checks: false` |
| CodeRabbit | `347564` | `auto_trigger_checks: false` |

Disabling auto-trigger stops GitHub from creating suites on every push. The apps still create suites explicitly when they have work to report.

If an app has never created a check run in a repository, GitHub omits that app from `auto_trigger_checks` entirely.
Both `scripts/apply-repo-settings.sh` and `scripts/compliance-audit.sh` treat this `missing` state as compliant —
no PATCH is needed and no finding is raised until the app is first seen in the repo.

**Additional AI engines** (Gemini, Copilot) — if a repo activates an alternative `DEV_LEAD_ENGINE`:
Verify that the corresponding app has `auto_trigger_checks: false` set if/when it first creates a check run.

**Applying** — the fleet self-heals weekly via the **`Apply repo settings`** workflow
(the org reusable `apply-repo-settings-reusable.yml`, adopted per repo through the thin
caller stub `standards/workflows/apply-repo-settings.yml`). To apply on demand, dispatch it:

```bash
# Dispatch the self-heal for one repo (add -f dry_run=true to preview):
gh workflow run "Apply repo settings" --repo petry-projects/<repo-name>
```

The workflow authenticates with the org secret **`GH_PAT_DON_PETRY`** (classic PAT, `repo`
scope, owner has repo-admin). The check-suites/preferences and ruleset APIs are legacy and
reject fine-grained PATs and `GITHUB_TOKEN` (403), which is why a classic admin PAT is
required. Running the scripts by hand (`GH_TOKEN=<classic-admin-pat> bash
scripts/apply-repo-settings.sh <repo-name>`) remains possible for break-glass, but the
dispatched workflow is the standard path.

### Other Integrations

| Integration | Purpose | Scope |
|-------------|---------|-------|
| **GitHub Copilot** | AI code review (native GitHub feature) | All repos |
| **CodeQL** | Static analysis (SAST) via GitHub Actions | Repos with CodeQL workflows |
| **Dependabot** | Security updates for dependencies | All repos (see [Dependabot Policy](dependabot-policy.md)) |

### Organization-Level Secrets for Standard CI

These secrets are configured at the **organization level** and inherited by
all repos automatically — no per-repo setup needed:

#### Required secrets (all repos)

| Secret | Purpose |
|--------|---------|
| `APP_ID` | GitHub App ID for Dependabot auto-merge (app_id: 3167543) |
| `APP_PRIVATE_KEY` | GitHub App private key for Dependabot auto-merge |
| `CLAUDE_CODE_OAUTH_TOKEN` | Authentication for Claude Code Action and dev-lead agent (default engine) |
| `DON_PETRY_BOT_GH_PAT` | Classic PAT (repo scope) owned by donpetry-bot; required by `pr-review-mention-reusable.yml` to post review-mention comments as the bot identity |
| `GH_PAT_DON_PETRY` | Classic PAT owned by donpetry-bot with **`repo` scope AND repo-admin on target repos**; used by the `Apply repo settings` self-heal (`apply-repo-settings-reusable.yml`) for the check-suites/preferences and ruleset admin APIs, which are legacy and **reject fine-grained PATs and `GITHUB_TOKEN` (403)**. Visibility must cover the whole fleet (including public repos) or the workflow preflight fails loud. Distinct from `DON_PETRY_BOT_GH_PAT` above (repo-scope only, no admin, review-mention identity) — do not conflate the two. |
| `GH_PAT_WORKFLOWS` | Classic PAT with `repo` scope; required for cross-repo script access and dev-lead to push workflow files |
| `GITLEAKS_LICENSE` | Gitleaks license key required for `secret-scan` job in organization repositories (see [ci-standards.md](ci-standards.md#4-secret-scanning-ciymll--gitleaks-job)) |
| `SONAR_TOKEN` | SonarCloud analysis authentication |

#### Optional secrets (by feature)

| Secret | Purpose | Required for |
|--------|---------|---------------|
| `GOOGLE_API_KEY` | Gemini API authentication | Repos using `vars.DEV_LEAD_ENGINE=gemini` |
| `GH_PAT` | GitHub token with Copilot scope | Repos using `vars.DEV_LEAD_ENGINE=copilot` |

Repos may require repo-specific secrets beyond this standard set.

---

## Labels — Standard Set

All repositories MUST have these labels configured. They fall into two groups: a
**fixed set** enumerated below, and a **derived family** (the persona opt-out labels)
computed from the persona manifests rather than hand-listed.

### Fixed set

| Label | Color | Purpose |
|-------|-------|---------|
| `security` | `#d93f0b` (red) | Security-related PRs and issues |
| `dependencies` | `#0075ca` (blue) | Dependency update PRs |
| `scorecard` | `#d93f0b` (red) | OpenSSF Scorecard findings (auto-created) |
| `bug` | `#d73a4a` (red) | Bug reports |
| `enhancement` | `#a2eeef` (teal) | Feature requests |
| `documentation` | `#0075ca` (blue) | Documentation changes |
| `in-progress` | `#fbca04` (yellow) | An agent is actively working this issue |
| `compliance-finding` | `#5319e7` (purple) | **Machine-owned.** Created and auto-closed by [`scripts/compliance-audit.sh`](../scripts/compliance-audit.sh). Do NOT hand-apply. |

> **`compliance-finding` is machine-owned (issue #1036).** The compliance audit
> creates this label and it is the **only** label the audit's auto-closer keys on:
> `close_resolved_issues()` closes an issue solely when it carries
> `compliance-finding`, is titled exactly `Compliance: <check>`, **and** its body
> carries the audit's generated-by marker. Do not hand-apply `compliance-finding`
> to an issue you do not want the audit to close. The human-facing
> `compliance-audit` label is safe to apply for triage — it no longer arms the
> closer.

### Derived family — persona opt-out labels (`<id>:hands-off`)

| Label | Color | Purpose |
|-------|-------|---------|
| `<id>:hands-off` (one per persona) | `#ededed` (grey) | Opt an item out of the `<id>` persona's automation entirely (per [persona-standards.md §4 rule 4](persona-standards.md)) |

This family is **derived, not enumerated.** [`scripts/apply-repo-settings.sh`](../scripts/apply-repo-settings.sh)
(`apply_labels()` → `persona_opt_out_label_configs()`) lists the persona directories
under `personas/<id>/` in [`petry-projects/.github-private`](https://github.com/petry-projects/.github-private)
and provisions each persona's `opt_out_label` (read from its `persona.yml`, defaulting
to the `<id>:hands-off` convention). The persona manifest is the index-of-record
([persona-standards.md §1.1](persona-standards.md)), so **onboarding a new persona
provisions its opt-out label automatically — no edit to the label list is required.**
Draft (`status: draft`) personas are included: being able to say "hands-off" is exactly
what a not-yet-stable persona needs.

> **`.github-private` is PUBLIC** (`private: false`, verified) despite its name, so the
> applier reads the manifests over the token it already uses for the rest of the run;
> no extra cross-repo auth is required.

All labels in this family share the single grey color `#ededed`, chosen to sit apart
from the functional labels above (which use red/blue/teal/yellow to signal category).

> **`dev-lead:hands-off` reconciliation.** `dev-lead:hands-off` already exists in
> repos but predates this mechanism — it was created ad hoc and appeared in neither
> the script nor this table (drift). It is now a member of this derived family: once
> the `dev-lead` persona is represented by a `personas/dev-lead/persona.yml` manifest,
> the applier provisions `dev-lead:hands-off` from that manifest like any other
> persona. The applier only creates/updates labels (never deletes), so the existing
> `dev-lead:hands-off` label is retained in the meantime.

---

## CODEOWNERS Standard

All repositories MUST have a `CODEOWNERS` file at `.github/CODEOWNERS`
(or `CODEOWNERS` at the repo root for repos with no `.github/` directory).

The full policy lives in [`codeowners-standard.md`](codeowners-standard.md).
Summary:

- The default owner line MUST be `* @petry-projects/org-leads`
- Direct listings of users or bot accounts (e.g.,
  `@petry-projects-pr-review-agent`, `@dependabot-automerge-petry`) are
  **forbidden** — manage membership through the team instead
- GitHub Apps cannot be code owners (platform limitation); use machine-user
  accounts added to the team

### Standard Template

```gitignore
# CODEOWNERS
# Standard: https://github.com/petry-projects/.github/blob/main/standards/codeowners-standard.md

* @petry-projects/org-leads
```

Repos with finer-grained path ownership MUST include `@petry-projects/org-leads`
on every owner line so the team can always satisfy `require_code_owner_review`.

---

## Applying to a New Repository

When creating a new repository in `petry-projects`:

1. **Create the repo** with standard settings (public, `main` branch, wiki disabled, discussions enabled)
2. **Create the `pr-quality` ruleset** matching the standard configuration above, including:
   - Bypass actors with `bypass_mode: always` for `dependabot-automerge-petry` and `OrganizationAdmin`
   - **Allow auto-merge enabled** — in the ruleset's "Merge settings", check the "Allow auto-merge" option.
     Required for seamless PR automation and CI-dependent merges
3. **Create the `code-quality` ruleset** with required checks for the repo's stack — verify check names against actual workflow runs before requiring them
4. **Add a `CODEOWNERS` file** using the [CODEOWNERS Standard](#codeowners-standard) template, extended with any repo-specific path patterns
5. **Add Dependabot configuration** — copy the appropriate template from
   [`standards/dependabot/`](dependabot/) and add to `.github/dependabot.yml`
6. **Add CI workflows** — see [CI Standards](ci-standards.md) for required workflows
7. **Create standard labels** — all labels from the [Standard Set](#labels--standard-set) above, plus any project-specific labels
8. **Enable auto-delete head branches** in repo settings
9. **Connect integrations** — ensure CodeRabbit and SonarCloud (if applicable) are enabled

> **Note:** All standard CI secrets are configured at the org level and inherited
> automatically — see [Organization-Level Secrets](#organization-level-secrets-for-standard-ci).
> No per-repo secret setup is needed for standard CI workflows.

---

## Organization-Level Workflows

The org runs several automated workflows across all repositories:

| Workflow | Schedule | Purpose | Details |
|----------|----------|---------|---------|
| **Actions Fleet Monitor** (`actions-fleet-monitor.yml` in `petry-projects/.github-private`) | Daily, 6:00 UTC | Monitor health of all GitHub Actions workflows across the org | Tracks success/failure rates, duration percentiles (p50/p95), and assigns status (HEALTHY/WARNING/DEGRADED/CRITICAL) per workflow; creates issues when workflows have failures |
| **Org Scorecard Review** (`org-scorecard.yml`) | Weekly, Monday 9:00 UTC | Security posture scoring for all public repos via OpenSSF Scorecard | Creates/updates/closes GitHub Issues with findings; auto-closes when resolved |
| **Org Standards Compliance Audit** (`compliance-audit-and-improvement.yml`) | Weekly, Friday 12:00 UTC | Deterministic audit of all repos against org standards + runtime health survey | Identifies missing workflows, misconfigured settings, stale PRs, security alerts; creates actionable issues labeled `dev-lead` for agent remediation |
| **Daily Org Status** (`daily-org-status.yml`) | Daily, 6:00 UTC | Org-wide health snapshot — PR counts, CI failures, dependency vulnerabilities | Reports via PR comments and workflow summary |
| **Dependency Audit** (`dependency-audit.yml`) | Per-repo CI (push/PR to `main`) | Multi-ecosystem dependency vulnerability scan (npm, pnpm, go, cargo, pip) | Fails the build when dependencies have known security advisories; adopted per-repo via the standard caller stub |

### Actions Fleet Monitor Details

The **Actions Fleet Monitor** runs daily and provides critical visibility into workflow health:

**Metrics tracked per workflow:**

- Total runs, successful runs, failed runs, cancelled runs (over lookback window)
- Failure rate (`failed / total`)
- Duration percentiles (p50 and p95)
- Health status: `HEALTHY` (0% failures), `WARNING` (>0%, ≤20%), `DEGRADED` (>20%, ≤50%), `CRITICAL` (>50%)

**Lookback window:** Defaults to 1 day; can be customized with `--field lookback_days=N` when running manually

**Results delivery:**

- Step Summary — workflow results table displayed in GitHub Actions UI (visible on every run)
- GitHub Issue — created in `.github-private` when any workflow has failed runs

**Manual trigger:**

```bash
gh workflow run actions-fleet-monitor.yml \
  --repo petry-projects/.github-private \
  --field org=petry-projects \
  --field lookback_days=7
```

This tool is essential for detecting CI flakiness, performance degradation, and systemic workflow issues before they impact development velocity.

**Ruleset bypass actors & legacy rulesets (remediated 2026-06-10):** a full
sweep (now enforced by `check_ruleset_bypass_actors()` and
`check_legacy_rulesets()`) found `.github-private` already compliant and every
other repo carrying findings — `code-quality` rulesets missing the
`dependabot-automerge-petry` bypass, `pr-quality` rulesets granting
`RepositoryAdmin` where `OrganizationAdmin` is required, and four deprecated
legacy rulesets still active. **All have been remediated.** A re-audit reports
**zero ruleset findings** across the fleet.

| Repository | Bypass actors | Legacy ruleset | Action taken |
|------------|:---:|:---:|-------|
| **.github-private** | ✅ | — | Already compliant |
| **.github** | ✅ | retired | `code-quality` dependabot bypass added; `protect-branches` deleted |
| **bmad-bgreat-suite** | ✅ | retired | `code-quality` bypass actors added; `protect-branches` deleted |
| **ContentTwin** | ✅ | — | `code-quality` dependabot bypass added; `pr-quality` OrganizationAdmin added |
| **broodly** | ✅ | — | `code-quality` dependabot bypass added; `pr-quality` OrganizationAdmin + dependabot added |
| **markets** | ✅ | — | `code-quality` bypass actors added; `pr-quality` OrganizationAdmin + dependabot added |
| **TalkTerm** | ✅ | retired | `code-quality` dependabot bypass added; redundant `main` ruleset deleted |
| **google-app-scripts** | ✅ | retired | `coverage` migrated into `code-quality`, then `protect-branches` deleted; `code-quality` bypass actors added |

> **Remediation:** see the [Ruleset Remediation Runbook](ruleset-remediation-runbook.md).
> Tooling: `scripts/fix-ruleset-bypass.sh` (bypass actors, least-destructive,
> dry-run capable) and `scripts/apply-rulesets.sh` (canonical `pr-quality` /
> `code-quality`). Legacy rulesets are retired with
> `gh api -X DELETE repos/petry-projects/<repo>/rulesets/<id>` once
> `check_legacy_rulesets()` reports an empty migration delta.

---

## Audit & Compliance

### Compliance Audit Process

Every Friday at 12:00 UTC, the **Org Standards Compliance Audit** runs across all repositories:

1. **Deterministic compliance checks** (`scripts/compliance-audit.sh`) verify each repo meets org standards:
   - Required workflows present (CI, CodeQL, dev-lead agent, Dependabot, etc.)
   - Branch protection rules and rulesets correctly configured
   - Labels, CODEOWNERS, and settings match the standard
   - GitHub App auto-trigger preferences set correctly

2. **Runtime health survey** checks:
   - CI failures and flaky tests
   - Stale pull requests (open > 14 days)
   - Security alerts (CodeQL, Dependabot, secret scanning)
   - Dependency vulnerabilities

3. **Issue creation and categorization:**
   - Each finding becomes a GitHub Issue in the repository, labeled `compliance-finding`
     (machine-owned) plus `compliance-audit` (human triage) and `dev-lead` (agent pickup)
   - High-priority findings (errors) are escalated for immediate remediation
   - Fixed issues are auto-closed by the audit — but **only** issues that carry the
     machine-owned `compliance-finding` label, are titled `Compliance: <check>`, and
     carry the audit's generated-by marker (issue #1036). Hand-filed issues and the
     cross-repo umbrella are never auto-closed.
   - The audit is **read-only by default** and mutates issue/label state only when run
     with `--apply` / `COMPLIANCE_AUDIT_APPLY=true` (set by the workflow)

4. **Org-level summary and reporting:**
   - Overall compliance health report
   - Trend analysis and improvement suggestions
   - Published as a GitHub Issue in the `.github` repository

### Scorecard Results

The weekly [OpenSSF Scorecard](https://github.com/ossf/scorecard) audit via
[`org-scorecard.yml`](../.github/workflows/org-scorecard.yml) scans all public repos:

- Creates/updates GitHub Issues for findings (labeled `scorecard`)
- Auto-closes issues when checks reach a score of 10/10
- Produces a summary report in the workflow step summary

Scorecard findings should be reviewed and remediated per the
[OpenSSF Scorecard documentation](https://github.com/ossf/scorecard/blob/main/docs/checks.md).
