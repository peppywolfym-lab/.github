#!/usr/bin/env bats
# Regression guard for the flaky "Lint GitHub Actions" step in
# .github/workflows/ci.yml.
#
# Pins issue #894: ci.yml intermittently fails (~14% of runs) because the pinned
# rhysd/actionlint binary is fetched from GitHub Releases — which redirects to
# objects.githubusercontent.com — with a bare `curl` that aborts on the first
# transient network/5xx blip. This is the same failure mode fixed for
# pr-review-mention-tests.yml under #739. AGENTS.md requires CI to be reliable;
# the one unavoidable network fetch must therefore retry on transient errors.
# These tests assert every download in ci.yml carries bounded curl retries, so a
# future edit can't silently reintroduce a bare download.

load 'helpers/setup'

# Emit the `run:` step block whose text contains the given marker substring.
# Steps in ci.yml start at a 6-space "- " (the `steps:` child indent); every
# deeper-indented line belongs to that step. Isolating a step lets each test
# assert resilience on the one fetch it cares about without matching flags that
# happen to appear in a neighbouring step.
step_block_with() {
  local marker="$1"
  local block="" out="" line=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" == "      - "* ]]; then
      if [[ "$block" == "      - "* ]]; then
        [[ "$block" == *"$marker"* ]] && out="$block"
      fi
      block="$line"$'\n'
    else
      if [[ -n "$block" ]]; then
        block+="$line"$'\n'
      fi
    fi
  done < "$TT_WORKFLOW"
  if [[ "$block" == "      - "* ]]; then
    [[ "$block" == *"$marker"* ]] && out="$block"
  fi
  printf '%s' "$out"
}

@test "install: the ci workflow exists" {
  [ -f "$TT_WORKFLOW" ]
}

@test "install: every curl download in ci.yml uses bounded retries" {
  [ -f "$TT_WORKFLOW" ]

  # Parse the workflow joining backslash-continued lines so that a curl command
  # split across multiple lines is treated as a single logical invocation.
  # This avoids false failures when flags appear on continuation lines, and
  # avoids false passes when a bare `curl` is split from its flags.
  local curls=()
  local current=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" == *\\ ]]; then
      current+="${line%\\} "
    else
      current+="$line"
      if [[ "$current" == *curl* ]] && ! [[ "$current" =~ ^[[:space:]]*# ]] && ! [[ "$current" =~ ^[[:space:]]*-?[[:space:]]*(name|uses|with): ]]; then
        curls+=("$current")
      fi
      current=""
    fi
  done < "$TT_WORKFLOW"

  # At least one curl invocation must be present so the test remains meaningful.
  [ "${#curls[@]}" -ge 1 ]
  for cmd in "${curls[@]}"; do
    # A finite retry budget (not unbounded) so a truly-down mirror still fails fast.
    [[ "$cmd" =~ --retry[[:space:]=][1-9] ]]
    # Retry on connection refused, which curl otherwise treats as non-transient.
    [[ "$cmd" == *"--retry-connrefused"* ]]
    # Retry on transient HTTP 5xx too, not just connection-level errors.
    [[ "$cmd" == *"--retry-all-errors"* ]]
  done
}

@test "install: the yamllint pip install carries a bounded retry budget" {
  # pip fetches wheels from PyPI/the configured index; a transient index blip
  # would otherwise red the Lint job. An explicit --retries pins the budget so a
  # future edit can't drop resilience and reintroduce a bare install.
  local block
  block="$(step_block_with 'pip install')"
  [ -n "$block" ]
  local pip_cmd
  pip_cmd="$(printf '%s' "$block" | grep -E '^[[:space:]]+pip install' | head -1)"
  [ -n "$pip_cmd" ]
  [[ "$pip_cmd" =~ --retries[[:space:]=][1-9] ]]
}

@test "install: the AgentShield npx fetch retries transient registry errors" {
  # `npx ecc-agentshield` downloads the package from the npm registry before
  # scanning; npm's default of 2 fetch retries is thin. Bump it via npm's native
  # fetch-retries config (env var, NOT a shell loop) so a transient registry
  # error retries while a genuine high-severity finding still fails on the first
  # run instead of being retried three times.
  local block
  block="$(step_block_with 'ecc-agentshield')"
  [ -n "$block" ]
  [[ "$block" =~ npm_config_fetch_retries:[[:space:]]*\'?[1-9] ]]
  [[ "$block" =~ npm_config_fetch_timeout:[[:space:]]*\'?[1-9] ]]
}

@test "install: every job in ci.yml declares a bounded timeout-minutes" {
  # An unbounded job turns a single hung step (a network fetch that stalls
  # without refusing the connection, a stuck npx/pip) into a run that grinds on
  # to GitHub's 360-minute default before failing — the long-tail behind the
  # fleet failure-rate/p95 warning (issue #986). Every job must therefore cap
  # itself with a bounded timeout-minutes so a hang fails fast; this test asserts
  # no job can silently drop that cap. Sibling fix: pr-auto-review-sweep.yml
  # (#947) added timeout-minutes for the same reason.
  [ -f "$TT_WORKFLOW" ]

  # Walk the `jobs:` block. Job ids are the only keys indented exactly 2 spaces;
  # each job's own keys (including timeout-minutes) sit at 4 spaces. For every
  # job id we assert its block carries a `timeout-minutes: N` with 1 <= N <= 59
  # (59 is GitHub's documented cap for setup-steps jobs and a sane fleet bound).
  local in_jobs=0
  local job_count=0
  local current_job="" current_ok=0 line=""
  finish_job() {
    if [[ -n "$current_job" ]]; then
      [ "$current_ok" -eq 1 ] || {
        echo "job '$current_job' is missing a bounded timeout-minutes (1-59)" >&2
        return 1
      }
    fi
    return 0
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    # Enter the jobs: block (top-level key, no indentation).
    if [[ "$line" =~ ^jobs:[[:space:]]*$ ]]; then
      in_jobs=1
      continue
    fi
    [ "$in_jobs" -eq 1 ] || continue
    # A new top-level key (no leading space) ends the jobs: block.
    if [[ "$line" =~ ^[^[:space:]] ]]; then
      finish_job || return 1
      break
    fi
    # A job id: exactly two spaces of indent then `name:`.
    if [[ "$line" =~ ^\ \ ([A-Za-z0-9_-]+):[[:space:]]*$ ]]; then
      finish_job || return 1
      current_job="${BASH_REMATCH[1]}"
      current_ok=0
      job_count=$((job_count + 1))
      continue
    fi
    # timeout-minutes for the current job (4-space indent), value 1-59.
    if [[ "$line" =~ ^\ \ \ \ timeout-minutes:[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
      local v="${BASH_REMATCH[1]}"
      if [ "$v" -ge 1 ] && [ "$v" -le 59 ]; then
        current_ok=1
      fi
    fi
  done < "$TT_WORKFLOW"
  # Handle the final job when the file ends inside the jobs: block.
  finish_job || return 1

  # Guard against a parser that silently matches nothing.
  [ "$job_count" -ge 1 ]
}

@test "install: the gitleaks release download retries on transient failure" {
  # `gh release download` pulls gitleaks from GitHub Releases (which redirects to
  # objects.githubusercontent.com) and has no native retry — the exact failure
  # mode #894 fixed for the actionlint curl. Wrap it in a bounded retry loop with
  # backoff so a transient blip retries instead of reding the Secret scan job.
  local block
  block="$(step_block_with 'gh release download')"
  [ -n "$block" ]
  [[ "$block" == *"for attempt in"* ]]
  [[ "$block" == *"sleep"* ]]
  [[ "$block" == *"timeout"* ]]
}
