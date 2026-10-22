#!/usr/bin/env bats
# Confirms AC4 of issue #926 (tracked by #928): a DIRTY (merge-conflict),
# non-draft PR is now actually ATTEMPTED by update-branch — it is no longer
# skipped for lacking an approval — and therefore reaches the existing
# <!-- auto-rebase-conflict: --> sentinel → dev-lead agentic-rebase path.
#
# Since #927 the eligibility default is `all` and the approval / review-ready
# plumbing is gone (see eligibility.bats). These grep-based regression guards
# pin the reusable workflow so the DIRTY → conflict-sentinel path cannot
# silently regress by reintroducing an approval precondition before
# update-branch. They mirror the file-scanning style of merge-method.bats.

load 'helpers/setup'

REUSABLE="${TT_REPO_ROOT}/.github/workflows/auto-rebase-reusable.yml"

@test "conflict-sentinel: reusable workflow file exists" {
  [ -f "$REUSABLE" ]
}

@test "conflict-sentinel: every eligible behind PR is attempted via update-branch" {
  # The DIRTY PR must actually be attempted — the update-branch call is present.
  run grep -E 'pulls/\$\{?PR_NUMBER\}?/update-branch' "$REUSABLE"
  [ "$status" -eq 0 ]
}

@test "conflict-sentinel: update-branch is not gated on an approval / review decision" {
  # A DIRTY PR must not be skipped for lacking an approval (#927 removed this).
  # Guard against reintroducing any review-decision precondition in the reusable.
  # Patterns are scoped to the specific identifiers removed in #927 — broad tokens
  # like /reviews are omitted because they can appear in unrelated comments or API
  # calls and would cause false positives on legitimate refactors.
  run grep -Ei 'reviewDecision|has_current_approval|has_ready_label' "$REUSABLE"
  [ "$status" -eq 1 ]
}

@test "conflict-sentinel: a merge-conflict update failure branches to the conflict path" {
  run grep -i 'merge conflict' "$REUSABLE"
  [ "$status" -eq 0 ]
}

@test "conflict-sentinel: the merge-conflict path posts the <!-- auto-rebase-conflict: --> dev-lead sentinel" {
  run grep -F '<!-- auto-rebase-conflict:' "$REUSABLE"
  [ "$status" -eq 0 ]
}

@test "conflict-sentinel: the weaker one-time <!-- auto-rebase-stuck --> escalation is absent (retired)" {
  # AC4 retires the redundant stuck-comment escalation as dead code. The primary
  # retirement lives in petry-projects/.github-private#711; this guard ensures the
  # weaker sentinel is never (re)introduced into this repo's auto-rebase reusable.
  run grep -F 'auto-rebase-stuck' "$REUSABLE"
  [ "$status" -eq 1 ]
}
