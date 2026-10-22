#!/usr/bin/env bash
# lib.sh — shared helpers for the add-to-project scripts.
#
# This is the "designed once" mechanism called for in
# petry-projects/.github#415: a single paginated project-item lookup
# (find_project_item) parameterized by a match predicate, plus the
# add / draft / delete mutations and the env guard. Both
# add-issue-or-pr.sh and reconcile-discussion.sh source this file so the
# reconcile machinery lives in one place rather than once per content type.
#
# Required env (checked by _atp_require_env):
#   PROJECT_ID            ProjectV2 node ID of the Initiatives project
#   GH_TOKEN              Token with org Projects: Read+write
#
# Optional env:
#   PROJECT_URL           Logged in human-readable messages only
#   PAGE_SIZE             Items fetched per GraphQL page (default 100)

set -euo pipefail

_atp_require_env() {
  if [ -z "${PROJECT_ID:-}" ]; then
    printf '[%s] PROJECT_ID env var is required\n' "$1" >&2
    return 64
  fi
  if [ -z "${GH_TOKEN:-}" ]; then
    printf '::error::[%s] GH_TOKEN is empty. INITIATIVES_APP_ID / INITIATIVES_APP_PRIVATE_KEY are likely unset or stale. See petry-projects/.github#387.\n' "$1" >&2
    return 64
  fi
}

# Prefetched board-membership cache (optional; batch reconcile only).
# reconcile-backlog.sh scans the whole fleet's open issues/PRs and would
# otherwise hit the API once PER item on both hot paths — a redundant
# idempotent add for items already on the board, and a find-to-remove for
# items that aren't on it. With the un-gated issue backlog (~450+ items) those
# per-item round-trips overrun the job timeout. So reconcile-backlog.sh
# populates `_ATP_ON_BOARD` (content_node_id -> 1) once, then sets
# `_ATP_MEMBERSHIP_READY=1`; the helpers below let the hot paths answer
# "is it already on the board?" from memory and skip the API call unless a
# genuine change is needed. The event path leaves both unset, so it always
# falls through to the network and its behavior is unchanged.
_atp_membership_ready() { [ "${_ATP_MEMBERSHIP_READY:-}" = "1" ]; }

# _atp_on_board <content_node_id>
#   Returns 0 if the cache says the content IS on the board, 1 if the cache
#   says it is NOT. MUST be gated by `_atp_membership_ready` — when no cache
#   has been populated the result is meaningless (there is nothing to consult).
_atp_on_board() { [ -n "${_ATP_ON_BOARD[$1]:-}" ]; }

# find_project_item <kind> <value>
#   kind=title-prefix  → match items whose content.title startswith <value>
#   kind=content-id    → match items whose content.id equals <value>
#
# Echoes the matching ProjectV2Item id (the first, if several match), or an
# empty string if none. Exit 0 on success; 64 on bad args; 75 when the
# project node comes back null (wrong PROJECT_ID / scope drift / archived) —
# failing loudly rather than treating it as an empty result and letting the
# caller add duplicates. Lookup is paginated so the project can grow past
# the first page without silently missing matches.
find_project_item() {
  if [ "$#" -ne 2 ]; then
    printf '[find_project_item] expected 2 args (kind value), got %d\n' "$#" >&2
    return 64
  fi
  local kind="$1"
  local value="$2"
  local page_size="${PAGE_SIZE:-100}"

  local noun
  case "${kind}" in
    title-prefix)
      noun='drafts match prefix'
      ;;
    content-id)
      noun='items match content-id'
      ;;
    *)
      printf '[find_project_item] unknown match kind %q (want title-prefix|content-id)\n' "${kind}" >&2
      return 64
      ;;
  esac

  # Cursor is a nullable String so a single query body handles both first
  # and subsequent pages. We omit the variable on the first call via shell
  # expansion below rather than coercing a literal "null".
  local cursor=""

  while true; do
    local json
    # shellcheck disable=SC2016  # $projectId/$pageSize/$cursor are GraphQL variables
    if [ -n "${cursor}" ]; then
      json=$(gh api graphql \
        -F projectId="${PROJECT_ID}" \
        -F pageSize="${page_size}" \
        -F cursor="${cursor}" \
        -f query='query($projectId:ID!, $pageSize:Int!, $cursor:String!){
          node(id:$projectId){
            ... on ProjectV2 {
              items(first:$pageSize, after:$cursor){
                pageInfo { endCursor hasNextPage }
                nodes {
                  id
                  content {
                    ... on DraftIssue { title }
                    ... on Issue       { id title }
                    ... on PullRequest { id title }
                  }
                }
              }
            }
          }
        }')
    else
      # shellcheck disable=SC2016
      json=$(gh api graphql \
        -F projectId="${PROJECT_ID}" \
        -F pageSize="${page_size}" \
        -f query='query($projectId:ID!, $pageSize:Int!){
          node(id:$projectId){
            ... on ProjectV2 {
              items(first:$pageSize){
                pageInfo { endCursor hasNextPage }
                nodes {
                  id
                  content {
                    ... on DraftIssue { title }
                    ... on Issue       { id title }
                    ... on PullRequest { id title }
                  }
                }
              }
            }
          }
        }')
    fi

    if [ "$(printf '%s' "${json}" | jq -r '.data.node')" = "null" ]; then
      printf '[find_project_item] GraphQL returned data.node:null. PROJECT_ID=%s — token may lack access, or the project was deleted.\n' "${PROJECT_ID}" >&2
      return 75
    fi

    # Parse match + page info in ONE jq invocation. The predicate is passed
    # to jq as $kind so the filter stays fully static (no shell interpolation).
    # `first(...)` emits at most one id and exits cleanly even when many
    # candidates match (avoids SIGPIPE from `| head -n 1` under pipefail).
    local parsed line match="" match_count=0 has_next="false" end_cursor=""
    parsed=$(printf '%s' "${json}" | jq -r \
      --arg kind "${kind}" \
      --arg val "${value}" \
      '
        (.data.node.items.nodes
          | map(select(
              if $kind == "title-prefix" then
                .content.title != null and (.content.title | startswith($val))
              elif $kind == "content-id" then
                .content.id != null and (.content.id == $val)
              else
                false
              end
            ))
        ) as $matches
        | "match=" + (first($matches[].id) // ""),
          "count=" + ($matches | length | tostring),
          "next="  + (.data.node.items.pageInfo.hasNextPage | tostring),
          "end="   + (.data.node.items.pageInfo.endCursor // "")
      ')

    # Read the four labelled lines without spawning a subshell per field.
    # `${line#prefix=}` strips only the leading key, so cursor values that
    # themselves contain '=' (base64 padding) survive intact.
    while IFS= read -r line; do
      case "${line}" in
        match=*) match="${line#match=}" ;;
        count=*) match_count="${line#count=}" ;;
        next=*)  has_next="${line#next=}" ;;
        end=*)   end_cursor="${line#end=}" ;;
      esac
    done <<< "${parsed}"

    if [ -n "${match}" ]; then
      if [ "${match_count}" != "1" ]; then
        # Multi-match on a single page indicates inconsistent state (manual
        # drafts shadowing automation). Warn so an operator can clean up,
        # but proceed with the first match so the state machine progresses.
        printf '[find_project_item] WARNING: %s %s %q. Returning first; reconcile may delete the wrong one.\n' \
          "${match_count}" "${noun}" "${value}" >&2
      fi
      printf '%s' "${match}"
      return 0
    fi

    if [ "${has_next}" != "true" ]; then
      return 0
    fi
    cursor="${end_cursor}"
  done
}

add_content_to_project() {
  if [ "$#" -ne 1 ]; then
    printf '[add_content_to_project] expected 1 arg (content_node_id), got %d\n' "$#" >&2
    return 64
  fi
  local content_node_id="$1"

  # Batch reconcile: if the prefetched membership cache already lists this
  # content, the add is a no-op (addProjectV2ItemById is idempotent) — skip it
  # entirely. Checked before DRY_RUN so dry-run reports accurate intent (no
  # "would add" for items already present) and a live run skips the network
  # round-trip. Gated on _atp_membership_ready so the event path (no cache)
  # always performs the add.
  if _atp_membership_ready && _atp_on_board "${content_node_id}"; then
    return 0
  fi

  if [ "${DRY_RUN:-}" = "1" ]; then
    printf '[dry-run] would add content %s to project\n' "${content_node_id}"
    return 0
  fi

  # addProjectV2ItemById is idempotent: adding content already on the board
  # returns the existing item, so the add path needs no find-first dedup.
  # shellcheck disable=SC2016  # $projectId/$contentId are GraphQL variables
  gh api graphql \
    -F projectId="${PROJECT_ID}" \
    -F contentId="${content_node_id}" \
    -f query='mutation($projectId:ID!,$contentId:ID!){
      addProjectV2ItemById(input:{projectId:$projectId,contentId:$contentId}){
        item { id }
      }
    }' >/dev/null
}

add_draft_item() {
  if [ "$#" -ne 2 ]; then
    printf '[add_draft_item] expected 2 args (title body), got %d\n' "$#" >&2
    return 64
  fi
  local title="$1"
  local body="$2"

  if [ "${DRY_RUN:-}" = "1" ]; then
    printf '[dry-run] would add draft: %s\n' "${title}"
    return 0
  fi

  # shellcheck disable=SC2016  # $projectId/$title/$body are GraphQL variables
  gh api graphql \
    -F projectId="${PROJECT_ID}" \
    -F title="${title}" \
    -F body="${body}" \
    -f query='mutation($projectId:ID!,$title:String!,$body:String!){
      addProjectV2DraftIssue(input:{projectId:$projectId,title:$title,body:$body}){
        projectItem { id }
      }
    }' >/dev/null
}

delete_project_item() {
  if [ "$#" -ne 1 ]; then
    printf '[delete_project_item] expected 1 arg (item_id), got %d\n' "$#" >&2
    return 64
  fi
  local item_id="$1"

  if [ "${DRY_RUN:-}" = "1" ]; then
    printf '[dry-run] would delete item %s from project\n' "${item_id}"
    return 0
  fi

  # Be idempotent on redelivered webhooks / racing runs: a "Could not
  # resolve" error from a no-longer-present item is the desired final state,
  # not a real failure. Capture stderr to inspect.
  local out
  if ! out=$(gh api graphql \
    -F projectId="${PROJECT_ID}" \
    -F itemId="${item_id}" \
    -f query='mutation($projectId:ID!,$itemId:ID!){
      deleteProjectV2Item(input:{projectId:$projectId,itemId:$itemId}){
        deletedItemId
      }
    }' 2>&1); then
    if printf '%s' "${out}" | grep -q -e 'Could not resolve to a node' -e 'not found'; then
      printf '[delete_project_item] item %s was already gone (idempotent path)\n' "${item_id}" >&2
      return 0
    fi
    printf '%s\n' "${out}" >&2
    return 1
  fi
}

# set_item_single_select_value <item_id> <field_id> <option_id>
#   Set a single-select field on one project item to the given option.
#
# This is updateProjectV2ItemFieldValue — a per-item VALUE write. It is NOT
# updateProjectV2Field (the schema mutation that full-replaces the option
# list and can orphan every item's value; see
# standards/initiatives-project.md → "Adding or modifying single-select
# options safely"). Writing an item value here can never wipe the schema, so
# a back-fill sweep over hundreds of items is inherently safe.
#
# Exit 0 on success; 64 on bad args. DRY_RUN=1 logs the intended write and
# mutates nothing.
set_item_single_select_value() {
  if [ "$#" -ne 3 ]; then
    printf '[set_item_single_select_value] expected 3 args (item_id field_id option_id), got %d\n' "$#" >&2
    return 64
  fi
  local item_id="$1"
  local field_id="$2"
  local option_id="$3"

  if [ "${DRY_RUN:-}" = "1" ]; then
    printf '[dry-run] would set item %s field %s = option %s\n' "${item_id}" "${field_id}" "${option_id}"
    return 0
  fi

  # optionId MUST use -f (raw string), NOT -F: `-F` does type inference, so an
  # all-numeric single-select option id (e.g. "91479014") is coerced to a JSON
  # number and the String! parameter rejects it ("provided invalid value").
  # The ID! args stay -F (node ids always carry a non-numeric prefix, so they
  # are never mis-coerced) — but optionId is plain hex and can be all-digits.
  # shellcheck disable=SC2016  # $projectId/$itemId/$fieldId/$optionId are GraphQL variables
  gh api graphql \
    -F projectId="${PROJECT_ID}" \
    -F itemId="${item_id}" \
    -F fieldId="${field_id}" \
    -f optionId="${option_id}" \
    -f query='mutation($projectId:ID!,$itemId:ID!,$fieldId:ID!,$optionId:String!){
      updateProjectV2ItemFieldValue(input:{
        projectId:$projectId, itemId:$itemId, fieldId:$fieldId,
        value:{ singleSelectOptionId:$optionId }
      }){
        projectV2Item { id }
      }
    }' >/dev/null
}
