#!/usr/bin/env bash
# gh-safe.sh — defensive wrapper around `gh` calls used by feature-ideation.
#
# Why this exists:
#   The original workflow used the `2>/dev/null || echo '[]'` pattern, which
#   silently swallows ALL errors — auth failures, rate limits, network outages,
#   GraphQL schema drift — and continues with empty data. The pipeline would
#   "succeed" while producing useless signals.
#
# Contract:
#   - On a documented empty result (200 OK + []) → exit 0, stdout is the empty array
#   - On any infrastructure error                  → exit non-zero, stderr explains why
#   - On a GraphQL response containing an "errors" field → exit non-zero
#   - On a GraphQL response with `data: null`            → exit non-zero
#
# Usage:
#   source .github/scripts/feature-ideation/lib/gh-safe.sh
#   ISSUES=$(gh_safe_rest issue list --repo "$REPO" --state open --limit 50 \
#              --json number,title,labels)
#   DISCUSSIONS=$(gh_safe_graphql "$query" -f owner=foo -f repo=bar \
#                   --jq '.data.repository.discussions.nodes')

set -euo pipefail

# Marker emitted by callers when they want to default to "[]" — explicit, not silent.
GH_SAFE_EMPTY_ARRAY='[]'

# Internal: emit a structured error to stderr.
_gh_safe_err() {
  local code="$1"
  shift
  printf '[gh-safe][%s] %s\n' "$code" "$*" >&2
}

# Validate that a string is well-formed JSON. Returns 0 if valid.
gh_safe_is_json() {
  local input="$1"
  [ -n "$input" ] || return 1
  printf '%s' "$input" | jq -e . >/dev/null 2>&1
}

# Run a `gh` REST/CLI call (gh issue list, gh pr list, gh release list, etc.).
# Captures stdout, stderr, and exit code separately so we can distinguish:
#   - empty result (success, output is "[]" or empty)
#   - hard failure (non-zero exit) — never silently downgraded
#
# Arguments are passed verbatim to `gh`.
gh_safe_rest() {
  local stdout stderr rc tmp_err
  tmp_err=$(mktemp)
  # shellcheck disable=SC2034
  set +e
  stdout=$(gh "$@" 2>"$tmp_err")
  rc=$?
  set -e
  stderr=$(cat "$tmp_err")
  rm -f "$tmp_err"

  if [ "$rc" -ne 0 ]; then
    _gh_safe_err "rest-failure" "exit=$rc args=$* stderr=$stderr"
    return "$rc"
  fi

  # Empty stdout from a successful gh call means the result set is empty.
  # Normalize to an empty JSON array so downstream jq composition never sees "".
  if [ -z "$stdout" ]; then
    printf '%s' "$GH_SAFE_EMPTY_ARRAY"
    return 0
  fi

  # Validate JSON shape — if gh ever returns non-JSON on success, fail loud.
  if ! gh_safe_is_json "$stdout"; then
    _gh_safe_err "rest-bad-json" "args=$* stdout (first 200 bytes)=${stdout:0:200}"
    return 65  # EX_DATAERR
  fi

  printf '%s' "$stdout"
}

# Run a `gh api graphql` call. Same defensive contract as gh_safe_rest, plus:
#   - Reject responses where the parsed result is the literal "null"
#   - Reject responses with a top-level "errors" field (only meaningful when
#     called WITHOUT --jq, i.e. when callers ask for the full response)
#
# When --jq is supplied, we cannot inspect the full response for an errors[]
# field, so we additionally call gh once WITHOUT --jq to validate the envelope.
# This costs an extra round-trip; for the feature-ideation workflow's volume
# (a handful of calls per run) this is the right trade-off.
gh_safe_graphql() {
  local args=("$@")
  local has_jq=0
  local jq_filter=""
  local i=0
  while [ "$i" -lt "${#args[@]}" ]; do
    if [ "${args[$i]}" = "--jq" ]; then
      # Guard bounds before dereferencing args[i+1]: under set -u an out-of-
      # bounds access aborts the shell. Caught by CodeRabbit review on PR
      # petry-projects/.github#85.
      if [ $((i + 1)) -ge "${#args[@]}" ]; then
        _gh_safe_err "graphql-bad-args" "--jq requires a jq filter argument"
        return 64
      fi
      has_jq=1
      jq_filter="${args[$((i + 1))]}"
      break
    fi
    i=$((i + 1))
  done

  # Build a no-jq variant for envelope validation.
  local raw_args=()
  i=0
  while [ "$i" -lt "${#args[@]}" ]; do
    if [ "${args[$i]}" = "--jq" ]; then
      i=$((i + 2))
      continue
    fi
    raw_args+=("${args[$i]}")
    i=$((i + 1))
  done

  local raw stderr rc tmp_err
  tmp_err=$(mktemp)
  set +e
  raw=$(gh api graphql "${raw_args[@]}" 2>"$tmp_err")
  rc=$?
  set -e
  stderr=$(cat "$tmp_err")
  rm -f "$tmp_err"

  if [ "$rc" -ne 0 ]; then
    _gh_safe_err "graphql-failure" "exit=$rc stderr=$stderr"
    return "$rc"
  fi

  if ! gh_safe_is_json "$raw"; then
    _gh_safe_err "graphql-bad-json" "first 200 bytes: ${raw:0:200}"
    return 65
  fi

  # Reject error envelopes — GraphQL returns 200 OK even on partial errors.
  if printf '%s' "$raw" | jq -e '(.errors // empty | type) == "array" and (.errors | length > 0)' >/dev/null 2>&1; then
    local errs
    errs=$(printf '%s' "$raw" | jq -c '.errors')
    _gh_safe_err "graphql-errors" "$errs"
    return 66  # EX_NOINPUT — repurposed: "GraphQL refused our request"
  fi

  # Reject `data: null` — usually means the path didn't resolve (permissions,
  # missing field, renamed repo).
  if printf '%s' "$raw" | jq -e '.data == null' >/dev/null 2>&1; then
    _gh_safe_err "graphql-null-data" "data field is null"
    return 66
  fi

  # If caller asked for a jq filter, apply it now and return that.
  if [ "$has_jq" -eq 1 ]; then
    # NB: do NOT swallow jq errors with `|| true`. A typo or wrong path in
    # the filter must surface as a hard failure, not a silent empty result —
    # otherwise we re-introduce R1 in a different shape. Caught by Copilot
    # review on PR petry-projects/.github#85.
    local filtered jq_rc jq_err
    jq_err=$(mktemp)
    set +e
    filtered=$(printf '%s' "$raw" | jq -c "$jq_filter" 2>"$jq_err")
    jq_rc=$?
    set -e
    if [ "$jq_rc" -ne 0 ]; then
      _gh_safe_err "graphql-jq-failed" "filter='$jq_filter' err=$(cat "$jq_err")"
      rm -f "$jq_err"
      return 65
    fi
    rm -f "$jq_err"
    if [ "$filtered" = "null" ] || [ -z "$filtered" ]; then
      # Filter resolved to JSON null (e.g. nodes path returned null) — this
      # is the documented "no results" case. Normalize to empty array.
      printf '%s' "$GH_SAFE_EMPTY_ARRAY"
      return 0
    fi
    printf '%s' "$filtered"
    return 0
  fi

  printf '%s' "$raw"
}

# Send a fully-formed GraphQL request body via stdin. Use this when the
# variables include arrays or other shapes that `gh api`'s -f/-F flags
# cannot express (e.g. `labelIds: [ID!]!`). The body must be a JSON
# document with `query` and `variables` top-level fields.
#
# Same defensive contract as `gh_safe_graphql`: any auth/network/schema
# failure exits non-zero with a structured stderr message.
gh_safe_graphql_input() {
  # Guard arg count before reading $1: under set -u a zero-arg call aborts the
  # shell instead of reaching the JSON validation. Caught by CodeRabbit review
  # on PR petry-projects/.github#85.
  if [ "$#" -ne 1 ]; then
    _gh_safe_err "graphql-bad-input" "expected 1 arg: JSON request body, got $#"
    return 64
  fi
  local body="$1"
  if ! gh_safe_is_json "$body"; then
    _gh_safe_err "graphql-bad-input" "request body is not valid JSON"
    return 64
  fi

  local raw stderr rc tmp_err
  tmp_err=$(mktemp)
  set +e
  raw=$(printf '%s' "$body" | gh api graphql --input - 2>"$tmp_err")
  rc=$?
  set -e
  stderr=$(cat "$tmp_err")
  rm -f "$tmp_err"

  if [ "$rc" -ne 0 ]; then
    _gh_safe_err "graphql-failure" "exit=$rc stderr=$stderr"
    return "$rc"
  fi

  if ! gh_safe_is_json "$raw"; then
    _gh_safe_err "graphql-bad-json" "first 200 bytes: ${raw:0:200}"
    return 65
  fi

  if printf '%s' "$raw" | jq -e '(.errors // empty | type) == "array" and (.errors | length > 0)' >/dev/null 2>&1; then
    local errs
    errs=$(printf '%s' "$raw" | jq -c '.errors')
    _gh_safe_err "graphql-errors" "$errs"
    return 66
  fi

  if printf '%s' "$raw" | jq -e '.data == null' >/dev/null 2>&1; then
    _gh_safe_err "graphql-null-data" "data field is null"
    return 66
  fi

  printf '%s' "$raw"
}
