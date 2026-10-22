#!/usr/bin/env bash
# Eligibility predicate for the auto-rebase reusable workflow.
#
# Pure and side-effect-free so it can be unit-tested with bats (see
# test/workflows/auto-rebase/eligibility.bats). The reusable workflow sources
# this file and uses the predicate to decide which behind PRs to update-branch.
#
# Contract: see .github/scripts/auto-rebase/README.md

# auto_rebase_pr_eligible MODE
#   Decides whether a behind PR should be updated. Returns 0 (eligible) or
#   2 (unknown mode).
#
#   Modes (the tunable `eligibility` workflow input):
#     all   every behind PR, including drafts.
#
#   Kept as a mode dispatch so future modes (e.g. a "front-of-queue N") can be
#   added here and selected via the `eligibility` input without changing the
#   workflow file.
auto_rebase_pr_eligible() {
  local mode="$1"
  case "$mode" in
    all)
      return 0
      ;;
    review-ready)
      # Deprecated alias: review-ready was removed in issue #927; treat as `all`
      # so existing callers continue to work without breaking.
      echo "auto_rebase_pr_eligible: 'review-ready' is deprecated and will be removed; use 'all' instead" >&2
      return 0
      ;;
    *)
      echo "auto_rebase_pr_eligible: unknown eligibility mode '$mode'" >&2
      return 2
      ;;
  esac
}
