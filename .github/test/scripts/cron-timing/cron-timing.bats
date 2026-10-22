#!/usr/bin/env bats
# Unit tests for scripts/lib/cron-timing.sh — the pure helpers behind the
# off-peak scheduled-workflow timing standard (standards/ci-standards.md →
# "Scheduled Workflow Timing", promoted from the .github-private repo-local
# convention). The lib has no `main`, so it is sourced directly and its
# side-effect-free helpers are exercised in-process.
#
# Context (#1052): this repo was the fleet's worst offender — 11 of its
# scheduled workflows fired at minute 0. These helpers both detect the
# violation (the CI check) and pick the deterministic replacement minute, so
# the check and the chosen values can never disagree.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/cron-timing.sh"
}

@test "cron_minute_field extracts field 1 of a 5-field expression" {
  [ "$(cron_minute_field '0 7 * * *')" = "0" ]
  [ "$(cron_minute_field '41 3 * * *')" = "41" ]
  [ "$(cron_minute_field '*/15 * * * *')" = "*/15" ]
}

@test "cron_minute_field tolerates leading/trailing whitespace" {
  [ "$(cron_minute_field '   17 6 * * 1  ')" = "17" ]
}

@test "cron_minute_is_zero is true only for a bare minute-0 start" {
  cron_minute_is_zero '0 * * * *'
  cron_minute_is_zero '0 7 * * *'
  cron_minute_is_zero '0 */4 * * *'
}

@test "cron_minute_is_zero is false for any offset minute" {
  ! cron_minute_is_zero '17 6 * * 1'
  ! cron_minute_is_zero '41 3 * * *'
  ! cron_minute_is_zero '*/15 * * * *'
  ! cron_minute_is_zero '15 17 * * 2'
}

@test "cron_offset_minute returns a deterministic minute in 1..59" {
  local m
  m="$(cron_offset_minute 'compliance-retrigger.yml')"
  [ "$m" -ge 1 ]
  [ "$m" -le 59 ]
  # Deterministic: the same filename always hashes to the same minute.
  [ "$m" = "$(cron_offset_minute 'compliance-retrigger.yml')" ]
}

@test "cron_offset_minute never returns 0 (would recreate the violation)" {
  # Sweep a representative set of workflow filenames; none may land back on :00.
  local f m
  for f in compliance-retrigger.yml dependabot-rebase.yml canary-rollout.yml \
           add-to-project-reconcile.yml feature-ideation.yml standards-deploy.yml \
           pinned-version-report.yml org-scorecard.yml daily-org-status.yml \
           pr-limits-report.yml compliance-audit-and-improvement.yml; do
    m="$(cron_offset_minute "$f")"
    [ "$m" -ne 0 ]
  done
}

@test "cron_offset_minute is basename-based (path-independent)" {
  [ "$(cron_offset_minute 'org-scorecard.yml')" = "$(cron_offset_minute '.github/workflows/org-scorecard.yml')" ]
}

@test "cron_offset_minute de-duplicates the two colliding pairs" {
  # dependabot-rebase.yml and canary-rollout.yml both shipped `0 */4 * * *`;
  # standards-deploy.yml and pinned-version-report.yml both shipped `0 8 * * 1`.
  # Distinct filenames must yield distinct offset minutes so the de-collided
  # expressions differ (AC #2: no two workflows share an identical cron).
  [ "$(cron_offset_minute 'dependabot-rebase.yml')" != "$(cron_offset_minute 'canary-rollout.yml')" ]
  [ "$(cron_offset_minute 'standards-deploy.yml')" != "$(cron_offset_minute 'pinned-version-report.yml')" ]
}
