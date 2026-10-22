#!/usr/bin/env bats
# Tests for .github/scripts/feature-ideation/lib/compose-signals.sh
#
# Kills R4 (jq --argjson crash on empty inputs) and R3 (no contract for
# the signals payload). Schema validation lives in signals-schema.bats;
# this file pins the composition logic itself.

load 'helpers/setup'

setup() {
  # shellcheck source=/dev/null
  . "${TT_SCRIPTS_DIR}/lib/compose-signals.sh"
}

# Helper: invoke compose_signals with all-empty buckets and a fixed scan_date.
compose_empty() {
  compose_signals \
    '[]' '[]' '[]' '[]' '[]' '[]' '[]' \
    'foo/bar' \
    '2026-04-07T00:00:00Z' \
    '1.0.0' \
    '[]'
}

# ---------------------------------------------------------------------------
# Argument validation (R4)
# ---------------------------------------------------------------------------

@test "compose: rejects wrong arg count" {
  run compose_signals '[]' '[]'
  [ "$status" -ne 0 ]
}

@test "compose: rejects empty string for any JSON arg" {
  run compose_signals \
    '' '[]' '[]' '[]' '[]' '[]' '[]' \
    'foo/bar' '2026-04-07T00:00:00Z' '1.0.0' '[]'
  [ "$status" -ne 0 ]
}

@test "compose: rejects non-JSON for any JSON arg" {
  run compose_signals \
    'not json' '[]' '[]' '[]' '[]' '[]' '[]' \
    'foo/bar' '2026-04-07T00:00:00Z' '1.0.0' '[]'
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Output shape (R3)
# ---------------------------------------------------------------------------

@test "compose: produces all required top-level fields with empty inputs" {
  run compose_empty
  [ "$status" -eq 0 ]
  for field in schema_version scan_date repo open_issues closed_issues_30d \
               ideas_discussions releases merged_prs_30d feature_requests \
               bug_reports truncation_warnings; do
    printf '%s' "$output" | jq -e "has(\"$field\")" >/dev/null
  done
}

@test "compose: count fields equal items length" {
  open='[{"number":1,"title":"a","labels":[]},{"number":2,"title":"b","labels":[]}]'
  run compose_signals \
    "$open" '[]' '[]' '[]' '[]' '[]' '[]' \
    'foo/bar' '2026-04-07T00:00:00Z' '1.0.0' '[]'
  [ "$status" -eq 0 ]
  count=$(printf '%s' "$output" | jq '.open_issues.count')
  items_len=$(printf '%s' "$output" | jq '.open_issues.items | length')
  [ "$count" = "2" ]
  [ "$items_len" = "2" ]
}

@test "compose: schema_version is preserved verbatim" {
  run compose_signals \
    '[]' '[]' '[]' '[]' '[]' '[]' '[]' \
    'foo/bar' '2026-04-07T00:00:00Z' '2.5.1' '[]'
  [ "$status" -eq 0 ]
  v=$(printf '%s' "$output" | jq -r '.schema_version')
  [ "$v" = "2.5.1" ]
}

@test "compose: truncation_warnings round-trip" {
  warnings='[{"source":"open_issues","limit":50,"message":"truncated"}]'
  run compose_signals \
    '[]' '[]' '[]' '[]' '[]' '[]' '[]' \
    'foo/bar' '2026-04-07T00:00:00Z' '1.0.0' "$warnings"
  [ "$status" -eq 0 ]
  src=$(printf '%s' "$output" | jq -r '.truncation_warnings[0].source')
  [ "$src" = "open_issues" ]
}

@test "compose: scan_date and repo round-trip exactly" {
  run compose_signals \
    '[]' '[]' '[]' '[]' '[]' '[]' '[]' \
    'octocat/hello-world' '2030-01-15T12:34:56Z' '1.0.0' '[]'
  [ "$status" -eq 0 ]
  d=$(printf '%s' "$output" | jq -r '.scan_date')
  r=$(printf '%s' "$output" | jq -r '.repo')
  [ "$d" = "2030-01-15T12:34:56Z" ]
  [ "$r" = "octocat/hello-world" ]
}
