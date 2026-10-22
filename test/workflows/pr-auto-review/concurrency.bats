#!/usr/bin/env bats
# Tests for the caller-stub workflow-level `concurrency:` block that deduplicates
# ONLY the default-branch-context Ready Check triggers (issue #1126).
#
# Background: on GitHub Free (20 concurrent jobs, org-wide) the Ready Check stub
# had NO concurrency and fanned out per trigger. Its runs split by trigger:
#   • check_suite / workflow_run — head_branch=main, default-branch context, the
#     check does NOT attach to the PR head, so superseding these is SAFE.
#   • pull_request / pull_request_review — run on the PR head; a cancelled run
#     would leave a cancelled `pr-auto-review / check-and-dispatch` check on the
#     PR head (the #1422/#1427 stranding shape), so these MUST stay unique.
#
# The block therefore keys check_suite + workflow_run on the PR number (shared,
# cancel-in-progress: true) and gives every PR-context run — and any
# default-branch trigger with no associated PR (fork / no PR) — a unique group.

load 'helpers/setup'

STUB="${TT_REPO_ROOT}/standards/workflows/pr-auto-review.yml"
LIVE="${TT_REPO_ROOT}/.github/workflows/pr-auto-review.yml"

# Exact, pinned expressions. yq folds the `>-` block scalar to one space-joined
# line, so these are the precise resolved strings the stub must carry. Pinning
# them guarantees the live YAML implements exactly the logic the resolver
# functions below describe.
GROUP_EXPR="\${{ (github.event_name == 'check_suite' && github.event.check_suite.pull_requests[0].number) && format('pr-auto-review-ready-check-pr-{0}', github.event.check_suite.pull_requests[0].number) || (github.event_name == 'workflow_run' && github.event.workflow_run.pull_requests[0].number) && format('pr-auto-review-ready-check-pr-{0}', github.event.workflow_run.pull_requests[0].number) || format('pr-auto-review-ready-check-unique-{0}', github.run_id) }}"

CANCEL_EXPR="\${{ github.event_name == 'check_suite' || github.event_name == 'workflow_run' }}"

# resolve_group / resolve_cancel encode the specified behavior of the pinned
# expressions above. <event> <pr-number-or-empty> <run-id>.
resolve_group() {
  local event="$1" pr="$2" run_id="$3"
  if { [ "$event" = "check_suite" ] || [ "$event" = "workflow_run" ]; } && [ -n "$pr" ]; then
    printf 'pr-auto-review-ready-check-pr-%s' "$pr"
  else
    printf 'pr-auto-review-ready-check-unique-%s' "$run_id"
  fi
}

resolve_cancel() {
  local event="$1"
  if [ "$event" = "check_suite" ] || [ "$event" = "workflow_run" ]; then
    echo "true"
  else
    echo "false"
  fi
}

# --------------------------------------------------------------------------
# The stub carries the concurrency block and the two expressions are pinned.
# --------------------------------------------------------------------------

@test "stub: defines a workflow-level concurrency block" {
  run yq -r '.concurrency | has("group")' "$STUB"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "stub: group expression is exactly the PR-keyed / unique-fallback expression" {
  run yq -r '.concurrency.group' "$STUB"
  [ "$status" -eq 0 ]
  [ "$output" = "$GROUP_EXPR" ]
}

@test "stub: cancel-in-progress is true only for the two default-branch-context events" {
  run yq -r '.concurrency.cancel-in-progress' "$STUB"
  [ "$status" -eq 0 ]
  [ "$output" = "$CANCEL_EXPR" ]
}

# --------------------------------------------------------------------------
# The group expression uses the correct per-event pull_requests[0].number path.
# --------------------------------------------------------------------------

@test "stub: check_suite branch reads github.event.check_suite.pull_requests[0].number" {
  run yq -r '.concurrency.group' "$STUB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"github.event.check_suite.pull_requests[0].number"* ]]
}

@test "stub: workflow_run branch reads github.event.workflow_run.pull_requests[0].number" {
  run yq -r '.concurrency.group' "$STUB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"github.event.workflow_run.pull_requests[0].number"* ]]
}

@test "stub: fallback group is unique per run (github.run_id)" {
  run yq -r '.concurrency.group' "$STUB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"format('pr-auto-review-ready-check-unique-{0}', github.run_id)"* ]]
}

@test "stub: PR-context events are NOT keyed on a pull_request number (they hit the unique fallback)" {
  run yq -r '.concurrency.group' "$STUB"
  [ "$status" -eq 0 ]
  # neither pull_request nor pull_request_review appear in the group expression,
  # so both fall through to the unique-per-run fallback.
  [[ "$output" != *"pull_request.number"* ]]
  [[ "$output" != *"event.pull_request"* ]]
}

# --------------------------------------------------------------------------
# Resolved group + cancel for each of the four events (spec behavior).
# --------------------------------------------------------------------------

@test "resolve: check_suite with PR #1793 dedupes on the PR number and cancels in progress" {
  [ "$(resolve_group check_suite 1793 42)" = "pr-auto-review-ready-check-pr-1793" ]
  [ "$(resolve_cancel check_suite)" = "true" ]
}

@test "resolve: workflow_run with PR #1793 shares the SAME group as check_suite and cancels" {
  # both default-branch-context events collapse onto one group per PR
  [ "$(resolve_group workflow_run 1793 99)" = "pr-auto-review-ready-check-pr-1793" ]
  [ "$(resolve_group workflow_run 1793 99)" = "$(resolve_group check_suite 1793 42)" ]
  [ "$(resolve_cancel workflow_run)" = "true" ]
}

@test "resolve: pull_request gets a unique-per-run group and never cancels" {
  [ "$(resolve_group pull_request "" 55)" = "pr-auto-review-ready-check-unique-55" ]
  [ "$(resolve_cancel pull_request)" = "false" ]
}

@test "resolve: pull_request_review gets a unique-per-run group and never cancels" {
  [ "$(resolve_group pull_request_review "" 77)" = "pr-auto-review-ready-check-unique-77" ]
  [ "$(resolve_cancel pull_request_review)" = "false" ]
}

@test "resolve: check_suite with NO associated PR falls back to a unique-per-run group" {
  [ "$(resolve_group check_suite "" 123)" = "pr-auto-review-ready-check-unique-123" ]
}

@test "resolve: two different PRs never collapse into one group" {
  [ "$(resolve_group check_suite 1793 1)" != "$(resolve_group check_suite 1794 1)" ]
}

# --------------------------------------------------------------------------
# Template and this repo's live copy carry an identical concurrency block, so
# a standards resync will not revert it and the surface-drift guard stays clean.
# --------------------------------------------------------------------------

@test "live copy: group expression matches the template exactly" {
  run yq -r '.concurrency.group' "$LIVE"
  [ "$status" -eq 0 ]
  [ "$output" = "$GROUP_EXPR" ]
}

@test "live copy: cancel-in-progress matches the template exactly" {
  run yq -r '.concurrency.cancel-in-progress' "$LIVE"
  [ "$status" -eq 0 ]
  [ "$output" = "$CANCEL_EXPR" ]
}
