#!/usr/bin/env bats
# Contract tests for the apply-repo-settings reusable workflow + its thin caller
# stubs (petry-projects/.github#984).
#
# The reusable (.github/workflows/apply-repo-settings-reusable.yml) is the single
# source of truth for the branch-policy compliance self-heal; the fleet adopts it
# through a thin caller stub (standards/workflows/apply-repo-settings.yml) and the
# host repo dogfoods it via a local-ref caller (.github/workflows/apply-repo-settings.yml).
#
# These tests encode the two invariants that break the self-heal when violated:
#   1. The caller-input contract (incident #1034): every `with:` key a stub
#      forwards MUST be a `workflow_call` input the reusable declares, or the
#      first real trigger dies at startup_failure.
#   2. Scope: the reusable must actually run BOTH the settings applier AND the
#      ruleset applier — the rulesets (pr-quality's require_last_push_approval)
#      are the recurring finding this issue exists to fix; settings alone do not
#      touch them.

REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
REUSABLE="${REPO_ROOT}/.github/workflows/apply-repo-settings-reusable.yml"
STUB="${REPO_ROOT}/standards/workflows/apply-repo-settings.yml"
HOST_CALLER="${REPO_ROOT}/.github/workflows/apply-repo-settings.yml"
REGISTRY="${REPO_ROOT}/standards/canary-rings.json"

# ── the reusable is a well-formed pure reusable ───────────────────────────────
@test "reusable exists and declares workflow_call" {
  [ -f "$REUSABLE" ]
  run yq '.on | has("workflow_call")' "$REUSABLE"
  [ "$output" = "true" ]
}

@test "reusable is a PURE reusable (workflow_call is its only trigger)" {
  # Per ci-standards.md, a pure reusable's `on:` declares workflow_call and nothing
  # else, and the file carries the -reusable.yml suffix.
  run yq '.on | keys | length' "$REUSABLE"
  [ "$output" = "1" ]
}

@test "reusable declares the dry_run and checkout_ref inputs" {
  run yq '.on.workflow_call.inputs | has("dry_run")' "$REUSABLE"
  [ "$output" = "true" ]
  run yq '.on.workflow_call.inputs | has("checkout_ref")' "$REUSABLE"
  [ "$output" = "true" ]
}

@test "reusable declares the GH_PAT_DON_PETRY secret" {
  run yq '.on.workflow_call.secrets | has("GH_PAT_DON_PETRY")' "$REUSABLE"
  [ "$output" = "true" ]
}

@test "reusable has a loud preflight naming the GH_PAT_DON_PETRY secret" {
  # markets-style: an empty/missing secret must fail loud, naming the secret in an
  # error annotation, not a buried generic failure.
  run grep -q 'GH_PAT_DON_PETRY' "$REUSABLE"
  [ "$status" -eq 0 ]
  run grep -qE '::error' "$REUSABLE"
  [ "$status" -eq 0 ]
}

@test "reusable runs BOTH apply-repo-settings.sh AND apply-rulesets.sh" {
  # Assert on the step run: blocks only, so comments in the file don't satisfy this.
  local run_blocks
  run_blocks="$(yq '[.jobs[].steps[].run // ""] | join("\n")' "$REUSABLE")"
  echo "$run_blocks" | grep -qF 'bash scripts/apply-repo-settings.sh'
  echo "$run_blocks" | grep -qF 'bash scripts/apply-rulesets.sh'
}

# ── ordering + independence (#1038): the ruleset self-heal is load-bearing ──────
# The 30/30 failures happened because the settings script ran FIRST under errexit and
# aborted (on the check-suites 403) before the ruleset self-heal — pr-quality
# convergence, the whole point of this workflow — ever ran. The reusable must run the
# load-bearing rulesets FIRST, and neither script's failure may skip the other.
@test "reusable runs apply-rulesets.sh BEFORE apply-repo-settings.sh (load-bearing first, #1038)" {
  local run_blocks rulesets_line settings_line
  run_blocks="$(yq '[.jobs[]?.steps[]?.run // ""] | join("\n")' "$REUSABLE")"
  rulesets_line="$(printf '%s\n' "$run_blocks" | grep -n 'bash scripts/apply-rulesets.sh' | head -1 | cut -d: -f1)"
  settings_line="$(printf '%s\n' "$run_blocks" | grep -n 'bash scripts/apply-repo-settings.sh' | head -1 | cut -d: -f1)"
  [ -n "$rulesets_line" ]
  [ -n "$settings_line" ]
  [ "$rulesets_line" -lt "$settings_line" ]
}

@test "reusable guards each script so one failure never skips the other, and names failures (#1038)" {
  local run_blocks
  run_blocks="$(yq '[.jobs[]?.steps[]?.run // ""] | join("\n")' "$REUSABLE")"
  # Each applier invocation is guarded (|| record) rather than left to abort the step.
  printf '%s\n' "$run_blocks" | grep -qE 'apply-rulesets\.sh[^|]*\|\|'
  printf '%s\n' "$run_blocks" | grep -qE 'apply-repo-settings\.sh[^|]*\|\|'
  # Any failure surfaces a named GitHub error annotation, then a non-zero exit.
  printf '%s\n' "$run_blocks" | grep -qF '::error'
  printf '%s\n' "$run_blocks" | grep -qE 'exit[[:space:]]+1'
}

@test "reusable checks out petry-projects/.github at the checkout_ref input" {
  run yq '[.jobs[].steps[] | select(.uses | contains("checkout")) | .with.repository] | contains(["petry-projects/.github"])' "$REUSABLE"
  [ "$output" = "true" ]
  run grep -q 'inputs.checkout_ref' "$REUSABLE"
  [ "$status" -eq 0 ]
}

# ── caller-input contract (#1034): stub forwards only declared inputs ──────────
@test "every with: key the canonical stub forwards is a declared reusable input" {
  [ -f "$STUB" ]
  local declared forwarded key
  declared="$(yq '(.on.workflow_call.inputs // {}) | keys | .[]?' "$REUSABLE")"
  forwarded="$(yq '(.jobs[].with // {}) | keys | .[]?' "$STUB")"
  [ -n "$forwarded" ] || skip "stub forwards no inputs"
  while IFS= read -r key || [ -n "$key" ]; do
    key="${key%$'\r'}"
    [ -z "$key" ] && continue
    if ! grep -qxF "$key" <<<"$declared"; then
      echo "stub forwards undeclared input: $key (declared: $declared)"
      return 1
    fi
  done <<<"$forwarded"
}

# ── canonical stub shape ──────────────────────────────────────────────────────
@test "canonical stub pins the major-scoped apply-repo-settings channel with the S7637 marker" {
  run grep -E 'uses:.*apply-repo-settings-reusable\.yml@apply-repo-settings/v[0-9]+-stable.*NOSONAR\(githubactions:S7637\) first-party channel ref' "$STUB"
  [ "$status" -eq 0 ]
}

@test "canonical stub uses secrets: inherit with the S7635 marker" {
  run grep -E '^[[:space:]]*secrets:[[:space:]]+inherit.*NOSONAR\(githubactions:S7635\)' "$STUB"
  [ "$status" -eq 0 ]
}

@test "canonical stub is named 'Apply repo settings' to match the registry run_workflow" {
  run yq '.name' "$STUB"
  [ "$output" = "Apply repo settings" ]
}

# ── host dogfood caller ───────────────────────────────────────────────────────
@test "host caller dogfoods via a local ./ reusable ref" {
  [ -f "$HOST_CALLER" ]
  run grep -qE 'uses:[[:space:]]*\./\.github/workflows/apply-repo-settings-reusable\.yml' "$HOST_CALLER"
  [ "$status" -eq 0 ]
}

@test "host caller is named 'Apply repo settings' and runs weekly" {
  run yq '.name' "$HOST_CALLER"
  [ "$output" = "Apply repo settings" ]
  run yq '.on | has("schedule")' "$HOST_CALLER"
  [ "$output" = "true" ]
  run yq '.on | has("workflow_dispatch")' "$HOST_CALLER"
  [ "$output" = "true" ]
}

# ── registry registration (avoids DRIFT[unregistered]) ────────────────────────
@test "apply-repo-settings is registered in canary-rings.json" {
  run yq -oy '.agents["apply-repo-settings"].host' "$REGISTRY"
  [ "$output" = "petry-projects/.github" ]
  run yq -oy '.agents["apply-repo-settings"].run_workflow' "$REGISTRY"
  [ "$output" = "Apply repo settings" ]
}

@test "registry entry declares next/ring0/ring1/stable rings" {
  run yq -oy '[.agents["apply-repo-settings"].rings[].channel] | sort | join(",")' "$REGISTRY"
  [ "$output" = "next,ring0,ring1,stable" ]
}

@test "registry entry has correct reusable path, ring order, and membership" {
  run yq -oy '.agents["apply-repo-settings"].reusable' "$REGISTRY"
  [ "$output" = ".github/workflows/apply-repo-settings-reusable.yml" ]
  # Ring orders must be monotonically staged: next=0, ring0=1, ring1=2, stable=3
  run yq -oy '.agents["apply-repo-settings"].rings[] | select(.channel == "next") | .order' "$REGISTRY"
  [ "$output" = "0" ]
  run yq -oy '.agents["apply-repo-settings"].rings[] | select(.channel == "ring0") | .order' "$REGISTRY"
  [ "$output" = "1" ]
  run yq -oy '.agents["apply-repo-settings"].rings[] | select(.channel == "ring1") | .order' "$REGISTRY"
  [ "$output" = "2" ]
  run yq -oy '.agents["apply-repo-settings"].rings[] | select(.channel == "stable") | .order' "$REGISTRY"
  [ "$output" = "3" ]
  # Membership anchors: host-private in next, host in ring0, wildcard in stable
  run yq -oy '.agents["apply-repo-settings"].rings[] | select(.channel == "next") | .members[0]' "$REGISTRY"
  [ "$output" = "petry-projects/.github-private" ]
  run yq -oy '.agents["apply-repo-settings"].rings[] | select(.channel == "ring0") | .members[0]' "$REGISTRY"
  [ "$output" = "petry-projects/.github" ]
  run yq -oy '.agents["apply-repo-settings"].rings[] | select(.channel == "stable") | .members[0]' "$REGISTRY"
  [ "$output" = "*" ]
}
