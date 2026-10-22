#!/usr/bin/env bats
# Regression guard for the flaky "Install bats, shellcheck, jq, and yq" step in
# .github/workflows/pr-review-mention-tests.yml.
#
# Pins issue #739: the suite intermittently fails (~14% of runs) because the
# pinned mikefarah/yq is fetched from GitHub Releases — which redirects to
# objects.githubusercontent.com — with a bare `curl` that aborts on the first
# transient network/5xx blip. AGENTS.md requires unit tests be deterministic;
# the one unavoidable network fetch must therefore retry on transient errors. These
# tests assert every GitHub-Releases download in the workflow carries bounded
# curl retries, so a future edit can't silently reintroduce a bare download.

load 'helpers/setup'

TESTS_WORKFLOW="${TT_REPO_ROOT}/.github/workflows/pr-review-mention-tests.yml"

@test "install: the tests workflow exists" {
  [ -f "$TESTS_WORKFLOW" ]
}

@test "install: every curl download uses bounded retries" {
  [ -f "$TESTS_WORKFLOW" ]

  # Parse the workflow joining backslash-continued lines so that a curl command
  # split across multiple lines is treated as a single logical invocation.
  # This avoids false failures when flags appear on continuation lines, and avoids
  # false passes when a bare `curl` is split from its flags.
  local curls=()
  local current=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" == *'\\' ]]; then
      current+="${line%\\} "
    else
      current+="$line"
      if [[ "$current" == *curl* ]] && ! [[ "$current" =~ ^[[:space:]]*'#' ]]; then
        curls+=("$current")
      fi
      current=""
    fi
  done < "$TESTS_WORKFLOW"

  # At least one curl invocation must be present so the test remains meaningful.
  [ "${#curls[@]}" -ge 1 ]
  for cmd in "${curls[@]}"; do
    # A finite retry budget (not unbounded) so a truly-down mirror still fails fast.
    [[ "$cmd" == *"--retry "* ]]
    # Retry on connection refused, which curl otherwise treats as non-transient.
    [[ "$cmd" == *"--retry-connrefused"* ]]
    # Retry on transient HTTP 5xx too, not just connection-level errors.
    [[ "$cmd" == *"--retry-all-errors"* ]]
  done
}
