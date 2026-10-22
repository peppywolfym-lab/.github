#!/usr/bin/env bash
# sync-gitignore-baseline.sh — append-or-replace the org secrets baseline (the L1
# block) in every org repo's .gitignore (issue #798).
#
# The canonical, marker-wrapped L1 block lives in this repo's root /.gitignore
# (maintained under STORY1, #797). This sweep places it in repos that lack it and
# REFRESHES it in place where it has drifted, using the shared, idempotent
# upsert_gitignore_baseline() — so a repo's per-repo L2 (everything below the END
# marker) is never touched.
#
# Deployment is PR-based, never a direct push to the default branch: a direct
# Contents-API push is rejected (HTTP 409) on repos whose ruleset enforces
# required status checks. The PRs are labeled `gitignore-baseline` and left for
# the normal review/auto-merge pipeline — this script never merges. It mirrors
# deploy-standard-workflows.sh and shares its sd_deploy_via_pr() primitive.
#
# Usage:
#   sync-gitignore-baseline.sh [options]
#
# Options:
#   --dry-run          Print planned actions without opening any PRs.
#   --repo <name>      Target a single repo instead of all org repos.
#   --force            Open a PR even if the repo's baseline already matches.
#
# Requirements:
#   GH_TOKEN (or gh auth login) with repo scope (branch + PR creation).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/standards-deploy.sh
source "$SCRIPT_DIR/lib/standards-deploy.sh"
# shellcheck source=scripts/lib/gitignore-baseline.sh
source "$SCRIPT_DIR/lib/gitignore-baseline.sh"

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
for _cmd in gh jq base64; do
  command -v "$_cmd" >/dev/null 2>&1 || { echo "::error::${_cmd} is required but not installed." >&2; exit 1; }
done
unset _cmd

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ORG="petry-projects"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Canonical source of the marker-wrapped L1 block; overridable as a test seam.
GITIGNORE_CANONICAL="${GITIGNORE_CANONICAL:-$REPO_ROOT/.gitignore}"

SYNC_BRANCH_PREFIX="gitignore-baseline"
SYNC_LABEL="gitignore-baseline"

# Repos exempt from the sweep.
#   .github         — hosts the canonical /.gitignore; syncing it to itself is circular.
#   .github-private — self-manages its own tree.
SKIP_REPOS=(".github" ".github-private")

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DRY_RUN=false
TARGET_REPO=""
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --force)   FORCE=true;   shift ;;
    --repo)    TARGET_REPO="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[gitignore-sync] $*"; }
skip() { echo "[gitignore-sync] SKIP  $*"; }
dry()  { echo "[gitignore-sync] DRY   $*"; }
ok()   { echo "[gitignore-sync] OK    $*"; }
err()  { echo "[gitignore-sync] ERROR $*" >&2; }

is_skipped_repo() {
  local repo="$1" s
  for s in "${SKIP_REPOS[@]}"; do
    [[ "$repo" == "$s" ]] && return 0
  done
  return 1
}

# fetch_gitignore <repo> — print the repo's decoded .gitignore, or empty on 404.
# Parses the Contents API JSON with jq locally (not `gh --jq`) so the decode path
# is identical to deploy-standard-workflows.sh's fetch_existing.
fetch_gitignore() {
  local repo="$1" raw encoded
  raw=$(gh api "repos/$ORG/$repo/contents/.gitignore" 2>/dev/null) || { printf ''; return; }
  encoded=$(printf '%s' "$raw" | jq -r '.content // empty' 2>/dev/null || true)
  [ -n "$encoded" ] && printf '%s' "$encoded" | { base64 -d 2>/dev/null || base64 -D 2>/dev/null; } || true
}

# ---------------------------------------------------------------------------
# Sync a single repo: upsert the baseline, open a PR if it changes anything.
# ---------------------------------------------------------------------------
sync_repo() {
  local repo="$1"
  if is_skipped_repo "$repo"; then
    skip "$repo (exempt)"
    return 0
  fi

  local existing action existfile upserted
  existing="$(fetch_gitignore "$repo")"
  if printf '%s\n' "$existing" | grep -qxF "$GIB_BEGIN_MARKER"; then
    action="REFRESH"
  else
    action="INSERT"
  fi

  existfile="$(mktemp)"
  tmpfiles+=("$existfile")
  printf '%s' "$existing" > "$existfile"
  upserted="$(upsert_gitignore_baseline "$BLOCK_FILE" "$existfile")" \
    || { rm -f "$existfile"; err "$repo — upsert failed"; return 1; }
  rm -f "$existfile"

  if [[ "$existing" == "$upserted" ]] && [[ "$FORCE" == "false" ]]; then
    skip "$repo/.gitignore already carries the current baseline"
    return 0
  fi

  local branch title body
  branch="${SYNC_BRANCH_PREFIX}/$(date -u +%Y%m%d)"
  title="chore: ${action,,} org secrets baseline in .gitignore"
  body="$(printf 'Syncs the marker-wrapped org secrets baseline (L1) into \`.gitignore\` (%s), preserving this repo'\''s per-repo L2 entries below the END marker. Opened by `scripts/sync-gitignore-baseline.sh` — see `standards/gitignore-standard.md`. Labeled `%s` and left for the normal review/auto-merge pipeline; the sweep never merges directly.\n' "$action" "$SYNC_LABEL")"

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "Would open PR for $repo (branch $branch) — .gitignore secrets baseline ($action)"
    return 0
  fi

  local upfile outcome
  upfile="$(mktemp)"
  tmpfiles+=("$upfile")
  printf '%s\n' "$upserted" > "$upfile"
  outcome=$(sd_deploy_via_pr "$ORG/$repo" ".gitignore" "$upfile" "$branch" "$SYNC_LABEL" "$title" "$body") || true
  rm -f "$upfile"

  case "$outcome" in
    "OPENED "*)       ok   "$repo — opened ${outcome#OPENED } (.gitignore baseline, $action)" ;;
    "SKIP_PR_OPEN "*) skip "$repo — sync PR #${outcome#SKIP_PR_OPEN } already open" ;;
    "FAILED "*)       err  "$repo — ${outcome#FAILED }" ;;
    *)                err  "$repo — unexpected outcome: ${outcome:-<none>}" ;;
  esac
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
[[ "$DRY_RUN" == "true" ]] && log "DRY RUN — no PRs will be opened"

# Extract the canonical block once, up front — a missing/half-open block is a
# hard error (never ship a partial baseline).
declare -a tmpfiles=()
trap '[ "${#tmpfiles[@]}" -eq 0 ] || rm -f "${tmpfiles[@]}"' EXIT

BLOCK_FILE="$(mktemp)"
tmpfiles+=("$BLOCK_FILE")
if ! gib_extract_baseline_block "$GITIGNORE_CANONICAL" > "$BLOCK_FILE"; then
  err "could not read the marker-wrapped baseline block from $GITIGNORE_CANONICAL"
  exit 1
fi

# Resolve target repos.
declare -a REPOS
if [[ -n "$TARGET_REPO" ]]; then
  REPOS=("$TARGET_REPO")
else
  mapfile -t REPOS < <(gh repo list "$ORG" --limit 500 --no-archived --json name -q '.[].name')
fi

log "Syncing the .gitignore secrets baseline to ${#REPOS[@]} repo(s)"

for repo in "${REPOS[@]}"; do
  sync_repo "$repo"
done

log "Done."
