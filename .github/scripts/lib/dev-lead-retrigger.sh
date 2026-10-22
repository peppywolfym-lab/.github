# shellcheck shell=bash
# dev-lead-retrigger.sh — shared helpers for re-engaging the dev-lead agent on a
# compliance issue by cycling its trigger label.
#
# Sourced by:
#   scripts/compliance-audit.sh      — weekly audit; re-triggers findings that
#                                      persist across runs (issue still open).
#   scripts/compliance-retrigger.sh  — daily sweep; re-triggers stale issues.
#
# Caller contract:
#   Source this file; do NOT execute it directly.  The library does NOT call
#   `set` itself, so it is safe to source from scripts that use `set -euo pipefail`.
#
# Why a shared lib?
#   Both entry points need the same two primitives, and both depend on how
#   dev-lead names its branches (dev-lead/issue-<number>-<timestamp>, see
#   scripts/dev-lead-fix-issue.sh in the agent repo). Keeping that convention in
#   one place stops the two callers from drifting apart.
#
# These functions are pure helpers: they take all inputs as arguments and call
# `gh api` directly, so they do not depend on the sourcing script's own wrappers
# or globals.

# dl_dev_lead_active <org> <repo> <issue>
# Returns 0 (true) if dev-lead is ALREADY working this issue — either an open PR
# exists on a dev-lead/issue-<number>-* branch, or the issue carries the
# `in-progress` label. In that case the caller must NOT cycle the trigger label,
# to avoid interrupting or duplicating active work.
dl_dev_lead_active() {
  local org="$1" repo="$2" issue="$3"

  # Match the dev-lead branch exactly: "dev-lead/issue-<n>-<timestamp>".
  # Require the trailing "-" so issue 1 does not match branch "issue-12-...".
  # Use --paginate so repos with >100 open PRs are fully scanned.
  # Fail closed: if the API call itself fails (transient error, rate limit, token
  # scope issue), treat the issue as active so we do not cycle the label and
  # accidentally create duplicate work.
  local pr_raw pr_count
  if ! pr_raw=$(gh api "repos/$org/$repo/pulls?state=open&per_page=100" \
    --paginate \
    --jq "[.[] | select(.head.ref | type == \"string\" and startswith(\"dev-lead/issue-${issue}-\"))] | length" \
    2>/dev/null); then
    echo "[warn]  PR lookup for $org/$repo#$issue failed — treating as active to avoid duplicate work" >&2
    return 0
  fi
  pr_count=$(echo "$pr_raw" | awk '{s+=$1} END {print s+0}')
  [ "${pr_count:-0}" -gt 0 ] && return 0

  # An agent currently mid-run marks the issue `in-progress` before it pushes a
  # PR — respect that window, but cap it at IN_PROGRESS_MAX_HOURS so a crashed or
  # cancelled run cannot block retrigger indefinitely.
  local in_progress
  if ! in_progress=$(gh api "repos/$org/$repo/issues/$issue" \
    --jq '.labels[].name | select(. == "in-progress")' \
    2>/dev/null); then
    echo "[warn]  Issue lookup for $org/$repo#$issue failed — treating as active to avoid duplicate work" >&2
    return 0
  fi

  if [ -n "$in_progress" ]; then
    local in_progress_max_hours="${IN_PROGRESS_MAX_HOURS:-4}"
    local labeled_at
    labeled_at=$(gh api "repos/$org/$repo/issues/$issue/events?per_page=100" \
      --paginate \
      --jq '.[] | select(.event == "labeled" and .label.name == "in-progress") | .created_at' \
      2>/dev/null | head -1 || echo "")

    if [ -z "$labeled_at" ] || [ "$labeled_at" = "null" ]; then
      # Cannot determine when the label was applied; trust it conservatively.
      return 0
    fi

    local now_epoch labeled_epoch elapsed_hours
    now_epoch=$(date -u +%s)
    labeled_epoch=$(date -u -d "$labeled_at" +%s 2>/dev/null \
      || python3 -c "import sys, datetime; \
                     ts = sys.stdin.read().strip().replace('Z', '+00:00'); \
                     print(int(datetime.datetime.fromisoformat(ts).timestamp()))" 2>/dev/null \
      <<< "$labeled_at" || echo "")

    if [ -z "$labeled_epoch" ]; then
      return 0
    fi
    elapsed_hours=$(( (now_epoch - labeled_epoch) / 3600 ))

    [ "$elapsed_hours" -le "$in_progress_max_hours" ] && return 0
    # in-progress label is stale (agent likely crashed). Remove it before
    # returning inactive: AGENTS.md's claim protocol requires any agent to skip
    # an issue that still carries in-progress, so leaving the label in place
    # means the next dev-lead run will immediately skip the issue even after the
    # trigger label is cycled, leaving the crash unrecovered.
    if [ "${DRY_RUN:-false}" = "true" ]; then
      echo "[dry-run] would remove stale 'in-progress' from $org/$repo#$issue" >&2
    else
      gh api -X DELETE "repos/$org/$repo/issues/$issue/labels/in-progress" \
        >/dev/null 2>&1 \
        && echo "[info]  Removed stale 'in-progress' from $org/$repo#$issue" >&2 \
        || echo "[warn]  Could not remove stale 'in-progress' from $org/$repo#$issue — dev-lead may skip it" >&2
    fi
    # fall through to return 1 (inactive)
  fi

  return 1
}

# dl_cycle_trigger_label <org> <repo> <issue> <label> [dry_run]
# Remove then re-add <label> so GitHub emits a fresh issues:labeled event,
# re-engaging dev-lead. dev-lead fires once per label application, so a
# persistent finding whose label is already present needs the label cycled to be
# picked up again. Returns non-zero if the re-add fails (the caller can fall
# back to ensuring the label is at least present).
dl_cycle_trigger_label() {
  local org="$1" repo="$2" issue="$3" label="$4" dry_run="${5:-false}"

  if [ "$dry_run" = "true" ]; then
    echo "[dry-run] would cycle '$label' on $org/$repo#$issue" >&2
    return 0
  fi

  # URL-encode the label for the REST path segment to handle names that contain
  # spaces or other reserved characters.
  local encoded_label
  encoded_label=$(printf '%s' "$label" \
    | python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip(), safe=''))" 2>/dev/null \
    || printf '%s' "$label" | sed 's/ /%20/g')
  # Treat a failed DELETE as a hard failure: if the label is still present when we
  # POST it back, GitHub will not emit a new labeled event, so the retrigger is a
  # no-op even though it appears to succeed. Return non-zero so the caller can
  # attempt a restore and warn appropriately.
  if ! gh api -X DELETE "repos/$org/$repo/issues/$issue/labels/$encoded_label" >/dev/null 2>&1; then
    echo "[warn]  Failed to remove '$label' from $org/$repo#$issue — skipping re-add to avoid emitting no event" >&2
    return 1
  fi
  # Let GitHub register the removal before re-adding so the add is not coalesced
  # with the delete (which would emit no labeled event).
  sleep 1
  gh api -X POST "repos/$org/$repo/issues/$issue/labels" \
    --field "labels[]=$label" >/dev/null 2>&1 || return 1
}
