#!/usr/bin/env bats
# Tests for check_reusable_workflows_disabled in scripts/compliance-audit.sh.
#
# Covers:
#   - Trigger classification: block form, inline scalar, inline sequence
#   - State check: only disabled_manually is compliant; active and
#     disabled_inactivity (and any other state) must be flagged

bats_require_minimum_version 1.5.0

# ---------------------------------------------------------------------------
# Mirror the trigger-classification logic from check_reusable_workflows_disabled.
# Prints one trigger key per line; exits 0.
# ---------------------------------------------------------------------------
_extract_triggers() {
  local decoded="$1"
  local on_line
  on_line=$(echo "$decoded" | grep -m1 '^on:')
  if echo "$on_line" | grep -qE '^on:[[:space:]]+[a-zA-Z_]+[[:space:]]*(#.*)?$'; then
    echo "$on_line" | sed 's/^on:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | tr -d '[:space:]'
  elif echo "$on_line" | grep -qE '^on:[[:space:]]*\['; then
    echo "$on_line" | sed 's/^on:[[:space:]]*//' | tr -d '[]"'"'"' ' | tr ',' '\n' | tr -d '[:space:]'
  else
    echo "$decoded" | awk '
      /^on:/                     { inblock=1; next }
      inblock && /^[^[:space:]#]/ { exit }
      inblock && /^  [a-zA-Z_]/  {
        key=$1; sub(/:.*/,"",key); gsub(/[[:space:]]/,"",key); print key
      }
    '
  fi
}

# ---------------------------------------------------------------------------
# Mirror the pure-reusable detection (workflow_call only, no other triggers).
# Returns 0 if pure reusable, 1 if hybrid or non-reusable.
# ---------------------------------------------------------------------------
_is_pure_reusable() {
  local decoded="$1"
  local triggers
  triggers=$(_extract_triggers "$decoded")
  echo "$triggers" | grep -qx "workflow_call" || return 1
  [ "$(echo "$triggers" | grep -vx "workflow_call" | grep -c .)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Mirror the compliance check: returns 0 when a finding should be emitted.
# ---------------------------------------------------------------------------
_should_flag() {
  local state="$1"
  [ "$state" != "disabled_manually" ]
}

# ===========================================================================
# Trigger classification — block form
# ===========================================================================

@test "block form: workflow_call-only is a pure reusable" {
  local wf
  wf=$(printf 'on:\n  workflow_call:\n    inputs:\n      repo:\n        type: string\n')
  run _is_pure_reusable "$wf"
  [ "$status" -eq 0 ]
}

@test "block form: workflow_call + push is a hybrid (not pure reusable)" {
  local wf
  wf=$(printf 'on:\n  workflow_call:\n  push:\n    branches: [main]\n')
  run _is_pure_reusable "$wf"
  [ "$status" -eq 1 ]
}

@test "block form: push-only workflow is not a reusable" {
  local wf
  wf=$(printf 'on:\n  push:\n    branches: [main]\n')
  run _is_pure_reusable "$wf"
  [ "$status" -eq 1 ]
}

# ===========================================================================
# Trigger classification — inline scalar
# ===========================================================================

@test "inline scalar: 'on: workflow_call' is a pure reusable" {
  local wf
  wf=$(printf 'on: workflow_call\njobs:\n  call:\n    runs-on: ubuntu-latest\n    steps: []\n')
  run _is_pure_reusable "$wf"
  [ "$status" -eq 0 ]
}

@test "inline scalar: 'on: push' is not a reusable" {
  local wf
  wf=$(printf 'on: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps: []\n')
  run _is_pure_reusable "$wf"
  [ "$status" -eq 1 ]
}

@test "inline scalar: trailing comment does not break classification" {
  local wf
  wf=$(printf 'on: workflow_call # pure reusable\njobs:\n  call:\n    runs-on: ubuntu-latest\n    steps: []\n')
  run _is_pure_reusable "$wf"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# Trigger classification — inline sequence
# ===========================================================================

@test "inline sequence: '[workflow_call]' is a pure reusable" {
  local wf
  wf=$(printf 'on: [workflow_call]\njobs:\n  call:\n    runs-on: ubuntu-latest\n    steps: []\n')
  run _is_pure_reusable "$wf"
  [ "$status" -eq 0 ]
}

@test "inline sequence: '[workflow_call, push]' is a hybrid (not pure reusable)" {
  local wf
  wf=$(printf 'on: [workflow_call, push]\njobs:\n  call:\n    runs-on: ubuntu-latest\n    steps: []\n')
  run _is_pure_reusable "$wf"
  [ "$status" -eq 1 ]
}

@test "inline sequence: '[push, pull_request]' is not a reusable" {
  local wf
  wf=$(printf 'on: [push, pull_request]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps: []\n')
  run _is_pure_reusable "$wf"
  [ "$status" -eq 1 ]
}

# ===========================================================================
# State check — only disabled_manually is compliant
# ===========================================================================

@test "state 'active' is flagged" {
  run _should_flag "active"
  [ "$status" -eq 0 ]
}

@test "state 'disabled_inactivity' is flagged" {
  run _should_flag "disabled_inactivity"
  [ "$status" -eq 0 ]
}

@test "state 'disabled_manually' is NOT flagged" {
  run _should_flag "disabled_manually"
  [ "$status" -eq 1 ]
}

@test "unknown/unexpected state is flagged" {
  run _should_flag "unknown"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Mirror the naming-suffix check from check_reusable_workflows_disabled.
# Returns 0 when a reusable-naming finding should be emitted.
# ---------------------------------------------------------------------------
_should_flag_naming() {
  local repo="$1" wf="$2"
  [[ "$wf" != *-reusable.yml && "$repo/$wf" != ".github-private/pr-review.yml" ]]
}

# ===========================================================================
# Naming suffix check — pure reusables must carry -reusable.yml
# ===========================================================================

@test "naming: file with -reusable.yml suffix is NOT flagged" {
  run _should_flag_naming "my-repo" "deploy-reusable.yml"
  [ "$status" -eq 1 ]
}

@test "naming: file without -reusable.yml suffix IS flagged" {
  run _should_flag_naming "my-repo" "deploy.yml"
  [ "$status" -eq 0 ]
}

@test "naming: .github-private/pr-review.yml is grandfathered (NOT flagged)" {
  run _should_flag_naming ".github-private" "pr-review.yml"
  [ "$status" -eq 1 ]
}

@test "naming: pr-review.yml in a different repo IS flagged" {
  run _should_flag_naming "other-repo" "pr-review.yml"
  [ "$status" -eq 0 ]
}

@test "naming: .yaml extension without -reusable suffix IS flagged" {
  run _should_flag_naming "my-repo" "deploy.yaml"
  [ "$status" -eq 0 ]
}

@test "naming: -reusable.yaml is flagged (.yml suffix is the only exempt form)" {
  run _should_flag_naming "my-repo" "deploy-reusable.yaml"
  [ "$status" -eq 0 ]
}