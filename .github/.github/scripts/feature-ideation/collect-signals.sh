#!/usr/bin/env bash
# collect-signals.sh — gather project signals into signals.json.
#
# Replaces the inline bash heredoc that previously lived in
# .github/workflows/feature-ideation.yml. Each step is delegated to a
# library function so it can be unit-tested in isolation.
#
# Required env:
#   REPO              "owner/name"
#   GH_TOKEN          GitHub token with read scopes
#
# Optional env:
#   SIGNALS_OUTPUT    Path to write signals.json (default: ./signals.json)
#   ISSUE_LIMIT       Max issues per query (default: 50)
#   PR_LIMIT          Max PRs per query (default: 30)
#   DISCUSSION_LIMIT  Max Ideas discussions to fetch (default: 100)
#   FEATURE_IDEATION_BOT_AUTHORS  Extra comma-separated bot logins to filter
#
# Exit codes:
#   0    signals.json written successfully
#   64   bad usage / missing env
#   65   data validation error
#   66   GraphQL refused our request (errors / null data)
#   1+   underlying gh failure (auth, rate limit, network)

set -euo pipefail

# SCHEMA_VERSION must stay in lockstep with the `version` field in
# .github/schemas/signals.schema.json. Bumping one without the other is a
# compatibility break: validate-signals.py will reject the runtime output
# if the constants drift, AND the bats `signals-schema: SCHEMA_VERSION
# constant matches schema file` test enforces this in CI.
# Caught by CodeRabbit review on PR petry-projects/.github#85.
SCHEMA_VERSION="1.0.0"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/gh-safe.sh
. "${SCRIPT_DIR}/lib/gh-safe.sh"
# shellcheck source=lib/filter-bots.sh
. "${SCRIPT_DIR}/lib/filter-bots.sh"
# shellcheck source=lib/compose-signals.sh
. "${SCRIPT_DIR}/lib/compose-signals.sh"
# shellcheck source=lib/date-utils.sh
. "${SCRIPT_DIR}/lib/date-utils.sh"

main() {
  if [ -z "${REPO:-}" ]; then
    printf '[collect-signals] REPO env var is required\n' >&2
    return 64
  fi
  if [ -z "${GH_TOKEN:-}" ]; then
    printf '[collect-signals] GH_TOKEN env var is required\n' >&2
    return 64
  fi

  local issue_limit="${ISSUE_LIMIT:-50}"
  local pr_limit="${PR_LIMIT:-30}"
  local discussion_limit="${DISCUSSION_LIMIT:-100}"
  local output_path="${SIGNALS_OUTPUT:-./signals.json}"

  # Validate that limit overrides are positive integers before forwarding to
  # GraphQL — a value like `ISSUE_LIMIT=foo` would cause an opaque downstream
  # failure instead of a clean usage error. Caught by CodeRabbit review on
  # PR petry-projects/.github#85.
  local _lim_name _lim_val
  for _lim_name in ISSUE_LIMIT PR_LIMIT DISCUSSION_LIMIT; do
    case "$_lim_name" in
      ISSUE_LIMIT)      _lim_val="$issue_limit" ;;
      PR_LIMIT)         _lim_val="$pr_limit" ;;
      DISCUSSION_LIMIT) _lim_val="$discussion_limit" ;;
    esac
    if [[ ! $_lim_val =~ ^[1-9][0-9]*$ ]]; then
      printf '[collect-signals] %s must be a positive integer, got: %s\n' "$_lim_name" "$_lim_val" >&2
      return 64
    fi
  done

  # Strict owner/name format — reject leading/trailing slashes, empty segments,
  # and extra path parts (e.g. "org//repo", "/repo", "org/repo/extra").
  # Caught by CodeRabbit review on PR petry-projects/.github#85.
  if [[ ! $REPO =~ ^[^/]+/[^/]+$ ]]; then
    printf '[collect-signals] REPO must be in owner/name format, got: %s\n' "$REPO" >&2
    return 64
  fi
  local owner repo_name
  owner="${REPO%%/*}"
  repo_name="${REPO##*/}"

  local thirty_days_ago
  thirty_days_ago=$(date_days_ago 30)
  local scan_date
  scan_date=$(date_now_iso)

  local truncation_warnings='[]'

  # --- Open issues -----------------------------------------------------------
  printf '[collect-signals] fetching open issues (limit=%s)\n' "$issue_limit" >&2
  local open_issues_raw
  open_issues_raw=$(gh_safe_rest issue list --repo "$REPO" --state open --limit "$issue_limit" \
    --json number,title,labels,createdAt,author)
  # Compute truncation warning BEFORE bot filtering. If we filter out bots
  # first, the count could drop below the limit and mask a real truncation.
  # Caught by Copilot review on PR petry-projects/.github#85.
  local raw_open_count
  raw_open_count=$(printf '%s' "$open_issues_raw" | jq 'length')
  if [ "$raw_open_count" -ge "$issue_limit" ]; then
    truncation_warnings=$(printf '%s' "$truncation_warnings" \
      | jq --arg src "open_issues" --argjson lim "$issue_limit" \
          '. + [{source: $src, limit: $lim, message: "result count equals limit; possible truncation"}]')
  fi

  local open_issues
  open_issues=$(printf '%s' "$open_issues_raw" | filter_bots_apply)

  # --- Recently closed issues ------------------------------------------------
  printf '[collect-signals] fetching closed issues (since %s)\n' "$thirty_days_ago" >&2
  local closed_issues_raw
  closed_issues_raw=$(gh_safe_rest issue list --repo "$REPO" --state closed --limit "$issue_limit" \
    --json number,title,labels,closedAt)
  local closed_issues
  closed_issues=$(printf '%s' "$closed_issues_raw" \
    | jq --arg cutoff "$thirty_days_ago" '[.[] | select(.closedAt >= $cutoff)]')

  # --- Ideas discussions (paginated, category-filtered) ----------------------
  printf '[collect-signals] resolving Ideas discussion category\n' >&2
  local categories_query
  read -r -d '' categories_query <<'GRAPHQL' || true
query($repo: String!, $owner: String!) {
  repository(name: $repo, owner: $owner) {
    discussionCategories(first: 25) {
      nodes { id name }
    }
  }
}
GRAPHQL

  local categories
  categories=$(gh_safe_graphql -f query="$categories_query" \
    -f owner="$owner" -f repo="$repo_name" \
    --jq '.data.repository.discussionCategories.nodes')

  local ideas_cat_id
  ideas_cat_id=$(printf '%s' "$categories" \
    | jq -r '[.[] | select(.name == "Ideas")][0].id // empty')

  local ideas_discussions='[]'
  if [ -n "$ideas_cat_id" ]; then
    printf '[collect-signals] fetching Ideas discussions (limit=%s)\n' "$discussion_limit" >&2
    local discussions_query
    read -r -d '' discussions_query <<'GRAPHQL' || true
query($repo: String!, $owner: String!, $categoryId: ID!, $limit: Int!) {
  repository(name: $repo, owner: $owner) {
    discussions(first: $limit, orderBy: {field: UPDATED_AT, direction: DESC}, categoryId: $categoryId) {
      pageInfo { hasNextPage }
      nodes {
        id
        number
        title
        createdAt
        updatedAt
        labels(first: 10) { nodes { name } }
        comments(first: 1) { totalCount }
      }
    }
  }
}
GRAPHQL

    local discussions_full
    discussions_full=$(gh_safe_graphql -f query="$discussions_query" \
      -f owner="$owner" -f repo="$repo_name" -f categoryId="$ideas_cat_id" \
      -F limit="$discussion_limit")

    ideas_discussions=$(printf '%s' "$discussions_full" \
      | jq -c '.data.repository.discussions.nodes // []')

    local has_next_page
    has_next_page=$(printf '%s' "$discussions_full" \
      | jq -r '.data.repository.discussions.pageInfo.hasNextPage // false')
    if [ "$has_next_page" = "true" ]; then
      truncation_warnings=$(printf '%s' "$truncation_warnings" \
        | jq --arg src "ideas_discussions" --argjson lim "$discussion_limit" \
            '. + [{source: $src, limit: $lim, message: "hasNextPage=true; results truncated"}]')
    fi
  else
    printf '[collect-signals] no "Ideas" category found, skipping discussions\n' >&2
  fi

  # --- Releases --------------------------------------------------------------
  printf '[collect-signals] fetching recent releases\n' >&2
  local releases
  releases=$(gh_safe_rest release list --repo "$REPO" --limit 5 \
    --json tagName,name,publishedAt,isPrerelease)

  # --- Merged PRs (last 30 days) ---------------------------------------------
  printf '[collect-signals] fetching merged PRs (limit=%s)\n' "$pr_limit" >&2
  local merged_prs_raw
  merged_prs_raw=$(gh_safe_rest pr list --repo "$REPO" --state merged --limit "$pr_limit" \
    --json number,title,labels,mergedAt)
  local merged_prs
  merged_prs=$(printf '%s' "$merged_prs_raw" \
    | jq --arg cutoff "$thirty_days_ago" '[.[] | select(.mergedAt >= $cutoff)]')

  # --- Derived: feature requests + bug reports -------------------------------
  local feature_requests
  feature_requests=$(printf '%s' "$open_issues" \
    | jq -c '[.[] | select(.labels | map(.name) | any(test("enhancement|feature|idea"; "i")))]')
  local bug_reports
  bug_reports=$(printf '%s' "$open_issues" \
    | jq -c '[.[] | select(.labels | map(.name) | any(test("bug"; "i")))]')

  # --- Compose ---------------------------------------------------------------
  local signals
  signals=$(compose_signals \
    "$open_issues" \
    "$closed_issues" \
    "$ideas_discussions" \
    "$releases" \
    "$merged_prs" \
    "$feature_requests" \
    "$bug_reports" \
    "$REPO" \
    "$scan_date" \
    "$SCHEMA_VERSION" \
    "$truncation_warnings")

  printf '%s\n' "$signals" >"$output_path"
  printf '[collect-signals] wrote %s\n' "$output_path" >&2

  # --- Step summary (only when running inside GitHub Actions) ----------------
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      printf '## Signals Collected\n\n'
      printf -- '- **Schema version:** %s\n' "$SCHEMA_VERSION"
      printf -- '- **Open issues:** %s\n' "$(jq '.open_issues.count' "$output_path")"
      printf -- '- **Feature requests:** %s\n' "$(jq '.feature_requests.count' "$output_path")"
      printf -- '- **Bug reports:** %s\n' "$(jq '.bug_reports.count' "$output_path")"
      printf -- '- **Merged PRs (30d):** %s\n' "$(jq '.merged_prs_30d.count' "$output_path")"
      printf -- '- **Existing Ideas discussions:** %s\n' "$(jq '.ideas_discussions.count' "$output_path")"
      local warn_count
      warn_count=$(jq '.truncation_warnings | length' "$output_path")
      if [ "$warn_count" -gt 0 ]; then
        printf -- '- **⚠️ Truncation warnings:** %s\n' "$warn_count"
        jq -r '.truncation_warnings[] | "  - " + .source + " (limit " + (.limit|tostring) + "): " + .message' "$output_path"
      fi
    } >>"$GITHUB_STEP_SUMMARY"
  fi
}

# Allow `source`-ing for tests; only run main when executed directly.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
