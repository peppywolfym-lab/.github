#!/usr/bin/env bats
# Tests for the credential wiring of the canonical caller stub
# standards/workflows/pr-auto-review.yml (issue #836, Part A).
#
# The GH_PAT_WORKFLOWS retirement (.github-private#1326) adds the canonical org
# secret GH_PAT_DON_PETRY, keeping the old name as a `||` transition fallback.
# Footgun: the reusable resolves the secret BY NAME, so this by-name pass must
# change only the VALUE — the passed key must stay named GH_PAT_WORKFLOWS.

load 'helpers/setup'

STUB="${TT_REPO_ROOT}/standards/workflows/pr-auto-review.yml"

CHAIN='${{ secrets.GH_PAT_DON_PETRY || secrets.GH_PAT_WORKFLOWS }}'

@test "stub: passed GH_PAT_WORKFLOWS value uses the canonical-first fallback" {
  run yq -r '.jobs.pr-auto-review.secrets.GH_PAT_WORKFLOWS' "$STUB"
  [ "$status" -eq 0 ]
  [ "$output" = "$CHAIN" ]
}

@test "stub: keeps the passed secret NAME GH_PAT_WORKFLOWS (reusable resolves by name)" {
  run yq -r '.jobs.pr-auto-review.secrets | keys | .[]' "$STUB"
  [ "$status" -eq 0 ]
  [ "$output" = 'GH_PAT_WORKFLOWS' ]
}

@test "stub: keeps the @pr-auto-review/v1-stable channel pin in the uses: line" {
  run yq -r '.jobs.pr-auto-review.uses' "$STUB"
  [ "$status" -eq 0 ]
  [[ "$output" == *'@pr-auto-review/v1-stable'* ]]
}
