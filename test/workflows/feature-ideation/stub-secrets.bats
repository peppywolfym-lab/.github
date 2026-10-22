#!/usr/bin/env bats
# Tests for the credential wiring of the canonical caller stub
# standards/workflows/feature-ideation.yml (issue #836, Part A).
#
# The GH_PAT_WORKFLOWS retirement (.github-private#1326) adds the canonical org
# secret GH_PAT_DON_PETRY, keeping the old name as a `||` transition fallback.
# The two redispatch-guard `GH_TOKEN:` refs must prefer GH_PAT_DON_PETRY.
# The reusable `secrets:` block passes CLAUDE_CODE_OAUTH_TOKEN (not the PAT) and
# MUST stay untouched.

load 'helpers/setup'

STUB="${TT_REPO_ROOT}/standards/workflows/feature-ideation.yml"

CHAIN='${{ secrets.GH_PAT_DON_PETRY || secrets.GH_PAT_WORKFLOWS }}'

@test "stub: redispatch PAT-present guard GH_TOKEN uses the canonical-first fallback" {
  run yq -r '.jobs.redispatch.steps[] | select(.name == "Guard — PAT present") | .env.GH_TOKEN' "$STUB"
  [ "$status" -eq 0 ]
  [ "$output" = "$CHAIN" ]
}

@test "stub: re-dispatch step GH_TOKEN uses the canonical-first fallback" {
  run yq -r '.jobs.redispatch.steps[] | select(.name == "Re-dispatch under workflow_dispatch") | .env.GH_TOKEN' "$STUB"
  [ "$status" -eq 0 ]
  [ "$output" = "$CHAIN" ]
}

@test "stub: no bare secrets.GH_PAT_WORKFLOWS runtime ref remains" {
  run grep -nE 'secrets\.GH_PAT_WORKFLOWS' "$STUB"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -vF "GH_PAT_DON_PETRY || secrets.GH_PAT_WORKFLOWS"
}

@test "stub: reusable secrets block still passes CLAUDE_CODE_OAUTH_TOKEN unchanged" {
  run yq -r '.jobs.ideate.secrets.CLAUDE_CODE_OAUTH_TOKEN' "$STUB"
  [ "$status" -eq 0 ]
  [ "$output" = '${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}' ]
}

@test "stub: reusable secrets block carries no GH_PAT ref (PAT is not passed to the reusable)" {
  run yq -r '.jobs.ideate.secrets | keys | .[]' "$STUB"
  [ "$status" -eq 0 ]
  [ "$output" = 'CLAUDE_CODE_OAUTH_TOKEN' ]
}
