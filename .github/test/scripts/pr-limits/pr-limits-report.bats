#!/usr/bin/env bats
# Tests for scripts/pr-limits-report.sh — the no-LLM PR-limits success-metric
# report that measures open, non-draft, automation-authored PRs org-wide against
# the signed-off cap in standards/pr-limits.json (#510, epic #505 Story 5).
#
# Context (ADR docs/initiatives/pull-request-limits-adr.md): the report reuses
# the admission gate's counting semantics (scripts/lib/pr-limit-gate.sh §7.4) so
# the two always agree — a PR counts toward the cap only when its author is not
# an exempt actor AND it carries no exempt label. This report is pure gh + jq
# (no LLM).
#
# `gh` is stubbed via the env-driven fake under
# test/scripts/compliance-remediate/stubs/gh (no live API), so the metrics depend
# only on the stubbed search payload + the config cap/exempt lists.

bats_require_minimum_version 1.5.0

SCRIPT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/scripts/pr-limits-report.sh"
GH_STUB_SRC="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/scripts/compliance-remediate/stubs/gh"

setup() {
  TMP="$(mktemp -d)"
  export TMP

  # Put the env-driven gh stub on PATH and log every invocation so we can assert
  # the report never issues a mutating gh subcommand (read-only search only).
  mkdir -p "$TMP/bin"
  cp "$GH_STUB_SRC" "$TMP/bin/gh"
  chmod +x "$TMP/bin/gh"
  PATH="$TMP/bin:$PATH"
  export PATH
  export GH_STUB_LOG="$TMP/gh.log"
  : >"$GH_STUB_LOG"

  export ORG="petry-projects"
}

teardown() {
  if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
    rm -rf "$TMP"
  fi
}

# Write a pr-limits config with the given org-wide cap and point
# PR_LIMITS_CONFIG at it. Exempt lists mirror the real config.
write_config() {
  local org_cap="$1"
  export PR_LIMITS_CONFIG="$TMP/pr-limits.json"
  jq -n --argjson org_cap "$org_cap" '{
    status: "provisional",
    _schema_version: 1,
    org_wide: { automation_open_pr_cap: $org_cap },
    per_source_caps: {},
    exempt_actors: ["dependabot[bot]"],
    exempt_labels: ["security"]
  }' >"$PR_LIMITS_CONFIG"
}

# Make the gh stub return a search payload of N open non-draft PRs, all authored
# by a non-exempt actor with no exempt labels.
stub_open_prs() {
  local count="$1"
  export GH_STUB_STDOUT
  GH_STUB_STDOUT="$(jq -nc --argjson n "$count" \
    '[range(0; $n) | { author: { login: "dev-lead-bot" }, labels: [], repository: { name: "r" }, title: "t", url: "u" }]')"
}

run_report() {
  run bash "$SCRIPT"
}

# --------------------------------------------------------------------------
# Under the cap -> "Under cap" with positive headroom
# --------------------------------------------------------------------------
@test "under the cap reports Under cap with positive headroom" {
  write_config 10
  stub_open_prs 4
  run_report
  [ "$status" -eq 0 ]
  [[ "$output" == *"Under cap"* ]]
  [[ "$output" == *"Counted toward cap | 4"* ]]
  [[ "$output" == *"Headroom (cap − counted) | 6"* ]]
}

# --------------------------------------------------------------------------
# At the cap -> "AT OR OVER CAP" with zero headroom
# --------------------------------------------------------------------------
@test "at the cap reports AT OR OVER CAP with zero headroom" {
  write_config 5
  stub_open_prs 5
  run_report
  [ "$status" -eq 0 ]
  [[ "$output" == *"AT OR OVER CAP"* ]]
  [[ "$output" == *"Headroom (cap − counted) | 0"* ]]
}

# --------------------------------------------------------------------------
# Over the cap -> "AT OR OVER CAP" with negative headroom
# --------------------------------------------------------------------------
@test "over the cap reports AT OR OVER CAP with negative headroom" {
  write_config 3
  stub_open_prs 7
  run_report
  [ "$status" -eq 0 ]
  [[ "$output" == *"AT OR OVER CAP"* ]]
  [[ "$output" == *"Counted toward cap | 7"* ]]
  [[ "$output" == *"Headroom (cap − counted) | -4"* ]]
}

# --------------------------------------------------------------------------
# Exempt-actor and exempt-labeled PRs are excluded from the counted figure
# but shown in the total (mirrors the admission gate, ADR §7.4).
# --------------------------------------------------------------------------
@test "exempt-actor and exempt-labeled PRs are excluded from the count" {
  write_config 3
  # 2 countable + 3 non-countable (1 exempt actor, 2 security-labeled) = 5 total,
  # only 2 count -> under the cap of 3.
  export GH_STUB_STDOUT
  GH_STUB_STDOUT="$(jq -nc '[
    { author: { login: "dev-lead-bot" },   labels: [],                    repository: { name: "a" }, title: "t", url: "u" },
    { author: { login: "claude-bot" },     labels: [],                    repository: { name: "b" }, title: "t", url: "u" },
    { author: { login: "dependabot[bot]" },labels: [],                    repository: { name: "c" }, title: "t", url: "u" },
    { author: { login: "claude-bot" },     labels: [{ name: "security" }],repository: { name: "d" }, title: "t", url: "u" },
    { author: { login: "claude-bot" },     labels: [{ name: "security" }],repository: { name: "e" }, title: "t", url: "u" }
  ]')"
  run_report
  [ "$status" -eq 0 ]
  [[ "$output" == *"Open non-draft PRs (total) | 5"* ]]
  [[ "$output" == *"Counted toward cap | 2"* ]]
  [[ "$output" == *"Exempt (actor or label) | 3"* ]]
  [[ "$output" == *"Under cap"* ]]
}

# --------------------------------------------------------------------------
# The by-source breakdown groups counted PRs by author login.
# --------------------------------------------------------------------------
@test "breakdown groups counted PRs by source author" {
  write_config 10
  export GH_STUB_STDOUT
  GH_STUB_STDOUT="$(jq -nc '[
    { author: { login: "dev-lead-bot" }, labels: [], repository: { name: "a" }, title: "t", url: "u" },
    { author: { login: "dev-lead-bot" }, labels: [], repository: { name: "b" }, title: "t", url: "u" },
    { author: { login: "claude-bot" },   labels: [], repository: { name: "c" }, title: "t", url: "u" }
  ]')"
  run_report
  [ "$status" -eq 0 ]
  [[ "$output" == *"| dev-lead-bot | 2 |"* ]]
  [[ "$output" == *"| claude-bot | 1 |"* ]]
}

# --------------------------------------------------------------------------
# Robust to an empty PR queue: report 0, not an error.
# --------------------------------------------------------------------------
@test "empty PR queue reports zero under cap without error" {
  write_config 50
  export GH_STUB_STDOUT="[]"
  run_report
  [ "$status" -eq 0 ]
  [[ "$output" == *"Open non-draft PRs (total) | 0"* ]]
  [[ "$output" == *"Counted toward cap | 0"* ]]
  [[ "$output" == *"Under cap"* ]]
  [[ "$output" == *"No counted automation PRs"* ]]
}

# --------------------------------------------------------------------------
# The report is read-only: never issues a mutating gh subcommand.
# --------------------------------------------------------------------------
@test "report issues only a read-only gh search" {
  write_config 10
  stub_open_prs 2
  run_report
  [ "$status" -eq 0 ]
  grep -q 'search prs' "$GH_STUB_LOG"
  ! grep -qE 'pr create|pr edit|api -X (POST|PATCH|PUT|DELETE)' "$GH_STUB_LOG"
}

# --------------------------------------------------------------------------
# Cap + exempt lists come from the config, not hardcoded: a different cap
# flips the status.
# --------------------------------------------------------------------------
@test "cap is read from the config (not hardcoded)" {
  write_config 4
  stub_open_prs 4
  run_report
  [ "$status" -eq 0 ]
  # 4 counted vs cap 4 -> at cap
  [[ "$output" == *"AT OR OVER CAP"* ]]
  [[ "$output" == *"| Cap | 4 |"* ]]
}

# --------------------------------------------------------------------------
# A null / missing author does not crash jq: it is counted as "unknown".
# --------------------------------------------------------------------------
@test "null or missing author is counted as unknown without a jq error" {
  write_config 10
  export GH_STUB_STDOUT
  GH_STUB_STDOUT="$(jq -nc '[
    { author: null,                       labels: [], repository: { name: "a" }, title: "t", url: "u" },
    { author: { login: "dev-lead-bot" },  labels: [], repository: { name: "b" }, title: "t", url: "u" },
    {                                     labels: [], repository: { name: "c" }, title: "t", url: "u" }
  ]')"
  run_report
  [ "$status" -eq 0 ]
  [[ "$output" == *"Open non-draft PRs (total) | 3"* ]]
  [[ "$output" == *"Counted toward cap | 3"* ]]
  # Both the null-author and the missing-author PR collapse to "unknown" (count 2).
  [[ "$output" == *"| unknown | 2 |"* ]]
  [[ "$output" == *"| dev-lead-bot | 1 |"* ]]
  # No jq error text leaked into the output.
  [[ "$output" != *"Cannot index"* ]]
}

# --------------------------------------------------------------------------
# Interleaved authors: group_by yields correct per-author counts regardless of
# input order (jq group_by sorts internally). Locks that invariant in.
# --------------------------------------------------------------------------
@test "interleaved authors are grouped correctly regardless of input order" {
  write_config 10
  export GH_STUB_STDOUT
  GH_STUB_STDOUT="$(jq -nc '[
    { author: { login: "a-bot" }, labels: [], repository: { name: "1" }, title: "t", url: "u" },
    { author: { login: "b-bot" }, labels: [], repository: { name: "2" }, title: "t", url: "u" },
    { author: { login: "a-bot" }, labels: [], repository: { name: "3" }, title: "t", url: "u" },
    { author: { login: "b-bot" }, labels: [], repository: { name: "4" }, title: "t", url: "u" },
    { author: { login: "a-bot" }, labels: [], repository: { name: "5" }, title: "t", url: "u" }
  ]')"
  run_report
  [ "$status" -eq 0 ]
  [[ "$output" == *"| a-bot | 3 |"* ]]
  [[ "$output" == *"| b-bot | 2 |"* ]]
}

# --------------------------------------------------------------------------
# A `gh` failure (non-zero exit) fails loudly: the report exits non-zero and
# prints "Metric unavailable" — NOT a fake "0/cap Under cap" table. Unlike the
# admission gate (which fails open for PR creation), a scheduled measurement
# report must not masquerade a query error as a real zero.
# --------------------------------------------------------------------------
@test "gh failure prints Metric unavailable and exits non-zero (no fake table)" {
  write_config 50
  export GH_STUB_EXIT=4
  export GH_STUB_STDOUT=""
  export GH_STUB_STDERR="simulated gh API error"
  run_report
  [ "$status" -ne 0 ]
  [[ "$output" == *"Metric unavailable"* ]]
  [[ "$output" == *"rc=4"* ]]
  # Must NOT emit the normal metrics table or an "under cap" verdict.
  [[ "$output" != *"Under cap"* ]]
  [[ "$output" != *"Counted toward cap"* ]]
}
