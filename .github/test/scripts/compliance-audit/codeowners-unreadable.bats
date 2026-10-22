#!/usr/bin/env bats
# Tests for check_codeowners' read-error handling in scripts/compliance-audit.sh.
#
# Issue #437: the audit filed `missing-codeowners` on a transient/auth read
# failure (e.g. a 404 that later proved wrong, or a 403/network blip), wasting a
# dev-lead run confirming a CODEOWNERS that existed all along. The fix mirrors
# check_check_suite_prefs (#487): a deterministic HTTP 404 on every candidate
# path is genuinely-absent (→ missing finding), but any non-404 error is
# inconclusive (→ `codeowners-unreadable` warning, never `missing-codeowners`).
bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

setup() {
  TEST_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  MOCK_BIN="$TEST_TMP/bin"
  mkdir -p "$MOCK_BIN"
  # No-op sleep so the retry path runs instantly.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/sleep"
  chmod +x "$MOCK_BIN/sleep"
}

teardown() { rm -rf "$TEST_TMP"; }

# _run_check <gh-mock-body>: install a mock gh, source the audit, run
# check_codeowners on a fake repo, and print findings.json for assertions.
_run_check() {
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$MOCK_BIN/gh"
  chmod +x "$MOCK_BIN/gh"
  PATH="$MOCK_BIN:$PATH" REPORT_DIR="$TEST_TMP" bash -c '
    set -uo pipefail
    echo "[]" > "$REPORT_DIR/findings.json"
    # shellcheck disable=SC1090
    source "'"$REPO_ROOT"'/scripts/compliance-audit.sh"
    check_codeowners "demo-repo"
    cat "$REPORT_DIR/findings.json"
  '
}

@test "all paths 404 (genuinely absent) → missing-codeowners error" {
  run _run_check 'echo "gh: Not Found (HTTP 404)" >&2; exit 1'
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing-codeowners"* ]]
  [[ "$output" != *"codeowners-unreadable"* ]]
}

@test "JSON status:404 body (no HTTP 404 header) → missing-codeowners error" {
  run _run_check 'printf '"'"'{"message":"Not Found","status":"404"}'"'"'\n; exit 1'
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing-codeowners"* ]]
  [[ "$output" != *"codeowners-unreadable"* ]]
}

@test "403 (no scope) is inconclusive → codeowners-unreadable warning, NOT missing (#437)" {
  run _run_check 'echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1'
  [ "$status" -eq 0 ]
  [[ "$output" == *"codeowners-unreadable"* ]]
  [[ "$output" == *"warning"* ]]
  [[ "$output" != *"missing-codeowners"* ]]
}

@test "network failure is inconclusive → codeowners-unreadable, NOT missing (#437)" {
  run _run_check 'echo "error connecting to api.github.com" >&2; exit 1'
  [ "$status" -eq 0 ]
  [[ "$output" == *"codeowners-unreadable"* ]]
  [[ "$output" != *"missing-codeowners"* ]]
}

@test "successful read of a compliant CODEOWNERS → no missing/unreadable finding" {
  b64="$(printf '* @petry-projects/org-leads\n' | base64 | tr -d '\n')"
  run _run_check 'printf "{\"content\":\"'"$b64"'\"}\n"; exit 0'
  [ "$status" -eq 0 ]
  [[ "$output" != *"missing-codeowners"* ]]
  [[ "$output" != *"codeowners-unreadable"* ]]
}
