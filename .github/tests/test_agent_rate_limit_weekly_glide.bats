#!/usr/bin/env bats
# Tests for the org-wide weekly-budget GLIDE-PATH circuit breaker added to
# scripts/lib/agent-rate-limit.sh — the time-varying breaker that pauses new
# agentic dispatch when the shared, FIXED 7-day Claude subscription
# (`weekly_all`) window crosses a threshold that RISES as the weekly reset
# approaches (#994, Phase 6 of epic #636).
#
# Context (ADR docs/initiatives/agent-rate-limits-adr.md, #637; post-ADR
# clarification in the issue):
#   - Extends the Phase-5 (#641) telemetry adapter, which already serves BOTH the
#     `session` (5-hour) and `weekly_all` (7-day) windows from one call — so no
#     unit test touches the network (mocked adapter seam only).
#   - The threshold is `clamp(ceiling_pct - reserve_pct_per_day * days_until_reset,
#     floor_pct, ceiling_pct)`. With reserve=2, ceiling=100, floor=86 the schedule
#     is 100% (reset day) .. 86% (just reset). No number is hardcoded (AC #1); the
#     schedule is expressible purely as config.
#   - `days_until_reset` derives from the telemetry payload's authoritative
#     `resets_at`, never a hardcoded weekday. Partial days round UP so the day
#     before reset is 1 day left (98%), not 0 (AC #2).
#   - Keys on the account-wide `weekly_all` window; a `weekly_scoped` (per-model)
#     limit at critical/is_active must NOT trip a fleet pause (AC #3).
#   - Fail-safe direction (ADR §7): on telemetry error (non-200, malformed body,
#     missing window/resets_at entry) the breaker ALLOWS dispatch with a warning;
#     a fresh 429 + retry-after BLOCKS (a hard first-hand cap signal) (AC #5).
#   - The breaker can CLOSE before `resets_at` — but only because the rising
#     threshold moved past a static (monotonic) percent, never because usage fell.
#     There is deliberately no percentage resume mark.
#   - Integration into arl_admission_gate ships INERT behind
#     AGENT_TOKEN_BUDGET_ENABLED (env arm) AND the config `weekly_all.enabled`
#     flag (canary / dry-run rollout, AC #6/#7).

bats_require_minimum_version 1.5.0

LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts/lib/agent-rate-limit.sh"
GH_STUB_SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/test/scripts/compliance-remediate/stubs/gh"

setup() {
  TMP="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  export TMP

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

# Write an agent-rate-limits config carrying a weekly_all glide block. Args:
#   $1 enabled (default true), $2 reserve (2), $3 floor (86), $4 ceiling (100),
#   $5 session threshold (90).
write_glide_config() {
  local enabled="${1:-true}" reserve="${2:-2}" floor="${3:-86}" ceiling="${4:-100}" session="${5:-90}"
  export AGENT_RATE_LIMITS_CONFIG="$TMP/agent-rate-limits.json"
  jq -n \
    --argjson enabled "$enabled" \
    --argjson reserve "$reserve" \
    --argjson floor "$floor" \
    --argjson ceiling "$ceiling" \
    --argjson session "$session" \
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
          claude_priority: true,
          limits: {
            session:       { kind: "session", window_hours: 5, pause_worthy: true, pause_threshold_pct: $session },
            weekly_all:    { kind: "weekly_all", window_days: 7, pause_worthy: true, enabled: $enabled, reserve_pct_per_day: $reserve, floor_pct: $floor, ceiling_pct: $ceiling },
            weekly_scoped: { kind: "weekly_scoped", pause_worthy: false }
          }
        }
      },
      exempt_actors: ["dependabot[bot]", "@petry-projects/org-leads"],
      exempt_labels: ["security"]
    }' >"$AGENT_RATE_LIMITS_CONFIG"
}

write_telemetry() {
  export AGENT_TOKEN_BUDGET_TELEMETRY_FILE="$TMP/telemetry.json"
  printf '%s' "$1" >"$AGENT_TOKEN_BUDGET_TELEMETRY_FILE"
}

# A 200 envelope whose weekly_all limit carries the given percent + resets_at,
# and a benign under-threshold session so only the glide path can trip.
envelope_weekly() {
  local weekly_pct="$1" resets_at="$2" session_pct="${3:-10}"
  jq -nc --argjson w "$weekly_pct" --arg r "$resets_at" --argjson s "$session_pct" '{
    status: 200,
    body: {
      limits: [
        { kind: "session",       percent: $s, severity: "normal", resets_at: "2099-01-01T00:00:00Z", is_active: true },
        { kind: "weekly_all",    percent: $w, severity: "normal", resets_at: $r, is_active: true },
        { kind: "weekly_scoped", percent: 100, severity: "critical", resets_at: $r, is_active: true }
      ]
    }
  }'
}

# Epoch for an ISO timestamp (GNU date).
iso_epoch() { date -d "$1" +%s; }

# --------------------------------------------------------------------------
# Source-time contract — the new functions are defined, sourcing is inert.
# --------------------------------------------------------------------------
@test "sourcing defines the weekly-glide functions and is side-effect-free" {
  run bash -c "set -euo pipefail; source '$LIB'; \
    for f in arl_token_glide_enabled arl_token_glide_reserve arl_token_glide_floor \
             arl_token_glide_ceiling arl_token_days_until_reset arl_token_glide_threshold \
             arl_token_iso_to_epoch arl_token_extract_resets_at arl_token_weekly_glide_gate \
             arl_token_glide_trip_reason; do \
      declare -F \"\$f\" >/dev/null || { echo \"missing \$f\"; exit 1; }; done; echo ok"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

# --------------------------------------------------------------------------
# Config accessors (AC #1) — every glide value read from config, never hardcoded.
# --------------------------------------------------------------------------
@test "glide config accessors read reserve/floor/ceiling/enabled from config" {
  write_glide_config true 2 86 100 90
  run bash -c "source '$LIB'; arl_token_glide_reserve"
  [ "$output" = "2" ]
  run bash -c "source '$LIB'; arl_token_glide_floor"
  [ "$output" = "86" ]
  run bash -c "source '$LIB'; arl_token_glide_ceiling"
  [ "$output" = "100" ]
  run bash -c "source '$LIB'; arl_token_glide_enabled"
  [ "$output" = "true" ]
}

@test "glide accessors honor non-default configured values (not hardcoded)" {
  write_glide_config false 3 80 99 90
  run bash -c "source '$LIB'; arl_token_glide_reserve"
  [ "$output" = "3" ]
  run bash -c "source '$LIB'; arl_token_glide_floor"
  [ "$output" = "80" ]
  run bash -c "source '$LIB'; arl_token_glide_ceiling"
  [ "$output" = "99" ]
  run bash -c "source '$LIB'; arl_token_glide_enabled"
  [ "$output" = "false" ]
}

@test "arl_token_glide_enabled defaults to false when the key is absent" {
  export AGENT_RATE_LIMITS_CONFIG="$TMP/agent-rate-limits.json"
  jq -n '{org_wide:{token_budget:{limits:{weekly_all:{kind:"weekly_all",pause_worthy:true}}}}}' >"$AGENT_RATE_LIMITS_CONFIG"
  run bash -c "source '$LIB'; arl_token_glide_enabled"
  [ "$output" = "false" ]
}

# --------------------------------------------------------------------------
# days_until_reset — round-up semantics (AC #2). PURE: <reset_epoch> <now_epoch>.
# --------------------------------------------------------------------------
@test "days_until_reset is 0 at the reset instant and after it has passed" {
  run bash -c "source '$LIB'; arl_token_days_until_reset 1000000 1000000"
  [ "$output" = "0" ]
  run bash -c "source '$LIB'; arl_token_days_until_reset 1000000 1000001"
  [ "$output" = "0" ]
}

@test "days_until_reset is exactly N for N whole days remaining (0..7)" {
  local reset=1000000000
  for n in 0 1 2 3 4 5 6 7; do
    local now=$(( reset - n * 86400 ))
    run bash -c "source '$LIB'; arl_token_days_until_reset $reset $now"
    [ "$output" = "$n" ]
  done
}

@test "days_until_reset rounds a PARTIAL day UP (12h left => 1 day, not 0)" {
  local reset=1000000000
  local now=$(( reset - 43200 ))   # 12 hours before reset
  run bash -c "source '$LIB'; arl_token_days_until_reset $reset $now"
  [ "$output" = "1" ]
}

@test "days_until_reset rounds up just over a whole day to the next day" {
  local reset=1000000000
  local now=$(( reset - 86401 ))   # 24h + 1s before reset
  run bash -c "source '$LIB'; arl_token_days_until_reset $reset $now"
  [ "$output" = "2" ]
}

# --------------------------------------------------------------------------
# glide_threshold — pure clamp core (AC #1). <days> <reserve> <floor> <ceiling>.
# --------------------------------------------------------------------------
@test "glide_threshold matches the issue schedule at each day-offset 0..7" {
  local -a expected=(100 98 96 94 92 90 88 86)
  for n in 0 1 2 3 4 5 6 7; do
    run bash -c "source '$LIB'; arl_token_glide_threshold $n 2 86 100"
    [ "$output" = "${expected[$n]}" ]
  done
}

@test "glide_threshold clamps to floor beyond the schedule (days=8 => floor 86)" {
  run bash -c "source '$LIB'; arl_token_glide_threshold 8 2 86 100"
  [ "$output" = "86" ]
  run bash -c "source '$LIB'; arl_token_glide_threshold 100 2 86 100"
  [ "$output" = "86" ]
}

@test "glide_threshold clamps to ceiling on reset day (days=0 => ceiling)" {
  run bash -c "source '$LIB'; arl_token_glide_threshold 0 2 86 95"
  [ "$output" = "95" ]
}

@test "glide_threshold honors a non-default reserve slope (config-driven)" {
  # reserve=3: day 2 => 100 - 6 = 94
  run bash -c "source '$LIB'; arl_token_glide_threshold 2 3 80 100"
  [ "$output" = "94" ]
}

# --------------------------------------------------------------------------
# ISO parsing + resets_at extraction adapters.
# --------------------------------------------------------------------------
@test "arl_token_iso_to_epoch parses an ISO-8601 timestamp" {
  local want; want="$(iso_epoch '2026-09-08T15:00:00Z')"
  run bash -c "source '$LIB'; arl_token_iso_to_epoch '2026-09-08T15:00:00Z'"
  [ "$output" = "$want" ]
}

@test "arl_token_iso_to_epoch echoes empty for a malformed timestamp" {
  run bash -c "source '$LIB'; arl_token_iso_to_epoch 'not a date'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "arl_token_iso_to_epoch echoes empty for a timezone-less timestamp (rejects local-time ambiguity)" {
  run bash -c "source '$LIB'; arl_token_iso_to_epoch '2026-09-08T15:00:00'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "arl_token_iso_to_epoch echoes empty for an invalid calendar date (e.g. Feb 30) that date -d would normalise" {
  run bash -c "source '$LIB'; arl_token_iso_to_epoch '2026-02-30T00:00:00Z'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "arl_token_iso_to_epoch accepts a +HH:MM offset timestamp" {
  local want; want="$(date -d '2026-09-08T17:00:00+02:00' +%s 2>/dev/null || printf '')"
  [ -z "$want" ] && skip "date -d does not support +HH:MM on this platform"
  run bash -c "source '$LIB'; arl_token_iso_to_epoch '2026-09-08T17:00:00+02:00'"
  [ "$output" = "$want" ]
}

@test "arl_token_extract_resets_at reads the weekly_all limits[] entry" {
  body='{"limits":[{"kind":"weekly_all","percent":40,"resets_at":"2026-09-02T15:59:59Z"}]}'
  run bash -c "source '$LIB'; arl_token_extract_resets_at '$body' weekly_all"
  [ "$output" = "2026-09-02T15:59:59Z" ]
}

@test "arl_token_extract_resets_at falls back to the flattened seven_day key" {
  body='{"seven_day":{"percent":40,"resets_at":"2026-09-02T15:59:59Z"}}'
  run bash -c "source '$LIB'; arl_token_extract_resets_at '$body' weekly_all"
  [ "$output" = "2026-09-02T15:59:59Z" ]
}

@test "arl_token_extract_resets_at echoes empty when absent" {
  body='{"limits":[{"kind":"weekly_all","percent":40}]}'
  run bash -c "source '$LIB'; arl_token_extract_resets_at '$body' weekly_all"
  [ -z "$output" ]
}

# --------------------------------------------------------------------------
# Orchestrator arl_token_weekly_glide_gate — boundaries (AC #1/#2)
# --------------------------------------------------------------------------
@test "gate: weekly percent exactly at the glide threshold defers (>= boundary)" {
  write_glide_config
  local reset_iso="2026-09-08T15:00:00Z" reset now
  reset="$(iso_epoch "$reset_iso")"; now=$(( reset - 4 * 86400 ))   # 4 days => threshold 92
  export SOURCE_NOW="$now"
  write_telemetry "$(envelope_weekly 92 "$reset_iso")"
  run bash -c "source '$LIB'; arl_token_weekly_glide_gate"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

@test "gate: one point under the glide threshold allows (boundary)" {
  write_glide_config
  local reset_iso="2026-09-08T15:00:00Z" reset now
  reset="$(iso_epoch "$reset_iso")"; now=$(( reset - 4 * 86400 ))   # 4 days => threshold 92
  export SOURCE_NOW="$now"
  write_telemetry "$(envelope_weekly 91 "$reset_iso")"
  run bash -c "source '$LIB'; arl_token_weekly_glide_gate"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: 86% with 7 days left (just reset) defers at the floor" {
  write_glide_config
  local reset_iso="2026-09-08T15:00:00Z" reset now
  reset="$(iso_epoch "$reset_iso")"; now=$(( reset - 7 * 86400 ))   # 7 days => threshold 86
  export SOURCE_NOW="$now"
  write_telemetry "$(envelope_weekly 86 "$reset_iso")"
  run bash -c "source '$LIB'; arl_token_weekly_glide_gate"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

@test "gate: 85% with 5 days left defers (the 2026-08-20 motivating probe)" {
  # Thursday: 5 days left => threshold 90. 85% is UNDER 90 so it does NOT trip;
  # the story's motivating observation was one point under. Assert the near-miss.
  write_glide_config
  local reset_iso="2026-09-08T15:00:00Z" reset now
  reset="$(iso_epoch "$reset_iso")"; now=$(( reset - 5 * 86400 ))   # 5 days => threshold 90
  export SOURCE_NOW="$now"
  write_telemetry "$(envelope_weekly 85 "$reset_iso")"
  run bash -c "source '$LIB'; arl_token_weekly_glide_gate"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: partial-day rounding tightens the threshold (12h left => 1 day => 98)" {
  write_glide_config
  local reset_iso="2026-09-08T15:00:00Z" reset now
  reset="$(iso_epoch "$reset_iso")"; now=$(( reset - 43200 ))   # 12h => rounds up to 1 day => 98
  export SOURCE_NOW="$now"
  # 97 is under 98 -> allow; if rounding were DOWN to 0 the threshold would be 100
  # and 97 would still allow, so also assert 98 trips below.
  write_telemetry "$(envelope_weekly 97 "$reset_iso")"
  run bash -c "source '$LIB'; arl_token_weekly_glide_gate"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
  write_telemetry "$(envelope_weekly 98 "$reset_iso")"
  run bash -c "source '$LIB'; arl_token_weekly_glide_gate"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

# --------------------------------------------------------------------------
# The differentiator (post-ADR #3): the breaker CLOSES before resets_at because
# the RISING threshold passed a static (monotonic) percent — never because usage
# fell. Same observed percent, two day-offsets, opposite decisions.
# --------------------------------------------------------------------------
@test "gate: a fixed percent trips farther from reset and closes nearer to it (threshold rose, not usage fell)" {
  write_glide_config
  local reset_iso="2026-09-08T15:00:00Z" reset
  reset="$(iso_epoch "$reset_iso")"

  # 5 days left => threshold 90. Observed 91% (monotonic) -> trips.
  export SOURCE_NOW=$(( reset - 5 * 86400 ))
  write_telemetry "$(envelope_weekly 91 "$reset_iso")"
  run bash -c "source '$LIB'; arl_token_weekly_glide_gate"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]

  # 4 days left => threshold 92. The SAME 91% is now under the risen threshold ->
  # closes. Utilization did not fall; the threshold moved past it.
  export SOURCE_NOW=$(( reset - 4 * 86400 ))
  write_telemetry "$(envelope_weekly 91 "$reset_iso")"
  run bash -c "source '$LIB'; arl_token_weekly_glide_gate"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

# --------------------------------------------------------------------------
# Scope guard (AC #3) — weekly_scoped must never trip a fleet pause.
# --------------------------------------------------------------------------
@test "gate: a weekly_scoped limit at critical/100% does NOT trip when weekly_all is under threshold" {
  write_glide_config
  local reset_iso="2026-09-08T15:00:00Z" reset now
  reset="$(iso_epoch "$reset_iso")"; now=$(( reset - 5 * 86400 ))   # threshold 90
  export SOURCE_NOW="$now"
  # weekly_all at 40 (well under 90); weekly_scoped at 100 critical is_active.
  write_telemetry "$(envelope_weekly 40 "$reset_iso")"
  run bash -c "source '$LIB'; arl_token_weekly_glide_gate"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: weekly_scoped window itself is never pause-worthy (scope guard)" {
  write_glide_config
  run bash -c "source '$LIB'; arl_token_window_pause_worthy weekly_scoped"
  [ "$output" = "false" ]
}

# --------------------------------------------------------------------------
# Config-level inert arm (AC #6/#7)
# --------------------------------------------------------------------------
@test "gate: config enabled=false keeps the glide breaker inert (allow) even over threshold" {
  write_glide_config false
  local reset_iso="2026-09-08T15:00:00Z" reset now
  reset="$(iso_epoch "$reset_iso")"; now=$(( reset - 5 * 86400 ))
  export SOURCE_NOW="$now"
  write_telemetry "$(envelope_weekly 99 "$reset_iso")"
  run bash -c "source '$LIB'; arl_token_weekly_glide_gate"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

# --------------------------------------------------------------------------
# Fail-safe degradation (AC #5)
# --------------------------------------------------------------------------
@test "gate: a fresh 429 with a future deadline BLOCKS (hard cap signal)" {
  write_glide_config
  local future_deadline; future_deadline=$(( $(date +%s) + 300 ))
  write_telemetry "{\"status\":429,\"retry_after\":120,\"retry_until\":${future_deadline}}"
  run bash -c "source '$LIB'; arl_token_weekly_glide_gate"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
  [[ "$output" == *"429"* ]]
}

@test "gate: a non-200 telemetry status fails safe to allow-with-warning" {
  write_glide_config
  write_telemetry '{"status":503}'
  run bash -c "source '$LIB'; arl_token_weekly_glide_gate"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: an unavailable telemetry source (status 0) fails safe to allow" {
  write_glide_config
  write_telemetry '{"status":0}'
  run bash -c "source '$LIB'; arl_token_weekly_glide_gate"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: no telemetry source configured fails safe to allow (degraded, AC #6)" {
  write_glide_config
  run bash -c "unset AGENT_TOKEN_BUDGET_TELEMETRY_FILE AGENT_TOKEN_BUDGET_TELEMETRY_CMD; source '$LIB'; arl_token_weekly_glide_gate"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: a missing weekly_all entry in an otherwise-200 body fails safe to allow" {
  write_glide_config
  write_telemetry '{"status":200,"body":{"limits":[{"kind":"session","percent":50}]}}'
  run bash -c "source '$LIB'; arl_token_weekly_glide_gate"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: a weekly_all entry with no resets_at fails safe to allow (cannot compute days)" {
  write_glide_config
  write_telemetry '{"status":200,"body":{"limits":[{"kind":"weekly_all","percent":99,"is_active":true}]}}'
  run bash -c "source '$LIB'; arl_token_weekly_glide_gate"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: weekly_all flagged is_active=false does not defer even over threshold" {
  write_glide_config
  local reset_iso="2026-09-08T15:00:00Z" reset now
  reset="$(iso_epoch "$reset_iso")"; now=$(( reset - 5 * 86400 ))
  export SOURCE_NOW="$now"
  write_telemetry "$(jq -nc --arg r "$reset_iso" '{status:200,body:{limits:[{kind:"weekly_all",percent:99,resets_at:$r,is_active:false}]}}')"
  run bash -c "source '$LIB'; arl_token_weekly_glide_gate"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: is set -euo pipefail-safe on the defer path" {
  write_glide_config
  local reset_iso="2026-09-08T15:00:00Z" reset now
  reset="$(iso_epoch "$reset_iso")"; now=$(( reset - 4 * 86400 ))
  export SOURCE_NOW="$now"
  write_telemetry "$(envelope_weekly 99 "$reset_iso")"
  run bash -c "set -euo pipefail; source '$LIB'; arl_token_weekly_glide_gate"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

# --------------------------------------------------------------------------
# Machine-readable trip reason (AC #4)
# --------------------------------------------------------------------------
@test "arl_token_glide_trip_reason emits structured JSON with window/percent/threshold/days/resets_at" {
  run bash -c "source '$LIB'; arl_token_glide_trip_reason 95 92 4 '2026-09-08T15:00:00Z'"
  [ "$status" -eq 0 ]
  run bash -c "source '$LIB'; arl_token_glide_trip_reason 95 92 4 '2026-09-08T15:00:00Z' | jq -er '.window'"
  [ "$output" = "weekly_all" ]
  run bash -c "source '$LIB'; arl_token_glide_trip_reason 95 92 4 '2026-09-08T15:00:00Z' | jq -er '.observed_percent'"
  [ "$output" = "95" ]
  run bash -c "source '$LIB'; arl_token_glide_trip_reason 95 92 4 '2026-09-08T15:00:00Z' | jq -er '.threshold_pct'"
  [ "$output" = "92" ]
  run bash -c "source '$LIB'; arl_token_glide_trip_reason 95 92 4 '2026-09-08T15:00:00Z' | jq -er '.days_until_reset'"
  [ "$output" = "4" ]
  run bash -c "source '$LIB'; arl_token_glide_trip_reason 95 92 4 '2026-09-08T15:00:00Z' | jq -er '.resets_at'"
  [ "$output" = "2026-09-08T15:00:00Z" ]
}

@test "gate: a defer logs the machine-readable trip reason (AC #4)" {
  write_glide_config
  local reset_iso="2026-09-08T15:00:00Z" reset now
  reset="$(iso_epoch "$reset_iso")"; now=$(( reset - 4 * 86400 ))
  export SOURCE_NOW="$now"
  write_telemetry "$(envelope_weekly 95 "$reset_iso")"
  run bash -c "source '$LIB'; arl_token_weekly_glide_gate" 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"weekly_all"* ]]
  [[ "$output" == *"threshold_pct"* ]]
  [[ "$output" == *"resets_at"* ]]
}

# --------------------------------------------------------------------------
# Human-clearable marker / label surfacing (AC #4) — reuse the shared idiom.
# --------------------------------------------------------------------------
@test "the weekly-glide breaker reuses the shared window marker + human-clearable label" {
  run bash -c "source '$LIB'; arl_token_breaker_marker weekly_all"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<!--"* ]]
  [[ "$output" == *"weekly_all"* ]]
  [[ "$output" == *"-->"* ]]
  run bash -c "source '$LIB'; arl_breaker_label"
  [ "$output" = "needs-human-review" ]
}

# --------------------------------------------------------------------------
# Integration into arl_admission_gate (AC #4/#6/#7) — INERT behind the flag.
# --------------------------------------------------------------------------
@test "admission gate: weekly-glide is INERT when AGENT_TOKEN_BUDGET_ENABLED is unset" {
  write_glide_config
  local reset_iso="2026-09-08T15:00:00Z" reset now
  reset="$(iso_epoch "$reset_iso")"; now=$(( reset - 4 * 86400 ))
  export SOURCE_NOW="$now"
  write_telemetry "$(envelope_weekly 99 "$reset_iso")"
  export AGENT_RATE_LIMITS_STATE="$TMP/state.json"
  printf '%s' '{"dev-lead":{"last_run_epoch":0,"daily_count":0,"consecutive_failures":0,"breaker_opened_epoch":0}}' >"$AGENT_RATE_LIMITS_STATE"
  export GH_STUB_STDOUT='[{"status":"in_progress"}]'
  run bash -c "source '$LIB'; arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "admission gate: defers when the weekly glide is armed (env + config) and tripped" {
  write_glide_config
  local reset_iso="2026-09-08T15:00:00Z" reset now
  reset="$(iso_epoch "$reset_iso")"; now=$(( reset - 4 * 86400 ))
  export SOURCE_NOW="$now"
  write_telemetry "$(envelope_weekly 99 "$reset_iso")"
  export AGENT_RATE_LIMITS_STATE="$TMP/state.json"
  printf '%s' '{"dev-lead":{"last_run_epoch":0,"daily_count":0,"consecutive_failures":0,"breaker_opened_epoch":0}}' >"$AGENT_RATE_LIMITS_STATE"
  export GH_STUB_STDOUT='[{"status":"in_progress"}]'
  run bash -c "source '$LIB'; AGENT_TOKEN_BUDGET_ENABLED=true arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
  [[ "$output" == *"token"* ]]
}

@test "admission gate: config enabled=false keeps the glide inert even with the env flag on" {
  write_glide_config false
  local reset_iso="2026-09-08T15:00:00Z" reset now
  reset="$(iso_epoch "$reset_iso")"; now=$(( reset - 4 * 86400 ))
  export SOURCE_NOW="$now"
  write_telemetry "$(envelope_weekly 99 "$reset_iso")"
  export AGENT_RATE_LIMITS_STATE="$TMP/state.json"
  printf '%s' '{"dev-lead":{"last_run_epoch":0,"daily_count":0,"consecutive_failures":0,"breaker_opened_epoch":0}}' >"$AGENT_RATE_LIMITS_STATE"
  export GH_STUB_STDOUT='[{"status":"in_progress"}]'
  run bash -c "source '$LIB'; AGENT_TOKEN_BUDGET_ENABLED=true arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "admission gate: an exempt actor is allowed even when the weekly glide is tripped" {
  write_glide_config
  local reset_iso="2026-09-08T15:00:00Z" reset now
  reset="$(iso_epoch "$reset_iso")"; now=$(( reset - 4 * 86400 ))
  export SOURCE_NOW="$now"
  write_telemetry "$(envelope_weekly 99 "$reset_iso")"
  run bash -c "source '$LIB'; AGENT_TOKEN_BUDGET_ENABLED=true arl_admission_gate dev-lead 'dependabot[bot]'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
  [[ "$output" == *"exempt"* ]]
}

@test "admission gate: weekly-glide defer emits the escalation marker to stderr" {
  write_glide_config
  local reset_iso="2026-09-08T15:00:00Z" reset now
  reset="$(iso_epoch "$reset_iso")"; now=$(( reset - 4 * 86400 ))
  export SOURCE_NOW="$now"
  write_telemetry "$(envelope_weekly 99 "$reset_iso")"
  export AGENT_RATE_LIMITS_STATE="$TMP/state.json"
  printf '%s' '{"dev-lead":{"last_run_epoch":0,"daily_count":0,"consecutive_failures":0,"breaker_opened_epoch":0}}' >"$AGENT_RATE_LIMITS_STATE"
  export GH_STUB_STDOUT='[{"status":"in_progress"}]'
  run bash -c "source '$LIB'; AGENT_TOKEN_BUDGET_ENABLED=true arl_admission_gate dev-lead donpetry-bot" 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"<!--"* ]]
  [[ "$output" == *"weekly_all"* ]]
}

@test "admission gate: DRY_RUN prints the would-be weekly-glide defer but returns allow" {
  write_glide_config
  local reset_iso="2026-09-08T15:00:00Z" reset now
  reset="$(iso_epoch "$reset_iso")"; now=$(( reset - 4 * 86400 ))
  export SOURCE_NOW="$now"
  write_telemetry "$(envelope_weekly 99 "$reset_iso")"
  export AGENT_RATE_LIMITS_STATE="$TMP/state.json"
  printf '%s' '{"dev-lead":{"last_run_epoch":0,"daily_count":0,"consecutive_failures":0,"breaker_opened_epoch":0}}' >"$AGENT_RATE_LIMITS_STATE"
  export GH_STUB_STDOUT='[{"status":"in_progress"}]'
  run bash -c "source '$LIB'; AGENT_TOKEN_BUDGET_ENABLED=true DRY_RUN=true arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"defer"* ]]
  [[ "$output" == *"decision=allow"* ]]
}

@test "admission gate: weekly-glide defer path issues no mutating gh call (guard-only)" {
  write_glide_config
  local reset_iso="2026-09-08T15:00:00Z" reset now
  reset="$(iso_epoch "$reset_iso")"; now=$(( reset - 4 * 86400 ))
  export SOURCE_NOW="$now"
  write_telemetry "$(envelope_weekly 99 "$reset_iso")"
  export AGENT_RATE_LIMITS_STATE="$TMP/state.json"
  printf '%s' '{"dev-lead":{"last_run_epoch":0,"daily_count":0,"consecutive_failures":0,"breaker_opened_epoch":0}}' >"$AGENT_RATE_LIMITS_STATE"
  export GH_STUB_STDOUT='[{"status":"in_progress"}]'
  run bash -c "set -euo pipefail; source '$LIB'; AGENT_TOKEN_BUDGET_ENABLED=true arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 1 ]
  run grep -qE 'run cancel|pr create|pr edit|issue edit|label|api -X (POST|PATCH|PUT|DELETE)' "$GH_STUB_LOG"
  [ "$status" -eq 1 ]
}

# --------------------------------------------------------------------------
# Single telemetry fetch: admission gate must call arl_token_fetch_envelope
# exactly once when both token-budget and weekly-glide breakers are armed.
# --------------------------------------------------------------------------
@test "admission gate: telemetry is fetched exactly once when both breakers are armed" {
  write_glide_config
  local reset_iso="2026-09-08T15:00:00Z" reset now
  reset="$(iso_epoch "$reset_iso")"; now=$(( reset - 4 * 86400 ))
  export SOURCE_NOW="$now"
  local fetch_log="$TMP/fetch_calls.log"
  # Use TELEMETRY_CMD that appends to a log on every invocation.
  local telemetry_json; telemetry_json="$(envelope_weekly 10 "$reset_iso")"
  export AGENT_TOKEN_BUDGET_TELEMETRY_CMD="printf '%s' '${telemetry_json}'; printf 'fetched\n' >>'${fetch_log}'"
  export AGENT_RATE_LIMITS_STATE="$TMP/state.json"
  printf '%s' '{"dev-lead":{"last_run_epoch":0,"daily_count":0,"consecutive_failures":0,"breaker_opened_epoch":0}}' >"$AGENT_RATE_LIMITS_STATE"
  export GH_STUB_STDOUT='[{"status":"in_progress"}]'
  run bash -c "source '$LIB'; AGENT_TOKEN_BUDGET_ENABLED=true arl_admission_gate dev-lead donpetry-bot"
  local fetch_count; fetch_count="$(wc -l < "$fetch_log" 2>/dev/null || printf '0')"
  [ "$fetch_count" -eq 1 ]
}
