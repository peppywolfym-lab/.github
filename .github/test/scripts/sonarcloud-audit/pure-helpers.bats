#!/usr/bin/env bats
# Unit tests for the pure helpers in scripts/sonarcloud-audit.sh:
#   classify_workstream, family_title, family_is_security,
#   sonar_project_to_repo, severity_rank, severity_priority_label.
#
# The script's `main` is guarded, so sourcing only defines functions — the real
# helpers are exercised directly in an isolated subshell.

bats_require_minimum_version 1.5.0

SCRIPT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/scripts/sonarcloud-audit.sh"

call() {
  local func="$1"
  shift
  run bash -c 'source "$1" >/dev/null 2>&1; shift; "$@"' _ "$SCRIPT" "$func" "$@"
}

# ── classify_workstream ────────────────────────────────────────────────────
@test "S7635 → s7635 (its own family, not generic ghactions)" {
  call classify_workstream "githubactions:S7635"; [ "$output" = "s7635" ]
}
@test "githubactions:S1135 (TODO tag) → misc, not ghactions-security" {
  call classify_workstream "githubactions:S1135"; [ "$output" = "misc" ]
}
@test "other githubactions rule → ghactions" {
  call classify_workstream "githubactions:S6505"; [ "$output" = "ghactions" ]
}
@test "text lockfile rule → ghactions" {
  call classify_workstream "text:S8564"; [ "$output" = "ghactions" ]
}
@test "shelldre rule → shell" {
  call classify_workstream "shelldre:S7688"; [ "$output" = "shell" ]
}
@test "pythonsecurity rule → pysec" {
  call classify_workstream "pythonsecurity:S8707"; [ "$output" = "pysec" ]
}
@test "python:S3776 → complexity (not misc)" {
  call classify_workstream "python:S3776"; [ "$output" = "complexity" ]
}
@test "javascript:S3776 → complexity (not jsquality)" {
  call classify_workstream "javascript:S3776"; [ "$output" = "complexity" ]
}
@test "javascript:S5906 → tests (its own family)" {
  call classify_workstream "javascript:S5906"; [ "$output" = "tests" ]
}
@test "other javascript rule → jsquality" {
  call classify_workstream "javascript:S6582"; [ "$output" = "jsquality" ]
}
@test "typescript rule → jsquality" {
  call classify_workstream "typescript:S1234"; [ "$output" = "jsquality" ]
}
@test "css rule → misc" {
  call classify_workstream "css:S7924"; [ "$output" = "misc" ]
}
@test "unknown rule → misc" {
  call classify_workstream "docker:S6471"; [ "$output" = "misc" ]
}

# ── sonar_project_to_repo ──────────────────────────────────────────────────
@test "strips org prefix" {
  call sonar_project_to_repo "petry-projects_markets"; [ "$output" = "markets" ]
}
@test "broodminder-export2 key maps to the real repo broodminder-export" {
  call sonar_project_to_repo "petry-projects_broodminder-export2"; [ "$output" = "broodminder-export" ]
}
@test "dotted repo name survives prefix strip" {
  call sonar_project_to_repo "petry-projects_.github"; [ "$output" = ".github" ]
}

# ── severity_rank ordering ─────────────────────────────────────────────────
@test "severity ranks are strictly ordered blocker>critical>major>minor>info" {
  run bash -c 'source "$1" >/dev/null 2>&1;
    [ "$(severity_rank BLOCKER)" -gt "$(severity_rank CRITICAL)" ] &&
    [ "$(severity_rank CRITICAL)" -gt "$(severity_rank MAJOR)" ] &&
    [ "$(severity_rank MAJOR)" -gt "$(severity_rank MINOR)" ] &&
    [ "$(severity_rank MINOR)" -gt "$(severity_rank INFO)" ]' _ "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ── severity_priority_label mapping ────────────────────────────────────────
@test "BLOCKER → priority:blocker" {
  call severity_priority_label "BLOCKER"; [ "$output" = "priority:blocker" ]
}
@test "CRITICAL → priority:critical" {
  call severity_priority_label "CRITICAL"; [ "$output" = "priority:critical" ]
}
@test "MAJOR → priority:major" {
  call severity_priority_label "MAJOR"; [ "$output" = "priority:major" ]
}
@test "MINOR → priority:minor" {
  call severity_priority_label "MINOR"; [ "$output" = "priority:minor" ]
}
@test "INFO → priority:info" {
  call severity_priority_label "INFO"; [ "$output" = "priority:info" ]
}
@test "unknown severity defaults to priority:minor" {
  call severity_priority_label "WEIRD"; [ "$output" = "priority:minor" ]
}

# ── family_is_security ─────────────────────────────────────────────────────
@test "s7635 is a security family" {
  call family_is_security s7635; [ "$status" -eq 0 ]
}
@test "ghactions is a security family" {
  call family_is_security ghactions; [ "$status" -eq 0 ]
}
@test "pysec is a security family" {
  call family_is_security pysec; [ "$status" -eq 0 ]
}
@test "shell is NOT a security family" {
  call family_is_security shell; [ "$status" -ne 0 ]
}
@test "tests is NOT a security family" {
  call family_is_security tests; [ "$status" -ne 0 ]
}

# ── issue_marker (hidden idempotency key) ──────────────────────────────────
@test "issue_marker embeds a stable repo/family key as an HTML comment" {
  run bash -c 'source "$1" >/dev/null 2>&1; issue_marker "$2" "$3"' _ "$SCRIPT" "markets" "ghactions"
  [ "$output" = "<!-- sonarcloud-audit:key=markets/ghactions -->" ]
}
@test "issue_marker handles dotted repo names (.github)" {
  run bash -c 'source "$1" >/dev/null 2>&1; issue_marker "$2" "$3"' _ "$SCRIPT" ".github" "misc"
  [ "$output" = "<!-- sonarcloud-audit:key=.github/misc -->" ]
}

# ── family_title stability (used as the idempotency key) ───────────────────
@test "family_title is non-empty for every known family" {
  run bash -c 'source "$1" >/dev/null 2>&1;
    for f in s7635 ghactions pysec complexity shell tests jsquality misc; do
      t=$(family_title "$f"); [ -n "$t" ] || exit 1; done' _ "$SCRIPT"
  [ "$status" -eq 0 ]
}
