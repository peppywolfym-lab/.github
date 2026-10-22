#!/usr/bin/env bats
# Tests for check_check_suite_prefs in scripts/compliance-audit.sh.
#
# The GET repos/{owner}/{repo}/check-suites/preferences endpoint returns 404
# when preferences have never been set — i.e. no app (Claude/CodeRabbit) has
# created a check run yet, so no orphaned "queued" suite can exist. That is the
# compliant "missing" state, NOT a read failure, and must not raise a finding.
# Only a genuine unreadable error (auth/scope/network) should raise the
# `check-suite-prefs-unreadable` warning. These tests pin that distinction plus
# the per-app auto-trigger evaluation. (Locks the fix for issue #487.)

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

setup() {
  TEST_TMP="$(mktemp -d)"
  MOCK_BIN="$TEST_TMP/bin"
  mkdir -p "$MOCK_BIN"
  # No-op sleep so the retry path in check_check_suite_prefs runs instantly.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/sleep"
  chmod +x "$MOCK_BIN/sleep"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# _run_check <gh-mock-body>
# Installs a mock `gh` whose body is the supplied script, sources the audit
# script in a clean subshell, runs check_check_suite_prefs on a fake repo, and
# prints the resulting findings.json so callers can assert on it.
_run_check() {
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$MOCK_BIN/gh"
  chmod +x "$MOCK_BIN/gh"
  PATH="$MOCK_BIN:$PATH" REPORT_DIR="$TEST_TMP" bash -c '
    set -uo pipefail
    echo "[]" > "$REPORT_DIR/findings.json"
    # shellcheck disable=SC1090
    source "'"$REPO_ROOT"'/scripts/compliance-audit.sh"
    check_check_suite_prefs "demo-repo"
    cat "$REPORT_DIR/findings.json"
  '
}

# ---------------------------------------------------------------------------
# Benign 404 → preferences never set → compliant, no finding
# ---------------------------------------------------------------------------
@test "GET 404 (prefs never set) raises no finding" {
  run _run_check 'echo "gh: Not Found (HTTP 404)" >&2; exit 1'
  [ "$status" -eq 0 ]
  [[ "$output" != *"check-suite-prefs-unreadable"* ]]
  [[ "$output" != *"check-suite-auto-trigger"* ]]
}

# ---------------------------------------------------------------------------
# Genuine read failure → unreadable warning IS raised
# ---------------------------------------------------------------------------
@test "GET 403 (no scope) raises the unreadable warning" {
  run _run_check 'echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1'
  [ "$status" -eq 0 ]
  [[ "$output" == *"check-suite-prefs-unreadable"* ]]
  [[ "$output" == *"warning"* ]]
}

@test "GET network failure raises the unreadable warning" {
  run _run_check 'echo "error connecting to api.github.com" >&2; exit 1'
  [ "$status" -eq 0 ]
  [[ "$output" == *"check-suite-prefs-unreadable"* ]]
}

# ---------------------------------------------------------------------------
# Successful read → per-app auto-trigger evaluation
# ---------------------------------------------------------------------------
@test "both apps auto_trigger disabled → no finding" {
  run _run_check "cat <<'JSON'
{\"preferences\":{\"auto_trigger_checks\":[{\"app_id\":1236702,\"setting\":false},{\"app_id\":347564,\"setting\":false}]}}
JSON"
  [ "$status" -eq 0 ]
  [[ "$output" != *"check-suite-prefs-unreadable"* ]]
  [[ "$output" != *"check-suite-auto-trigger"* ]]
}

@test "an app with auto_trigger enabled → auto-trigger error finding" {
  run _run_check "cat <<'JSON'
{\"preferences\":{\"auto_trigger_checks\":[{\"app_id\":1236702,\"setting\":true},{\"app_id\":347564,\"setting\":false}]}}
JSON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"check-suite-auto-trigger-1236702"* ]]
  [[ "$output" == *"error"* ]]
  [[ "$output" != *"check-suite-prefs-unreadable"* ]]
}

@test "an app absent from prefs (missing) → no finding" {
  run _run_check "cat <<'JSON'
{\"preferences\":{\"auto_trigger_checks\":[]}}
JSON"
  [ "$status" -eq 0 ]
  [[ "$output" != *"check-suite-auto-trigger"* ]]
  [[ "$output" != *"check-suite-prefs-unreadable"* ]]
}
