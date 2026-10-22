#!/usr/bin/env bash
# scripts/lib/standards-deploy.sh — shared primitive for deploying an
# org-standard file to a consumer repo via a pull request.
#
# This is the single deploy primitive used by deploy-standard-workflows.sh (and
# available to any other standards-sync tooling). It NEVER pushes to a repo's
# default branch directly and NEVER merges or uses --admin. Instead it:
#
#   1. checks for an already-open PR on the sync branch (idempotent skip),
#   2. preflights that the token can write the repo (clear finding on a scope gap),
#   3. creates (or reuses) a sync branch off the repo's default branch,
#   4. PUTs the verbatim file content onto that branch via the Contents API,
#   5. opens a labeled pull request.
#
# Why a PR and not a direct push: a direct Contents-API push to the default
# branch is rejected (HTTP 409) on repos whose ruleset enforces required status
# checks — the Contents API does not honor the org-admin ruleset bypass. A PR
# works uniformly on protected and unprotected repos, runs the repo's CI against
# the change, and leaves an auditable record. See petry-projects/.github#478.
#
# Requires `gh` authenticated with repo scope (branch + PR creation).
#
# shellcheck shell=bash

# Guard against double-sourcing.
if [ -n "${_STANDARDS_DEPLOY_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_STANDARDS_DEPLOY_SOURCED=1

# sd_deploy_via_pr <repo_slug> <path> <local_file> <branch> <label> <title> <body>
#
#   repo_slug   owner/name of the target repo (e.g. petry-projects/markets)
#   path        path of the file within the target repo
#   local_file  local file whose contents are deployed verbatim
#   branch      head branch to create/reuse for the PR
#   label       label applied to the opened PR (e.g. standards-sync)
#   title       commit message and PR title
#   body        PR body (markdown)
#
# Prints exactly one outcome token line to stdout:
#   OPENED <pr-url>            a PR was opened
#   SKIP_PR_OPEN <pr-number>   an open labeled sync PR already exists for the repo
#   FAILED <reason>            a hard error occurred (reason is a short slug)
#
# Returns 0 for OPENED/SKIP_PR_OPEN, non-zero for FAILED. Emits no other stdout,
# so callers can capture the outcome with a command substitution.
# Single-file convenience wrapper around sd_deploy_files_via_pr.
sd_deploy_via_pr() {
  local repo="$1" path="$2" local_file="$3" branch="$4" label="$5" title="$6" body="$7"
  sd_deploy_files_via_pr "$repo" "$branch" "$label" "$title" "$body" "$path" "$local_file"
}

# sd_deploy_files_via_pr <repo> <branch> <label> <title> <body> \
#                        <path> <local_file> [<path> <local_file> ...]
#
# Deploys one OR MORE files to a repo in a SINGLE labeled PR. A fleet re-sync of
# N stubs for a repo is therefore N files in one PR, not N PRs. Idempotency is
# keyed by the label — at most one open sync PR per repo; if one already exists
# it is reused (skip). Trailing args are (path, local_file) pairs.
sd_deploy_files_via_pr() {
  local repo="$1" branch="$2" label="$3" title="$4" body="$5"
  shift 5

  if [ "$#" -eq 0 ] || [ $(( $# % 2 )) -ne 0 ]; then
    echo "FAILED bad-file-args"
    return 1
  fi

  # Validate every local file up front, before touching the remote.
  local i
  for (( i = 2; i <= $#; i += 2 )); do
    if [ ! -f "${!i}" ]; then echo "FAILED missing-local-file"; return 1; fi
  done

  # 1. Idempotency — at most one open sync PR per repo, keyed by label.
  local existing_pr
  existing_pr=$(gh pr list --repo "$repo" --label "$label" --state open \
    --json number --jq '.[0].number // ""' 2>/dev/null || true)
  if [ -n "$existing_pr" ]; then
    echo "SKIP_PR_OPEN $existing_pr"
    return 0
  fi

  # 2. Preflight write check. The driver must run under a contents/PR-write
  #    identity; an audit/read-only token silently produces per-file 422s deep in
  #    step 5 (petry-projects/.github#864). Probe the repo permission set once, up
  #    front, so a token-scope gap surfaces as one clear finding, not opaque
  #    per-file put-failures. The probe's OWN errors (a transient/auth/404) are
  #    surfaced distinctly — they must NOT be misreported as "no write access".
  #    Repo-level push permission implies PR-create for a collaborator identity.
  local can_push perm_err perm_rc
  perm_err=$(mktemp)
  can_push=$(gh api "repos/${repo}" --jq '.permissions.push // false' 2>"$perm_err") && perm_rc=0 || perm_rc=$?
  if [ "$perm_rc" -ne 0 ]; then
    local perm_msg; perm_msg=$(tr '\n' ' ' < "$perm_err"); rm -f "$perm_err"
    echo "FAILED perm-probe-failed:${perm_msg}"
    return 1
  fi
  rm -f "$perm_err"
  if [ "$can_push" != "true" ]; then
    echo "FAILED no-write-access"
    return 1
  fi

  # 3. Resolve the default branch and its tip SHA (branch point).
  local default_branch base_sha
  default_branch=$(gh api "repos/${repo}" --jq '.default_branch' 2>/dev/null || echo "main")
  base_sha=$(gh api "repos/${repo}/git/ref/heads/${default_branch}" \
    --jq '.object.sha' 2>/dev/null || true)
  if [ -z "$base_sha" ]; then
    echo "FAILED no-base-sha"
    return 1
  fi

  # 4. Create the sync branch; reuse it if a prior run already created it.
  if ! gh api "repos/${repo}/git/refs" --method POST \
        --raw-field "ref=refs/heads/${branch}" \
        --raw-field "sha=${base_sha}" --silent 2>/dev/null; then
    if ! gh api "repos/${repo}/git/ref/heads/${branch}" --silent 2>/dev/null; then
      echo "FAILED no-branch"
      return 1
    fi
  fi

  # 5. PUT each file verbatim onto the branch. The blob SHA is looked up per file
  #    on the branch so both create (absent → empty SHA) and update (drifted stub)
  #    work, whether the branch is fresh or reused. Errors are NOT swallowed: a
  #    read failure that yields an empty SHA would make the subsequent PUT omit
  #    `sha` and 422 against an existing file — the exact opaque failure in #864.
  local path local_file branch_sha encoded j err_file get_rc get_msg put_msg
  for (( i = 1; i < $#; i += 2 )); do
    j=$(( i + 1 )); path="${!i}"; local_file="${!j}"

    # Resolve the file's blob SHA on the branch, capturing stderr and exit code.
    err_file=$(mktemp)
    branch_sha=$(gh api "repos/${repo}/contents/${path}?ref=${branch}" \
      --jq '.sha // ""' 2>"$err_file") && get_rc=0 || get_rc=$?
    if [ "$get_rc" -eq 0 ]; then
      # GET succeeded → the file EXISTS on the branch, so its SHA must resolve.
      # A blank SHA here means we cannot update it safely; a sha-less PUT would
      # 422. Fail loudly rather than mask it.
      if [ -z "$branch_sha" ]; then
        rm -f "$err_file"
        echo "FAILED sha-unresolved:${path}"
        return 1
      fi
    else
      get_msg=$(tr '\n' ' ' < "$err_file"); rm -f "$err_file"
      if printf '%s' "$get_msg" | grep -q 'HTTP 404'; then
        branch_sha=""   # file absent on the branch → create path, no SHA
      else
        echo "FAILED contents-get-failed:${get_msg}"
        return 1
      fi
    fi
    rm -f "$err_file"

    encoded=$(base64 -w 0 "$local_file" 2>/dev/null || base64 -b 0 "$local_file")

    local put_args=(--method PUT
      --raw-field "message=${title}"
      --raw-field "content=${encoded}"
      --raw-field "branch=${branch}")
    [ -n "$branch_sha" ] && put_args+=(--raw-field "sha=${branch_sha}")

    err_file=$(mktemp)
    if ! gh api "repos/${repo}/contents/${path}" "${put_args[@]}" --silent 2>"$err_file"; then
      put_msg=$(tr '\n' ' ' < "$err_file"); rm -f "$err_file"
      echo "FAILED put-failed:${put_msg}"
      return 1
    fi
    rm -f "$err_file"
  done

  # 6. Ensure the label exists, then open the PR. `gh pr create --label` fails
  #    outright if the label is absent, and consumer repos do not carry the
  #    standards-sync label by default. Create-if-missing (no --force, so an
  #    existing curated label is never clobbered); ignore the "already exists"
  #    error.
  gh label create "$label" --repo "$repo" \
    --color ededed \
    --description "Org-standard workflow stub synced from ${repo%%/*}/.github" \
    >/dev/null 2>&1 || true

  local pr_url
  pr_url=$(gh pr create --repo "$repo" --head "$branch" --base "$default_branch" \
    --title "$title" --body "$body" --label "$label" 2>/dev/null || true)
  if [ -z "$pr_url" ]; then
    echo "FAILED pr-create-failed"
    return 1
  fi

  echo "OPENED $pr_url"
  return 0
}
