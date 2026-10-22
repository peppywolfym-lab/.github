#!/usr/bin/env bash
# Candidate-selection logic for the pr-auto-review catch-up sweep (issue #868).
#
# Pure, side-effect-free — unit-tested with bats
# (test/workflows/pr-auto-review/sweep.bats). The sweep workflow gathers the
# open standards-sync PR list via `gh search prs` and hands it here to pick the
# bounded set of PRs to (re-)evaluate this cycle. The per-PR readiness decision
# is NOT re-implemented: the orchestrator (sweep-dispatch.sh) feeds each URL
# through pr_auto_review_ready, so the #680 required-vs-non-required tolerance
# is inherited verbatim.
#
# Contract: see .github/scripts/pr-auto-review/README.md
# Pins issue #868.

# pr_auto_review_sweep_candidates MAX
#   Reads a PR-list JSON array on stdin — the response of
#   `gh search prs --json url,isDraft` (each element has .url and .isDraft) —
#   and prints, one per line, up to MAX candidate PR URLs to evaluate this
#   sweep cycle. Draft PRs (`.isDraft == true`) are dropped; the rest are
#   emitted in input order, capped at MAX for per-run back-pressure.
#
#   MAX      the maximum number of PRs to process this run (back-pressure). A
#            non-positive or non-numeric MAX emits nothing — the sweep does no
#            work rather than fire an unbounded burst of dispatches.
#
#   A missing `.isDraft` is treated as non-draft (fail-open on the field, since
#   `gh search prs --json isDraft` always populates it; a bare `{url}` from a
#   hand-built payload should still be swept). Non-array input (e.g. a
#   `{"message": "Not Found"}` error body) or empty stdin emits nothing.
#   Always returns 0; the caller decides what an empty candidate set means.
pr_auto_review_sweep_candidates() {
  local max="${1:-0}"

  # Back-pressure guard: only a positive integer bounds the run. Anything else
  # (0, negative, non-numeric) selects nothing so a misconfigured cap can never
  # fire an unbounded dispatch burst.
  if ! [[ "$max" =~ ^[0-9]+$ ]] || [ "$max" -le 0 ]; then
    return 0
  fi

  jq -r --argjson max "$max" '
    if type == "array" then
      [ .[] | select(.isDraft != true) | .url | select(type == "string") ][:$max][]
    else
      empty
    end
  '
}
