#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/agent-rate-limit-gate.sh — dispatch-time orchestrator for the
# source-side agent admission + circuit-breaker gate (#640, Phase 4 of epic #636).
#
# This is the thin I/O glue AGENTS.md ("Decision Logic Lives in a Pure, Tested
# Script") prescribes for the pure gate library scripts/lib/agent-rate-limit.sh:
# an agent-dispatching workflow calls this orchestrator BEFORE it dispatches
# agentic work; the orchestrator gathers facts from run history and feeds them to
# the library's pure decision functions, which read every threshold from the
# single source of truth standards/agent-rate-limits.json (no number is
# hardcoded here — AC #1).
#
# Why derive from run history, not a state file (AC #3): the library's optional
# $AGENT_RATE_LIMITS_STATE backend cannot work on GitHub Actions — runners are
# ephemeral, so a file-backed counter never survives to the next run and the
# breaker could never trip. So this orchestrator DERIVES every counter
# (concurrency, cooldown's last-run, the rolling daily count, and the breaker's
# consecutive_failures) from a single `gh run list` over the agent's recent runs
# — the same run-history primitive scripts/canary-rollout.sh uses in its
# _run_json / _cumulative_health health gate — and passes them into the library's
# pure arl_admission_decision / arl_breaker_decision. It never reads or writes
# AGENT_RATE_LIMITS_STATE.
#
# Canary scope (AC #5): only `initiative-driver` ENFORCES (pure bash, no model
# spend, the direct #443 target). Every other agent type runs in --mode log-only:
# the decision is computed and logged but the emitted decision is always `allow`,
# so nothing is acted on. Promotion path from log-only to enforcing: flip the
# caller workflow's `--mode log-only` to `--mode enforce` for that agent type in a
# discrete follow-up PR (see standards/agent-rate-limits.md).
#
# A `defer` is a clean no-op with the reason logged — never a cancel, never a job
# failure (AC #1). This script therefore ALWAYS exits 0; the decision rides on
# stdout (`decision=allow|defer`) and in $GITHUB_OUTPUT, and the caller gates its
# dispatch step on it. DRY_RUN / DEV_LEAD_DRY_RUN log every intended decision and
# mutate nothing (AC #7).
#
# Org-wide token-budget breaker (#1155): in addition to the per-agent-type checks
# above, the orchestrator also consults the org-wide Claude token-budget breaker
# (the `session` 5-hour and `weekly_all` 7-day account windows; `weekly_scoped` is
# never consulted — ADR §2.5). A `defer` from EITHER half defers the dispatch. The
# whole consultation is behind AGENT_TOKEN_BUDGET_ENABLED: unset (the default) ⇒
# skipped entirely, so the output is byte-identical to before this change; it is
# inert until a maintainer arms the flag AND wires the private telemetry seam
# (petry-projects/.github-private#1565). Even armed, the weekly glide half stays
# inert until org_wide.token_budget.limits.weekly_all.enabled is flipped in config.
#
# Usage:
#   agent-rate-limit-gate.sh <agent_type> [options]
#     --mode enforce|log-only   default: log-only (only initiative-driver enforces)
#     --workflow <name>         workflow to read run history from (default: <agent_type>)
#     --actor <login>           triggering actor (exempt-actor bypass)
#     --labels <csv>            triggering PR/issue labels (exempt-label bypass)
#     --repo <owner/repo>       repo whose run history is read (default: current)
#     --tracking-repo <o/r>     repo of the breaker escalation tracking issue
#     --tracking-issue <n>      issue number to post the breaker marker/label onto
#     --history-limit <n>       runs to fetch (default: 100)
#
# Env: SOURCE_NOW (epoch override, testability), DRY_RUN / DEV_LEAD_DRY_RUN,
#      AGENT_RATE_LIMITS_CONFIG (library override), ARGATE_LIB_ONLY (source
#      without running main — for unit tests), AGENT_TOKEN_BUDGET_ENABLED (arm the
#      org-wide token-budget consultation; unset ⇒ skipped entirely),
#      AGENT_TOKEN_BUDGET_TELEMETRY_CMD / AGENT_TOKEN_BUDGET_TELEMETRY_FILE (the
#      private telemetry adapter seam the library reads the usage envelope from).

# Source the co-located pure gate library.
_ARGATE_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=scripts/lib/agent-rate-limit.sh
source "${_ARGATE_HERE}/lib/agent-rate-limit.sh"

# The rolling window (seconds) for the daily_run_budget dimension — 24h is the
# definition of "daily", not a tunable threshold, so it is a constant here (the
# library uses the same 86400 for its daily-window reset).
ARGATE_DAILY_WINDOW_SECONDS=86400

# The run conclusions that count as a failure for the consecutive-failure
# breaker. `cancelled` is deliberately EXCLUDED: a concurrency-evicted run
# (cancelled, 0 steps executed) is not a candidate failure — counting it was the
# #1047 false-REGRESSION bug. `success` resets the streak; any other conclusion
# (cancelled/skipped/neutral/…) is ignored — it neither counts nor resets.
ARGATE_FAILURE_CONCLUSIONS="failure startup_failure timed_out"

# ---------------------------------------------------------------------------
# argate_log <msg…> — human-readable reasoning to stderr (stdout carries only the
# machine-readable decision, mirroring the library's arl_log convention).
# ---------------------------------------------------------------------------
argate_log() { printf 'agent-rate-limit-gate: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# argate_iso_to_epoch <iso8601> — epoch seconds for an ISO-8601 run timestamp,
# or empty when unparseable (a malformed timestamp degrades the caller to a
# neutral value rather than crashing).
# ---------------------------------------------------------------------------
argate_iso_to_epoch() {
  local iso="${1:-}" epoch
  [ -z "$iso" ] && return 0
  epoch="$(date -u -d "$iso" +%s 2>/dev/null || printf '')"
  [[ "$epoch" =~ ^[0-9]+$ ]] && printf '%s' "$epoch"
}

# ---------------------------------------------------------------------------
# argate_concurrent <runs_json> — PURE. Count this workflow's in-flight (queued
# or in_progress) runs from the run-history JSON. This is the concurrency
# dimension: it complements (never removes) the workflow's own `concurrency:`
# group by serializing a dispatch burst ahead of it (AC #2).
# ---------------------------------------------------------------------------
argate_concurrent() {
  local runs="${1:-[]}" n current_run_id="${GITHUB_RUN_ID:-}"
  n="$(jq -r --arg current "$current_run_id" \
    '[.[]? | select((.status // "") == "in_progress" or (.status // "") == "queued") | select($current == "" or (.databaseId | tostring) != $current)] | length' \
    <<<"$runs" 2>/dev/null || printf '0')"
  arl_sanitize_int "$n"
}

# ---------------------------------------------------------------------------
# argate_last_run_epoch <runs_json> — PURE-ish. Epoch of the most recent run of
# any kind (the cooldown dimension's "last run" — a fresh dispatch inside the
# cooldown window is the #443 double-fire the gate must defer). Empty when there
# is no run history.
# ---------------------------------------------------------------------------
argate_last_run_epoch() {
  local runs="${1:-[]}" latest current_run_id="${GITHUB_RUN_ID:-}"
  latest="$(jq -r --arg current "$current_run_id" \
    '[.[]? | select($current == "" or (.databaseId | tostring) != $current) | .createdAt // empty] | max // empty' \
    <<<"$runs" 2>/dev/null || printf '')"
  argate_iso_to_epoch "$latest"
}

# ---------------------------------------------------------------------------
# argate_daily_count <runs_json> <now_epoch> — PURE-ish. Count runs created
# within the trailing rolling 24h window (the daily_run_budget dimension; for
# initiative-driver this is a dispatches/day bound).
# ---------------------------------------------------------------------------
argate_daily_count() {
  local runs="${1:-[]}" now threshold_iso n current_run_id="${GITHUB_RUN_ID:-}"
  now="$(arl_sanitize_int "${2:-}")"
  threshold_iso="$(date -u -d "@$(( now - ARGATE_DAILY_WINDOW_SECONDS ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')"
  if [ -z "$threshold_iso" ]; then
    printf '0'
    return 0
  fi
  n="$(jq -r --arg th "$threshold_iso" --arg current "$current_run_id" \
    '[.[]? | select((.createdAt // "") >= $th) | select($current == "" or (.databaseId | tostring) != $current)] | length' \
    <<<"$runs" 2>/dev/null || printf '0')"
  arl_sanitize_int "$n"
}

# ---------------------------------------------------------------------------
# argate_consecutive_failures <runs_json> — PURE. Derive the breaker's
# consecutive_failures from run history (AC #3): among COMPLETED runs ordered
# most-recent-first, count the leading streak of failure-class conclusions. A
# `success` breaks the streak; a `cancelled`/`skipped`/other conclusion is
# ignored (neither counts nor breaks — the #1047 lesson). Fed straight into
# arl_breaker_decision.
# ---------------------------------------------------------------------------
argate_consecutive_failures() {
  local runs="${1:-[]}" concl streak=0
  while IFS= read -r concl; do
    [ -z "$concl" ] && continue
    case " $ARGATE_FAILURE_CONCLUSIONS " in
      *" $concl "*) streak=$(( streak + 1 )) ;;
      *)
        if [ "$concl" = "success" ]; then
          break
        fi
        # cancelled / skipped / neutral / action_required: ignore, keep scanning.
        ;;
    esac
  done < <(jq -r '
      [ .[]? | select((.conclusion // "") != "") ]
      | sort_by(.createdAt) | reverse | .[] | (.conclusion // "")
    ' <<<"$runs" 2>/dev/null || true)
  printf '%s' "$streak"
}

# ---------------------------------------------------------------------------
# argate_last_failure_epoch <runs_json> — PURE-ish. Epoch of the most recent
# failure-class run — the stateless proxy for "when the breaker opened", since no
# persisted opened-timestamp exists (AC #3). The backoff window is measured from
# here: the breaker holds open for backoff_minutes after the last failure, then a
# half-open probe is admitted.
# ---------------------------------------------------------------------------
argate_last_failure_epoch() {
  local runs="${1:-[]}" jqset latest
  # Build a jq array membership test from the failure-conclusion set.
  jqset="$(printf '%s\n' $ARGATE_FAILURE_CONCLUSIONS | jq -R . | jq -sc .)"
  latest="$(jq -r --argjson set "$jqset" \
    '[.[]? | . as $r | select(($set | index($r.conclusion // "")) != null) | .createdAt // empty] | max // empty' \
    <<<"$runs" 2>/dev/null || printf '')"
  argate_iso_to_epoch "$latest"
}

# ---------------------------------------------------------------------------
# argate_fetch_runs <workflow> <repo> <limit> — the ONLY impure gather: read the
# agent's recent workflow runs via `gh run list`. Fail-safe: any gh error or
# empty payload yields `[]`, so a transient API failure degrades the derived
# counters to their allowing defaults rather than wedging dispatch (AC #1).
# ---------------------------------------------------------------------------
argate_fetch_runs() {
  local workflow="$1" repo="$2" limit="$3" out
  local json_fields="databaseId,status,conclusion,createdAt"
  local args=(run list --workflow "$workflow" --json "$json_fields" --limit "$limit")
  [ -n "$repo" ] && args+=(--repo "$repo")
  out="$(gh "${args[@]}" 2>/dev/null || printf '')"
  if [ -z "$out" ] || ! jq -e . <<<"$out" >/dev/null 2>&1; then
    argate_log "warning: run history for workflow '${workflow}' was unreadable — treating as empty (degraded)"
    printf '[]'
    return 0
  fi
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# argate_escalate <agent_type> <tracking_repo> <tracking_issue> — post the open-
# breaker marker to the tracking issue ONCE and apply the human-clearable label
# (AC #4). Guarded by arl_should_escalate for dedup; both the marker string and
# the label are read from the library, never restated. Best-effort and disclosed:
# with no tracking issue configured it logs the marker (observable) and skips the
# gh mutation rather than failing.
# ---------------------------------------------------------------------------
argate_escalate() {
  local agent_type="$1" tracking_repo="$2" tracking_issue="$3"
  local marker label body
  marker="$(arl_breaker_marker "$agent_type")"
  label="$(arl_breaker_label)"

  if [ -z "$tracking_issue" ]; then
    argate_log "breaker OPEN for '${agent_type}' but no --tracking-issue configured — not posting; marker would be: ${marker}"
    return 0
  fi

  local repo_args=()
  [ -n "$tracking_repo" ] && repo_args=(--repo "$tracking_repo")

  body="$(gh issue view "$tracking_issue" "${repo_args[@]}" --json body --jq '.body' 2>/dev/null || printf '')"
  if ! arl_should_escalate "$body" "$agent_type"; then
    argate_log "breaker OPEN for '${agent_type}' — marker already present on ${tracking_repo:-current}#${tracking_issue}; deduped, not re-posting"
    return 0
  fi

  local comment
  comment="$(printf '%s\n\n⛔ The **%s** dispatch circuit breaker is OPEN — %s consecutive failures tripped it and new dispatch is deferred for the configured backoff. A human clears this by removing the `%s` label and deleting this comment once the underlying failures are understood.' \
    "$marker" "$agent_type" "$(arl_breaker_threshold "$agent_type" consecutive_failure_threshold)" "$label")"

  if gh issue comment "$tracking_issue" "${repo_args[@]}" --body "$comment" >/dev/null 2>&1; then
    argate_log "breaker OPEN for '${agent_type}' — posted escalation marker to ${tracking_repo:-current}#${tracking_issue}"
  else
    argate_log "warning: failed to post breaker escalation comment to ${tracking_repo:-current}#${tracking_issue}"
  fi
  if gh issue edit "$tracking_issue" "${repo_args[@]}" --add-label "$label" >/dev/null 2>&1; then
    argate_log "applied '${label}' to ${tracking_repo:-current}#${tracking_issue}"
  else
    argate_log "warning: failed to apply '${label}' to ${tracking_repo:-current}#${tracking_issue} (does the label exist?)"
  fi
}

# ---------------------------------------------------------------------------
# argate_token_escalate <window> <tracking_repo> <tracking_issue> — post the open
# token-budget-breaker marker for <window> to the tracking issue ONCE and apply
# the human-clearable label (the same needs-human-review gate the per-agent
# breaker uses). Guarded by arl_token_should_escalate for dedup; the marker string
# is read from the library (arl_token_breaker_marker) and the label from
# arl_breaker_label — never restated. Best-effort and disclosed: with no tracking
# issue configured it logs the marker (observable) and skips the gh mutation
# rather than failing. Mirrors argate_escalate for the org-wide token windows so a
# tripped budget is human-clearable and deduplicated, not merely logged (#1155).
# ---------------------------------------------------------------------------
argate_token_escalate() {
  local window="$1" tracking_repo="$2" tracking_issue="$3"
  local marker label body
  marker="$(arl_token_breaker_marker "$window")"
  label="$(arl_breaker_label)"

  if [ -z "$tracking_issue" ]; then
    argate_log "token-budget[${window}] breaker OPEN but no --tracking-issue configured — not posting; marker would be: ${marker}"
    return 0
  fi

  local repo_args=()
  [ -n "$tracking_repo" ] && repo_args=(--repo "$tracking_repo")

  body="$(gh issue view "$tracking_issue" "${repo_args[@]}" \
    --json body,comments \
    --jq '[.body, (.comments[]?.body)] | join("\n")' \
    2>/dev/null || printf '')"
  if ! arl_token_should_escalate "$body" "$window"; then
    argate_log "token-budget[${window}] breaker OPEN — marker already present on ${tracking_repo:-current}#${tracking_issue}; deduped, not re-posting"
    return 0
  fi

  local comment
  comment="$(printf '%s\n\n⛔ The org-wide **%s** Claude token-budget breaker is OPEN — account-wide usage is at/over the pause threshold and new agent dispatch is deferred. A human clears this by removing the `%s` label and deleting this comment once usage has recovered.' \
    "$marker" "$window" "$label")"

  if gh issue comment "$tracking_issue" "${repo_args[@]}" --body "$comment" >/dev/null 2>&1; then
    argate_log "token-budget[${window}] breaker OPEN — posted escalation marker to ${tracking_repo:-current}#${tracking_issue}"
  else
    argate_log "warning: failed to post token-budget escalation comment to ${tracking_repo:-current}#${tracking_issue}"
  fi
  if gh issue edit "$tracking_issue" "${repo_args[@]}" --add-label "$label" >/dev/null 2>&1; then
    argate_log "applied '${label}' to ${tracking_repo:-current}#${tracking_issue}"
  else
    argate_log "warning: failed to apply '${label}' to ${tracking_repo:-current}#${tracking_issue} (does the label exist?)"
  fi
}

# ---------------------------------------------------------------------------
# argate_token_budget — consult the org-wide token-budget breaker across the two
# pause-worthy account-wide windows and echo `allow` or `defer` on stdout (#1155).
#
# The telemetry envelope is fetched ONCE (through the library's private adapter
# seam) and fed to BOTH library gates: arl_token_budget_gate for the 5-hour
# `session` window and arl_token_weekly_glide_gate for the 7-day `weekly_all`
# window. `weekly_scoped` is deliberately NOT consulted — per-model exhaustion is
# the engine's model-fallback chain, never a fleet pause (ADR §2.5, AC #4).
#
# Observability (AC #5): every window read, its percent, and its threshold are
# logged, and — critically — whether telemetry was ACTUALLY obtained (a 200
# envelope) is logged distinctly, so a fail-open on absent/degraded telemetry is
# visibly different from a genuine under-threshold allow. On a trip the window's
# human-clearable escalation marker is logged too.
#
# Guard-only: reads telemetry, never mutates. Returns 0 always. The decision
# rides on stdout as space-separated fields: the first is `allow`/`defer`, and any
# remaining fields name the windows that tripped (`session`, `weekly_all`) so the
# enforcing caller can escalate each one (dedup marker + needs-human-review label).
# ---------------------------------------------------------------------------
argate_token_budget() {
  local envelope status body decision="allow"
  local -a tripped=()
  envelope="$(arl_token_fetch_envelope)"
  status="$(arl_sanitize_int "$(jq -r '.status? // 0' <<<"$envelope" 2>/dev/null || printf '0')")"
  body="$(jq -c '.body? // {}' <<<"$envelope" 2>/dev/null || printf '{}')"

  # Extract both pause-worthy window percents up front so the OBTAINED/DEGRADED
  # headline reflects whether the body actually carried usable window data. A 200
  # status with a missing/empty/malformed body fails BOTH gates open, so it is a
  # DEGRADED fail-open — not a genuine OBTAINED read — and must be logged as such
  # (AC #5 precision): the headline gates on the presence of a usable percent, not
  # on the HTTP status alone.
  local s_percent w_percent
  s_percent="$(arl_token_extract_percent "$body" session)"
  w_percent="$(arl_token_extract_percent "$body" weekly_all)"

  if [ "$status" -eq 200 ] && { [ -n "$s_percent" ] || [ -n "$w_percent" ]; }; then
    argate_log "token-budget: telemetry OBTAINED (status=200) — evaluating pause-worthy account windows (session, weekly_all)"
  elif [ "$status" -eq 200 ]; then
    argate_log "token-budget: telemetry status=200 but NO usable window data (empty/malformed body) — the breaker fails open; any allow below is DEGRADED, not a genuine under-threshold allow"
  else
    argate_log "token-budget: telemetry NOT obtained (status=${status}) — the breaker fails open; any allow below is DEGRADED, not a genuine under-threshold allow"
  fi

  # session (5-hour, static config threshold).
  local s_threshold s_decision
  s_threshold="$(arl_token_pause_threshold session)"
  argate_log "token-budget[session]: percent=${s_percent:-<none>} threshold=${s_threshold:-<none>}%"
  s_decision="$(arl_token_budget_gate session "$envelope")" || true
  if [ "$s_decision" = "decision=defer" ]; then
    decision="defer"
    tripped+=(session)
    argate_log "token-budget[session] TRIP — escalation marker: $(arl_token_breaker_marker session)"
  fi

  # weekly_all (7-day, time-varying glide-path threshold). Inert until
  # weekly_all.enabled is set in config, even when the env flag is armed.
  local w_decision
  argate_log "token-budget[weekly_all]: percent=${w_percent:-<none>} threshold=glide-path (config-enabled=$(arl_token_glide_enabled))"
  w_decision="$(arl_token_weekly_glide_gate "$envelope")" || true
  if [ "$w_decision" = "decision=defer" ]; then
    decision="defer"
    tripped+=(weekly_all)
    argate_log "token-budget[weekly_all] TRIP — escalation marker: $(arl_token_breaker_marker weekly_all)"
  fi

  printf '%s' "$decision"
  [ "${#tripped[@]}" -gt 0 ] && printf ' %s' "${tripped[@]}"
}

# ---------------------------------------------------------------------------
# argate_emit <decision> — print `decision=<decision>` to stdout and, when
# running under GitHub Actions, append it to $GITHUB_OUTPUT so the caller can
# gate its dispatch step (`if: steps.gate.outputs.decision == 'allow'`).
# ---------------------------------------------------------------------------
argate_emit() {
  local decision="$1"
  printf 'decision=%s\n' "$decision"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'decision=%s\n' "$decision" >>"$GITHUB_OUTPUT"
  fi
}

# ---------------------------------------------------------------------------
# argate_gate <agent_type> [--mode …] [--actor …] … — the orchestrator entry
# point. Gathers run history, derives the counters, computes the admission +
# breaker decisions via the pure library, applies the canary/log-only split and
# the dry-run override, escalates an open breaker, and emits the decision. Always
# returns 0 (a defer is a no-op, never a job failure).
# ---------------------------------------------------------------------------
argate_gate() {
  local agent_type="" mode="log-only" workflow="" actor="" labels="" repo=""
  local tracking_repo="" tracking_issue="" history_limit="100"

  # First positional is the agent type; the rest are flags.
  if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
    agent_type="$1"; shift
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) mode="${2:-}"; shift 2 ;;
      --workflow) workflow="${2:-}"; shift 2 ;;
      --actor) actor="${2:-}"; shift 2 ;;
      --labels) labels="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --tracking-repo) tracking_repo="${2:-}"; shift 2 ;;
      --tracking-issue) tracking_issue="${2:-}"; shift 2 ;;
      --history-limit) history_limit="${2:-}"; shift 2 ;;
      *) argate_log "warning: ignoring unrecognized argument '$1'"; shift ;;
    esac
  done

  if [ -z "$agent_type" ]; then
    argate_log "error: an <agent_type> argument is required"
    argate_emit "allow"   # fail-open: a usage error must not block the fleet
    return 0
  fi
  [ -z "$workflow" ] && workflow="$agent_type"

  # Config unreadable → allow (never block the fleet on a config outage; AC #1).
  local config
  config="$(arl_config_path)"
  if [ ! -f "$config" ] || ! jq -e . "$config" >/dev/null 2>&1; then
    argate_log "warning: config at '$config' is missing or malformed — allowing dispatch (degraded)"
    argate_emit "allow"
    return 0
  fi

  # Exempt actors / labels are never blocked and never counted (same policy as
  # the library and the PR-limit gate).
  if [ -n "$actor" ] && arl_is_exempt_actor "$actor"; then
    argate_log "actor '${actor}' is exempt — allowing (not subject to the limits)"
    argate_emit "allow"
    return 0
  fi
  if [ -n "$labels" ] && arl_is_exempt_label "$labels"; then
    argate_log "run carries an exempt label — allowing (not subject to the limits)"
    argate_emit "allow"
    return 0
  fi

  local now
  now="$(arl_now)"

  # Gather run history once, then derive every counter from it (AC #3).
  local runs concurrent last_run daily_count failures last_failure
  runs="$(argate_fetch_runs "$workflow" "$repo" "$history_limit")"
  concurrent="$(argate_concurrent "$runs")"
  last_run="$(argate_last_run_epoch "$runs")"
  daily_count="$(argate_daily_count "$runs" "$now")"
  failures="$(argate_consecutive_failures "$runs")"
  last_failure="$(argate_last_failure_epoch "$runs")"
  : "${last_run:=0}" "${last_failure:=0}"

  argate_log "derived for '${agent_type}' (workflow=${workflow}): concurrent=${concurrent} last_run=${last_run} daily=${daily_count} consecutive_failures=${failures} last_failure=${last_failure} now=${now}"

  # Circuit breaker first — an open breaker defers regardless of admission. The
  # last-failure epoch is the stateless opened-timestamp proxy. `|| true`: the
  # decision rides on captured stdout and a defer returns non-zero.
  local decision="allow" breaker_open=0 breaker admission
  breaker="$(arl_breaker_decision "$agent_type" "$failures" "$last_failure" "$now")" || true
  if [ "$breaker" != "decision=allow" ]; then
    decision="defer"
    breaker_open=1
  fi

  # Admission — concurrency / cooldown / daily budget (only if the breaker is closed).
  if [ "$decision" = "allow" ]; then
    admission="$(arl_admission_decision "$agent_type" "$concurrent" "$last_run" "$daily_count" "$now")" || true
    [ "$admission" != "decision=allow" ] && decision="defer"
  fi

  # Org-wide token-budget breaker (#1155). INERT unless AGENT_TOKEN_BUDGET_ENABLED
  # is set: unset ⇒ this block is skipped entirely, so the output stays
  # byte-identical to the pre-#1155 per-agent-only behaviour (AC #2/#6). When
  # armed, a `defer` from the token-budget half defers dispatch in addition to the
  # per-agent-type checks above — the account-wide budget is consulted regardless
  # of whether a per-agent limit already deferred, so the observability log always
  # records the budget state (AC #1/#5).
  local -a tripped_token_windows=()
  if [ "${AGENT_TOKEN_BUDGET_ENABLED:-false}" = "true" ]; then
    local -a token_fields=()
    local token_decision
    read -r -a token_fields < <(argate_token_budget)
    token_decision="${token_fields[0]:-allow}"
    tripped_token_windows=("${token_fields[@]:1}")
    if [ "$token_decision" = "defer" ]; then
      argate_log "token-budget breaker deferred dispatch for '${agent_type}' (org-wide account budget over threshold)"
      decision="defer"
    fi
  fi

  # DRY_RUN: log the intended decision, mutate nothing, do not block (AC #7).
  if arl_is_dry_run; then
    argate_log "DRY_RUN — computed decision=${decision} for '${agent_type}'; emitting allow, no side effects"
    argate_emit "allow"
    return 0
  fi

  # Log-only canary split: compute + log, but never act (AC #5).
  if [ "$mode" != "enforce" ]; then
    argate_log "log-only mode for '${agent_type}' — computed decision=${decision} but NOT acting (emitting allow)"
    argate_emit "allow"
    return 0
  fi

  # Enforcing. Escalate an open breaker exactly once (AC #4), then emit the
  # computed decision. A defer is a clean no-op — the caller simply skips
  # dispatch; it is never a job failure.
  if [ "$breaker_open" -eq 1 ]; then
    argate_escalate "$agent_type" "$tracking_repo" "$tracking_issue"
  fi
  # Escalate each tripped org-wide token-budget window the same way (dedup marker +
  # needs-human-review label), so an armed budget trip is human-clearable and
  # deduplicated through the tracking issue rather than merely logged (#1155).
  local token_window
  for token_window in "${tripped_token_windows[@]}"; do
    argate_token_escalate "$token_window" "$tracking_repo" "$tracking_issue"
  done
  argate_log "enforce mode for '${agent_type}' — decision=${decision}"
  argate_emit "$decision"
  return 0
}

# Run main unless sourced for unit testing (ARGATE_LIB_ONLY=1) or dot-sourced.
if [ -z "${ARGATE_LIB_ONLY:-}" ] && [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  argate_gate "$@"
fi
