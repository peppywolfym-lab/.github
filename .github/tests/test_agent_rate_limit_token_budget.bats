#!/usr/bin/env bats
# Tests for the org-wide token-budget circuit breaker added to
# scripts/lib/agent-rate-limit.sh — the PROACTIVE pre-dispatch check that pauses
# new agentic dispatch when the shared, FIXED 5-hour Claude subscription
# (`session`) window is at/over the config-driven pause_threshold_pct
# (default 90%) (#641, Phase 5 of epic #636).
#
# Context (ADR docs/initiatives/agent-rate-limits-adr.md, #637; post-ADR
# clarification in the issue):
#   - Telemetry source of record is the OAuth usage endpoint (ADR §4.1), whose
#     credentialed read lives PRIVATE (ADR §8.2). This public library holds the
#     thresholds/policy, the pure decision, and a small ADAPTER SEAM the private
#     poller plugs the live read into — so no unit test touches the network.
#   - The `session` (5-hour) and `weekly_all` (7-day) windows are FIXED windows
#     with an authoritative resets_at; percent is monotonically non-decreasing,
#     so there is NO percentage resume mark (that is #994's glide path for
#     weekly_all; this story ships the session breaker and builds the adapter to
#     serve BOTH windows from one call).
#   - Fail-safe direction (ADR §7): on telemetry error (non-200, malformed body,
#     missing window entry) the breaker ALLOWS dispatch and logs a warning; a
#     fresh 429 + retry-after BLOCKS (a hard first-hand cap signal).
#   - weekly_scoped (per-model) is NEVER pause-worthy (scope guard, ADR §2.5).
#   - Threshold is config-driven, never hardcoded (AC #5). Integration into
#     arl_admission_gate ships INERT behind AGENT_TOKEN_BUDGET_ENABLED (canary /
#     dry-run rollout, AC #5/#6).

bats_require_minimum_version 1.5.0

LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts/lib/agent-rate-limit.sh"
GH_STUB_SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/test/scripts/compliance-remediate/stubs/gh"

setup() {
  TMP="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  export TMP

  # Put the env-driven gh stub on PATH and log every invocation so we can assert
  # the token-budget path never issues a mutating gh subcommand (guard-only).
  mkdir -p "$TMP/bin"
  cp "$GH_STUB_SRC" "$TMP/bin/gh"
  chmod +x "$TMP/bin/gh"
  PATH="$TMP/bin:$PATH"
  export PATH
  export GH_STUB_LOG="$TMP/gh.log"
  : >"$GH_STUB_LOG"
}

teardown() {
  if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
    rm -rf "$TMP"
  fi
}

# Write an agent-rate-limits config carrying the org_wide.token_budget block
# (session default threshold + claude_priority) plus a dev-lead agent type for
# the integration-gate tests, and export AGENT_RATE_LIMITS_CONFIG at it.
write_token_config() {
  local threshold="${1:-90}" claude_priority="${2:-true}"
  export AGENT_RATE_LIMITS_CONFIG="$TMP/agent-rate-limits.json"
  jq -n \
    --argjson threshold "$threshold" \
    --argjson claude_priority "$claude_priority" \
    '{
      status: "provisional",
      _schema_version: 1,
      agent_types: {
        "dev-lead": {
          max_concurrent_runs: 3,
          max_runtime_minutes: 30,
          cooldown_minutes: 5,
          daily_run_budget: 50,
          circuit_breaker: { consecutive_failure_threshold: 3, backoff_minutes: 30 }
        }
      },
      org_wide: {
        token_budget: {
          claude_priority: $claude_priority,
          limits: {
            session:       { kind: "session", window_hours: 5, pause_worthy: true, pause_threshold_pct: $threshold },
            weekly_all:    { kind: "weekly_all", window_days: 7, pause_worthy: true, reserve_pct_per_day: 2 },
            weekly_scoped: { kind: "weekly_scoped", pause_worthy: false }
          }
        }
      },
      exempt_actors: ["dependabot[bot]", "@petry-projects/org-leads"],
      exempt_labels: ["security"]
    }' >"$AGENT_RATE_LIMITS_CONFIG"
}

# Point the telemetry adapter seam at a fixture file holding the normalized
# envelope JSON the private poller would emit.
write_telemetry() {
  export AGENT_TOKEN_BUDGET_TELEMETRY_FILE="$TMP/telemetry.json"
  printf '%s' "$1" >"$AGENT_TOKEN_BUDGET_TELEMETRY_FILE"
}

# A 200 envelope whose body carries a limits[] array with the given session /
# weekly_all percentages.
envelope_limits() {
  local session_pct="$1" weekly_pct="${2:-40}"
  jq -nc --argjson s "$session_pct" --argjson w "$weekly_pct" '{
    status: 200,
    body: {
      limits: [
        { kind: "session",       percent: $s, severity: "warning", resets_at: "2026-08-31T12:00:00Z", is_active: true },
        { kind: "weekly_all",    percent: $w, severity: "normal",  resets_at: "2026-09-02T15:59:59Z", is_active: true },
        { kind: "weekly_scoped", percent: 100, severity: "critical", resets_at: "2026-09-02T15:59:59Z", is_active: true }
      ]
    }
  }'
}

# --------------------------------------------------------------------------
# Source-time contract — the new functions are defined, sourcing is inert.
# --------------------------------------------------------------------------
@test "sourcing defines the token-budget functions and is side-effect-free" {
  run bash -c "set -euo pipefail; source '$LIB'; \
    for f in arl_token_pause_threshold arl_token_budget_decision arl_token_budget_gate \
             arl_token_fetch_envelope arl_token_extract_percent arl_token_breaker_marker; do \
      declare -F \"\$f\" >/dev/null || { echo \"missing \$f\"; exit 1; }; done; echo ok"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

# --------------------------------------------------------------------------
# Config accessors (AC #5) — the threshold is read from config, never hardcoded.
# --------------------------------------------------------------------------
@test "arl_token_pause_threshold reads the session threshold from config" {
  write_token_config 90 true
  run bash -c "source '$LIB'; arl_token_pause_threshold session"
  [ "$status" -eq 0 ]
  [ "$output" = "90" ]
}

@test "arl_token_pause_threshold honors a non-default configured threshold (not hardcoded 90)" {
  write_token_config 75 true
  run bash -c "source '$LIB'; arl_token_pause_threshold session"
  [ "$status" -eq 0 ]
  [ "$output" = "75" ]
}

@test "arl_token_window_pause_worthy is true for session, false for weekly_scoped" {
  write_token_config 90 true
  run bash -c "source '$LIB'; arl_token_window_pause_worthy session"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  run bash -c "source '$LIB'; arl_token_window_pause_worthy weekly_scoped"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "arl_token_claude_priority reflects the config flag" {
  write_token_config 90 true
  run bash -c "source '$LIB'; arl_token_claude_priority"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  write_token_config 90 false
  run bash -c "source '$LIB'; arl_token_claude_priority"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

# --------------------------------------------------------------------------
# Claude-priority-on-recovery ranking (AC #3)
# --------------------------------------------------------------------------
@test "arl_token_priority_rank ranks Claude-backed agents ahead of initiative-driver" {
  write_token_config 90 true
  run bash -c "source '$LIB'; arl_token_priority_rank dev-lead"
  [ "$output" = "0" ]
  run bash -c "source '$LIB'; arl_token_priority_rank feature-ideation"
  [ "$output" = "0" ]
  run bash -c "source '$LIB'; arl_token_priority_rank compliance-audit"
  [ "$output" = "0" ]
  run bash -c "source '$LIB'; arl_token_priority_rank initiative-driver"
  [ "$output" = "1" ]
}

@test "arl_token_priority_rank collapses to equal rank when claude_priority is off" {
  write_token_config 90 false
  run bash -c "source '$LIB'; arl_token_priority_rank dev-lead"
  [ "$output" = "0" ]
  run bash -c "source '$LIB'; arl_token_priority_rank initiative-driver"
  [ "$output" = "0" ]
}

# --------------------------------------------------------------------------
# Pure decision core (AC #1)
# Signature: <percent> <threshold> <pause_worthy>
# --------------------------------------------------------------------------
@test "decision: percent over threshold on a pause-worthy window defers" {
  run bash -c "source '$LIB'; arl_token_budget_decision 92 90 true"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

@test "decision: percent exactly at threshold defers (>= boundary)" {
  run bash -c "source '$LIB'; arl_token_budget_decision 90 90 true"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

@test "decision: percent under threshold allows" {
  run bash -c "source '$LIB'; arl_token_budget_decision 89 90 true"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "decision: a non-pause-worthy window never defers (scope guard)" {
  run bash -c "source '$LIB'; arl_token_budget_decision 100 90 false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "decision: a malformed percent degrades to allow (fail-safe)" {
  run bash -c "source '$LIB'; arl_token_budget_decision garbage 90 true"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "decision: an empty/malformed threshold allows (never blocks)" {
  run bash -c "source '$LIB'; arl_token_budget_decision 99 '' true"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

# --------------------------------------------------------------------------
# Adapter parsers (AC #2 / post-ADR #5) — prefer limits[], fall back to
# flattened keys; serve BOTH windows from one body.
# --------------------------------------------------------------------------
@test "arl_token_extract_percent prefers the limits[] entry for the window" {
  body='{"limits":[{"kind":"session","percent":88},{"kind":"weekly_all","percent":33}],"five_hour":{"percent":11}}'
  run bash -c "source '$LIB'; arl_token_extract_percent '$body' session"
  [ "$status" -eq 0 ]
  [ "$output" = "88" ]
}

@test "arl_token_extract_percent serves weekly_all from the same body (one call, both windows)" {
  body='{"limits":[{"kind":"session","percent":88},{"kind":"weekly_all","percent":33}]}'
  run bash -c "source '$LIB'; arl_token_extract_percent '$body' weekly_all"
  [ "$status" -eq 0 ]
  [ "$output" = "33" ]
}

@test "arl_token_extract_percent falls back to the flattened five_hour key" {
  body='{"five_hour":{"percent":95},"seven_day":{"percent":50}}'
  run bash -c "source '$LIB'; arl_token_extract_percent '$body' session"
  [ "$status" -eq 0 ]
  [ "$output" = "95" ]
}

@test "arl_token_extract_percent floors a fractional percent" {
  body='{"limits":[{"kind":"session","percent":89.9}]}'
  run bash -c "source '$LIB'; arl_token_extract_percent '$body' session"
  [ "$status" -eq 0 ]
  [ "$output" = "89" ]
}

@test "arl_token_extract_percent echoes empty when the window entry is absent" {
  body='{"limits":[{"kind":"weekly_all","percent":33}]}'
  run bash -c "source '$LIB'; arl_token_extract_percent '$body' session"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --------------------------------------------------------------------------
# Telemetry adapter seam (AC #2) — mockable via CMD/FILE; default unavailable.
# --------------------------------------------------------------------------
@test "arl_token_fetch_envelope reads the FILE seam" {
  write_telemetry '{"status":200,"body":{"limits":[]}}'
  run bash -c "source '$LIB'; arl_token_fetch_envelope"
  [ "$status" -eq 0 ]
  run bash -c "source '$LIB'; arl_token_fetch_envelope | jq -er '.status'"
  [ "$output" = "200" ]
}

@test "arl_token_fetch_envelope reads the CMD seam (the private poller's plug point)" {
  export AGENT_TOKEN_BUDGET_TELEMETRY_CMD='jq -nc "{status:429,retry_after:90}"'
  run bash -c "source '$LIB'; arl_token_fetch_envelope | jq -er '.status'"
  [ "$status" -eq 0 ]
  [ "$output" = "429" ]
}

@test "arl_token_fetch_envelope defaults to unavailable (status 0) with no source configured" {
  run bash -c "unset AGENT_TOKEN_BUDGET_TELEMETRY_FILE AGENT_TOKEN_BUDGET_TELEMETRY_CMD; source '$LIB'; arl_token_fetch_envelope | jq -er '.status'"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "arl_token_fetch_envelope degrades a malformed seam payload to status 0" {
  write_telemetry 'not json {{{'
  run bash -c "source '$LIB'; arl_token_fetch_envelope | jq -er '.status'"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# --------------------------------------------------------------------------
# Orchestrator arl_token_budget_gate (AC #1/#2/#4/#6)
# --------------------------------------------------------------------------
@test "gate: session at/over threshold defers (at-threshold defers)" {
  write_token_config 90 true
  write_telemetry "$(envelope_limits 92 40)"
  run bash -c "source '$LIB'; arl_token_budget_gate session"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

@test "gate: session under threshold allows (under-threshold allows)" {
  write_token_config 90 true
  write_telemetry "$(envelope_limits 50 40)"
  run bash -c "source '$LIB'; arl_token_budget_gate session"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: honors a non-default threshold from config (config-driven, not hardcoded 90)" {
  write_token_config 40 true
  write_telemetry "$(envelope_limits 50 40)"
  run bash -c "source '$LIB'; arl_token_budget_gate session"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

@test "gate: a fresh 429 with a future deadline BLOCKS (hard cap signal, ADR §7)" {
  write_token_config 90 true
  local future_deadline; future_deadline=$(( $(date +%s) + 300 ))
  write_telemetry "{\"status\":429,\"retry_after\":120,\"retry_until\":${future_deadline}}"
  run bash -c "source '$LIB'; arl_token_budget_gate session"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
  [[ "$output" == *"429"* ]]
}

@test "gate: a non-200 telemetry status fails safe to allow-with-warning" {
  write_token_config 90 true
  write_telemetry '{"status":503}'
  run bash -c "source '$LIB'; arl_token_budget_gate session"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: an unavailable telemetry source (status 0) fails safe to allow" {
  write_token_config 90 true
  write_telemetry '{"status":0}'
  run bash -c "source '$LIB'; arl_token_budget_gate session"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: no telemetry source configured fails safe to allow (disabled/degraded mode, AC #6)" {
  write_token_config 90 true
  run bash -c "unset AGENT_TOKEN_BUDGET_TELEMETRY_FILE AGENT_TOKEN_BUDGET_TELEMETRY_CMD; source '$LIB'; arl_token_budget_gate session"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: a missing window entry in an otherwise-200 body fails safe to allow" {
  write_token_config 90 true
  write_telemetry '{"status":200,"body":{"limits":[{"kind":"weekly_all","percent":99}]}}'
  run bash -c "source '$LIB'; arl_token_budget_gate session"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: a window flagged is_active=false does not defer even over threshold" {
  write_token_config 90 true
  write_telemetry '{"status":200,"body":{"limits":[{"kind":"session","percent":99,"is_active":false}]}}'
  run bash -c "source '$LIB'; arl_token_budget_gate session"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: weekly_scoped is never pause-worthy even at 100% (scope guard, ADR §2.5)" {
  write_token_config 90 true
  write_telemetry '{"status":200,"body":{"limits":[{"kind":"weekly_scoped","percent":100,"is_active":true}]}}'
  run bash -c "source '$LIB'; arl_token_budget_gate weekly_scoped"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: reads a session percent via the flattened fallback and defers over threshold" {
  write_token_config 90 true
  write_telemetry '{"status":200,"body":{"five_hour":{"percent":95},"seven_day":{"percent":50}}}'
  run bash -c "source '$LIB'; arl_token_budget_gate session"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

@test "gate: is set -euo pipefail-safe on the defer path" {
  write_token_config 90 true
  write_telemetry "$(envelope_limits 95 40)"
  run bash -c "set -euo pipefail; source '$LIB'; arl_token_budget_gate session"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

# --------------------------------------------------------------------------
# Human-clearable marker / label surfacing (AC #3)
# --------------------------------------------------------------------------
@test "arl_token_breaker_marker embeds the window in a stable HTML marker" {
  run bash -c "source '$LIB'; arl_token_breaker_marker session"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<!--"* ]]
  [[ "$output" == *"session"* ]]
  [[ "$output" == *"-->"* ]]
}

@test "arl_token_should_escalate is true when the marker is absent, false when present (dedup)" {
  run bash -c "source '$LIB'; arl_token_should_escalate 'nothing here' session"
  [ "$status" -eq 0 ]
  run bash -c "source '$LIB'; marker=\"\$(arl_token_breaker_marker session)\"; arl_token_should_escalate \"prior \$marker\" session"
  [ "$status" -eq 1 ]
}

@test "the token breaker reuses the shared human-clearable label" {
  run bash -c "source '$LIB'; arl_breaker_label"
  [ "$status" -eq 0 ]
  [ "$output" = "needs-human-review" ]
}

# --------------------------------------------------------------------------
# Integration into arl_admission_gate (AC #1/#5) — INERT behind the flag.
# --------------------------------------------------------------------------
@test "admission gate: token-budget check is INERT when AGENT_TOKEN_BUDGET_ENABLED is unset" {
  write_token_config 90 true
  write_telemetry "$(envelope_limits 99 99)"
  write_state() { export AGENT_RATE_LIMITS_STATE="$TMP/state.json"; printf '%s' "$1" >"$AGENT_RATE_LIMITS_STATE"; }
  write_state '{"dev-lead":{"last_run_epoch":0,"daily_count":0,"consecutive_failures":0,"breaker_opened_epoch":0}}'
  export GH_STUB_STDOUT='[{"status":"in_progress"}]'
  run bash -c "source '$LIB'; arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "admission gate: defers when the token budget is enabled and tripped" {
  write_token_config 90 true
  write_telemetry "$(envelope_limits 99 40)"
  export AGENT_RATE_LIMITS_STATE="$TMP/state.json"
  printf '%s' '{"dev-lead":{"last_run_epoch":0,"daily_count":0,"consecutive_failures":0,"breaker_opened_epoch":0}}' >"$AGENT_RATE_LIMITS_STATE"
  export GH_STUB_STDOUT='[{"status":"in_progress"}]'
  run bash -c "source '$LIB'; AGENT_TOKEN_BUDGET_ENABLED=true arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
  [[ "$output" == *"token"* ]]
}

@test "admission gate: an exempt actor is allowed even when the token budget is tripped" {
  write_token_config 90 true
  write_telemetry "$(envelope_limits 99 99)"
  run bash -c "source '$LIB'; AGENT_TOKEN_BUDGET_ENABLED=true arl_admission_gate dev-lead 'dependabot[bot]'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
  [[ "$output" == *"exempt"* ]]
}

@test "admission gate: token-budget defer path is set -euo pipefail-safe and issues no mutating gh call" {
  write_token_config 90 true
  write_telemetry "$(envelope_limits 99 40)"
  export AGENT_RATE_LIMITS_STATE="$TMP/state.json"
  printf '%s' '{"dev-lead":{"last_run_epoch":0,"daily_count":0,"consecutive_failures":0,"breaker_opened_epoch":0}}' >"$AGENT_RATE_LIMITS_STATE"
  export GH_STUB_STDOUT='[{"status":"in_progress"}]'
  run bash -c "set -euo pipefail; source '$LIB'; AGENT_TOKEN_BUDGET_ENABLED=true arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
  run grep -qE 'run cancel|pr create|pr edit|issue edit|label|api -X (POST|PATCH|PUT|DELETE)' "$GH_STUB_LOG"
  [ "$status" -eq 1 ]
}

@test "admission gate: DRY_RUN prints the would-be token-budget defer but returns allow" {
  write_token_config 90 true
  write_telemetry "$(envelope_limits 99 40)"
  export AGENT_RATE_LIMITS_STATE="$TMP/state.json"
  printf '%s' '{"dev-lead":{"last_run_epoch":0,"daily_count":0,"consecutive_failures":0,"breaker_opened_epoch":0}}' >"$AGENT_RATE_LIMITS_STATE"
  export GH_STUB_STDOUT='[{"status":"in_progress"}]'
  run bash -c "source '$LIB'; AGENT_TOKEN_BUDGET_ENABLED=true DRY_RUN=true arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"defer"* ]]
  [[ "$output" == *"decision=allow"* ]]
}

# --------------------------------------------------------------------------
# Timeout on AGENT_TOKEN_BUDGET_TELEMETRY_CMD (coderabbitai: line 592)
# --------------------------------------------------------------------------
@test "fetch: a blocking AGENT_TOKEN_BUDGET_TELEMETRY_CMD times out and fails safe to status 0" {
  write_token_config 90 true
  # A command that sleeps longer than the 1-second test timeout
  export AGENT_TOKEN_BUDGET_TELEMETRY_CMD="sleep 10"
  export AGENT_TOKEN_BUDGET_TELEMETRY_TIMEOUT=1
  run bash -c "source '$LIB'; arl_token_fetch_envelope"
  [ "$status" -eq 0 ]
  [[ "$output" == '{"status":0}' ]]
}

@test "gate: a blocking telemetry CMD times out and allows admission (fail-open)" {
  write_token_config 90 true
  export AGENT_TOKEN_BUDGET_TELEMETRY_CMD="sleep 10"
  export AGENT_TOKEN_BUDGET_TELEMETRY_TIMEOUT=1
  run bash -c "source '$LIB'; arl_token_budget_gate session"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

# --------------------------------------------------------------------------
# 429 expiry: an expired retry window allows dispatch (coderabbitai: line 724)
# --------------------------------------------------------------------------
@test "gate: a 429 with observed_at+retry_after in the past allows (expired window, fail-open)" {
  write_token_config 90 true
  # observed 200 seconds ago, retry_after=120 — deadline has passed
  local past_ts
  past_ts=$(( $(date +%s) - 200 ))
  write_telemetry "{\"status\":429,\"retry_after\":120,\"observed_at\":${past_ts}}"
  run bash -c "source '$LIB'; arl_token_budget_gate session"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: a 429 with retry_until in the past allows (expired absolute deadline, fail-open)" {
  write_token_config 90 true
  local past_deadline
  past_deadline=$(( $(date +%s) - 60 ))
  write_telemetry "{\"status\":429,\"retry_after\":120,\"retry_until\":${past_deadline}}"
  run bash -c "source '$LIB'; arl_token_budget_gate session"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: a 429 with retry_until in the future still defers (window not expired)" {
  write_token_config 90 true
  local future_deadline
  future_deadline=$(( $(date +%s) + 300 ))
  write_telemetry "{\"status\":429,\"retry_after\":120,\"retry_until\":${future_deadline}}"
  run bash -c "source '$LIB'; arl_token_budget_gate session"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

@test "gate: a 429 with no deadline anchor (no retry_until/observed_at) allows, not defers (stale cached response)" {
  write_token_config 90 true
  write_telemetry '{"status":429,"retry_after":3600}'
  run bash -c "source '$LIB'; arl_token_budget_gate session"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

# --------------------------------------------------------------------------
# Fail-open: empty/error from arl_token_budget_gate must not defer (gemini: line 862)
# --------------------------------------------------------------------------
@test "admission gate: an empty token_decision from a broken gate allows, not defers (fail-open)" {
  write_token_config 90 true
  write_telemetry "$(envelope_limits 99 40)"
  export AGENT_RATE_LIMITS_STATE="$TMP/state.json"
  printf '%s' '{"dev-lead":{"last_run_epoch":0,"daily_count":0,"consecutive_failures":0,"breaker_opened_epoch":0}}' >"$AGENT_RATE_LIMITS_STATE"
  export GH_STUB_STDOUT='[{"status":"in_progress"}]'
  # Override arl_token_budget_gate to emit nothing (simulating a broken gate)
  run bash -c "source '$LIB'; arl_token_budget_gate() { return 0; }; AGENT_TOKEN_BUDGET_ENABLED=true arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

# --------------------------------------------------------------------------
# Marker surfacing when token breaker defers (codeant-ai: line 859-862)
# --------------------------------------------------------------------------
@test "admission gate: token-budget defer emits escalation marker to stderr" {
  write_token_config 90 true
  write_telemetry "$(envelope_limits 99 40)"
  export AGENT_RATE_LIMITS_STATE="$TMP/state.json"
  printf '%s' '{"dev-lead":{"last_run_epoch":0,"daily_count":0,"consecutive_failures":0,"breaker_opened_epoch":0}}' >"$AGENT_RATE_LIMITS_STATE"
  export GH_STUB_STDOUT='[{"status":"in_progress"}]'
  run bash -c "source '$LIB'; AGENT_TOKEN_BUDGET_ENABLED=true arl_admission_gate dev-lead donpetry-bot" 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"<!--"* ]]
  [[ "$output" == *"session"* ]]
}
