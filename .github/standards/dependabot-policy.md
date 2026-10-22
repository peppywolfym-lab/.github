# Dependabot Policy: Security-Only Updates

## Rationale

New package versions pose risk to stability and security. Keeping known-good versions
and upgrading only when vulnerabilities are found and fixed provides a better
security posture than chasing every minor/patch release.

## Policy

1. **Security updates only** for application dependencies (npm, Go modules, pip, Cargo).
   Dependabot opens PRs only when a vulnerability advisory exists for a dependency.
   Version update PRs are suppressed by setting `open-pull-requests-limit: 0` for
   application ecosystems — Dependabot security updates bypass this limit.
2. **Version updates weekly** for GitHub Actions, since pinned action versions do not
   affect application stability and staying current reduces CI attack surface.
3. **Labels** `security` and `dependencies` on every Dependabot PR for filtering and audit.
4. **Auto-merge** after all CI checks pass, approving and merging eligible PRs.
   Approvals come from members of the `@petry-projects/org-leads` team listed
   in every repo's `CODEOWNERS` file (see
   [codeowners-standard.md](codeowners-standard.md)), so they satisfy
   `require_code_owner_review` without any bypass. Eligible updates:
   - **GitHub Actions**: all version bumps including major (SHA-pinned, no runtime impact)
   - **App ecosystems**: patch and minor security updates only (major requires human review)
   - **Indirect (transitive) dependencies**: all updates regardless of version bump
   Uses `gh pr merge --auto` to wait for required checks before merging.
5. **Vulnerability audit CI check** runs on every PR and push to `main`, failing the
   build if any dependency has a known advisory. This is a required status check.

## Prerequisites

- **Dependabot security updates** must be enabled at the org or repo level
  (Settings > Code security > Dependabot security updates).
- The `dependabot.yml` entries below configure which ecosystems and directories
  Dependabot monitors. Setting `open-pull-requests-limit: 0` for application
  ecosystems suppresses routine version-update PRs while still allowing
  security-alert-triggered PRs to be created.

## Configuration Files

Each repository must have the following baseline files:

| File | Purpose |
|------|---------|
| `.github/dependabot.yml` | Dependabot config scoped to the repo's ecosystems |
| `.github/workflows/dependabot-automerge.yml` | Auto-approve + squash-merge security PRs |
| `.github/workflows/dependency-audit.yml` | CI check — fail on known vulnerabilities |
| `.github/workflows/dependabot-rebase.yml` | Keep Dependabot PRs up-to-date and merge them serially |

The `dependabot-rebase.yml` is required for all repos using the `code-quality`
ruleset (which enforces `require_branches_to_be_up_to_date: true`). Without it,
each merge to `main` leaves remaining Dependabot PRs behind and they stall
indefinitely — Dependabot only rebases on its weekly schedule or on merge conflicts,
not when a branch merely falls behind.

## Dependabot Templates

Use the template matching your repository type.

**Application ecosystems** (npm, gomod, cargo, pip, terraform) use:

```yaml
schedule:
  interval: "weekly"
open-pull-requests-limit: 0   # suppress version updates; security PRs bypass this
labels:
  - "security"
  - "dependencies"
```

**GitHub Actions** uses:

```yaml
schedule:
  interval: "weekly"
open-pull-requests-limit: 10  # allow version updates for CI actions
labels:
  - "security"
  - "dependencies"
```

### Frontend (npm)

For repos with `package.json` at root or in subdirectories.

- Ecosystem: `npm`
- Directory: `/` (or path to each `package.json`)

See [`dependabot/frontend.yml`](dependabot/frontend.yml)

### Backend — Go

For repos with `go.mod`.

- Ecosystem: `gomod`
- Directory: path to `go.mod`

See [`dependabot/backend-go.yml`](dependabot/backend-go.yml)

### Backend — Rust

For repos with `Cargo.toml`.

- Ecosystem: `cargo`
- Directory: `/`

See [`dependabot/backend-rust.yml`](dependabot/backend-rust.yml)

### Backend — Python

For repos with `pyproject.toml` or `requirements.txt`.

- Ecosystem: `pip`
- Directory: `/`

See [`dependabot/backend-python.yml`](dependabot/backend-python.yml)

### Infrastructure — Terraform

For repos with Terraform modules.

- Ecosystem: `terraform`
- Directory: path to Terraform root module

See [`dependabot/infra-terraform.yml`](dependabot/infra-terraform.yml)

### GitHub Actions (all repos)

Every repository must include the `github-actions` ecosystem entry.
GitHub Actions use **version updates** (not security-only) on a weekly schedule
since pinned action SHAs do not affect application runtime stability.

```yaml
- package-ecosystem: "github-actions"
  directory: "/"
  schedule:
    interval: "weekly"
  open-pull-requests-limit: 10
  labels:
    - "security"
    - "dependencies"
```

### Full-Stack Example

A full-stack repo (e.g., npm + Go + Terraform + GitHub Actions) combines the
relevant ecosystem entries into a single `dependabot.yml`. See
[`dependabot/fullstack.yml`](dependabot/fullstack.yml) for a complete example.

## Auto-Merge Workflow

See [`workflows/dependabot-automerge.yml`](workflows/dependabot-automerge.yml).

Behavior:

- Triggers on `pull_request_target` from `dependabot[bot]`
- Fetches Dependabot metadata to determine update type and ecosystem
- For **GitHub Actions**: approves and auto-merges all version bumps including
  major, since actions are SHA-pinned and CI catches breaking interface changes
- For **app ecosystems**: approves **patch** and **minor** updates (and indirect
  dependency updates); **major** updates are left for human review
- Uses `gh pr merge --auto --squash` so the merge only happens after CI passes

## Update and Merge Behind PRs Workflow

See [`workflows/dependabot-rebase.yml`](workflows/dependabot-rebase.yml).

When branch protection requires branches to be up-to-date (`strict: true`),
merging one Dependabot PR makes the others fall behind. Dependabot only rebases
PRs on its scheduled run (weekly) or when there are merge conflicts — not when
a PR merely falls behind `main`. Additionally, GitHub's auto-merge (`--auto`)
may not trigger when rulesets cause `mergeable_state` to report "blocked" even
when all requirements are met. Together, these issues stall Dependabot PR
merges indefinitely.

This workflow fires on every push to `main` (and can be triggered manually via
`workflow_dispatch` to flush the queue) and:

1. **Updates behind PRs** — calls the GitHub `update-branch` API with the
   **APP_TOKEN** on any Dependabot PR that is behind `main`. This adds a merge
   commit from `main` onto the PR branch. CI triggers normally because the
   APP_TOKEN is a GitHub App installation token, not `GITHUB_TOKEN`.
2. **Merges ready PRs** — directly merges any Dependabot PR that is up-to-date,
   has auto-merge enabled, and is `MERGEABLE` with no pending checks.

Using the app token for merges ensures each merge triggers a new push to `main`,
creating a self-sustaining chain that serializes Dependabot PR merges.

**GitHub App permission requirement:** The `dependabot-automerge-petry` GitHub App
must have the `workflows` permission granted. Without it, the `update-branch` API
call fails with *"refusing to allow a GitHub App to create or update workflow"*
whenever `main` contains workflow file changes (`.github/workflows/*.yml`) that
would be merged into the PR branch. Grant the permission in the GitHub App settings:
Settings → GitHub Apps → dependabot-automerge-petry → Permissions → Workflows → Read & Write.

**Chain-stall safety net:** The rebase workflow also runs on a 4-hour schedule
(`cron: '0 */4 * * *'`) in addition to `push: main` and `workflow_dispatch`.
This prevents the serialization chain from stalling in repos where no PR merges
to `main` occur for extended periods, without relying solely on external pushes.

**Fallback merge when `update-branch` fails:** If `update-branch` fails (e.g., the
GitHub App lacks the `workflows` permission or there are merge conflicts), the
workflow falls through to the direct merge attempt instead of skipping the PR
permanently. The bypass actor (`bypass_mode: always`) can call `gh api .../merge`
directly when the branch is behind `main`, provided the PR's own CI has passed
and `strict_required_status_checks_policy` is `false` for the repo. If a repo
enforces `strict_required_status_checks_policy: true` (branches must be up to
date before merge), the fallback direct merge will also fail — granting the
`dependabot-automerge-petry` App the `workflows` permission so that
`update-branch` succeeds is the correct resolution in that case.

**Why `update-branch` with APP_TOKEN (not `GITHUB_TOKEN` or `@dependabot rebase`):**

- **`GITHUB_TOKEN`** is subject to GitHub's recursive-trigger guard — events it
  causes do not create new workflow runs. Calling `update-branch` with
  `GITHUB_TOKEN` pushes to the PR branch but CI never runs, so the PR stays
  blocked indefinitely.

- **`@dependabot rebase`** only works when posted by a *user account* with push
  access. GitHub App bots are rejected even if their installation has
  `contents: write` — Dependabot replies "Sorry, only users with push access can
  use that command." This makes bot-posted `@dependabot rebase` unusable for
  automation.

- **APP_TOKEN** (a GitHub App installation token) is treated as a distinct
  identity and is **not** subject to the `GITHUB_TOKEN` recursive-trigger guard.
  Pushes via APP_TOKEN trigger CI workflow runs normally.

**Merge-readiness check:** The workflow checks GitHub's native `mergeable` state
(`MERGEABLE`) rather than inspecting every individual check conclusion. This is
correct because `mergeable` already accounts for all *required* status checks —
non-required checks that happen to fail (e.g. a gitleaks false positive) do not
block the merge. An additional guard ensures no checks are still `IN_PROGRESS`
before merging.

### Caller Stub Format

The repo-level `dependabot-rebase.yml` is a thin caller stub. It must use
**explicit secrets** (not `secrets: inherit`) and **write permissions**:

```yaml
jobs:
  dependabot-rebase:
    permissions:
      pull-requests: write # call update-branch API on behind PRs and merge when ready
    uses: petry-projects/.github/.github/workflows/dependabot-rebase-reusable.yml@b51e2edf830ea085be0277bcf3174c7b3ec8f958 # v1
    secrets:
      APP_ID: ${{ secrets.APP_ID }}
      APP_PRIVATE_KEY: ${{ secrets.APP_PRIVATE_KEY }}
```

> **Why not `secrets: inherit`?** GitHub reusable workflows receive no more
> permissions than the calling job grants them. A caller with `permissions: read`
> prevents the reusable from making any write API calls — branch updates and
> merges silently fail. Additionally, `secrets: inherit` with mismatched
> permission levels can cause `startup_failure` on the reusable job. Always use
> explicit secrets and grant write permissions.

To manually flush the Dependabot PR queue after fixing a stalled pipeline:

```bash
gh workflow run dependabot-rebase.yml --repo petry-projects/<repo>
```

### Manual Rebase (Break-Glass)

If the automated chain stalls and a Dependabot PR is stuck behind `main`, any
user with push access can unblock it by posting `@dependabot rebase` directly:

```bash
# Post @dependabot rebase as a user with push access (not a bot):
gh pr list --repo petry-projects/<repo> --label dependencies --json number \
  --jq '.[].number' | xargs -I{} gh pr comment {} --repo petry-projects/<repo> \
  --body "@dependabot rebase"
```

This must be run as a human user (e.g. `gh auth status` should show your account,
not a bot). Dependabot ignores the command from GitHub App bot accounts.

### CODEOWNERS Approval Timing

GitHub evaluates code owner status **at the time an approval is submitted**, not
retroactively. If `CODEOWNERS` is updated (e.g., bot accounts are added), existing
approvals from those accounts on open PRs are not retroactively credited.

To re-trigger fresh approvals after a CODEOWNERS change, use the manual rebase
command above — each new Dependabot push causes the automerge workflow to fire
and submit a fresh approval.

## Vulnerability Audit CI Check

See [`workflows/dependency-audit.yml`](workflows/dependency-audit.yml).

This workflow template detects the ecosystems present in the repo and runs the
appropriate audit tool:

| Ecosystem | Tool | Command |
|-----------|------|---------|
| npm | `npm audit` | `npm audit --audit-level=low` per `package-lock.json` (fails on any advisory) |
| pnpm | `pnpm audit` | `pnpm audit --audit-level low` per `pnpm-lock.yaml` |
| Go | `govulncheck` | `govulncheck ./...` per `go.mod` directory |
| Rust | `cargo-audit` | `cargo audit` per `Cargo.toml` workspace |
| Python | `pip-audit` | `pip-audit .` per `pyproject.toml` / `-r requirements.txt` |

The workflow fails if any known vulnerability is found, blocking the PR from merging.

## Applying to a Repository

1. Copy the appropriate `dependabot.yml` template to `.github/dependabot.yml`,
   adjusting `directory` paths as needed.
2. Add `workflows/dependabot-automerge.yml` to `.github/workflows/`.
3. Add `workflows/dependabot-rebase.yml` to `.github/workflows/` (required for
   all repos using the `code-quality` ruleset with `require_branches_to_be_up_to_date: true`).
   Copy verbatim from [`standards/workflows/dependabot-rebase.yml`](workflows/dependabot-rebase.yml)
   — do **not** modify the secrets block or permissions.

   > **Note:** The rebase workflow is **not** required for `require_code_owner_review`.
   > The correct solution for CODEOWNERS enforcement is to list the
   > `@petry-projects/org-leads` team in every CODEOWNERS pattern — see the
   > [CODEOWNERS Standard](codeowners-standard.md). The earlier approach of
   > using `gh api .../merge` as a bypass was fragile and has been superseded.
4. Add `workflows/dependency-audit.yml` to `.github/workflows/`.
5. **GitHub App permissions** — the `dependabot-automerge-petry` GitHub App requires
   the `workflows` permission in addition to `contents: write` and `pull_requests: write`.
   Without it, the rebase workflow cannot call `update-branch` when `main` contains
   workflow file changes. Grant: GitHub App settings → Permissions → Repository →
   Workflows → Read & Write, then accept the updated permission in each repo's
   installed-app settings.

6. **GitHub App secrets** — `APP_ID` and `APP_PRIVATE_KEY` are managed at the
   **organization level** (`gh secret set <name> --org petry-projects --visibility all`),
   not per-repo. The caller stubs pass these explicitly via:

   ```yaml
   secrets:
     APP_ID: ${{ secrets.APP_ID }}
     APP_PRIVATE_KEY: ${{ secrets.APP_PRIVATE_KEY }}
   ```

   Per-repo `APP_ID` / `APP_PRIVATE_KEY` settings are deprecated drift — once the org
   secrets are confirmed in place, delete any per-repo copies so there's a
   single source of truth and rotations propagate everywhere.

   **Verify before deleting per-repo copies.** Run

   ```bash
   gh secret list --org petry-projects | grep -E '^(APP_ID|APP_PRIVATE_KEY)\s'
   ```

   to confirm both org-level secrets exist with `visibility: all`. Only after
   both secrets are confirmed should you run `gh secret delete APP_ID --repo <repo>`
   to clean up per-repo copies — otherwise `gh pr review` calls fail with
   `Secret APP_ID is required`.
7. Create the `security` and `dependencies` labels in the repository if they
   don't already exist.
8. Add `dependency-audit / Detect ecosystems` as a required status check in
   branch protection rules. Do **not** require the per-ecosystem audit jobs
   (`npm audit`, `govulncheck`, `cargo audit`, `pip-audit`, `pnpm audit`) —
   they're conditional on lockfile presence and report `SKIPPED` when absent,
   and a required-but-skipped check fails the merge gate.
