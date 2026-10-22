# shellcheck shell=bash
# scripts/lib/pr-limit-gate.sh — Source-side PR-limit admission gate
#
# Reusable Bash library implementing the §7.2–§7.4 source-side mechanism from
# the Pull-Request-Limits ADR:
#
#   docs/initiatives/pull-request-limits-adr.md
#
# GitHub exposes no native "maximum number of open pull requests" surface (ADR
# §2–§3), so the cap is enforced at the automation *source*: before a PR-creating
# workflow (dev-lead / initiative-driver / agentic) opens a PR, it asks this gate
# whether the standing queue of open, non-draft automation PRs is already at the
# configured cap. The gate counts the queue with `gh search prs` (the same
# enumeration idiom as .dev-lead/scripts/list-prs.sh) and returns allow or defer.
#
# This library delivers the guard + its tests only. Wiring it into the live
# PR-creation path and choosing rollout scope is #508.
#
# ----------------------------------------------------------------------------
# Caller contract
# ----------------------------------------------------------------------------
# This library is `set -euo pipefail`-safe and designed to be sourced by a
# parent script (`# shellcheck source=scripts/lib/pr-limit-gate.sh`). It does
# NOT call `set` itself and runs nothing at source time.
#
# Reads (all optional, with defaults):
#   - $ORG               — GitHub org slug to scope the search (default: petry-projects)
#   - $PR_LIMITS_CONFIG  — path to the pr-limits.json single source of truth
#                          (default: <repo>/standards/pr-limits.json, resolved
#                          relative to this file)
#   - $DRY_RUN / $DEV_LEAD_DRY_RUN — "true" forces an allow result with no
#                          side effects, after printing the computed decision
#   - `gh` CLI on PATH, `jq` on PATH
#
# Functions are namespaced with the `plg_` prefix to avoid colliding with
# caller helpers.

# Default location of the machine-readable caps + exempt list (#507). Resolved
# relative to this library so a caller that sources it from anywhere still finds
# the org single source of truth without hardcoding a path.
PLG_DEFAULT_CONFIG="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/standards/pr-limits.json"

# ---------------------------------------------------------------------------
# Logging — to stderr so a caller can capture the machine-readable decision on
# stdout without the human-readable reasoning getting in the way.
# ---------------------------------------------------------------------------
plg_log() { printf 'pr-limit-gate: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# plg_config_path — echo the effective config path, honoring $PR_LIMITS_CONFIG.
# ---------------------------------------------------------------------------
plg_config_path() {
  printf '%s' "${PR_LIMITS_CONFIG:-$PLG_DEFAULT_CONFIG}"
}

# ---------------------------------------------------------------------------
# plg_is_dry_run — 0 (true) when DRY_RUN or DEV_LEAD_DRY_RUN is "true".
# ---------------------------------------------------------------------------
plg_is_dry_run() {
  local dry="${DRY_RUN:-${DEV_LEAD_DRY_RUN:-false}}"
  if [ "$dry" = "true" ]; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# plg_is_exempt_actor <source> — 0 when <source> is on the config exempt list.
# Exempt actors (e.g. dependabot[bot], human break-glass) must never be blocked
# by the cap, nor counted against it (ADR §7.4).
# ---------------------------------------------------------------------------
plg_is_exempt_actor() {
  local source="$1" config
  config="$(plg_config_path)"
  if jq -e --arg s "$source" '(.exempt_actors // []) | index($s) != null' "$config" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# plg_count_open_automation_prs — count open, non-draft PRs org-wide that count
# toward the cap: i.e. excluding PRs authored by an exempt actor and PRs that
# carry an exempt label (ADR §7.4). Echoes the integer count on stdout.
#
# Uses `gh search prs` (the list-prs.sh enumeration idiom). A search failure is
# fail-open: it logs and yields 0, so a transient API error never wedges the
# PR-creating automation.
# ---------------------------------------------------------------------------
plg_count_open_automation_prs() {
  local config="$1"
  local org="${ORG:-petry-projects}"
  local exempt_actors exempt_labels prs

  exempt_actors="$(jq -c '.exempt_actors // []' "$config" 2>/dev/null || echo '[]')"
  exempt_labels="$(jq -c '.exempt_labels // []' "$config" 2>/dev/null || echo '[]')"

  prs="$(gh search prs \
    --owner "$org" \
    --state open \
    --draft=false \
    --limit 1000 \
    --json author,labels \
    2>/dev/null || true)"

  if [ -z "$prs" ]; then
    plg_log "warning: PR enumeration returned no data (treating count as 0)"
    printf '0'
    return 0
  fi

  # Count PRs whose author is not exempt AND which carry no exempt label.
  jq -r \
    --argjson exempt_actors "$exempt_actors" \
    --argjson exempt_labels "$exempt_labels" '
      [ .[]
        | select((.author.login // "") as $a | ($exempt_actors | index($a)) == null)
        | select(
            ([.labels[]?.name] | map(. as $n | $exempt_labels | index($n)) | any) | not
          )
      ] | length
    ' <<<"$prs" 2>/dev/null || printf '0'
  return 0
}

# ---------------------------------------------------------------------------
# plg_count_source_prs <source> — count this source's own open, non-draft PRs
# via the GitHub `head:` branch qualifier (automation branches are namespaced
# as `<source>/...`, e.g. dev-lead/issue-561). Echoes the integer count.
# Fail-open like plg_count_open_automation_prs.
# ---------------------------------------------------------------------------
plg_count_source_prs() {
  local source="$1"
  local org="${ORG:-petry-projects}"
  local prs

  prs="$(gh search prs "head:$source/" \
    --owner "$org" \
    --state open \
    --draft=false \
    --limit 1000 \
    --json author \
    2>/dev/null || true)"

  if [ -z "$prs" ]; then
    printf '0'
    return 0
  fi

  jq -r 'length' <<<"$prs" 2>/dev/null || printf '0'
  return 0
}

# ---------------------------------------------------------------------------
# plg_admission_gate <source> — the guard.
#
# Decides whether <source> may open another PR right now. <source> is the
# candidate author/source identity (e.g. "dev-lead", "claude", or an actor
# login like "dependabot[bot]").
#
# Decision (ADR §7.2–§7.4):
#   1. Exempt actor                          -> allow (never blocked, never counted)
#   2. Org-wide automation queue >= org cap  -> defer
#   3. Per-source queue >= that source's sub-cap (when one is configured) -> defer
#   4. Otherwise                             -> allow
#
# Prints `decision=allow` / `decision=defer` (the machine-readable result) plus
# the counts it is based on. Returns 0 on allow, 1 on defer.
#
# DRY_RUN / DEV_LEAD_DRY_RUN: prints the computed decision and the counts, then
# returns allow (0) and performs no side effects.
# ---------------------------------------------------------------------------
plg_admission_gate() {
  local source="${1:-}"
  if [ -z "$source" ]; then
    plg_log "error: plg_admission_gate requires a <source> argument"
    return 2
  fi

  local config
  config="$(plg_config_path)"
  if [ ! -f "$config" ]; then
    plg_log "error: pr-limits config not found at $config"
    return 2
  fi

  # 1. Exempt actors are always allowed and are never counted.
  if plg_is_exempt_actor "$source"; then
    plg_log "source '$source' is an exempt actor — allowed (not subject to the cap)"
    local rc=0
    plg_finish "$source" "allow" "exempt actor" && rc=0 || rc=$?
    return "$rc"
  fi

  local org_cap org_count
  org_cap="$(jq -er '.org_wide.automation_open_pr_cap' "$config" 2>/dev/null || printf '')"
  if ! [[ "$org_cap" =~ ^[0-9]+$ ]]; then
    plg_log "error: org_wide.automation_open_pr_cap is missing or not an integer in $config"
    return 2
  fi
  org_count="$(plg_count_open_automation_prs "$config")"
  if ! [[ "$org_count" =~ ^[0-9]+$ ]]; then
    plg_log "error: retrieved open PR count is not a valid integer: '$org_count'"
    return 2
  fi

  local decision="allow" reason
  reason="org queue ${org_count}/${org_cap}"

  if [ "$org_count" -ge "$org_cap" ]; then
    decision="defer"
    reason="org queue ${org_count}/${org_cap} at or over the org-wide cap"
  else
    # 3. Per-source sub-cap, only when one is configured for this source.
    local sub_cap
    sub_cap="$(jq -r --arg s "$source" '.per_source_caps[$s] // empty' "$config" 2>/dev/null || printf '')"
    if [[ "$sub_cap" =~ ^[0-9]+$ ]]; then
      local src_count
      src_count="$(plg_count_source_prs "$source")"
      if ! [[ "$src_count" =~ ^[0-9]+$ ]]; then
        plg_log "error: retrieved source PR count is not a valid integer: '$src_count'"
        return 2
      fi
      reason="org queue ${org_count}/${org_cap}, source '${source}' queue ${src_count}/${sub_cap}"
      if [ "$src_count" -ge "$sub_cap" ]; then
        decision="defer"
        reason="source '${source}' queue ${src_count}/${sub_cap} at or over its sub-cap (org queue ${org_count}/${org_cap})"
      fi
    fi
  fi

  local rc=0
  plg_finish "$source" "$decision" "$reason" && rc=0 || rc=$?
  return "$rc"
}

# ---------------------------------------------------------------------------
# plg_finish <source> <decision> <reason> — emit the result and set the return
# code, applying the dry-run override. Internal helper for plg_admission_gate.
# ---------------------------------------------------------------------------
plg_finish() {
  local source="$1" decision="$2" reason="$3"

  if plg_is_dry_run; then
    plg_log "DRY_RUN — computed decision=${decision} for '${source}' (${reason}); returning allow, no side effects"
    printf 'decision=allow\n'
    return 0
  fi

  plg_log "decision=${decision} for '${source}' (${reason})"
  printf 'decision=%s\n' "$decision"

  if [ "$decision" = "allow" ]; then
    return 0
  fi
  return 1
}
