#!/usr/bin/env bash
# fix-ruleset-bypass.sh — Normalize ruleset bypass actors on petry-projects repos
#
# Companion to apply-rulesets.sh and compliance-audit.sh. Brings the bypass
# actors of EVERY ruleset that targets the default branch into compliance with:
#   standards/github-settings.md#bypass-actors--required-on-every-ruleset-targeting-main
#
# The standard requires that every such ruleset grant `bypass_mode: always` to
# BOTH:
#   1. the `dependabot-automerge-petry` GitHub App (Integration, actor_id 3167543)
#   2. the `OrganizationAdmin` role
#
# Unlike apply-rulesets.sh (which only manages `pr-quality` and `code-quality`
# by full-replace), this script patches bypass actors on ANY ruleset targeting
# the default branch — including legacy `protect-branches` / `main` rulesets
# that apply-rulesets.sh leaves untouched. It is the missing remediation for
# the bypass-actor findings raised by compliance-audit.sh.
#
# Transform is least-destructive: existing bypass actors are preserved, EXCEPT
# that any existing OrganizationAdmin or dependabot-app entry is normalized to
# `bypass_mode: always`. Other actors (e.g. a Repository admin role, or an
# extra Integration) are kept as-is — they are not forbidden by the standard,
# they are just not sufficient on their own. To collapse a ruleset to exactly
# the two canonical actors, run apply-rulesets.sh (pr-quality / code-quality
# only).
#
# Usage:
#   # Dry run — write ready-to-PUT payloads to OUT_DIR and print a change summary:
#   GH_TOKEN=<admin-token> ./scripts/fix-ruleset-bypass.sh <repo-name> --dry-run
#   GH_TOKEN=<admin-token> ./scripts/fix-ruleset-bypass.sh --all --dry-run
#
#   # Apply (PUT) the changes to live rulesets:
#   GH_TOKEN=<admin-token> ./scripts/fix-ruleset-bypass.sh <repo-name>
#   GH_TOKEN=<admin-token> ./scripts/fix-ruleset-bypass.sh --all
#
# Environment variables:
#   GH_TOKEN   GitHub token with administration:write scope (required to apply)
#   OUT_DIR    Directory for dry-run payloads (default: a temp dir outside the
#              repo, so generated payloads are never accidentally committed)
#
# Requirements:
#   - GH_TOKEN must have administration:write scope on the target repo(s)
#   - gh CLI and jq must be installed

set -euo pipefail

ORG="petry-projects"
DRY_RUN=false
OUT_DIR="${OUT_DIR:-${TMPDIR:-/tmp}/petry-ruleset-payloads}"

# Required bypass actors (see standard).
DEPENDABOT_APP_ACTOR_ID=3167543

info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
err()   { echo "[ERROR] $*" >&2; }
skip()  { echo "[SKIP]  $*"; }

usage() {
  echo "Usage: $0 <repo-name> [--dry-run]"
  echo "       $0 --all [--dry-run]"
  echo ""
  echo "Environment variables:"
  echo "  GH_TOKEN   GitHub token with administration:write scope (required to apply)"
  echo "  OUT_DIR    Directory for dry-run payloads (default: a temp dir outside the repo)"
  exit 1
}

# ---------------------------------------------------------------------------
# Does a ruleset (full GET JSON on stdin via $1) target the default branch?
# Matches GitHub aliases (~DEFAULT_BRANCH, ~ALL) or an explicit refs/heads/<db>,
# but NOT if the default branch is in the exclude list (a ruleset may include
# ~ALL yet exclude main). Must stay in lockstep with check_ruleset_bypass_actors
# in compliance-audit.sh so remediation and detection agree on the target set.
# ---------------------------------------------------------------------------
targets_default_branch() {
  local rs="$1" default_branch="$2"
  echo "$rs" | jq -e --arg db "refs/heads/$default_branch" '
    ((.conditions.ref_name.include) // []) as $inc
    | ((.conditions.ref_name.exclude) // []) as $exc
    | (
        (($inc | index("~DEFAULT_BRANCH")) != null)
        or (($inc | index("~ALL")) != null)
        or (($inc | index($db)) != null)
      )
      and (($exc | index("~DEFAULT_BRANCH")) == null)
      and (($exc | index($db)) == null)
  ' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Build the PUT payload from a ruleset's GET JSON.
# Keeps name/target/enforcement/conditions/rules verbatim; normalizes
# bypass_actors: drop any existing OrganizationAdmin / dependabot-app entries
# (any mode), preserve all other actors, then append the two canonical actors
# with bypass_mode: always.
# ---------------------------------------------------------------------------
build_put_payload() {
  local rs="$1"
  echo "$rs" | jq --argjson dep "$DEPENDABOT_APP_ACTOR_ID" '
    {
      name,
      target,
      enforcement,
      conditions,
      rules,
      bypass_actors: (
        [ (.bypass_actors // [])[]
          | select(
              ((.actor_type == "OrganizationAdmin")
               or (.actor_type == "Integration" and .actor_id == $dep)) | not
            )
        ]
        + [
            { actor_id: 0,    actor_type: "OrganizationAdmin", bypass_mode: "always" },
            { actor_id: $dep, actor_type: "Integration",       bypass_mode: "always" }
          ]
      )
    }
  '
}

# ---------------------------------------------------------------------------
# Is a ruleset already compliant (both required actors present as `always`)?
# ---------------------------------------------------------------------------
is_compliant() {
  local rs="$1"
  echo "$rs" | jq -e --argjson dep "$DEPENDABOT_APP_ACTOR_ID" '
    ([.bypass_actors[]? | select(.actor_type == "OrganizationAdmin" and .bypass_mode == "always")] | length > 0)
    and
    ([.bypass_actors[]? | select(.actor_type == "Integration" and .actor_id == $dep and .bypass_mode == "always")] | length > 0)
  ' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Process one repo
# ---------------------------------------------------------------------------
fix_repo() {
  local repo="$1"
  info "Processing $ORG/$repo ..."

  local default_branch
  default_branch=$(gh api "repos/$ORG/$repo" --jq '.default_branch // "main"' 2>/dev/null || echo "main")
  [ -z "$default_branch" ] || [ "$default_branch" = "null" ] && default_branch="main"

  local rulesets
  rulesets=$(gh api "repos/$ORG/$repo/rulesets" 2>/dev/null || echo "[]")

  local ids
  ids=$(echo "$rulesets" | jq -r '.[].id' 2>/dev/null || echo "")
  if [ -z "$ids" ]; then
    skip "  No rulesets on $ORG/$repo"
    return 0
  fi

  local rs_id
  for rs_id in $ids; do
    local rs
    rs=$(gh api "repos/$ORG/$repo/rulesets/$rs_id" 2>/dev/null || echo "")
    [ -z "$rs" ] && continue

    targets_default_branch "$rs" "$default_branch" || continue

    local name slug
    name=$(echo "$rs" | jq -r '.name')
    slug=$(printf '%s' "$name" | tr '[:upper:] /' '[:lower:]--' | tr -cd 'a-z0-9_-')
    [ -z "$slug" ] && slug="$rs_id"

    if is_compliant "$rs"; then
      skip "  $name (id=$rs_id) already compliant"
      continue
    fi

    local payload
    payload=$(build_put_payload "$rs")

    # Human-readable before/after of the bypass actors for the summary.
    local before after
    before=$(echo "$rs"      | jq -c '[.bypass_actors[]? | {t: .actor_type, id: .actor_id, m: .bypass_mode}]')
    after=$(echo "$payload"  | jq -c '[.bypass_actors[]  | {t: .actor_type, id: .actor_id, m: .bypass_mode}]')

    if [ "$DRY_RUN" = true ]; then
      mkdir -p "$OUT_DIR"
      local out="$OUT_DIR/${repo}__${slug}.json"
      echo "$payload" | jq '.' > "$out"
      skip "  DRY_RUN — would PUT $name (id=$rs_id)"
      echo "         before: $before"
      echo "         after:  $after"
      echo "         payload: $out"
    else
      info "  Updating bypass actors on $name (id=$rs_id) ..."
      gh api -X PUT "repos/$ORG/$repo/rulesets/$rs_id" --input <(echo "$payload") > /dev/null
      ok "  $name updated ($before -> $after)"
    fi
  done
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
if [ $# -eq 0 ]; then
  usage
fi

if [ -z "${GH_TOKEN:-}" ]; then
  err "GH_TOKEN is required — provide a token with administration:write scope"
  exit 1
fi
export GH_TOKEN

TARGET=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --all)     TARGET="--all" ;;
    -*)        err "Unknown flag: $arg"; usage ;;
    *)         TARGET="$arg" ;;
  esac
done

[ -z "$TARGET" ] && usage

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [ "$TARGET" = "--all" ]; then
  info "Fetching all non-archived repos in $ORG ..."
  repos=$(gh repo list "$ORG" --no-archived --json name -q '.[].name' --limit 500)
  [ -z "$repos" ] && { err "No repositories found in $ORG — check GH_TOKEN permissions"; exit 1; }

  failed=0
  for repo in $repos; do
    fix_repo "$repo" || failed=$((failed + 1))
  done
  [ "$failed" -gt 0 ] && { err "$failed repo(s) had errors"; exit 1; }
else
  fix_repo "$TARGET"
fi

if [ "$DRY_RUN" = true ]; then
  info "Dry run complete. Payloads written under $OUT_DIR/"
  info "Apply one with: gh api -X PUT repos/$ORG/<repo>/rulesets/<id> --input <payload.json>"
fi
