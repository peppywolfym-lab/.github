#!/usr/bin/env bats
# Tests for the credential wiring of the canonical caller stub
# standards/workflows/initiative-driver.yml (issue #836, Part A).
#
# The GH_PAT_WORKFLOWS retirement (.github-private#1326) adds the canonical org
# secret GH_PAT_DON_PETRY, keeping the old name as a `||` transition fallback.
# The two `GH_TOKEN:` guard/dispatch refs must prefer GH_PAT_DON_PETRY.
# Referenced inside a `||` the canonical secret needs no workflow_call.secrets
# declaration (this stub is a self-contained dispatcher — no reusable).

TT_REPO_ROOT="$(cd -- "$(dirname -- "${BATS_TEST_DIRNAME}")/../.." && pwd)"
STUB="${TT_REPO_ROOT}/standards/workflows/initiative-driver.yml"

CHAIN='${{ secrets.GH_PAT_DON_PETRY || secrets.GH_PAT_WORKFLOWS }}'

@test "stub: PAT-present guard GH_TOKEN uses the canonical-first fallback" {
  run yq -r '.jobs.dispatch.steps[] | select(.name == "Guard — PAT present") | .env.GH_TOKEN' "$STUB"
  [ "$status" -eq 0 ]
  [ "$output" = "$CHAIN" ]
}

@test "stub: dispatch-step GH_TOKEN uses the canonical-first fallback" {
  run yq -r '.jobs.dispatch.steps[] | select(.name == "Dispatch central initiative-driver") | .env.GH_TOKEN' "$STUB"
  [ "$status" -eq 0 ]
  [ "$output" = "$CHAIN" ]
}

@test "stub: no bare secrets.GH_PAT_WORKFLOWS runtime ref remains" {
  # Every GH_PAT_WORKFLOWS occurrence must be inside the canonical-first chain.
  run grep -nE 'secrets\.GH_PAT_WORKFLOWS' "$STUB"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -vF "GH_PAT_DON_PETRY || secrets.GH_PAT_WORKFLOWS"
}

@test "stub: adds no workflow_call.secrets block (self-contained dispatcher)" {
  run yq -r '.on.workflow_call // "absent"' "$STUB"
  [ "$output" = 'absent' ]
}
