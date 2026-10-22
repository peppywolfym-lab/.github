#!/usr/bin/env bash
# fix-check-suite-prefs.sh — Disable Claude + CodeRabbit auto-trigger check suites org-wide
#
# Problem: GitHub auto-creates a check suite for Claude and CodeRabbit on every
# push. These apps only complete their suites when they have real work to do;
# when they don't, the suite stays "queued" forever — permanently blocking
# GitHub auto-merge (which waits for all suites to reach a terminal state).
#
# Fix: PATCH /repos/{owner}/{repo}/check-suites/preferences to set
# auto_trigger_checks: false for both app IDs. This stops GitHub from
# auto-creating suites on push; the apps still create suites explicitly
# when they have work to report.
#
# Usage:
#   GH_TOKEN=ghp_<classic-pat> bash scripts/fix-check-suite-prefs.sh
#   GH_TOKEN=ghp_<classic-pat> bash scripts/fix-check-suite-prefs.sh <repo>
#
# Requirements:
#   - Classic PAT (ghp_*) with `repo` scope — OAuth tokens (gho_*) are
#     rejected by the check-suites/preferences endpoint.
#   - gh CLI installed and on PATH.
#   - Works with Bash 3.2+ (macOS default).

set -euo pipefail

ORG="petry-projects"

# App IDs whose auto_trigger_checks must be disabled.
# 1236702 = Claude (anthropics/claude-code-action)
# 347564  = CodeRabbit
APP_IDS=(1236702 347564)

ok()   { echo "[OK]    $*"; }
info() { echo "[INFO]  $*"; }
err()  { echo "[ERROR] $*" >&2; }
fail() { echo "[FAIL]  $*" >&2; }

# ---------------------------------------------------------------------------
# Validate token type — OAuth tokens return 404 on this endpoint
# ---------------------------------------------------------------------------
validate_token() {
  local token="${GH_TOKEN:-}"
  if [ -z "$token" ]; then
    err "GH_TOKEN is not set. Export a classic PAT with 'repo' scope."
    err "  export GH_TOKEN=ghp_..."
    exit 1
  fi
  if [[ "$token" == gho_* ]]; then
    err "GH_TOKEN appears to be an OAuth app token (gho_*). This endpoint"
    err "requires a classic PAT (ghp_*) with 'repo' scope."
    err "Generate one at: https://github.com/settings/tokens"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Build the PATCH payload: [{app_id: N, setting: false}, ...]
# ---------------------------------------------------------------------------
build_payload() {
  local payload='{"auto_trigger_checks":['
  local first=true
  for app_id in "${APP_IDS[@]}"; do
    if [ "$first" = true ]; then
      first=false
    else
      payload+=','
    fi
    payload+="{\"app_id\":${app_id},\"setting\":false}"
  done
  payload+=']}'
  echo "$payload"
}

# ---------------------------------------------------------------------------
# Apply to a single repo. Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
fix_repo() {
  local repo="$1"
  info "Patching $ORG/$repo ..."

  # Read current state (non-fatal if missing — means no preference set yet)
  local current_json
  if ! current_json=$(gh api "repos/$ORG/$repo/check-suites/preferences" 2>&1); then
    # 404 = endpoint responded but resource not found (likely wrong token type
    # if we got this far past validate_token). Treat as needing patch.
    info "  Could not read current prefs — will apply anyway. Response: $current_json"
  fi

  # Apply the patch
  local payload
  payload=$(build_payload)

  local api_err
  if api_err=$(gh api -X PATCH "repos/$ORG/$repo/check-suites/preferences" \
       --input - <<< "$payload" 2>&1 >/dev/null); then
    ok "  auto_trigger_checks disabled for app_ids: ${APP_IDS[*]}"
  else
    fail "  PATCH failed for $ORG/$repo. API response: $api_err"
    return 1
  fi

  # Verify
  local result
  if result=$(gh api "repos/$ORG/$repo/check-suites/preferences" \
      --jq '.preferences.auto_trigger_checks | map(select(.app_id == 1236702 or .app_id == 347564))' 2>/dev/null); then
    ok "  Verified: $result"
  else
    info "  Could not verify (non-fatal)"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
validate_token
export GH_TOKEN

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,/^set /p' "$0" | grep '^#' | sed 's/^# \?//'
  exit 0
fi

if [ $# -ge 1 ] && [ "$1" != "--all" ]; then
  # Single repo mode
  fix_repo "$1"
  exit $?
fi

# Org-wide mode
info "Fetching all non-archived repos in $ORG ..."
repos=$(gh repo list "$ORG" --no-archived --json name -q '.[].name' --limit 500)

if [ -z "$repos" ]; then
  err "No repositories found in $ORG — check GH_TOKEN permissions"
  exit 1
fi

failed=0
total=0
for repo in $repos; do
  total=$((total + 1))
  fix_repo "$repo" || failed=$((failed + 1))
done

echo ""
if [ "$failed" -gt 0 ]; then
  err "$failed/$total repo(s) failed — check output above"
  exit 1
fi
ok "Done. $total repo(s) patched successfully."
ok "New pushes to any PR branch will no longer generate orphaned check suites"
ok "from Claude or CodeRabbit. Existing stuck suites on open PRs will need a"
ok "new push to clear — the nightly auto-rebase will handle this automatically."
