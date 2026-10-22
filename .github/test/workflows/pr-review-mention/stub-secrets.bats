#!/usr/bin/env bats
# Tests for the credential wiring of the canonical caller stub
# standards/workflows/pr-review-mention.yml (issue #791).
#
# The persona-identity rename (#1316 / .github-private#1317) renamed the
# workflows PAT org secret GH_PAT_WORKFLOWS -> GH_PAT_DON_PETRY, keeping the old
# name as a `||` transition fallback. The stub must source the reusable's
# GH_PAT_WORKFLOWS input from that fallback expression.
#
# Fail-closed contract: the reusable declares BOTH GH_PAT_WORKFLOWS and
# DON_PETRY_BOT_GH_PAT as `required: true`. An explicit `secrets:` block passes
# only the keys it lists (no implicit inherit), so the stub MUST still carry
# DON_PETRY_BOT_GH_PAT or the acknowledgement step loses its token. These tests
# pin both the rename and that retention.

load 'helpers/setup'

STUB="${TT_REPO_ROOT}/standards/workflows/pr-review-mention.yml"

# ── the rename: workflows PAT sourced from GH_PAT_DON_PETRY with old-name fallback

@test "stub: GH_PAT_WORKFLOWS input uses the GH_PAT_DON_PETRY || GH_PAT_WORKFLOWS fallback" {
  run yq -r '.jobs.pr-review-mention.secrets.GH_PAT_WORKFLOWS' "$STUB"
  [ "$status" -eq 0 ]
  [ "$output" = '${{ secrets.GH_PAT_DON_PETRY || secrets.GH_PAT_WORKFLOWS }}' ]
}

# ── fail-closed: the bot-comment PAT must not silently drop out of the wiring ──

@test "stub: retains DON_PETRY_BOT_GH_PAT (required by the reusable's ack step)" {
  run yq -r '.jobs.pr-review-mention.secrets.DON_PETRY_BOT_GH_PAT' "$STUB"
  [ "$status" -eq 0 ]
  [ "$output" = '${{ secrets.DON_PETRY_BOT_GH_PAT }}' ]
}

@test "stub: uses an explicit secrets mapping, not bare 'inherit'" {
  # With `secrets: inherit`, .secrets is a scalar string; the explicit block is a
  # mapping. An explicit block is what lets us rewire GH_PAT_WORKFLOWS per #791.
  run yq -r '.jobs.pr-review-mention.secrets | tag' "$STUB"
  [ "$status" -eq 0 ]
  [ "$output" = '!!map' ]
}

# ── contract this stub depends on: both PATs are required by the reusable ──────

@test "reusable: declares GH_PAT_WORKFLOWS and DON_PETRY_BOT_GH_PAT as required" {
  run yq -r '.on.workflow_call.secrets.GH_PAT_WORKFLOWS.required' "$TT_WORKFLOW"
  [ "$output" = 'true' ]
  run yq -r '.on.workflow_call.secrets.DON_PETRY_BOT_GH_PAT.required' "$TT_WORKFLOW"
  [ "$output" = 'true' ]
}
