#!/usr/bin/env bats
# Tests for .github/scripts/auto-rebase/lib/eligibility.sh
#
# auto-rebase updates every behind PR (the `all` mode). The predicate is kept
# selectable via a tunable mode so future modes (e.g. a "front-of-queue N")
# can be added without touching the workflow file.

load 'helpers/setup'

setup() {
  # shellcheck source=/dev/null
  . "${TT_SCRIPTS_DIR}/lib/eligibility.sh"
}

# ── auto_rebase_pr_eligible ──────────────────────────────────────────────────

@test "pr_eligible all: every behind PR is eligible" {
  run auto_rebase_pr_eligible all
  [ "$status" -eq 0 ]
}

@test "pr_eligible: unknown mode errors out (exit 2)" {
  run auto_rebase_pr_eligible bogus-mode
  [ "$status" -eq 2 ]
}

@test "pr_eligible: empty mode errors out (exit 2)" {
  run auto_rebase_pr_eligible ""
  [ "$status" -eq 2 ]
}

@test "pr_eligible: the deprecated review-ready mode is treated as 'all' (exit 0)" {
  run auto_rebase_pr_eligible review-ready
  [ "$status" -eq 0 ]
}

# ── dead review-ready/approval plumbing is gone ──────────────────────────────

@test "auto_rebase_has_current_approval is no longer defined" {
  run type -t auto_rebase_has_current_approval
  [ "$status" -ne 0 ]
}

@test "auto_rebase_has_ready_label is no longer defined" {
  run type -t auto_rebase_has_ready_label
  [ "$status" -ne 0 ]
}
