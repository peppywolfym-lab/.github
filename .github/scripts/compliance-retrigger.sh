#!/usr/bin/env bash
set -euo pipefail
# compliance-retrigger.sh — Re-trigger stale compliance-audit issues.
#
# Run hourly (see .github/workflows/compliance-retrigger.yml). The per-run
# one-engagement-per-repo throttle means each repo gets at most one issue
# re-triggered per run (≈ one per hour on the scheduled cadence), draining
# each repo's backlog steadily without bursts.
#
# What it does:
#   Finds all open compliance-audit issues that are ≥ STALE_DAYS old and
#   have no associated open PR on a dev-lead branch.  Cycles the "dev-lead"
#   label (remove + re-add) to re-fire the issues:labeled event and give
#   dev-lead a fresh chance to create a fix PR.
#
#      Throttling: at most ONE issue per repo is engaged per run (shared across
#      the primary and legacy-label sweeps), and a repo already active (open PR
#      or in-progress issue) is skipped.  Issues are processed oldest-first, so
#      the most-stuck finding in each repo is the one re-engaged; the hourly
#      cadence drains the rest of each repo's backlog one at a time.  This keeps
#      concurrent dev-lead runs in any single repo to one, avoiding the rebase
#      storms and token exhaustion a fleet-wide burst would cause.
#
#      Throttling: at most ONE issue per repo is engaged per run (shared across
#      the primary and legacy-label sweeps), and a repo already active (open PR
#      or in-progress issue) is skipped.  Issues are processed oldest-first, so
#      the most-stuck finding in each repo is the one re-engaged; the daily
#      cadence drains the rest of each repo's backlog one at a time.  This keeps
#      concurrent dev-lead runs in any single repo to one, avoiding the rebase
#      storms and token exhaustion a fleet-wide burst would cause.
#
# Why re-trigger instead of relying on the original event?
#   GitHub only fires issues:labeled once per label application.  If dev-lead
#   had a transient failure at that moment (template error, git-identity bug,
#   rate-limit, disabled workflow), the event is lost forever unless the label
#   is re-applied.  This script recovers those lost events automatically.
#
# Environment:
#   GH_TOKEN      — must have issues:write and contents:read across the org
#   ORG           — GitHub org name (default: petry-projects)
#   STALE_DAYS    — issues older than this are considered stale (default: 2)
#   DRY_RUN       — set to "true" to log actions without executing them
#   AUDIT_LABEL   — label used to tag compliance findings (default: compliance-audit)
#   TRIGGER_LABEL — label used to trigger dev-lead (default: dev-lead)

ORG="${ORG:-petry-projects}"
STALE_DAYS="${STALE_DAYS:-2}"
DRY_RUN="${DRY_RUN:-false}"
AUDIT_LABEL="${AUDIT_LABEL:-compliance-audit}"
TRIGGER_LABEL="${TRIGGER_LABEL:-dev-lead}"
# Legacy label to also sweep during the transition window before the one-time
# migration script has run. Issues that still carry only the old label are
# found here and given the new label so dev-lead picks them up.
LEGACY_TRIGGER_LABEL="${LEGACY_TRIGGER_LABEL:-claude}"

# Shared dev-lead retrigger helpers (dl_dev_lead_active, dl_cycle_trigger_label).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/dev-lead-retrigger.sh
. "$SCRIPT_DIR/lib/dev-lead-retrigger.sh"

ISSUES_RETRIGGERED=0
ISSUES_SKIPPED=0
ISSUES_DEFERRED=0

# Repos that already have an in-flight dev-lead engagement THIS run — either an
# issue we re-triggered or one we found already active. At most one engagement
# per repo per run keeps concurrent dev-lead runs in a single repo to one,
# avoiding rebase storms and token exhaustion from a fleet-wide burst. Shared
# across BOTH the primary and legacy-label sweeps so the per-repo budget covers
# every path that could engage dev-lead.
declare -A REPO_ENGAGED=()

# Repos that already have an in-flight dev-lead engagement THIS run — either an
# issue we re-triggered or one we found already active. At most one engagement
# per repo per run keeps concurrent dev-lead runs in a single repo to one,
# avoiding rebase storms and token exhaustion from a fleet-wide burst. Shared
# across BOTH the primary and legacy-label sweeps so the per-repo budget covers
# every path that could engage dev-lead.
declare -A REPO_ENGAGED=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()  { echo "[info]  $*"; }
warn()  { echo "[warn]  $*" >&2; }
error() { echo "[error] $*" >&2; }

# Number of attempts for the org-wide search/issues calls, and the linear-backoff
# base (seconds) between them. A single transient search failure (rate limit / 5xx)
# used to abort the whole run and fail the hourly scheduled workflow — the ~11%
# failure rate Fleet Monitor flagged (#948). Retrying absorbs those transient
# blips while a genuine, persistent outage still surfaces after the budget is
# exhausted. Both overridable via env so tests can run with zero delay.
GH_SEARCH_ATTEMPTS="${GH_SEARCH_ATTEMPTS:-3}"
GH_API_RETRY_BASE_DELAY="${GH_API_RETRY_BASE_DELAY:-2}"
if ! [[ "$GH_SEARCH_ATTEMPTS" =~ ^[0-9]+$ ]] || [ "$GH_SEARCH_ATTEMPTS" -lt 1 ]; then
  error "GH_SEARCH_ATTEMPTS must be an integer >= 1 (got: '${GH_SEARCH_ATTEMPTS}')"
  exit 1
fi
if ! [[ "$GH_API_RETRY_BASE_DELAY" =~ ^[0-9]+$ ]]; then
  error "GH_API_RETRY_BASE_DELAY must be a non-negative integer (got: '${GH_API_RETRY_BASE_DELAY}')"
  exit 1
fi

# gh_api_search <query...> — run a (paginated) `gh api` search, capturing combined
# stdout+stderr into the global GH_API_SEARCH_OUT and retrying transient failures
# with linear backoff. Returns the last attempt's exit code. Kept separate from a
# --jq wrapper because callers here need the raw response body to detect
# error-JSON pages returned with a zero exit code.
gh_api_search() {
  local attempt rc=0
  GH_API_SEARCH_OUT=""
  for ((attempt=1; attempt<=GH_SEARCH_ATTEMPTS; attempt++)); do
    GH_API_SEARCH_OUT=$(gh api "$@" 2>&1) && rc=0 || rc=$?
    [ "$rc" -eq 0 ] && return 0
    if [ "$attempt" -lt "$GH_SEARCH_ATTEMPTS" ]; then
      warn "search/issues API call failed (exit $rc), attempt ${attempt}/${GH_SEARCH_ATTEMPTS} — retrying in $((attempt * GH_API_RETRY_BASE_DELAY))s"
      sleep "$((attempt * GH_API_RETRY_BASE_DELAY))"
    fi
  done
  return "$rc"
}

# has_open_pr / cycle_label live in lib/dev-lead-retrigger.sh as
# dl_dev_lead_active() and dl_cycle_trigger_label(), shared with the weekly
# compliance audit so both stay in sync with dev-lead's branch-naming
# convention. Sourced via SCRIPT_DIR resolved at the top of the file.

# stale_cutoff — ISO timestamp N days ago
stale_cutoff() {
  date -u -d "${STALE_DAYS} days ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || python3 -c "from datetime import datetime,timedelta,timezone; \
                   print((datetime.now(timezone.utc)-timedelta(days=${STALE_DAYS})).strftime('%Y-%m-%dT%H:%M:%SZ'))"
}

# ---------------------------------------------------------------------------
# Re-trigger stale compliance issues
# ---------------------------------------------------------------------------

retrigger_stale_issues() {
  info "Looking for stale compliance-audit issues (older than ${STALE_DAYS} days)..."
  local cutoff
  cutoff=$(stale_cutoff)
  info "Stale cutoff: $cutoff"

  # Search across the whole org. Fetch raw response first so we can detect
  # HTTP errors — gh api dumps the error JSON to stdout and exits non-zero,
  # which the old `--jq '.items[]' || echo ""` pattern silently swallowed,
  # producing a single "Skipping null#null" iteration when the token lacked
  # search scope. See: failure mode where ORG_SCORECARD_TOKEN scope did not
  # permit cross-org search but the script still reported success.
  # is:issue is REQUIRED — GitHub now rejects search/issues queries that omit
  # is:issue/is:pull-request with HTTP 422 (this was the bug that broke the daily
  # sweep). sort=created&order=asc surfaces the oldest (most-stuck) issue per repo
  # first, so the one-per-repo throttle below re-engages the right one. --paginate
  # walks all result pages: with the throttle, a single repo's large backlog would
  # otherwise fill the first 100 results and starve every other repo for the run.
  local raw rc
  gh_api_search --paginate \
    "search/issues?q=org:${ORG}+label:${AUDIT_LABEL}+label:${TRIGGER_LABEL}+state:open+is:issue&sort=created&order=asc&per_page=100" \
    && rc=0 || rc=$?
  raw="$GH_API_SEARCH_OUT"

  if [ "$rc" -ne 0 ]; then
    error "search/issues API call failed (exit $rc) after ${GH_SEARCH_ATTEMPTS} attempts. Response:"
    echo "$raw" | head -5 >&2
    error "Cannot retrigger issues; aborting. Check GH_TOKEN scope — token must be able to read issues across all repos in org ${ORG}."
    return 1
  fi

  # With --paginate, gh concatenates one JSON object per page, so slurp (-s) and
  # inspect every page. Detect an error-response object on any page even when the
  # exit code was 0 (defensive).
  if echo "$raw" | jq -se 'any(.[]; has("message") and (.items | not))' >/dev/null 2>&1; then
    error "search/issues returned an error response:"
    echo "$raw" | jq -rs '.[] | select(has("message")) | .message' >&2
    return 1
  fi

  # total_count is repeated identically on every page; take the first.
  local total
  total=$(echo "$raw" | jq -rs '.[0].total_count // 0')
  info "search/issues returned ${total} matching issues"

  local issues
  issues=$(echo "$raw" | jq -c '.items[] | {number: .number, repo: (.repository_url | split("/") | last), created_at: .created_at, title: .title}')

  if [ -z "$issues" ]; then
    info "No open compliance-audit issues found with '$TRIGGER_LABEL' label."
  fi

  while IFS= read -r issue_json; do
    [ -z "$issue_json" ] && continue
    local number repo created_at title
    number=$(echo "$issue_json" | jq -r '.number')
    repo=$(echo "$issue_json" | jq -r '.repo')
    created_at=$(echo "$issue_json" | jq -r '.created_at')
    title=$(echo "$issue_json" | jq -r '.title')

    # Issues arrive oldest-first, so once we hit one newer than the cutoff every
    # remaining issue is also newer (not stale) — stop scanning entirely.
    if [[ "$created_at" > "$cutoff" ]]; then
      info "Reached first non-stale issue ($repo#$number, created $created_at); no older issues remain."
      break
    fi

    # One engagement per repo per run. If this repo already got an issue
    # re-triggered (or was found active) this run, defer the rest to a later sweep.
    if [ -n "${REPO_ENGAGED[$repo]:-}" ]; then
      info "Deferring $repo#$number ($title) — $repo already engaged this run (one issue per repo per run)"
      ISSUES_DEFERRED=$((ISSUES_DEFERRED + 1))
      continue
    fi

    # Skip if dev-lead is already working this issue (open PR or in-progress).
    # This consumes the repo's slot: a repo already churning on a fix must not
    # get a second concurrent engagement.
    if dl_dev_lead_active "$ORG" "$repo" "$number"; then
      info "Skipping $repo#$number — dev-lead already active (open PR or in-progress); $repo slot taken"
      REPO_ENGAGED[$repo]=1
      ISSUES_SKIPPED=$((ISSUES_SKIPPED + 1))
      continue
    fi

    # Take the repo's slot for this run regardless of cycle outcome, so a
    # transient failure cannot let a second issue in the same repo fire and
    # reintroduce burst behaviour. The next hourly sweep retries this repo.
    REPO_ENGAGED[$repo]=1
    info "Re-triggering $repo#$number: $title (created $created_at)"
    if dl_cycle_trigger_label "$ORG" "$repo" "$number" "$TRIGGER_LABEL" "$DRY_RUN"; then
      ISSUES_RETRIGGERED=$((ISSUES_RETRIGGERED + 1))
    else
      warn "Failed to re-trigger dev-lead on issue #$number in $repo — attempting to restore label"
      # The label may have been deleted but the re-add failed. Restore it so the
      # issue remains visible to the next sweep's search query.
      if [ "$DRY_RUN" != "true" ]; then
        gh api -X POST "repos/$ORG/$repo/issues/$number/labels" \
          --field "labels[]=$TRIGGER_LABEL" >/dev/null 2>&1 \
          && info "Restored $TRIGGER_LABEL on $repo#$number" \
          || warn "Could not restore $TRIGGER_LABEL on $repo#$number — issue may drop out of next sweep"
      fi
      ISSUES_SKIPPED=$((ISSUES_SKIPPED + 1))
    fi
    # dl_cycle_trigger_label already sleeps 1s internally; no additional pause needed.
  done <<< "$issues"

  # Sweep pre-migration issues that still carry only the legacy trigger label.
  # When this change is deployed before the one-time migration has run, open
  # compliance issues with the legacy label would otherwise be invisible to the
  # main search above and never retriggered. Adding TRIGGER_LABEL to each such
  # issue both recovers the lost event and acts as a lazy per-issue migration.
  if [ -n "${LEGACY_TRIGGER_LABEL:-}" ] && [ "$LEGACY_TRIGGER_LABEL" != "$TRIGGER_LABEL" ]; then
    info "Sweeping pre-migration '$LEGACY_TRIGGER_LABEL'-labeled issues..."
    local legacy_raw legacy_issues legacy_rc
    # Exclude issues that already carry TRIGGER_LABEL — they were handled above.
    # is:issue is required (HTTP 422 otherwise); oldest-first matches the primary
    # sweep; --paginate walks all result pages so issues beyond the first 100 are
    # included.
    gh_api_search --paginate \
      "search/issues?q=org:${ORG}+label:${AUDIT_LABEL}+label:${LEGACY_TRIGGER_LABEL}+-label:${TRIGGER_LABEL}+state:open+is:issue&sort=created&order=asc&per_page=100" \
      && legacy_rc=0 || legacy_rc=$?
    legacy_raw="$GH_API_SEARCH_OUT"
    if [ "$legacy_rc" -ne 0 ]; then
      warn "Legacy label sweep search failed (exit $legacy_rc after ${GH_SEARCH_ATTEMPTS} attempts) — pre-migration issues not swept this run"
    elif echo "$legacy_raw" | jq -se 'any(.[]; has("message") and (.items | not))' >/dev/null 2>&1; then
      warn "Legacy label sweep search returned an error response — pre-migration issues not swept this run"
    else
      legacy_issues=$(echo "$legacy_raw" | jq -c '.items[] | {number: .number, repo: (.repository_url | split("/") | last), created_at: .created_at, title: .title}')
      local legacy_total
      legacy_total=$(echo "$legacy_raw" | jq -rs '.[0].total_count // 0')
      info "Legacy sweep found ${legacy_total} matching issues"
      while IFS= read -r issue_json; do
        [ -z "$issue_json" ] && continue
        number=$(echo "$issue_json" | jq -r '.number')
        repo=$(echo "$issue_json" | jq -r '.repo')
        created_at=$(echo "$issue_json" | jq -r '.created_at')
        title=$(echo "$issue_json" | jq -r '.title')
        # Oldest-first: first non-stale issue means no older ones remain.
        if [[ "$created_at" > "$cutoff" ]]; then
          break
        fi
        # Honour the shared one-engagement-per-repo budget set by the primary
        # sweep, so a repo already engaged above is not also label-bumped here.
        if [ -n "${REPO_ENGAGED[$repo]:-}" ]; then
          info "Deferring legacy $repo#$number ($title) — $repo already engaged this run"
          ISSUES_DEFERRED=$((ISSUES_DEFERRED + 1))
          continue
        fi
        if dl_dev_lead_active "$ORG" "$repo" "$number"; then
          info "Skipping legacy $repo#$number — dev-lead already active; $repo slot taken"
          REPO_ENGAGED[$repo]=1
          ISSUES_SKIPPED=$((ISSUES_SKIPPED + 1))
          continue
        fi
        REPO_ENGAGED[$repo]=1
        info "Adding '$TRIGGER_LABEL' to pre-migration issue $repo#$number: $title"
        if [ "$DRY_RUN" = "true" ]; then
          info "[dry-run] would ensure '$TRIGGER_LABEL' label exists in $repo and add it to #$number"
          ISSUES_RETRIGGERED=$((ISSUES_RETRIGGERED + 1))
        else
          # Repos in the pre-migration state may only have the legacy label
          # object. Ensure the new label exists before trying to apply it so
          # the add-label API call does not fail silently and leave the issue
          # invisible to the main dev-lead sweep.
          gh label create "$TRIGGER_LABEL" --repo "$ORG/$repo" \
            --color "8B5CF6" --description "For dev-lead agent pickup" --force 2>/dev/null || true
          if gh api -X POST "repos/$ORG/$repo/issues/$number/labels" \
            --field "labels[]=$TRIGGER_LABEL" >/dev/null 2>&1; then
            info "  added '$TRIGGER_LABEL' to $repo#$number"
            ISSUES_RETRIGGERED=$((ISSUES_RETRIGGERED + 1))
          else
            warn "Failed to add '$TRIGGER_LABEL' to $repo#$number — issue may not be retriggered"
            ISSUES_SKIPPED=$((ISSUES_SKIPPED + 1))
          fi
        fi
      done <<< "$legacy_issues"
    fi
  fi

  info "Re-trigger complete: ${ISSUES_RETRIGGERED} retriggered, ${ISSUES_SKIPPED} skipped, ${ISSUES_DEFERRED} deferred (repo already engaged this run)"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary() {
  echo ""
  echo "=========================================="
  echo "  compliance-retrigger summary"
  echo "=========================================="
  echo "  Stale threshold : ${STALE_DAYS} days"
  echo "  Dry run         : ${DRY_RUN}"
  echo "  Issues retriggered  : ${ISSUES_RETRIGGERED}"
  echo "  Issues skipped      : ${ISSUES_SKIPPED}"
  echo "  Issues deferred     : ${ISSUES_DEFERRED} (repo already engaged this run)"
  echo "=========================================="

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "## Compliance Re-trigger Summary"
      echo ""
      echo "| Metric | Value |"
      echo "| ------ | ----- |"
      echo "| Issues retriggered | $ISSUES_RETRIGGERED |"
      echo "| Issues skipped (PR exists or recent) | $ISSUES_SKIPPED |"
      echo "| Issues deferred (repo already engaged this run) | $ISSUES_DEFERRED |"
      echo "| Stale threshold | ${STALE_DAYS} days |"
      echo "| Dry run | $DRY_RUN |"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  info "compliance-retrigger starting (org=$ORG, stale_days=$STALE_DAYS, dry_run=$DRY_RUN)"
  retrigger_stale_issues
  print_summary
}

main "$@"
