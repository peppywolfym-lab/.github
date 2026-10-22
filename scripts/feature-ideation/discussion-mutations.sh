#!/usr/bin/env bash
# discussion-mutations.sh — wrappers around the GraphQL mutations Mary uses
# to create / comment on Ideas Discussions, with a DRY_RUN switch.
#
# Why this exists:
#   The original prompt instructed Mary to call `gh api graphql` directly for
#   createDiscussion / addDiscussionComment. There was no way to:
#     - safely smoke-test the workflow on a sandbox repo
#     - replay a run without writing to GitHub
#     - audit what Mary was about to do before she did it
#
#   With DRY_RUN=1, every mutation logs a structured "planned action" entry
#   instead of executing. The plan log is the contract Mary's prompt now
#   references.
#
# Env:
#   DRY_RUN              "1" → log instead of execute
#   DRY_RUN_LOG          path to JSONL log file (default: ./dry-run.jsonl)
#   GH_TOKEN             required when not in DRY_RUN
#
# Functions:
#   create_discussion <repo_id> <category_id> <title> <body>
#   comment_on_discussion <discussion_id> <body>
#   add_label_to_discussion <discussion_id> <label_id>

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/gh-safe.sh
. "${SCRIPT_DIR}/lib/gh-safe.sh"

_dry_run_log() {
  local action_json="$1"
  local log_path="${DRY_RUN_LOG:-./dry-run.jsonl}"
  printf '%s\n' "$action_json" >>"$log_path"
}

_is_dry_run() {
  [ "${DRY_RUN:-0}" = "1" ]
}

create_discussion() {
  if [ "$#" -ne 4 ]; then
    printf '[create_discussion] expected 4 args (repo_id category_id title body), got %d\n' "$#" >&2
    return 64
  fi
  local repo_id="$1"
  local category_id="$2"
  local title="$3"
  local body="$4"

  if _is_dry_run; then
    local entry
    entry=$(jq -nc \
      --arg op "create_discussion" \
      --arg repo_id "$repo_id" \
      --arg category_id "$category_id" \
      --arg title "$title" \
      --arg body "$body" \
      '{op: $op, repo_id: $repo_id, category_id: $category_id, title: $title, body: $body}')
    _dry_run_log "$entry"
    printf '%s' "$entry"
    return 0
  fi

  local query
  read -r -d '' query <<'GRAPHQL' || true
mutation($repoId: ID!, $categoryId: ID!, $title: String!, $body: String!) {
  createDiscussion(input: {
    repositoryId: $repoId,
    categoryId: $categoryId,
    title: $title,
    body: $body
  }) {
    discussion { id number url }
  }
}
GRAPHQL

  gh_safe_graphql -f query="$query" \
    -f repoId="$repo_id" \
    -f categoryId="$category_id" \
    -f title="$title" \
    -f body="$body"
}

comment_on_discussion() {
  if [ "$#" -ne 2 ]; then
    printf '[comment_on_discussion] expected 2 args (discussion_id body), got %d\n' "$#" >&2
    return 64
  fi
  local discussion_id="$1"
  local body="$2"

  if _is_dry_run; then
    local entry
    entry=$(jq -nc \
      --arg op "comment_on_discussion" \
      --arg discussion_id "$discussion_id" \
      --arg body "$body" \
      '{op: $op, discussion_id: $discussion_id, body: $body}')
    _dry_run_log "$entry"
    printf '%s' "$entry"
    return 0
  fi

  local query
  read -r -d '' query <<'GRAPHQL' || true
mutation($discussionId: ID!, $body: String!) {
  addDiscussionComment(input: {
    discussionId: $discussionId,
    body: $body
  }) {
    comment { id url }
  }
}
GRAPHQL

  gh_safe_graphql -f query="$query" \
    -f discussionId="$discussion_id" \
    -f body="$body"
}

add_label_to_discussion() {
  if [ "$#" -ne 2 ]; then
    printf '[add_label_to_discussion] expected 2 args (discussion_id label_id), got %d\n' "$#" >&2
    return 64
  fi
  local discussion_id="$1"
  local label_id="$2"

  if _is_dry_run; then
    local entry
    entry=$(jq -nc \
      --arg op "add_label_to_discussion" \
      --arg discussion_id "$discussion_id" \
      --arg label_id "$label_id" \
      '{op: $op, discussion_id: $discussion_id, label_id: $label_id}')
    _dry_run_log "$entry"
    printf '%s' "$entry"
    return 0
  fi

  local query
  read -r -d '' query <<'GRAPHQL' || true
mutation($labelableId: ID!, $labelIds: [ID!]!) {
  addLabelsToLabelable(input: {
    labelableId: $labelableId,
    labelIds: $labelIds
  }) {
    clientMutationId
  }
}
GRAPHQL

  # GraphQL `labelIds: [ID!]!` requires a JSON array variable. `gh api`'s
  # `-f`/`-F` flags don't express GraphQL array variables, so build the
  # full request body as JSON and send it via stdin. Caught by Copilot
  # review on PR petry-projects/.github#85: the previous version sent
  # labelIds as the literal string `["L_1"]`, which the API rejects.
  local body
  body=$(jq -nc --arg q "$query" --arg id "$discussion_id" --arg label "$label_id" \
    '{query: $q, variables: {labelableId: $id, labelIds: [$label]}}')

  gh_safe_graphql_input "$body"
}
