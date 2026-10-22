#!/usr/bin/env bats
# Contract tests for standards/agent-rate-limits.json — the machine-readable
# single source of truth for per-agent-type rate limits, circuit breakers, and
# the org-wide Claude token-budget breaker (#638, Phase 2 of epic #636).
#
# Context (ADR docs/initiatives/agent-rate-limits-adr.md, #637):
# GitHub exposes no native per-workflow rate limiter and no run-count budget
# (ADR §2/§4), so the limits live as source-side shared config consumed later by
# the Phase 3 gate library and the Phase 4-5 wiring. This story delivers ONLY the
# data file: it is INERT on merge, no workflow reads it (AC #3), and every number
# is a proposal pending human sign-off (ADR §6/§7), mirroring the pr-limits
# sign-off gate.
#
# These tests validate the contract every future consumer relies on: the file
# parses as JSON, all required keys exist, per-agent numeric limits are positive
# integers, each agent carries a circuit breaker, the token-budget block records
# the 5-hour session threshold (default 90%) and the Claude-priority flag, only
# account-wide windows are pause-worthy, and — per the post-ADR clarification —
# there is NO percentage resume mark and the windows are never called "rolling".

bats_require_minimum_version 1.5.0

CONFIG="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/standards/agent-rate-limits.json"
PR_LIMITS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/standards/pr-limits.json"

# The four in-scope agent types fixed by the ADR (§3).
AGENT_TYPES=(dev-lead compliance-audit feature-ideation initiative-driver)

@test "config file exists" {
  [ -f "$CONFIG" ]
}

@test "config parses as valid JSON" {
  run jq -e . "$CONFIG"
  [ "$status" -eq 0 ]
}

@test "status records the config is signed-off (epic #636 gate consumed, #640)" {
  # The maintainer sign-off on #636 (2026-09-01) is consumed by the Phase-4
  # wiring (#640): the per-agent limits are now live for initiative-driver
  # (enforcing) and log-only for the rest. A regression BACK to provisional would
  # falsely re-open the sign-off gate, so pin the signed-off state.
  run jq -er '.status' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "signed-off" ]
}

@test "an inline _note records the human sign-off" {
  run jq -er '._note' "$CONFIG"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # The sign-off provenance must be written down so a reader knows the gate cleared.
  run jq -er '._note | ascii_downcase | test("sign-off|sign off")' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "the weekly glide-path breaker stays disarmed (weekly_all.enabled false; AC #6)" {
  # Signing off the per-agent limits must NOT arm the weekly glide-path breaker
  # (#994) — that is an explicit out-of-scope follow-up. `jq -r`: a legitimate
  # `false` must not flip the exit code.
  run jq -r '.org_wide.token_budget.limits.weekly_all.enabled' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "_schema_version is a positive integer" {
  run jq -er '._schema_version' "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -gt 0 ]
}

@test "all required top-level keys exist" {
  run jq -e '[has("status"), has("_note"), has("_schema_version"), has("agent_types"), has("org_wide"), has("exempt_actors"), has("exempt_labels")] | all' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "agent_types contains exactly the four ADR in-scope types" {
  run jq -er '(.agent_types // {}) | keys_unsorted | sort | join(",")' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "compliance-audit,dev-lead,feature-ideation,initiative-driver" ]
}

@test "each agent type carries all five ADR control dimensions" {
  run jq -e '.agent_types | all(.[]; has("max_concurrent_runs") and has("max_runtime_minutes") and has("cooldown_minutes") and has("daily_run_budget") and has("circuit_breaker"))' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "per-agent concurrency, runtime and daily budget are positive integers" {
  run jq -e '.agent_types | all(.[]; [.max_concurrent_runs, .max_runtime_minutes, .daily_run_budget] | all(type == "number" and . > 0 and . % 1 == 0))' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "per-agent cooldown is a non-negative integer (0 = n/a for weekly-cron agents)" {
  # Cooldown is 'n/a' for the weekly-cron agents (ADR §6) and is encoded as 0
  # rather than a faked positive value. It must still be a real non-negative int.
  run jq -e '.agent_types | all(.[]; .cooldown_minutes | type == "number" and . >= 0 and . % 1 == 0)' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "each agent circuit breaker has a positive threshold and backoff" {
  run jq -e '.agent_types | all(.[]; .circuit_breaker | [.consecutive_failure_threshold, .backoff_minutes] | all(type == "number" and . > 0 and . % 1 == 0))' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "daily_run_budget is present as the per-agent cost bound (AC #7)" {
  # The epic's cost cap traces to this concrete key; assert it exists per agent
  # so the traceability the standard doc claims is real in the config.
  run jq -e '.agent_types | all(.[]; has("daily_run_budget"))' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "org_wide.token_budget block exists" {
  run jq -e '.org_wide | has("token_budget")' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "the 5-hour session pause threshold is within (0,100]" {
  run jq -er '.org_wide.token_budget.limits.session.pause_threshold_pct' "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -gt 0 ]
  [ "$output" -le 100 ]
}

@test "the session threshold default is 90 (ADR §7 / AC #2)" {
  run jq -er '.org_wide.token_budget.limits.session.pause_threshold_pct' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "90" ]
}

@test "claude_priority flag is boolean true (AC #2)" {
  run jq -e '.org_wide.token_budget.claude_priority | type == "boolean" and .' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "the session (5h) and weekly_all (7d) windows are pause-worthy" {
  run jq -e '.org_wide.token_budget.limits | (.session.pause_worthy and .weekly_all.pause_worthy)' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  # Guard: no window outside the named account-wide set may be pause-worthy
  run jq -e '[.org_wide.token_budget.limits | to_entries[] | select(.key != "session" and .key != "weekly_all") | .value.pause_worthy] | all(. == false or . == null)' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "weekly_scoped (per-model) is NOT pause-worthy (ADR §2.5 / post-ADR #4)" {
  # `jq -r` (not `-e`): a legitimate `false` value must not flip the exit code.
  run jq -r '.org_wide.token_budget.limits.weekly_scoped.pause_worthy' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "weekly_all reserve_pct_per_day, if present, defaults to 2 and is a positive int" {
  # Optional glide-path key; when present it must be the inert default of 2
  # (post-ADR clarification #3). `//empty` skips the check when absent.
  run jq -er '.org_wide.token_budget.limits.weekly_all.reserve_pct_per_day // empty' "$CONFIG"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    [[ "$output" =~ ^[0-9]+$ ]]
    [ "$output" -gt 0 ]
    [ "$output" = "2" ]
  fi
}

@test "there is NO percentage resume mark anywhere (post-ADR clarification #2)" {
  # An 80% resume/hysteresis mark was REMOVED, not re-tuned: under a fixed window
  # a downward percentage dip cannot occur, making such a mark unreachable. Guard
  # that no resume_pct / resume_threshold / hysteresis key is re-introduced.
  # `jq` (not `-e`): a boolean `false` result is the passing case here.
  run jq '[paths | .[-1]] | map(tostring | ascii_downcase)
          | any(test("resume_pct|resume_threshold|resume_mark|hysteresis"))' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "the token-budget windows are never described as 'rolling' (post-ADR #1)" {
  # The session (5h) and weekly_all (7d) SUBSCRIPTION windows are FIXED
  # (authoritative resets_at), not rolling/sliding — guard that vocabulary in the
  # token_budget subtree. (The per-agent daily_run_budget IS a rolling 24h window
  # per ADR §5, a different mechanism, so the guard is scoped, not file-wide.)
  run jq -r '[.org_wide.token_budget | .. | strings] | join(" ") | ascii_downcase | test("rolling")' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "exempt_actors is a non-empty array" {
  run jq -er '.exempt_actors | type' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "array" ]
  run jq -er '.exempt_actors | length' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "exemption sets match pr-limits (same-set contract)" {
  run jq -e --slurpfile pr_limits "$PR_LIMITS" '
    (.exempt_actors | sort) == ($pr_limits[0].exempt_actors | sort) and
    (.exempt_labels | sort) == ($pr_limits[0].exempt_labels | sort)' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "dependabot[bot] is present in the exempt-actor list (reused from pr-limits)" {
  run jq -e '.exempt_actors | index("dependabot[bot]") != null' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "org-leads break-glass actor is present in the exempt-actor list" {
  run jq -e '.exempt_actors | index("@petry-projects/org-leads") != null' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "security is present in the exempt-label list" {
  run jq -e '.exempt_labels | index("security") != null' "$CONFIG"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}
