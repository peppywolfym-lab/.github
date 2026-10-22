#!/usr/bin/env bash
# pinned-version-report.sh — Safe Release SC8 (#495/#502): report each ring
# consumer's currently-pinned CHANNEL and the concrete VERSION it resolves to,
# for every ring-released reusable, so "who is on what version" is a single
# reportable surface (not just drift detection).
#
# For each fleet repo × ring reusable it finds the caller-stub `uses:` line,
# extracts the `@<agent>/<channel>` pin, resolves that channel tag to the
# immutable `<agent>/vX.Y.Z` release it points at (matching tag SHAs on the host
# repo), and flags whether the pin matches the repo's expected ring tier.
#
# Output: a Markdown report on stdout, and appended to $GITHUB_STEP_SUMMARY when
# set. Read-only: only GET calls; never mutates.
#
# Env: GH_TOKEN (repo read + org metadata). ORG (default petry-projects).
set -euo pipefail

ORG="${ORG:-petry-projects}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/ring-pins.sh
source "$SCRIPT_DIR/lib/ring-pins.sh"

# Ring-released reusables to report on (mirrors RING_REUSABLES from ring-pins.sh).
REUSABLES=("${RING_REUSABLES[@]}")

# Fleet repos to scan (non-archived). Enumerated live so new repos are covered.
mapfile -t REPOS < <(gh repo list "$ORG" --no-archived --limit 500 --json name --jq '.[].name' | sort)

# --- channel -> version resolution -----------------------------------------
# Cache each host repo's tags (name -> commit sha) once; resolve a channel tag to
# the vX.Y.Z release sharing its SHA.
declare -A TAG_SHA          # "host\ttag" -> sha
declare -A HOST_LOADED      # host -> 1

load_host_tags() {
  local host="$1"
  [ -n "${HOST_LOADED[$host]:-}" ] && return 0
  HOST_LOADED[$host]=1
  local name sha
  while IFS=$'\t' read -r name sha || [ -n "$name" ]; do
    [ -n "$name" ] && TAG_SHA["$host"$'\t'"$name"]="$sha"
  done < <(gh api --paginate "repos/$ORG/$host/tags" \
             --jq '.[] | [.name, .commit.sha] | @tsv' 2>/dev/null | tr -d '\r' || true)
}

# resolve_version <host> <agent> <channel-ref> -> "vX.Y.Z" | "?" (unresolved)
resolve_version() {
  local host="$1" agent="$2" ref="$3"
  load_host_tags "$host"
  local chan_sha="${TAG_SHA["$host"$'\t'"$ref"]:-}"
  # If the pin is already an immutable vX.Y.Z, report it as-is.
  ref_regex="^${agent}/v[0-9]+\.[0-9]+\.[0-9]+$"
  if [[ "$ref" =~ $ref_regex ]]; then
    printf '%s' "${ref#"$agent"/}"; return 0
  fi
  [ -z "$chan_sha" ] && { printf '?'; return 0; }
  local t
  for t in "${!TAG_SHA[@]}"; do
    [[ "$t" == "$host"$'\t'"$agent"/v*.*.* ]] || continue
    if [ "${TAG_SHA[$t]}" = "$chan_sha" ]; then
      printf '%s' "${t##*/}"; return 0
    fi
  done
  printf '?(%.8s)' "$chan_sha"
}

# --- scan -------------------------------------------------------------------
today="$(date -u +%Y-%m-%d)"
rows=""
drift_count=0
declare -A SEEN_VERSION   # "agent\tversion" -> 1 (for the fan-out summary)

for repo in "${REPOS[@]}"; do
  for agent in "${REUSABLES[@]}"; do
    # Ring membership is per-agent (#1092): the same repo can sit in different tiers
    # for different agents (e.g. markets is ring1 for apply-repo-settings, stable
    # elsewhere), so resolve the tier per (agent, repo), not once per repo.
    tier="$(ring_tier_for_repo "$agent" "$repo")"
    # Caller stub + reusable filename come from the registry (the single source of
    # truth), so a grandfathered agent whose engine/stub break the `<agent>.yml` /
    # `<agent>-reusable.yml` convention (e.g. pr-review: engine `pr-review.yml` called by
    # `pr-review-trigger.yml`, #1127) is scanned correctly rather than silently omitted
    # from the report (#1166). ring_caller_stub / ring_reusable_file fall back to the
    # convention for every conventionally-named agent.
    stub="$(ring_caller_stub "$agent")"
    reusable_file="$(ring_reusable_file "$agent")"
    reusable_re="${reusable_file//./\\.}"   # escape dots for the ERE below
    content="$(gh api "repos/$ORG/$repo/contents/$stub" --jq '.content // empty' 2>/dev/null | base64 -d 2>/dev/null || true)"
    [ -n "$content" ] || continue
    # Extract the reusable uses: line -> host + @ref.
    uses_line="$(grep -oE "uses:[[:space:]]*$ORG/(\.github|\.github-private)/\.github/workflows/${reusable_re}@[^[:space:]#]+" <<< "$content" | head -1 || true)"
    [ -n "$uses_line" ] || continue
    ref="${uses_line##*@}"          # e.g. dev-lead/v1-ring1
    host=""
    host_regex="$ORG/(\.github(-private)?)/"
    if [[ "$uses_line" =~ $host_regex ]]; then
      host="${BASH_REMATCH[1]}"
    fi
    channel="${ref#"$agent"/}"                            # e.g. v1-ring1
    version="$(resolve_version "$host" "$agent" "$ref")"
    SEEN_VERSION["$agent"$'\t'"$version"]=1
    # Drift: does the pinned tier match the repo's expected ring tier?
    local_drift=""
    case "$channel" in
      *"$tier"|"$tier") : ;;                              # e.g. v1-ring1 endswith ring1
      stable|v*-stable) [ "$tier" = "stable" ] || local_drift="⚠️" ;;
      *) local_drift="⚠️" ;;
    esac
    [ -n "$local_drift" ] && drift_count=$((drift_count + 1))
    rows+="| \`$repo\` | \`$agent\` | \`$tier\` | \`$channel\` | \`$version\` | ${local_drift:-✅} |"$'\n'
  done
done

# --- render -----------------------------------------------------------------
{
  echo "## Pinned-version report — $today"
  echo ""
  echo "_Safe Release SC8 (#495/#502): each ring consumer's pinned channel and the immutable release it resolves to._"
  echo ""
  echo "| Repo | Reusable | Ring tier | Pinned channel | Resolved version | Tier match |"
  echo "|------|----------|-----------|----------------|------------------|:----------:|"
  printf '%b' "$rows"
  echo ""
  echo "**Drift (pin not on the repo's ring tier): $drift_count**  ·  \`?\` = channel tag did not resolve to a vX.Y.Z release."
  echo ""
  echo "### Version fan-out (who is on each release)"
  echo ""
  echo "| Reusable | Versions in the fleet |"
  echo "|----------|-----------------------|"
  # Group SEEN_VERSION by agent.
  for agent in "${REUSABLES[@]}"; do
    vers_arr=()
    for k in "${!SEEN_VERSION[@]}"; do
      [[ "$k" == "$agent"$'\t'* ]] && vers_arr+=("${k#*$'\t'}")
    done
    if [ "${#vers_arr[@]}" -gt 0 ]; then
      vers="$(printf '%s\n' "${vers_arr[@]}" | sort -u | tr '\n' ' ')"
      echo "| \`$agent\` | ${vers% } |"
    fi
  done
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
