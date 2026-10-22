#!/usr/bin/env bats
# Tests for the legacy-ruleset migration-delta logic in
# scripts/compliance-audit.sh (check_legacy_rulesets).
#
# A legacy ruleset (any default-branch ruleset other than pr-quality /
# code-quality) is "safe to delete" only when every required status check it
# carries is ALSO required by a sanctioned ruleset. The audit computes the set
# of uncovered checks (the migration delta); these tests pin that set logic.

bats_require_minimum_version 1.5.0

# Extract the contexts a ruleset requires (same jq the audit uses).
_ctx() {
  echo "$1" | jq -r '[.rules[]? | select(.type=="required_status_checks") | .parameters.required_status_checks[]?.context] | .[]'
}

# Given sanctioned contexts (newline list) and a legacy ruleset JSON, emit the
# uncovered contexts — the migration delta the audit reports.
_delta() {
  local sanctioned_ctx="$1" legacy_json="$2" c uncovered=""
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    grep -qxF "$c" <<< "$sanctioned_ctx" || uncovered+="$c "
  done <<< "$(_ctx "$legacy_json")"
  echo "$uncovered"
}

@test "delta: legacy checks fully covered by sanctioned → empty (safe to delete)" {
  sanctioned=$'Validate\nCodeQL\nSonarCloud\nagent-shield / AgentShield'
  legacy='{"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"SonarCloud"},{"context":"CodeQL"},{"context":"agent-shield / AgentShield"},{"context":"Validate"}]}}]}'
  run _delta "$sanctioned" "$legacy"
  [ "$status" -eq 0 ]
  [ -z "$(echo "$output" | tr -d '[:space:]')" ]
}

@test "delta: legacy ruleset with no required checks → empty (safe to delete)" {
  sanctioned=$'SonarCloud\nCodeQL'
  legacy='{"rules":[{"type":"pull_request","parameters":{}}]}'
  run _delta "$sanctioned" "$legacy"
  [ "$status" -eq 0 ]
  [ -z "$(echo "$output" | tr -d '[:space:]')" ]
}

@test "delta: legacy check not in sanctioned set → reported (migrate first)" {
  sanctioned=$'SonarCloud\nCodeQL\nagent-shield / AgentShield\nbuild-and-test'
  legacy='{"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CodeQL"},{"context":"coverage"}]}}]}'
  run _delta "$sanctioned" "$legacy"
  [ "$status" -eq 0 ]
  [[ "$output" == *"coverage"* ]]
  [[ "$output" != *"CodeQL"* ]]
}

@test "delta: multiple uncovered checks are all reported" {
  sanctioned=$'CodeQL'
  legacy='{"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"coverage"},{"context":"ShellCheck"},{"context":"CodeQL"}]}}]}'
  run _delta "$sanctioned" "$legacy"
  [[ "$output" == *"coverage"* ]]
  [[ "$output" == *"ShellCheck"* ]]
  [[ "$output" != *"CodeQL"* ]]
}

@test "delta: context names with spaces/slashes are matched whole, not by token" {
  # 'agent-shield / AgentShield' must match exactly; a partial like 'AgentShield'
  # alone in the sanctioned set must NOT count as covering it.
  sanctioned=$'AgentShield'
  legacy='{"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"agent-shield / AgentShield"}]}}]}'
  run _delta "$sanctioned" "$legacy"
  [[ "$output" == *"agent-shield / AgentShield"* ]]
}

@test "ctx: extracts required_status_checks contexts and ignores other rule types" {
  rs='{"rules":[{"type":"pull_request","parameters":{}},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"SonarCloud"},{"context":"CodeQL"}]}},{"type":"non_fast_forward"}]}'
  run _ctx "$rs"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SonarCloud"* ]]
  [[ "$output" == *"CodeQL"* ]]
}
