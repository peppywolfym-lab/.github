#!/usr/bin/env bats
# Tests for the caller-stub surface-drift guard in scripts/compliance-audit.sh
# (issue #607): stub_extract_blocks / stub_normalize_surface / stub_surface_drift.
#
# The centralized caller stubs (dev-lead + the RING reusables) are thin: their
# behavior lives in the reusable, so three surfaces are NOT repo-adjustable — the
# `on:` trigger set, the `permissions:` grants, and the (usually absent)
# `concurrency:` block. The field-allowlist pin checks never inspect those
# surfaces, so a stub that trims a trigger, widens/narrows a permission, or
# injects a per-stub concurrency group drifts silently. This guard catches it.
#
# These surfaces carry NO channel pin (the tier pin lives only on the
# jobs.<id>.uses / agent_ref lines), so a stub that differs from the canonical
# ONLY by its correct tier channel pin has identical surfaces and is never
# flagged. The tests below assert both directions.
#
# The script is sourced in an isolated subshell (its `main` is guarded, so
# sourcing only defines functions) and the real pure helpers are exercised.

bats_require_minimum_version 1.5.0

SCRIPT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/scripts/compliance-audit.sh"

# stub_surface_drift returns status 0 when drift IS detected, non-zero when the
# surface is clean.
surface_drift() {
  run bash -c 'source "$1" >/dev/null 2>&1; stub_surface_drift "$2" "$3" "$4"' \
    _ "$SCRIPT" "$1" "$2" "$3"
}

extract_blocks() {
  run bash -c 'source "$1" >/dev/null 2>&1; stub_extract_blocks "$2" "$3"' \
    _ "$SCRIPT" "$1" "$2"
}

# ---------------------------------------------------------------------------
# Fixtures — trimmed but realistic canonical stubs for the guarded surfaces.
# ---------------------------------------------------------------------------

DEV_LEAD_CANONICAL=$(cat <<'EOF'
name: Dev-Lead Agent

on:
  pull_request:
    branches: [main]
    types: [opened, reopened, synchronize]
  issue_comment:
    types: [created]
  issues:
    types: [labeled]

permissions: {}

jobs:
  dev-lead:
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/stable  # NOSONAR
    with:
      agent_ref: dev-lead/stable
    secrets: inherit
    permissions:
      contents: write
      issues: write
      statuses: read
EOF
)

AGENT_SHIELD_CANONICAL=$(cat <<'EOF'
name: AgentShield

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read

jobs:
  agent-shield:
    uses: petry-projects/.github/.github/workflows/agent-shield-reusable.yml@agent-shield/stable  # NOSONAR
EOF
)

FEATURE_IDEATION_CANONICAL=$(cat <<'EOF'
name: Feature Research & Ideation

on:
  schedule:
    - cron: '0 7 * * 5' # Friday 07:00 UTC
  workflow_dispatch:
    inputs:
      focus_area:
        required: false
        type: string
  discussion:
    types: [created]

permissions: {}

concurrency:
  group: feature-ideation
  cancel-in-progress: false

jobs:
  ideate:
    permissions:
      contents: read
      discussions: write
    uses: petry-projects/.github/.github/workflows/feature-ideation-reusable.yml@feature-ideation/stable  # NOSONAR
    with:
      project_context: |
        TODO: Replace with a description of the project.
EOF
)

PR_AUTO_REVIEW_CANONICAL=$(cat <<'EOF'
name: PR Auto-Review — Ready Check

on:
  # TODO: replace "CI" with your repository's CI workflow name(s).
  workflow_run:
    workflows: ["CI"]
    types: [completed]
  check_suite:
    types: [completed]
  pull_request_review:
    types: [submitted, dismissed]
  pull_request:
    types: [opened, reopened, synchronize, ready_for_review]

permissions: {}

jobs:
  pr-auto-review:
    permissions:
      pull-requests: read
      checks: read
      actions: read
    uses: petry-projects/.github/.github/workflows/pr-auto-review-reusable.yml@pr-auto-review/v1-stable  # NOSONAR
    secrets:
      GH_PAT_WORKFLOWS: ${{ secrets.GH_PAT_DON_PETRY || secrets.GH_PAT_WORKFLOWS }}
EOF
)

# ---------------------------------------------------------------------------
# AC2 — a stub that differs ONLY by its correct tier channel pin is clean on
# every guarded surface (the pin lives outside on:/permissions/concurrency).
# ---------------------------------------------------------------------------

@test "dev-lead: ring1-repinned stub is clean on the on: surface (tier pin only)" {
  local deployed="${DEV_LEAD_CANONICAL//dev-lead\/stable/dev-lead/ring1}"
  surface_drift "$DEV_LEAD_CANONICAL" "$deployed" "on"
  [ "$status" -ne 0 ]
}

@test "agent-shield: ring1-repinned stub is clean on all three surfaces (tier pin only)" {
  local deployed="${AGENT_SHIELD_CANONICAL//agent-shield\/stable/agent-shield/ring1}"
  surface_drift "$AGENT_SHIELD_CANONICAL" "$deployed" "on"
  [ "$status" -ne 0 ]
  surface_drift "$AGENT_SHIELD_CANONICAL" "$deployed" "permissions"
  [ "$status" -ne 0 ]
  surface_drift "$AGENT_SHIELD_CANONICAL" "$deployed" "concurrency"
  [ "$status" -ne 0 ]
}

@test "an unmodified stub is clean on every guarded surface" {
  local s
  for s in on permissions concurrency; do
    surface_drift "$DEV_LEAD_CANONICAL" "$DEV_LEAD_CANONICAL" "$s"
    [ "$status" -ne 0 ]
    surface_drift "$FEATURE_IDEATION_CANONICAL" "$FEATURE_IDEATION_CANONICAL" "$s"
    [ "$status" -ne 0 ]
  done
}

# ---------------------------------------------------------------------------
# AC1 — a trimmed on: trigger surface is flagged.
# ---------------------------------------------------------------------------

@test "dev-lead: dropping the issues: trigger is flagged (trimmed on:)" {
  local deployed
  deployed=$(printf '%s\n' "$DEV_LEAD_CANONICAL" | sed '/^  issues:$/,/^    types: \[labeled\]$/d')
  # sanity: the trigger really was removed
  ! grep -q '^  issues:$' <<< "$deployed"
  surface_drift "$DEV_LEAD_CANONICAL" "$deployed" "on"
  [ "$status" -eq 0 ]
}

@test "dev-lead: narrowing pull_request types is flagged (trimmed on:)" {
  local deployed
  deployed=$(printf '%s\n' "$DEV_LEAD_CANONICAL" | sed 's/\[opened, reopened, synchronize\]/[opened]/')
  # sanity: the types list really was narrowed
  [ "$deployed" != "$DEV_LEAD_CANONICAL" ]
  surface_drift "$DEV_LEAD_CANONICAL" "$deployed" "on"
  [ "$status" -eq 0 ]
}

@test "feature-ideation: dropping the discussion: trigger is flagged (trimmed on:)" {
  local deployed
  deployed=$(printf '%s\n' "$FEATURE_IDEATION_CANONICAL" | sed '/^  discussion:$/,/^    types: \[created\]$/d')
  surface_drift "$FEATURE_IDEATION_CANONICAL" "$deployed" "on"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# feature-ideation's per-repo cron retune is NOT trigger-surface drift — the
# header documents it as an allowed customization, so cron VALUES are normalized.
# ---------------------------------------------------------------------------

@test "feature-ideation: retuning the schedule cron is NOT flagged" {
  local deployed="${FEATURE_IDEATION_CANONICAL/0 7 * * 5/30 13 * * 1}"
  # sanity: the cron value really did change
  [ "$deployed" != "$FEATURE_IDEATION_CANONICAL" ]
  surface_drift "$FEATURE_IDEATION_CANONICAL" "$deployed" "on"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# pr-auto-review's per-repo workflow_run.workflows name is NOT trigger-surface
# drift — the template header + TODO document it as an allowed customization
# (a repo MUST name its own CI workflow), so the workflows list VALUE is
# normalized. The rest of the on: surface stays verbatim-locked (#990).
# ---------------------------------------------------------------------------

@test "pr-auto-review: renaming the workflow_run.workflows value is NOT flagged" {
  local deployed="${PR_AUTO_REVIEW_CANONICAL/\[\"CI\"\]/[\"CI Pipeline\"]}"
  # sanity: the workflows list really did change
  [ "$deployed" != "$PR_AUTO_REVIEW_CANONICAL" ]
  surface_drift "$PR_AUTO_REVIEW_CANONICAL" "$deployed" "on"
  [ "$status" -eq 1 ]
}

@test "pr-auto-review: a multi-name workflow_run.workflows list is NOT flagged" {
  local deployed="${PR_AUTO_REVIEW_CANONICAL/\[\"CI\"\]/[\"CI\", \"Lint\"]}"
  # sanity: the workflows list really did change
  [ "$deployed" != "$PR_AUTO_REVIEW_CANONICAL" ]
  surface_drift "$PR_AUTO_REVIEW_CANONICAL" "$deployed" "on"
  [ "$status" -eq 1 ]
}

@test "pr-auto-review: naming the workflow_run.workflows as a block-sequence list is NOT flagged" {
  # A repo MAY name its CI workflow(s) in either YAML list form. The block-sequence
  # form is just as valid as the inline flow form and must not count as on: drift.
  local deployed
  deployed=$(printf '%s\n' "$PR_AUTO_REVIEW_CANONICAL" | sed -E 's/^(  workflow_run:)$/\1\n    workflows:\n      - "CI Pipeline"/; /^    workflows: \["CI"\]$/d')
  # sanity: the inline form is gone and a block-sequence entry is present
  ! grep -q 'workflows: \["CI"\]' <<< "$deployed"
  grep -q '^      - "CI Pipeline"$' <<< "$deployed"
  surface_drift "$PR_AUTO_REVIEW_CANONICAL" "$deployed" "on"
  [ "$status" -eq 1 ]
}

@test "pr-auto-review: a multi-name block-sequence workflows list is NOT flagged" {
  local deployed
  deployed=$(printf '%s\n' "$PR_AUTO_REVIEW_CANONICAL" | sed -E 's/^(  workflow_run:)$/\1\n    workflows:\n      - CI\n      - Lint/; /^    workflows: \["CI"\]$/d')
  ! grep -q 'workflows: \["CI"\]' <<< "$deployed"
  grep -q '^      - Lint$' <<< "$deployed"
  surface_drift "$PR_AUTO_REVIEW_CANONICAL" "$deployed" "on"
  [ "$status" -eq 1 ]
}

@test "pr-auto-review: block-sequence workflows with a blank line before the first entry is NOT flagged" {
  # A blank line (or a stripped comment) between the workflows: key and the first
  # block-sequence entry must not prematurely flush the pending block.
  local deployed
  deployed=$(printf '%s\n' "$PR_AUTO_REVIEW_CANONICAL" | sed -E 's/^(  workflow_run:)$/\1\n    workflows:\n\n      - "CI Pipeline"/; /^    workflows: \["CI"\]$/d')
  # sanity: inline form gone; blank line present between key and entry
  ! grep -q 'workflows: \["CI"\]' <<< "$deployed"
  grep -q '^      - "CI Pipeline"$' <<< "$deployed"
  surface_drift "$PR_AUTO_REVIEW_CANONICAL" "$deployed" "on"
  [ "$status" -eq 1 ]
}

@test "pr-auto-review: an empty block-sequence workflows list (no entries) is flagged" {
  # workflows: with no list entries names nothing — not a valid customization.
  local deployed
  deployed=$(printf '%s\n' "$PR_AUTO_REVIEW_CANONICAL" | sed -E 's/^    workflows: \["CI"\]$/    workflows:/')
  ! grep -q 'workflows: \["CI"\]' <<< "$deployed"
  surface_drift "$PR_AUTO_REVIEW_CANONICAL" "$deployed" "on"
  [ "$status" -eq 0 ]
}

@test "pr-auto-review: dropping the check_suite: trigger is still flagged (rest of on: stays locked)" {
  local deployed
  deployed=$(printf '%s\n' "$PR_AUTO_REVIEW_CANONICAL" | sed '/^  check_suite:$/,/^    types: \[completed\]$/d')
  # sanity: the trigger really was removed
  ! grep -q '^  check_suite:$' <<< "$deployed"
  surface_drift "$PR_AUTO_REVIEW_CANONICAL" "$deployed" "on"
  [ "$status" -eq 0 ]
}

@test "pr-auto-review: removing the whole workflow_run: block is still flagged (trigger key not adjustable)" {
  local deployed
  deployed=$(printf '%s\n' "$PR_AUTO_REVIEW_CANONICAL" | sed '/^  workflow_run:$/,/^    types: \[completed\]$/d')
  # sanity: the workflow_run trigger key really was removed
  ! grep -q '^  workflow_run:$' <<< "$deployed"
  surface_drift "$PR_AUTO_REVIEW_CANONICAL" "$deployed" "on"
  [ "$status" -eq 0 ]
}

@test "pr-auto-review: workflows: [] (empty inline list) is flagged (not a valid list shape)" {
  local deployed="${PR_AUTO_REVIEW_CANONICAL/workflows: \[\"CI\"\]/workflows: []}"
  [ "$deployed" != "$PR_AUTO_REVIEW_CANONICAL" ]
  surface_drift "$PR_AUTO_REVIEW_CANONICAL" "$deployed" "on"
  [ "$status" -eq 0 ]
}

@test "pr-auto-review: workflows: null is flagged (not a valid list shape)" {
  local deployed="${PR_AUTO_REVIEW_CANONICAL/workflows: \[\"CI\"\]/workflows: null}"
  [ "$deployed" != "$PR_AUTO_REVIEW_CANONICAL" ]
  surface_drift "$PR_AUTO_REVIEW_CANONICAL" "$deployed" "on"
  [ "$status" -eq 0 ]
}

@test "pr-auto-review: workflows: CI (bare string) is flagged (not a valid list shape)" {
  local deployed="${PR_AUTO_REVIEW_CANONICAL/workflows: \[\"CI\"\]/workflows: CI}"
  [ "$deployed" != "$PR_AUTO_REVIEW_CANONICAL" ]
  surface_drift "$PR_AUTO_REVIEW_CANONICAL" "$deployed" "on"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# permissions surface — added or removed permission is flagged.
# ---------------------------------------------------------------------------

@test "agent-shield: adding a permission is flagged" {
  local deployed="${AGENT_SHIELD_CANONICAL/  contents: read/  contents: read
  issues: read}"
  surface_drift "$AGENT_SHIELD_CANONICAL" "$deployed" "permissions"
  [ "$status" -eq 0 ]
}

@test "agent-shield: removing a permission is flagged" {
  local deployed="${AGENT_SHIELD_CANONICAL/permissions:
  contents: read/permissions: {\}}"
  surface_drift "$AGENT_SHIELD_CANONICAL" "$deployed" "permissions"
  [ "$status" -eq 0 ]
}

@test "dev-lead: removing statuses: read from the job permissions is flagged" {
  local deployed
  deployed=$(printf '%s\n' "$DEV_LEAD_CANONICAL" | sed '/^      statuses: read$/d')
  surface_drift "$DEV_LEAD_CANONICAL" "$deployed" "permissions"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# concurrency surface — injecting a per-stub concurrency block is flagged;
# retaining the canonical block (feature-ideation) is clean; changing it drifts.
# ---------------------------------------------------------------------------

@test "agent-shield: injecting a per-stub concurrency block is flagged" {
  local deployed="${AGENT_SHIELD_CANONICAL/permissions:
  contents: read/permissions:
  contents: read

concurrency:
  group: agent-shield-\${{ github.ref \}}
  cancel-in-progress: true}"
  surface_drift "$AGENT_SHIELD_CANONICAL" "$deployed" "concurrency"
  [ "$status" -eq 0 ]
}

@test "feature-ideation: retaining the canonical concurrency block is clean" {
  surface_drift "$FEATURE_IDEATION_CANONICAL" "$FEATURE_IDEATION_CANONICAL" "concurrency"
  [ "$status" -ne 0 ]
}

@test "feature-ideation: changing the concurrency group is flagged" {
  local deployed="${FEATURE_IDEATION_CANONICAL/group: feature-ideation/group: my-custom-group}"
  surface_drift "$FEATURE_IDEATION_CANONICAL" "$deployed" "concurrency"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# stub_extract_blocks — captures every block for a key at any depth, so a stub
# with both a top-level and a nested job-level permissions: block is compared in
# full (dev-lead's shape).
# ---------------------------------------------------------------------------

@test "extract_blocks captures both the top-level and job-level permissions blocks" {
  extract_blocks "$DEV_LEAD_CANONICAL" "permissions"
  [ "$status" -eq 0 ]
  # top-level empty mapping
  grep -q 'permissions: {}' <<< "$output"
  # job-level grants
  grep -q 'contents: write' <<< "$output"
  grep -q 'statuses: read' <<< "$output"
}

@test "extract_blocks returns nothing for a concurrency key that is absent" {
  extract_blocks "$AGENT_SHIELD_CANONICAL" "concurrency"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "extract_blocks does not treat a comment line as the concurrency key" {
  local content
  content=$(cat <<'EOF'
name: X
# concurrency: is centralised in the reusable — see #402
permissions: {}
EOF
)
  extract_blocks "$content" "concurrency"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
