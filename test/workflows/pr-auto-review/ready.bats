#!/usr/bin/env bats
# Decision-matrix tests for pr_auto_review_ready in
# .github/scripts/pr-auto-review/lib/ready-check.sh
#
# pr_auto_review_ready is the unified pure core for the pr-auto-review readiness
# gate (issue #686 / #668 increment 5). It folds all four readiness criteria into
# one side-effect-free function so the reusable workflow is thin I/O glue:
#
#   pr_auto_review_ready STATE IS_DRAFT CHECKS_JSON REQUIRED_JSON \
#                        SELF_CHECK REVIEW_DECISION UNRESOLVED_COUNT
#
# It prints the decision class on stdout (one of: skip-draft,
# skip-checks-pending, skip-changes-requested, skip-unresolved-threads,
# dispatched) — the classes Layer 2 decision-telemetry consumes — and returns 0
# iff the PR is ready to dispatch (decision == dispatched), 1 otherwise.
#
# Pins the #680 required-vs-non-required gate through the unified core.

load 'helpers/setup'

setup() {
  # shellcheck source=/dev/null
  . "${TT_SCRIPTS_DIR}/lib/ready-check.sh"
}

# Convenience wrapper: an all-green single-required-check payload for the cases
# that only vary one dimension away from the happy path.
GREEN_CHECKS='[{"name":"CI / Lint","bucket":"pass"}]'
REQUIRED='["Lint"]'

# ── happy path ───────────────────────────────────────────────────────────────

@test "ready: open, non-draft, required green, no CHANGES_REQUESTED, 0 unresolved → dispatched" {
  run pr_auto_review_ready "OPEN" "false" "$GREEN_CHECKS" "$REQUIRED" "" "APPROVED" "0"
  [ "$status" -eq 0 ]
  [ "$output" = "dispatched" ]
}

@test "ready: empty review decision (no reviews yet) still dispatches" {
  run pr_auto_review_ready "OPEN" "false" "$GREEN_CHECKS" "$REQUIRED" "" "" "0"
  [ "$status" -eq 0 ]
  [ "$output" = "dispatched" ]
}

# ── criterion #1: open + not draft ───────────────────────────────────────────

@test "not ready: draft → skip-draft" {
  run pr_auto_review_ready "OPEN" "true" "$GREEN_CHECKS" "$REQUIRED" "" "APPROVED" "0"
  [ "$status" -eq 1 ]
  [ "$output" = "skip-draft" ]
}

@test "not ready: closed PR → skip-draft" {
  run pr_auto_review_ready "CLOSED" "false" "$GREEN_CHECKS" "$REQUIRED" "" "APPROVED" "0"
  [ "$status" -eq 1 ]
  [ "$output" = "skip-draft" ]
}

@test "not ready: merged PR → skip-draft" {
  run pr_auto_review_ready "MERGED" "false" "$GREEN_CHECKS" "$REQUIRED" "" "APPROVED" "0"
  [ "$status" -eq 1 ]
  [ "$output" = "skip-draft" ]
}

# ── criterion #2: required checks passing (delegates to checks_ready, #680) ───

@test "not ready: a required check is pending → skip-checks-pending" {
  run pr_auto_review_ready "OPEN" "false" \
    '[{"name":"CI / Lint","bucket":"pending"}]' "$REQUIRED" "" "APPROVED" "0"
  [ "$status" -eq 1 ]
  [ "$output" = "skip-checks-pending" ]
}

@test "not ready: a required check is failing → skip-checks-pending" {
  run pr_auto_review_ready "OPEN" "false" \
    '[{"name":"CI / Lint","bucket":"fail"}]' "$REQUIRED" "" "APPROVED" "0"
  [ "$status" -eq 1 ]
  [ "$output" = "skip-checks-pending" ]
}

@test "not ready: a required context has no check reported yet → skip-checks-pending" {
  run pr_auto_review_ready "OPEN" "false" \
    '[{"name":"CI / Lint","bucket":"pass"}]' '["Lint","ShellCheck"]' "" "APPROVED" "0"
  [ "$status" -eq 1 ]
  [ "$output" = "skip-checks-pending" ]
}

@test "not ready: no checks at all → skip-checks-pending" {
  run pr_auto_review_ready "OPEN" "false" '[]' "$REQUIRED" "" "APPROVED" "0"
  [ "$status" -eq 1 ]
  [ "$output" = "skip-checks-pending" ]
}

@test "not ready: empty checks string normalized → skip-checks-pending" {
  run pr_auto_review_ready "OPEN" "false" "" "$REQUIRED" "" "APPROVED" "0"
  [ "$status" -eq 1 ]
  [ "$output" = "skip-checks-pending" ]
}

@test "not ready: null or malformed checks string → skip-checks-pending" {
  run pr_auto_review_ready "OPEN" "false" "null" "$REQUIRED" "" "APPROVED" "0"
  [ "$status" -eq 1 ]
  [ "$output" = "skip-checks-pending" ]

  run pr_auto_review_ready "OPEN" "false" "invalid-json" "$REQUIRED" "" "APPROVED" "0"
  [ "$status" -eq 1 ]
  [ "$output" = "skip-checks-pending" ]
}

# #680: a NON-required failing/cancelled advisory must NOT block dispatch.
@test "ready: required green + NON-required cancelled/failing advisory → dispatched" {
  run pr_auto_review_ready "OPEN" "false" \
    '[{"name":"CI / Lint","bucket":"pass"},{"name":"dev-lead / ci-relay","bucket":"cancel"},{"name":"some-advisory","bucket":"fail"}]' \
    "$REQUIRED" "" "APPROVED" "0"
  [ "$status" -eq 0 ]
  [ "$output" = "dispatched" ]
}

# REQ: required-only gate ignores cancelled dev-lead orchestration checks and non-required failing checks, dispatching when all REQUIRED contexts are green
# #884 fleet-convergence repro (the exact "main blocker" fact pattern): a
# standards-sync PR whose REQUIRED contexts are all green, carrying BOTH
# concurrency-churn cancelled dev-lead orchestration checks
# (`dev-lead / dispatch` + `dev-lead / ci-relay`) AND a non-required failing
# advisory (mirroring ContentTwin `Test` / google-app-scripts `autofix`). The
# required-only gate must ignore all three non-required contexts and dispatch —
# so the pr-auto-review path never reads CANCELLED (or a non-required FAILURE) as
# a merge-readiness blocker.
@test "ready: #884 convergence — required green + cancelled dev-lead pair + non-required failure → dispatched" {
  run pr_auto_review_ready "OPEN" "false" \
    '[{"name":"CI / Lint","bucket":"pass"},{"name":"dev-lead / dispatch","bucket":"cancel"},{"name":"dev-lead / ci-relay","bucket":"cancel"},{"name":"Test","bucket":"fail"}]' \
    "$REQUIRED" "" "" "0"
  [ "$status" -eq 0 ]
  [ "$output" = "dispatched" ]
}

# ── criterion #3: review decision ────────────────────────────────────────────

@test "not ready: CHANGES_REQUESTED → skip-changes-requested" {
  run pr_auto_review_ready "OPEN" "false" "$GREEN_CHECKS" "$REQUIRED" "" "CHANGES_REQUESTED" "0"
  [ "$status" -eq 1 ]
  [ "$output" = "skip-changes-requested" ]
}

# ── criterion #4: unresolved review threads ──────────────────────────────────

@test "not ready: 1 unresolved thread → skip-unresolved-threads" {
  run pr_auto_review_ready "OPEN" "false" "$GREEN_CHECKS" "$REQUIRED" "" "APPROVED" "1"
  [ "$status" -eq 1 ]
  [ "$output" = "skip-unresolved-threads" ]
}

@test "not ready: several unresolved threads → skip-unresolved-threads" {
  run pr_auto_review_ready "OPEN" "false" "$GREEN_CHECKS" "$REQUIRED" "" "APPROVED" "5"
  [ "$status" -eq 1 ]
  [ "$output" = "skip-unresolved-threads" ]
}

# ── precedence: earlier criteria win over later ones ─────────────────────────

@test "precedence: draft + CHANGES_REQUESTED → skip-draft (criterion #1 first)" {
  run pr_auto_review_ready "OPEN" "true" "$GREEN_CHECKS" "$REQUIRED" "" "CHANGES_REQUESTED" "3"
  [ "$status" -eq 1 ]
  [ "$output" = "skip-draft" ]
}

@test "precedence: pending required check + CHANGES_REQUESTED → skip-checks-pending (criterion #2 before #3)" {
  run pr_auto_review_ready "OPEN" "false" \
    '[{"name":"CI / Lint","bucket":"pending"}]' "$REQUIRED" "" "CHANGES_REQUESTED" "0"
  [ "$status" -eq 1 ]
  [ "$output" = "skip-checks-pending" ]
}

@test "precedence: CHANGES_REQUESTED + unresolved threads → skip-changes-requested (criterion #3 before #4)" {
  run pr_auto_review_ready "OPEN" "false" "$GREEN_CHECKS" "$REQUIRED" "" "CHANGES_REQUESTED" "2"
  [ "$status" -eq 1 ]
  [ "$output" = "skip-changes-requested" ]
}

# ── self-check exclusion flows through to the unified core ────────────────────

@test "ready: this workflow's own pending check is excluded via SELF_CHECK" {
  run pr_auto_review_ready "OPEN" "false" \
    '[{"name":"CI / Lint","bucket":"pass"},{"name":"PR Auto-Review — Ready Check","bucket":"pending"}]' \
    "$REQUIRED" "PR Auto-Review — Ready Check" "APPROVED" "0"
  [ "$status" -eq 0 ]
  [ "$output" = "dispatched" ]
}
