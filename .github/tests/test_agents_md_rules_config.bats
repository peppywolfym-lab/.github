#!/usr/bin/env bats
# Contract tests for scripts/lib/agents-md-rules.json — the documented,
# machine-readable structural rule set for AGENTS.md validation (#643, Phase 1
# of epic #642).
#
# Context (reference doc docs/initiatives/agents-md-validation.md; discussion
# #534; idea #341): the org wants a deterministic STRUCTURAL validator for
# AGENTS.md wired into the Standards Sync compliance audit (epic #642). This
# Phase-1 story delivers ONLY the rule set the later linter reads — the file is
# INERT on merge (no script consumes it yet, that is Phase 2). Keeping the rules
# in a data file the linter reads is the key design constraint: the AAIF/agents.md
# spec is young and moving, so the rule set must be updatable without code changes.
#
# These tests validate the contract every future consumer relies on: the file
# parses as JSON; all required keys exist; the scope is structural (semantic
# checks are explicitly out of scope, matching the discussion's adversarial
# rebuttal); every rule is tagged exactly 'required' or 'recommended' so a
# recommended rule is reported but never fails the check; the structurally-stable
# rules (single H1, valid heading hierarchy, resolvable cross-references) are
# 'required' while contested section-presence rules stay 'recommended'; the
# captured spec snapshot records a source + date; and the informational->blocking
# promotion gate encodes two clean cycles plus maintainer sign-off.

bats_require_minimum_version 1.5.0

CONFIG="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts/lib/agents-md-rules.json"

@test "rule-set file exists" {
  [ -f "$CONFIG" ]
}

@test "rule set parses as valid JSON" {
  run jq -e . "$CONFIG"
  [ "$status" -eq 0 ]
}

@test "_schema_version is a positive integer" {
  run jq -er '._schema_version' "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -gt 0 ]
}

@test "an inline _note documents the file is inert (no linter consumes it yet)" {
  # Phase 1 is data-only; the Phase 2 linter reads this file. Assert the
  # inert/Phase-2 intent is written down so a reader knows nothing enforces it yet.
  run jq -er '._note | ascii_downcase | test("inert|phase 2|phase-2")' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "all required top-level keys exist" {
  run jq -e '[has("_schema_version"), has("_note"), has("scope"), has("out_of_scope"), has("spec_snapshot"), has("rules"), has("promotion")] | all' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "scope is 'structural' (AC #3)" {
  run jq -er '.scope' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "structural" ]
}

@test "out_of_scope is a non-empty array explicitly excluding semantic/content checks (AC #3)" {
  run jq -er '.out_of_scope | type' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "array" ]
  run jq -er '.out_of_scope | length' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
  # The exclusion of semantic/content validation must be spelled out, not implied.
  run jq -er '[.out_of_scope[] | ascii_downcase] | any(test("semantic") or test("content"))' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "spec_snapshot records a source and a date (AC #1 task 2)" {
  run jq -er '.spec_snapshot | has("source") and has("date")' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  run jq -er '.spec_snapshot.source' "$CONFIG"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # Date must be an ISO yyyy-mm-dd so the derivation point is unambiguous.
  run jq -er '.spec_snapshot.date' "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

@test "rules is a non-empty array" {
  run jq -er '.rules | type' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "array" ]
  run jq -er '.rules | length' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "every rule has a unique id, a description and an element" {
  run jq -e '.rules | all(.[]; has("id") and (.id | type == "string" and length > 0) and has("description") and has("element") and has("applies_to") and has("check") and has("rationale"))' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  # ids must be unique — the linter and audit summary key findings on them.
  run jq -er '[.rules[].id] | (length) == (unique | length)' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "every rule is tagged exactly 'required' or 'recommended' (AC #2)" {
  run jq -e '.rules | all(.[]; .level == "required" or .level == "recommended")' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "at least one required and at least one recommended rule exist (AC #2)" {
  run jq -er '[.rules[] | select(.level == "required")] | length' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
  run jq -er '[.rules[] | select(.level == "recommended")] | length' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "the required rules exist and are 'required'" {
  for id in single-h1-title heading-hierarchy-valid cross-reference-integrity org-repo-import-consistency fenced-code-block-closure; do
    run jq -er --arg id "$id" '.rules[] | select(.id == $id) | .level' "$CONFIG"
    [ "$status" -eq 0 ]
    [ "$output" = "required" ]
  done
}

@test "contested section-presence rules stay 'recommended', never 'required' (Dev Notes)" {
  # The required-vs-recommended split for section presence is an open question;
  # any rule whose element is section-presence must NOT be hard-required yet.
  run jq -e '[.rules[] | select(.element == "section-presence")] | all(.[]; .level == "recommended")' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  # And there is at least one such rule so the guard is not vacuous.
  run jq -er '[.rules[] | select(.element == "section-presence")] | length' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "promotion gate encodes two clean cycles and maintainer sign-off (AC #1 task 4)" {
  run jq -er '.promotion | has("clean_cycles_required") and has("maintainer_sign_off_required") and has("target_severity")' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  run jq -er '.promotion.clean_cycles_required' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  run jq -e '.promotion.maintainer_sign_off_required == true' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "promotion default_severity starts informational (non-blocking) (epic scope)" {
  run jq -er '.promotion.default_severity' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "informational" ]
}

@test "promotion toggle ships DISABLED (enabled=false) — the mechanism arms nothing (#647)" {
  # The Phase-4 "arms nothing" guarantee is literally promotion.toggle.enabled=false.
  # Pin it so a future flip to true cannot pass CI silently — mirroring the disarmed
  # breaker assertion (weekly_all.enabled == false) in
  # tests/test_agent_rate_limits_config.bats and the default_severity assertion above.
  run jq -e '.promotion.toggle.enabled == false' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}
