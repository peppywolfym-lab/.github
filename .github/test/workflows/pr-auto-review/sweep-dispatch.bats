#!/usr/bin/env bats
# End-to-end fault-isolation tests for the catch-up sweep orchestrator
# .github/scripts/pr-auto-review/sweep-dispatch.sh
#
# Pins issue #947 (Fleet Monitor WARNING: pr-auto-review-sweep.yml failure rate
# 11.1%). The sweep runs under `set -euo pipefail` on a 15-min schedule. Before
# this guard, the unguarded repository_dispatch POST inside the candidate loop
# ran with errexit active, so a single transient API failure (secondary rate
# limit / 5xx / network blip) on ONE PR aborted the whole run — failing the
# workflow and stranding every remaining candidate. The sweep is idempotent and
# re-runs every cycle, so a transient per-PR error must be logged and skipped,
# not fail the run. These tests drive the script with a scripted `gh` stub and
# assert that one PR's transient failure never aborts the sweep.

bats_require_minimum_version 1.5.0

load 'helpers/setup'

# Write an executable `gh` stub onto PATH. Behaviour is driven by env vars so a
# test can script per-PR success/failure without a stub variant per case.
#
#   STUB_PR_LIST            JSON returned by `gh search prs`
#   STUB_VIEW_FAIL_URL      `gh pr view <url>` exits 1 when url matches (transient fetch failure)
#   STUB_DISPATCH_FAIL_URL  the repository_dispatch POST exits 1 when its args contain this url
#   STUB_DISPATCH_FAIL_ONCE fail the first N dispatch POSTs (any url), then succeed (retry test)
#   STUB_COUNTER            counter file backing STUB_DISPATCH_FAIL_ONCE
write_gh_stub() {
  local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"search prs"*)
    printf '%s' "${STUB_PR_LIST:-[]}"
    ;;
  "pr view "*)
    url="$3"
    if [ -n "${STUB_VIEW_FAIL_URL:-}" ] && [ "$url" = "$STUB_VIEW_FAIL_URL" ]; then
      exit 1
    fi
    printf '{"state":"OPEN","isDraft":false,"number":1,"reviewDecision":"","baseRefName":"main"}'
    ;;
  "pr checks "*)
    printf '[{"name":"CI / Lint","bucket":"pass"}]'
    ;;
  *"rules/branches"*)
    exit 1  # 404 → no required contexts configured → required_json=[]
    ;;
  *graphql*)
    if [ -n "${STUB_GRAPHQL_NULL_REPO:-}" ] && [[ "$*" == *"repo=${STUB_GRAPHQL_NULL_REPO}"* ]]; then
      printf '{"data":{"repository":{"pullRequest":null}}}'
    elif [ -n "${STUB_GRAPHQL_ERRORS_REPO:-}" ] && [[ "$*" == *"repo=${STUB_GRAPHQL_ERRORS_REPO}"* ]]; then
      printf '{"errors":[{"message":"Could not resolve ReviewThreads"}],"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
    elif [ -n "${STUB_GRAPHQL_NULL_THREADS_REPO:-}" ] && [[ "$*" == *"repo=${STUB_GRAPHQL_NULL_THREADS_REPO}"* ]]; then
      printf '{"data":{"repository":{"pullRequest":{"reviewThreads":null}}}}'
    else
      printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
    fi
    ;;
  *dispatches*)
    if [ -n "${STUB_DISPATCH_FAIL_URL:-}" ] && [[ "$*" == *"$STUB_DISPATCH_FAIL_URL"* ]]; then
      exit 1
    fi
    if [ -n "${STUB_DISPATCH_FAIL_ONCE:-}" ]; then
      n=0
      [ -f "${STUB_COUNTER:-/dev/null}" ] && n=$(cat "$STUB_COUNTER")
      n=$((n + 1))
      printf '%s' "$n" > "$STUB_COUNTER"
      if [ "$n" -le "$STUB_DISPATCH_FAIL_ONCE" ]; then
        exit 1
      fi
    fi
    printf '{"ok":true}'
    ;;
  *)
    ;;
esac
STUB
  chmod +x "$bin/gh"
  PATH="${bin}:${PATH}"; export PATH
}

setup() {
  write_gh_stub
  export GH_TOKEN="t"
  export SEARCH_OWNER="petry-projects"
  export SWEEP_LABEL="standards-sync"
  export MAX_PER_RUN="8"
  export DRY_RUN="0"
  export DISPATCH_REPO="petry-projects/.github-private"
  # Keep retries bounded and instant so the suite stays fast + deterministic.
  export DISPATCH_RETRIES="2"
  export DISPATCH_RETRY_SLEEP="0"
  export STUB_COUNTER="${BATS_TEST_TMPDIR}/dispatch-count"
  # Two ready, non-draft PRs.
  export STUB_PR_LIST='[
    {"url":"https://github.com/petry-projects/repo-a/pull/1","isDraft":false},
    {"url":"https://github.com/petry-projects/repo-c/pull/3","isDraft":false}
  ]'
}

run_sweep() { run bash "${TT_SCRIPTS_DIR}/sweep-dispatch.sh"; }

# ── happy path baseline ───────────────────────────────────────────────────────

@test "sweep: both ready PRs dispatch and the run succeeds" {
  run_sweep
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'dispatched auto-review for https://github.com/petry-projects/repo-a/pull/1'
  echo "$output" | grep -q 'dispatched auto-review for https://github.com/petry-projects/repo-c/pull/3'
  echo "$output" | grep -q 'dispatched 2 of 2'
}

# ── fault isolation: a transient dispatch failure must not abort the sweep ─────

@test "sweep: a transient dispatch failure on one PR does not abort the run" {
  export STUB_DISPATCH_FAIL_URL="https://github.com/petry-projects/repo-a/pull/1"
  run_sweep
  # The whole run must still succeed — a transient dispatch error is retried
  # next cycle, not a workflow failure.
  [ "$status" -eq 0 ]
  # repo-a persistently fails → warning, not an abort.
  echo "$output" | grep -q 'failed to dispatch https://github.com/petry-projects/repo-a/pull/1'
  # repo-c is still reached and dispatched (loop was not aborted).
  echo "$output" | grep -q 'dispatched auto-review for https://github.com/petry-projects/repo-c/pull/3'
  echo "$output" | grep -q 'dispatched 1 of 2'
}

# ── fault isolation: a transient fact-fetch failure skips only that PR ─────────

@test "sweep: a transient 'gh pr view' failure skips that PR and continues" {
  export STUB_VIEW_FAIL_URL="https://github.com/petry-projects/repo-a/pull/1"
  run_sweep
  [ "$status" -eq 0 ]
  local sweep_output="$output"
  # repo-c still dispatches.
  echo "$sweep_output" | grep -q 'dispatched auto-review for https://github.com/petry-projects/repo-c/pull/3'
  echo "$sweep_output" | grep -q 'dispatched 1 of 2'
  # repo-a could not be evaluated → skipped, never dispatched.
  run grep -q 'dispatched auto-review for https://github.com/petry-projects/repo-a/pull/1' <<< "$sweep_output"
  [ "$status" -eq 1 ]
}

# ── bounded retry: a dispatch that fails once then succeeds is retried ─────────

@test "sweep: a dispatch that fails once is retried and then succeeds" {
  export STUB_DISPATCH_FAIL_ONCE="1"
  # Only one PR so the single retry budget is spent on it deterministically.
  export STUB_PR_LIST='[{"url":"https://github.com/petry-projects/repo-a/pull/1","isDraft":false}]'
  run_sweep
  [ "$status" -eq 0 ]
  local sweep_output="$output"
  echo "$sweep_output" | grep -q 'dispatched auto-review for https://github.com/petry-projects/repo-a/pull/1'
  echo "$sweep_output" | grep -q 'dispatched 1 of 1'
  # No persistent-failure warning — the retry recovered it.
  run grep -q 'failed to dispatch' <<< "$sweep_output"
  [ "$status" -eq 1 ]
}

# ── fault isolation: null GraphQL PR data must not silently pass the gate ──────

@test "sweep: a GraphQL response with null pullRequest data skips that PR" {
  # gh api graphql exits 0 but returns null pullRequest when a PR is deleted or
  # the repo is renamed; the null-path guard must treat this as a fetch failure
  # and skip the PR rather than letting pr_auto_review_blocking_thread_count
  # return 0 and silently pass the readiness gate.
  export STUB_GRAPHQL_NULL_REPO="repo-a"
  run_sweep
  [ "$status" -eq 0 ]
  local sweep_output="$output"
  # repo-c is still reached and dispatched — null data on repo-a must not abort.
  echo "$sweep_output" | grep -q 'dispatched auto-review for https://github.com/petry-projects/repo-c/pull/3'
  echo "$sweep_output" | grep -q 'dispatched 1 of 2'
  # repo-a had null PR data → warning + skip, never dispatched.
  run grep -q 'dispatched auto-review for https://github.com/petry-projects/repo-a/pull/1' <<< "$sweep_output"
  [ "$status" -eq 1 ]
}

# ── fault isolation: GraphQL errors array must skip that PR ──────────────────

@test "sweep: a GraphQL response with an errors array skips that PR" {
  # gh api graphql can return an errors array alongside non-null data (partial
  # failure, e.g. reviewThreads could not be resolved). The guard must treat
  # this as incomplete data and skip rather than counting zero blocking threads.
  export STUB_GRAPHQL_ERRORS_REPO="repo-a"
  run_sweep
  [ "$status" -eq 0 ]
  local sweep_output="$output"
  # repo-c is still reached and dispatched — errors on repo-a must not abort.
  echo "$sweep_output" | grep -q 'dispatched auto-review for https://github.com/petry-projects/repo-c/pull/3'
  echo "$sweep_output" | grep -q 'dispatched 1 of 2'
  # repo-a had GraphQL errors → warning + skip, never dispatched.
  run grep -q 'dispatched auto-review for https://github.com/petry-projects/repo-a/pull/1' <<< "$sweep_output"
  [ "$status" -eq 1 ]
}

# ── fault isolation: null reviewThreads must skip that PR ────────────────────

@test "sweep: a GraphQL response with null reviewThreads skips that PR" {
  # gh api graphql can return null reviewThreads when the thread list cannot be
  # fetched. The guard must skip rather than letting the blocking count default
  # to zero and silently pass the readiness gate.
  export STUB_GRAPHQL_NULL_THREADS_REPO="repo-a"
  run_sweep
  [ "$status" -eq 0 ]
  local sweep_output="$output"
  # repo-c is still reached and dispatched — null threads on repo-a must not abort.
  echo "$sweep_output" | grep -q 'dispatched auto-review for https://github.com/petry-projects/repo-c/pull/3'
  echo "$sweep_output" | grep -q 'dispatched 1 of 2'
  # repo-a had null reviewThreads → warning + skip, never dispatched.
  run grep -q 'dispatched auto-review for https://github.com/petry-projects/repo-a/pull/1' <<< "$sweep_output"
  [ "$status" -eq 1 ]
}
