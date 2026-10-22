#!/usr/bin/env bats
# Tests verifying compliance-retrigger.sh survives transient GitHub API failures.
#
# Context (Fleet Monitor issue #948):
#   The hourly scheduled workflow had an ~11% failure rate. Root cause: the
#   primary search/issues call aborted the whole run with `return 1` on any
#   single transient error (rate limit / 5xx), which propagates through `main`
#   under `set -euo pipefail` and fails the workflow. The fix wraps the search
#   calls in a bounded retry-with-backoff so transient errors are absorbed while
#   a genuine, persistent outage still surfaces as a failure.

bats_require_minimum_version 1.5.0

load 'helpers/setup'

setup() {
  tt_make_tmpdir
  tt_install_gh_stub
  export GH_STUB_LOG="${TT_TMP}/gh.log"
  : >"$GH_STUB_LOG"
  # Keep the suite fast: no real backoff sleeps between retries.
  export GH_API_RETRY_BASE_DELAY=0
}

teardown() {
  tt_cleanup_tmpdir
}

@test "recovers when the first search/issues call fails transiently" {
  # The first search attempt fails (simulated rate limit); the retry must
  # succeed and the script must exit 0.
  GH_TOKEN=fake \
    ORG=petry-projects \
    DRY_RUN=true \
    GH_STUB_SEARCH_FAIL_TIMES=1 \
    run bash "$TT_SCRIPT"

  [ "$status" -eq 0 ]
  # The search endpoint was hit more than once — the retry actually fired.
  run grep -c "search/issues" "$GH_STUB_LOG"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}

@test "legacy sweep recovers when its search/issues call fails transiently" {
  # Primary sweep succeeds; legacy sweep's first attempt fails transiently.
  # TRIGGER_LABEL != LEGACY_TRIGGER_LABEL so both sweeps run.
  GH_TOKEN=fake \
    ORG=petry-projects \
    DRY_RUN=true \
    TRIGGER_LABEL=dev-lead \
    LEGACY_TRIGGER_LABEL=claude \
    GH_SEARCH_ATTEMPTS=3 \
    GH_STUB_SEARCH_FAIL_START=2 \
    GH_STUB_SEARCH_FAIL_TIMES=1 \
    run bash "$TT_SCRIPT"

  [ "$status" -eq 0 ]
  # Primary: 1 call; legacy: 2 calls (1 fail + 1 success) = 3 total.
  run grep -c "search/issues" "$GH_STUB_LOG"
  [ "$status" -eq 0 ]
  [ "$output" -ge 3 ]
}

@test "zero-exit error JSON from search endpoint fails the run" {
  # gh api exits 0 but returns an error object — the script must detect it
  # and fail rather than treating the run as successful.
  GH_TOKEN=fake \
    ORG=petry-projects \
    DRY_RUN=true \
    GH_STUB_SEARCH_ZERO_EXIT_ERROR_TIMES=1 \
    run bash "$TT_SCRIPT"

  [ "$status" -ne 0 ]
}

@test "still fails when every search/issues attempt fails" {
  # A persistent outage (more failures than the retry budget) must still surface
  # as a non-zero exit — we must not silently swallow a real outage.
  GH_TOKEN=fake \
    ORG=petry-projects \
    DRY_RUN=true \
    GH_SEARCH_ATTEMPTS=2 \
    GH_STUB_SEARCH_FAIL_TIMES=99 \
    run bash "$TT_SCRIPT"

  [ "$status" -ne 0 ]
  # The stub was hit exactly GH_SEARCH_ATTEMPTS=2 times before giving up.
  run grep -c "search/issues" "$GH_STUB_LOG"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}
