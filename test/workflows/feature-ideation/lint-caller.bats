#!/usr/bin/env bats
# Tests for lint-caller.sh — kills #571 (a reusable-workflow `with:` that
# references the `inputs` context, which fails at workflow setup with zero jobs
# on the `discussion` trigger regardless of the calling job's `if:`).

load 'helpers/setup'

setup() {
  tt_make_tmpdir
}

teardown() {
  tt_cleanup_tmpdir
}

LINTER="${TT_REPO_ROOT}/.github/scripts/feature-ideation/lint-caller.sh"
CALLERS="${TT_FIXTURES_DIR}/callers"

write_yml() {
  local path="$1"
  cat >"$path"
}

# ---------------------------------------------------------------------------
# Committed fixtures — the correct and the broken shapes.
# ---------------------------------------------------------------------------

@test "lint-caller: clean needs.prep.outputs caller passes" {
  run bash "$LINTER" "${CALLERS}/clean-needs-outputs.yml"
  [ "$status" -eq 0 ]
}

@test "lint-caller: FAILS on inputs.* in a reusable with: block" {
  run bash "$LINTER" "${CALLERS}/inputs-in-with.yml"
  [ "$status" -eq 1 ]
  # The offending key must be named in the output.
  [[ "$output" == *"with.target_discussion"* ]] || [[ "$output" == *"with.focus_area"* ]]
}

# ---------------------------------------------------------------------------
# False-positive guards.
# ---------------------------------------------------------------------------

@test "lint-caller: step-level action uses: with inputs is NOT flagged" {
  write_yml "${TT_TMP}/steplevel.yml" <<'YML'
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/github-script@v7
        with:
          script: core.info('${{ inputs.focus_area }}')
YML
  run bash "$LINTER" "${TT_TMP}/steplevel.yml"
  [ "$status" -eq 0 ]
}

@test "lint-caller: github.event.inputs.* in a reusable with: is allowed" {
  # github.event.inputs is available at setup for every event (null when absent),
  # so it does not cause the #571 startup failure and must not be flagged.
  write_yml "${TT_TMP}/ghevent.yml" <<'YML'
jobs:
  ideate:
    uses: org/.github/.github/workflows/reusable.yml@v1
    with:
      focus_area: ${{ github.event.inputs.focus_area }}
YML
  run bash "$LINTER" "${TT_TMP}/ghevent.yml"
  [ "$status" -eq 0 ]
}

@test "lint-caller: a job without a reusable uses: is ignored" {
  write_yml "${TT_TMP}/nouses.yml" <<'YML'
jobs:
  prep:
    runs-on: ubuntu-latest
    steps:
      - run: echo "${{ inputs.focus_area }}"
YML
  run bash "$LINTER" "${TT_TMP}/nouses.yml"
  [ "$status" -eq 0 ]
}

@test "lint-caller: inputs referenced via index syntax is flagged" {
  write_yml "${TT_TMP}/index.yml" <<'YML'
jobs:
  ideate:
    uses: org/.github/.github/workflows/reusable.yml@v1
    with:
      focus_area: ${{ inputs['focus_area'] }}
YML
  run bash "$LINTER" "${TT_TMP}/index.yml"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Regression guards — the live caller stubs must stay clean.
# ---------------------------------------------------------------------------

@test "lint-caller: standards caller-stub template lints clean" {
  workflow="${TT_REPO_ROOT}/standards/workflows/feature-ideation.yml"
  [ -f "$workflow" ]
  run bash "$LINTER" "$workflow"
  [ "$status" -eq 0 ]
}

@test "lint-caller: this repo's own caller lints clean" {
  workflow="${TT_REPO_ROOT}/.github/workflows/feature-ideation.yml"
  [ -f "$workflow" ]
  run bash "$LINTER" "$workflow"
  [ "$status" -eq 0 ]
}

@test "lint-caller: default (no args) scans both caller stubs and passes" {
  run bash "$LINTER"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Exit-code precedence: a file/parse error (2) must not be downgraded by a
# later lint finding (1). Mirrors lint-prompt.sh.
# ---------------------------------------------------------------------------

@test "lint-caller: missing file before a lint-failing file still exits 2" {
  run bash "$LINTER" "${TT_TMP}/missing.yml" "${CALLERS}/inputs-in-with.yml"
  [ "$status" -eq 2 ]
}
