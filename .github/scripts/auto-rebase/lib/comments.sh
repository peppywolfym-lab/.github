#!/usr/bin/env bash
# Best-effort comment helper for the auto-rebase reusable workflow.
#
# Unlike lib/eligibility.sh (pure predicates), this is a thin I/O wrapper around
# `gh pr comment`. It lives here — rather than inline in the YAML — so its
# non-fatal behavior can be unit-tested with bats
# (see test/workflows/auto-rebase/comments.bats).
#
# Contract: see .github/scripts/auto-rebase/README.md

# auto_rebase_post_comment_best_effort PR_NUMBER REPO BODY
#   Posts BODY as a comment on PR_NUMBER in REPO, best-effort. A comment-side
#   failure — GitHub's 2500-comment cap ("Commenting is disabled on issues with
#   more than 2500 comments"), a secondary rate limit, or a transient 5xx — is
#   logged as a workflow warning and swallowed. Always returns 0.
#
#   Why (issue #594): the reusable's conflict-resolution comment ran unguarded
#   under `bash -e`, so a single capped PR failed the whole step and stopped the
#   other PRs from being rebased. A best-effort notification must never be fatal
#   to the core function of rebasing the other PRs.
auto_rebase_post_comment_best_effort() {
  local pr_number="$1" repo="$2" body="$3"
  gh pr comment "$pr_number" --repo "$repo" --body "$body" \
    || echo "::warning::could not post conflict comment on #$pr_number (comment cap / API error) — continuing" >&2
  return 0
}
