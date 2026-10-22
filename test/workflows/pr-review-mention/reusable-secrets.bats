#!/usr/bin/env bats
# Pins the credential fallback wiring inside the reusable
# pr-review-mention-reusable.yml (issue #833).
#
# The thin caller invokes this reusable with `secrets: inherit`, so both
# GH_PAT_DON_PETRY (canonical org secret) and GH_PAT_WORKFLOWS (legacy) resolve
# inside its steps. Every GH_TOKEN must prefer the canonical secret with the old
# name as a `||` fallback, so retiring GH_PAT_WORKFLOWS org-wide leaves behavior
# intact (.github-private#1326).

setup() {
  load 'helpers/setup'
}

FALLBACK='${{ secrets.GH_PAT_DON_PETRY || secrets.GH_PAT_WORKFLOWS }}'

gh_token_for_step() {
  local step_name="$1"
  yq -r ".jobs.handle-mention.steps[] | select(.name == \"${step_name}\") | .env.GH_TOKEN" "$TT_WORKFLOW"
}

@test "reusable: 'Check commenter trust level' GH_TOKEN uses the canonical fallback" {
  run gh_token_for_step "Check commenter trust level"
  [ "$status" -eq 0 ]
  [ "$output" = "$FALLBACK" ]
}

@test "reusable: 'Resolve PR URL' GH_TOKEN uses the canonical fallback" {
  run gh_token_for_step "Resolve PR URL"
  [ "$status" -eq 0 ]
  [ "$output" = "$FALLBACK" ]
}

@test "reusable: 'Trigger review agent' GH_TOKEN uses the canonical fallback" {
  run gh_token_for_step "Trigger review agent"
  [ "$status" -eq 0 ]
  [ "$output" = "$FALLBACK" ]
}
