#!/usr/bin/env bash
# scripts/pr-limits-report.sh — No-LLM PR-limits success-metric report (#510).
#
# Measures the epic #505 success metric for the source-side PR-limit: how the
# count of open, non-draft, automation-authored PRs org-wide compares to the
# signed-off cap in standards/pr-limits.json. This is a pure `gh` + `jq` report
# (NO LLM / agent): it enumerates the standing PR queue, applies the SAME
# counting semantics as the admission gate (scripts/lib/pr-limit-gate.sh) so the
# report and the gate always agree, and prints a Markdown summary.
#
# Counting semantics (must mirror scripts/lib/pr-limit-gate.sh §7.4):
#   * enumerate open, non-draft PRs org-wide via `gh search prs`;
#   * a PR counts toward the cap only when its author is NOT an exempt actor
#     AND it carries NO exempt label;
#   * exempt-actor and exempt-labeled PRs are shown in the total but excluded
#     from the counted-toward-cap figure.
#
# Reads the cap + exempt lists from the single source of truth
# (standards/pr-limits.json); nothing is hardcoded.
#
# Environment (all optional):
#   ORG               — GitHub org slug to scope the search (default: petry-projects)
#   PR_LIMITS_CONFIG  — path to pr-limits.json (default: <repo>/standards/pr-limits.json,
#                       resolved relative to this script so it works from any CWD)
#   GH_TOKEN / GITHUB_TOKEN — token for `gh search prs` (github.token in CI)
#   GITHUB_STEP_SUMMARY — when set, the Markdown summary is ALSO appended there.
#
# Exit status: 0 on success (including an empty PR queue, reported as 0). A
# non-zero exit only indicates a hard error (missing config, unparseable cap).

set -euo pipefail

# Resolve the config relative to this script so the report finds the org single
# source of truth regardless of the caller's CWD.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="${SCRIPT_DIR}/../standards/pr-limits.json"
CONFIG="${PR_LIMITS_CONFIG:-$DEFAULT_CONFIG}"
ORG="${ORG:-petry-projects}"

if [ ! -f "$CONFIG" ]; then
  echo "pr-limits-report: error: config not found at $CONFIG" >&2
  exit 1
fi

# ── Read the cap + exempt lists from the single source of truth ───────────────
CAP="$(jq -er '.org_wide.automation_open_pr_cap' "$CONFIG" 2>/dev/null || printf '')"
if ! [[ "$CAP" =~ ^[0-9]+$ ]]; then
  echo "pr-limits-report: error: org_wide.automation_open_pr_cap missing or not an integer in $CONFIG" >&2
  exit 1
fi
EXEMPT_ACTORS="$(jq -c '.exempt_actors // []' "$CONFIG" 2>/dev/null || echo '[]')"
EXEMPT_LABELS="$(jq -c '.exempt_labels // []' "$CONFIG" 2>/dev/null || echo '[]')"

# ── Enumerate open, non-draft PRs org-wide (same idiom as the admission gate) ──
# Distinguish a real `gh` failure from a genuinely-empty queue. Unlike the
# admission gate (which fails OPEN so PR creation is never wedged), a scheduled
# report must fail LOUDLY when it cannot measure — otherwise a transient API
# error masquerades as a misleading "🟢 Under cap 0/cap" result.
gh_rc=0
PRS="$(gh search prs \
  --owner "$ORG" \
  --state open \
  --draft=false \
  --limit 1000 \
  --json author,labels,repository,title,url \
  2>/dev/null)" || gh_rc=$?

if [ "$gh_rc" -ne 0 ]; then
  UNAVAILABLE="$(printf '## PR-limits report — %s\n\n> ⚠️ **Metric unavailable** — `gh search prs` failed (rc=%s); the open-PR queue could not be enumerated. No cap comparison was produced.\n' "$ORG" "$gh_rc")"
  printf '%s\n' "$UNAVAILABLE"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$UNAVAILABLE" >>"$GITHUB_STEP_SUMMARY"
  fi
  exit 1
fi

# rc 0: a genuinely empty result is a real "0 open PRs". Keep the unparseable-JSON
# guard as a secondary safety net (rc 0 but garbage stdout).
if [ -z "$PRS" ]; then
  PRS='[]'
fi
if ! jq -e . >/dev/null 2>&1 <<<"$PRS"; then
  echo "pr-limits-report: warning: PR enumeration returned unparseable data — treating as empty" >&2
  PRS='[]'
fi

# ── Compute the metrics with a single jq pass ─────────────────────────────────
# `counted` uses exactly the gate's predicate: non-exempt author AND no exempt
# label. `by_source` groups the counted PRs by author login for the breakdown.
METRICS="$(jq -c \
  --argjson exempt_actors "$EXEMPT_ACTORS" \
  --argjson exempt_labels "$EXEMPT_LABELS" '
  def is_exempt_actor: ((.author.login // "") as $a | ($exempt_actors | index($a)) != null);
  def has_exempt_label: ([.labels[]?.name] | map(. as $n | $exempt_labels | index($n)) | any);
  def counts_toward_cap: ((is_exempt_actor | not) and (has_exempt_label | not));
  {
    total: length,
    counted: ([ .[] | select(counts_toward_cap) ] | length),
    exempt: ([ .[] | select(counts_toward_cap | not) ] | length),
    by_source: (
      [ .[] | select(counts_toward_cap) | (.author.login // "unknown") ]
      | group_by(.)
      | map({ source: .[0], count: length })
      | sort_by(-.count)
    )
  }
' <<<"$PRS")"

TOTAL="$(jq -r '.total' <<<"$METRICS")"
COUNTED="$(jq -r '.counted' <<<"$METRICS")"
EXEMPT="$(jq -r '.exempt' <<<"$METRICS")"
HEADROOM=$(( CAP - COUNTED ))

if [ "$COUNTED" -ge "$CAP" ]; then
  STATUS_ICON="🔴"
  STATUS_LINE="**AT OR OVER CAP** — ${COUNTED}/${CAP} counted automation PRs (headroom ${HEADROOM})."
else
  STATUS_ICON="🟢"
  STATUS_LINE="**Under cap** — ${COUNTED}/${CAP} counted automation PRs (headroom ${HEADROOM})."
fi

# ── Render the Markdown summary ───────────────────────────────────────────────
render_summary() {
  printf '## PR-limits report — %s\n\n' "$ORG"
  printf 'Success metric for epic #505: open non-draft automation PRs org-wide vs. the signed-off cap.\n'
  printf 'Counting mirrors the admission gate (`scripts/lib/pr-limit-gate.sh`): a PR counts only when its author is not exempt and it carries no exempt label.\n\n'

  printf '| Metric | Value |\n'
  printf '| --- | --- |\n'
  printf '| Open non-draft PRs (total) | %s |\n' "$TOTAL"
  printf '| Counted toward cap | %s |\n' "$COUNTED"
  printf '| Exempt (actor or label) | %s |\n' "$EXEMPT"
  printf '| Cap | %s |\n' "$CAP"
  printf '| Headroom (cap − counted) | %s |\n' "$HEADROOM"
  printf '\n'

  printf '%s %s\n\n' "$STATUS_ICON" "$STATUS_LINE"

  printf '### Breakdown by source (counted PRs by author)\n\n'
  if [ "$COUNTED" -eq 0 ]; then
    printf '_No counted automation PRs._\n'
  else
    printf '| Source (author login) | Counted PRs |\n'
    printf '| --- | --- |\n'
    jq -r '.by_source[] | "| \(.source) | \(.count) |"' <<<"$METRICS"
  fi
  printf '\n'
}

SUMMARY="$(render_summary)"
printf '%s\n' "$SUMMARY"

# Mirror the daily-org-status pattern: also append to the job summary when set.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '%s\n' "$SUMMARY" >>"$GITHUB_STEP_SUMMARY"
fi

exit 0
