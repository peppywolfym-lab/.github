#!/usr/bin/env bats
# Tests for the push-protection security_and_analysis remediation path added
# to scripts/compliance-remediate.sh.
#
# Before this change, every push-protection/* finding was routed to the
# `report_skip` catch-all. This suite pins the new behaviour: the specific
# `secret_scanning_non_provider_patterns` finding now PATCHes the nested
# security_and_analysis setting on the repo, and the rest of the
# push-protection/* catch-all is preserved.

bats_require_minimum_version 1.5.0

load 'helpers/setup'

setup() {
  tt_make_tmpdir
  tt_install_gh_stub
  export GH_STUB_LOG="${TT_TMP}/gh.log"
  export GH_STUB_STDIN_LOG="${TT_TMP}/gh.stdin"
  : >"$GH_STUB_LOG"
  : >"$GH_STUB_STDIN_LOG"
}

teardown() {
  tt_cleanup_tmpdir
}

# ---------------------------------------------------------------------------
# Apply path: non_provider_patterns_enabled (canonical audit check name)
# is auto-remediated
# ---------------------------------------------------------------------------

@test "applies PATCH to security_and_analysis for non_provider_patterns_enabled" {
  findings="$(tt_write_finding ".github" "push-protection" "non_provider_patterns_enabled")"
  report_dir="${TT_TMP}/report"

  GH_TOKEN=fake \
    FINDINGS_FILE="$findings" \
    REPORT_DIR="$report_dir" \
    DRY_RUN=false \
    run bash "$TT_SCRIPT"

  [ "$status" -eq 0 ]

  # gh was called with `api -X PATCH repos/petry-projects/.github --input -`
  grep -qE 'api -X PATCH repos/petry-projects/\.github (.*)--input -' "$GH_STUB_LOG"

  # The stdin payload must enable the specific setting via the nested object
  grep -q '"security_and_analysis"' "$GH_STUB_STDIN_LOG"
  grep -q '"secret_scanning_non_provider_patterns"' "$GH_STUB_STDIN_LOG"
  grep -q '"enabled"' "$GH_STUB_STDIN_LOG"

  # The finding should land in the direct-fix table, not in skipped
  grep -q 'non_provider_patterns_enabled' "$report_dir/remediation-report.md"
  ! grep -q 'non_provider_patterns_enabled' "$report_dir/skipped.md"
}

# Backward-compat alias: the legacy `secret_scanning_non_provider_patterns`
# finding name is still routed to the same handler.
@test "applies PATCH to security_and_analysis for secret_scanning_non_provider_patterns (legacy alias)" {
  findings="$(tt_write_finding ".github" "push-protection" "secret_scanning_non_provider_patterns")"
  report_dir="${TT_TMP}/report"

  GH_TOKEN=fake \
    FINDINGS_FILE="$findings" \
    REPORT_DIR="$report_dir" \
    DRY_RUN=false \
    run bash "$TT_SCRIPT"

  [ "$status" -eq 0 ]

  # gh was called with `api -X PATCH repos/petry-projects/.github --input -`
  grep -qE 'api -X PATCH repos/petry-projects/\.github (.*)--input -' "$GH_STUB_LOG"

  # The stdin payload must enable the specific setting via the nested object
  grep -q '"security_and_analysis"' "$GH_STUB_STDIN_LOG"
  grep -q '"secret_scanning_non_provider_patterns"' "$GH_STUB_STDIN_LOG"
  grep -q '"enabled"' "$GH_STUB_STDIN_LOG"

  # The finding should land in the direct-fix table, not in skipped
  grep -q 'secret_scanning_non_provider_patterns' "$report_dir/remediation-report.md"
  ! grep -q 'secret_scanning_non_provider_patterns' "$report_dir/skipped.md"
}

# ---------------------------------------------------------------------------
# Dry-run path: no API call is made, but the finding shows up as a dry-run
# entry on the remediation report (not in the skipped report).
# ---------------------------------------------------------------------------

@test "dry-run does not call the GitHub API but records the planned change" {
  findings="$(tt_write_finding ".github" "push-protection" "secret_scanning_non_provider_patterns")"
  report_dir="${TT_TMP}/report"

  GH_TOKEN=fake \
    FINDINGS_FILE="$findings" \
    REPORT_DIR="$report_dir" \
    DRY_RUN=true \
    run bash "$TT_SCRIPT"

  [ "$status" -eq 0 ]

  # No PATCH call should have been logged
  ! grep -qE 'api -X PATCH repos/petry-projects/\.github' "$GH_STUB_LOG"

  # And the finding still lands on the remediation report, not skipped
  grep -q 'secret_scanning_non_provider_patterns' "$report_dir/remediation-report.md"
}

# ---------------------------------------------------------------------------
# Failure path: when the PATCH fails, the finding is reported as failed
# rather than as a successful remediation.
# ---------------------------------------------------------------------------

@test "failed PATCH is reported as a failure" {
  findings="$(tt_write_finding ".github" "push-protection" "secret_scanning_non_provider_patterns")"
  report_dir="${TT_TMP}/report"

  GH_TOKEN=fake \
    GH_STUB_EXIT=1 \
    GH_STUB_STDERR="HTTP 403: forbidden" \
    FINDINGS_FILE="$findings" \
    REPORT_DIR="$report_dir" \
    DRY_RUN=false \
    run bash "$TT_SCRIPT"

  # The script's main() exits non-zero when failed_count > 0
  [ "$status" -ne 0 ]

  # And the finding is in the skipped/failed report with a FAILED prefix
  grep -q 'FAILED' "$report_dir/skipped.md"
}

# ---------------------------------------------------------------------------
# Catch-all preserved: other push-protection/* findings still skip
# ---------------------------------------------------------------------------

@test "non-remediated push-protection findings still hit the skip path" {
  findings="$(tt_write_finding ".github" "push-protection" "open_secret_alerts")"
  report_dir="${TT_TMP}/report"

  GH_TOKEN=fake \
    FINDINGS_FILE="$findings" \
    REPORT_DIR="$report_dir" \
    DRY_RUN=false \
    run bash "$TT_SCRIPT"

  [ "$status" -eq 0 ]

  # No PATCH call should be issued for this category
  ! grep -qE 'api -X PATCH' "$GH_STUB_LOG"

  # Finding should be in the skipped report
  grep -q 'open_secret_alerts' "$report_dir/skipped.md"
}
