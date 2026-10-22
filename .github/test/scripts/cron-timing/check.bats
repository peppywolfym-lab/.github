#!/usr/bin/env bats
# Tests for scripts/check-cron-timing.sh — the CI guard that fails any workflow
# in .github/workflows/ scheduling a cron on the top of the hour (minute 0),
# per the off-peak scheduled-workflow timing standard (standards/ci-standards.md
# → "Scheduled Workflow Timing"). Wired into ci.yml's Lint job and
# .dev-lead/scripts/dev-lead-lint.sh.
#
# Context (#1052): AC #3 requires the check to fail minute-0 crons with a
# message pointing at the standard; AC #2 requires the repo's own workflows to
# be offset with no two sharing an identical cron expression.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  CHECK="${REPO_ROOT}/scripts/check-cron-timing.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "${TMP}"
}

@test "check passes on a directory whose crons are all offset" {
  mkdir -p "${TMP}/wf"
  printf 'on:\n  schedule:\n    - cron: %s\n' "'17 6 * * 1'" > "${TMP}/wf/a.yml"
  printf 'on:\n  schedule:\n    - cron: %s\n' '"*/15 * * * *"' > "${TMP}/wf/b.yml"
  run bash "$CHECK" "${TMP}/wf"
  [ "$status" -eq 0 ]
}

@test "check fails on a minute-0 cron and points at the standard" {
  mkdir -p "${TMP}/wf"
  printf 'on:\n  schedule:\n    - cron: %s\n' "'0 7 * * *'" > "${TMP}/wf/bad.yml"
  run bash "$CHECK" "${TMP}/wf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad.yml"* ]]
  [[ "$output" == *"minute 0"* ]]
  [[ "$output" == *"Scheduled Workflow Timing"* ]]
}

@test "check catches the hourly-on-the-hour form (0 * * * *)" {
  mkdir -p "${TMP}/wf"
  printf 'on:\n  schedule:\n    - cron: %s\n' "'0 * * * *'" > "${TMP}/wf/hourly.yml"
  run bash "$CHECK" "${TMP}/wf"
  [ "$status" -eq 1 ]
}

@test "check suggests a non-zero replacement minute for the offending file" {
  mkdir -p "${TMP}/wf"
  printf 'on:\n  schedule:\n    - cron: %s\n' "'0 7 * * *'" > "${TMP}/wf/org-scorecard.yml"
  run bash "$CHECK" "${TMP}/wf"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Suggested minute"* ]]
}

@test "the real .github/workflows/ tree passes the check (AC #2)" {
  run bash "$CHECK" "${REPO_ROOT}/.github/workflows"
  [ "$status" -eq 0 ]
}

@test "no two workflows in this repo share an identical cron expression (AC #2)" {
  # Collect every cron expression across the repo's own workflows and assert the
  # set has no duplicates — the two historical collisions must be de-collided.
  run bash -c "set -o pipefail; grep -rhoE \"cron:[[:space:]]*['\\\"][^'\\\"]+['\\\"]\" \"${REPO_ROOT}/.github/workflows\"/*.yml | sed -E \"s/cron:[[:space:]]*['\\\"]//; s/['\\\"]\\$//\" | sort | uniq -d"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
