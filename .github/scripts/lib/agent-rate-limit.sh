# shellcheck shell=bash
# scripts/lib/agent-rate-limit.sh — Source-side agent admission + circuit-breaker gate
#
# Reusable Bash library implementing the §5/§8.1 source-side mechanism from the
# Agent-Rate-Limit ADR:
#
#   docs/initiatives/agent-rate-limits-adr.md
#
# GitHub exposes no native per-workflow rate limiter and no run-count budget (ADR
# §2/§4), so per-agent-type throttling is enforced at the automation *source*:
# before an agent-creating workflow (dev-lead / initiative-driver / feature-
# ideation / compliance-audit) dispatches a run, it asks this gate whether the
# agent type may run right now. The gate evaluates four admission dimensions plus
# a consecutive-failure circuit breaker, reading every threshold from the config
# single source of truth (standards/agent-rate-limits.json), and returns allow or
# defer — it never cancels an in-flight run (`cancel-in-progress` is the #402
# anti-pattern; ADR §1).
#
# This library delivers the guard + its tests ONLY. Wiring it into the live
# dispatch path is Phases 4-5 (ADR §8): Phase 4 wires the public gate into the
# private engine's dispatch path; Phase 5 builds the private token-budget breaker.
# It is deliberately wired into no live workflow here (AC #6), mirroring how
# scripts/lib/pr-limit-gate.sh shipped its guard + tests before #508 wired it.
#
# ----------------------------------------------------------------------------
# Caller contract
# ----------------------------------------------------------------------------
# This library is `set -euo pipefail`-safe and designed to be sourced by a parent
# script (`# shellcheck source=scripts/lib/agent-rate-limit.sh`). It does NOT call
# `set` itself and runs nothing at source time.
#
# Reads (all optional, with defaults):
#   - $AGENT_RATE_LIMITS_CONFIG — path to the agent-rate-limits.json single source
#                          of truth (default: <repo>/standards/agent-rate-limits.json,
#                          resolved relative to this file)
#   - $AGENT_RATE_LIMITS_STATE — path to a JSON state document holding per-agent
#                          last-run timestamps, daily counters, and breaker state
#                          (default: unset — treated as empty; degrades to allow)
#   - $SOURCE_NOW        — epoch-seconds override for "now" (testability; default:
#                          `date +%s`)
#   - $DRY_RUN / $DEV_LEAD_DRY_RUN — "true" forces an allow result with no side
#                          effects, after printing the computed decision
#   - `gh` CLI on PATH (for concurrency enumeration), `jq` on PATH
#
# Decision fail-safe direction (ADR §7, post-ADR clarification): malformed,
# missing, or unreadable config/state/telemetry ALLOWS dispatch and logs a
# warning — an outage of a data source must never stop the fleet, which is the
# failure mode this epic exists to prevent. Missing counts degrade to an allowing
# default. (A hard first-hand 429 blocking signal belongs to the token-budget
# breaker of Phases 5/6, not this library.)
#
# Functions are namespaced with the `arl_` prefix to avoid colliding with caller
# helpers.

# Default location of the machine-readable thresholds + exempt list (#638).
# Resolved relative to this library so a caller that sources it from anywhere
# still finds the org single source of truth without hardcoding a path.
ARL_DEFAULT_CONFIG="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/standards/agent-rate-limits.json"

# Stable HTML marker prefix for the deduped, human-clearable open-breaker record
# (mirrors the pr-automation-budget exhaustion marker idiom). The agent type is
# appended so one issue/PR can carry markers for distinct agent types.
ARL_BREAKER_MARKER_PREFIX="<!-- agent-rate-limit-breaker open"

# Human-clearable label a caller applies alongside the marker when the breaker
# opens (mirrors the pr-automation-budget needs-human-review gate). A human
# removes it to acknowledge/clear the open breaker.
ARL_BREAKER_LABEL="needs-human-review"

# ---------------------------------------------------------------------------
# Logging — to stderr so a caller can capture the machine-readable decision on
# stdout without the human-readable reasoning getting in the way.
# ---------------------------------------------------------------------------
arl_log() { printf 'agent-rate-limit: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# arl_config_path — echo the effective config path, honoring $AGENT_RATE_LIMITS_CONFIG.
# ---------------------------------------------------------------------------
arl_config_path() {
  printf '%s' "${AGENT_RATE_LIMITS_CONFIG:-$ARL_DEFAULT_CONFIG}"
}

# ---------------------------------------------------------------------------
# arl_now — current epoch seconds, honoring the $SOURCE_NOW test override.
# ---------------------------------------------------------------------------
arl_now() {
  if [ -n "${SOURCE_NOW:-}" ]; then
    printf '%s' "$SOURCE_NOW"
    return 0
  fi
  date +%s
}

# ---------------------------------------------------------------------------
# arl_is_dry_run — 0 (true) when DRY_RUN or DEV_LEAD_DRY_RUN is "true".
# Each variable is checked independently so DEV_LEAD_DRY_RUN=true is honoured
# even when DRY_RUN is explicitly set to "false" (not merely unset).
# ---------------------------------------------------------------------------
arl_is_dry_run() {
  [ "${DRY_RUN:-false}" = "true" ] || [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]
}

# ---------------------------------------------------------------------------
# arl_sanitize_int <value> [default] — echo <value> when it is a non-negative
# integer, else echo <default> (default 0). The fail-safe integer idiom: a
# malformed count never breaks the numeric gate, it degrades to a value that
# allows (mirrors the pr-automation-budget "degrade malformed input to 0").
# ---------------------------------------------------------------------------
arl_sanitize_int() {
  local value="${1:-}" fallback="${2:-0}"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
  else
    printf '%s' "$fallback"
  fi
}

# ---------------------------------------------------------------------------
# arl_is_exempt_actor <actor> — 0 when <actor> is on the config exempt list.
# Exempt actors (e.g. dependabot[bot], human break-glass) must never be blocked
# or deferred by the rate limits (ADR §8.1, same set as pr-limits).
# ---------------------------------------------------------------------------
arl_is_exempt_actor() {
  local actor="$1" config
  config="$(arl_config_path)"
  if jq -e --arg a "$actor" '(.exempt_actors // []) | index($a) != null' "$config" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# arl_is_exempt_label <labels_csv> — 0 when any label in the comma-separated
# <labels_csv> string appears in the config exempt_labels list. Callers pass the
# labels attached to the triggering PR/issue (e.g. "security,priority-high").
# A security label on a run must never be deferred by rate limits.
# ---------------------------------------------------------------------------
arl_is_exempt_label() {
  local labels_csv="$1" config label
  config="$(arl_config_path)"
  local IFS=','
  for label in $labels_csv; do
    label="${label// /}"
    [ -z "$label" ] && continue
    if jq -e --arg l "$label" '(.exempt_labels // []) | index($l) != null' "$config" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# arl_agent_threshold <agent_type> <key> — echo the numeric threshold <key> for
# <agent_type> from the config, or empty when the value is absent/non-integer.
# An empty result means "no configured limit" and the caller skips that check
# (an unreadable threshold must not block — it degrades to allow).
# ---------------------------------------------------------------------------
arl_agent_threshold() {
  local agent_type="$1" key="$2" config value
  config="$(arl_config_path)"
  value=""
  value="$(jq -er --arg t "$agent_type" --arg k "$key" \
    '(.agent_types[$t][$k])? // empty' "$config" 2>/dev/null || printf '')"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
  fi
}

# ---------------------------------------------------------------------------
# arl_breaker_threshold <agent_type> <key> — echo a numeric circuit_breaker
# threshold <key> for <agent_type>, or empty when absent/non-integer.
# ---------------------------------------------------------------------------
arl_breaker_threshold() {
  local agent_type="$1" key="$2" config value
  config="$(arl_config_path)"
  value=""
  value="$(jq -er --arg t "$agent_type" --arg k "$key" \
    '(.agent_types[$t].circuit_breaker[$k])? // empty' "$config" 2>/dev/null || printf '')"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
  fi
}

# ---------------------------------------------------------------------------
# arl_admission_decision <agent_type> <concurrent> <last_run_epoch> <daily_count>
#                        <now_epoch>
#
# PURE — computes allow/defer from injected counts/timestamps, reading only the
# configured thresholds (no gh, no state I/O), so every branch is unit-testable.
#
# Defers when, for the configured (non-zero) thresholds:
#   - concurrent runs >= max_concurrent_runs, or
#   - a recorded last run is newer than cooldown_minutes, or
#   - today's run count >= daily_run_budget.
# A zero or absent threshold disables that dimension (e.g. cooldown_minutes = 0
# for the weekly-cron agents). Malformed counts degrade to an allowing default.
#
# Prints `decision=allow` / `decision=defer` on stdout; returns 0 on allow, 1 on
# defer.
# ---------------------------------------------------------------------------
arl_admission_decision() {
  local agent_type="$1"
  local concurrent last_run daily_count now
  concurrent="$(arl_sanitize_int "${2:-}")"
  last_run="$(arl_sanitize_int "${3:-}")"
  daily_count="$(arl_sanitize_int "${4:-}")"
  now="$(arl_sanitize_int "${5:-}")"

  local max cooldown daily
  max="$(arl_agent_threshold "$agent_type" max_concurrent_runs)"
  cooldown="$(arl_agent_threshold "$agent_type" cooldown_minutes)"
  daily="$(arl_agent_threshold "$agent_type" daily_run_budget)"

  local decision="allow" reason="under all limits"

  # 1. Concurrency — hard cap on simultaneous runs of this type (counted, never
  #    cancelled; ADR §5).
  if [ -n "$max" ] && [ "$max" -gt 0 ] && [ "$concurrent" -ge "$max" ]; then
    decision="defer"
    reason="concurrency ${concurrent}/${max} at or over max_concurrent_runs"
  fi

  # 2. Cooldown — minimum quiet interval since the last run (kills dispatch
  #    races; ADR §5). Skipped when disabled (0) or when there is no last run.
  #    A future last_run (elapsed < 0) is malformed state — fail open (allow).
  if [ "$decision" = "allow" ] && [ -n "$cooldown" ] && [ "$cooldown" -gt 0 ] && [ "$last_run" -gt 0 ]; then
    local elapsed=$(( now - last_run ))
    local window=$(( cooldown * 60 ))
    if [ "$elapsed" -lt 0 ]; then
      arl_log "warning: last_run_epoch is in the future — skipping cooldown check (degraded allow)"
    elif [ "$elapsed" -lt "$window" ]; then
      decision="defer"
      reason="cooldown ${elapsed}s/${window}s since last run has not elapsed"
    fi
  fi

  # 3. Daily budget — runs (dispatches for initiative-driver) per rolling 24h.
  if [ "$decision" = "allow" ] && [ -n "$daily" ] && [ "$daily" -gt 0 ] && [ "$daily_count" -ge "$daily" ]; then
    decision="defer"
    reason="daily budget ${daily_count}/${daily} at or over daily_run_budget"
  fi

  arl_log "admission for '${agent_type}': ${decision} (${reason})"
  printf 'decision=%s\n' "$decision"
  [ "$decision" = "allow" ] && return 0
  return 1
}

# ---------------------------------------------------------------------------
# arl_breaker_decision <agent_type> <consecutive_failures> <opened_epoch>
#                      <now_epoch> [probe_dispatched_epoch]
#
# PURE — the consecutive-failure circuit breaker (ADR §5). Reads the threshold
# and backoff from config; computes state from injected counters/timestamps.
# [probe_dispatched_epoch] (optional, default 0): epoch when a half-open probe
# was last dispatched. If a probe was recently dispatched (within the backoff
# window), subsequent callers defer instead of admitting a second simultaneous
# probe. Callers are expected to record probe_dispatched_epoch in state after
# a probe is granted.
#
# State machine:
#   - failures < threshold           -> closed    -> allow
#   - failures >= threshold, and the backoff has NOT elapsed since the breaker
#     opened                         -> open      -> defer
#   - failures >= threshold, and the backoff HAS elapsed
#                                     -> half-open -> allow a single probe run
#
# Fail-safe (ADR §7 / AC #4): a malformed failure count degrades to 0 (closed),
# and a malformed/missing threshold or backoff allows (never blocks) — an
# unreadable breaker config must not stop the fleet.
#
# Prints `decision=allow` / `decision=defer` on stdout and logs the breaker state
# to stderr; returns 0 on allow, 1 on defer.
# ---------------------------------------------------------------------------
arl_breaker_decision() {
  local agent_type="$1"
  local failures opened now probe_dispatched
  failures="$(arl_sanitize_int "${2:-}")"
  opened="$(arl_sanitize_int "${3:-}")"
  now="$(arl_sanitize_int "${4:-}")"
  probe_dispatched="$(arl_sanitize_int "${5:-}")"

  local threshold backoff
  threshold="$(arl_breaker_threshold "$agent_type" consecutive_failure_threshold)"
  backoff="$(arl_breaker_threshold "$agent_type" backoff_minutes)"

  # Malformed / missing breaker config -> cannot evaluate -> allow (never block).
  if [ -z "$threshold" ] || [ "$threshold" -le 0 ]; then
    arl_log "breaker for '${agent_type}': state=closed (no usable consecutive_failure_threshold — allowing)"
    printf 'decision=allow\n'
    return 0
  fi

  if [ "$failures" -lt "$threshold" ]; then
    arl_log "breaker for '${agent_type}': state=closed (${failures}/${threshold} consecutive failures)"
    printf 'decision=allow\n'
    return 0
  fi

  # Breaker has tripped. Without a usable backoff we cannot time a half-open
  # probe; degrade to allow rather than block indefinitely on bad config.
  if [ -z "$backoff" ] || [ "$backoff" -le 0 ]; then
    arl_log "breaker for '${agent_type}': state=open but no usable backoff_minutes — allowing (degraded)"
    printf 'decision=allow\n'
    return 0
  fi

  # Just tripped (no opened timestamp recorded yet) -> open, defer.
  if [ "$opened" -le 0 ]; then
    arl_log "breaker for '${agent_type}': state=open (${failures}/${threshold} failures, just tripped)"
    printf 'decision=defer\n'
    return 1
  fi

  local elapsed=$(( now - opened ))
  local window=$(( backoff * 60 ))
  if [ "$elapsed" -lt 0 ]; then
    arl_log "breaker for '${agent_type}': warning: breaker_opened_epoch is in the future — failing open (degraded allow)"
    printf 'decision=allow\n'
    return 0
  fi
  if [ "$elapsed" -lt "$window" ]; then
    arl_log "breaker for '${agent_type}': state=open (backoff ${elapsed}s/${window}s not elapsed)"
    printf 'decision=defer\n'
    return 1
  fi

  # Half-open: allow one probe, but defer if a probe was already dispatched within
  # the backoff window (reduces the race window for simultaneous callers; callers
  # must record probe_dispatched_epoch in state after a probe is granted).
  if [ "$probe_dispatched" -gt 0 ] && [ $(( now - probe_dispatched )) -lt "$window" ]; then
    arl_log "breaker for '${agent_type}': state=half-open but probe already dispatched — deferring"
    printf 'decision=defer\n'
    return 1
  fi
  arl_log "breaker for '${agent_type}': state=half-open (backoff ${elapsed}s/${window}s elapsed — allowing one probe)"
  printf 'decision=allow\n'
  return 0
}

# ---------------------------------------------------------------------------
# arl_breaker_marker <agent_type> — echo the stable, deduped HTML marker recording
# that the breaker is open for <agent_type> (the pr-automation-budget marker
# idiom). A caller posts this once on the tracking issue/PR when the breaker
# opens; a human clears it.
# ---------------------------------------------------------------------------
arl_breaker_marker() {
  local agent_type="$1"
  printf '%s: %s -->' "$ARL_BREAKER_MARKER_PREFIX" "$agent_type"
}

# ---------------------------------------------------------------------------
# arl_should_escalate <existing_body> <agent_type> — 0 (true) when the open-breaker
# marker for <agent_type> is NOT already present in <existing_body>, so the caller
# should post it; 1 (false) when it is already present, so the caller dedups and
# does nothing (mirrors the pr-automation-budget deduped escalation).
# ---------------------------------------------------------------------------
arl_should_escalate() {
  local existing_body="$1" agent_type="$2" marker
  marker="$(arl_breaker_marker "$agent_type")"
  case "$existing_body" in
    *"$marker"*) return 1 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# arl_breaker_label — echo the human-clearable label a caller applies alongside
# the open-breaker marker (the pr-automation-budget needs-human-review gate). A
# human removes the label to acknowledge/clear the open breaker. Exposed as an
# accessor so the Phase-4 wiring reads it from the library rather than restating
# the string.
# ---------------------------------------------------------------------------
arl_breaker_label() {
  printf '%s' "$ARL_BREAKER_LABEL"
}

# ---------------------------------------------------------------------------
# arl_state_path — echo the effective state path, honoring $AGENT_RATE_LIMITS_STATE.
# May be empty (no state backend configured); callers degrade to defaults.
# ---------------------------------------------------------------------------
arl_state_path() {
  printf '%s' "${AGENT_RATE_LIMITS_STATE:-}"
}

# ---------------------------------------------------------------------------
# arl_load_state — echo the state document as JSON. A missing, empty, or
# malformed state file degrades to `{}` (with a warning), so every downstream
# count reads its allowing default rather than crashing the caller (AC #4).
# ---------------------------------------------------------------------------
arl_load_state() {
  local path
  path="$(arl_state_path)"
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    printf '{}'
    return 0
  fi
  local raw
  raw="$(cat "$path" 2>/dev/null || printf '')"
  if [ -z "$raw" ] || ! jq -e . <<<"$raw" >/dev/null 2>&1; then
    arl_log "warning: agent-rate-limit state at '$path' is missing or malformed — treating as empty"
    printf '{}'
    return 0
  fi
  printf '%s' "$raw"
}

# ---------------------------------------------------------------------------
# arl_state_field <state_json> <agent_type> <field> [default] — PURE. Echo the
# per-agent state <field> from the injected state JSON, or [default] (0) when
# absent/malformed.
# ---------------------------------------------------------------------------
arl_state_field() {
  local state_json="$1" agent_type="$2" field="$3" fallback="${4:-0}" value
  value=""
  if [ -n "$state_json" ]; then
    value="$(jq -er --arg t "$agent_type" --arg f "$field" \
      '(.[$t][$f])? // empty' <<<"$state_json" 2>/dev/null || printf '')"
  fi
  arl_sanitize_int "$value" "$fallback"
}

# ---------------------------------------------------------------------------
# arl_count_concurrent_runs <agent_type> — count this agent type's in-flight
# (queued or in-progress) workflow runs via `gh run list`. Echoes the integer
# count on stdout. Fail-safe: a `gh` failure or empty payload logs and yields 0,
# so a transient API error degrades to allow rather than wedging dispatch.
#
# NOTE: `gh run list` scopes to the current repository by default, so this
# count cannot enforce org-wide concurrent limits on its own. Set
# AGENT_RATE_LIMITS_ORG_REPOS to a comma-separated list of "owner/repo" values
# to include additional repos in the tally (Phase-4 wiring responsibility).
# ---------------------------------------------------------------------------
arl_count_concurrent_runs() {
  local agent_type="$1"
  local total=0 runs n

  runs="$(gh run list --workflow "$agent_type" --json status --limit 1000 2>/dev/null || true)"
  if [ -z "$runs" ]; then
    arl_log "warning: run enumeration for '${agent_type}' returned no data (treating concurrency as 0)"
  else
    n="$(jq -r '[.[]? | select((.status // "") == "in_progress" or (.status // "") == "queued")] | length' \
      <<<"$runs" 2>/dev/null || printf '0')"
    total=$(( total + $(arl_sanitize_int "$n") ))
  fi

  # Extend to additional repos for org-wide enforcement when configured.
  if [ -n "${AGENT_RATE_LIMITS_ORG_REPOS:-}" ]; then
    local repo
    IFS=',' read -ra _arl_repos <<< "$AGENT_RATE_LIMITS_ORG_REPOS"
    for repo in "${_arl_repos[@]}"; do
      repo="${repo// /}"
      [ -z "$repo" ] && continue
      runs="$(gh run list --repo "$repo" --workflow "$agent_type" --json status --limit 1000 2>/dev/null || true)"
      if [ -n "$runs" ]; then
        n="$(jq -r '[.[]? | select((.status // "") == "in_progress" or (.status // "") == "queued")] | length' \
          <<<"$runs" 2>/dev/null || printf '0')"
        total=$(( total + $(arl_sanitize_int "$n") ))
      fi
    done
  fi

  printf '%s' "$total"
  return 0
}

# ===========================================================================
# Org-wide token-budget circuit breaker (#641, Phase 5 of epic #636; ADR §7)
# ---------------------------------------------------------------------------
# The PROACTIVE pre-dispatch check the discussion asked for: pause new agentic
# dispatch when the shared, FIXED 5-hour Claude subscription (`session`) window
# is at/over the config-driven pause_threshold_pct (default 90%). Distinct from
# the per-agent-type consecutive-failure breaker above.
#
# Telemetry source of record is the OAuth usage endpoint (ADR §4.1):
#   GET https://api.anthropic.com/api/oauth/usage
#     Authorization: Bearer <CLAUDE_CODE_OAUTH_TOKEN>
#     anthropic-beta: oauth-2025-04-20
#     User-Agent: claude-code/<version>   # load-bearing — omitting it => 429s
# whose credentialed read lives PRIVATE (ADR §8.2). This public library holds
# the thresholds/policy, the pure decision, and a small ADAPTER SEAM the private
# poller plugs the live read into — so no unit test touches the network, and the
# telemetry source can change without editing the gate. The seam speaks a
# normalized envelope so the private side owns only the HTTP call:
#   { "status": <http_status>, "retry_after": <int?>, "body": <raw upstream?> }
# where <raw upstream> carries the ADR §4.1 `limits[]` array (preferred) and/or
# the flattened `five_hour`/`seven_day` keys (fallback for older shapes).
#
# The adapter serves BOTH the `session` (5-hour) and `weekly_all` (7-day)
# windows from one envelope so #994's glide-path breaker extends it rather than
# refactoring (post-ADR clarification #5).
#
# Fail-safe direction (ADR §7): on telemetry error — non-200, malformed body, or
# a missing window entry — the breaker ALLOWS dispatch and logs a warning; an
# outage of an undocumented third-party endpoint must never stop the fleet. The
# one exception: a fresh 429 with a positive retry-after BLOCKS, a hard
# first-hand signal that the cap is already hit.
#
# Scope guard (ADR §2.5): only account-wide windows (`session`, `weekly_all`)
# are pause-worthy; `weekly_scoped` (per-model) never trips a fleet pause.
# ===========================================================================

# Claude-backed agent types prioritized on budget recovery (ADR §7). On recovery
# these clear the backlog first; initiative-driver (which only *causes* Claude
# spend downstream) resumes after them.
ARL_TOKEN_CLAUDE_AGENTS="dev-lead feature-ideation compliance-audit"

# Stable HTML marker prefix for the deduped, human-clearable open-token-breaker
# record (mirrors ARL_BREAKER_MARKER_PREFIX). The window is appended so one
# tracking issue/PR can carry markers for distinct windows.
ARL_TOKEN_BREAKER_MARKER_PREFIX="<!-- agent-token-budget-breaker open"

# ---------------------------------------------------------------------------
# arl_token_pause_threshold <window> — echo the numeric pause_threshold_pct for
# <window> from org_wide.token_budget.limits, or empty when absent/non-integer.
# Empty means "no configured threshold" and the caller degrades to allow (a
# threshold must never be hardcoded — AC #5).
# ---------------------------------------------------------------------------
arl_token_pause_threshold() {
  local window="$1" config value
  config="$(arl_config_path)"
  value="$(jq -er --arg w "$window" \
    '(.org_wide.token_budget.limits[$w].pause_threshold_pct)? // empty' "$config" 2>/dev/null || printf '')"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
  fi
}

# ---------------------------------------------------------------------------
# arl_token_window_pause_worthy <window> — echo "true" when <window> is flagged
# pause_worthy in config, else "false". A missing/false flag degrades to
# "false" (never pause-worthy) — the scope guard defaults closed to a fleet
# pause, not open.
# ---------------------------------------------------------------------------
arl_token_window_pause_worthy() {
  local window="$1" config value
  config="$(arl_config_path)"
  value="$(jq -r --arg w "$window" \
    '(.org_wide.token_budget.limits[$w].pause_worthy) // false' "$config" 2>/dev/null || printf 'false')"
  case "$value" in
    true) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

# ---------------------------------------------------------------------------
# arl_token_claude_priority — echo "true"/"false" for the claude_priority flag.
# ---------------------------------------------------------------------------
arl_token_claude_priority() {
  local config value
  config="$(arl_config_path)"
  value="$(jq -r '(.org_wide.token_budget.claude_priority) // false' "$config" 2>/dev/null || printf 'false')"
  case "$value" in
    true) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

# ---------------------------------------------------------------------------
# arl_token_priority_rank <agent_type> — echo a recovery priority rank: 0 for
# Claude-backed agents (prioritized on recovery), 1 for the rest, when
# claude_priority is on. When the flag is off, every agent collapses to rank 0
# (no prioritization). Lower rank == earlier on the recovering budget (AC #3).
# ---------------------------------------------------------------------------
arl_token_priority_rank() {
  local agent_type="$1" a
  if [ "$(arl_token_claude_priority)" != "true" ]; then
    printf '0'
    return 0
  fi
  for a in $ARL_TOKEN_CLAUDE_AGENTS; do
    if [ "$a" = "$agent_type" ]; then
      printf '0'
      return 0
    fi
  done
  printf '1'
}

# ---------------------------------------------------------------------------
# arl_token_fetch_envelope — echo the normalized telemetry envelope from the
# adapter seam. The private poller plugs the live OAuth read into one of:
#   $AGENT_TOKEN_BUDGET_TELEMETRY_CMD  — a command whose stdout is the envelope
#   $AGENT_TOKEN_BUDGET_TELEMETRY_FILE — a file holding the envelope JSON
# With neither configured, or on a malformed/empty payload, echoes
# {"status":0} so the orchestrator fails safe (allow) — this is the documented
# degraded / shipped-disabled mode (AC #6).
# ---------------------------------------------------------------------------
arl_token_fetch_envelope() {
  local raw=""
  if [ -n "${AGENT_TOKEN_BUDGET_TELEMETRY_CMD:-}" ]; then
    local _timeout="${AGENT_TOKEN_BUDGET_TELEMETRY_TIMEOUT:-10}"
    raw="$(timeout "$_timeout" bash -c "$AGENT_TOKEN_BUDGET_TELEMETRY_CMD" 2>/dev/null || printf '')"
  elif [ -n "${AGENT_TOKEN_BUDGET_TELEMETRY_FILE:-}" ] && [ -f "${AGENT_TOKEN_BUDGET_TELEMETRY_FILE}" ]; then
    raw="$(cat "$AGENT_TOKEN_BUDGET_TELEMETRY_FILE" 2>/dev/null || printf '')"
  fi
  if [ -z "$raw" ] || ! jq -e . <<<"$raw" >/dev/null 2>&1; then
    printf '{"status":0}'
    return 0
  fi
  printf '%s' "$raw"
}

# ---------------------------------------------------------------------------
# arl_token_extract_percent <body_json> <window> — PURE. Echo the integer
# percent for <window> from a telemetry body, preferring the ADR §4.1 `limits[]`
# entry (matched on `kind`) and falling back to the flattened key
# (session -> five_hour, weekly_all -> seven_day). A fractional percent is
# floored (conservative: 89.9 does not trip a 90 threshold). Echoes empty when
# the window is absent from both shapes (the caller degrades to allow).
# ---------------------------------------------------------------------------
arl_token_extract_percent() {
  local body="$1" window="$2" flat value
  case "$window" in
    session) flat="five_hour" ;;
    weekly_all) flat="seven_day" ;;
    *) flat="" ;;
  esac
  value="$(jq -r --arg k "$window" --arg f "$flat" '
    ( [ .limits[]? | select(.kind == $k) | .percent ] | .[0] ) as $from_limits
    | ( if $from_limits != null then $from_limits
        elif ($f != "" and (.[$f].percent? != null)) then .[$f].percent
        else null end )
    | if . == null then empty else (. | floor) end
  ' <<<"$body" 2>/dev/null || printf '')"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
  fi
}

# ---------------------------------------------------------------------------
# arl_token_window_active <body_json> <window> — PURE. Echo "false" only when
# the <window> `limits[]` entry is explicitly is_active=false; otherwise "true"
# (a window with no entry or no is_active field is treated as active/binding).
# An inactive window is not binding and never defers.
# ---------------------------------------------------------------------------
arl_token_window_active() {
  local body="$1" window="$2" value
  value="$(jq -r --arg k "$window" '
    ( [ .limits[]? | select(.kind == $k) | .is_active ] | .[0] ) as $a
    | if $a == null then true else $a end
  ' <<<"$body" 2>/dev/null || printf 'true')"
  case "$value" in
    false) printf 'false' ;;
    *) printf 'true' ;;
  esac
}

# ---------------------------------------------------------------------------
# arl_token_budget_decision <percent> <threshold> <pause_worthy> — PURE core.
# Defers when the window is pause-worthy and <percent> >= <threshold>; else
# allows. A non-pause-worthy window, an unreadable threshold, or a malformed
# percent all degrade to allow (fail-safe). Prints decision=allow/defer;
# returns 0 on allow, 1 on defer.
# ---------------------------------------------------------------------------
arl_token_budget_decision() {
  local percent threshold pause_worthy
  percent="$(arl_sanitize_int "${1:-}")"
  threshold="${2:-}"
  pause_worthy="${3:-}"

  if [ "$pause_worthy" != "true" ]; then
    arl_log "token-budget: window is not pause-worthy — allowing (scope guard)"
    printf 'decision=allow\n'
    return 0
  fi
  if ! [[ "$threshold" =~ ^[0-9]+$ ]] || [ "$threshold" -le 0 ]; then
    arl_log "token-budget: no usable pause_threshold_pct — allowing (degraded)"
    printf 'decision=allow\n'
    return 0
  fi

  local decision="allow" reason="budget ${percent}% under ${threshold}% threshold"
  if [ "$percent" -ge "$threshold" ]; then
    decision="defer"
    reason="budget ${percent}% at or over ${threshold}% threshold"
  fi
  arl_log "token-budget decision: ${decision} (${reason})"
  printf 'decision=%s\n' "$decision"
  [ "$decision" = "allow" ] && return 0
  return 1
}

# ---------------------------------------------------------------------------
# arl_token_transport_decision <envelope_json> <now_epoch> — PURE-ish. The
# telemetry-TRANSPORT-level fail-safe shared by BOTH the session and weekly-glide
# breakers, so there is exactly one 429 / non-200 convention (post-ADR #1). Echoes
# exactly one token on stdout:
#   defer   — a fresh, unexpired 429 with a positive retry-after (the one hard,
#             first-hand cap signal that BLOCKS; ADR §7). A stale 429 whose
#             retry_until (or observed_at + retry_after) has already passed is
#             treated as expired degraded telemetry and allows instead.
#   allow   — any other non-200 / unavailable telemetry (fail-safe with warning).
#   proceed — a usable 200 body; the caller inspects `.body` for the window.
# Logs the human-readable reason to stderr. Returns 0 always.
# ---------------------------------------------------------------------------
arl_token_transport_decision() {
  local envelope="$1" now status retry_after
  now="$(arl_sanitize_int "${2:-}")"
  status="$(arl_sanitize_int "$(jq -r '.status? // 0' <<<"$envelope" 2>/dev/null || printf '0')")"

  # Fresh 429 with a positive retry-after: the one telemetry response that
  # blocks (ADR §7). An observation timestamp (observed_at) or absolute deadline
  # (retry_until) in the envelope guards against a stale file deferring forever:
  # if the deadline has already passed, treat it as expired degraded telemetry.
  if [ "$status" -eq 429 ]; then
    retry_after="$(arl_sanitize_int "$(jq -r '.retry_after? // 0' <<<"$envelope" 2>/dev/null || printf '0')")"
    if [ "$retry_after" -gt 0 ]; then
      local retry_deadline observed_at
      retry_deadline="$(arl_sanitize_int "$(jq -r '.retry_until? // 0' <<<"$envelope" 2>/dev/null || printf '0')")"
      if [ "$retry_deadline" -eq 0 ]; then
        observed_at="$(arl_sanitize_int "$(jq -r '.observed_at? // 0' <<<"$envelope" 2>/dev/null || printf '0')")"
        if [ "$observed_at" -gt 0 ]; then
          retry_deadline=$(( observed_at + retry_after ))
        fi
      fi
      if [ "$retry_deadline" -eq 0 ]; then
        arl_log "warning: token-budget 429 has no deadline anchor (no retry_until/observed_at) — treating as stale, allowing dispatch (degraded)"
        printf 'allow'
        return 0
      fi
      if [ "$now" -ge "$retry_deadline" ]; then
        arl_log "warning: token-budget 429 retry window expired (deadline=${retry_deadline}, now=${now}) — allowing dispatch (degraded)"
        printf 'allow'
        return 0
      fi
      arl_log "token-budget: fresh 429 with retry-after=${retry_after}s — deferring (hard cap signal)"
      printf 'defer'
      return 0
    fi
  fi

  # Any other non-200 fails safe: allow-with-warning.
  if [ "$status" -ne 200 ]; then
    arl_log "warning: token-budget telemetry unavailable (status=${status}) — allowing dispatch (degraded)"
    printf 'allow'
    return 0
  fi

  printf 'proceed'
}

# ---------------------------------------------------------------------------
# arl_token_budget_gate [window] — orchestrate the token-budget breaker for
# <window> (default: session). Reads the config threshold, consults the
# telemetry adapter seam, and emits decision=allow/defer.
#
# Decision order:
#   1. Window not pause-worthy (e.g. weekly_scoped) -> allow (scope guard)
#   2. No configured threshold                       -> allow (degraded)
#   3. Fresh 429 + retry-after                       -> defer (hard cap signal)
#   4. Any other non-200 / unavailable telemetry     -> allow-with-warning
#   5. Window explicitly inactive                    -> allow (not binding)
#   6. Missing window entry in a 200 body            -> allow-with-warning
#   7. percent >= threshold                          -> defer, else allow
#
# Returns 0 on allow, 1 on defer. Guard-only: reads telemetry, never mutates.
# ---------------------------------------------------------------------------
arl_token_budget_gate() {
  local window="${1:-session}"

  local pause_worthy threshold
  pause_worthy="$(arl_token_window_pause_worthy "$window")"
  if [ "$pause_worthy" != "true" ]; then
    arl_log "token-budget: window '${window}' is not pause-worthy — allowing (scope guard)"
    printf 'decision=allow\n'
    return 0
  fi
  threshold="$(arl_token_pause_threshold "$window")"
  if [ -z "$threshold" ]; then
    arl_log "token-budget: no configured pause_threshold_pct for '${window}' — allowing (degraded)"
    printf 'decision=allow\n'
    return 0
  fi

  local now envelope transport body
  now="$(arl_now)"
  envelope="${2:-$(arl_token_fetch_envelope)}"

  # Shared transport-level fail-safe (429 / non-200) — one convention for both
  # breakers.
  transport="$(arl_token_transport_decision "$envelope" "$now")"
  case "$transport" in
    defer)  printf 'decision=defer\n'; return 1 ;;
    allow)  printf 'decision=allow\n'; return 0 ;;
  esac

  body="$(jq -c '.body? // {}' <<<"$envelope" 2>/dev/null || printf '{}')"

  if [ "$(arl_token_window_active "$body" "$window")" = "false" ]; then
    arl_log "token-budget: window '${window}' is not active — allowing (not binding)"
    printf 'decision=allow\n'
    return 0
  fi

  local percent
  percent="$(arl_token_extract_percent "$body" "$window")"
  if [ -z "$percent" ]; then
    arl_log "warning: token-budget telemetry has no '${window}' window entry — allowing dispatch (degraded)"
    printf 'decision=allow\n'
    return 0
  fi

  arl_token_budget_decision "$percent" "$threshold" "true"
}

# ===========================================================================
# Weekly-budget GLIDE-PATH breaker (#994, Phase 6 of epic #636; ADR §7)
# ---------------------------------------------------------------------------
# The orthogonal, TIME-VARYING control on the account-wide `weekly_all` (7-day,
# FIXED) window that the static session breaker cannot express: pause new dispatch
# when
#     weekly_all.percent >= clamp(ceiling_pct - reserve_pct_per_day * days_until_reset,
#                                 floor_pct, ceiling_pct)
# so the fleet reserves ~reserve_pct_per_day% of the weekly budget per remaining
# day and cannot burn the whole week in the first two days. Every number is read
# from config (org_wide.token_budget.limits.weekly_all) — no threshold, slope, or
# weekday is hardcoded (AC #1).
#
# What makes this breaker DIFFERENT from the session breaker (keep this explicit):
# it CAN close before `resets_at` — but never because utilization fell. Within a
# fixed window percent is monotonically non-decreasing; the glide-path threshold
# RISES as the reset approaches, so each poll re-evaluates statelessly and the
# breaker may close because the THRESHOLD moved past a static percent, not because
# usage dipped. There is deliberately NO percentage resume mark (conflating this
# with the session breaker's "resets_at only" rule in either direction is the bug
# to avoid). Because each poll is a fresh, stateless re-evaluation, no persistent
# trip state is stored and a downward percentage dip (which cannot occur in a
# fixed window) is structurally unable to un-trip it.
#
# Reuses Phase 5's telemetry adapter (one call serves both windows), the shared
# transport-level fail-safe (arl_token_transport_decision), the percent extractor,
# the is_active check, the pause-worthy scope guard, and the pure decision core.
# ===========================================================================

# ---------------------------------------------------------------------------
# arl_token_glide_int <key> — echo a numeric weekly_all glide <key> from config,
# or empty when absent/non-integer (the caller degrades to allow — a threshold
# must never be hardcoded, AC #1).
# ---------------------------------------------------------------------------
arl_token_glide_int() {
  local key="$1" config value
  config="$(arl_config_path)"
  value="$(jq -er --arg k "$key" \
    '(.org_wide.token_budget.limits.weekly_all[$k])? // empty' "$config" 2>/dev/null || printf '')"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
  fi
}

arl_token_glide_reserve() { arl_token_glide_int reserve_pct_per_day; }
arl_token_glide_floor()   { arl_token_glide_int floor_pct; }
arl_token_glide_ceiling() { arl_token_glide_int ceiling_pct; }

# ---------------------------------------------------------------------------
# arl_token_glide_enabled — echo "true"/"false" for the weekly_all.enabled config
# arm. Missing/false degrades to "false" (inert): the glide breaker stays off
# until a maintainer arms it in config, independent of the AGENT_TOKEN_BUDGET_ENABLED
# env flag that arms integration (staged rollout, AC #6/#7).
# ---------------------------------------------------------------------------
arl_token_glide_enabled() {
  local config value
  config="$(arl_config_path)"
  value=""
  if [ -n "$config" ]; then
    value="$(jq -r '(.org_wide.token_budget.limits.weekly_all.enabled)? // "false"' "$config" 2>/dev/null || printf 'false')"
  fi
  case "$value" in
    true) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

# ---------------------------------------------------------------------------
# arl_token_iso_to_epoch <iso8601> — echo the epoch seconds for an ISO-8601
# timestamp (the telemetry `resets_at`), or empty when unparseable. Kept separate
# from the pure day arithmetic so parsing (date-dependent) and the round-up rule
# (pure, unit-tested) do not entangle.
# ---------------------------------------------------------------------------
arl_token_iso_to_epoch() {
  local iso="${1:-}" epoch
  [ -z "$iso" ] && return 0
  # Require an explicit timezone offset (Z or ±HH:MM) so date -d does not
  # silently interpret a timezone-less value as local time.
  if [[ ! "$iso" =~ (Z|[+-][0-9]{2}:[0-9]{2})$ ]]; then
    return 0
  fi
  epoch="$(date -d "$iso" +%s 2>/dev/null || printf '')"
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 0
  # Round-trip: if date normalised an invalid calendar date (e.g. Feb 30 → Mar 2)
  # the reconstructed YYYY-MM-DD will not match the input prefix — reject it.
  local reconstructed_date
  reconstructed_date="$(date -u -d "@$epoch" +%Y-%m-%d 2>/dev/null || printf '')"
  [ "$reconstructed_date" = "${iso:0:10}" ] || return 0
  printf '%s' "$epoch"
}

# ---------------------------------------------------------------------------
# arl_token_days_until_reset <reset_epoch> <now_epoch> — PURE. Echo the whole
# days remaining until the reset, rounding a PARTIAL day UP (AC #2): the day
# before reset evaluates as 1 day left, not 0, so the reserve is held for any
# fraction of a day that remains. At or after the reset instant echoes 0.
# ---------------------------------------------------------------------------
arl_token_days_until_reset() {
  local reset now diff
  reset="$(arl_sanitize_int "${1:-}")"
  now="$(arl_sanitize_int "${2:-}")"
  diff=$(( reset - now ))
  if [ "$diff" -le 0 ]; then
    printf '0'
    return 0
  fi
  # Ceiling division by 86400 (integer): (diff + 86399) / 86400.
  printf '%s' "$(( (diff + 86399) / 86400 ))"
}

# ---------------------------------------------------------------------------
# arl_token_glide_threshold <days_until_reset> <reserve_pct_per_day> <floor_pct>
#                           <ceiling_pct> — PURE. Echo the glide-path pause
# threshold: clamp(ceiling - reserve*days, floor, ceiling). The threshold RISES
# toward the ceiling as the reset approaches (fewer days left) and is held at the
# floor far from the reset (the "don't spend the whole week on day one" guard).
# ---------------------------------------------------------------------------
arl_token_glide_threshold() {
  local days reserve floor ceiling raw
  days="$(arl_sanitize_int "${1:-}")"
  reserve="$(arl_sanitize_int "${2:-}")"
  floor="$(arl_sanitize_int "${3:-}")"
  ceiling="$(arl_sanitize_int "${4:-}")"
  raw=$(( ceiling - reserve * days ))
  if [ "$raw" -gt "$ceiling" ]; then raw="$ceiling"; fi
  if [ "$raw" -lt "$floor" ]; then raw="$floor"; fi
  printf '%s' "$raw"
}

# ---------------------------------------------------------------------------
# arl_token_extract_resets_at <body_json> <window> — PURE. Echo the ISO `resets_at`
# for <window>, preferring the ADR §4.1 limits[] entry (matched on kind) and
# falling back to the flattened key (weekly_all -> seven_day). Empty when absent
# (the caller degrades to allow — days_until_reset cannot be computed).
# ---------------------------------------------------------------------------
arl_token_extract_resets_at() {
  local body="$1" window="$2" flat value
  case "$window" in
    session) flat="five_hour" ;;
    weekly_all) flat="seven_day" ;;
    *) flat="" ;;
  esac
  value="$(jq -r --arg k "$window" --arg f "$flat" '
    ( [ .limits[]? | select(.kind == $k) | .resets_at ] | .[0] ) as $from_limits
    | ( if $from_limits != null then $from_limits
        elif ($f != "" and (.[$f].resets_at? != null)) then .[$f].resets_at
        else null end )
    | if . == null then empty else . end
  ' <<<"$body" 2>/dev/null || printf '')"
  if [ -n "$value" ]; then
    printf '%s' "$value"
  fi
}

# ---------------------------------------------------------------------------
# arl_token_glide_trip_reason <percent> <threshold> <days> <resets_at> — echo a
# compact, MACHINE-READABLE trip reason (AC #4): which window, the observed
# percent, the computed threshold, the days until reset, and the reset timestamp
# — so the reason is a parseable object, not prose buried in a log line.
# ---------------------------------------------------------------------------
arl_token_glide_trip_reason() {
  local percent threshold days resets_at
  percent="$(arl_sanitize_int "${1:-}")"
  threshold="$(arl_sanitize_int "${2:-}")"
  days="$(arl_sanitize_int "${3:-}")"
  resets_at="${4:-}"
  jq -cn \
    --arg w "weekly_all" \
    --argjson p "$percent" \
    --argjson t "$threshold" \
    --argjson d "$days" \
    --arg r "$resets_at" \
    '{window: $w, observed_percent: $p, threshold_pct: $t, days_until_reset: $d, resets_at: $r}'
}

# ---------------------------------------------------------------------------
# arl_token_weekly_glide_gate — orchestrate the weekly glide-path breaker for the
# account-wide `weekly_all` window. Reads the glide config, consults the shared
# telemetry adapter seam, derives days_until_reset from the payload's `resets_at`,
# computes the time-varying threshold, and emits decision=allow/defer.
#
# Decision order:
#   1. Config weekly_all.enabled != true            -> allow (inert; config arm)
#   2. weekly_all not pause-worthy                   -> allow (scope guard)
#   3. Incomplete glide config (reserve/floor/ceil)  -> allow (degraded)
#   4. Fresh 429 + retry-after                       -> defer (hard cap signal)
#   5. Any other non-200 / unavailable telemetry     -> allow-with-warning
#   6. weekly_all explicitly inactive                -> allow (not binding)
#   7. Missing weekly_all percent in a 200 body      -> allow-with-warning
#   8. Missing / unparseable resets_at               -> allow-with-warning
#   9. percent >= glide threshold                    -> defer, else allow
#
# Returns 0 on allow, 1 on defer. Guard-only: reads telemetry, never mutates.
# ---------------------------------------------------------------------------
arl_token_weekly_glide_gate() {
  local window="weekly_all"

  # 1. Config-level arm — inert until a maintainer enables it in config, even
  #    when the integration env flag is on (staged dry-run rollout, AC #7).
  if [ "$(arl_token_glide_enabled)" != "true" ]; then
    arl_log "token-budget weekly-glide: not enabled in config (weekly_all.enabled) — allowing (inert)"
    printf 'decision=allow\n'
    return 0
  fi

  # 2. Scope guard — only the account-wide window is pause-worthy (ADR §2.5).
  if [ "$(arl_token_window_pause_worthy "$window")" != "true" ]; then
    arl_log "token-budget weekly-glide: window '${window}' is not pause-worthy — allowing (scope guard)"
    printf 'decision=allow\n'
    return 0
  fi

  # 3. The schedule must be fully expressible from config; a missing part
  #    degrades to allow rather than hardcoding a fallback (AC #1).
  local reserve floor ceiling
  reserve="$(arl_token_glide_reserve)"
  floor="$(arl_token_glide_floor)"
  ceiling="$(arl_token_glide_ceiling)"
  if [ -z "$reserve" ] || [ -z "$floor" ] || [ -z "$ceiling" ]; then
    arl_log "token-budget weekly-glide: incomplete glide config (reserve/floor/ceiling) — allowing (degraded)"
    printf 'decision=allow\n'
    return 0
  fi

  local now envelope transport body
  now="$(arl_now)"
  envelope="${1:-$(arl_token_fetch_envelope)}"

  # 4/5. Shared transport-level fail-safe (429 / non-200) — one convention.
  transport="$(arl_token_transport_decision "$envelope" "$now")"
  case "$transport" in
    defer)  printf 'decision=defer\n'; return 1 ;;
    allow)  printf 'decision=allow\n'; return 0 ;;
  esac

  body="$(jq -c '.body? // {}' <<<"$envelope" 2>/dev/null || printf '{}')"

  # 6. An inactive window is not binding.
  if [ "$(arl_token_window_active "$body" "$window")" = "false" ]; then
    arl_log "token-budget weekly-glide: window '${window}' is not active — allowing (not binding)"
    printf 'decision=allow\n'
    return 0
  fi

  # 7. Missing percent -> cannot evaluate -> allow-with-warning (AC #5).
  local percent
  percent="$(arl_token_extract_percent "$body" "$window")"
  if [ -z "$percent" ]; then
    arl_log "warning: token-budget weekly-glide telemetry has no '${window}' window entry — allowing dispatch (degraded)"
    printf 'decision=allow\n'
    return 0
  fi

  # 8. days_until_reset derives from the authoritative resets_at, never a
  #    hardcoded weekday (AC #2). A missing/unparseable value fails safe.
  local resets_at reset_epoch
  resets_at="$(arl_token_extract_resets_at "$body" "$window")"
  if [ -z "$resets_at" ]; then
    arl_log "warning: token-budget weekly-glide telemetry has no resets_at for '${window}' — allowing dispatch (degraded)"
    printf 'decision=allow\n'
    return 0
  fi
  reset_epoch="$(arl_token_iso_to_epoch "$resets_at")"
  if [ -z "$reset_epoch" ]; then
    arl_log "warning: token-budget weekly-glide could not parse resets_at='${resets_at}' — allowing dispatch (degraded)"
    printf 'decision=allow\n'
    return 0
  fi

  # 9. Compute the time-varying threshold and evaluate (reusing the pure core).
  local days threshold decision_out
  days="$(arl_token_days_until_reset "$reset_epoch" "$now")"
  threshold="$(arl_token_glide_threshold "$days" "$reserve" "$floor" "$ceiling")"
  arl_log "token-budget weekly-glide: ${days} day(s) until reset (${resets_at}) -> threshold ${threshold}% vs observed ${percent}%"

  # `|| true`: the pure core returns non-zero on defer; the decision rides in
  # stdout — neutralize the exit so a `set -e` caller is not aborted here.
  decision_out="$(arl_token_budget_decision "$percent" "$threshold" "true")" || true
  if [ "$decision_out" = "decision=defer" ]; then
    arl_log "token-budget weekly-glide TRIP: $(arl_token_glide_trip_reason "$percent" "$threshold" "$days" "$resets_at")"
    printf 'decision=defer\n'
    return 1
  fi
  printf 'decision=allow\n'
  return 0
}

# ---------------------------------------------------------------------------
# arl_token_breaker_marker <window> — echo the stable, deduped HTML marker
# recording that the token-budget breaker is open for <window> (mirrors
# arl_breaker_marker). A caller posts it once on the tracking issue/PR when the
# breaker trips; a human clears it (alongside removing arl_breaker_label).
# ---------------------------------------------------------------------------
arl_token_breaker_marker() {
  local window="$1"
  printf '%s: %s -->' "$ARL_TOKEN_BREAKER_MARKER_PREFIX" "$window"
}

# ---------------------------------------------------------------------------
# arl_token_should_escalate <existing_body> <window> — 0 (true) when the
# open-token-breaker marker for <window> is NOT already present in
# <existing_body> (so the caller posts it); 1 (false) when present (dedup).
# ---------------------------------------------------------------------------
arl_token_should_escalate() {
  local existing_body="$1" window="$2" marker
  marker="$(arl_token_breaker_marker "$window")"
  case "$existing_body" in
    *"$marker"*) return 1 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# arl_finish <agent_type> <decision> <reason> — emit the result and set the
# return code, applying the dry-run override. Internal helper for
# arl_admission_gate (mirrors plg_finish).
# ---------------------------------------------------------------------------
arl_finish() {
  local agent_type="$1" decision="$2" reason="$3"

  if arl_is_dry_run; then
    arl_log "DRY_RUN — computed decision=${decision} for '${agent_type}' (${reason}); returning allow, no side effects"
    printf 'decision=allow\n'
    return 0
  fi

  arl_log "decision=${decision} for '${agent_type}' (${reason})"
  printf 'decision=%s\n' "$decision"

  [ "$decision" = "allow" ] && return 0
  return 1
}

# ---------------------------------------------------------------------------
# arl_admission_gate <agent_type> [actor] [labels_csv] — the guard.
#
# Decides whether <agent_type> may dispatch another run right now. [actor] is the
# candidate triggering identity (e.g. an actor login); [labels_csv] is a
# comma-separated list of labels on the triggering PR/issue (e.g. "security").
# An exempt actor or an exempt label always allows and is never counted (ADR §8.1).
#
# Decision order:
#   1. Missing/malformed config               -> allow (never block the fleet; AC #4)
#   2. Exempt actor or exempt label            -> allow (never blocked, never counted)
#   3. Open consecutive-failure breaker        -> defer (evaluated before admission)
#   4. Admission (concurrency/cooldown/daily)  -> allow or defer
#
# Prints `decision=allow` / `decision=defer`; returns 0 on allow, 1 on defer, 2
# on a usage error (no agent type given). DRY_RUN / DEV_LEAD_DRY_RUN prints the
# computed decision then returns allow with no side effects.
# ---------------------------------------------------------------------------
arl_admission_gate() {
  local agent_type="${1:-}" actor="${2:-}" labels="${3:-}"
  if [ -z "$agent_type" ]; then
    arl_log "error: arl_admission_gate requires an <agent_type> argument"
    return 2
  fi

  # 1. Missing / malformed config degrades to allow (ADR §7 / AC #4): an outage of
  #    the config source must never stop the fleet.
  local config
  config="$(arl_config_path)"
  if [ ! -f "$config" ] || ! jq -e . "$config" >/dev/null 2>&1; then
    arl_log "warning: config at '$config' is missing or malformed — allowing dispatch (degraded)"
    arl_finish "$agent_type" "allow" "config unreadable — degraded allow"
    return $?
  fi

  # 2. Exempt actors and exempt labels are always allowed and never counted.
  if [ -n "$actor" ] && arl_is_exempt_actor "$actor"; then
    arl_finish "$agent_type" "allow" "actor '${actor}' is exempt (not subject to the limits)"
    return $?
  fi
  if [ -n "$labels" ] && arl_is_exempt_label "$labels"; then
    arl_finish "$agent_type" "allow" "run carries an exempt label (not subject to the limits)"
    return $?
  fi

  # 2.5 Org-wide token-budget breaker (Phase 5, #641). INERT unless explicitly
  #     enabled (canary/dry-run rollout, AC #5): when off it reads no telemetry
  #     and does not affect the decision, keeping the provisional config inert
  #     until human sign-off. When on and the shared 5-hour Claude `session`
  #     window is at/over threshold, dispatch defers before any per-agent
  #     admission check. `|| true`: the decision rides in captured stdout and a
  #     defer returns non-zero — neutralize it so a `set -e` caller is not
  #     aborted before the decision is emitted.
  if [ "${AGENT_TOKEN_BUDGET_ENABLED:-false}" = "true" ]; then
    local token_decision glide_decision shared_envelope
    shared_envelope="$(arl_token_fetch_envelope)"
    token_decision="$(arl_token_budget_gate session "$shared_envelope")" || true
    if [ "$token_decision" = "decision=defer" ]; then
      arl_log "token-budget escalation: $(arl_token_breaker_marker session) — add to tracking issue/PR body, remove when cleared"
      arl_finish "$agent_type" "defer" "org-wide token-budget breaker is open (5-hour Claude session window at/over threshold)"
      return $?
    fi

    # 2.6 Weekly glide-path breaker (Phase 6, #994). Orthogonal to the 5-hour
    #     session breaker: a time-varying threshold on the FIXED 7-day weekly_all
    #     window. Shares the same env arm; the config weekly_all.enabled flag keeps
    #     it inert until sign-off even when this env flag is on. `|| true`: the
    #     decision rides in captured stdout and a defer returns non-zero.
    glide_decision="$(arl_token_weekly_glide_gate "$shared_envelope")" || true
    if [ "$glide_decision" = "decision=defer" ]; then
      arl_log "token-budget escalation: $(arl_token_breaker_marker weekly_all) — add to tracking issue/PR body, remove when cleared"
      arl_finish "$agent_type" "defer" "org-wide token-budget breaker is open (7-day Claude weekly window over glide-path threshold)"
      return $?
    fi
  fi

  local now state
  now="$(arl_now)"
  state="$(arl_load_state)"

  local failures opened probe_dispatched
  failures="$(arl_state_field "$state" "$agent_type" consecutive_failures 0)"
  opened="$(arl_state_field "$state" "$agent_type" breaker_opened_epoch 0)"
  probe_dispatched="$(arl_state_field "$state" "$agent_type" probe_dispatched_epoch 0)"

  # 3. Circuit breaker first — an open breaker defers regardless of admission.
  #    `|| true`: the decision is carried in the captured stdout, and a defer
  #    returns non-zero — neutralize it so a caller running under `set -e` is not
  #    aborted at this assignment before the decision is emitted.
  local breaker
  breaker="$(arl_breaker_decision "$agent_type" "$failures" "$opened" "$now" "$probe_dispatched")" || true
  if [ "$breaker" != "decision=allow" ]; then
    arl_finish "$agent_type" "defer" "consecutive-failure breaker is open"
    return $?
  fi

  # 4. Admission — concurrency / cooldown / daily budget.
  local concurrent last_run daily_count daily_window_start
  concurrent="$(arl_count_concurrent_runs "$agent_type")"
  last_run="$(arl_state_field "$state" "$agent_type" last_run_epoch 0)"
  daily_count="$(arl_state_field "$state" "$agent_type" daily_count 0)"
  daily_window_start="$(arl_state_field "$state" "$agent_type" daily_window_start 0)"
  # Reset daily_count when the recorded window is more than 24 h old so
  # yesterday's usage cannot block runs indefinitely. Callers are expected to
  # persist daily_window_start alongside daily_count when recording a dispatch.
  if [ "$daily_window_start" -gt 0 ] && [ $(( now - daily_window_start )) -ge 86400 ]; then
    arl_log "daily window for '${agent_type}' expired ($(( now - daily_window_start ))s) — resetting daily_count"
    daily_count=0
  fi

  local admission
  # `|| true`: as above — a defer returns non-zero, so neutralize it and read the
  # decision from the captured stdout instead of the exit status.
  # NOTE: this is an observe-then-act check; two concurrent callers on separate
  # GitHub Actions runners can both observe capacity and both receive allow. Full
  # atomic enforcement requires a distributed claim mechanism (e.g. a GitHub
  # Deployment or Environments lock) — that belongs to Phase-4 wiring, not this
  # guard-only library.
  admission="$(arl_admission_decision "$agent_type" "$concurrent" "$last_run" "$daily_count" "$now")" || true
  if [ "$admission" = "decision=allow" ]; then
    arl_finish "$agent_type" "allow" "under all limits with a clean breaker"
    return $?
  fi

  arl_finish "$agent_type" "defer" "an admission limit is at or over cap"
  return $?
}
