#!/usr/bin/env bats
# Tests for classify_sonar_s7637_exemption() in scripts/compliance-audit.sh —
# the pure classifier behind check_sonar_s7637_exemption.
#
# Context (#498): SonarCloud's githubactions:S7637 ("pin actions to a full-length
# commit SHA") fires on first-party petry-projects/.github(-private) reusable-ref
# caller stubs that the org standard intentionally pins by moving channel/tag, not
# SHA. The org reconciles this with a NARROW sonar.issue.ignore that suppresses
# S7637 only on the thin caller-stub workflow files — never a blanket
# workflows/*.yml exclusion, which would also drop SHA-pin enforcement on the
# third-party actions in ci.yml/sonarcloud.yml.
#
# The classifier returns exactly one of:
#   present   — at least one S7637 ignore criterion, all narrow (specific files)
#   missing   — no criterion suppresses githubactions:S7637
#   too-broad — an S7637 criterion uses a blanket resourceKey (the filename
#               segment contains a wildcard, or the pattern is a bare ** )
#
# The script is sourced in an isolated subshell (its `main` is guarded, so
# sourcing only defines functions) and the real helper is exercised directly.

bats_require_minimum_version 1.5.0

SCRIPT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/scripts/compliance-audit.sh"

# Run the real classifier against the given properties-file content.
classify() {
  run bash -c 'source "$1" >/dev/null 2>&1; classify_sonar_s7637_exemption "$2"' \
    _ "$SCRIPT" "$1"
}

@test "no issue-ignore config at all is missing" {
  classify "$(printf 'sonar.projectKey=petry-projects_foo\nsonar.organization=petry-projects\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "missing" ]
}

@test "an issue-ignore for an unrelated rule is missing (S7637 not covered)" {
  classify "$(printf 'sonar.issue.ignore.multicriteria=e1\nsonar.issue.ignore.multicriteria.e1.ruleKey=javascript:S1234\nsonar.issue.ignore.multicriteria.e1.resourceKey=**/agent-shield.yml\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "missing" ]
}

@test "a narrow single-file S7637 exemption is present" {
  classify "$(printf 'sonar.issue.ignore.multicriteria=s1\nsonar.issue.ignore.multicriteria.s1.ruleKey=githubactions:S7637\nsonar.issue.ignore.multicriteria.s1.resourceKey=**/agent-shield.yml\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "present" ]
}

@test "multiple narrow per-stub S7637 criteria are present" {
  body=$(cat <<'PROPS'
sonar.issue.ignore.multicriteria=s1,s2
sonar.issue.ignore.multicriteria.s1.ruleKey=githubactions:S7637
sonar.issue.ignore.multicriteria.s1.resourceKey=**/agent-shield.yml
sonar.issue.ignore.multicriteria.s2.ruleKey=githubactions:S7637
sonar.issue.ignore.multicriteria.s2.resourceKey=**/pr-review-mention.yml
PROPS
)
  classify "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "present" ]
}

@test "a blanket workflows/*.yml resourceKey is too-broad" {
  classify "$(printf 'sonar.issue.ignore.multicriteria=b1\nsonar.issue.ignore.multicriteria.b1.ruleKey=githubactions:S7637\nsonar.issue.ignore.multicriteria.b1.resourceKey=**/.github/workflows/*.yml\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "too-broad" ]
}

@test "a bare ** resourceKey is too-broad" {
  classify "$(printf 'sonar.issue.ignore.multicriteria=b1\nsonar.issue.ignore.multicriteria.b1.ruleKey=githubactions:S7637\nsonar.issue.ignore.multicriteria.b1.resourceKey=**\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "too-broad" ]
}

@test "a bare *.yml resourceKey is too-broad" {
  classify "$(printf 'sonar.issue.ignore.multicriteria=b1\nsonar.issue.ignore.multicriteria.b1.ruleKey=githubactions:S7637\nsonar.issue.ignore.multicriteria.b1.resourceKey=*.yml\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "too-broad" ]
}

@test "one narrow + one blanket S7637 criterion is too-broad (blanket wins)" {
  body=$(cat <<'PROPS'
sonar.issue.ignore.multicriteria=s1,b1
sonar.issue.ignore.multicriteria.s1.ruleKey=githubactions:S7637
sonar.issue.ignore.multicriteria.s1.resourceKey=**/agent-shield.yml
sonar.issue.ignore.multicriteria.b1.ruleKey=githubactions:S7637
sonar.issue.ignore.multicriteria.b1.resourceKey=**/.github/workflows/*.yml
PROPS
)
  classify "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "too-broad" ]
}

@test "whitespace around the ruleKey assignment is tolerated" {
  classify "$(printf 'sonar.issue.ignore.multicriteria.s1.ruleKey =  githubactions:S7637 \nsonar.issue.ignore.multicriteria.s1.resourceKey = **/agent-shield.yml\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "present" ]
}

@test "the repo's own canonical sonar-project.properties classifies as present" {
  props="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/sonar-project.properties"
  classify "$(cat "$props")"
  [ "$status" -eq 0 ]
  [ "$output" = "present" ]
}

# ---------------------------------------------------------------------------
# classify_inline_s7637_marker() — the canonical mechanism (#549). Verifies the
# inline `# NOSONAR(githubactions:S7637)` marker travels on each channel-pinned
# first-party reusable-ref `uses:` line in a caller-stub workflow file.
#   present — every channel-pinned first-party reusable-ref line carries the marker
#   missing — at least one channel-pinned first-party reusable-ref line lacks it
#   n/a     — no channel-pinned first-party reusable ref (SHA-pinned or none)
# ---------------------------------------------------------------------------

# Run the real inline classifier against the given workflow-file content.
classify_inline() {
  run bash -c 'source "$1" >/dev/null 2>&1; classify_inline_s7637_marker "$2"' \
    _ "$SCRIPT" "$1"
}

@test "inline: channel-pinned first-party ref with the marker is present" {
  classify_inline "$(printf 'jobs:\n  dev-lead:\n    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/stable  # NOSONAR(githubactions:S7637) first-party channel ref\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "present" ]
}

@test "inline: channel-pinned first-party ref without the marker is missing" {
  classify_inline "$(printf 'jobs:\n  dev-lead:\n    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/stable\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "missing" ]
}

@test "inline: a @v2 moving-major channel ref needs the marker too" {
  classify_inline "$(printf 'jobs:\n  pr-auto-review:\n    uses: petry-projects/.github/.github/workflows/pr-auto-review-reusable.yml@v2\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "missing" ]
}

@test "inline: a SHA-pinned first-party ref needs no marker (n/a)" {
  classify_inline "$(printf 'jobs:\n  feature-ideation:\n    uses: petry-projects/.github/.github/workflows/feature-ideation-reusable.yml@e20a8fac1b6a10bd6ad0999258e88a423f890ba6 # v1\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "n/a" ]
}

@test "inline: a workflow with no first-party reusable ref is n/a" {
  classify_inline "$(printf 'jobs:\n  ci:\n    steps:\n      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683\n')"
  [ "$status" -eq 0 ]
  [ "$output" = "n/a" ]
}

@test "inline: mixed — one marked channel ref + one SHA-pinned ref is present" {
  body=$(cat <<'WF'
jobs:
  a:
    uses: petry-projects/.github/.github/workflows/agent-shield-reusable.yml@agent-shield/stable  # NOSONAR(githubactions:S7637) first-party channel ref
  b:
    uses: petry-projects/.github/.github/workflows/feature-ideation-reusable.yml@e20a8fac1b6a10bd6ad0999258e88a423f890ba6 # v1
WF
)
  classify_inline "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "present" ]
}

@test "inline: every shipped channel-pinned caller-stub template is present" {
  root="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  for tmpl in "$root"/standards/workflows/*.yml; do
    tmpl_name=$(basename "$tmpl")
    classify_inline "$(cat "$tmpl")"
    [ "$status" -eq 0 ]
    [ "$output" != "missing" ] || {
      echo "template $tmpl_name classified as missing, but should be present or n/a" >&2
      return 1
    }
  done
}
