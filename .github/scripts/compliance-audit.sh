#!/usr/bin/env bash
# compliance-audit.sh — Weekly org-wide compliance audit
#
# Checks every petry-projects repository against the standards defined in:
#   standards/ci-standards.md
#   standards/dependabot-policy.md
#   standards/github-settings.md
#   standards/push-protection.md
#
# Outputs:
#   $REPORT_DIR/findings.json      — machine-readable findings
#   $REPORT_DIR/summary.md         — human-readable report
#   $REPORT_DIR/issue-counts.json  — issue management counts (added/existing/removed)
#
# Environment variables:
#   GH_TOKEN               — GitHub token with repo/org scope (required)
#   REPORT_DIR             — directory for output files (default: mktemp -d)
#   DRY_RUN                — set to "true" to skip issue creation (default: false)
#   CREATE_ISSUES          — set to "false" to skip issue creation (default: true)
#   COMPLIANCE_AUDIT_APPLY — set to "true" (or pass --apply) to actually mutate
#                            issue/label state (default: false → read-only)
#
# READ-ONLY BY DEFAULT (issue #1036, Defect 3): auditing is always safe to run,
# but this script also creates, comments on, and CLOSES issues across every repo
# in the org. Those mutations happen ONLY when explicitly enabled with the
# `--apply` flag or `COMPLIANCE_AUDIT_APPLY=true` (the value the compliance-audit
# workflow sets). Without it the script performs the read-only audit, prints the
# issue actions it WOULD take, and exits 0 — so an agent working on this code, or
# a maintainer inspecting output locally, cannot silently mutate production issue
# state. `DRY_RUN=true` additionally suppresses mutation even when apply is on.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ORG="petry-projects"
AUDIT_LABEL="compliance-audit"
AUDIT_LABEL_COLOR="7057ff"
AUDIT_LABEL_DESC="Automated compliance audit finding"
# Machine-owned label (issue #1036, AC1c). The audit CREATES and CLOSES only
# issues carrying this label; close_resolved_issues() keys on it, never on
# AUDIT_LABEL. This leaves `compliance-audit` free for people to apply for triage
# without arming the auto-closer. Do NOT hand-apply `compliance-finding`.
FINDING_LABEL="compliance-finding"
FINDING_LABEL_COLOR="5319e7"
FINDING_LABEL_DESC="Machine-owned: created and auto-closed by the compliance audit. Do not hand-apply."
# Stable machine-written marker embedded in every issue body this audit creates.
# close_resolved_issues() requires it (or the legacy generated-by footer) as
# evidence THIS TOOL created an issue before closing it (issue #1036, AC1b).
AUDIT_GENERATED_MARKER="<!-- compliance-audit:generated -->"
# dev-lead actor routing (issue #1093, decision #1037). Compliance findings about
# GitHub *configuration* — the `rulesets` category — are labelled
# DEV_LEAD_HANDS_OFF_LABEL instead of DEV_LEAD_LABEL: dev-lead cannot read or write
# ruleset state, so every dispatch against such a finding is wasted or harmful.
# hands-off removes the actor WITHOUT resolving the finding; the audit keeps
# creating, updating, and re-reporting it so it stays visible until
# apply-rulesets.sh reaches the fleet (#1045). Every other category keeps
# DEV_LEAD_LABEL. See category_actor_label().
DEV_LEAD_LABEL="dev-lead"
DEV_LEAD_LABEL_DESC="For dev-lead agent pickup"
DEV_LEAD_LABEL_COLOR="8B5CF6"
DEV_LEAD_HANDS_OFF_LABEL="dev-lead:hands-off"
DEV_LEAD_HANDS_OFF_DESC="Exclude from dev-lead agent automation"
# Grey — the persona opt-out label family colour (standards/github-settings.md
# "Derived family — persona opt-out labels"). apply-repo-settings.sh provisions
# this label from the persona manifest; the audit ensures it locally too so a
# finding issue can carry it on a repo the applier has not yet reconciled.
DEV_LEAD_HANDS_OFF_COLOR="ededed"
REPORT_DIR="${REPORT_DIR:-$(mktemp -d)}"
DRY_RUN="${DRY_RUN:-false}"
CREATE_ISSUES="${CREATE_ISSUES:-true}"
# Read-only by default (issue #1036, Defect 3 / AC4). Enabled by --apply (parsed
# in main) or COMPLIANCE_AUDIT_APPLY=true. See the script header.
APPLY="${COMPLIANCE_AUDIT_APPLY:-false}"

FINDINGS_FILE="$REPORT_DIR/findings.json"
SUMMARY_FILE="$REPORT_DIR/summary.md"
ISSUES_FILE="$REPORT_DIR/issues.json"
ISSUE_COUNTS_FILE="$REPORT_DIR/issue-counts.json"
# Repos whose checks actually RAN this execution (issue #1036, AC2). A repo not
# recorded here was skipped/unscanned, so close_resolved_issues() must not treat
# its empty findings set as "everything fixed".
AUDITED_REPOS_FILE="$REPORT_DIR/audited-repos.txt"
# Repos where closure-relevant checks could not complete (issue #1036, AC2 extension).
# If a repo had an inconclusive check (e.g. workflow list unreadable), it's recorded
# here and NOT marked audited, so close_resolved_issues() skips it.
INCONCLUSIVE_REPOS_FILE="$REPORT_DIR/inconclusive-repos.txt"
# Informational AGENTS.md structural-linter findings (issue #645, epic #642).
# These are kept OUT of FINDINGS_FILE on purpose: they open no issues, never
# join the umbrella, and never fail the run — Phase 3 ships structural
# validation informational-only (see docs/initiatives/agents-md-validation.md).
STRUCTURAL_FINDINGS_FILE="$REPORT_DIR/agents-md-structural.tsv"
# A non-empty marker file here means the structural linter did NOT complete for
# one or more repos this cycle (issue #647, AC #1). An incomplete linter leaves
# the findings accumulator empty, which would otherwise read as a CLEAN
# zero-finding cycle; this marker makes the summary mark the cycle INDETERMINATE
# instead, so a suppressed linter failure can never be recorded as clean.
STRUCTURAL_LINT_ERROR_FILE="$REPORT_DIR/agents-md-structural.err"
# Rule-set / promotion-gate reference the informational summary section links to.
AGENTS_MD_RULESET_DOC="docs/initiatives/agents-md-validation.md"
# Append-only, committed per-cycle log (issue #647, Phase 4). The audit summary
# records THIS cycle's structural finding count and points a maintainer here to
# log the false-positive determination durably — an editable summary issue alone
# could be silently rewritten to fake a "two clean cycles" claim.
AGENTS_MD_CYCLE_LOG="docs/initiatives/agents-md-validation-cycle-log.md"

# Issue management counters (incremented by create_issue_for_finding / close_resolved_issues)
ISSUES_ADDED=0
ISSUES_EXISTING=0
ISSUES_REMOVED=0
ISSUES_RETRIGGERED=0

REQUIRED_WORKFLOWS=(ci.yml sonarcloud.yml dev-lead.yml dependabot-automerge.yml dependency-audit.yml agent-shield.yml pr-review-mention.yml feature-ideation.yml pr-auto-review.yml initiative-driver.yml)
# feature-ideation.yml, pr-auto-review.yml, and initiative-driver.yml were
# promoted to required org-wide in #844 (previously feature-ideation was
# bmad-method-conditional and the other two were optional/pin-checked-if-present).
# feature-ideation additionally carries a project_context invariant enforced by
# check_required_workflows: presence alone is necessary but not sufficient — a
# stub still on the seed TODO:/Example: placeholder is flagged separately.
# Note: codeql.yml is intentionally NOT in REQUIRED_WORKFLOWS. CodeQL is now
# configured via GitHub-managed default setup (Settings → Code security →
# Code scanning), not a per-repo workflow file. The check_codeql_default_setup
# function below verifies the API state and treats stray codeql.yml files
# as drift to be removed. See standards/ci-standards.md#2-codeql-analysis-github-managed-default-setup.

# The fixed label set (STANDARD_LABEL_SPECS) and the derived <id>:hands-off
# persona opt-out family (persona_opt_out_label_configs) live in
# scripts/lib/labels.sh, the single source of truth shared with
# apply-repo-settings.sh and compliance-remediate.sh (issue #1139). Sourced below,
# after warn() is defined. check_labels() consumes both.

# App IDs whose auto_trigger_checks must be disabled org-wide.
# 1236702 = Claude (anthropics/claude-code-action)
# 347564  = CodeRabbit
CHECK_SUITE_APP_IDS=(1236702 347564)

REQUIRED_SETTINGS_BOOL=(
  "allow_auto_merge:true:warning:Allow auto-merge must be enabled for Dependabot workflow"
  "delete_branch_on_merge:true:warning:Automatically delete head branches must be enabled"
  "has_wiki:false:warning:Wiki should be disabled — documentation lives in the repo"
  "has_issues:true:error:Issue tracking must be enabled"
  "has_discussions:true:error:Discussions must be enabled for ideation and community engagement"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
findings_count=0

add_finding() {
  local repo="$1" category="$2" check="$3" severity="$4" detail="$5" standard_ref="${6:-}"

  findings_count=$((findings_count + 1))
  local finding
  finding=$(jq -n \
    --arg repo "$repo" \
    --arg category "$category" \
    --arg check "$check" \
    --arg severity "$severity" \
    --arg detail "$detail" \
    --arg standard_ref "$standard_ref" \
    '{repo:$repo,category:$category,check:$check,severity:$severity,detail:$detail,standard_ref:$standard_ref}')

  jq --argjson f "$finding" '. += [$f]' "$FINDINGS_FILE" > "$FINDINGS_FILE.tmp"
  mv "$FINDINGS_FILE.tmp" "$FINDINGS_FILE"
}

log() { echo "::group::$*" >&2; }
log_end() { echo "::endgroup::" >&2; }
info() { echo "[INFO] $*" >&2; }
warn() { echo "::warning::$*" >&2; }

# mutations_enabled: issue/label mutation is allowed only when explicitly applied
# and not in dry-run (issue #1036, AC4). Everything gated behind this is a no-op
# in the read-only default.
mutations_enabled() {
  [ "$APPLY" = "true" ] && [ "$DRY_RUN" != "true" ]
}

# mark_repo_audited <repo>: record that <repo>'s checks ran this execution.
mark_repo_audited() {
  printf '%s\n' "$1" >> "$AUDITED_REPOS_FILE"
}

# repo_was_audited <repo>: return 0 if <repo>'s checks ran this execution (AC2).
repo_was_audited() {
  [ -f "$AUDITED_REPOS_FILE" ] || return 1
  grep -qxF "$1" "$AUDITED_REPOS_FILE"
}

# mark_repo_inconclusive <repo>: record that a closure-relevant check failed for <repo>.
mark_repo_inconclusive() {
  printf '%s\n' "$1" >> "$INCONCLUSIVE_REPOS_FILE"
}

# repo_has_inconclusive_checks <repo>: return 0 if <repo> had a failed collection check.
repo_has_inconclusive_checks() {
  [ -f "$INCONCLUSIVE_REPOS_FILE" ] || return 1
  grep -qxF "$1" "$INCONCLUSIVE_REPOS_FILE"
}

# issue_has_generated_marker <body>: return 0 if the issue body carries evidence
# THIS TOOL created it — the explicit machine marker on issues created after
# #1036, or the legacy generated-by footer on issues created before it. A
# hand-filed issue carries neither and is therefore never closable (AC1b).
issue_has_generated_marker() {
  local body="$1"
  case "$body" in
    *"$AUDIT_GENERATED_MARKER"*) return 0 ;;
    *"automatically created by the [weekly compliance audit]"*) return 0 ;;
  esac
  return 1
}

# category_actor_label <category>: the dev-lead actor label a finding of this
# category should carry (issue #1093, decision #1037). A `rulesets` finding routes
# to `dev-lead:hands-off` because dev-lead cannot read or write ruleset
# configuration — the reconciler (apply-rulesets.sh, #1045) converges it, not a
# code-change agent. Every other category routes to `dev-lead` as before. Pure:
# input in, label out, no side effects.
category_actor_label() {
  case "$1" in
    rulesets) printf '%s\n' "$DEV_LEAD_HANDS_OFF_LABEL" ;;
    *)        printf '%s\n' "$DEV_LEAD_LABEL" ;;
  esac
}

# escape_ere escapes ERE metacharacters in a string for literal matching in grep -E.
# This ensures that version tags (e.g. v2.1) and reusable basenames are treated
# as literal strings even if they contain regex metacharacters.
escape_ere() {
  printf '%s' "$1" | sed 's/[][\.^$*+?(){}|\\/{}]/\\&/g'
}

# Retry wrapper for gh api calls (handles rate limits)
gh_api() {
  local retries=3
  local output
  for i in $(seq 1 $retries); do
    if output=$(gh api "$@" 2>/dev/null); then
      echo "$output"
      return 0
    fi
    if [ "$i" -lt "$retries" ]; then
      sleep $((i * 2))
    else
      info "gh api $1 failed after $retries retries" >&2
    fi
  done
  return 1
}

# Source the shared push-protection library — provides pp_run_all_checks()
# and the PP_REQUIRED_SA_SETTINGS list. Sourced AFTER gh_api() and
# add_finding() are defined, since the lib's check functions call them.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Directory holding the codified ruleset source of truth
# (pr-quality.json / code-quality.json). check_ruleset_contents diffs each live
# ruleset against these files. Overridable for tests.
RULESETS_SRC_DIR="${RULESETS_SRC_DIR:-$SCRIPT_DIR/../standards/rulesets}"

# shellcheck source=lib/push-protection.sh
. "$SCRIPT_DIR/lib/push-protection.sh"

# Shared label source of truth — STANDARD_LABEL_SPECS (fixed set) and
# persona_opt_out_label_configs (derived <id>:hands-off family). Sourced after
# warn() is defined so the library uses this script's logging helper (issue #1139).
# shellcheck source=lib/labels.sh
. "$SCRIPT_DIR/lib/labels.sh"

# Shared dev-lead retrigger helpers — dl_dev_lead_active() and
# dl_cycle_trigger_label(). Used to re-engage dev-lead on persistent findings.
# shellcheck source=lib/dev-lead-retrigger.sh
. "$SCRIPT_DIR/lib/dev-lead-retrigger.sh"

# Canary-ring pin model — ring_tier_for_repo(), ring_canonical_ref(),
# ring_legacy_csv(). Shared with deploy-standard-workflows.sh so the audit's
# "non-compliant" and the deploy sweep's "drift" stay in lockstep (#482).
# shellcheck source=lib/ring-pins.sh
. "$SCRIPT_DIR/lib/ring-pins.sh"

# AGENTS.md structural linter — the pure, data-driven driver (amdl_lint) and its
# default rule-set path (AMDL_DEFAULT_RULES). Sourced, not exec'd: agents-md-lint.sh
# guards its CLI behind a BASH_SOURCE check, so sourcing only defines functions.
# Phase 3 (#645) runs it over each scanned repo's AGENTS.md, informational-only.
# shellcheck source=agents-md-lint.sh
. "$SCRIPT_DIR/agents-md-lint.sh"

# Canonical workflow-stub templates — the source of truth the caller-stub
# surface-drift guard (check_stub_surface_drift) compares deployed stubs against.
STANDARDS_WF_DIR="$SCRIPT_DIR/../standards/workflows"

# ---------------------------------------------------------------------------
# Ecosystem detection
# ---------------------------------------------------------------------------
detect_ecosystems() {
  local repo="$1"
  ECOSYSTEMS=()

  # Check for common ecosystem markers via the repo tree
  local tree
  tree=$(gh_api "repos/$ORG/$repo/git/trees/HEAD?recursive=1" --jq '.tree[].path' 2>/dev/null || echo "")

  if grep -qE '(^|/)package\.json$' <<< "$tree"; then
    ECOSYSTEMS+=("npm")
  fi
  if grep -qE '(^|/)pnpm-lock\.yaml$' <<< "$tree"; then
    # Override npm with pnpm if lock file present, or add pnpm directly
    if [[ " ${ECOSYSTEMS[*]} " == *" npm "* ]]; then
      ECOSYSTEMS=("${ECOSYSTEMS[@]/npm/pnpm}")
    else
      ECOSYSTEMS+=("pnpm")
    fi
  fi
  if grep -qE '(^|/)go\.mod$' <<< "$tree"; then
    ECOSYSTEMS+=("go")
  fi
  if grep -qE '(^|/)Cargo\.toml$' <<< "$tree"; then
    ECOSYSTEMS+=("rust")
  fi
  if grep -qE '(^|/)(pyproject\.toml|requirements\.txt)$' <<< "$tree"; then
    ECOSYSTEMS+=("python")
  fi
  if grep -qE '\.tf$' <<< "$tree"; then
    ECOSYSTEMS+=("terraform")
  fi
  if grep -qE '\.github/workflows/.*\.ya?ml$' <<< "$tree"; then
    ECOSYSTEMS+=("github-actions")
  fi
  # BMAD Method: detected via either the active install dir (`_bmad/`) or
  # the planning artifacts output dir (`_bmad-output/`). Repos may have one,
  # the other, or both depending on the BMAD workflow stage.
  if grep -qE '(^|/)_bmad(-output)?/' <<< "$tree"; then
    ECOSYSTEMS+=("bmad-method")
  fi
}

# ---------------------------------------------------------------------------
# Check: Required workflows exist
# ---------------------------------------------------------------------------
check_required_workflows() {
  local repo="$1"

  for wf in "${REQUIRED_WORKFLOWS[@]}"; do
    if ! gh_api "repos/$ORG/$repo/contents/.github/workflows/$wf" --jq '.name' > /dev/null 2>&1; then
      add_finding "$repo" "ci-workflows" "missing-$wf" "error" \
        "Required workflow \`$wf\` is missing" \
        "standards/ci-standards.md#required-workflows"
    fi
  done

  # feature-ideation project_context invariant (#844): the file being *present*
  # is necessary but not sufficient. The seed stub ships a TODO:/Example:
  # placeholder project_context (the one required per-repo edit), so a repo that
  # merely has the workflow but never customised it would run weekly ideation on
  # "TODO". Flag a still-placeholder context — a warning, not an error: the file
  # is present and correctly pinned; it only needs its one required per-repo edit.
  local fi_content fi_decoded
  fi_content=$(gh_api "repos/$ORG/$repo/contents/.github/workflows/feature-ideation.yml" --jq '.content' 2>/dev/null || echo "")
  if [ -n "$fi_content" ]; then
    fi_decoded=$(echo "$fi_content" | base64 -d 2>/dev/null || echo "")
    if [ -n "$fi_decoded" ] && feature_ideation_should_flag_placeholder "$repo" "$fi_decoded"; then
      add_finding "$repo" "ci-workflows" "feature-ideation-placeholder-context" "warning" \
        "\`feature-ideation.yml\` is present but its \`project_context\` is still the seed template placeholder (\`TODO:\`/\`Example:\`) — replace it with a real per-repo project description so weekly ideation runs on real context" \
        "standards/ci-standards.md#required-workflows"
    fi
  fi
}

# Pure: the audit's decision on whether to raise feature-ideation-placeholder-context
# for a given repo. Fires only when the context is still the seed placeholder AND the
# repo is not exempt from the finding.
feature_ideation_should_flag_placeholder() {
  local repo="$1" decoded="$2"
  feature_ideation_context_is_placeholder "$decoded" || return 1
  feature_ideation_placeholder_exempt "$repo" && return 1
  return 0
}

# Pure: return 0 if the repo is exempt from the feature-ideation-placeholder-context
# finding. repo-template is the seed for new repos (#856): its feature-ideation.yml
# legitimately KEEPS the TODO:/Example: placeholder project_context — new repos
# customise it on adoption — so flagging it would be a permanent false positive.
feature_ideation_placeholder_exempt() {
  local repo="$1"
  [[ "$repo" == "repo-template" ]]
}

# Pure: given a decoded feature-ideation.yml caller stub, return 0 if its
# `project_context` is still the seed template placeholder (the TODO:/Example:
# sentinel shipped by standards/workflows/feature-ideation.yml), non-zero once a
# real per-repo description has replaced it. Anchored to start-of-line (after
# indentation) so a `# ...` comment mentioning TODO can never satisfy the match.
feature_ideation_context_is_placeholder() {
  local decoded="$1"
  grep -qE '^[[:space:]]*(TODO: Replace this with a description of the project|Example: "ProjectX)' <<< "$decoded"
}

# ---------------------------------------------------------------------------
# Check: Action SHA pinning
# ---------------------------------------------------------------------------
check_action_pinning() {
  local repo="$1"

  # List workflow files. Detect collection failure to avoid false closures (issue #1036).
  local workflows
  if ! workflows=$(gh_api "repos/$ORG/$repo/contents/.github/workflows" --jq '.[].name' 2>/dev/null); then
    # Workflow list fetch failed — collection was inconclusive, don't mark repo audited
    mark_repo_inconclusive "$repo"
    return 0
  fi

  for wf in $workflows; do
    [[ "$wf" != *.yml && "$wf" != *.yaml ]] && continue

    local content
    content=$(gh_api "repos/$ORG/$repo/contents/.github/workflows/$wf" --jq '.content' 2>/dev/null || echo "")
    [ -z "$content" ] && continue

    local decoded
    decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")
    [ -z "$decoded" ] && continue

    # Find uses: directives that are NOT SHA-pinned
    # SHA-pinned: uses: owner/action@<40+ hex chars>
    # Exclude docker:// and ./ references
    # Exclude $ORG/.github reusable workflow refs — these use tag refs
    # (@v1, @v2, @main) by design per ci-standards.md#action-pinning-policy
    local unpinned
    unpinned=$(echo "$decoded" | grep -E '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]+[^#]*@' | grep -vE '@[0-9a-f]{40}' | grep -vE '(docker://|\.\/)' | grep -vE "uses:[[:space:]]+$ORG/\\.github(-private)?/\\.github/workflows/" || true)

    if [ -n "$unpinned" ]; then
      local count
      count=$(echo "$unpinned" | wc -l | tr -d ' ')
      local examples
      examples=$(echo "$unpinned" | head -3 | sed 's/^[[:space:]]*//' | paste -sd ', ' -)
      add_finding "$repo" "action-pinning" "unpinned-actions-$wf" "error" \
        "Workflow \`$wf\` has $count action(s) not pinned to SHA: $examples" \
        "standards/ci-standards.md#action-pinning-policy"
    fi
  done
}

# ---------------------------------------------------------------------------
# Check: Reusable workflow path syntax
# ---------------------------------------------------------------------------
# NOTE: The correct pattern IS petry-projects/.github/.github/workflows/...
# because the first .github is the repository name, and the second .github
# is the directory path within that repository. This check is disabled as
# a known false positive per petry-projects/.github standards.
#
# Reference: https://docs.github.com/en/actions/using-workflows/reusing-workflows
# Example: uses: petry-projects/.github/.github/workflows/claude-code-reusable.yml@v1
check_reusable_workflow_paths() {
  local repo="$1"
  # This check is intentionally disabled — the double .github/ pattern is correct
  return 0
}

# ---------------------------------------------------------------------------
# Check: Pure reusable workflows must be disabled
# ---------------------------------------------------------------------------
# A "pure reusable" is a workflow whose `on:` block declares workflow_call and
# NOTHING else — it has no independent event triggers and can never run on its
# own, only when invoked via `uses:`. Per ci-standards.md such workflows must be
# disabled in the Actions UI. GitHub ignores a reusable's enabled/disabled state
# when it is called via workflow_call, so disabling has zero effect on callers.
# Hybrid workflows that ALSO declare a real trigger (schedule/workflow_dispatch/
# push/pull_request/...) are exempt and must stay active.
#
# Three YAML forms of `on:` are handled: block form, inline scalar
# (`on: workflow_call`), and inline sequence (`on: [workflow_call]`).
check_reusable_workflows_disabled() {
  local repo="$1"

  local workflows
  workflows=$(gh_api "repos/$ORG/$repo/contents/.github/workflows" --jq '.[].name' 2>/dev/null || echo "")

  for wf in $workflows; do
    [[ "$wf" != *.yml && "$wf" != *.yaml ]] && continue

    local content decoded
    content=$(gh_api "repos/$ORG/$repo/contents/.github/workflows/$wf" --jq '.content' 2>/dev/null || echo "")
    [ -z "$content" ] && continue
    decoded=$(printf '%s' "$content" | base64 -d 2>/dev/null) || continue
    [ -z "$decoded" ] && continue

    # Extract the top-level trigger keys from the `on:` declaration.
    # Handles block form, inline scalar (`on: workflow_call`), and
    # inline sequence (`on: [workflow_call, push]`).
    local triggers on_line
    on_line=$(echo "$decoded" | grep -m1 '^on:')
    if echo "$on_line" | grep -qE '^on:[[:space:]]+[a-zA-Z_]+[[:space:]]*(#.*)?$'; then
      # Inline scalar: on: workflow_call
      triggers=$(echo "$on_line" | sed 's/^on:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | tr -d '[:space:]')
    elif echo "$on_line" | grep -qE '^on:[[:space:]]*\['; then
      # Inline sequence: on: [workflow_call, push]
      triggers=$(echo "$on_line" | sed 's/^on:[[:space:]]*//' | tr -d '[]"'"'"' ' | tr ',' '\n' | tr -d '[:space:]')
    else
      # Block form: on:\n  key:\n  ...
      triggers=$(echo "$decoded" | awk '
        /^on:/                     { inblock=1; next }
        inblock && /^[^[:space:]#]/ { exit }          # dedent -> left the on: block
        inblock && /^  [a-zA-Z_]/  {                   # exactly-2-space-indented key
          key=$1; sub(/:.*/,"",key); gsub(/[[:space:]]/,"",key); print key
        }
      ')
    fi

    # Pure reusable = workflow_call present AND no other trigger key.
    echo "$triggers" | grep -qx "workflow_call" || continue
    if [ "$(echo "$triggers" | grep -vx "workflow_call" | grep -c .)" -ne 0 ]; then
      continue   # hybrid (workflow_call + real trigger) — exempt, must stay active
    fi

    # Naming lint — a pure reusable must carry the `-reusable.yml` suffix so its
    # "library, safe to disable, never runnable" nature is legible from the
    # filename. Detection above is by triggers, never by name (a name can lie);
    # this is a separate readability finding. Grandfathered: the legacy
    # `pr-review.yml` engine is tracked for rename in .github-private#1127 —
    # suppress its naming finding until the rename lands.
    if [[ "$wf" != *-reusable.yml && "$repo/$wf" != ".github-private/pr-review.yml" ]]; then
      add_finding "$repo" "reusable-workflows" "reusable-naming-$wf" "warning" \
        "Pure reusable workflow \`$wf\` (workflow_call-only) does not use the required \`-reusable.yml\` name suffix; rename it to \`<purpose>-reusable.yml\` so its reusable nature is legible from the filename" \
        "standards/ci-standards.md#pure-reusable-workflows-must-be-disabled"
    fi

    # Pure reusable — check its enabled/disabled state.
    local state
    state=$(gh_api "repos/$ORG/$repo/actions/workflows/$wf" --jq '.state' 2>/dev/null || echo "")
    [ -z "$state" ] && continue   # not registered (e.g. absent from default branch)

    if [ "$state" != "disabled_manually" ]; then
      add_finding "$repo" "reusable-workflows" "reusable-not-disabled-manually-$wf" "warning" \
        "Pure reusable workflow \`$wf\` (workflow_call-only) is in state \`$state\` (expected \`disabled_manually\`); it must be intentionally disabled in the Actions UI. Disable with: \`gh workflow disable $wf -R $ORG/$repo\`" \
        "standards/ci-standards.md#pure-reusable-workflows-must-be-disabled"
    fi
  done
}

# ---------------------------------------------------------------------------
# Check: Dependabot configuration
# ---------------------------------------------------------------------------
check_dependabot_config() {
  local repo="$1"

  local content
  content=$(gh_api "repos/$ORG/$repo/contents/.github/dependabot.yml" --jq '.content' 2>/dev/null || echo "")

  if [ -z "$content" ]; then
    add_finding "$repo" "dependabot" "missing-config" "error" \
      "Missing \`.github/dependabot.yml\` configuration file" \
      "standards/dependabot-policy.md"
    return 0
  fi

  local decoded
  decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")

  # Check github-actions ecosystem entry exists
  # Accept both double-quoted ("github-actions") and single-quoted ('github-actions') YAML values.
  if ! echo "$decoded" | grep -qE "package-ecosystem:[[:space:]]*(\"github-actions\"|'github-actions')"; then
    add_finding "$repo" "dependabot" "missing-github-actions-ecosystem" "error" \
      "Dependabot config missing \`github-actions\` ecosystem entry" \
      "standards/dependabot-policy.md#github-actions-all-repos"
  fi

  # Check that app ecosystem entries use open-pull-requests-limit: 0
  # Extract ecosystem blocks and check limits.
  # Accept both double-quoted and single-quoted YAML string values.
  for eco in npm pip gomod cargo terraform; do
    if echo "$decoded" | grep -qE "package-ecosystem:[[:space:]]*(\"$eco\"|'$eco')"; then
      # Check if this ecosystem has limit: 0
      # Simple heuristic: find the ecosystem line and look for limit in the next ~10 lines
      local block
      block=$(echo "$decoded" | awk "/package-ecosystem:.*(\"$eco\"|'$eco')/{found=1} found{print; if(/package-ecosystem:/ && NR>1 && !/(\"$eco\"|'$eco')/) exit}" | head -15)
      local limit
      limit=$(echo "$block" | grep 'open-pull-requests-limit:' | head -1 | grep -oE '[0-9]+' || echo "")
      if [ -n "$limit" ] && [ "$limit" != "0" ]; then
        add_finding "$repo" "dependabot" "wrong-limit-$eco" "warning" \
          "Dependabot \`$eco\` ecosystem has \`open-pull-requests-limit: $limit\` (should be \`0\` for security-only policy)" \
          "standards/dependabot-policy.md#policy"
      fi
    fi
  done

  # Check for required labels in dependabot config.
  # Accept both double-quoted and single-quoted YAML string values.
  if ! echo "$decoded" | grep -qE '("security"|'"'"'security'"'"')'; then
    add_finding "$repo" "dependabot" "missing-security-label" "warning" \
      "Dependabot config missing \`security\` label on updates" \
      "standards/dependabot-policy.md#policy"
  fi
  if ! echo "$decoded" | grep -qE '("dependencies"|'"'"'dependencies'"'"')'; then
    add_finding "$repo" "dependabot" "missing-dependencies-label" "warning" \
      "Dependabot config missing \`dependencies\` label on updates" \
      "standards/dependabot-policy.md#policy"
  fi
}

# ---------------------------------------------------------------------------
# Check: Repository settings
# ---------------------------------------------------------------------------
check_repo_settings() {
  local repo="$1"
  local repo_json="$2"

  local settings
  settings=$(echo "$repo_json" | jq '{
    allow_auto_merge: .allow_auto_merge,
    delete_branch_on_merge: .delete_branch_on_merge,
    has_wiki: .has_wiki,
    has_discussions: .has_discussions,
    default_branch: .default_branch,
    has_issues: .has_issues
  }' 2>/dev/null || echo "{}")

  [ "$settings" = "{}" ] && return

  # Boolean settings checks
  for entry in "${REQUIRED_SETTINGS_BOOL[@]}"; do
    IFS=':' read -r key expected severity detail <<< "$entry"
    local actual
    actual=$(printf '%s' "$settings" | jq -r --arg key "$key" '.[$key] | if . == null then "null" else tostring end')
    if [ "$actual" != "$expected" ]; then
      add_finding "$repo" "settings" "$key" "$severity" \
        "$detail (current: \`$actual\`, expected: \`$expected\`)" \
        "standards/github-settings.md#repository-settings--standard-defaults"
    fi
  done

  # Default branch
  local default_branch
  default_branch=$(printf '%s' "$settings" | jq -r '.default_branch')
  if [ "$default_branch" != "main" ]; then
    add_finding "$repo" "settings" "default-branch" "error" \
      "Default branch is \`$default_branch\`, should be \`main\`" \
      "standards/github-settings.md#general"
  fi

}

# ---------------------------------------------------------------------------
# Check: Required labels
# ---------------------------------------------------------------------------
check_labels() {
  local repo="$1"

  local existing_labels
  existing_labels=$(gh_api "repos/$ORG/$repo/labels" --jq '.[].name' --paginate 2>/dev/null || echo "")

  # --- Fixed set (STANDARD_LABEL_SPECS, from scripts/lib/labels.sh) -----------
  local spec label color description rest
  for spec in "${STANDARD_LABEL_SPECS[@]}"; do
    label="${spec%%|*}"
    rest="${spec#*|}"
    color="${rest%%|*}"
    description="${rest#*|}"
    _check_or_create_label "$repo" "$label" "$color" "$description" "$existing_labels"
  done

  # --- Derived <id>:hands-off persona opt-out family --------------------------
  # Derived from the persona manifests EXACTLY as apply-repo-settings.sh's
  # apply_labels does (persona_opt_out_label_configs), so adding a persona
  # requires no edit to any label list here (#756, issue #1139 AC#1).
  #
  # Fail closed (#755, AC#3): if the family cannot be derived faithfully — the
  # manifest listing is unreadable, or a manifest could not be read and its label
  # had to be guessed — emit a finding. An unreadable manifest list must NEVER be
  # read as "no persona labels required"; that is the systemic bug the applier
  # already guards against, mirrored here.
  local persona_out persona_rc=0
  persona_out=$(persona_opt_out_label_configs) || persona_rc=$?
  if [ "$persona_rc" -ne 0 ]; then
    add_finding "$repo" "labels" "persona-opt-out-derivation-failed" "error" \
      "Could not derive the \`<id>:hands-off\` persona opt-out label family from the persona manifests (\`$PERSONA_MANIFEST_REPO\`). Failing closed: an unreadable or incomplete manifest list is NOT treated as \"no persona labels required\" — run \`scripts/apply-repo-settings.sh $repo\` once the manifests are readable to provision the family." \
      "standards/github-settings.md#derived-family--persona-opt-out-labels-idhands-off"
  fi
  # Still check whatever WAS derived: a partial derivation emits its best guess,
  # and even on the happy path this is the per-persona missing-label check.
  while IFS='|' read -r label color description; do
    [ -z "$label" ] && continue
    _check_or_create_label "$repo" "$label" "$color" "$description" "$existing_labels"
  done <<< "$persona_out"
}

# _check_or_create_label <repo> <label> <color> <description> <existing_labels>
# If <label> is absent from the newline-separated <existing_labels>: file a
# missing-label finding in the read-only default, or (when mutations are enabled)
# create it idempotently and file a finding only if creation fails. Shared by the
# fixed set and the derived persona family so both honour the read-only default
# (issue #1036, AC4) and both auto-create under --apply.
_check_or_create_label() {
  local repo="$1" label="$2" color="$3" description="$4" existing_labels="$5"

  echo "$existing_labels" | grep -qxF -- "$label" && return 0

  if ! mutations_enabled; then
    add_finding "$repo" "labels" "missing-label-$label" "warning" \
      "Required label \`$label\` is missing" \
      "standards/github-settings.md#labels--standard-set"
    return 0
  fi

  info "Auto-creating missing label '$label' on $repo"
  if gh label create "$label" \
      --repo "$ORG/$repo" \
      --color "$color" \
      --description "$description" \
      --force 2>/dev/null; then
    info "Label '$label' created successfully on $repo"
  else
    warn "Failed to create label '$label' on $repo — filing finding for manual remediation"
    add_finding "$repo" "labels" "missing-label-$label" "warning" \
      "Required label \`$label\` is missing and could not be auto-created" \
      "standards/github-settings.md#labels--standard-set"
  fi
}

# ---------------------------------------------------------------------------
# Check: Repository rulesets
# ---------------------------------------------------------------------------
check_rulesets() {
  local repo="$1"
  local repo_json="${2:-}"

  # Default branch drives which rulesets are "targeting main" below.
  local default_branch
  default_branch=$(echo "$repo_json" | jq -r '.default_branch // "main"' 2>/dev/null || echo "main")
  if [ -z "$default_branch" ] || [ "$default_branch" = "null" ]; then
    default_branch="main"
  fi

  # Fetch the full ruleset list once (id + name + everything). We need ids to
  # pull each ruleset's bypass_actors below, so we cannot use --jq '.[].name'.
  # Use --paginate so all rulesets are fetched regardless of page count, then
  # reconstitute the per-page arrays into one flat array with jq -s '[.[]]'.
  local rulesets_json
  rulesets_json=$(gh_api --paginate "repos/$ORG/$repo/rulesets" 2>/dev/null | jq -s '[.[][]]' 2>/dev/null || echo "[]")
  [ -z "$rulesets_json" ] && rulesets_json="[]"

  local names
  names=$(echo "$rulesets_json" | jq -r '.[].name' 2>/dev/null || echo "")

  if ! echo "$names" | grep -qx "pr-quality"; then
    add_finding "$repo" "rulesets" "missing-pr-quality" "error" \
      "Missing \`pr-quality\` repository ruleset" \
      "standards/github-settings.md#pr-quality--standard-ruleset-all-repositories"
  fi

  if ! echo "$names" | grep -qx "code-quality"; then
    add_finding "$repo" "rulesets" "missing-code-quality" "error" \
      "Missing \`code-quality\` repository ruleset (required status checks)" \
      "standards/github-settings.md#code-quality--required-checks-ruleset-all-repositories"
  fi

  check_ruleset_bypass_actors "$repo" "$default_branch" "$rulesets_json"
  check_legacy_rulesets "$repo" "$default_branch" "$rulesets_json"
  check_ruleset_contents "$repo" "$rulesets_json"
}

# ---------------------------------------------------------------------------
# Check: Ruleset CONTENTS match the codified source of truth
# ---------------------------------------------------------------------------
# check_rulesets above only verifies a ruleset EXISTS BY NAME. That is the whole
# of the pre-#766 check: a repo could flip `required_review_thread_resolution`
# to false, drop `require_code_owner_review`, lower the approving-review count,
# or widen `allowed_merge_methods`, and compliance still passed because a
# ruleset named `pr-quality` still existed. The codified standard and live
# reality could diverge arbitrarily and silently (issue #766).
#
# This check compares each live ruleset against its codified source in
# standards/rulesets/*.json and raises a finding per drifted PARAMETER, naming
# the parameter, the expected value, and the actual value.
#
# Design constraints (issue #766):
#   - The codified JSON is the source of truth (#575/#580). Intent is NEVER
#     inferred from the live ruleset — that is the detection-based builder
#     apply-rulesets.sh retired for diverging from the standard.
#   - Normalisation: only the parameters WE CODIFY are compared. The API returns
#     fields the codified JSON does not carry (id, source, source_type,
#     _links, required_reviewers, dismissal_restriction, actor ids) and in a
#     different key order; iterating only codified keys and comparing values (not
#     serialised blobs) ignores that noise so a clean fleet stays clean.
#   - required_status_checks uses SUBSET semantics: the codified contexts are the
#     unconditional fleet-wide minimum (github-settings.md#code-quality); a repo
#     may ADD repo-specific checks (build-and-test, Go, coverage, …) — those are
#     not drift. A MISSING codified context IS drift. Every other parameter
#     (pull_request scalars + allowed_merge_methods) is matched exactly, with
#     arrays compared order-insensitively.
#   - Fail closed: if a ruleset cannot be fetched or parsed, or the codified
#     source is missing, that is a finding — never a silent pass. An error must
#     never read as "no drift" (the systemic bug in #755).
#
# Missing-by-name is already reported by check_rulesets (missing-pr-quality /
# missing-code-quality); this check stays silent in that case to avoid double
# reporting, and instead audits the contents of the rulesets that DO exist.

# Codified ruleset name → the rule `type` whose parameters we audit.
RULESET_CONTENT_SPECS=(
  "pr-quality:pull_request:standards/github-settings.md#pr-quality--standard-ruleset-all-repositories"
  "code-quality:required_status_checks:standards/github-settings.md#code-quality--required-checks-ruleset-all-repositories"
)

# jq program: given codified params ($exp) and live params ($act), emit one
# TSV line (param<TAB>expected<TAB>actual) per drifted codified parameter.
#   - required_status_checks: subset check on the set of `.context` values;
#     drift only when a codified context is absent from the live set. `actual`
#     is rendered as the missing contexts so the finding is directly actionable.
#   - all other params: exact compare (arrays sorted so order never matters).
RULESET_DRIFT_JQ='
  def ctxset($v): (if ($v | type) == "array" then [ $v[]? | .context? ] | unique else [] end);
  ($act // {}) as $a
  | $exp | to_entries[]
  | .key as $k
  | .value as $ev
  | ($a[$k]) as $av
  | if $k == "required_status_checks" then
      (ctxset($ev)) as $e
      | (ctxset($av)) as $c
      | ($e - $c) as $missing
      | select(($missing | length) > 0)
      | [ $k, ($e | join(", ")), ("missing: " + ($missing | join(", "))) ]
    else
      (if ($ev | type) == "array" then ($ev | sort) else $ev end) as $e
      | (if ($av | type) == "array" then ($av | sort) else $av end) as $c
      | select($e != $c)
      | [ $k,
          ($e | if type == "array" then map(tostring) | join(", ") else tostring end),
          ($c | if type == "array" then map(tostring) | join(", ") else tostring end) ]
    end
  | @tsv
'

check_ruleset_contents() {
  local repo="$1" rulesets_json="$2"

  local spec name rtype std_ref
  for spec in "${RULESET_CONTENT_SPECS[@]}"; do
    IFS=':' read -r name rtype std_ref <<< "$spec"
    _ruleset_contents_one "$repo" "$rulesets_json" "$name" "$rtype" "$std_ref"
  done
}

# _ruleset_contents_one <repo> <rulesets_json> <name> <rule_type> <std_ref>
# Audit one named ruleset's codified parameters against its live counterpart.
_ruleset_contents_one() {
  local repo="$1" rulesets_json="$2" name="$3" rtype="$4" std_ref="$5"

  # --- Codified source of truth (fail closed if missing/unparseable) --------
  local codified_file="$RULESETS_SRC_DIR/$name.json"
  if [ ! -f "$codified_file" ]; then
    add_finding "$repo" "rulesets" "ruleset-contents-source-missing-$name" "error" \
      "Cannot audit \`$name\` ruleset contents: codified source of truth \`standards/rulesets/$name.json\` was not found. Treating as a finding rather than a pass (fail closed) — an audit that cannot read the standard must never read as \"no drift\"." \
      "$std_ref"
    return 0
  fi
  local exp_params
  exp_params=$(jq -c --arg t "$rtype" '[.rules[]? | select(.type==$t) | .parameters][0] // empty' "$codified_file" 2>/dev/null || echo "")
  if [ -z "$exp_params" ]; then
    add_finding "$repo" "rulesets" "ruleset-contents-source-invalid-$name" "error" \
      "Cannot audit \`$name\` ruleset contents: codified source \`standards/rulesets/$name.json\` has no \`$rtype\` rule parameters to compare against (unparseable or malformed). Fail closed." \
      "$std_ref"
    return 0
  fi

  # --- Resolve the live ruleset id by name ----------------------------------
  # Absence-by-name is already reported by check_rulesets; stay silent here.
  local rs_id
  rs_id=$(echo "$rulesets_json" | jq -r --arg n "$name" '.[]? | select(.name==$n) | .id' 2>/dev/null || echo "")
  [ -z "$rs_id" ] && return 0

  # --- Fetch the full live ruleset (fail closed on error/invalid JSON) ------
  local rs
  rs=$(gh_api "repos/$ORG/$repo/rulesets/$rs_id" 2>/dev/null || echo "")
  if [ -z "$rs" ] || ! echo "$rs" | jq empty >/dev/null 2>&1; then
    add_finding "$repo" "rulesets" "ruleset-contents-unfetchable-$name" "error" \
      "Could not fetch or parse the \`$name\` ruleset (id $rs_id) to audit its contents against \`standards/rulesets/$name.json\`. Treating as drift, not a pass (fail closed): an error must never be conflated with \"no drift\"." \
      "$std_ref"
    return 0
  fi

  # A ruleset that exists but has lost the codified rule type entirely is drift.
  local has_rule
  has_rule=$(echo "$rs" | jq --arg t "$rtype" 'any(.rules[]?; .type==$t)' 2>/dev/null || echo "false")
  if [ "$has_rule" != "true" ]; then
    add_finding "$repo" "rulesets" "ruleset-drift-$name-missing-rule" "error" \
      "Ruleset \`$name\` exists but no longer carries a \`$rtype\` rule, so every codified parameter is unenforced. The codified standard (\`standards/rulesets/$name.json\`) requires it; run \`scripts/apply-rulesets.sh --repo $ORG/$repo\` to converge." \
      "$std_ref"
    return 0
  fi

  local act_params
  act_params=$(echo "$rs" | jq -c --arg t "$rtype" '[.rules[]? | select(.type==$t) | .parameters][0] // {}' 2>/dev/null || echo "")
  [ -z "$act_params" ] && act_params="{}"

  # --- Diff codified vs live and emit one finding per drifted parameter ------
  local drift
  if ! drift=$(jq -rn --argjson exp "$exp_params" --argjson act "$act_params" "$RULESET_DRIFT_JQ" 2>/dev/null); then
    add_finding "$repo" "rulesets" "ruleset-contents-uncomparable-$name" "error" \
      "Could not compare the \`$name\` ruleset (id $rs_id) against \`standards/rulesets/$name.json\` (parameter comparison failed). Fail closed." \
      "$std_ref"
    return 0
  fi

  local param expected actual slug
  while IFS=$'\t' read -r param expected actual || [ -n "$param" ]; do
    [ -z "$param" ] && continue
    slug=$(printf '%s' "$param" | tr '[:upper:]' '[:lower:]' | tr ' /' '--' | tr -cd 'a-z0-9_-')
    [ -z "$slug" ] && slug="param"
    add_finding "$repo" "rulesets" "ruleset-drift-$name-$slug" "error" \
      "Ruleset \`$name\` parameter \`$param\` has drifted from the codified standard: expected \`$expected\`, actual \`$actual\`. The codified JSON (\`standards/rulesets/$name.json\`) is the source of truth (#575/#580); run \`scripts/apply-rulesets.sh --repo $ORG/$repo\` to converge." \
      "$std_ref"
  done <<< "$drift"
}

# ---------------------------------------------------------------------------
# Check: Ruleset bypass actors (every ruleset targeting the default branch)
# ---------------------------------------------------------------------------
# The standard (github-settings.md § "Bypass Actors — Required on Every Ruleset
# Targeting main") requires that EVERY ruleset whose conditions include the
# default branch grant always-bypass to BOTH:
#   1. the `dependabot-automerge-petry` GitHub App (Integration, actor_id 3167543)
#   2. the `OrganizationAdmin` role
# GitHub evaluates bypass eligibility independently per ruleset, so a missing
# actor on code-quality (or a legacy protect-branches / main ruleset) silently
# blocks Dependabot auto-merge or removes the emergency admin override even when
# pr-quality is correct. This logic previously lived only as a copy-paste shell
# snippet in the standard and was never enforced by the audit.
#
# Two correctness nuances the simple snippet missed:
#   - bypass_mode MUST be `always`. `pull_request` mode only applies when the
#     bypass actor opens the PR; Dependabot opens its own PRs, so a
#     `pull_request`-mode app bypass is rejected at merge time.
#   - The `Repository admin` role (RepositoryRole, actor_id 5) is NOT the
#     `OrganizationAdmin` role. It renders similarly in the UI but is repo-scoped
#     and does not satisfy the org-wide emergency-override requirement.
DEPENDABOT_APP_ACTOR_ID=3167543

check_ruleset_bypass_actors() {
  local repo="$1" default_branch="$2" rulesets_json="$3"

  local std_ref="standards/github-settings.md#bypass-actors--required-on-every-ruleset-targeting-main"

  local ids
  ids=$(echo "$rulesets_json" | jq -r '.[].id' 2>/dev/null || echo "")
  [ -z "$ids" ] && return 0

  local rs_id
  for rs_id in $ids; do
    local rs
    rs=$(gh_api "repos/$ORG/$repo/rulesets/$rs_id" 2>/dev/null || echo "")
    [ -z "$rs" ] && continue

    # Does this ruleset target the default branch? Match the GitHub aliases
    # (~DEFAULT_BRANCH, ~ALL) or an explicit refs/heads/<default> include.
    local targets_default
    targets_default=$(echo "$rs" | jq --arg db "refs/heads/$default_branch" '
      ((.conditions.ref_name.include) // []) as $inc
      | ((.conditions.ref_name.exclude) // []) as $exc
      | (
          (($inc | index("~DEFAULT_BRANCH")) != null)
          or (($inc | index("~ALL")) != null)
          or (($inc | index($db)) != null)
        )
        and (($exc | index("~DEFAULT_BRANCH")) == null)
        and (($exc | index($db)) == null)
    ' 2>/dev/null || echo "false")
    [ "$targets_default" != "true" ] && continue

    local rs_name
    rs_name=$(echo "$rs" | jq -r '.name' 2>/dev/null || echo "ruleset-$rs_id")
    # Stable, filesystem/label-safe slug for the finding id so findings don't
    # churn across runs. Ruleset names (pr-quality, code-quality, …) are stable.
    local slug
    slug=$(printf '%s' "$rs_name" | tr '[:upper:] /' '[:lower:]--' | tr -cd 'a-z0-9_-')
    [ -z "$slug" ] && slug="$rs_id"

    # --- Bypass actor check (single jq invocation) ------------------------
    local oa_always oa_any repo_admin dep_always dep_any
    local bypass_info
    bypass_info=$(jq -r --argjson id "$DEPENDABOT_APP_ACTOR_ID" '
      [
        ([.bypass_actors[]? | select(.actor_type=="OrganizationAdmin" and .bypass_mode=="always")] | length > 0),
        ([.bypass_actors[]? | select(.actor_type=="OrganizationAdmin")] | length > 0),
        ([.bypass_actors[]? | select(.actor_type=="RepositoryRole" and .actor_id==5)] | length > 0),
        ([.bypass_actors[]? | select(.actor_type=="Integration" and .actor_id==$id and .bypass_mode=="always")] | length > 0),
        ([.bypass_actors[]? | select(.actor_type=="Integration" and .actor_id==$id)] | length > 0)
      ] | map(tostring) | join(" ")
    ' <<< "$rs" 2>/dev/null || echo "false false false false false")
    [ -z "$bypass_info" ] && bypass_info="false false false false false"
    read -r oa_always oa_any repo_admin dep_always dep_any <<< "$bypass_info"

    if [ "$oa_always" != "true" ]; then
      if [ "$oa_any" = "true" ]; then
        add_finding "$repo" "rulesets" "ruleset-bypass-orgadmin-mode-$slug" "error" \
          "Ruleset \`$rs_name\` (targets \`$default_branch\`) grants \`OrganizationAdmin\` bypass but not with \`bypass_mode: always\`. The standard requires \`always\` for emergency admin override on every ruleset targeting the default branch." \
          "$std_ref"
      elif [ "$repo_admin" = "true" ]; then
        add_finding "$repo" "rulesets" "ruleset-bypass-orgadmin-$slug" "error" \
          "Ruleset \`$rs_name\` (targets \`$default_branch\`) grants bypass to the **Repository admin** role (RepositoryRole id 5), not the **OrganizationAdmin** role required by the standard. Repository admin is repo-scoped and does not satisfy the org-wide emergency-override requirement. Add \`OrganizationAdmin\` with \`bypass_mode: always\`." \
          "$std_ref"
      else
        add_finding "$repo" "rulesets" "ruleset-bypass-orgadmin-$slug" "error" \
          "Ruleset \`$rs_name\` (targets \`$default_branch\`) is missing the required \`OrganizationAdmin\` bypass actor (\`bypass_mode: always\`) for emergency admin override." \
          "$std_ref"
      fi
    fi

    # --- dependabot-automerge-petry app -----------------------------------
    if [ "$dep_always" != "true" ]; then
      if [ "$dep_any" = "true" ]; then
        add_finding "$repo" "rulesets" "ruleset-bypass-dependabot-mode-$slug" "error" \
          "Ruleset \`$rs_name\` (targets \`$default_branch\`) grants the \`dependabot-automerge-petry\` app (id $DEPENDABOT_APP_ACTOR_ID) bypass but with the wrong mode. \`pull_request\` mode only applies when the bypass actor opens the PR; Dependabot opens its own PRs, so its merge API calls are rejected. Set \`bypass_mode: always\`." \
          "$std_ref"
      else
        add_finding "$repo" "rulesets" "ruleset-bypass-dependabot-$slug" "error" \
          "Ruleset \`$rs_name\` (targets \`$default_branch\`) is missing the required \`dependabot-automerge-petry\` app (id $DEPENDABOT_APP_ACTOR_ID) bypass actor (\`bypass_mode: always\`). Without it, Dependabot auto-merge API calls are rejected by this ruleset — GitHub evaluates bypass per-ruleset, so it must be present on every ruleset targeting the default branch, not only \`pr-quality\`." \
          "$std_ref"
      fi
    fi
  done
}

# ---------------------------------------------------------------------------
# Check: Legacy / non-sanctioned rulesets on the default branch
# ---------------------------------------------------------------------------
# `pr-quality` and `code-quality` are the ONLY sanctioned rulesets
# (standards/github-settings.md § Repository Rulesets). Classic
# `protect-branches` rules and ad-hoc `main` rulesets are deprecated and MUST be
# migrated into the two sanctioned rulesets and deleted. A leftover legacy
# ruleset is drift: it duplicates protections, and — because GitHub evaluates
# bypass per-ruleset — it is a second place every bypass actor must be kept in
# sync (the exact trap that produced the inconsistent OrganizationAdmin /
# RepositoryAdmin bypass state across the fleet).
#
# Deleting a legacy ruleset is only safe once every required status check it
# carries is ALSO required by a sanctioned ruleset; otherwise deletion silently
# drops a merge gate. This check computes that migration delta and reports it so
# remediation is deterministic: "safe to delete" vs the exact checks to migrate
# first.
SANCTIONED_RULESETS=("pr-quality" "code-quality")

check_legacy_rulesets() {
  local repo="$1" default_branch="$2" rulesets_json="$3"

  local std_ref="standards/github-settings.md#repository-rulesets"

  local ids
  ids=$(echo "$rulesets_json" | jq -r '.[].id' 2>/dev/null || echo "")
  [ -z "$ids" ] && return 0

  # jq snippet: does a ruleset (full JSON on stdin) target the default branch?
  # Kept identical to check_ruleset_bypass_actors so the two agree on scope.
  local targets_jq='
    ((.conditions.ref_name.include) // []) as $inc
    | ((.conditions.ref_name.exclude) // []) as $exc
    | (
        (($inc | index("~DEFAULT_BRANCH")) != null)
        or (($inc | index("~ALL")) != null)
        or (($inc | index($db)) != null)
      )
      and (($exc | index("~DEFAULT_BRANCH")) == null)
      and (($exc | index($db)) == null)
  '

  # Pass 1: fetch every default-branch ruleset once, caching name + JSON, and
  # accumulate the set of status-check contexts required by the SANCTIONED
  # rulesets (the coverage that will remain after a legacy ruleset is deleted).
  local sanctioned_ctx=""        # newline-separated contexts
  declare -A rs_cache=()         # rs_id -> full JSON (only default-branch ones)
  declare -A rs_name_cache=()    # rs_id -> name
  local rs_id rs targets rs_name
  for rs_id in $ids; do
    rs=$(gh_api "repos/$ORG/$repo/rulesets/$rs_id" 2>/dev/null || echo "")
    [ -z "$rs" ] && continue
    targets=$(echo "$rs" | jq --arg db "refs/heads/$default_branch" "$targets_jq" 2>/dev/null || echo "false")
    [ "$targets" != "true" ] && continue

    rs_name=$(echo "$rs" | jq -r '.name' 2>/dev/null || echo "ruleset-$rs_id")
    rs_cache["$rs_id"]="$rs"
    rs_name_cache["$rs_id"]="$rs_name"

    if [[ " ${SANCTIONED_RULESETS[*]} " == *" $rs_name "* ]]; then
      local ctx
      ctx=$(echo "$rs" | jq -r '[.rules[]? | select(.type=="required_status_checks") | .parameters.required_status_checks[]?.context] | .[]' 2>/dev/null || echo "")
      [ -n "$ctx" ] && sanctioned_ctx+="$ctx"$'\n'
    fi
  done

  # Pass 2: flag every non-sanctioned default-branch ruleset and compute the
  # set of required checks it carries that are NOT covered by the sanctioned
  # rulesets — the checks that must be migrated before it is safe to delete.
  for rs_id in "${!rs_cache[@]}"; do
    rs_name="${rs_name_cache[$rs_id]}"
    [[ " ${SANCTIONED_RULESETS[*]} " == *" $rs_name "* ]] && continue

    rs="${rs_cache[$rs_id]}"
    local slug
    slug=$(printf '%s' "$rs_name" | tr '[:upper:] /' '[:lower:]--' | tr -cd 'a-z0-9_-')
    [ -z "$slug" ] && slug="$rs_id"

    local legacy_ctx uncovered=""
    legacy_ctx=$(echo "$rs" | jq -r '[.rules[]? | select(.type=="required_status_checks") | .parameters.required_status_checks[]?.context] | .[]' 2>/dev/null || echo "")
    local c
    while IFS= read -r c; do
      [ -z "$c" ] && continue
      if ! grep -qxF "$c" <<< "$sanctioned_ctx"; then
        uncovered+="\`$c\` "
      fi
    done <<< "$legacy_ctx"

    local migrate_note
    if [ -n "$uncovered" ]; then
      migrate_note="**Migrate before deleting** — these required checks are not yet required by \`pr-quality\` or \`code-quality\`, so deleting this ruleset would drop them as merge gates: ${uncovered}Add them to \`code-quality\` first, then delete this ruleset."
    else
      migrate_note="Every required check it carries is already required by a sanctioned ruleset, so it is **safe to delete** (e.g. \`gh api -X DELETE repos/$ORG/$repo/rulesets/$rs_id\`)."
    fi

    add_finding "$repo" "rulesets" "legacy-ruleset-$slug" "error" \
      "Legacy ruleset \`$rs_name\` (id $rs_id) targets the default branch. Only \`pr-quality\` and \`code-quality\` are sanctioned; classic \`protect-branches\` / ad-hoc \`main\` rulesets are deprecated and must be migrated into the two sanctioned rulesets and removed (a duplicate ruleset is a second place every bypass actor must be kept in sync). $migrate_note" \
      "$std_ref"
  done
}

# ---------------------------------------------------------------------------
# Check: CODEOWNERS
# ---------------------------------------------------------------------------
check_codeowners() {
  local repo="$1"

  # CODEOWNERS can be in root, .github/, or docs/
  local found=false
  local codeowners_content=""
  # #437: distinguish a genuinely-absent file (a deterministic HTTP 404 on every
  # candidate path) from a transient/auth read error (non-404), so a blip never
  # becomes a false `missing-codeowners` finding that spends a whole dev-lead run
  # confirming a file that was there all along. Mirrors check_check_suite_prefs
  # (#487): capture the raw response + status that gh_api's `--jq` masks, retry
  # non-deterministic failures, and treat any non-404 failure as inconclusive.
  local any_unreadable=false
  for path in CODEOWNERS .github/CODEOWNERS docs/CODEOWNERS; do
    local raw="" rc=1 i
    for i in 1 2 3; do
      raw=$(gh api "repos/$ORG/$repo/contents/$path" 2>&1) && rc=0 || rc=$?
      [ "$rc" -eq 0 ] && break
      # 404 is deterministic — the file is not at this path; stop retrying it.
      # Matches both gh's stderr "(HTTP 404)" and the API's JSON {"status":"404"}.
      [[ "$raw" == *"HTTP 404"* || "$raw" == *'"status":"404"'* ]] && break
      [ "$i" -lt 3 ] && sleep $((i * 2))
    done
    if [ "$rc" -ne 0 ]; then
      # Non-404 failure (auth/scope/network/5xx/rate-limit) → inconclusive path.
      [[ "$raw" == *"HTTP 404"* || "$raw" == *'"status":"404"'* ]] || any_unreadable=true
      continue
    fi
    local content decoded
    content=$(printf '%s' "$raw" | jq -r '.content? // empty' 2>/dev/null || echo "")
    [ -n "$content" ] || continue
    # The contents API returns the body as base64. Reject anything that does not
    # cleanly decode so an error body can never leak in as owner lines (#370).
    decoded=$(printf '%s' "$content" | base64 -d 2>/dev/null) || continue
    [ -n "$decoded" ] || continue
    found=true
    codeowners_content="$decoded"
    break
  done

  if [ "$found" = false ]; then
    if [ "$any_unreadable" = true ]; then
      # Could not determine presence — do NOT file a `missing` finding (#437).
      add_finding "$repo" "settings" "codeowners-unreadable" "warning" \
        "Could not read CODEOWNERS (transient/auth error, not a 404) — verify GH_TOKEN scope and repo access. CODEOWNERS presence was not evaluated this run; NOT filed as missing to avoid a false finding." \
        "standards/codeowners-standard.md"
      return 0
    fi
    add_finding "$repo" "settings" "missing-codeowners" "error" \
      "No \`CODEOWNERS\` file found — required for code owner review enforcement (pr-quality ruleset)" \
      "standards/codeowners-standard.md"
    return 0
  fi

  # Extract non-comment, non-blank owner lines for accurate matching.
  # Each such line has the form: <pattern> <owner1> [<owner2> ...]
  # Standard (codeowners-standard.md):
  #   1. @petry-projects/org-leads MUST be the FIRST owner on every line.
  #   2. Additional teams (@petry-projects/<slug>) are allowed.
  #   3. Individual users (@username without "/") are forbidden.
  local owner_lines
  owner_lines=$(echo "$codeowners_content" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$')

  if [ -z "$owner_lines" ]; then
    add_finding "$repo" "settings" "codeowners-empty" "error" \
      "CODEOWNERS file has no owner lines (only comments/blank)" \
      "standards/codeowners-standard.md"
    return 0
  fi

  # Rule 1: @petry-projects/org-leads MUST be the first owner on every line
  # (the first whitespace-separated token after the pattern).
  local bad_first_owner=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # awk $2 = first owner token after the pattern
    local first_owner
    first_owner=$(echo "$line" | awk '{print $2}')
    if [ "$first_owner" != "@petry-projects/org-leads" ]; then
      bad_first_owner="$line"
      break
    fi
  done <<< "$owner_lines"
  if [ -n "$bad_first_owner" ]; then
    add_finding "$repo" "settings" "codeowners-org-leads-not-first" "error" \
      "CODEOWNERS owner lines must list \`@petry-projects/org-leads\` as the FIRST owner. Offending line: \`$bad_first_owner\`" \
      "standards/codeowners-standard.md"
  fi

  # Rule 3: no individual users — every owner token must be a team (contain "/").
  # Collect owner tokens from all lines (everything starting with @).
  local individual_owners
  individual_owners=$(echo "$owner_lines" \
    | tr ' \t' '\n' \
    | grep -E '^@' \
    | grep -vE '^@[^/]+/' \
    | sort -u || true)
  if [ -n "$individual_owners" ]; then
    local joined
    joined=$(echo "$individual_owners" | tr '\n' ' ')
    add_finding "$repo" "settings" "codeowners-individual-users" "error" \
      "CODEOWNERS contains forbidden individual user owners: ${joined% } — only teams (@petry-projects/<slug>) are allowed; manage membership via teams" \
      "standards/codeowners-standard.md"
  fi

  # Advisory: a catch-all `*` pattern should exist so files unmatched by any
  # path-specific rule still have an owner.
  if ! echo "$owner_lines" | awk '{print $1}' | grep -qxF '*'; then
    add_finding "$repo" "settings" "codeowners-no-catchall" "warning" \
      "CODEOWNERS has no default \`*\` catch-all pattern — files not matched by a path rule will have no owner and \`require_code_owner_review\` will not apply to them" \
      "standards/codeowners-standard.md"
  fi
}

# ---------------------------------------------------------------------------
# Check: SonarCloud project properties
# ---------------------------------------------------------------------------
check_sonarcloud() {
  local repo="$1"

  # Only check if sonarcloud.yml exists
  if gh_api "repos/$ORG/$repo/contents/.github/workflows/sonarcloud.yml" --jq '.name' > /dev/null 2>&1; then
    if ! gh_api "repos/$ORG/$repo/contents/sonar-project.properties" --jq '.name' > /dev/null 2>&1; then
      add_finding "$repo" "ci-workflows" "missing-sonar-properties" "warning" \
        "SonarCloud workflow exists but \`sonar-project.properties\` is missing" \
        "standards/ci-standards.md#3-sonarcloud-analysis-sonarcloudyml"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Check: SonarCloud S7637 first-party reusable-ref exemption (#498)
#
# SonarCloud's githubactions:S7637 ("pin actions to a full-length commit SHA")
# fires on first-party petry-projects/.github(-private) reusable-ref caller
# stubs that the org standard intentionally pins by moving channel/tag rather
# than SHA (see check_action_pinning's exemption and the Action Pinning Policy).
# The two policies are otherwise mutually exclusive on a single pin, so each
# SonarCloud-gated repo must carry a NARROW sonar.issue.ignore that suppresses
# S7637 only on the thin caller-stub workflow files — never a blanket
# workflows/*.yml exclusion, which would also drop SHA-pin enforcement on the
# third-party actions in ci.yml/sonarcloud.yml.
#
# classify_sonar_s7637_exemption echoes exactly one verdict for a given
# sonar-project.properties body:
#   present   — at least one issue-ignore criterion suppresses
#               githubactions:S7637 and every such criterion targets specific
#               caller-stub files (no blanket workflow glob).
#   too-broad — an S7637 criterion uses a blanket resourceKey (the filename
#               segment carries a wildcard, e.g. workflows/*.yml or *.yml, or
#               the pattern is a bare **). This also exempts third-party actions
#               and violates the org policy.
#   missing   — no criterion suppresses githubactions:S7637.
# ---------------------------------------------------------------------------
classify_sonar_s7637_exemption() {
  local content="$1"

  # Criterion keys whose ruleKey assigns githubactions:S7637 (whitespace around
  # the key/`=`/value is tolerated; properties keys are [A-Za-z0-9_]).
  local keys
  keys=$(printf '%s\n' "$content" \
    | grep -E '^[[:space:]]*sonar\.issue\.ignore\.multicriteria\.[A-Za-z0-9_]+\.ruleKey[[:space:]]*=[[:space:]]*githubactions:S7637[[:space:]]*$' \
    | sed -E 's/^[[:space:]]*sonar\.issue\.ignore\.multicriteria\.([A-Za-z0-9_]+)\.ruleKey.*/\1/' || true)

  if [ -z "$keys" ]; then
    echo "missing"
    return 0
  fi

  local key resourcekey base broad=0
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    resourcekey=$(printf '%s\n' "$content" \
      | grep -E "^[[:space:]]*sonar\\.issue\\.ignore\\.multicriteria\\.${key}\\.resourceKey[[:space:]]*=" \
      | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//' | head -n1 || true)
    # A criterion is blanket (too broad) when the filename segment carries a
    # wildcard — e.g. **/.github/workflows/*.yml, *.yml — or the whole pattern
    # is a bare **. Such a pattern also matches ci.yml and would drop S7637 on
    # the third-party actions there.
    base="${resourcekey##*/}"
    if [ "$resourcekey" = "**" ] || case "$base" in *'*'* | *'?'*) true ;; *) false ;; esac; then
      broad=1
    fi
  done <<< "$keys"

  if [ "$broad" -eq 1 ]; then
    echo "too-broad"
  else
    echo "present"
  fi
}

# ---------------------------------------------------------------------------
# Inline NOSONAR S7637 marker on first-party caller stubs (#549)
#
# Canonical mechanism (supersedes the per-file sonar-project.properties approach):
# the inline `# NOSONAR(githubactions:S7637)` marker on the channel-pinned
# first-party reusable-ref `uses:` line travels WITH the caller-stub file, so
# adopters inherit the exemption on copy with zero per-repo properties entries.
#
# classify_inline_s7637_marker echoes exactly one verdict for a single workflow
# file's decoded content:
#   present — every channel-pinned first-party reusable-ref `uses:` line carries
#             the inline `NOSONAR(githubactions:S7637)` marker.
#   missing — at least one channel-pinned first-party reusable-ref line lacks the
#             marker; SonarCloud's githubactions:S7637 would fire on it.
#   n/a     — the file has no channel-pinned first-party reusable ref (it is
#             SHA-pinned — which already satisfies S7637 — or carries no
#             first-party reusable ref at all), so no inline marker is required.
# ---------------------------------------------------------------------------
classify_inline_s7637_marker() {
  local content="$1"

  # First-party reusable-workflow `uses:` lines (channel- or SHA-pinned).
  local uses_lines
  uses_lines=$(printf '%s\n' "$content" \
    | grep -E '^[[:space:]]*uses:[[:space:]]*petry-projects/\.github(-private)?/\.github/workflows/[^@[:space:]]+@' || true)

  if [ -z "$uses_lines" ]; then
    echo "n/a"
    return 0
  fi

  local line ref channel_seen=0 missing=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # The pinned ref is the token after the first '@', up to whitespace/comment.
    ref=$(printf '%s\n' "$line" | sed -E 's/^[^@]*@([^[:space:]#]+).*/\1/')
    # A 40-char hex SHA pin already satisfies S7637 — no inline marker needed.
    if printf '%s' "$ref" | grep -qE '^[0-9a-f]{40}$'; then
      continue
    fi
    channel_seen=1
    if ! printf '%s' "$line" | grep -qF 'NOSONAR(githubactions:S7637)'; then
      missing=1
    fi
  done <<< "$uses_lines"

  if [ "$channel_seen" -eq 0 ]; then
    echo "n/a"
  elif [ "$missing" -eq 1 ]; then
    echo "missing"
  else
    echo "present"
  fi
}

check_sonar_s7637_exemption() {
  local repo="$1"

  # Only relevant when the repo actually runs SonarCloud analysis.
  gh_api "repos/$ORG/$repo/contents/.github/workflows/sonarcloud.yml" --jq '.name' > /dev/null 2>&1 || return 0

  # Canonical (#549): scan the repo's caller-stub workflows for the inline
  # `# NOSONAR(githubactions:S7637)` marker. If every channel-pinned first-party
  # reusable-ref stub carries it, the repo is exempt with no per-file
  # sonar-project.properties entries needed.
  local workflows wf wf_content wf_decoded inline_verdict
  local inline_seen=0 inline_missing=0
  workflows=$(gh_api "repos/$ORG/$repo/contents/.github/workflows" --jq '.[].name' 2>/dev/null || echo "")
  for wf in $workflows; do
    case "$wf" in *.yml | *.yaml) ;; *) continue ;; esac
    wf_content=$(gh_api "repos/$ORG/$repo/contents/.github/workflows/$wf" --jq '.content' 2>/dev/null || echo "")
    [ -z "$wf_content" ] && continue
    wf_decoded=$(echo "$wf_content" | base64 -d 2>/dev/null || echo "")
    [ -z "$wf_decoded" ] && continue
    inline_verdict=$(classify_inline_s7637_marker "$wf_decoded")
    case "$inline_verdict" in
      present) inline_seen=1 ;;
      missing) inline_seen=1; inline_missing=1 ;;
    esac
  done

  # Every channel-pinned first-party stub carries the inline marker → exempt.
  if [ "$inline_seen" -eq 1 ] && [ "$inline_missing" -eq 0 ]; then
    return 0
  fi

  # Legacy per-file mechanism — accepted during the transition (#549). A repo
  # whose stubs are not yet inline-marked is still compliant if its
  # sonar-project.properties carries the narrow per-stub exemption.
  local content decoded
  content=$(gh_api "repos/$ORG/$repo/contents/sonar-project.properties" --jq '.content' 2>/dev/null || echo "")
  if [ -z "$content" ]; then
    # No properties file. Flag only when a stub needs but lacks the inline marker
    # (a missing properties file itself is reported by check_sonarcloud).
    if [ "$inline_missing" -eq 1 ]; then
      add_finding "$repo" "ci-workflows" "sonar-s7637-exemption-missing" "warning" \
        "First-party caller stub(s) carry a channel-pinned reusable ref (\`@<name>/stable\`, \`@v1\`/\`@v2\`) without the inline \`# NOSONAR(githubactions:S7637)\` marker, and there is no legacy \`sonar-project.properties\` exemption. SonarCloud will flag them as unpinned actions even though the org exempts them from SHA-pinning. Add the inline marker to each channel-pinned first-party \`uses:\` line (canonical), or the legacy per-stub \`sonar.issue.ignore\` entry." \
        "standards/ci-standards.md#sonarcloud-exemption-first-party-reusable-ref-s7637"
    fi
    return 0
  fi
  decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")
  [ -z "$decoded" ] && return 0

  local verdict
  verdict=$(classify_sonar_s7637_exemption "$decoded")

  case "$verdict" in
    missing)
      # Only a real gap when a channel-pinned first-party stub actually lacks the
      # inline marker; with no such stub there is nothing for S7637 to fire on.
      if [ "$inline_missing" -eq 1 ]; then
        add_finding "$repo" "ci-workflows" "sonar-s7637-exemption-missing" "warning" \
          "No \`githubactions:S7637\` exemption found. SonarCloud will flag first-party reusable-ref caller stubs (\`@<name>/stable\`, \`@v1\`/\`@v2\`) as unpinned actions even though the org exempts them from SHA-pinning. Add the inline \`# NOSONAR(githubactions:S7637)\` marker to each channel-pinned first-party \`uses:\` line (canonical), or the legacy per-stub \`sonar.issue.ignore\` exemption in \`sonar-project.properties\`." \
          "standards/ci-standards.md#sonarcloud-exemption-first-party-reusable-ref-s7637"
      fi
      ;;
    too-broad)
      add_finding "$repo" "ci-workflows" "sonar-s7637-exemption-too-broad" "error" \
        "\`sonar-project.properties\` suppresses \`githubactions:S7637\` with a blanket workflow-path \`resourceKey\` (e.g. \`workflows/*.yml\` or \`**\`). This also exempts third-party actions in \`ci.yml\`/\`sonarcloud.yml\` from SHA-pin enforcement. Scope the exemption to the individual caller-stub files instead, or migrate to the inline \`# NOSONAR(githubactions:S7637)\` marker." \
        "standards/ci-standards.md#sonarcloud-exemption-first-party-reusable-ref-s7637"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Check: CodeQL default setup is configured (and no stray codeql.yml exists)
#
# After petry-projects/.github#103, CodeQL is configured via GitHub's
# managed default setup, not a per-repo workflow file. Two distinct findings:
#
#   1. codeql-default-setup-not-configured (error): the repo has not enabled
#      default setup. Remediate by running:
#        gh api -X PATCH repos/<org>/<repo>/code-scanning/default-setup \
#          -F state=configured -F query_suite=default
#      (or by running scripts/apply-repo-settings.sh against the repo).
#
#   2. stray-codeql-workflow (error): the repo still ships a codeql.yml
#      workflow file. Default setup and an inline workflow are mutually
#      exclusive at the GitHub level — leaving the file behind double-bills
#      CI minutes and creates two competing analyses. Remediation: delete
#      .github/workflows/codeql.yml.
# ---------------------------------------------------------------------------
check_codeql_default_setup() {
  local repo="$1"

  # Query the default-setup state.
  # IMPORTANT: Do NOT use the gh_api() retry wrapper here. When gh api gets a
  # 403 it outputs the error JSON body to stdout before exiting non-zero. The
  # retry wrapper loops 3 times without suppressing stdout, so the captured
  # output ends up as 3 concatenated error bodies — indistinguishable from a
  # real "not-configured" state and causing persistent false-positive findings.
  # We capture the response body and exit code separately so we can detect a
  # 403 permission error and skip without filing a spurious finding.
  local raw_response=""
  local api_ok=0
  raw_response=$(gh api "repos/$ORG/$repo/code-scanning/default-setup" 2>/dev/null) || api_ok=$?

  if [ "$api_ok" -ne 0 ]; then
    # Distinguish a 403 permission error from other failures (404, 500, …).
    # The gh api error body contains `"status": "403"` (a JSON string) for
    # "Resource not accessible by personal access token" responses.
    if echo "$raw_response" | jq -e '.status == "403"' > /dev/null 2>&1; then
      # ORG_SCORECARD_TOKEN lacks the security_events scope required by this
      # endpoint. We cannot determine the CodeQL default-setup state, so we
      # skip without adding a finding — a 403 from the audit token must not be
      # misreported as "not configured". To verify state manually run:
      #   gh api repos/$ORG/$repo/code-scanning/default-setup
      # with a token that carries security_events (or repo-admin) scope.
      info "  CodeQL default setup check skipped for $repo — audit token lacks required permissions (403)"
    else
      add_finding "$repo" "ci-workflows" "codeql-default-setup-not-configured" "error" \
        "CodeQL default setup query returned no state — either the repo has code scanning disabled or the API call failed. Enable via \`gh api -X PATCH repos/$ORG/$repo/code-scanning/default-setup -F state=configured -F query_suite=default\`." \
        "standards/ci-standards.md#2-codeql-analysis-github-managed-default-setup"
    fi
  else
    local state
    state=$(echo "$raw_response" | jq -r '.state // ""')
    if [ "$state" != "configured" ]; then
      add_finding "$repo" "ci-workflows" "codeql-default-setup-not-configured" "error" \
        "CodeQL default setup is in state \`$state\` (expected \`configured\`). Run \`apply-repo-settings.sh $repo\` or \`gh api -X PATCH repos/$ORG/$repo/code-scanning/default-setup -F state=configured -F query_suite=default\`." \
        "standards/ci-standards.md#2-codeql-analysis-github-managed-default-setup"
    fi
  fi

  # Stray workflow check: any codeql.yml under .github/workflows is drift.
  if gh_api "repos/$ORG/$repo/contents/.github/workflows/codeql.yml" --jq '.name' > /dev/null 2>&1; then
    add_finding "$repo" "ci-workflows" "stray-codeql-workflow" "error" \
      "Repo still ships \`.github/workflows/codeql.yml\`. The org standard now uses GitHub-managed CodeQL default setup; per-repo workflow files are drift and run a duplicate analysis alongside default setup. Delete the file. If a documented exception applies (custom query pack, build mode, path filters), open a standards PR against \`standards/ci-standards.md\` to record the exception before re-adding the workflow." \
      "standards/ci-standards.md#2-codeql-analysis-github-managed-default-setup"
  fi
}

# ---------------------------------------------------------------------------
# Check: Workflow permissions follow least-privilege
# ---------------------------------------------------------------------------
check_workflow_permissions() {
  local repo="$1"

  local workflows
  workflows=$(gh_api "repos/$ORG/$repo/contents/.github/workflows" --jq '.[].name' 2>/dev/null || echo "")

  for wf in $workflows; do
    [[ "$wf" != *.yml && "$wf" != *.yaml ]] && continue

    local content
    content=$(gh_api "repos/$ORG/$repo/contents/.github/workflows/$wf" --jq '.content' 2>/dev/null || echo "")
    [ -z "$content" ] && continue

    local decoded
    decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")
    [ -z "$decoded" ] && continue

    # Skip reusable workflows (workflow_call-only triggers).
    # Their permissions are controlled entirely by the caller workflow, so
    # requiring a top-level permissions: block here would be redundant and
    # would generate false positives for every *-reusable.yml in the org.
    # All reusable workflows follow the -reusable.yml naming convention.
    if [[ "$wf" == *-reusable.yml || "$wf" == *-reusable.yaml ]]; then
      continue
    fi

    # Check if the workflow has a top-level permissions key
    # Single-job workflows may define permissions at job level instead
    if ! echo "$decoded" | grep -qE '^permissions:'; then
      # Count jobs and check if the single job has job-level permissions
      local job_count
      job_count=$(echo "$decoded" | grep -cE '^  [a-zA-Z_-]+:$' || echo "0")
      local has_job_perms
      has_job_perms=$(echo "$decoded" | grep -cE '^    permissions:' || echo "0")
      if [ "$job_count" -gt 1 ] || [ "$has_job_perms" -eq 0 ]; then
        add_finding "$repo" "ci-workflows" "missing-permissions-$wf" "warning" \
          "Workflow \`$wf\` missing top-level \`permissions:\` declaration (least-privilege policy)" \
          "standards/ci-standards.md#permissions-policy"
      fi
    fi
  done
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Check: ci.yml uses SHA-scoped concurrency group
#
# Per-ref concurrency groups (`ci-${{ github.ref }}`) with cancel-in-progress
# can leave the HEAD commit without CI results when a rapid push arrives while
# the previous cancellation is in flight. The standard requires the group to
# include github.sha so every commit gets its own slot.
#
# See standards/ci-standards.md#1-ci-pipeline-ciyml for the rationale.
# ---------------------------------------------------------------------------
check_ci_concurrency() {
  local repo="$1"

  local content
  content=$(gh_api "repos/$ORG/$repo/contents/.github/workflows/ci.yml" --jq '.content' 2>/dev/null || echo "")
  [ -z "$content" ] && return  # missing ci.yml is caught by check_required_workflows

  local decoded
  decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")
  [ -z "$decoded" ] && return

  # Only flag workflows that have a concurrency block but are missing github.sha.
  # Workflows with no concurrency block at all are not flagged here (they may be
  # intentionally unbounded for reasons outside this check's scope).
  if echo "$decoded" | grep -qE '^concurrency:'; then
    if ! echo "$decoded" | grep -qE 'group:.*github\.sha'; then
      add_finding "$repo" "ci-workflows" "ci-concurrency-missing-sha" "warning" \
        "The \`ci.yml\` concurrency group does not include \`github.sha\`. A per-ref group with \`cancel-in-progress: true\` can leave the HEAD commit with no CI results when pushes arrive in quick succession. Update to: \`group: ci-\${{ github.ref }}-\${{ github.sha }}\`." \
        "standards/ci-standards.md#1-ci-pipeline-ciyml"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Check: Tier 1 centralized workflows must be thin caller stubs pinned to the
# canonical version tag for their reusable.
#
# For each workflow that the org has centralized into a reusable workflow,
# verify the downstream repo's copy is a stub that delegates via:
#   uses: petry-projects/.github/.github/workflows/<reusable>.yml@<version>
#
# This prevents drift: a repo that copies the inline pre-centralization
# version (or pins to @main, or pins to a non-canonical tag) is flagged so
# it can be re-synced from the standard. The central .github repo itself is
# exempt because it owns the reusables and may legitimately reference
# its own workflows by @main during release prep.
#
# Array format: "workflow-filename:reusable-basename:canonical-pin:legacy-csv"
# ---------------------------------------------------------------------------

# stub_pin_acceptable <decoded> <reusable-basename> <canonical-ref> <legacy-csv>
# True if a non-comment `uses:` line pins petry-projects/.github's <reusable> at
# the canonical ref OR one of the comma-separated transitional legacy refs. The
# legacy grace keeps a stub on its old @vN pin compliant while the fleet migrates
# to the <name>/stable channel, so the audit neither flags nor reverts it
# mid-migration (#482). Anchored to start-of-line so a `# uses: …` comment never
# counts.
stub_pin_acceptable() {
  local decoded="$1" reusable="$2" canonical="$3" legacy_csv="$4"
  local esc_reusable; esc_reusable=$(escape_ere "$reusable")

  local -a legacy_arr=()
  [ -n "$legacy_csv" ] && IFS=',' read -r -a legacy_arr <<< "$legacy_csv"

  local alt="" r
  for r in "$canonical" "${legacy_arr[@]}"; do
    [ -z "$r" ] && continue
    alt+="${alt:+|}$(escape_ere "$r")"
  done

  local expected="petry-projects/\\.github/\\.github/workflows/${esc_reusable}\\.yml@(${alt})"
  printf '%s\n' "$decoded" | grep -qE "^[[:space:]]*uses:[[:space:]]*${expected}([[:space:]]|$)"
}

# ring_major_form_acceptable <decoded> <reusable-basename> <channel-base> <repo>
# True if a non-comment `uses:` line pins petry-projects/.github's <reusable> at
# the MAJOR-SCOPED channel form `<channel-base>/v<M>-<tier-for-repo>` for any
# major M, where the tier matches <repo>'s ring tier (major-scoped-channels epic
# #657, Phase F3). This is a backward-compatible ADD alongside stub_pin_acceptable's
# bare-tier grace: it teaches the audit to also accept the `v<M>-` form the fleet
# migrates onto in F5, without yet requiring it. A v-form pinned to the WRONG
# tier (e.g. `…/v1-ring0` on a stable-tier repo) is NOT accepted here and falls
# through to the drift finding. Anchored to start-of-line so a `# uses: …` comment
# never counts. Pure — extracts the pinned ref, reads its major with
# ring_pinned_major(), and checks it against ring_canonical_ref(…, major).
ring_major_form_acceptable() {
  local decoded="$1" reusable="$2" chan="$3" repo="$4"
  local esc_reusable; esc_reusable=$(escape_ere "$reusable")

  local pinned_ref
  pinned_ref=$(printf '%s\n' "$decoded" \
    | sed -nE "s#^[[:space:]]*uses:[[:space:]]*petry-projects/\\.github/\\.github/workflows/${esc_reusable}\\.yml@([^[:space:]]+).*#\\1#p" \
    | head -n1)
  [ -n "$pinned_ref" ] || return 1

  local pinned_major; pinned_major=$(ring_pinned_major "$pinned_ref")
  [ -n "$pinned_major" ] || return 1

  [ "$pinned_ref" = "$(ring_canonical_ref "$chan" "$repo" "$pinned_major")" ]
}

# ring_tier_for_repo(), ring_canonical_ref() and ring_legacy_csv() are provided by
# lib/ring-pins.sh (sourced above) — the single source of truth shared with the
# deploy sweep so the audit and the deploy never disagree on a stub's pin (#482).

check_centralized_workflow_stubs() {
  local repo="$1"

  # The .github repo is the source of truth and is allowed to reference its
  # own reusables by @main; skip the stub check for it.
  [ "$repo" = ".github" ] && return

  # workflow-filename:reusable-basename:canonical-pin:legacy-accepted-csv
  #   canonical-pin       — the org-standard ref a stub should pin. The sentinel
  #                         `RING` means "this reusable is on the canary-ring
  #                         model": the expected channel is the repo's RING TIER
  #                         (next/ring0/ring1/stable — see ring_tier_for_repo),
  #                         e.g. `agent-shield/ring1` on a ring1 repo. Any other
  #                         value would be a fixed pin (e.g. `foo → v1`); every
  #                         reusable below is now on the ring model (#606).
  #   legacy-accepted-csv — additional refs still accepted *during* migration so
  #                         the audit neither flags nor reverts a stub mid-move.
  #                         For RING reusables the per-repo legacy set (the other
  #                         ring channels — higher tiers) is computed below.
  # NOTE: dev-lead.yml is intentionally NOT listed here — its reusable lives in
  # the private petry-projects/.github-private repo and is pinned to the
  # dev-lead/stable channel, validated by check_dev_lead_stub() below.
  local centralized=(
    "auto-rebase.yml:auto-rebase-reusable:RING"
    "dependency-audit.yml:dependency-audit-reusable:RING"
    "dependabot-automerge.yml:dependabot-automerge-reusable:RING"
    "dependabot-rebase.yml:dependabot-rebase-reusable:RING"
    "agent-shield.yml:agent-shield-reusable:RING"
    "feature-ideation.yml:feature-ideation-reusable:RING"
    "pr-review-mention.yml:pr-review-mention-reusable:RING"
    "pr-auto-review.yml:pr-auto-review-reusable:RING"
  )

  # List the repo's workflow directory once instead of probing each file.
  # If the listing fails (no workflows dir), there's nothing to check.
  local workflow_list
  workflow_list=$(gh_api "repos/$ORG/$repo/contents/.github/workflows" --jq '.[].name' 2>/dev/null || echo "")
  [ -z "$workflow_list" ] && return

  local entry wf reusable canonical legacy chan is_ring
  for entry in "${centralized[@]}"; do
    IFS=':' read -r wf reusable canonical legacy <<< "$entry"
    [ -z "$canonical" ] && { echo "::error::centralized entry '$entry' missing canonical pin — expected format 'wf:reusable:canonical:legacy-csv'" >&2; exit 1; }
    is_ring=0
    chan=""

    # RING sentinel: this reusable is on the canary-ring model. The canonical
    # ref is the channel for THIS repo's ring tier (next/ring0/ring1/stable),
    # and the per-repo legacy grace accepts the `<name>/stable` channel plus the
    # pre-ring @v1/@v2 pins so the audit neither flags nor reverts a stub while
    # the fleet migrates onto the rings (#870, same revert-collision lesson as
    # #482). Higher tiers are also acceptable so a repo pinned ahead of its tier
    # (e.g. a ring1 repo still on /stable, or .github-private's /next promoted to
    # /stable) is never flagged — only @main / inline / off-channel pins are.
    if [ "$canonical" = "RING" ]; then
      is_ring=1
      chan="${reusable%-reusable}"
      canonical="$(ring_canonical_ref "$chan" "$repo")"
      legacy="$(ring_legacy_csv "$chan" "$repo")"
    fi

    # Skip workflows that don't exist in this repo. Required workflows are
    # checked separately by check_required_workflows; conditional ones
    # (dependabot-rebase, feature-ideation) are intentionally optional.
    if ! echo "$workflow_list" | grep -qxF "$wf"; then
      continue
    fi

    local content
    content=$(gh_api "repos/$ORG/$repo/contents/.github/workflows/$wf" --jq '.content' 2>/dev/null || echo "")
    [ -z "$content" ] && continue

    local decoded
    decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")
    [ -z "$decoded" ] && continue

    # Compliance rule (major-scoped-channels epic #657 F5, #861):
    #   RING reusables MUST pin the major-scoped `<name>/v<M>-<tier>` form — any
    #     major M whose tier matches the repo (ring_major_form_acceptable). A bare
    #     `<name>/<tier>` pin is now drift: the fleet has migrated onto the v-form,
    #     so the bare grace (stub_pin_acceptable) no longer applies to the rings.
    #   Non-RING reusables (fixed-pin entries) keep the exact/legacy match via
    #     stub_pin_acceptable.
    # Both helpers anchor to start-of-line so a `# uses: …` comment never counts;
    # a v-form pinned to the WRONG tier stays drift.
    if { [ "$is_ring" = 1 ] && ring_major_form_acceptable "$decoded" "$reusable" "$chan" "$repo"; } \
      || { [ "$is_ring" != 1 ] && stub_pin_acceptable "$decoded" "$reusable" "$canonical" "$legacy"; }; then
      continue
    fi

    # Determine why it's non-compliant for a more actionable message. For RING
    # reusables the expected pin is the major-scoped v-form `<name>/v<M>-<tier>`
    # (major-agnostic on tier, #657 F5); non-ring keeps the fixed canonical ref.
    local esc_reusable why expected_pin="$canonical"
    esc_reusable=$(escape_ere "$reusable")
    [ "$is_ring" = 1 ] && expected_pin="${chan}/v<M>-$(ring_tier_for_repo "$chan" "$repo")"
    if echo "$decoded" | grep -qE "^[[:space:]]*uses:[[:space:]]*petry-projects/\\.github/\\.github/workflows/${esc_reusable}\\.yml@"; then
      why="references the reusable but is not pinned to the major-scoped channel \`@${expected_pin}\` (org standard — a bare \`@${canonical}\` tier pin is drift)"
    elif echo "$decoded" | grep -qF "petry-projects/.github/.github/workflows/${reusable}"; then
      why="references the reusable but the \`uses:\` line does not match the canonical stub"
    else
      why="is an inline copy instead of a thin caller stub — re-sync from \`standards/workflows/${wf}\`"
    fi

    add_finding "$repo" "ci-workflows" "non-stub-$wf" "error" \
      "Centralized workflow \`$wf\` $why. Replace with the canonical stub from \`standards/workflows/${wf}\` which delegates to \`petry-projects/.github/.github/workflows/${reusable}.yml@${expected_pin}\`." \
      "standards/ci-standards.md#centralization-tiers"
  done
}

# ---------------------------------------------------------------------------
# Check: dev-lead.yml caller stub conforms to the centralized contract
#
# Unlike the other reusables, dev-lead lives in the PRIVATE repo and is pinned
# to the moving `dev-lead/stable` channel tag (not @main, not a frozen @vN — see
# standards/ci-standards.md#dev-lead-agent for the self-host channel model), and
# its concurrency + permissions are owned centrally. A stub drifts — and breaks —
# in three ways this check catches (all root causes of petry-projects/.github#402):
#
#   1. Wrong pin: not petry-projects/.github-private/.../dev-lead-reusable.yml@dev-lead/stable.
#   2. Local concurrency block: per-stub concurrency drifts and cancels issue
#      pickups; concurrency is owned by the reusable (per-issue/per-PR lanes).
#   3. Missing `statuses: read`: the reusable requests it since #435, so without
#      it every run fails at startup (startup_failure) with no runtime error.
# ---------------------------------------------------------------------------
check_dev_lead_stub() {
  local repo="$1"

  # .github holds the template (exercised by the reusable's own CI) and
  # .github-private runs the workflow inline rather than as a caller stub.
  [ "$repo" = ".github" ] && return
  [ "$repo" = ".github-private" ] && return

  local content decoded
  content=$(gh_api "repos/$ORG/$repo/contents/.github/workflows/dev-lead.yml" --jq '.content' 2>/dev/null || echo "")
  [ -z "$content" ] && return  # repo hasn't adopted dev-lead — nothing to check
  decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")
  [ -z "$decoded" ] && return

  # 1) Canonical pin (non-comment `uses:` line) — a moving dev-lead channel tag
  #    (self-host channel model). The production default is `stable`; the staged
  #    canary model (versioning.md Phase 2, #499/#500) also permits the candidate
  #    channel `next` and per-ring channels `ring0`, `ring1`, … A frozen `@vX.Y.Z`
  #    or `@<sha>` is NOT a channel and is intentionally rejected — callers pin the
  #    moving channel so rollout/rollback is a single central tag move.
  #    Major-scoped channels (#657 F5, #861): the channel MUST carry the `v<M>-`
  #    major prefix — a bare `dev-lead/stable` is now drift; only `dev-lead/v<M>-<tier>`
  #    (any major) is accepted, mirroring the RING reusables above.
  if ! printf '%s\n' "$decoded" | grep -qE "^[[:space:]]*uses:[[:space:]]*petry-projects/\\.github-private/\\.github/workflows/dev-lead-reusable\\.yml@dev-lead/v[0-9]+-(stable|next|ring[0-9]+)([[:space:]]|$)"; then
    add_finding "$repo" "ci-workflows" "dev-lead-stub-pin" "error" \
      "The \`dev-lead.yml\` caller stub must pin a major-scoped \`dev-lead\` channel tag — \`petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v<M>-<channel>\` where <channel> is \`stable\` (default), \`next\`, or \`ring<N>\` (a bare \`dev-lead/<channel>\` tier pin is drift). Re-sync from \`standards/workflows/dev-lead.yml\`." \
      "standards/ci-standards.md#dev-lead-agent"
  fi

  # 2) agent_ref must be threaded through to pin the same channel inside the
  #    reusable's own script/prompt checkout (prevents split-brain on promotion).
  #    Same major-scoped channel form as the uses: pin above; must match the uses:
  #    channel exactly — including its major, so a `v3-stable` uses pin with a
  #    `v2-stable` agent_ref is caught.
  uses_channel=$(printf '%s\n' "$decoded" | sed -nE 's#^[[:space:]]*uses:[[:space:]]*petry-projects/\.github-private/\.github/workflows/dev-lead-reusable\.yml@dev-lead/(v[0-9]+-(stable|next|ring[0-9]+))([[:space:]]|$).*#\1#p')
  if [ -n "$uses_channel" ]; then
    if ! printf '%s\n' "$decoded" | grep -qE "^[[:space:]]*agent_ref:[[:space:]]*dev-lead/$uses_channel([[:space:]]|$)"; then
      add_finding "$repo" "ci-workflows" "dev-lead-stub-agent-ref" "error" \
        "The \`dev-lead.yml\` caller stub must pass \`with: agent_ref: dev-lead/$uses_channel\` to match the pinned channel \`$uses_channel\`. Re-sync from \`standards/workflows/dev-lead.yml\`." \
        "standards/ci-standards.md#dev-lead-agent"
    fi
  else
    if ! printf '%s\n' "$decoded" | grep -qE "^[[:space:]]*agent_ref:[[:space:]]*dev-lead/v[0-9]+-(stable|next|ring[0-9]+)([[:space:]]|$)"; then
      add_finding "$repo" "ci-workflows" "dev-lead-stub-agent-ref" "error" \
        "The \`dev-lead.yml\` caller stub must pass \`with: agent_ref: dev-lead/v<M>-<channel>\` (\`stable\`, \`next\`, or \`ring<N>\`) so the reusable checks out its own scripts/prompts from the same major-scoped channel. Re-sync from \`standards/workflows/dev-lead.yml\`." \
        "standards/ci-standards.md#dev-lead-agent"
    fi
  fi

  # 3) No per-stub concurrency block — concurrency is owned by the reusable.
  if echo "$decoded" | grep -qE "^concurrency:"; then
    add_finding "$repo" "ci-workflows" "dev-lead-stub-concurrency" "warning" \
      "The \`dev-lead.yml\` stub defines its own \`concurrency:\` block. Concurrency is centralized in the reusable (per-issue/per-PR lanes); a per-stub block drifts and can cancel issue pickups. Remove it — see petry-projects/.github#402." \
      "standards/ci-standards.md#dev-lead-agent"
  fi

  # 4) Caller permissions must grant `statuses: read`.
  if ! echo "$decoded" | grep -qE "^[[:space:]]*statuses:[[:space:]]*read([[:space:]]|$)"; then
    add_finding "$repo" "ci-workflows" "dev-lead-stub-statuses-perm" "error" \
      "The \`dev-lead.yml\` stub is missing \`statuses: read\` in \`jobs.dev-lead.permissions\`. The reusable requests it (since #435), so without it every run fails at startup (\`startup_failure\`). Add \`statuses: read\`." \
      "standards/ci-standards.md#dev-lead-agent"
  fi
}

# ---------------------------------------------------------------------------
# Caller-stub surface-drift guard (#607)
#
# The centralized caller stubs (dev-lead + the RING reusables) are thin: their
# behavior lives in the reusable, so three surfaces are NOT repo-adjustable — the
# `on:` trigger set, the `permissions:` grants, and the (usually absent)
# `concurrency:` block. The field-allowlist pin checks above (stub_pin_acceptable,
# check_dev_lead_stub) validate the channel pin / agent_ref but never look at
# those surfaces, so a stub that trims a trigger, widens/narrows a permission, or
# injects a per-stub concurrency group drifts SILENTLY (root cause of #607).
#
# These surfaces carry NO channel pin — the tier pin lives only on the
# jobs.<id>.uses / agent_ref lines. So the comparison is tier-invariant by
# construction: a stub that differs from the canonical ONLY by its correct tier
# channel pin has identical surfaces and is never flagged. This is the "explicit
# sub-checks" branch of #607 (vs a full-file byte guard, which would false-positive
# on the per-repo `with:` liberties agent-shield / feature-ideation document, and
# on feature-ideation's documented per-repo cron retune).
#
# The helpers below are PURE (args in, stdout out) and unit-tested by
# test/scripts/compliance-audit/stub-surface-drift.bats.
# ---------------------------------------------------------------------------

# stub_extract_blocks <content> <key> — print every YAML block whose key line, at
# ANY indentation, is `<indent><key>:`, including all lines indented deeper than
# the key line (the block body). A key can appear more than once (e.g. dev-lead's
# top-level `permissions: {}` plus its job-level `permissions:`), so all matches
# are concatenated in file order. Comment/blank lines inside a body are kept and
# stripped later by stub_normalize_surface; a `# concurrency:` comment never
# starts a block (the key must be the first non-space token).
stub_extract_blocks() {
  local content="$1" key="$2"
  printf '%s\n' "$content" | awk -v key="$key" '
    function indent(s,   n) { n = match(s, /[^ ]/); return n == 0 ? 0 : n - 1 }
    {
      if (capturing) {
        if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) { print; next }
        if (indent($0) > keyindent) { print; next }
        capturing = 0
      }
      if ($0 ~ ("^[[:space:]]*" key ":")) {
        capturing = 1; keyindent = indent($0); print; next
      }
    }
  '
}

# stub_normalize_surface — read a surface block on stdin and canonicalize it for
# comparison: strip trailing ` #…` inline comments and whole-line comments, drop
# blank lines, and collapse two documented per-repo VALUES to placeholders:
#   • schedule cron VALUES — a repo MAY retune the cron without it counting as
#     trigger-surface drift (see feature-ideation.yml's header).
#   • pr-auto-review's `workflow_run.workflows:` list VALUE — a repo MUST name
#     its own CI workflow(s) here (see pr-auto-review.yml's header + TODO), so
#     the list value is not repo-locked while the `workflow_run` trigger key and
#     the rest of the `on:` surface stay verbatim-compared (#990). Both YAML list
#     forms are honored: the inline flow sequence `workflows: [ … ]` and the
#     block sequence (`workflows:` followed by deeper-indented `- …` entries) both
#     collapse to the same `workflows: WORKFLOWS` placeholder. Non-list shapes
#     (`null`, a bare scalar, or an empty list with no entries) are left intact so
#     they still count as drift.
# `workflows:` is a key only under `workflow_run`, which appears in no other
# guarded surface, so the collapse is safe to apply unconditionally. Pure:
# stdin -> stdout.
stub_normalize_surface() {
  tr -d '\r' \
    | sed -E \
        -e 's/[[:space:]]+#.*$//' \
        -e 's/^[[:space:]]*#.*$//' \
        -e 's/(- cron:[[:space:]]*).*/\1CRON/' \
    | awk '
        function flush() {
          if (pending) { if (saw_item) printf "%sworkflows: WORKFLOWS\n", ind; else print saved; pending = 0 }
        }
        function indent(s,   n) { n = match(s, /[^ ]/); return n == 0 ? 0 : n - 1 }
        {
          if (pending) {
            if ($0 ~ /^[[:space:]]*$/) { next }
            # collapse a block sequence: deeper-indented "- …" entries belong to
            # the deferred workflows: line; anything else ends the block.
            if (indent($0) > wfindent && $0 ~ /^[[:space:]]*-[[:space:]]+/) {
              saw_item = 1; next
            }
            flush()
          }
          if ($0 ~ /^[[:space:]]*workflows:[[:space:]]*/) {
            val = $0; sub(/^[[:space:]]*workflows:[[:space:]]*/, "", val)
            wfindent = indent($0); ind = substr($0, 1, wfindent)
            if (val ~ /^\[/ && val !~ /^\[[[:space:]]*\]/) { printf "%sworkflows: WORKFLOWS\n", ind; next }
            if (val == "")  { pending = 1; saw_item = 0; saved = $0; next }
            print; next          # null / bare scalar — leave intact (drift)
          }
          print
        }
        END { flush() }
      ' \
    | grep -vE '^[[:space:]]*$' || true
}

# stub_surface_drift <canonical> <deployed> <key> — return 0 (success) when the
# given surface has DRIFTED between the canonical template and the deployed stub,
# 1 when it is clean. Success-means-drift so `if stub_surface_drift …; then
# add_finding …; fi` reads naturally.
stub_surface_drift() {
  local canonical="$1" deployed="$2" key="$3" c d
  c="$(stub_extract_blocks "$canonical" "$key" | stub_normalize_surface)"
  d="$(stub_extract_blocks "$deployed" "$key" | stub_normalize_surface)"
  [ "$c" = "$d" ] && return 1 || return 0
}

# ---------------------------------------------------------------------------
# Check: caller-stub on:/permissions/concurrency surfaces match the canonical
#
# For each enrolled shim, compares the deployed stub's guarded surfaces against
# the on-disk canonical in standards/workflows/. dev-lead's `permissions`
# (statuses: read) and `concurrency` surfaces already have dedicated, higher-signal
# checks in check_dev_lead_stub() (specific #402 / startup_failure remediation), so
# this check owns dev-lead's previously-unguarded `on:` surface only, plus all
# three surfaces for the RING shims (whose permissions/concurrency were unguarded).
# ---------------------------------------------------------------------------
check_stub_surface_drift() {
  local repo="$1"

  # .github is the source of truth for the templates; .github-private runs these
  # workflows inline rather than as caller stubs.
  [ "$repo" = ".github" ] && return 0
  [ "$repo" = ".github-private" ] && return 0

  # "workflow.yml:comma-separated-surfaces". Keep in lockstep with the RING list
  # in check_centralized_workflow_stubs() and RING_REUSABLES in lib/ring-pins.sh.
  local shims=(
    "dev-lead.yml:on"
    "agent-shield.yml:on,permissions,concurrency"
    "auto-rebase.yml:on,permissions,concurrency"
    "dependency-audit.yml:on,permissions,concurrency"
    "dependabot-automerge.yml:on,permissions,concurrency"
    "dependabot-rebase.yml:on,permissions,concurrency"
    "pr-review-mention.yml:on,permissions,concurrency"
    "feature-ideation.yml:on,permissions,concurrency"
    "pr-auto-review.yml:on,permissions,concurrency"
  )

  local entry wf surfaces template canonical content deployed surface severity
  local -a surface_list
  for entry in "${shims[@]}"; do
    IFS=':' read -r wf surfaces <<< "$entry"

    template="$STANDARDS_WF_DIR/$wf"
    if [ ! -f "$template" ]; then
      warn "No canonical template at $template — skipping surface-drift check for $wf"
      continue
    fi
    canonical="$(< "$template")"

    content=$(gh_api "repos/$ORG/$repo/contents/.github/workflows/$wf" --jq '.content' 2>/dev/null || echo "")
    [ -z "$content" ] && continue  # repo hasn't adopted this stub — nothing to check
    deployed=$(echo "$content" | base64 -d 2>/dev/null || echo "")
    [ -z "$deployed" ] && continue

    IFS=',' read -r -a surface_list <<< "$surfaces"
    for surface in "${surface_list[@]}"; do
      stub_surface_drift "$canonical" "$deployed" "$surface" || continue
      # An injected/removed concurrency block degrades but does not hard-break the
      # run (it can cancel lanes — #402); a trimmed trigger or altered permission
      # breaks functionality, so those are errors.
      severity="error"
      [ "$surface" = "concurrency" ] && severity="warning"
      add_finding "$repo" "ci-workflows" "stub-surface-drift-$wf-$surface" "$severity" \
        "The \`$wf\` caller stub's \`$surface:\` surface has drifted from the canonical \`standards/workflows/$wf\`. These stubs are thin callers — the \`on:\` triggers, \`permissions:\` grants, and \`concurrency:\` block are owned centrally and are not repo-adjustable (only the documented \`with:\` inputs and the tier channel pin may differ per repo). Re-sync \`$surface:\` from \`standards/workflows/$wf\`." \
        "standards/ci-standards.md#centralization-tiers"
    done
  done
}

# ---------------------------------------------------------------------------
# Check: required-status-check rulesets reference current names
#
# After centralizing workflows into reusables (#87, #88), GitHub composes
# check names as `<caller-job-id> / <reusable-job-id-or-name>`. Repos
# that updated their workflow files but didn't update their rulesets
# are silently broken — the merge gate references a name that no
# longer exists, so it can never be satisfied.
#
# Inspects both the new ruleset system and classic branch protection.
# Flags two distinct problems:
#   1. Stale pre-centralization name (e.g. `claude`, `AgentShield`)
#      → emit "stale-required-check-<old-name>"
#   2. `claude-code / claude` listed as required
#      → emit "required-claude-code-check-broken" because that check
#        is structurally incompatible with workflow-modifying PRs
#        (claude-code-action's app-token validation refuses to mint
#        a token whenever the PR diff includes any workflow file)
# ---------------------------------------------------------------------------
check_centralized_check_names() {
  local repo="$1"

  # The .github repo owns the reusables; its own ruleset is allowed to
  # reference whatever check names it likes.
  [ "$repo" = ".github" ] && return

  # Map from stale name → current canonical name. Used for the rename
  # remediation message. The remediation here is "rename in the
  # ruleset" because both the old and new names refer to a check that
  # CAN be required (it runs on PRs and reports a definitive result).
  #
  # NOTE: `claude` and `claude-issue` are deliberately NOT in this map.
  # The post-centralization equivalents are `claude-code / claude` and
  # `claude-code / claude-issue`, but those checks are themselves
  # incompatible with workflow-modifying PRs (claude-code-action's app
  # token validation refuses to mint a token for any PR whose diff
  # includes a workflow file, so the check fails on every workflow PR
  # and the merge gate becomes a deadlock). The remediation for the
  # `claude*` cases is therefore "remove from required checks", not
  # "rename" — handled below as a separate finding so the message
  # never recommends a name that creates a new deadlock.
  local renames=(
    "AgentShield:agent-shield / AgentShield"
    "Detect ecosystems:dependency-audit / Detect ecosystems"
  )

  # Patterns for required checks that are structurally broken and
  # should be removed (not renamed). Matched as either:
  #   - the bare legacy name ("claude" / "claude-issue"), or
  #   - any reusable-workflow check whose suffix is "/ claude" or
  #     "/ claude-issue", regardless of caller-job-id prefix
  #     (so a custom caller named e.g. "Claude Code / claude" is
  #     also caught, not just the canonical "claude-code / claude").
  #
  # The match is computed against each context line below.

  # Collect every required-status-check context from every source.
  # Sources: (1) every active ruleset, (2) classic branch protection.
  local contexts=""

  # Source 1: rulesets that apply to main
  local ruleset_contexts
  ruleset_contexts=$(gh_api "repos/$ORG/$repo/rules/branches/main" \
    --jq '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' 2>/dev/null || echo "")
  contexts+="$ruleset_contexts"$'\n'

  # Source 2: classic branch protection (may not exist)
  local classic_contexts
  classic_contexts=$(gh_api "repos/$ORG/$repo/branches/main/protection/required_status_checks" \
    --jq '.contexts[]' 2>/dev/null || echo "")
  contexts+="$classic_contexts"

  [ -z "$(echo "$contexts" | tr -d '[:space:]')" ] && return

  # Check 1: stale pre-centralization names that have a safe rename
  local entry old new
  for entry in "${renames[@]}"; do
    IFS=':' read -r old new <<< "$entry"
    if echo "$contexts" | grep -qxF "$old"; then
      add_finding "$repo" "rulesets" "stale-required-check-${old// /-}" "error" \
        "Required-status-check ruleset references the stale check name \`$old\`. After workflow centralization (petry-projects/.github#87) this check is published as \`$new\`. Update the ruleset (and any classic branch protection) to use the new name." \
        "standards/ci-standards.md#centralization-tiers"
    fi
  done

  # Check 2: claude-* checks (legacy or post-centralization) listed as
  # required. These cannot be made compliant by renaming because the
  # post-centralization name is itself broken — the only safe action
  # is to remove the check from required-status-checks entirely.
  #
  # We classify each context line by suffix so any caller-job-id prefix
  # is caught (e.g. "claude-code / claude", "Claude Code / claude",
  # "review-claude / claude" all match).
  local context match_type
  while IFS= read -r context; do
    [ -z "$context" ] && continue
    match_type=""
    case "$context" in
      "claude")              match_type="claude" ;;
      "claude-issue")        match_type="claude-issue" ;;
      *"/ claude")           match_type="claude" ;;
      *"/ claude-issue")     match_type="claude-issue" ;;
      *) continue ;;
    esac

    # Stable check id per match type so findings don't churn across
    # audit runs from variations in caller-job-id prefixes.
    local check_id
    if [ "$match_type" = "claude-issue" ]; then
      check_id="required-claude-issue-check-broken"
    else
      check_id="required-claude-check-broken"
    fi

    add_finding "$repo" "rulesets" "$check_id" "error" \
      "Required-status-check ruleset includes \`$context\`, which is incompatible with workflow-modifying PRs. claude-code-action's GitHub App refuses to mint an OAuth token for any PR whose diff includes a workflow file, so the check fails on every workflow PR and the merge gate becomes a deadlock. **Remove \`$context\` from required status checks** — do NOT rename it. The Claude review check still runs on normal PRs and surfaces feedback without being a merge gate. See the codified \`standards/rulesets/code-quality.json\` for the canonical required-checks list." \
      "standards/ci-standards.md#centralization-tiers"
  done <<< "$contexts"
}


# ---------------------------------------------------------------------------
# Check: CLAUDE.md exists and references AGENTS.md
# ---------------------------------------------------------------------------
check_claude_md() {
  local repo="$1"

  local content
  content=$(gh_api "repos/$ORG/$repo/contents/CLAUDE.md" --jq '.content' 2>/dev/null || echo "")

  if [ -z "$content" ]; then
    add_finding "$repo" "standards" "missing-claude-md" "error" \
      "Missing \`CLAUDE.md\` — every repo must have a CLAUDE.md that references AGENTS.md" \
      "AGENTS.md"
    return
  fi

  local decoded
  decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")

  if ! echo "$decoded" | grep -qi 'AGENTS\.md'; then
    add_finding "$repo" "standards" "claude-md-missing-agents-ref" "error" \
      "\`CLAUDE.md\` does not reference \`AGENTS.md\`" \
      "AGENTS.md"
  fi
}

# ---------------------------------------------------------------------------
# Check: AGENTS.md exists and references org .github/AGENTS.md
# ---------------------------------------------------------------------------
# agents_md_lint_scope_for_repo <repo> — which structural rule scope to lint
# under. The canonical file (this .github repo's own AGENTS.md) is exempt from
# downstream-only rules (org-repo-import-consistency, which requires a back-link
# to itself); every other repo is a downstream consumer and gets the full rule
# set. Pure.
agents_md_lint_scope_for_repo() {
  local repo="$1"
  if [ "$repo" = ".github" ]; then
    printf 'canonical'
  else
    printf 'downstream'
  fi
}

# record_agents_md_structural_findings <repo> <decoded_content> — run the
# structural linter (amdl_lint, from scripts/agents-md-lint.sh) over an AGENTS.md
# whose contents were already fetched + base64-decoded, and append its findings
# to the INFORMATIONAL structural accumulator as
# "<repo>\t<severity>\t<rule_id>\t<line>\t<message>". A no-op on empty content,
# so the linter runs only when the file actually exists (a 404 stays on the
# missing-agents-md presence path). These findings never enter FINDINGS_FILE, so
# they open no issues, never join the umbrella, and never fail the run — Phase 3
# ships structural validation informational-only (docs/initiatives/agents-md-validation.md).
record_agents_md_structural_findings() {
  local repo="$1" decoded="$2"
  [ -n "$decoded" ] || return 0

  local scope tmp
  scope="$(agents_md_lint_scope_for_repo "$repo")"
  tmp="$(mktemp)"
  printf '%s' "$decoded" > "$tmp"
  # Capture the linter's OWN exit status (PIPESTATUS[0], not the pipeline's). A
  # non-zero amdl_lint means it did NOT complete (e.g. an invalid/unreadable rule
  # set) — the old `2>/dev/null | … || true` swallowed that, leaving the
  # accumulator empty so the cycle read as a clean zero-finding cycle. Record the
  # failure so append_structural_findings_summary marks the cycle INDETERMINATE,
  # never clean (issue #647, AC #1).
  local lint_rc=0
  amdl_lint "$tmp" "$AMDL_DEFAULT_RULES" "$scope" 2>/dev/null \
    | awk -v repo="$repo" -F'\t' 'BEGIN {OFS=FS} $2 != "" {print repo, $0}' \
    >> "$STRUCTURAL_FINDINGS_FILE" || lint_rc="${PIPESTATUS[0]}"
  if [ "$lint_rc" -ne 0 ]; then
    printf '%s\tamdl_lint exited %s\n' "$repo" "$lint_rc" >> "$STRUCTURAL_LINT_ERROR_FILE"
  fi
  rm -f "$tmp"
  return 0
}

check_agents_md() {
  local repo="$1"

  local content
  content=$(gh_api "repos/$ORG/$repo/contents/AGENTS.md" --jq '.content' 2>/dev/null || echo "")

  if [ -z "$content" ]; then
    add_finding "$repo" "standards" "missing-agents-md" "error" \
      "Missing \`AGENTS.md\` — every repo must have an AGENTS.md that references the org-level standards" \
      "AGENTS.md"
    return
  fi

  local decoded
  decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")

  # For repos other than .github, AGENTS.md should reference the org-level .github/AGENTS.md
  if [ "$repo" != ".github" ]; then
    # Accept two forms of reference:
    #   1. Any path containing .github/AGENTS.md (relative link text or path reference)
    #   2. GitHub blob URL format: /petry-projects/.github/blob/<ref>/AGENTS.md (in href)
    # Both are treated as references to the org-level standards file.
    if ! echo "$decoded" | grep -qE '(\.github/AGENTS\.md|petry-projects/\.github/blob/.+/AGENTS\.md)'; then
      add_finding "$repo" "standards" "agents-md-missing-org-ref" "error" \
        "\`AGENTS.md\` does not reference the org-level \`.github/AGENTS.md\` standards" \
        "AGENTS.md"
    fi
  fi

  # Phase 3 (#645): run the structural linter over the fetched file, INFORMATIONAL
  # and non-blocking. Runs only when content is present (the 404 path returned
  # above), so the presence check does not regress. This also covers the
  # cross-repo import-consistency rule (org-repo-import-consistency) under the
  # downstream scope for non-.github repos.
  record_agents_md_structural_findings "$repo" "$decoded"
}

# ---------------------------------------------------------------------------
# Check: copilot-setup-steps.yml exists
# ---------------------------------------------------------------------------
# Every repo should have a copilot-setup-steps.yml to pre-install tools and
# dependencies in the Copilot cloud agent environment before it starts work.
# Without it the agent discovers dependencies via trial and error, which is
# slow, non-deterministic, and impossible for repos with private packages.
# See standards/ci-standards.md §11 Copilot Cloud Agent Setup.
# ---------------------------------------------------------------------------
check_copilot_setup_steps() {
  local repo="$1"

  local content
  content=$(gh_api "repos/$ORG/$repo/contents/.github/workflows/copilot-setup-steps.yml" \
    --jq '.content' 2>/dev/null || echo "")

  if [ -z "$content" ]; then
    add_finding "$repo" "standards" "missing-copilot-setup-steps" "warning" \
      "Missing \`.github/workflows/copilot-setup-steps.yml\` — every repo should pre-install tools and dependencies for the Copilot cloud agent. Copy the template from the org standards and uncomment the stack block(s) for this repo." \
      "standards/ci-standards.md"
    return
  fi

  # Verify the workflow contains jobs.copilot-setup-steps specifically.
  # Use a small indentation-based parser (not a loose grep) so comments or similarly
  # named keys elsewhere cannot falsely satisfy this compliance check.
  local decoded
  decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")
  if ! echo "$decoded" | python3 -c '
import re
import sys

lines = sys.stdin.read().splitlines()
jobs_indent = None
child_indent = None
in_jobs = False
found = False

for raw in lines:
    # Skip empty lines and comments
    if re.match(r"^[ \t]*(#.*)?$", raw):
        continue

    indent = len(raw) - len(raw.lstrip(" \t"))
    line = raw.strip()

    if not in_jobs:
        if re.match(r"^jobs:[ \t]*(#.*)?$", line):
            in_jobs = True
            jobs_indent = indent
        continue

    # Left jobs section
    if indent <= jobs_indent:
        break

    # Determine direct-child indentation under jobs (first mapping key)
    if child_indent is None and re.match(r"^[^:#][^:]*:[ \t]*(#.*)?$", line):
        child_indent = indent

    # Match the exact required direct child key (quoted or unquoted YAML key)
    if child_indent is not None and indent == child_indent and re.match(r"^[\"\x27]?copilot-setup-steps[\"\x27]?:[ ]*(#.*)?$", line):
        found = True
        break

sys.exit(0 if found else 1)
'; then
    add_finding "$repo" "standards" "copilot-setup-steps-invalid-job-name" "error" \
      "\`.github/workflows/copilot-setup-steps.yml\` exists but does not contain a job named \`copilot-setup-steps\` — GitHub requires this exact job name to pick up the file." \
      "standards/ci-standards.md"
  fi
}

# ---------------------------------------------------------------------------
# Check: .github/copilot-instructions.md exists with required sections
#
# Every repo SHOULD have a repo-level Copilot instructions file to give
# Copilot specific context it cannot derive from code alone: the active
# tech stack versions, project structure, exact local dev commands, required
# environment variables, and testing thresholds. The org-level baseline in
# petry-projects/.github supplies org-wide rules (SOLID, TDD, logging, CI
# gates, PR workflow); repo-level files extend it with repo-specific detail.
# Copilot prioritises repository instructions over org instructions, so the
# repo-level file is the primary surface for per-project customisation.
#
# Checks:
#   1. File present at .github/copilot-instructions.md (warning if missing)
#   2. Required sections present: "## Tech Stack" and "## Local Dev Commands"
#      (warning per missing section)
#
# The .github repo itself is exempt — it holds the canonical template, not
# a per-repo extension.
#
# See standards/copilot-instructions-standard.md for the required sections
# and fill-in template.
# ---------------------------------------------------------------------------
check_copilot_instructions() {
  local repo="$1"

  # The .github repo holds the canonical template — exempt from the
  # per-repo requirement.
  [ "$repo" = ".github" ] && return

  local content
  content=$(gh_api "repos/$ORG/$repo/contents/.github/copilot-instructions.md" \
    --jq '.content' 2>/dev/null || echo "")

  if [ -z "$content" ]; then
    add_finding "$repo" "standards" "missing-copilot-instructions" "error" \
      "Missing \`.github/copilot-instructions.md\`. Every repo must have its own Copilot instructions file — Copilot instruction files are repository-scoped and do not propagate from the \`petry-projects/.github\` repo. Copy the canonical template from \`standards/copilot-instructions-standard.md\` in \`petry-projects/.github\`, then tailor it with this repo's specific tech stack, project structure, local dev commands, required environment variables, and testing configuration." \
      "standards/copilot-instructions-standard.md"
    return
  fi

  local decoded
  decoded=$(echo "$content" | base64 -d 2>/dev/null || echo "")

  # Strip fenced code blocks before checking for required section headers so
  # that ## headings inside code examples (e.g. template snippets) cannot
  # falsely satisfy the check.
  local prose
  prose=$(echo "$decoded" | awk '/^```/{in_block=!in_block; next} !in_block{print}')

  # Verify required section headers (level-2, case-insensitive)
  local required_sections=("Tech Stack" "Local Dev Commands")
  for section in "${required_sections[@]}"; do
    local slug
    slug=$(echo "$section" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    if ! echo "$prose" | grep -qiE "^##[[:space:]]+${section}"; then
      add_finding "$repo" "standards" "copilot-instructions-missing-${slug}" "warning" \
        "\`.github/copilot-instructions.md\` is missing the required \`## $section\` section. See \`standards/copilot-instructions-standard.md\` for the required template and guidance on what to include." \
        "standards/copilot-instructions-standard.md"
    fi
  done
}

# ---------------------------------------------------------------------------
# Check: check-suite auto-trigger disabled for Claude and CodeRabbit
# ---------------------------------------------------------------------------
check_check_suite_prefs() {
  local repo="$1"

  # The GET endpoint returns 404 when check-suite preferences have never been
  # set for this repo — i.e. no app (Claude/CodeRabbit) has created a check run
  # yet, so no orphaned "queued" suite can exist. That is the compliant
  # "missing" state (mirrors the per-app handling below), not a read failure, so
  # it must not raise a finding. Only a genuine unreadable error (auth/scope/
  # network) warrants the warning. apply-repo-settings.sh and
  # fix-check-suite-prefs.sh tolerate this same 404. Capture the GET's combined
  # output and exit status (gh_api swallows both) so the cases can be told apart.
  local prefs="" rc=1 i
  for i in 1 2 3; do
    prefs=$(gh api "repos/$ORG/$repo/check-suites/preferences" 2>&1) && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
      break
    fi
    # 404 is deterministic and benign — stop retrying and report nothing.
    if grep -q 'HTTP 404' <<< "$prefs"; then
      return 0
    fi
    if [ "$i" -lt 3 ]; then
      sleep $((i * 2))
    fi
  done

  if [ "$rc" -ne 0 ]; then
    add_finding "$repo" "settings" "check-suite-prefs-unreadable" "warning" \
      "Could not read check-suite preferences — verify GH_TOKEN has repo scope and the repo is accessible. Check-suite auto-trigger compliance was not evaluated." \
      "standards/github-settings.md"
    return
  fi

  for app_id in "${CHECK_SUITE_APP_IDS[@]}"; do
    local setting
    setting=$(echo "$prefs" | jq -r --argjson id "$app_id" \
      '.preferences.auto_trigger_checks // [] | map(select(.app_id == $id)) | first | .setting // "missing"')

    # "missing" means the app has never run in this repo — no orphaned suite possible
    [ "$setting" = "missing" ] && continue
    [ "$setting" = "false"   ] && continue

    local app_label="app_id=$app_id"
    [ "$app_id" = "1236702" ] && app_label="Claude (1236702)"
    [ "$app_id" = "347564"  ] && app_label="CodeRabbit (347564)"

    add_finding "$repo" "settings" "check-suite-auto-trigger-${app_id}" "error" \
      "$app_label auto-trigger is enabled: GitHub creates a queued check suite on every push that is never completed, permanently blocking auto-merge. Run: \`bash scripts/apply-repo-settings.sh $repo\`" \
      "standards/github-settings.md"
  done
}

# ---------------------------------------------------------------------------
# Issue management
# ---------------------------------------------------------------------------
ensure_audit_label() {
  local repo="$1"
  gh label create "$AUDIT_LABEL" \
    --repo "$ORG/$repo" \
    --description "$AUDIT_LABEL_DESC" \
    --color "$AUDIT_LABEL_COLOR" \
    --force 2>/dev/null || true
  # Machine-owned finding label — the sole label the auto-closer keys on (AC1c).
  gh label create "$FINDING_LABEL" \
    --repo "$ORG/$repo" \
    --description "$FINDING_LABEL_DESC" \
    --color "$FINDING_LABEL_COLOR" \
    --force 2>/dev/null || true
  gh label create "$DEV_LEAD_LABEL" \
    --repo "$ORG/$repo" \
    --description "$DEV_LEAD_LABEL_DESC" \
    --color "$DEV_LEAD_LABEL_COLOR" \
    --force 2>/dev/null || true
  # dev-lead:hands-off — the actor label `rulesets` findings carry instead of
  # dev-lead (issue #1093 / #1037). Ensure it exists so create_issue_for_finding
  # can attach it even on a repo apply-repo-settings.sh has not yet reconciled.
  gh label create "$DEV_LEAD_HANDS_OFF_LABEL" \
    --repo "$ORG/$repo" \
    --description "$DEV_LEAD_HANDS_OFF_DESC" \
    --color "$DEV_LEAD_HANDS_OFF_COLOR" \
    --force 2>/dev/null || true
}

# Create all required labels (idempotent — uses --force to update if present)
ensure_required_labels() {
  local repo="$1"
  # Format: "name|color|description" (pipe-delimited to avoid colon conflicts)
  local label_configs=("${STANDARD_LABEL_SPECS[@]}")

  for config in "${label_configs[@]}"; do
    IFS='|' read -r name color description <<< "$config"
    gh label create "$name" \
      --repo "$ORG/$repo" \
      --description "$description" \
      --color "$color" \
      --force 2>/dev/null || true
  done
}

# swap_rulesets_finding_to_hands_off <repo> <issue>: on an existing open
# `rulesets` finding, remove the `dev-lead` actor label (if present) and add
# `dev-lead:hands-off` (issue #1093, decision #1037). Idempotent and safe to
# repeat: the add and remove are independent gh calls so a remove of an
# already-absent label never blocks the add. Honours DRY_RUN. This removes the
# actor only — it neither closes nor resolves the finding (AC3).
swap_rulesets_finding_to_hands_off() {
  local repo="$1" issue="$2"

  if [ "$DRY_RUN" = "true" ]; then
    info "[dry-run] would swap \`dev-lead\` -> \`dev-lead:hands-off\` on $ORG/$repo#$issue (ruleset finding)"
    return 0
  fi

  # Add hands-off first so the issue is never momentarily without an actor label,
  # then drop dev-lead. Track both edits: a genuine API failure on either must be
  # surfaced rather than silently reported as success, or the issue is left
  # incorrectly routed with no signal. `gh issue edit` computes the label set, so
  # removing an already-absent dev-lead label (idempotent rerun) still succeeds.
  local swap_ok=true
  gh issue edit "$issue" --repo "$ORG/$repo" --add-label "$DEV_LEAD_HANDS_OFF_LABEL" 2>/dev/null || swap_ok=false
  gh issue edit "$issue" --repo "$ORG/$repo" --remove-label "$DEV_LEAD_LABEL" 2>/dev/null || swap_ok=false
  if [ "$swap_ok" != "true" ]; then
    warn "Failed to fully route ruleset finding #$issue in $repo to \`dev-lead:hands-off\` (label add/remove failed — issue may be incorrectly routed)"
    return 1
  fi
  info "Routed ruleset finding #$issue in $repo to \`dev-lead:hands-off\` (dev-lead removed; finding kept open)"
}

create_issue_for_finding() {
  local repo="$1" category="$2" check="$3" severity="$4" detail="$5" standard_ref="$6"

  local title="Compliance: ${check}"
  # Normalize title for search
  local search_title="${title}"

  # Check for existing open issue with same title
  local existing
  existing=$(gh issue list --repo "$ORG/$repo" \
    --label "$AUDIT_LABEL" \
    --state open \
    --search "\"$search_title\" in:title" \
    --json number,title \
    -q ".[] | select(.title == \"$search_title\") | .number" \
    2>/dev/null | head -1 || echo "")

  if [ -n "$existing" ]; then
    # Migrate the machine-owned finding label onto pre-existing issues so the
    # auto-closer (which keys on FINDING_LABEL) can retire them once resolved
    # (issue #1036, AC1c). Idempotent; a no-op if already present.
    gh issue edit "$existing" --repo "$ORG/$repo" --add-label "$FINDING_LABEL" 2>/dev/null || true

    # Update existing issue with a comment; only count as existing if the update succeeds
    local update_ok=true
    gh issue comment "$existing" --repo "$ORG/$repo" \
      --body "**Weekly Compliance Audit** ($(date -u +%Y-%m-%d))

This finding is still open.

**Detail:** $detail

**Standard:** [$standard_ref](https://github.com/$ORG/.github/blob/main/$standard_ref)" 2>/dev/null || update_ok=false
    if [ "$update_ok" = "true" ]; then
      info "Updated existing issue #$existing in $repo for: $check"
      ISSUES_EXISTING=$((ISSUES_EXISTING + 1))
    else
      warn "Failed to update existing issue #$existing in $repo for: $check"
    fi

    # Route `rulesets` findings away from dev-lead (issue #1093, decision #1037).
    # dev-lead cannot read or write ruleset state, so instead of re-triggering it
    # we swap the actor label to dev-lead:hands-off. The comment update above
    # already re-reported the finding (AC3) — hands-off removes the actor without
    # resolving the finding; convergence happens via apply-rulesets.sh (#1045).
    if [ "$category" = "rulesets" ]; then
      # Only drop the active dev-lead route once the re-report comment above
      # actually landed. If the update failed (update_ok=false), swapping to
      # hands-off would remove dev-lead without a successful re-report, leaving
      # the finding with no active route; keep dev-lead in place so the next
      # audit retries.
      if [ "$update_ok" = "true" ]; then
        swap_rulesets_finding_to_hands_off "$repo" "$existing"
      else
        warn "Skipped routing ruleset finding #$existing in $repo to hands-off — re-report comment failed; leaving dev-lead in place for retry"
      fi
    # Re-engage dev-lead on non-rulesets findings that PERSIST across audits.
    #
    # dev-lead listens on issues:labeled and fires only once per label
    # application. The `dev-lead` label is already present on a pre-existing
    # issue, so a plain --add-label is a no-op that emits no event and dev-lead
    # is never re-triggered. To give it a fresh chance to produce a fix PR we
    # cycle the label (remove + re-add) — UNLESS dev-lead is already working
    # this issue (open dev-lead PR or `in-progress` label), in which case we
    # leave it alone (the label is already present, so no action is needed).
    elif dl_dev_lead_active "$ORG" "$repo" "$existing"; then
      info "Existing issue #$existing in $repo — dev-lead already active, not re-triggering"
    elif dl_cycle_trigger_label "$ORG" "$repo" "$existing" "dev-lead" "$DRY_RUN"; then
      info "Re-triggered dev-lead on persistent issue #$existing in $repo for: $check"
      ISSUES_RETRIGGERED=$((ISSUES_RETRIGGERED + 1))
    else
      # Cycle failed mid-way — ensure the label is at least present so the issue
      # is not left without its trigger label.
      gh issue edit "$existing" --repo "$ORG/$repo" --add-label "dev-lead" 2>/dev/null || true
      warn "Failed to re-trigger dev-lead on issue #$existing in $repo for: $check"
    fi
    # Record existing issue for umbrella
    jq --null-input \
      --arg repo "$repo" \
      --arg category "$category" \
      --arg check "$check" \
      --arg severity "$severity" \
      --arg number "$existing" \
      --arg url "https://github.com/$ORG/$repo/issues/$existing" \
      '{repo:$repo,category:$category,check:$check,severity:$severity,number:$number,url:$url}' \
      >> "$ISSUES_FILE"
    return
  fi

  # Category-specific remediation instructions
  local remediation_steps
  case "$category" in
    settings)
      remediation_steps="Run \`scripts/apply-repo-settings.sh ${repo}\` with a token that has admin access to the repository (requires a classic PAT with \`repo\` scope or equivalent):

\`\`\`bash
GH_TOKEN=<admin-pat> bash scripts/apply-repo-settings.sh ${repo}
\`\`\`

This script applies all standard settings defined in \`standards/github-settings.md\` in one pass.
For a dry run to preview changes without applying: \`DRY_RUN=true GH_TOKEN=<admin-pat> bash scripts/apply-repo-settings.sh ${repo}\`"
      ;;
    ci-workflows|workflows)
      remediation_steps="Copy the relevant workflow template from \`standards/workflows/\` verbatim — do not generate from scratch:

\`\`\`bash
gh api repos/${ORG}/.github/contents/standards/workflows/<template>.yml --jq '.content' | base64 -d > .github/workflows/<template>.yml
\`\`\`

Available templates: \`agent-shield.yml\`, \`dev-lead.yml\`, \`dependabot-automerge.yml\`, \`dependabot-rebase.yml\`, \`dependency-audit.yml\`, \`feature-ideation.yml\`"
      ;;
    labels)
      remediation_steps="Run \`scripts/apply-repo-settings.sh ${repo}\` — it applies standard labels alongside settings:

\`\`\`bash
GH_TOKEN=<admin-pat> bash scripts/apply-repo-settings.sh ${repo}
\`\`\`"
      ;;
    *)
      remediation_steps="Please review the linked standard and bring this repository into compliance.

See the [full standards documentation](https://github.com/${ORG}/.github/tree/main/standards) for implementation guidance."
      ;;
  esac

  # Build issue body — variable values are safe (from our own check logic + GitHub API)
  local body="## Compliance Finding

**Category:** \`${category}\`
**Severity:** \`${severity}\`
**Check:** \`${check}\`

## Detail

${detail}

## Standard Reference

[${standard_ref}](https://github.com/${ORG}/.github/blob/main/${standard_ref})

## Remediation

${remediation_steps}

---
*This issue was automatically created by the [weekly compliance audit](https://github.com/${ORG}/.github/blob/main/.github/workflows/compliance-audit.yml).*
${AUDIT_GENERATED_MARKER}"

  local issue_url
  # Finding issues carry: compliance-finding (machine-owned closer key, AC1c),
  # compliance-audit (human-facing triage label), and the dev-lead actor label
  # for this category (issue #1093 / #1037): dev-lead for code-change findings,
  # dev-lead:hands-off for `rulesets` findings dev-lead cannot act on.
  local actor_label
  actor_label=$(category_actor_label "$category")
  issue_url=$(gh issue create --repo "$ORG/$repo" \
    --title "$search_title" \
    --label "$FINDING_LABEL" \
    --label "$AUDIT_LABEL" \
    --label "$actor_label" \
    --body "$body" 2>/dev/null || echo "")

  if [ -n "$issue_url" ]; then
    local new_issue
    new_issue=$(echo "$issue_url" | grep -oE '[0-9]+$' || echo "")
    info "Created issue #$new_issue in $repo for: $check ($issue_url)"
    ISSUES_ADDED=$((ISSUES_ADDED + 1))

    # Record created issue for umbrella
    if [ -n "$new_issue" ]; then
      jq --null-input \
        --arg repo "$repo" \
        --arg category "$category" \
        --arg check "$check" \
        --arg severity "$severity" \
        --arg number "$new_issue" \
        --arg url "$issue_url" \
        '{repo:$repo,category:$category,check:$check,severity:$severity,number:$number,url:$url}' \
        >> "$ISSUES_FILE"
    fi
  else
    warn "Failed to create issue in $repo for: $check"
  fi
}

create_umbrella_issue() {
  local audit_date
  audit_date=$(date -u +%Y-%m-%d)
  local title="Compliance audit — $audit_date"

  # Skip if no findings
  local total_findings
  total_findings=$(jq length "$FINDINGS_FILE")
  if [ "$total_findings" -eq 0 ]; then
    info "No findings — skipping umbrella issue"
    return
  fi

  # Check for existing open umbrella issue for today
  local existing_umbrella
  existing_umbrella=$(gh issue list --repo "$ORG/.github" \
    --label "$AUDIT_LABEL" \
    --state open \
    --search "\"$title\" in:title" \
    --json number,title \
    -q ".[] | select(.title == \"$title\") | .number" \
    2>/dev/null | head -1 || echo "")

  if [ -n "$existing_umbrella" ]; then
    info "Umbrella issue #$existing_umbrella already exists for $audit_date — skipping"
    return
  fi

  # Map finding categories to remediation groups
  # Each group: category_keys|display_name|remediation_script
  local groups=(
    "settings|Repository Settings|apply-repo-settings.sh"
    "push-protection|Push Protection & Secret Scanning|apply-repo-settings.sh (security_and_analysis) + per-repo ci.yml and .gitignore"
    "labels|Labels|apply_labels() in apply-repo-settings.sh"
    "rulesets|Repository Rulesets|apply-rulesets.sh"
    "ci-workflows|Workflows|per-repo workflow additions"
    "reusable-workflows|Reusable Workflows (disabled_manually)|gh workflow disable <workflow> -R <repo>"
    "action-pinning|Action SHA Pinning|pin actions to SHA in each workflow file"
    "dependabot|Dependabot Configuration|per-repo .github/dependabot.yml"
    "standards|Agent Standards (CLAUDE.md / AGENTS.md / copilot-setup-steps.yml)|per-repo doc and workflow additions"
  )

  local body
  body="## Compliance Audit — $audit_date

This umbrella issue tracks all findings from the automated compliance audit run on **$audit_date**.
Findings are grouped by remediation category. Address each category together to avoid duplicate agent PRs.

**Total findings:** $total_findings across $(jq -r '[.[].repo] | unique | length' "$FINDINGS_FILE") repositories

---

## Remediation Work Breakdown
"

  for group_entry in "${groups[@]}"; do
    IFS='|' read -r cat_key display_name remediation_script <<< "$group_entry"

    local cat_findings
    cat_findings=$(jq -c --arg cat "$cat_key" '[.[] | select(.category == $cat)]' "$FINDINGS_FILE")
    local cat_count
    cat_count=$(echo "$cat_findings" | jq 'length')

    [ "$cat_count" -eq 0 ] && continue

    local affected_repos
    affected_repos=$(echo "$cat_findings" | jq -r '[.[].repo] | unique | join(", ")')

    body+="
### $display_name ($cat_count finding(s))

**Remediation:** \`$remediation_script\`
**Affected repos:** $affected_repos

| Repo | Check | Severity |
|------|-------|----------|
"
    # Add per-finding rows with issue links where available
    while IFS= read -r finding; do
      local f_repo f_check f_severity f_number f_url
      f_repo=$(echo "$finding" | jq -r '.repo')
      f_check=$(echo "$finding" | jq -r '.check')
      f_severity=$(echo "$finding" | jq -r '.severity')

      # Look up issue link if we tracked it
      local issue_link=""
      if [ -s "$ISSUES_FILE" ]; then
        local issue_entry
        issue_entry=$(grep -F "\"repo\":\"$f_repo\"" "$ISSUES_FILE" 2>/dev/null | \
          jq -c --arg repo "$f_repo" --arg check "$f_check" \
          'select(.repo == $repo and .check == $check)' 2>/dev/null | head -1 || echo "")
        if [ -n "$issue_entry" ]; then
          f_number=$(echo "$issue_entry" | jq -r '.number')
          f_url=$(echo "$issue_entry" | jq -r '.url')
          issue_link=" ([#$f_number]($f_url))"
        fi
      fi

      body+="| \`$f_repo\` | \`$f_check\`$issue_link | \`$f_severity\` |
"
    done < <(echo "$cat_findings" | jq -c '.[]')

  done

  body+="
---
*Generated by the [weekly compliance audit](https://github.com/${ORG}/.github/blob/main/.github/workflows/compliance-audit.yml) on $(date -u "+%Y-%m-%d %H:%M UTC").*
*Address each remediation category as a single coordinated PR to avoid duplicate agent work.*"

  ensure_audit_label ".github"

  local umbrella_url
  umbrella_url=$(gh issue create --repo "$ORG/.github" \
    --title "$title" \
    --label "$AUDIT_LABEL" \
    --label "dev-lead" \
    --body "$body" 2>/dev/null || echo "")

  if [ -n "$umbrella_url" ]; then
    info "Created umbrella issue: $umbrella_url"
  else
    warn "Failed to create umbrella issue in $ORG/.github"
  fi
}

# close_resolved_issues <repo>: retire finding issues whose check is no longer
# present. Fail-CLOSED to match the detection paths (issue #1036):
#   AC2  — only for a repo actually scanned this run; a repo that was skipped,
#          scoped out, or aborted mid-collection has an empty findings set that
#          must NOT be read as "everything fixed".
#   AC3  — never when total findings across all repos is zero; that is a failed
#          scan, not a compliant org.
#   AC1c — enumerate ONLY the machine-owned FINDING_LABEL, never AUDIT_LABEL.
#   AC1  — close ONLY issues titled exactly `Compliance: <check>`.
#   AC1b — close ONLY issues whose body carries this tool's generated-by marker.
close_resolved_issues() {
  local repo="$1"

  # AC2: a repo that was not actually scanned this run must not have its findings
  # closed — its empty findings set is "not scanned", not "clean".
  if ! repo_was_audited "$repo"; then
    info "Skipping issue closure for $repo — not scanned this run (avoids closing live findings on a skipped/scoped-out repo)"
    return
  fi

  # AC2 (extended): skip repos with inconclusive checks (e.g. failed workflow-list
  # request in check_action_pinning). Collection was incomplete, so don't close.
  if repo_has_inconclusive_checks "$repo"; then
    info "Skipping issue closure for $repo — collection was inconclusive (closure-relevant check failed)"
    return
  fi

  # AC3: refuse to close anything on a zero-finding run. Detection is fail-closed
  # (an unreadable ruleset is drift, not a pass), so a total of zero across every
  # repo is a failed scan, not a compliant org.
  local total_findings
  total_findings=$(jq 'length' "$FINDINGS_FILE" 2>/dev/null || echo "")
  if [ -z "$total_findings" ]; then
    warn "Could not read total finding count from $FINDINGS_FILE — skipping issue closure (fail closed)"
    return
  fi
  if [ "$total_findings" -eq 0 ]; then
    warn "Total finding count is zero across all repos — treating as a failed scan and refusing to close any issue (issue #1036, AC3)"
    return
  fi

  # AC1c: enumerate ONLY machine-owned finding issues. `compliance-audit` is
  # deliberately NOT queried — hand-filed issues anyone labels it stay untouched.
  local open_issues_json
  open_issues_json=$(gh issue list --repo "$ORG/$repo" \
    --label "$FINDING_LABEL" \
    --state open \
    --limit 1000 \
    --json number,title,body 2>/dev/null || echo "[]")
  [ -z "$open_issues_json" ] && open_issues_json="[]"

  # Get current findings for this repo (bail if jq fails to avoid false closures)
  local current_checks
  if ! current_checks=$(jq -r --arg repo "$repo" '.[] | select(.repo == $repo) | .check' "$FINDINGS_FILE" 2>/dev/null); then
    warn "Failed to read findings for $repo — skipping issue closure to avoid false positives"
    return
  fi

  # Iterate one compact JSON object per line (jq escapes any newlines inside the
  # body, so a multi-line body cannot corrupt the loop).
  local obj
  while IFS= read -r obj; do
    [ -z "$obj" ] && continue
    local issue_num issue_title issue_body
    issue_num=$(jq -r '.number' <<< "$obj")
    issue_title=$(jq -r '.title' <<< "$obj")
    issue_body=$(jq -r '.body // ""' <<< "$obj")

    # AC1: only per-finding issues titled exactly `Compliance: <check>`. The
    # umbrella (`Compliance audit — <date>`) and hand-filed issues never match.
    case "$issue_title" in
      "Compliance: "*) : ;;
      *)
        info "Skipping #$issue_num in $repo — not a per-finding \`Compliance: <check>\` title: $issue_title"
        continue
        ;;
    esac

    # AC1b: only issues THIS TOOL created (evidenced by the generated-by marker),
    # never on the title or label alone.
    if ! issue_has_generated_marker "$issue_body"; then
      info "Skipping #$issue_num in $repo — no compliance-audit generated-by marker (not machine-created)"
      continue
    fi

    local check_name="${issue_title#Compliance: }"

    # If this check is no longer in findings, close the issue
    if ! echo "$current_checks" | grep -qx "$check_name"; then
      if gh issue close "$issue_num" --repo "$ORG/$repo" \
          --comment "Resolved! This check is now passing as of $(date -u +%Y-%m-%d). Closing automatically." \
          2>/dev/null; then
        info "Closed resolved issue #$issue_num in $repo: $issue_title"
        ISSUES_REMOVED=$((ISSUES_REMOVED + 1))
      else
        warn "Failed to close resolved issue #$issue_num in $repo: $issue_title"
      fi
    fi
  done < <(echo "$open_issues_json" | jq -c '.[]' 2>/dev/null)
}

# print_planned_issue_actions: in read-only mode, report the issue mutations the
# script WOULD perform if run with --apply, so a maintainer can preview intent
# without touching production issue state (issue #1036, AC4). Read-only: prints
# the per-finding create/update plan and appends a note to the summary. Closures
# are not enumerated here (that would require querying every repo's open issues);
# the note makes clear they are gated behind --apply too.
print_planned_issue_actions() {
  local total
  total=$(jq 'length' "$FINDINGS_FILE" 2>/dev/null || echo 0)
  info "Would ensure org labels and file/update $total finding issue(s) (and close resolved ones) — suppressed in read-only mode."

  # Pre-parse findings into tab-separated format to avoid spawning jq inside the loop.
  local planned_actions
  planned_actions=$(jq -r '.[] | [.repo, .check] | @tsv' "$FINDINGS_FILE" 2>/dev/null || echo "")

  local p_repo p_check
  while IFS=$'\t' read -r p_repo p_check; do
    [ -z "$p_repo" ] && continue
    info "  would file/update: $ORG/$p_repo — Compliance: $p_check"
  done <<< "$planned_actions"
}

# ---------------------------------------------------------------------------
# Summary generation
# ---------------------------------------------------------------------------
generate_summary() {
  local total_repos="$1"
  local total_findings
  total_findings=$(jq length "$FINDINGS_FILE")

  local error_count
  error_count=$(jq '[.[] | select(.severity == "error")] | length' "$FINDINGS_FILE")
  local warning_count
  warning_count=$(jq '[.[] | select(.severity == "warning")] | length' "$FINDINGS_FILE")

  cat > "$SUMMARY_FILE" <<HEREDOC
# Org Compliance Audit Report — $(date -u +%Y-%m-%d)

## Summary

| Metric | Count |
|--------|-------|
| Repositories audited | $total_repos |
| Total findings | $total_findings |
| Errors (must fix) | $error_count |
| Warnings (should fix) | $warning_count |

HEREDOC

  if [ "$total_findings" -eq 0 ]; then
    echo "All repositories are fully compliant! No findings." >> "$SUMMARY_FILE"
    return
  fi

  # ── Findings by Check Type ──────────────────────────────────────────────────
  # Group by check name (not repo) to surface cross-repo patterns at a glance.
  # Errors first, then warnings; within each severity sorted by category then check.
  cat >> "$SUMMARY_FILE" <<'HEREDOC'
## Findings by Check Type

| Check | Severity | Category | Repos Affected |
|-------|----------|----------|----------------|
HEREDOC

  jq -r --arg org "$ORG" '
    group_by(.check)
    | map({
        check:      .[0].check,
        category:   .[0].category,
        severity:   .[0].severity,
        repos:      [.[].repo]
      })
    | sort_by([(if .severity == "error" then 0 else 1 end), .category, .check])
    | .[]
    | "| `\(.check)` | `\(.severity)` | \(.category) | \(.repos | map("[`" + . + "`](https://github.com/" + $org + "/" + . + ")") | join(", ")) |"
  ' "$FINDINGS_FILE" >> "$SUMMARY_FILE"

  # ── Per-Repo Scorecard ───────────────────────────────────────────────────────
  cat >> "$SUMMARY_FILE" <<'HEREDOC'

## Per-Repo Scorecard

| Repo | Errors | Warnings | Total |
|------|--------|----------|-------|
HEREDOC

  jq -r --arg org "$ORG" '
    group_by(.repo)
    | map({
        repo:     .[0].repo,
        errors:   ([.[] | select(.severity == "error")]   | length),
        warnings: ([.[] | select(.severity == "warning")] | length),
        total:    length
      })
    | sort_by(-.total)
    | .[]
    | "| [**\(.repo)**](https://github.com/" + $org + "/" + .repo + ") | \(.errors) | \(.warnings) | **\(.total)** |"
  ' "$FINDINGS_FILE" >> "$SUMMARY_FILE"

  # ── Category breakdown ───────────────────────────────────────────────────────
  cat >> "$SUMMARY_FILE" <<'HEREDOC'

## Findings by Category

HEREDOC

  for category in ci-workflows reusable-workflows action-pinning dependabot settings push-protection labels rulesets standards; do
    local cat_count
    cat_count=$(jq --arg cat "$category" '[.[] | select(.category == $cat)] | length' "$FINDINGS_FILE")
    if [ "$cat_count" -gt 0 ]; then
      echo "- **$category:** $cat_count finding(s)" >> "$SUMMARY_FILE"
    fi
  done
  # Footer appended by main() after issue links are added
}

# ---------------------------------------------------------------------------
# Issue & PR link summary (appended after issue creation)
# ---------------------------------------------------------------------------
append_issue_pr_links() {
  [ -s "$ISSUES_FILE" ] || return

  # Collect open PRs per affected repo (one GraphQL call per repo) to find
  # those whose closingIssuesReferences include one of our compliance issues.
  local pr_data_file
  pr_data_file=$(mktemp)
  echo '[]' > "$pr_data_file"

  local repos_in_issues
  repos_in_issues=$(jq -rn '[inputs | .repo] | unique[]' "$ISSUES_FILE" 2>/dev/null || echo "")

  for repo in $repos_in_issues; do
    local repo_prs
    repo_prs=$(gh api graphql \
      -f owner="$ORG" -f name="$repo" \
      -f query='query($owner:String!,$name:String!){
        repository(owner:$owner,name:$name){
          pullRequests(states:OPEN,first:100){
            nodes{
              number url
              closingIssuesReferences(first:10){nodes{number}}
            }
          }
        }
      }' 2>/dev/null \
      | jq --arg repo "$repo" '[
          .data.repository.pullRequests.nodes[] | {
            repo:      $repo,
            pr_number: .number,
            pr_url:    .url,
            closes:    [.closingIssuesReferences.nodes[].number]
          }
        ]' 2>/dev/null || echo '[]')

    jq -n \
      --argjson existing "$(cat "$pr_data_file")" \
      --argjson new_prs "$repo_prs" \
      '$existing + $new_prs' > "$pr_data_file.tmp" \
      && mv "$pr_data_file.tmp" "$pr_data_file"
  done

  cat >> "$SUMMARY_FILE" <<'HEREDOC'

## Issues & Related PRs

Grouped by compliance check type. Each entry links to the GitHub Issue for the
finding in each affected repo; **Related PRs** shows open pull requests that
close that issue.

HEREDOC

  # Iterate checks in severity then alphabetical order
  local checks_ordered
  checks_ordered=$(jq -rn '[inputs]
    | group_by(.check)
    | map({check: .[0].check, severity: .[0].severity})
    | sort_by([(if .severity == "error" then 0 else 1 end), .check])
    | .[].check
  ' "$ISSUES_FILE" 2>/dev/null || echo "")

  while IFS= read -r check; do
    [ -z "$check" ] && continue

    local check_issues severity category issue_count
    check_issues=$(jq -cn --arg c "$check" '[inputs | select(.check == $c)] | sort_by(.repo)' "$ISSUES_FILE")
    severity=$(jq -r '.[0].severity' <<< "$check_issues")
    category=$(jq -r '.[0].category' <<< "$check_issues")
    issue_count=$(jq 'length' <<< "$check_issues")

    printf '\n### `%s`\n' "$check" >> "$SUMMARY_FILE"
    printf '**Severity:** `%s` | **Category:** %s | **%d repo(s) affected**\n\n' \
      "$severity" "$category" "$issue_count" >> "$SUMMARY_FILE"
    printf '| Repo | Issue | Related PRs |\n' >> "$SUMMARY_FILE"
    printf '|------|-------|-------------|\n' >> "$SUMMARY_FILE"

    while IFS= read -r issue_entry; do
      local repo issue_num issue_url pr_links
      repo=$(jq -r '.repo'    <<< "$issue_entry")
      issue_num=$(jq -r '.number' <<< "$issue_entry")
      issue_url=$(jq -r '.url'    <<< "$issue_entry")

      pr_links=$(jq -r \
        --arg repo "$repo" \
        --argjson inum "$issue_num" \
        '[.[] | select(.repo == $repo and (.closes | map(. == $inum) | any))
          | "[#\(.pr_number)](\(.pr_url))"]
        | if length > 0 then join(", ") else "—" end' \
        "$pr_data_file")

      printf '| [%s](https://github.com/%s/%s) | [#%s](%s) | %s |\n' \
        "$repo" "$ORG" "$repo" "$issue_num" "$issue_url" "$pr_links" \
        >> "$SUMMARY_FILE"
    done < <(jq -c '.[]' <<< "$check_issues")
  done <<< "$checks_ordered"

  rm -f "$pr_data_file"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Informational AGENTS.md structural-findings summary section
# ---------------------------------------------------------------------------
# structural_finding_count <tsv-file> — number of recorded structural findings
# (one per line) in the informational accumulator; 0 for an empty/missing file.
# Pure. This per-cycle count is what makes "two consecutive clean cycles"
# observable from the audit issue history (issue #647, AC #1).
structural_finding_count() {
  local file="$1"
  [ -s "$file" ] || { printf '0'; return 0; }
  # Branch on grep's exit status instead of discarding it. grep exits 1 on zero
  # matches (a genuine finding-free cycle → 0) but exits >=2 on an actual error
  # (e.g. a non-empty file that cannot be read). Swallowing the latter would
  # report "0 findings" — a CLEAN cycle — because we could not read the evidence,
  # which is the one failure mode this promotion-precondition counter must never
  # have (issue #647, AC #1). Propagate it as a hard failure instead so the cycle
  # is recorded as indeterminate, never clean.
  # Guard the assignment so the rc-based branching is deterministic in BOTH call
  # contexts. `grep -c` exits 1 on zero matches; under this script's own
  # `set -euo pipefail` a bare `n="$(grep …)"; rc=$?` exits the shell at the
  # assignment BEFORE `rc` is read when the function is called DIRECTLY (a `$( )`
  # caller suspends errexit and hides the bug). The `if` captures the status
  # without tripping errexit, so the error branches below are reachable however
  # the function is invoked — including from the bats tests that call it directly.
  local n rc
  if n="$(grep -c . "$file" 2>/dev/null)"; then rc=0; else rc=$?; fi
  if [ "$rc" -eq 0 ]; then printf '%s' "$n"; return 0; fi
  if [ "$rc" -eq 1 ]; then printf '0'; return 0; fi
  printf '::error::structural_finding_count: cannot read %s (grep exit %s)\n' "$file" "$rc" >&2
  return 1
}

# Append the structural-linter findings collected in STRUCTURAL_FINDINGS_FILE to
# the run summary as a clearly-labelled INFORMATIONAL (non-blocking) section that
# links to the rule-set / promotion-gate doc. These findings never opened issues
# and never affected the exit code — this section is their only surface.
append_structural_findings_summary() {
  local doc_link="https://github.com/$ORG/.github/blob/main/$AGENTS_MD_RULESET_DOC"
  local cycle_log_link="https://github.com/$ORG/.github/blob/main/$AGENTS_MD_CYCLE_LOG"
  local count
  count="$(structural_finding_count "$STRUCTURAL_FINDINGS_FILE")"
  # If the linter did not complete for one or more repos this cycle, the finding
  # count is not trustworthy (a suppressed failure leaves the accumulator empty).
  # Mark the cycle INDETERMINATE so it can never be recorded as a clean
  # zero-finding cycle (issue #647, AC #1).
  local lint_incomplete=""
  if [ -f "$STRUCTURAL_LINT_ERROR_FILE" ] && [ -s "$STRUCTURAL_LINT_ERROR_FILE" ]; then
    lint_incomplete="yes"
  fi
  {
    printf '\n## AGENTS.md Structural Findings (informational)\n\n'
    printf '_Non-blocking: these structural-linter findings are advisory only — they open no issues and never fail the audit. Rule set and informational → blocking promotion gate: [%s](%s)._\n\n' \
      "$AGENTS_MD_RULESET_DOC" "$doc_link"
    # Per-cycle record (issue #647, AC #1): the machine-counted number of
    # structural findings this cycle, plus the durable, tamper-evident home for
    # the maintainer's confirmed-false-positive determination. The audit cannot
    # itself confirm false positives (that is a human review), so it records the
    # count and points at the append-only committed cycle log.
    if [ -n "$lint_incomplete" ]; then
      printf '**Structural findings this cycle: INDETERMINATE.** The structural linter did not complete for one or more repositories this cycle, so the finding count is not trustworthy. **This cycle MUST NOT be recorded as clean** in the append-only [cycle log](%s) — investigate the linter failure and re-run before recording any determination. Promotion is never automatic.\n\n' \
        "$cycle_log_link"
    else
      printf '**Structural findings this cycle: %s.** Confirmed false positives are a maintainer determination — record this cycle'\''s count and any confirmed false positive (naming the maintainer) in the append-only [cycle log](%s). Two consecutive cycles with zero confirmed false positives **and** explicit maintainer sign-off are required before the check may be promoted to blocking; promotion is never automatic.\n\n' \
        "$count" "$cycle_log_link"
    fi
  } >> "$SUMMARY_FILE"

  if [ ! -s "$STRUCTURAL_FINDINGS_FILE" ]; then
    if [ -n "$lint_incomplete" ]; then
      printf 'No findings were recorded, but the structural linter did not complete for every scanned repo this cycle — see the INDETERMINATE note above. This is **not** a clean cycle.\n' >> "$SUMMARY_FILE"
    else
      printf 'No structural findings — every scanned `AGENTS.md` is structurally valid.\n' >> "$SUMMARY_FILE"
    fi
    return 0
  fi

  {
    printf '| Repo | Severity | Rule | Line | Finding |\n'
    printf '|------|----------|------|------|---------|\n'
  } >> "$SUMMARY_FILE"

  local repo sev rule line msg
  while IFS=$'\t' read -r repo sev rule line msg; do
    [ -n "$repo" ] || continue
    # A finding message can contain a literal '|' (e.g. a rule's alternation
    # regex like /standard|development standards/); escape it so it stays inside
    # the cell instead of splitting the markdown table column.
    msg="${msg//|/\\|}"
    printf '| `%s` | %s | `%s` | %s | %s |\n' "$repo" "$sev" "$rule" "$line" "$msg" \
      >> "$SUMMARY_FILE"
  done < "$STRUCTURAL_FINDINGS_FILE"
  return 0
}

main() {
  # Explicit apply flag (issue #1036, AC4). --apply enables mutation; it can also
  # be enabled via COMPLIANCE_AUDIT_APPLY=true (see APPLY default above).
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --apply) APPLY="true"; shift ;;
      --) shift; break ;;
      *) shift ;;
    esac
  done

  # Preflight: verify GH_TOKEN is set and gh CLI is authenticated
  if [ -z "${GH_TOKEN:-}" ]; then
    echo "::error::GH_TOKEN is not set. Ensure ORG_SCORECARD_TOKEN secret is configured and passed as an env var to this step." \
      "Job-level env vars should be inherited, but add GH_TOKEN explicitly to the step env block as a workaround." >&2
    exit 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "::error::gh auth failed — GH_TOKEN is set but authentication did not succeed." \
      "Check that ORG_SCORECARD_TOKEN is valid. If using a Fine-Grained token, ensure it has repository permissions: 'Administration: Read-only', 'Metadata: Read-only', 'Contents: Read-only', 'Issues: Read and write'; and organization permission: 'Metadata: Read-only' (required to list repositories)." >&2
    exit 1
  fi

  info "Starting compliance audit for $ORG"
  info "Report directory: $REPORT_DIR"
  info "Dry run: $DRY_RUN"
  info "Apply (mutate issues/labels): $APPLY"
  mutations_enabled || info "Read-only mode — no issues or labels will be created, commented on, or closed. Pass --apply or set COMPLIANCE_AUDIT_APPLY=true to enable mutation."

  # Initialize findings and issues tracking files
  echo "[]" > "$FINDINGS_FILE"
  : > "$ISSUES_FILE"
  # Record of repos actually scanned this run (issue #1036, AC2).
  : > "$AUDITED_REPOS_FILE"
  # Informational AGENTS.md structural findings accumulate here (never in
  # FINDINGS_FILE) so they stay non-blocking (#645).
  : > "$STRUCTURAL_FINDINGS_FILE"
  : > "$STRUCTURAL_LINT_ERROR_FILE"

  # Get all non-archived repos in the org
  local repos
  repos=$(gh repo list "$ORG" --no-archived --json name -q '.[].name' --limit 500)

  if [ -z "$repos" ]; then
    warn "No repositories found in $ORG — check GH_TOKEN permissions"
    echo "[]" > "$FINDINGS_FILE"
    return 1
  fi

  local repo_count=0

  for repo in $repos; do
    repo_count=$((repo_count + 1))
    log "Auditing $ORG/$repo"

    detect_ecosystems "$repo"
    if [ ${#ECOSYSTEMS[@]} -eq 0 ]; then
      info "Detected ecosystems: none"
    else
      info "Detected ecosystems: ${ECOSYSTEMS[*]}"
    fi

    # Fetch full repo JSON once and share with settings/push-protection checks
    local repo_json
    repo_json=$(gh_api "repos/$ORG/$repo" 2>/dev/null || echo "{}")
    if [ "$repo_json" = "{}" ]; then
      add_finding "$repo" "settings" "repo_metadata_unavailable" "error" \
        "Could not fetch repository metadata; settings and push-protection checks were skipped" \
        "standards/github-settings.md#repository-settings--standard-defaults"
      log_end
      continue
    fi

    check_required_workflows "$repo"
    check_action_pinning "$repo"
    check_reusable_workflow_paths "$repo"
    check_reusable_workflows_disabled "$repo"
    check_dependabot_config "$repo"
    check_repo_settings "$repo" "$repo_json"
    check_labels "$repo"
    check_rulesets "$repo" "$repo_json"
    check_codeowners "$repo"
    check_sonarcloud "$repo"
    check_sonar_s7637_exemption "$repo"
    check_codeql_default_setup "$repo"
    check_workflow_permissions "$repo"
    check_ci_concurrency "$repo"
    check_centralized_workflow_stubs "$repo"
    check_dev_lead_stub "$repo"
    check_stub_surface_drift "$repo"
    check_centralized_check_names "$repo"
    check_claude_md "$repo"
    check_agents_md "$repo"
    check_copilot_setup_steps "$repo"
    check_copilot_instructions "$repo"
    check_check_suite_prefs "$repo"
    pp_run_all_checks "$repo"

    # Record that this repo's checks actually ran (AC2). Reached only past the
    # repo_json guard above — a repo whose metadata could not be fetched hits the
    # `continue` and is deliberately NOT recorded, so its issues are never closed.
    # Also skip if any closure-relevant check was inconclusive (issue #1036).
    if ! repo_has_inconclusive_checks "$repo"; then
      mark_repo_audited "$repo"
    fi

    log_end
  done

  info "Audit complete: $findings_count findings across $repo_count repositories"

  # Generate summary report
  generate_summary "$repo_count"

  # Append the informational (non-blocking) AGENTS.md structural-findings section
  # (#645). Ordered before issue management so it is part of the summary body.
  append_structural_findings_summary

  # Create/update/close issues — only when mutation is explicitly enabled (AC4).
  if mutations_enabled && [ "$CREATE_ISSUES" = "true" ]; then
    info "Managing issues..."

    for repo in $repos; do
      ensure_audit_label "$repo"
      ensure_required_labels "$repo"

      # Create issues for new findings (process substitution avoids subshell)
      while IFS= read -r finding; do
        [ -z "$finding" ] && continue
        local f_check f_severity f_detail f_standard_ref f_category
        f_category=$(echo "$finding" | jq -r '.category')
        f_check=$(echo "$finding" | jq -r '.check')
        f_severity=$(echo "$finding" | jq -r '.severity')
        f_detail=$(echo "$finding" | jq -r '.detail')
        f_standard_ref=$(echo "$finding" | jq -r '.standard_ref')

        create_issue_for_finding "$repo" "$f_category" "$f_check" "$f_severity" "$f_detail" "$f_standard_ref"
      done < <(jq -c --arg repo "$repo" '.[] | select(.repo == $repo)' "$FINDINGS_FILE")

      # Close issues for resolved findings
      close_resolved_issues "$repo"
    done

    # Create one umbrella issue per audit run grouping all findings by remediation category.
    # Both individual issues and the umbrella get the `dev-lead` label for agent pickup.
    create_umbrella_issue

    # Append per-check issue links and related open PRs to the step summary
    info "Fetching linked PRs for issue summary..."
    append_issue_pr_links
  elif [ "$CREATE_ISSUES" = "true" ]; then
    # Read-only (or dry-run): report what issue management WOULD do, mutate nothing (AC4).
    info "Read-only — issue management skipped (APPLY=$APPLY, DRY_RUN=$DRY_RUN). Planned actions:"
    print_planned_issue_actions
  else
    info "Skipping issue creation (CREATE_ISSUES=$CREATE_ISSUES)"
  fi

  # Write issue-management counts and append to summary (conditional on issue management running)
  if mutations_enabled && [ "$CREATE_ISSUES" = "true" ]; then
    printf '{"added":%d,"existing":%d,"removed":%d,"retriggered":%d}\n' \
      "$ISSUES_ADDED" "$ISSUES_EXISTING" "$ISSUES_REMOVED" "$ISSUES_RETRIGGERED" > "$ISSUE_COUNTS_FILE"
    cat >> "$SUMMARY_FILE" <<HEREDOC

## Issue Management

| Action | Count |
|--------|-------|
| Added (new) | $ISSUES_ADDED |
| Existing (updated) | $ISSUES_EXISTING |
| Re-triggered (dev-lead re-engaged) | $ISSUES_RETRIGGERED |
| Removed (resolved) | $ISSUES_REMOVED |
HEREDOC
  else
    printf '{"added":0,"existing":0,"removed":0,"retriggered":0}\n' > "$ISSUE_COUNTS_FILE"
    cat >> "$SUMMARY_FILE" <<HEREDOC

## Issue Management

_Issue management was skipped — read-only (APPLY=$APPLY, DRY\_RUN=$DRY_RUN, CREATE\_ISSUES=$CREATE_ISSUES)._
HEREDOC
  fi

  # Append footer (always last)
  cat >> "$SUMMARY_FILE" <<HEREDOC

---
*Generated by the [weekly compliance audit](https://github.com/$ORG/.github/blob/main/.github/workflows/compliance-audit.yml) on $(date -u "+%Y-%m-%d %H:%M UTC").*
HEREDOC

  # Output report paths
  echo "findings=$FINDINGS_FILE"
  echo "summary=$SUMMARY_FILE"

  info "Summary written to $SUMMARY_FILE"
  info "Findings written to $FINDINGS_FILE"

  cat "$SUMMARY_FILE"
}

# Run main only when executed directly, not when sourced (e.g. by bats tests
# that exercise individual helper functions).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
