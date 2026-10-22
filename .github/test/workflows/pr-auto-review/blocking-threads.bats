#!/usr/bin/env bats
# Tests for pr_auto_review_blocking_thread_count in
# .github/scripts/pr-auto-review/lib/ready-check.sh
#
# Pins issue #806: dev-lead's fix-review cycle addresses an advisory finding in a
# follow-up commit but frequently never marks the corresponding review thread
# resolved, so the PR stalls REVIEW_REQUIRED on the unresolved-threads gate even
# though the code is fixed and CI is green.
#
# Consumer-side, defense-in-depth: a review thread that is unresolved but
# OUTDATED (its anchored diff position no longer exists at HEAD — line changed /
# file moved) no longer blocks auto-dispatch. GitHub sets reviewThread.isOutdated
# when the diff anchor shifts (a heuristic, not proof the concern is fixed), so
# unresolved-but-outdated threads stop blocking without requiring the producer to
# resolve them.
#
# The function reads the `gh api graphql` reviewThreads response on stdin (each
# node exposing .isResolved and .isOutdated) and prints the count of *blocking*
# threads — unresolved AND not outdated.

load 'helpers/setup'

setup() {
  # shellcheck source=/dev/null
  . "${TT_SCRIPTS_DIR}/lib/ready-check.sh"
}

# Build a GraphQL-shaped response from a raw nodes array, matching the shape the
# reusable workflow passes: .data.repository.pullRequest.reviewThreads.nodes
resp() {
  printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":%s}}}}}' "$1"
}

# ── empty / trivial ──────────────────────────────────────────────────────────

@test "blocking count: no threads → 0" {
  run pr_auto_review_blocking_thread_count <<<"$(resp '[]')"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "blocking count: all resolved → 0" {
  run pr_auto_review_blocking_thread_count <<<"$(resp '[{"isResolved":true,"isOutdated":false},{"isResolved":true,"isOutdated":true}]')"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ── the blocking case: still applies to HEAD ─────────────────────────────────

@test "blocking count: unresolved and NOT outdated → 1 (still blocks)" {
  run pr_auto_review_blocking_thread_count <<<"$(resp '[{"isResolved":false,"isOutdated":false}]')"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# ── the #806 fix: outdated thread (diff anchor shifted at HEAD) → non-blocking ─

@test "blocking count: unresolved but OUTDATED → 0 (diff anchor shifted, non-blocking)" {
  run pr_auto_review_blocking_thread_count <<<"$(resp '[{"isResolved":false,"isOutdated":true}]')"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "blocking count: the #805 scenario — three fixed advisory threads all outdated → 0" {
  # Copilot dep-check + two Gemini temp-file findings, each fixed in a follow-up
  # commit that changed the anchored line, so all three threads are outdated.
  run pr_auto_review_blocking_thread_count <<<"$(resp '[
    {"isResolved":false,"isOutdated":true},
    {"isResolved":false,"isOutdated":true},
    {"isResolved":false,"isOutdated":true}
  ]')"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ── mixed sets: only unresolved-and-current threads count ─────────────────────

@test "blocking count: mixed set counts only unresolved-and-current threads" {
  # resolved(current), resolved(outdated), unresolved+outdated, unresolved+current
  run pr_auto_review_blocking_thread_count <<<"$(resp '[
    {"isResolved":true,"isOutdated":false},
    {"isResolved":true,"isOutdated":true},
    {"isResolved":false,"isOutdated":true},
    {"isResolved":false,"isOutdated":false}
  ]')"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "blocking count: several unresolved-and-current threads → their count" {
  run pr_auto_review_blocking_thread_count <<<"$(resp '[
    {"isResolved":false,"isOutdated":false},
    {"isResolved":false,"isOutdated":false},
    {"isResolved":false,"isOutdated":true}
  ]')"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

# ── fail-safe: missing / null isOutdated on an unresolved thread still blocks ─

@test "blocking count: unresolved thread with null isOutdated → 1 (fail safe: still blocks)" {
  run pr_auto_review_blocking_thread_count <<<"$(resp '[{"isResolved":false,"isOutdated":null}]')"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "blocking count: unresolved thread with absent isOutdated → 1 (fail safe: still blocks)" {
  run pr_auto_review_blocking_thread_count <<<"$(resp '[{"isResolved":false}]')"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# ── robustness: GraphQL error / missing-data bodies yield 0 ──────────────────

@test "blocking count: GraphQL error body (no data) → 0" {
  run pr_auto_review_blocking_thread_count <<<'{"errors":[{"message":"Could not resolve to a Repository"}]}'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "blocking count: null nodes → 0" {
  run pr_auto_review_blocking_thread_count <<<"$(resp 'null')"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ── null-safety: absent / null intermediate fields → 0 ──────────────────────

@test "blocking count: absent .data key → 0" {
  run pr_auto_review_blocking_thread_count <<<'{}'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "blocking count: null .data → 0" {
  run pr_auto_review_blocking_thread_count <<<'{"data":null}'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "blocking count: absent .data.repository → 0" {
  run pr_auto_review_blocking_thread_count <<<'{"data":{}}'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "blocking count: null .data.repository → 0" {
  run pr_auto_review_blocking_thread_count <<<'{"data":{"repository":null}}'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ── issue #892: advisory-bot-only threads are non-blocking ───────────────────
# A thread whose comments are exclusively from bots (author.__typename == "Bot")
# is advisory feedback, not a human review request. It should not block
# dispatch — otherwise the gate stalls on a human to resolve bot threads that
# dev-lead fix-review correctly returns no-changes for (empty machine findings).

@test "blocking count: unresolved thread with all-bot comments → 0 (advisory bot, non-blocking)" {
  run pr_auto_review_blocking_thread_count <<<"$(resp '[{
    "isResolved":false,"isOutdated":false,
    "comments":{"nodes":[{"author":{"__typename":"Bot"}}]}
  }]')"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "blocking count: unresolved thread with User comment → 1 (human thread, still blocks)" {
  run pr_auto_review_blocking_thread_count <<<"$(resp '[{
    "isResolved":false,"isOutdated":false,
    "comments":{"nodes":[{"author":{"__typename":"User"}}]}
  }]')"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "blocking count: absent comments field → 1 (fail-safe: cannot confirm bot-only, still blocks)" {
  run pr_auto_review_blocking_thread_count <<<"$(resp '[{"isResolved":false,"isOutdated":false}]')"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "blocking count: empty comments nodes → 1 (fail-safe: no authors to confirm bot-only)" {
  run pr_auto_review_blocking_thread_count <<<"$(resp '[{
    "isResolved":false,"isOutdated":false,
    "comments":{"nodes":[]}
  }]')"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "blocking count: mixed bot and human threads — only human thread blocks" {
  run pr_auto_review_blocking_thread_count <<<"$(resp '[
    {"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"__typename":"Bot"}}]}},
    {"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"__typename":"User"}}]}},
    {"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"__typename":"Bot"}}]}}
  ]')"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "blocking count: thread with bot first comment and human reply → 1 (not purely advisory-bot)" {
  # A thread opened by a bot but with a human follow-up must block.
  # This pins the requirement that comments(first:100) is used in the GQL query
  # rather than comments(first:1) — a first:1 query would only see the Bot
  # comment and incorrectly classify the thread as advisory-bot-only.
  run pr_auto_review_blocking_thread_count <<<"$(resp '[{
    "isResolved":false,"isOutdated":false,
    "comments":{"nodes":[
      {"author":{"__typename":"Bot"}},
      {"author":{"__typename":"User"}}
    ]}
  }]')"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "blocking count: the #892 scenario — multiple advisory bot threads (gemini + codeant) → 0" {
  # Scenario: CI green, CHANGES_REQUESTED from advisory bots (gemini-code-assist,
  # codeant-ai), all 5 threads unresolved and not outdated. Without the fix,
  # the gate counts 5 blocking threads and stalls dispatch even though every
  # thread is advisory-bot feedback with no machine findings.
  run pr_auto_review_blocking_thread_count <<<"$(resp '[
    {"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"__typename":"Bot"}}]}},
    {"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"__typename":"Bot"}}]}},
    {"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"__typename":"Bot"}}]}},
    {"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"__typename":"Bot"}}]}},
    {"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"__typename":"Bot"}}]}}
  ]')"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}
