#!/usr/bin/env bash
# reconcile-backlog.sh — periodic/manual backlog reconcile for add-to-project.
#
# Why this exists (petry-projects/.github#518): the event-driven add-to-project
# path misses qualifying items in two structural cases —
#   1. issues/PRs created by the default GITHUB_TOKEN (app/github-actions):
#      GitHub does not fire workflows from default-token events, so
#      `issues: opened` never triggers the add; and
#   2. runs dropped under runner congestion (no retry).
# This scans each repo's OPEN issues/PRs and reconciles each with the board
# using the SAME gate + helpers as the event path (evaluate_noise_gate /
# reconcile_content_with_project), so a missed item lands within one reconcile
# cycle regardless of author/token. Issues are un-gated (every issue tracked);
# PRs keep the required-label gate. Discussions are not tracked.
# Idempotent; honours DRY_RUN=1 (logs intended actions, mutates nothing).
#
# Env:
#   PROJECT_ID       ProjectV2 node ID of the Initiatives project   (required)
#   PROJECT_URL      human-readable URL (logging only)
#   REQUIRED_LABEL   PR gate's required label (default: dev-lead); issues are
#                    un-gated regardless
#   EXCLUDED_LABELS  gate's excluded labels  (default in add-issue-or-pr.sh)
#   RECON_REPOS      space-separated owner/repo list to scan
#                    (default: the planner App installation's repositories)
#   DRY_RUN          "1" → log only
#   GH_TOKEN         planner App installation token (issues/PRs read + project write)
set -euo pipefail

_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/add-to-project/add-issue-or-pr.sh
source "${_dir}/add-issue-or-pr.sh"       # reconcile_content_with_project (+ lib.sh)

: "${PROJECT_ID:?PROJECT_ID is required}"
# Issues are un-gated; PRs keep the required-label gate. Capture the PR gate
# from the incoming REQUIRED_LABEL (default dev-lead) before the loop overrides
# it per item.
pr_required="${REQUIRED_LABEL-dev-lead}"

# Resolve target repos: explicit RECON_REPOS, else the App installation's repos.
declare -a repos
if [ -n "${RECON_REPOS:-}" ]; then
  read -r -a repos <<< "${RECON_REPOS}"
else
  mapfile -t repos < <(gh api --paginate /installation/repositories --jq '.repositories[].full_name')
fi
if [ "${#repos[@]}" -eq 0 ]; then
  echo "::error::no repos to reconcile (set RECON_REPOS or check the App installation)" >&2
  exit 64
fi

# Prefetch board membership ONCE so the per-item hot paths (add / find-to-remove
# in reconcile_content_with_project) can answer "already on the board?" from
# memory instead of an API round-trip each. Without this, an un-gated fleet
# scan makes ~one GraphQL call per open issue/PR every cycle and overruns the
# job timeout; with it, only genuine changes (new adds, real removes) touch the
# API. The map + ready flag are consumed by _atp_on_board / _atp_membership_ready
# in lib.sh; the event path never sets them and keeps its always-network path.
declare -gA _ATP_ON_BOARD=()
prefetch_board_membership() {
  local cursor="" json count=0
  while true; do
    # shellcheck disable=SC2016  # $projectId/$pageSize/$cursor are GraphQL variables
    if [ -n "${cursor}" ]; then
      json=$(gh api graphql \
        -F projectId="${PROJECT_ID}" -F pageSize="${PAGE_SIZE:-100}" -F cursor="${cursor}" \
        -f query='query($projectId:ID!,$pageSize:Int!,$cursor:String!){
          node(id:$projectId){ ... on ProjectV2 {
            items(first:$pageSize, after:$cursor){
              pageInfo{ endCursor hasNextPage }
              nodes{ content{ ... on Issue{ id } ... on PullRequest{ id } } }
            } } } }')
    else
      # shellcheck disable=SC2016
      json=$(gh api graphql \
        -F projectId="${PROJECT_ID}" -F pageSize="${PAGE_SIZE:-100}" \
        -f query='query($projectId:ID!,$pageSize:Int!){
          node(id:$projectId){ ... on ProjectV2 {
            items(first:$pageSize){
              pageInfo{ endCursor hasNextPage }
              nodes{ content{ ... on Issue{ id } ... on PullRequest{ id } } }
            } } } }')
    fi
    if [ "$(printf '%s' "${json}" | jq -r '.data?.node?.items? // "null"')" = "null" ]; then
      echo "::error::[reconcile] membership prefetch got no items for PROJECT_ID=${PROJECT_ID} — token access, PROJECT_ID drift, or non-ProjectV2 node" >&2
      return 75
    fi
    local id
    while IFS= read -r id || [ -n "${id}" ]; do
      id="${id%$'\r'}"
      [ -n "$id" ] || continue
      _ATP_ON_BOARD["$id"]=1
      count=$((count + 1))
    done < <(printf '%s' "${json}" | jq -r '.data.node?.items?.nodes?[]?.content?.id? // empty')
    [ "$(printf '%s' "${json}" | jq -r '.data.node?.items?.pageInfo?.hasNextPage?')" = "true" ] || break
    cursor=$(printf '%s' "${json}" | jq -r '.data.node?.items?.pageInfo?.endCursor? // ""')
    if [ -z "${cursor}" ]; then
      echo "::error::[reconcile] membership prefetch got hasNextPage=true with empty endCursor — API inconsistency, aborting" >&2
      return 75
    fi
  done
  echo "Prefetched ${count} board item(s) for membership fast-path."
  return 0
}
prefetch_board_membership
_ATP_MEMBERSHIP_READY=1

scanned=0
echo "Reconciling ${#repos[@]} repo(s) into ${PROJECT_URL:-the project}${DRY_RUN:+ (DRY RUN)}"
for repo in "${repos[@]}"; do
  [ -z "$repo" ] && continue
  echo "::group::${repo}"

  # Open issues AND PRs (the issues endpoint returns both). A PR carries a
  # `.pull_request` object; emit that so the loop can apply the required-label
  # gate to PRs only — issues are un-gated. Pass labels as the objects array
  # the gate expects. Fetch into a variable so an API failure is surfaced (not
  # silenced) and `set -e`'s check isn't bypassed by a subshell; feed the loop
  # via here-string so it stays in the parent shell and `scanned` updates.
  issues_tsv=$(gh api --paginate "repos/${repo}/issues?state=open&per_page=100" \
            --jq '.[] | [.node_id, .html_url, ([.labels?[]? | {name}] | @json), (if .pull_request then "pr" else "issue" end)] | @tsv') || {
    echo "::error::failed to fetch issues for ${repo}" >&2
    echo "::endgroup::"
    continue
  }
  while IFS=$'\t' read -r nid url labels kind || [ -n "$kind" ]; do
    kind="${kind%$'\r'}"
    [ -z "$nid" ] && continue
    scanned=$((scanned + 1))
    # Un-gate issues (empty required label); PRs keep the gate.
    if [ "$kind" = "pr" ]; then REQUIRED_LABEL="$pr_required"; else REQUIRED_LABEL=""; fi
    export REQUIRED_LABEL
    reconcile_content_with_project "$nid" "$url" "$labels"
  done <<< "$issues_tsv"

  echo "::endgroup::"
done

echo "Reconcile complete — scanned ${scanned} item(s) across ${#repos[@]} repo(s)."
