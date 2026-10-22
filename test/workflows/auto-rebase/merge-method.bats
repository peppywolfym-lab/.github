#!/usr/bin/env bats
# Regression guard: the auto-rebase reusable must ALWAYS update behind branches
# with update_method=merge, never rebase.
#
# The API update-branch endpoint with the rebase method rewrites SHAs, which
# confuses CI and invalidates existing approvals; the merge method preserves the
# original commits. This invariant must not regress.

load 'helpers/setup'

REUSABLE="${TT_REPO_ROOT}/.github/workflows/auto-rebase-reusable.yml"

@test "merge-method: reusable workflow file exists" {
  [ -f "$REUSABLE" ]
}

@test "merge-method: update-branch is called with update_method=merge" {
  run grep -F 'update_method=merge' "$REUSABLE"
  [ "$status" -eq 0 ]
}

@test "merge-method: update-branch is never called with the rebase method" {
  run grep -E 'update_method[=:][[:space:]]*rebase' "$REUSABLE"
  [ "$status" -eq 1 ]
}
