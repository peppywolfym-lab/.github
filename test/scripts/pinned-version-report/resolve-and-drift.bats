#!/usr/bin/env bats
# Tests for scripts/pinned-version-report.sh — SC8 pin-resolution and drift detection.
#
# Covers the key decision paths:
#   - resolve_version: channel tag resolves to a vX.Y.Z release (SHA match)
#   - resolve_version: channel tag present but no vX.Y.Z shares its SHA → ?(sha)
#   - resolve_version: channel tag absent entirely → ?
#   - Drift detection: tier match → ✅, tier mismatch → ⚠️
#   - Fan-out table: no blank version entries (trailing-space regression, #502)
#
# gh is stubbed via test/scripts/pinned-version-report/stubs/gh; no live API.

bats_require_minimum_version 1.5.0

SCRIPT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/scripts/pinned-version-report.sh"
GH_STUB="$(cd "$BATS_TEST_DIRNAME" && pwd)/stubs/gh"

setup() {
  TMP="$(mktemp -d)"
  export TMP
  mkdir -p "$TMP/bin"
  cp "$GH_STUB" "$TMP/bin/gh"
  chmod +x "$TMP/bin/gh"
  PATH="$TMP/bin:$PATH"
  export PATH
  export GH_STUB_LOG="$TMP/gh.log"
  : >"$GH_STUB_LOG"
  export ORG="petry-projects"
  # Default: one stable-tier repo (anything not in the explicit ring lists)
  export GH_STUB_REPOS="my-fleet-repo"
  # Workflow content: a stub that pins dev-lead-reusable.yml@dev-lead/stable.
  # The script base64-decodes the content, so the stub returns base64 text.
  export GH_STUB_CONTENTS
  GH_STUB_CONTENTS="$(printf 'jobs:\n  dev-lead:\n    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/stable\n    secrets: inherit\n' | base64)"
  # Default: no tags (unresolved channel)
  export GH_STUB_TAGS_TSV=""
}

teardown() {
  [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP"
}

run_report() {
  run bash "$SCRIPT"
}

# ── resolve_version ────────────────────────────────────────────────────────────

@test "channel tag resolves to vX.Y.Z when SHA matches a release tag" {
  # dev-lead/stable and dev-lead/v2.1.0 share the same SHA: channel resolves.
  GH_STUB_TAGS_TSV="$(printf 'dev-lead/stable\tabcdef1234567890\ndev-lead/v2.1.0\tabcdef1234567890\n')"
  run_report
  [ "$status" -eq 0 ]
  [[ "$output" == *"v2.1.0"* ]]
}

@test "channel tag present but no vX.Y.Z shares its SHA gives SHA hint" {
  # dev-lead/stable exists but its SHA has no matching release tag → ?(sha).
  # First 8 chars of abcdef1234567890 = abcdef12
  GH_STUB_TAGS_TSV="$(printf 'dev-lead/stable\tabcdef1234567890\n')"
  run_report
  [ "$status" -eq 0 ]
  grep -qF "?(abcdef12)" <<< "$output"
}

@test "channel tag absent entirely gives plain ?" {
  # No tags at all: SHA lookup fails, resolve_version returns ?.
  GH_STUB_TAGS_TSV=""
  run_report
  [ "$status" -eq 0 ]
  # The version column in the main table should contain the literal `?`
  grep -qF '`?`' <<< "$output"
}

# ── drift detection ────────────────────────────────────────────────────────────

@test "tier match: stable-tier repo pinning stable channel shows no drift" {
  # my-fleet-repo → stable tier; stub pins dev-lead/stable → no mismatch.
  GH_STUB_TAGS_TSV=""
  run_report
  [ "$status" -eq 0 ]
  [[ "$output" == *"✅"* ]]
  [[ "$output" != *"⚠️"* ]]
}

@test "tier mismatch: ring1-tier repo pinning stable channel shows drift flag" {
  # TalkTerm → ring1 tier; stub pins dev-lead/stable → drift.
  GH_STUB_REPOS="TalkTerm"
  GH_STUB_TAGS_TSV=""
  run_report
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠️"* ]]
}

# ── fan-out table (trailing-space regression) ──────────────────────────────────

@test "fan-out table has no blank version entry from trailing space (#502)" {
  # Before fix: vers+='v2.1.0 ' then tr ' ' '\n' creates an empty token that
  # sort-u promotes to a leading space in the cell: "|  v2.1.0  |".
  # After fix (array-based join): "| v2.1.0 |" with no extra whitespace.
  GH_STUB_TAGS_TSV="$(printf 'dev-lead/stable\tabcdef1234567890\ndev-lead/v2.1.0\tabcdef1234567890\n')"
  run_report
  [ "$status" -eq 0 ]
  # Fan-out rows are NOT backtick-wrapped (unlike main table); look for
  # the exact "| v2.1.0 |" pattern. With the bug, the cell starts with a
  # space ("| " + " v2.1.0") and would not match this pattern.
  grep -qF '| v2.1.0 |' <<< "$output"
}
