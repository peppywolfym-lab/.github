#!/usr/bin/env bats
# Tests for scripts/agent-rate-limit-gate.sh — the Phase-4 dispatch-time
# orchestrator that wires the pure gate library (scripts/lib/agent-rate-limit.sh)
# into the agent-dispatching workflows (#640, Phase 4 of epic #636).
#
# The orchestrator is the thin I/O glue AGENTS.md prescribes: it gathers facts
# from run history (via a single `gh run list`), DERIVES the admission counters
# and the breaker's consecutive_failures from that history (no state backend —
# Actions runners are ephemeral; AC #3), and feeds them to the library's pure
# arl_admission_decision / arl_breaker_decision. It enforces for the
# initiative-driver canary and runs log-only for every other agent type (AC #5),
# escalates an open breaker exactly once via the library's marker/label idiom
# (AC #4), and honours DRY_RUN (AC #7).
#
# Every threshold is read by the library from standards/agent-rate-limits.json —
# no number is restated here (AC #1). `gh` is stubbed; no network is touched.

bats_require_minimum_version 1.5.0

GATE="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts/agent-rate-limit-gate.sh"

setup() {
  TMP="$(mktemp -d "$BATS_TEST_TMPDIR/gate.XXXXXX")"
  export TMP

  # A dispatching gh stub: `run list` returns the scripted run history,
  # `issue view` returns the scripted tracking-issue body, and every mutating
  # subcommand is logged (and no-ops) so a test can assert exactly-once posting
  # and read-only-ness. Behaviour is env-driven so no per-test stub variant is
  # needed (mirrors test/scripts/compliance-remediate/stubs/gh).
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${GH_STUB_LOG:-}" ]; then
  printf '%q ' "$@" >>"$GH_STUB_LOG"
  printf '\n' >>"$GH_STUB_LOG"
fi
case "$1 ${2:-}" in
  "run list")
    printf '%s' "${GH_RUNS_JSON:-[]}"
    ;;
  "issue view")
    printf '{"body":%s,"comments":%s}' \
      "$(printf '%s' "${GH_ISSUE_BODY:-}" | jq -Rs .)" \
      "${GH_ISSUE_COMMENTS_JSON:-[]}"
    ;;
  *)
    : # comment / edit / anything else: no-op, exit 0
    ;;
esac
exit 0
STUB
  chmod +x "$TMP/bin/gh"
  PATH="$TMP/bin:$PATH"
  export PATH
  export GH_STUB_LOG="$TMP/gh.log"
  : >"$GH_STUB_LOG"

  # A single-agent config so the library resolves thresholds from a file, never
  # a hardcoded number (AC #1). Signature: agent max cooldown daily cb_thr cb_backoff.
  write_config() {
    local agent="$1" max="$2" cooldown="$3" daily="$4" cb_threshold="$5" cb_backoff="$6"
    export AGENT_RATE_LIMITS_CONFIG="$TMP/agent-rate-limits.json"
    jq -n \
      --arg agent "$agent" \
      --argjson max "$max" --argjson cooldown "$cooldown" --argjson daily "$daily" \
      --argjson cb_threshold "$cb_threshold" --argjson cb_backoff "$cb_backoff" \
      '{
        status: "signed-off", _schema_version: 1,
        agent_types: { ($agent): {
          max_concurrent_runs: $max, max_runtime_minutes: 30,
          cooldown_minutes: $cooldown, daily_run_budget: $daily,
          circuit_breaker: { consecutive_failure_threshold: $cb_threshold, backoff_minutes: $cb_backoff }
        } },
        org_wide: {},
        exempt_actors: ["dependabot[bot]", "@petry-projects/org-leads"],
        exempt_labels: ["security"]
      }' >"$AGENT_RATE_LIMITS_CONFIG"
  }

  # A config carrying the org_wide.token_budget block (session threshold +
  # weekly_all glide keys + the non-pause-worthy weekly_scoped) plus one agent
  # type, for the token-budget wiring tests (#1155). weekly_all.enabled is left
  # unset (defaults false) so the glide breaker stays inert until a maintainer
  # arms it in config — arming it is deliberately out of scope.
  write_token_gate_config() {
    local agent="$1" threshold="${2:-90}"
    export AGENT_RATE_LIMITS_CONFIG="$TMP/agent-rate-limits.json"
    jq -n --arg agent "$agent" --argjson threshold "$threshold" '{
      status: "signed-off", _schema_version: 1,
      agent_types: { ($agent): {
        max_concurrent_runs: 3, max_runtime_minutes: 30,
        cooldown_minutes: 0, daily_run_budget: 50,
        circuit_breaker: { consecutive_failure_threshold: 3, backoff_minutes: 30 }
      } },
      org_wide: { token_budget: {
        claude_priority: true,
        limits: {
          session:       { kind: "session", window_hours: 5, pause_worthy: true, pause_threshold_pct: $threshold },
          weekly_all:    { kind: "weekly_all", window_days: 7, pause_worthy: true, reserve_pct_per_day: 2, floor_pct: 86, ceiling_pct: 100 },
          weekly_scoped: { kind: "weekly_scoped", pause_worthy: false }
        }
      } },
      exempt_actors: ["dependabot[bot]", "@petry-projects/org-leads"],
      exempt_labels: ["security"]
    }' >"$AGENT_RATE_LIMITS_CONFIG"
  }

  # A test-only variant of write_token_gate_config that ARMS the weekly glide
  # breaker (weekly_all.enabled: true) so the glide half is exercised end-to-end
  # through the orchestrator. standards/agent-rate-limits.json is never touched —
  # this fixture lives only in $TMP for the duration of a test (#1155 review).
  write_glide_gate_config() {
    local agent="$1" session_threshold="${2:-90}"
    export AGENT_RATE_LIMITS_CONFIG="$TMP/agent-rate-limits.json"
    jq -n --arg agent "$agent" --argjson threshold "$session_threshold" '{
      status: "signed-off", _schema_version: 1,
      agent_types: { ($agent): {
        max_concurrent_runs: 3, max_runtime_minutes: 30,
        cooldown_minutes: 0, daily_run_budget: 50,
        circuit_breaker: { consecutive_failure_threshold: 3, backoff_minutes: 30 }
      } },
      org_wide: { token_budget: {
        claude_priority: true,
        limits: {
          session:       { kind: "session", window_hours: 5, pause_worthy: true, pause_threshold_pct: $threshold },
          weekly_all:    { kind: "weekly_all", window_days: 7, pause_worthy: true, enabled: true, reserve_pct_per_day: 2, floor_pct: 86, ceiling_pct: 100 },
          weekly_scoped: { kind: "weekly_scoped", pause_worthy: false }
        }
      } },
      exempt_actors: ["dependabot[bot]", "@petry-projects/org-leads"],
      exempt_labels: ["security"]
    }' >"$AGENT_RATE_LIMITS_CONFIG"
  }

  # A 200 envelope whose weekly_all window carries the given percent and reset
  # timestamp (session pinned under-threshold so the ONLY pause signal is the
  # weekly glide path). Used with a matching SOURCE_NOW to fix days_until_reset.
  envelope_weekly() {
    local weekly_pct="$1" resets_at="$2"
    jq -nc --argjson w "$weekly_pct" --arg r "$resets_at" '{
      status: 200,
      body: { limits: [
        { kind: "session",    percent: 5, resets_at: "2026-08-31T12:00:00Z", is_active: true },
        { kind: "weekly_all", percent: $w, resets_at: $r, is_active: true }
      ] }
    }'
  }

  # Point the telemetry adapter seam at a fixture file holding the normalized
  # envelope JSON the private poller would emit.
  write_telemetry() {
    export AGENT_TOKEN_BUDGET_TELEMETRY_FILE="$TMP/telemetry.json"
    printf '%s' "$1" >"$AGENT_TOKEN_BUDGET_TELEMETRY_FILE"
  }

  # A 200 envelope whose body carries a limits[] array with the given session /
  # weekly_all percentages (weekly_scoped pinned at 100 to prove it is ignored).
  envelope_limits() {
    local session_pct="$1" weekly_pct="${2:-40}"
    jq -nc --argjson s "$session_pct" --argjson w "$weekly_pct" '{
      status: 200,
      body: { limits: [
        { kind: "session",       percent: $s, resets_at: "2026-08-31T12:00:00Z", is_active: true },
        { kind: "weekly_all",    percent: $w, resets_at: "2026-09-02T15:59:59Z", is_active: true },
        { kind: "weekly_scoped", percent: 100, resets_at: "2026-09-02T15:59:59Z", is_active: true }
      ] }
    }'
  }

  # Build a run-history JSON array. Each argument is "conclusion@ISO8601"; a
  # status of in_progress/queued is expressed as "in_progress@ISO" (empty
  # conclusion). Runs are emitted as gh's `run list --json` shape.
  runs_json() {
    local out="[]" spec concl created status
    for spec in "$@"; do
      concl="${spec%@*}"; created="${spec#*@}"
      case "$concl" in
        in_progress|queued) status="$concl"; concl="" ;;
        *) status="completed" ;;
      esac
      out="$(jq -c \
        --arg s "$status" --arg c "$concl" --arg t "$created" \
        '. + [{databaseId: (length+1), status: $s, conclusion: (if $c=="" then null else $c end), createdAt: $t}]' \
        <<<"$out")"
    done
    printf '%s' "$out"
  }
}

teardown() {
  [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP"
}

# Assert the gh log contains no mutating issue subcommand.
refute_mutated() {
  touch "$GH_STUB_LOG"
  run grep -qE 'issue comment|issue edit|--add-label|api -X (POST|PATCH|PUT|DELETE)' "$GH_STUB_LOG"
  [ "$status" -eq 1 ]
}

# --------------------------------------------------------------------------
# Sourcing contract — set -euo pipefail-safe, defines the orchestrator API.
# --------------------------------------------------------------------------
@test "sourcing the orchestrator is side-effect-free and defines argate_gate" {
  run bash -c "set -euo pipefail; ARGATE_LIB_ONLY=1 source '$GATE'; declare -F argate_gate >/dev/null && echo ok"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

# --------------------------------------------------------------------------
# Pure derivation from run history (AC #3) — no state backend involved.
# --------------------------------------------------------------------------
@test "argate_concurrent counts in-progress and queued runs" {
  local j; j="$(runs_json 'success@2026-09-01T00:00:00Z' 'in_progress@2026-09-01T01:00:00Z' 'queued@2026-09-01T02:00:00Z')"
  run bash -c "ARGATE_LIB_ONLY=1 source '$GATE'; argate_concurrent '$j'"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "argate_consecutive_failures counts the leading failure streak (most-recent-first)" {
  # Newest → oldest: failure, failure, success, failure  => streak of 2.
  local j; j="$(runs_json 'failure@2026-09-01T00:00:00Z' 'success@2026-09-01T01:00:00Z' 'failure@2026-09-01T02:00:00Z' 'failure@2026-09-01T03:00:00Z')"
  run bash -c "ARGATE_LIB_ONLY=1 source '$GATE'; argate_consecutive_failures '$j'"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "argate_consecutive_failures is zero when the newest completed run succeeded" {
  local j; j="$(runs_json 'failure@2026-09-01T00:00:00Z' 'failure@2026-09-01T01:00:00Z' 'success@2026-09-01T02:00:00Z')"
  run bash -c "ARGATE_LIB_ONLY=1 source '$GATE'; argate_consecutive_failures '$j'"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "argate_consecutive_failures skips a cancelled run without breaking the streak (#1047 lesson)" {
  # A concurrency-evicted (cancelled) run must neither count as a failure nor
  # reset the streak: newest→oldest failure, cancelled, failure, success => streak of 2.
  local j; j="$(runs_json 'failure@2026-09-01T03:00:00Z' 'cancelled@2026-09-01T02:00:00Z' 'failure@2026-09-01T01:00:00Z' 'success@2026-09-01T00:00:00Z')"
  run bash -c "ARGATE_LIB_ONLY=1 source '$GATE'; argate_consecutive_failures '$j'"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "argate_concurrent ignores completed runs" {
  local j; j="$(runs_json 'success@2026-09-01T00:00:00Z' 'failure@2026-09-01T01:00:00Z')"
  run bash -c "ARGATE_LIB_ONLY=1 source '$GATE'; argate_concurrent '$j'"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "argate_concurrent excludes the current run (GITHUB_RUN_ID) from the in-progress count" {
  # databaseId 1 and 2 are both in_progress; GITHUB_RUN_ID=2 is this gate's own run.
  # Only databaseId 1 should count — the gate must not see itself as a concurrent run.
  local j; j="$(runs_json 'in_progress@2026-09-01T00:00:00Z' 'in_progress@2026-09-01T00:01:00Z')"
  run bash -c "export GITHUB_RUN_ID=2; ARGATE_LIB_ONLY=1 source '$GATE'; argate_concurrent '$j'"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "argate_last_run_epoch excludes the current run (GITHUB_RUN_ID) from the cooldown calculation" {
  # databaseId 2 (the current gate run, created just now) is the newest run.
  # With GITHUB_RUN_ID=2 it must be excluded so the cooldown derives from databaseId 1 only.
  local j; j="$(runs_json 'success@2026-09-01T00:00:00Z' 'success@2026-09-01T01:00:00Z')"
  # Without exclusion: max createdAt = 2026-09-01T01:00:00Z (databaseId 2).
  # With exclusion:    max createdAt = 2026-09-01T00:00:00Z (databaseId 1).
  local epoch_with epoch_without
  epoch_with="$(bash -c "export GITHUB_RUN_ID=2; ARGATE_LIB_ONLY=1 source '$GATE'; argate_last_run_epoch '$j'")"
  epoch_without="$(bash -c "unset GITHUB_RUN_ID; ARGATE_LIB_ONLY=1 source '$GATE'; argate_last_run_epoch '$j'")"
  # The excluded epoch must be strictly earlier (databaseId 1 was created first).
  [ "$epoch_with" -lt "$epoch_without" ]
}

@test "argate_daily_count excludes the current run (GITHUB_RUN_ID) from the daily budget" {
  # databaseId 1 and 2 are both within the 24h window. GITHUB_RUN_ID=2 is the
  # current gate run and must not count toward the daily budget — an in-progress
  # gate run alone must not exhaust the budget and defer itself.
  local now; now=1788221100  # 2026-09-01T00:05:00Z
  local j; j="$(runs_json "success@2026-09-01T00:03:00Z" "success@2026-09-01T00:04:00Z")"
  run bash -c "export GITHUB_RUN_ID=2; ARGATE_LIB_ONLY=1 source '$GATE'; argate_daily_count '$j' $now"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "enforce: the current gate run alone does not trigger cooldown deferral" {
  # A single in-progress run that IS the current gate run (GITHUB_RUN_ID=1) must not
  # cause a cooldown defer — the gate would otherwise always defer itself on the very
  # first run after a prior failure-free history (last_run would be "now").
  write_config "initiative-driver" 2 10 20 3 30
  # One completed run from 5 seconds ago (within the 10-min cooldown), plus the
  # current gate run as in_progress. With exclusion the last_run epoch is the
  # completed run; without exclusion it would be the in_progress run created "just now".
  # We arrange the completed run to be recent enough to cause a defer if last_run is wrong.
  local now=1788221100  # 2026-09-01T00:05:00Z
  export GH_RUNS_JSON; GH_RUNS_JSON="$(runs_json "success@2026-09-01T00:04:55Z" "in_progress@2026-09-01T00:05:00Z")"
  # GITHUB_RUN_ID=2 corresponds to the in_progress run (databaseId 2 in runs_json).
  # The completed run at T-5s is still within the 10-min cooldown, so the gate should
  # defer (the cooldown DOES apply to the prior completed run — we're not claiming
  # no defer, just that the in_progress gate run itself is excluded from last_run).
  run bash -c "export GITHUB_RUN_ID=2; SOURCE_NOW=$now bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot"
  [ "$status" -eq 0 ]
  # Decision may be defer due to the prior completed run, but the gate must not crash
  # and must not count the in_progress run toward daily_count or last_run twice.
  [[ "$output" == *"decision="* ]]
}

# --------------------------------------------------------------------------
# Enforcing vs log-only split (AC #5)
# --------------------------------------------------------------------------
@test "enforce: at the concurrency cap the decision is defer" {
  write_config "initiative-driver" 1 10 20 3 30
  export GH_RUNS_JSON; GH_RUNS_JSON="$(runs_json 'in_progress@2026-09-01T00:00:00Z')"
  run bash -c "SOURCE_NOW=1893456000 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"defer"* ]]
}

@test "log-only: a computed defer is emitted as allow and never acted on" {
  write_config "feature-ideation" 1 0 1 3 60
  # 1 in-progress run == the cap of 1, so the COMPUTED decision is defer.
  export GH_RUNS_JSON; GH_RUNS_JSON="$(runs_json 'in_progress@2026-09-01T00:00:00Z')"
  run bash -c "SOURCE_NOW=1893456000 bash '$GATE' feature-ideation --mode log-only --actor donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"allow"* ]]
  # It must log that the enforced decision WOULD have been defer (observability).
  [[ "$output" == *"defer"* ]]
  refute_mutated
}

# --------------------------------------------------------------------------
# Defer is a clean no-op: never a job failure, never a mutation (AC #1)
# --------------------------------------------------------------------------
@test "enforce: a defer exits 0 (defer is never a job failure) and mutates nothing" {
  write_config "initiative-driver" 1 10 20 3 30
  export GH_RUNS_JSON; GH_RUNS_JSON="$(runs_json 'in_progress@2026-09-01T00:00:00Z')"
  run bash -c "SOURCE_NOW=1893456000 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot"
  [ "$status" -eq 0 ]
  refute_mutated
}

@test "enforce: writes the decision to GITHUB_OUTPUT for the workflow to gate on" {
  write_config "initiative-driver" 1 10 20 3 30
  export GH_RUNS_JSON; GH_RUNS_JSON="$(runs_json 'in_progress@2026-09-01T00:00:00Z')"
  export GITHUB_OUTPUT="$TMP/gh_output"
  : >"$GITHUB_OUTPUT"
  run bash -c "SOURCE_NOW=1893456000 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot"
  [ "$status" -eq 0 ]
  run grep -q '^decision=defer$' "$GITHUB_OUTPUT"
  [ "$status" -eq 0 ]
}

@test "enforce: under all limits with a clean breaker allows" {
  write_config "initiative-driver" 1 10 20 3 30
  # No runs at all → concurrency 0, no cooldown, daily 0, no failures → allow.
  export GH_RUNS_JSON; GH_RUNS_JSON="[]"
  run bash -c "SOURCE_NOW=1893456000 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

# --------------------------------------------------------------------------
# Consecutive-failure breaker derived from run history feeds the library (AC #3/#4)
# --------------------------------------------------------------------------
@test "enforce: 3 consecutive recent failures (>= threshold) within backoff defers" {
  write_config "initiative-driver" 1 10 20 3 30
  # 3 failures, the newest 60s before now → within the 30-min backoff → breaker open.
  # now = 2026-09-01T00:05:00Z (epoch 1788221100)
  export GH_RUNS_JSON
  GH_RUNS_JSON="$(runs_json 'failure@2026-09-01T00:04:00Z' 'failure@2026-09-01T00:03:00Z' 'failure@2026-09-01T00:02:00Z')"
  run bash -c "SOURCE_NOW=1788221100 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=defer"* ]]
}

# --------------------------------------------------------------------------
# Breaker escalation posts exactly once and dedups (AC #4)
# --------------------------------------------------------------------------
@test "enforce: an open breaker escalates once — posts the marker and applies the label" {
  write_config "initiative-driver" 1 10 20 3 30
  export GH_RUNS_JSON
  GH_RUNS_JSON="$(runs_json 'failure@2026-09-01T00:04:00Z' 'failure@2026-09-01T00:03:00Z' 'failure@2026-09-01T00:02:00Z')"
  export GH_ISSUE_BODY="tracking issue, no marker yet"
  run bash -c "SOURCE_NOW=1788221100 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot --tracking-repo petry-projects/.github --tracking-issue 636"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=defer"* ]]
  # Exactly one comment posting the breaker marker, and the label applied.
  run grep -c 'issue comment' "$GH_STUB_LOG"
  [ "$output" = "1" ]
  run grep -qE 'issue edit .*--add-label' "$GH_STUB_LOG"
  [ "$status" -eq 0 ]
}

@test "enforce: escalation dedups when the marker is already on the tracking issue" {
  write_config "initiative-driver" 1 10 20 3 30
  export GH_RUNS_JSON
  GH_RUNS_JSON="$(runs_json 'failure@2026-09-01T00:04:00Z' 'failure@2026-09-01T00:03:00Z' 'failure@2026-09-01T00:02:00Z')"
  # Body already carries the marker for initiative-driver → no second post.
  export GH_ISSUE_BODY
  GH_ISSUE_BODY="prior escalation $(bash -c "source '$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts/lib/agent-rate-limit.sh'; arl_breaker_marker initiative-driver")"
  run bash -c "SOURCE_NOW=1788221100 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot --tracking-repo petry-projects/.github --tracking-issue 636"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=defer"* ]]
  run grep -c 'issue comment' "$GH_STUB_LOG"
  [ "$output" = "0" ]
}

# --------------------------------------------------------------------------
# DRY_RUN mutates nothing (AC #7)
# --------------------------------------------------------------------------
@test "DRY_RUN: an open breaker logs the intended decision but mutates nothing" {
  write_config "initiative-driver" 1 10 20 3 30
  export GH_RUNS_JSON
  GH_RUNS_JSON="$(runs_json 'failure@2026-09-01T00:04:00Z' 'failure@2026-09-01T00:03:00Z' 'failure@2026-09-01T00:02:00Z')"
  export GH_ISSUE_BODY="no marker"
  run bash -c "DRY_RUN=true SOURCE_NOW=1788221100 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot --tracking-repo petry-projects/.github --tracking-issue 636"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
  refute_mutated
}

@test "DEV_LEAD_DRY_RUN is honoured as an alias for DRY_RUN" {
  write_config "initiative-driver" 1 10 20 3 30
  export GH_RUNS_JSON; GH_RUNS_JSON="$(runs_json 'in_progress@2026-09-01T00:00:00Z')"
  run bash -c "DEV_LEAD_DRY_RUN=true SOURCE_NOW=1893456000 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

# --------------------------------------------------------------------------
# Exempt actors/labels bypass the gate (AC #1, same policy as the library)
# --------------------------------------------------------------------------
@test "enforce: an exempt actor is allowed even over the concurrency cap" {
  write_config "initiative-driver" 1 10 20 3 30
  export GH_RUNS_JSON; GH_RUNS_JSON="$(runs_json 'in_progress@2026-09-01T00:00:00Z')"
  run bash -c "SOURCE_NOW=1893456000 bash '$GATE' initiative-driver --mode enforce --actor 'dependabot[bot]'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "enforce: an exempt label is allowed even over the concurrency cap" {
  write_config "initiative-driver" 1 10 20 3 30
  export GH_RUNS_JSON; GH_RUNS_JSON="$(runs_json 'in_progress@2026-09-01T00:00:00Z')"
  run bash -c "SOURCE_NOW=1893456000 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot --labels security"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

# --------------------------------------------------------------------------
# Fail-safe: a run-list fetch failure degrades to allow (AC #1)
# --------------------------------------------------------------------------
@test "enforce: an unreadable config degrades to allow (never blocks the fleet)" {
  export AGENT_RATE_LIMITS_CONFIG="$TMP/does-not-exist.json"
  export GH_RUNS_JSON; GH_RUNS_JSON="$(runs_json 'in_progress@2026-09-01T00:00:00Z' 'in_progress@2026-09-01T00:01:00Z')"
  run bash -c "SOURCE_NOW=1893456000 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

# --------------------------------------------------------------------------
# The gate is read-only on the happy path (AC #1)
# --------------------------------------------------------------------------
@test "enforce: an allow decision issues no mutating gh subcommand" {
  write_config "initiative-driver" 1 10 20 3 30
  export GH_RUNS_JSON; GH_RUNS_JSON="[]"
  run bash -c "SOURCE_NOW=1893456000 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot --tracking-repo petry-projects/.github --tracking-issue 636"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
  refute_mutated
}

# ==========================================================================
# Org-wide token-budget breaker wiring (#1155)
#
# The orchestrator must consult the org-wide token-budget breaker (session +
# weekly_all) in its decision path, in addition to the per-agent-type checks —
# but only when AGENT_TOKEN_BUDGET_ENABLED is set. A defer from the token-budget
# half defers dispatch; with the flag unset the behaviour is byte-identical to
# before this change. `weekly_scoped` is never consulted (ADR §2.5).
# ==========================================================================

@test "token-budget: armed + over-threshold session envelope defers under enforce (AC #6)" {
  write_token_gate_config "initiative-driver" 90
  write_telemetry "$(envelope_limits 95 40)"
  export GH_RUNS_JSON; GH_RUNS_JSON="[]"
  # Admission is clean (no run history, cooldown 0), so the ONLY reason to defer
  # is the org-wide token budget being over threshold.
  run bash -c "AGENT_TOKEN_BUDGET_ENABLED=true SOURCE_NOW=1893456000 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=defer"* ]]
}

@test "token-budget: with the flag unset an over-threshold envelope has no effect (AC #2/#6 inert)" {
  write_token_gate_config "initiative-driver" 90
  write_telemetry "$(envelope_limits 95 40)"
  export GH_RUNS_JSON; GH_RUNS_JSON="[]"
  run bash -c "SOURCE_NOW=1893456000 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
  # No token-budget code path runs at all when the flag is unset.
  [[ "$output" != *"token-budget"* ]]
}

@test "token-budget: with the flag unset output is byte-identical whether or not telemetry is present (AC #6)" {
  write_token_gate_config "initiative-driver" 90
  export GH_RUNS_JSON; GH_RUNS_JSON="[]"
  local with_tel without_tel
  write_telemetry "$(envelope_limits 95 40)"
  run bash -c "SOURCE_NOW=1893456000 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot"
  [ "$status" -eq 0 ]
  with_tel="$output"
  unset AGENT_TOKEN_BUDGET_TELEMETRY_FILE
  rm -f "$TMP/telemetry.json"
  run bash -c "SOURCE_NOW=1893456000 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot"
  [ "$status" -eq 0 ]
  without_tel="$output"
  [ "$with_tel" = "$without_tel" ]
}

@test "token-budget: armed + over-threshold under log-only emits allow but logs the would-be defer and percent (AC #3)" {
  write_token_gate_config "feature-ideation" 90
  write_telemetry "$(envelope_limits 95 40)"
  export GH_RUNS_JSON; GH_RUNS_JSON="[]"
  run bash -c "AGENT_TOKEN_BUDGET_ENABLED=true SOURCE_NOW=1893456000 bash '$GATE' feature-ideation --mode log-only --actor donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
  # Observability: the computed defer and the session percent are logged even
  # though nothing is acted on (canary discipline).
  [[ "$output" == *"defer"* ]]
  [[ "$output" == *"95"* ]]
  refute_mutated
}

@test "token-budget: weekly_scoped at 100% never defers when session is under threshold (scope guard, AC #4)" {
  write_token_gate_config "initiative-driver" 90
  # session 50 (under), weekly_all 40 (under + glide disarmed), weekly_scoped 100.
  write_telemetry "$(envelope_limits 50 40)"
  export GH_RUNS_JSON; GH_RUNS_JSON="[]"
  run bash -c "AGENT_TOKEN_BUDGET_ENABLED=true SOURCE_NOW=1893456000 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

@test "token-budget: absent telemetry allows but logs a DEGRADED fail-open distinct from a healthy allow (AC #5)" {
  write_token_gate_config "initiative-driver" 90
  export GH_RUNS_JSON; GH_RUNS_JSON="[]"
  run bash -c "unset AGENT_TOKEN_BUDGET_TELEMETRY_FILE AGENT_TOKEN_BUDGET_TELEMETRY_CMD; AGENT_TOKEN_BUDGET_ENABLED=true SOURCE_NOW=1893456000 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
  # The degraded fail-open must be visibly distinct from a genuine allow (AC #5).
  [[ "$output" == *"NOT obtained"* ]]
}

@test "token-budget: a 200 with an empty body reads as DEGRADED, not OBTAINED (AC #5 precision)" {
  write_token_gate_config "initiative-driver" 90
  # HTTP 200 but no usable window data — both gates fail open. The headline must
  # NOT claim OBTAINED; it must surface a degraded fail-open instead.
  write_telemetry '{"status":200,"body":{}}'
  export GH_RUNS_JSON; GH_RUNS_JSON="[]"
  run bash -c "AGENT_TOKEN_BUDGET_ENABLED=true SOURCE_NOW=1893456000 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
  [[ "$output" == *"NO usable window data"* ]]
  [[ "$output" != *"telemetry OBTAINED"* ]]
}

@test "token-budget: obtained under-threshold telemetry logs a genuine (non-degraded) allow (AC #5)" {
  write_token_gate_config "initiative-driver" 90
  write_telemetry "$(envelope_limits 10 10)"
  export GH_RUNS_JSON; GH_RUNS_JSON="[]"
  run bash -c "AGENT_TOKEN_BUDGET_ENABLED=true SOURCE_NOW=1893456000 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
  [[ "$output" == *"OBTAINED"* ]]
  # Both pause-worthy windows are read and their percents surfaced (AC #5).
  [[ "$output" == *"session"* ]]
  [[ "$output" == *"weekly_all"* ]]
}

# --------------------------------------------------------------------------
# weekly_all glide path armed (weekly_all.enabled: true) — end-to-end defer/allow
# through the orchestrator. standards/agent-rate-limits.json stays disarmed; the
# arm lives only in the test fixture (#1155 review — weekly glide integration).
# threshold = clamp(ceiling - reserve*days, floor, ceiling): reset 2026-09-05,
# now 2026-09-02 => 3 days => 100 - 2*3 = 94% pause threshold.
# --------------------------------------------------------------------------
@test "token-budget: armed weekly_all over the glide threshold defers under enforce" {
  write_glide_gate_config "initiative-driver" 90
  # session under threshold (5% vs 90%); weekly_all 96% >= the 94% glide threshold.
  write_telemetry "$(envelope_weekly 96 2026-09-05T00:00:00Z)"
  export GH_RUNS_JSON; GH_RUNS_JSON="[]"
  run bash -c "AGENT_TOKEN_BUDGET_ENABLED=true SOURCE_NOW=1788307200 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=defer"* ]]
  # The pause is attributable to the weekly window, not the (under-threshold) session.
  [[ "$output" == *"weekly_all"* ]]
}

@test "token-budget: armed weekly_all under the glide threshold allows under enforce" {
  write_glide_gate_config "initiative-driver" 90
  # weekly_all 90% < the 94% glide threshold, session under too => genuine allow.
  write_telemetry "$(envelope_weekly 90 2026-09-05T00:00:00Z)"
  export GH_RUNS_JSON; GH_RUNS_JSON="[]"
  run bash -c "AGENT_TOKEN_BUDGET_ENABLED=true SOURCE_NOW=1788307200 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

# --------------------------------------------------------------------------
# A tripped token-budget window escalates like the per-agent breaker: posts the
# window's marker once and applies needs-human-review, deduped on the marker
# (#1155 review — a trip must be human-clearable, not merely logged).
# --------------------------------------------------------------------------
@test "token-budget: an armed session trip escalates once — posts the token marker and applies the label" {
  write_token_gate_config "initiative-driver" 90
  write_telemetry "$(envelope_limits 95 40)"
  export GH_RUNS_JSON; GH_RUNS_JSON="[]"
  export GH_ISSUE_BODY="tracking issue, no token marker yet"
  run bash -c "AGENT_TOKEN_BUDGET_ENABLED=true SOURCE_NOW=1893456000 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot --tracking-repo petry-projects/.github --tracking-issue 636"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=defer"* ]]
  run grep -c 'issue comment' "$GH_STUB_LOG"
  [ "$output" = "1" ]
  run grep -qE 'issue edit .*--add-label' "$GH_STUB_LOG"
  [ "$status" -eq 0 ]
}

@test "token-budget: session-trip escalation dedups when the token marker is already present" {
  write_token_gate_config "initiative-driver" 90
  write_telemetry "$(envelope_limits 95 40)"
  export GH_RUNS_JSON; GH_RUNS_JSON="[]"
  export GH_ISSUE_BODY
  GH_ISSUE_BODY="prior escalation $(bash -c "source '$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts/lib/agent-rate-limit.sh'; arl_token_breaker_marker session")"
  run bash -c "AGENT_TOKEN_BUDGET_ENABLED=true SOURCE_NOW=1893456000 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot --tracking-repo petry-projects/.github --tracking-issue 636"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=defer"* ]]
  run grep -c 'issue comment' "$GH_STUB_LOG"
  [ "$output" = "0" ]
}

@test "token-budget: session-trip escalation dedups when the token marker is on a prior comment (not the body)" {
  # argate_token_escalate posts its marker with `gh issue comment`, so the dedup
  # read must scan the issue's comments, not only its body — otherwise a second
  # enforce invocation would re-post the marker (#1164 review).
  write_token_gate_config "initiative-driver" 90
  write_telemetry "$(envelope_limits 95 40)"
  export GH_RUNS_JSON; GH_RUNS_JSON="[]"
  export GH_ISSUE_BODY="tracking issue, no token marker in body"
  export GH_ISSUE_COMMENTS_JSON
  GH_ISSUE_COMMENTS_JSON="$(jq -n --arg m "$(bash -c "source '$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts/lib/agent-rate-limit.sh'; arl_token_breaker_marker session")" '[{body: ("prior escalation " + $m)}]')"
  run bash -c "AGENT_TOKEN_BUDGET_ENABLED=true SOURCE_NOW=1893456000 bash '$GATE' initiative-driver --mode enforce --actor donpetry-bot --tracking-repo petry-projects/.github --tracking-issue 636"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=defer"* ]]
  run grep -c 'issue comment' "$GH_STUB_LOG"
  [ "$output" = "0" ]
}

@test "token-budget: an armed trip under log-only escalates nothing (canary discipline)" {
  write_token_gate_config "feature-ideation" 90
  write_telemetry "$(envelope_limits 95 40)"
  export GH_RUNS_JSON; GH_RUNS_JSON="[]"
  export GH_ISSUE_BODY="tracking issue, no token marker yet"
  run bash -c "AGENT_TOKEN_BUDGET_ENABLED=true SOURCE_NOW=1893456000 bash '$GATE' feature-ideation --mode log-only --actor donpetry-bot --tracking-repo petry-projects/.github --tracking-issue 636"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
  refute_mutated
}
