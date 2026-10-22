#!/usr/bin/env bats
# Tests for scripts/lib/agent-rate-limit.sh — the source-side agent admission +
# consecutive-failure circuit-breaker gate that, before an agent-creating
# workflow dispatches a run, decides allow / defer for a given agent type by
# evaluating concurrency / cooldown / daily-budget against the caps in
# standards/agent-rate-limits.json, plus a consecutive-failure breaker
# (open -> backoff -> half-open probe) (#639, Phase 3 of epic #636).
#
# Context (ADR docs/initiatives/agent-rate-limits-adr.md, #637): GitHub exposes
# no native per-workflow rate limiter (ADR §2/§4), so the limits are enforced at
# the agent-creating source. This guard is the reusable library; wiring it into
# the live dispatch path is Phases 4-5. The guard reads its thresholds + exempt
# list from standards/agent-rate-limits.json (#638), never hardcoded.
#
# Design: the decision core is a set of PURE functions that compute from injected
# counts / timestamps / state, so bats unit-tests every branch with no live API.
# The only impure surface (`gh run list`, label/marker escalation) is stubbed via
# the env-driven fake under test/scripts/compliance-remediate/stubs/gh, and the
# gh invocation log is asserted to prove the guard never issues a mutating call.

bats_require_minimum_version 1.5.0

LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts/lib/agent-rate-limit.sh"
GH_STUB_SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/test/scripts/compliance-remediate/stubs/gh"

setup() {
  TMP="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  export TMP

  # Put the env-driven gh stub on PATH and log every invocation so we can assert
  # the gate never issues a mutating gh subcommand.
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

# Write an agent-rate-limits config for a single agent type with the given
# thresholds, and export AGENT_RATE_LIMITS_CONFIG pointing at it.
write_config() {
  local agent="$1" max="$2" cooldown="$3" daily="$4" cb_threshold="$5" cb_backoff="$6"
  export AGENT_RATE_LIMITS_CONFIG="$TMP/agent-rate-limits.json"
  jq -n \
    --arg agent "$agent" \
    --argjson max "$max" \
    --argjson cooldown "$cooldown" \
    --argjson daily "$daily" \
    --argjson cb_threshold "$cb_threshold" \
    --argjson cb_backoff "$cb_backoff" \
    '{
      status: "provisional",
      _schema_version: 1,
      agent_types: {
        ($agent): {
          max_concurrent_runs: $max,
          max_runtime_minutes: 30,
          cooldown_minutes: $cooldown,
          daily_run_budget: $daily,
          circuit_breaker: {
            consecutive_failure_threshold: $cb_threshold,
            backoff_minutes: $cb_backoff
          }
        }
      },
      org_wide: {},
      exempt_actors: ["dependabot[bot]", "@petry-projects/org-leads"],
      exempt_labels: ["security"]
    }' >"$AGENT_RATE_LIMITS_CONFIG"
}

# Write a state document and export AGENT_RATE_LIMITS_STATE pointing at it.
write_state() {
  export AGENT_RATE_LIMITS_STATE="$TMP/state.json"
  printf '%s' "$1" >"$AGENT_RATE_LIMITS_STATE"
}

# Make the gh stub return a `gh run list` payload of N in-progress runs.
stub_concurrent_runs() {
  local count="$1"
  export GH_STUB_STDOUT
  GH_STUB_STDOUT="$(jq -nc --argjson n "$count" \
    '[range(0; $n) | { status: "in_progress" }]')"
}

# --------------------------------------------------------------------------
# Source-time contract (AC #1) — sourcing runs nothing and defines arl_*.
# --------------------------------------------------------------------------
@test "sourcing the library is side-effect-free and set -euo pipefail-safe" {
  run bash -c "set -euo pipefail; source '$LIB'; declare -F arl_admission_gate >/dev/null && echo ok"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "arl_config_path honors the AGENT_RATE_LIMITS_CONFIG override (AC #1)" {
  write_config "dev-lead" 3 5 50 3 30
  run bash -c "source '$LIB'; arl_config_path"
  [ "$status" -eq 0 ]
  [ "$output" = "$AGENT_RATE_LIMITS_CONFIG" ]
}

@test "arl_config_path default resolves relative to the library (AC #1)" {
  run bash -c "unset AGENT_RATE_LIMITS_CONFIG; source '$LIB'; arl_config_path"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/standards/agent-rate-limits.json" ]]
}

# --------------------------------------------------------------------------
# arl_sanitize_int — the fail-safe integer idiom (AC #4)
# --------------------------------------------------------------------------
@test "arl_sanitize_int passes through a valid non-negative integer" {
  run bash -c "source '$LIB'; arl_sanitize_int 7"
  [ "$status" -eq 0 ]
  [ "$output" = "7" ]
}

@test "arl_sanitize_int degrades malformed input to the default (0)" {
  run bash -c "source '$LIB'; arl_sanitize_int 'not-a-number'"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "arl_sanitize_int honors an explicit default for empty input" {
  run bash -c "source '$LIB'; arl_sanitize_int '' 5"
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]
}

# --------------------------------------------------------------------------
# arl_is_exempt_actor (AC #2) — reads the exempt list from the config
# --------------------------------------------------------------------------
@test "arl_is_exempt_actor is true for a configured exempt actor" {
  write_config "dev-lead" 3 5 50 3 30
  run bash -c "source '$LIB'; arl_is_exempt_actor 'dependabot[bot]'"
  [ "$status" -eq 0 ]
}

@test "arl_is_exempt_actor is false for a non-exempt actor" {
  write_config "dev-lead" 3 5 50 3 30
  run bash -c "source '$LIB'; arl_is_exempt_actor 'donpetry-bot'"
  [ "$status" -eq 1 ]
}

# --------------------------------------------------------------------------
# arl_admission_decision (AC #2) — pure concurrency / cooldown / daily checks
# Signature: <agent_type> <concurrent> <last_run_epoch> <daily_count> <now_epoch>
# --------------------------------------------------------------------------
@test "admission: under every limit returns allow" {
  write_config "dev-lead" 3 5 50 3 30
  # concurrent 1/3, last run 10 min ago (> 5 min cooldown), daily 4/50
  run bash -c "source '$LIB'; arl_admission_decision dev-lead 1 1000 4 1600"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "admission: at the concurrency cap returns defer" {
  write_config "dev-lead" 3 5 50 3 30
  run bash -c "source '$LIB'; arl_admission_decision dev-lead 3 1000 4 100000"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
  [[ "$output" == *"concurren"* ]]
}

@test "admission: at the daily budget returns defer" {
  write_config "dev-lead" 3 5 50 3 30
  run bash -c "source '$LIB'; arl_admission_decision dev-lead 0 1000 50 100000"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
  [[ "$output" == *"daily"* ]]
}

@test "admission: within the cooldown window returns defer" {
  write_config "dev-lead" 3 5 50 3 30
  # cooldown 5 min = 300s; only 299s since last run -> defer
  run bash -c "source '$LIB'; arl_admission_decision dev-lead 0 1000 4 1299"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
  [[ "$output" == *"cooldown"* ]]
}

@test "admission: exactly at the cooldown boundary returns allow" {
  write_config "dev-lead" 3 5 50 3 30
  # 300s elapsed == cooldown -> the quiet interval has passed -> allow
  run bash -c "source '$LIB'; arl_admission_decision dev-lead 0 1000 4 1300"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "admission: cooldown is skipped when there is no recorded last run" {
  write_config "dev-lead" 3 5 50 3 30
  # last_run_epoch 0 => never run => cooldown does not apply => allow
  run bash -c "source '$LIB'; arl_admission_decision dev-lead 0 0 0 1300"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "admission: a zero threshold disables that check (weekly-cron cooldown=0)" {
  # compliance-audit style: cooldown 0 must never defer on cooldown grounds.
  write_config "compliance-audit" 1 0 1 3 60
  run bash -c "source '$LIB'; arl_admission_decision compliance-audit 0 1599 0 1600"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

# --------------------------------------------------------------------------
# arl_admission_decision degradation (AC #4) — malformed count allows
# --------------------------------------------------------------------------
@test "admission: a malformed concurrent count degrades to allow" {
  write_config "dev-lead" 3 5 50 3 30
  run bash -c "source '$LIB'; arl_admission_decision dev-lead 'garbage' 0 0 100000"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

# --------------------------------------------------------------------------
# arl_breaker_decision (AC #3) — consecutive-failure open/half-open transitions
# Signature: <agent_type> <consecutive_failures> <opened_epoch> <now_epoch>
# --------------------------------------------------------------------------
@test "breaker: below the failure threshold is closed and allows" {
  write_config "dev-lead" 3 5 50 3 30
  run bash -c "source '$LIB'; arl_breaker_decision dev-lead 2 0 100000"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
  [[ "$output" == *"closed"* ]]
}

@test "breaker: at the threshold with no opened timestamp opens and defers" {
  write_config "dev-lead" 3 5 50 3 30
  run bash -c "source '$LIB'; arl_breaker_decision dev-lead 3 0 100000"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
  [[ "$output" == *"open"* ]]
}

@test "breaker: within the backoff window stays open and defers" {
  write_config "dev-lead" 3 5 50 3 30
  # backoff 30 min = 1800s; opened at 100000, now 100000+1799 -> still open
  run bash -c "source '$LIB'; arl_breaker_decision dev-lead 5 100000 101799"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
  [[ "$output" == *"open"* ]]
}

@test "breaker: after the backoff expires goes half-open and allows a probe" {
  write_config "dev-lead" 3 5 50 3 30
  # 1800s elapsed == backoff -> half-open probe -> allow
  run bash -c "source '$LIB'; arl_breaker_decision dev-lead 5 100000 101800"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
  [[ "$output" == *"half-open"* ]]
}

@test "breaker: a malformed failure count degrades to allow (AC #4)" {
  write_config "dev-lead" 3 5 50 3 30
  run bash -c "source '$LIB'; arl_breaker_decision dev-lead 'NaN' 100000 101799"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "breaker: a malformed / missing breaker config allows (never blocks)" {
  # Config with no circuit_breaker block at all -> cannot evaluate -> allow.
  export AGENT_RATE_LIMITS_CONFIG="$TMP/agent-rate-limits.json"
  jq -n '{ status: "provisional", agent_types: { "dev-lead": { max_concurrent_runs: 3 } }, exempt_actors: [], exempt_labels: [] }' \
    >"$AGENT_RATE_LIMITS_CONFIG"
  run bash -c "source '$LIB'; arl_breaker_decision dev-lead 9 100000 100001"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

# --------------------------------------------------------------------------
# Deduped, human-clearable open-breaker marker (AC #3)
# --------------------------------------------------------------------------
@test "arl_breaker_marker embeds the agent type in a stable HTML marker" {
  run bash -c "source '$LIB'; arl_breaker_marker dev-lead"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<!--"* ]]
  [[ "$output" == *"dev-lead"* ]]
  [[ "$output" == *"-->"* ]]
}

@test "arl_should_escalate is true when the marker is absent from the body" {
  run bash -c "source '$LIB'; arl_should_escalate 'no marker here' dev-lead"
  [ "$status" -eq 0 ]
}

@test "arl_should_escalate is false (deduped) when the marker is already present" {
  run bash -c "source '$LIB'; marker=\"\$(arl_breaker_marker dev-lead)\"; arl_should_escalate \"prior comment \$marker\" dev-lead"
  [ "$status" -eq 1 ]
}

@test "arl_breaker_label exposes the human-clearable label" {
  run bash -c "source '$LIB'; arl_breaker_label"
  [ "$status" -eq 0 ]
  [ "$output" = "needs-human-review" ]
}

# --------------------------------------------------------------------------
# arl_admission_gate (AC #2/#3) — top-level entrypoint end-to-end
# --------------------------------------------------------------------------
@test "gate: requires an agent-type argument" {
  write_config "dev-lead" 3 5 50 3 30
  run bash -c "source '$LIB'; arl_admission_gate"
  [ "$status" -eq 2 ]
}

@test "gate: under limits with a clean breaker returns allow" {
  write_config "dev-lead" 3 5 50 3 30
  write_state '{"dev-lead":{"last_run_epoch":0,"daily_count":1,"consecutive_failures":0,"breaker_opened_epoch":0}}'
  stub_concurrent_runs 1
  run bash -c "source '$LIB'; arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: an exempt actor is allowed even over every limit and never counted" {
  write_config "dev-lead" 1 5 1 1 30
  write_state '{"dev-lead":{"last_run_epoch":0,"daily_count":999,"consecutive_failures":99,"breaker_opened_epoch":0}}'
  stub_concurrent_runs 50
  run bash -c "source '$LIB'; arl_admission_gate dev-lead 'dependabot[bot]'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
  [[ "$output" == *"exempt"* ]]
}

@test "gate: an open breaker (within backoff) defers before any admission check" {
  write_config "dev-lead" 3 5 50 3 30
  # opened at SOURCE_NOW, 5 >= threshold 3, elapsed 0 < 1800s backoff -> open.
  write_state '{"dev-lead":{"last_run_epoch":0,"daily_count":0,"consecutive_failures":5,"breaker_opened_epoch":100000}}'
  stub_concurrent_runs 0
  run bash -c "source '$LIB'; SOURCE_NOW=100000 arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

@test "gate: is set -euo pipefail-safe on the open-breaker defer path" {
  # A caller sourcing the lib under `set -e` must still get the emitted decision
  # and a clean defer return, not an abort at the internal command substitution.
  write_config "dev-lead" 3 5 50 3 30
  write_state '{"dev-lead":{"last_run_epoch":0,"daily_count":0,"consecutive_failures":5,"breaker_opened_epoch":100000}}'
  stub_concurrent_runs 0
  run bash -c "set -euo pipefail; source '$LIB'; SOURCE_NOW=100000 arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

@test "gate: is set -euo pipefail-safe on the admission defer path" {
  write_config "dev-lead" 3 5 50 3 30
  write_state '{"dev-lead":{"last_run_epoch":0,"daily_count":0,"consecutive_failures":0,"breaker_opened_epoch":0}}'
  stub_concurrent_runs 3
  run bash -c "set -euo pipefail; source '$LIB'; arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

@test "gate: at the concurrency cap defers" {
  write_config "dev-lead" 3 5 50 3 30
  write_state '{"dev-lead":{"last_run_epoch":0,"daily_count":0,"consecutive_failures":0,"breaker_opened_epoch":0}}'
  stub_concurrent_runs 3
  run bash -c "source '$LIB'; arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

@test "gate: DRY_RUN prints the would-be defer but returns allow with no mutation" {
  write_config "dev-lead" 3 5 50 3 30
  write_state '{"dev-lead":{"last_run_epoch":0,"daily_count":0,"consecutive_failures":0,"breaker_opened_epoch":0}}'
  stub_concurrent_runs 3
  run bash -c "source '$LIB'; DRY_RUN=true arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"defer"* ]]
  [[ "$output" == *"decision=allow"* ]]
  run grep -qE 'run cancel|pr create|pr edit|issue edit|label|api -X (POST|PATCH|PUT|DELETE)' "$GH_STUB_LOG"
  [ "$status" -eq 1 ]
}

@test "gate: DEV_LEAD_DRY_RUN is honored as an alias for DRY_RUN" {
  write_config "dev-lead" 3 5 50 3 30
  write_state '{"dev-lead":{"last_run_epoch":0,"daily_count":0,"consecutive_failures":0,"breaker_opened_epoch":0}}'
  stub_concurrent_runs 3
  run bash -c "source '$LIB'; DEV_LEAD_DRY_RUN=true arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

# --------------------------------------------------------------------------
# Degradation of the top-level gate (AC #4) — missing config/state allows
# --------------------------------------------------------------------------
@test "gate: a missing config file degrades to allow (never blocks the fleet)" {
  export AGENT_RATE_LIMITS_CONFIG="$TMP/does-not-exist.json"
  stub_concurrent_runs 0
  run bash -c "source '$LIB'; arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: a malformed config file degrades to allow" {
  export AGENT_RATE_LIMITS_CONFIG="$TMP/agent-rate-limits.json"
  printf '%s' 'this is not json {{{' >"$AGENT_RATE_LIMITS_CONFIG"
  stub_concurrent_runs 0
  run bash -c "source '$LIB'; arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: missing state degrades counts to an allowing default" {
  write_config "dev-lead" 3 5 50 3 30
  export AGENT_RATE_LIMITS_STATE="$TMP/no-state.json"  # absent file
  stub_concurrent_runs 0
  run bash -c "source '$LIB'; arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: a failing gh run-list degrades the concurrency count to allow" {
  write_config "dev-lead" 3 5 50 3 30
  write_state '{"dev-lead":{"last_run_epoch":0,"daily_count":0,"consecutive_failures":0,"breaker_opened_epoch":0}}'
  export GH_STUB_EXIT=1
  export GH_STUB_STDOUT=""
  run bash -c "source '$LIB'; arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: the guard never issues a mutating gh subcommand (read-only)" {
  write_config "dev-lead" 3 5 50 3 30
  write_state '{"dev-lead":{"last_run_epoch":0,"daily_count":0,"consecutive_failures":0,"breaker_opened_epoch":0}}'
  stub_concurrent_runs 1
  run bash -c "source '$LIB'; arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 0 ]
  run grep -qE 'run cancel|pr create|pr edit|issue edit|label|api -X (POST|PATCH|PUT|DELETE)' "$GH_STUB_LOG"
  [ "$status" -eq 1 ]
}

# --------------------------------------------------------------------------
# arl_is_dry_run — independent OR check (both DRY_RUN and DEV_LEAD_DRY_RUN)
# --------------------------------------------------------------------------
@test "DRY_RUN=false DEV_LEAD_DRY_RUN=true is treated as a dry run" {
  # Previously DRY_RUN=false would shadow DEV_LEAD_DRY_RUN=true via :- expansion.
  write_config "dev-lead" 3 5 50 3 30
  write_state '{"dev-lead":{"last_run_epoch":0,"daily_count":0,"consecutive_failures":0,"breaker_opened_epoch":0}}'
  stub_concurrent_runs 3
  run bash -c "source '$LIB'; DRY_RUN=false DEV_LEAD_DRY_RUN=true arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
  [[ "$output" == *"DRY_RUN"* ]]
}

# --------------------------------------------------------------------------
# Negative elapsed time — future timestamps must fail open (degraded allow)
# --------------------------------------------------------------------------
@test "admission: a future last_run_epoch (negative elapsed) degrades to allow" {
  write_config "dev-lead" 3 5 50 3 30
  # now=1000, last_run=2000 -> elapsed=-1000 -> future timestamp -> allow
  run bash -c "source '$LIB'; arl_admission_decision dev-lead 0 2000 0 1000"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
  [[ "$output" == *"future"* ]]
}

@test "breaker: a future breaker_opened_epoch (negative elapsed) degrades to allow" {
  write_config "dev-lead" 3 5 50 3 30
  # failures=5 >= threshold=3, opened=200000 > now=100000 -> future -> allow
  run bash -c "source '$LIB'; arl_breaker_decision dev-lead 5 200000 100000"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
  [[ "$output" == *"future"* ]]
}

# --------------------------------------------------------------------------
# Daily window reset — expired daily_window_start resets the counter
# --------------------------------------------------------------------------
@test "gate: daily_count at budget is allowed when the 24h window has expired" {
  write_config "dev-lead" 3 5 50 3 30
  # daily_window_start=0 (86400s before now=86401) -> window expired -> count reset to 0
  write_state '{"dev-lead":{"last_run_epoch":0,"daily_count":50,"daily_window_start":1,"consecutive_failures":0,"breaker_opened_epoch":0}}'
  stub_concurrent_runs 0
  run bash -c "source '$LIB'; SOURCE_NOW=86401 arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "gate: daily_count at budget defers when the 24h window is still active" {
  write_config "dev-lead" 3 5 50 3 30
  # daily_window_start=86000, now=86401, elapsed=401 < 86400 -> window still active
  write_state '{"dev-lead":{"last_run_epoch":0,"daily_count":50,"daily_window_start":86000,"consecutive_failures":0,"breaker_opened_epoch":0}}'
  stub_concurrent_runs 0
  run bash -c "source '$LIB'; SOURCE_NOW=86401 arl_admission_gate dev-lead donpetry-bot"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

# --------------------------------------------------------------------------
# Half-open probe deduplication — probe_dispatched_epoch prevents double probe
# --------------------------------------------------------------------------
@test "breaker: half-open with a recent probe_dispatched_epoch defers" {
  write_config "dev-lead" 3 5 50 3 30
  # opened=100000, now=101800 (1800s elapsed == backoff -> half-open)
  # probe_dispatched=101700 (100s ago, within 1800s window) -> defer
  run bash -c "source '$LIB'; arl_breaker_decision dev-lead 5 100000 101800 101700"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
  [[ "$output" == *"probe already dispatched"* ]]
}

@test "breaker: half-open with an expired probe_dispatched_epoch allows a new probe" {
  write_config "dev-lead" 3 5 50 3 30
  # opened=100000, now=103800 (3800s elapsed > 1800s backoff -> half-open)
  # probe_dispatched=100001 (3799s ago, > 1800s window) -> allow new probe
  run bash -c "source '$LIB'; arl_breaker_decision dev-lead 5 100000 103800 100001"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
  [[ "$output" == *"half-open"* ]]
}

# --------------------------------------------------------------------------
# arl_is_exempt_label and gate exempt-label path (AC #2)
# --------------------------------------------------------------------------
@test "arl_is_exempt_label is true for a configured exempt label" {
  write_config "dev-lead" 3 5 50 3 30
  run bash -c "source '$LIB'; arl_is_exempt_label 'security'"
  [ "$status" -eq 0 ]
}

@test "arl_is_exempt_label is false for a non-exempt label" {
  write_config "dev-lead" 3 5 50 3 30
  run bash -c "source '$LIB'; arl_is_exempt_label 'enhancement'"
  [ "$status" -eq 1 ]
}

@test "arl_is_exempt_label is true when one label in a csv list is exempt" {
  write_config "dev-lead" 3 5 50 3 30
  run bash -c "source '$LIB'; arl_is_exempt_label 'priority-high,security,bug'"
  [ "$status" -eq 0 ]
}

@test "gate: a run with an exempt label is allowed even over every limit" {
  write_config "dev-lead" 1 5 1 1 30
  write_state '{"dev-lead":{"last_run_epoch":0,"daily_count":999,"consecutive_failures":99,"breaker_opened_epoch":0}}'
  stub_concurrent_runs 50
  run bash -c "source '$LIB'; arl_admission_gate dev-lead non-exempt-actor 'security'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
  [[ "$output" == *"exempt"* ]]
}
