#!/usr/bin/env bats
# Tests for close_resolved_issues() and the read-only execution guard in
# scripts/compliance-audit.sh (issue #1036).
#
# The closer used to close ANY open issue carrying the `compliance-audit` label
# whose stripped title was absent from the current findings set — fail-open where
# the detection paths are fail-closed. That destroyed umbrella issues (title never
# matched) and every hand-filed issue anyone labelled `compliance-audit`, and it
# ran whenever the script executed. These tests pin the fixed contract:
#
#   AC1  — only close issues titled exactly `Compliance: <check>`.
#   AC1b — only close issues whose body carries the audit's generated-by marker.
#   AC1c — enumerate/close only issues carrying the machine label `compliance-finding`.
#   AC1d — an audit-labelled issue with a non-matching title and no marker survives.
#   AC2  — never close for a repo that was not scanned this run.
#   AC3  — never close anything when total findings across all repos is zero.
#   AC4  — default read-only: no mutation without --apply / COMPLIANCE_AUDIT_APPLY.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

setup() {
  TEST_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/car.XXXXXX")"
  MOCK_BIN="$TEST_TMP/bin"
  mkdir -p "$MOCK_BIN"
  # No-op sleep so any retry path runs instantly.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/sleep"
  chmod +x "$MOCK_BIN/sleep"

  # Mock gh: `issue list` echoes the fixture JSON; `issue close` records the
  # closed issue number so a test can assert exactly what was (not) closed.
  # `label create`, `issue comment`, `issue edit`, and `auth` are no-ops.
  MOCK_ISSUES_JSON="$TEST_TMP/issues.json"
  MOCK_CLOSED_FILE="$TEST_TMP/closed.txt"
  : > "$MOCK_CLOSED_FILE"
  cat > "$MOCK_BIN/gh" << 'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list")  cat "$MOCK_ISSUES_JSON" ;;
  "issue close")
    # gh issue close <number> --repo ... ; the number is $3
    echo "$3" >> "$MOCK_CLOSED_FILE" ;;
  *) : ;;
esac
exit 0
GH
  chmod +x "$MOCK_BIN/gh"
}

teardown() { rm -rf "$TEST_TMP"; }

MARKER='<!-- compliance-audit:generated -->'

# _issue <number> <title> <body> : emit one issue object for the fixture array.
_issue() {
  jq -n --arg n "$1" --arg t "$2" --arg b "$3" \
    '{number:($n|tonumber),title:$t,body:$b}'
}

# _run_close <findings-json> <issues-json> <audited-repos-newline-list> : set up
# the report dir, source the audit, run close_resolved_issues for demo-repo, and
# print the newline list of issue numbers that were closed.
_run_close() {
  local findings="$1" issues="$2" audited="$3"
  echo "$findings" > "$TEST_TMP/findings.json"
  echo "$issues"   > "$MOCK_ISSUES_JSON"
  printf '%s\n' "$audited" > "$TEST_TMP/audited-repos.txt"
  # Silence the audit's INFO/WARN diagnostics (stderr) so the only thing `run`
  # captures is the list of issue numbers the mock actually CLOSED — otherwise a
  # "Skipping #<n> …" log line would look like a closure to a substring assert.
  MOCK_ISSUES_JSON="$MOCK_ISSUES_JSON" MOCK_CLOSED_FILE="$MOCK_CLOSED_FILE" \
  PATH="$MOCK_BIN:$PATH" REPORT_DIR="$TEST_TMP" bash -c '
    set -uo pipefail
    export MOCK_ISSUES_JSON MOCK_CLOSED_FILE
    # shellcheck disable=SC1090
    source "'"$REPO_ROOT"'/scripts/compliance-audit.sh"
    close_resolved_issues "demo-repo" || true
  ' 2>/dev/null
  cat "$MOCK_CLOSED_FILE"
}

@test "AC1: umbrella-titled issue survives even though its title is absent from findings" {
  findings='[{"repo":"demo-repo","check":"missing-ci.yml"}]'
  issues="[$(_issue 1014 'Compliance audit — 2026-01-01' "umbrella body $MARKER")]"
  run _run_close "$findings" "$issues" "demo-repo"
  [ "$status" -eq 0 ]
  [[ "$output" != *"1014"* ]]
}

@test "AC1d: audit-labelled issue with non-matching title and no marker survives" {
  findings='[{"repo":"demo-repo","check":"missing-ci.yml"}]'
  issues="[$(_issue 1045 'apply-repo-settings can never reach the fleet' 'hand-filed engineering issue, no marker')]"
  run _run_close "$findings" "$issues" "demo-repo"
  [ "$status" -eq 0 ]
  [[ "$output" != *"1045"* ]]
}

@test "AC1b: a Compliance:-titled issue with NO generated-by marker survives" {
  # A human could file "Compliance: <something>" by hand. Without the marker it
  # must not be closable, even though the title shape matches.
  findings='[{"repo":"demo-repo","check":"missing-ci.yml"}]'
  issues="[$(_issue 2001 'Compliance: hand-written-note' 'filed by a person, no marker')]"
  run _run_close "$findings" "$issues" "demo-repo"
  [ "$status" -eq 0 ]
  [[ "$output" != *"2001"* ]]
}

@test "resolved machine finding (marker + matching title, check absent) is closed" {
  findings='[{"repo":"demo-repo","check":"missing-ci.yml"}]'
  issues="[$(_issue 3001 'Compliance: settings-has_wiki' "generated $MARKER")]"
  run _run_close "$findings" "$issues" "demo-repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"3001"* ]]
}

@test "still-live machine finding (check present) survives" {
  findings='[{"repo":"demo-repo","check":"missing-ci.yml"}]'
  issues="[$(_issue 3002 'Compliance: missing-ci.yml' "generated $MARKER")]"
  run _run_close "$findings" "$issues" "demo-repo"
  [ "$status" -eq 0 ]
  [[ "$output" != *"3002"* ]]
}

@test "legacy generated-by footer (no explicit marker) is still recognised as machine-created" {
  local footer='*This issue was automatically created by the [weekly compliance audit](https://github.com/petry-projects/.github/blob/main/.github/workflows/compliance-audit.yml).*'
  findings='[{"repo":"demo-repo","check":"missing-ci.yml"}]'
  issues="[$(_issue 3003 'Compliance: settings-has_wiki' "body ... $footer")]"
  run _run_close "$findings" "$issues" "demo-repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"3003"* ]]
}

@test "AC2: a repo that was not scanned this run has no issue closed" {
  findings='[{"repo":"other-repo","check":"missing-ci.yml"}]'
  # demo-repo is NOT in the audited list — its resolvable-looking issue must survive.
  issues="[$(_issue 4001 'Compliance: settings-has_wiki' "generated $MARKER")]"
  run _run_close "$findings" "$issues" "other-repo"
  [ "$status" -eq 0 ]
  [[ "$output" != *"4001"* ]]
}

@test "AC3: zero total findings closes nothing (failed scan, not a compliant org)" {
  findings='[]'
  issues="[$(_issue 5001 'Compliance: settings-has_wiki' "generated $MARKER")]"
  run _run_close "$findings" "$issues" "demo-repo"
  [ "$status" -eq 0 ]
  [[ "$output" != *"5001"* ]]
}

# ---------------------------------------------------------------------------
# Pure helper coverage
# ---------------------------------------------------------------------------
_source_audit() {
  # shellcheck disable=SC1090
  PATH="$MOCK_BIN:$PATH" REPORT_DIR="$TEST_TMP" source "$REPO_ROOT/scripts/compliance-audit.sh"
}

@test "issue_has_generated_marker: explicit marker, legacy footer, and neither" {
  run bash -c '
    set -uo pipefail
    REPORT_DIR="'"$TEST_TMP"'" source "'"$REPO_ROOT"'/scripts/compliance-audit.sh"
    issue_has_generated_marker "x '"$MARKER"' y" && echo "marker:yes" || echo "marker:no"
    issue_has_generated_marker "automatically created by the [weekly compliance audit] here" && echo "footer:yes" || echo "footer:no"
    issue_has_generated_marker "a plain hand-filed issue body" && echo "plain:yes" || echo "plain:no"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"marker:yes"* ]]
  [[ "$output" == *"footer:yes"* ]]
  [[ "$output" == *"plain:no"* ]]
}

@test "repo_was_audited: present vs absent in the audited-repos record" {
  printf 'alpha\nbeta\n' > "$TEST_TMP/audited-repos.txt"
  run bash -c '
    set -uo pipefail
    REPORT_DIR="'"$TEST_TMP"'" source "'"$REPO_ROOT"'/scripts/compliance-audit.sh"
    repo_was_audited "beta"  && echo "beta:yes"  || echo "beta:no"
    repo_was_audited "gamma" && echo "gamma:yes" || echo "gamma:no"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"beta:yes"* ]]
  [[ "$output" == *"gamma:no"* ]]
}

@test "AC4: check_labels files a finding (no mutation) when not in apply mode" {
  # In read-only mode a missing required label must be reported, never created.
  run bash -c '
    set -uo pipefail
    export APPLY="false" DRY_RUN="false"
    PATH="'"$MOCK_BIN"':$PATH" REPORT_DIR="'"$TEST_TMP"'" bash -c "
      set -uo pipefail
      echo \"[]\" > \"'"$TEST_TMP"'/findings.json\"
      source \"'"$REPO_ROOT"'/scripts/compliance-audit.sh\"
      # mock gh returns no existing labels for the list call
      check_labels demo-repo
      cat \"'"$TEST_TMP"'/findings.json\"
    "
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing-label-"* ]]
}

@test "repo with inconclusive checks has no issue closed (failed workflow-list request guard)" {
  # If check_action_pinning's workflow-list fetch fails, the repo is marked
  # inconclusive. Any open finding issue in that repo must NOT be closed.
  findings='[{"repo":"demo-repo","check":"missing-ci.yml"}]'
  issues="[$(_issue 6001 'Compliance: settings-has_wiki' "generated $MARKER")]"
  # Create both audited-repos and inconclusive-repos files
  echo "$findings" > "$TEST_TMP/findings.json"
  echo "$issues"   > "$MOCK_ISSUES_JSON"
  printf 'demo-repo\n' > "$TEST_TMP/audited-repos.txt"
  printf 'demo-repo\n' > "$TEST_TMP/inconclusive-repos.txt"

  MOCK_ISSUES_JSON="$MOCK_ISSUES_JSON" MOCK_CLOSED_FILE="$MOCK_CLOSED_FILE" \
  PATH="$MOCK_BIN:$PATH" REPORT_DIR="$TEST_TMP" bash -c '
    set -uo pipefail
    export MOCK_ISSUES_JSON MOCK_CLOSED_FILE
    # shellcheck disable=SC1090
    source "'"$REPO_ROOT"'/scripts/compliance-audit.sh"
    close_resolved_issues "demo-repo" || true
  ' 2>/dev/null

  run cat "$MOCK_CLOSED_FILE"
  [ "$status" -eq 0 ]
  # Issue should NOT be closed
  [[ "$output" != *"6001"* ]]
}
