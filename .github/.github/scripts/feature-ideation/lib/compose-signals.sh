#!/usr/bin/env bash
# compose-signals.sh — assemble the canonical signals.json document.
#
# Why this exists:
#   The original `jq -n --argjson` block crashed if any input variable was an
#   empty string. By centralizing composition here, we (a) validate every input
#   is JSON before passing to --argjson, (b) emit a stable shape regardless of
#   which sub-queries returned empty, and (c) keep the schema source-of-truth
#   in one place.
#
# Inputs (all JSON arrays, never empty strings):
#   $1  open_issues
#   $2  closed_issues
#   $3  ideas_discussions
#   $4  releases
#   $5  merged_prs
#   $6  feature_requests
#   $7  bug_reports
#   $8  repo (string, e.g. "petry-projects/talkterm")
#   $9  scan_date (ISO-8601 string)
#  $10  schema_version (string)
#  $11  truncation_warnings (JSON array, may be [])
#
# Output: signals.json document on stdout.

set -euo pipefail

compose_signals() {
  if [ "$#" -ne 11 ]; then
    printf '[compose-signals] expected 11 args, got %d\n' "$#" >&2
    return 64  # EX_USAGE
  fi

  local open_issues="$1"
  local closed_issues="$2"
  local ideas_discussions="$3"
  local releases="$4"
  local merged_prs="$5"
  local feature_requests="$6"
  local bug_reports="$7"
  local repo="$8"
  local scan_date="$9"
  local schema_version="${10}"
  local truncation_warnings="${11}"

  # Validate every JSON input before composition. Better to fail loudly here
  # than to let `jq --argjson` produce a cryptic parse error.
  local idx=0
  for input in "$open_issues" "$closed_issues" "$ideas_discussions" "$releases" \
               "$merged_prs" "$feature_requests" "$bug_reports" "$truncation_warnings"; do
    idx=$((idx + 1))
    # Require a JSON array, not just valid JSON. Objects/strings/nulls accepted
    # by `jq -e .` would silently produce wrong counts (key count, char count).
    # Caught by CodeRabbit review on PR petry-projects/.github#85.
    if ! printf '%s' "$input" | jq -e 'type == "array"' >/dev/null 2>&1; then
      printf '[compose-signals] arg #%d must be a JSON array: %s\n' "$idx" "${input:0:120}" >&2
      return 65  # EX_DATAERR
    fi
  done

  jq -n \
    --arg scan_date "$scan_date" \
    --arg repo "$repo" \
    --arg schema_version "$schema_version" \
    --argjson open_issues "$open_issues" \
    --argjson closed_issues "$closed_issues" \
    --argjson ideas_discussions "$ideas_discussions" \
    --argjson releases "$releases" \
    --argjson merged_prs "$merged_prs" \
    --argjson feature_requests "$feature_requests" \
    --argjson bug_reports "$bug_reports" \
    --argjson truncation_warnings "$truncation_warnings" \
    '{
      schema_version: $schema_version,
      scan_date: $scan_date,
      repo: $repo,
      open_issues: { count: ($open_issues | length), items: $open_issues },
      closed_issues_30d: { count: ($closed_issues | length), items: $closed_issues },
      ideas_discussions: { count: ($ideas_discussions | length), items: $ideas_discussions },
      releases: $releases,
      merged_prs_30d: { count: ($merged_prs | length), items: $merged_prs },
      feature_requests: { count: ($feature_requests | length), items: $feature_requests },
      bug_reports: { count: ($bug_reports | length), items: $bug_reports },
      truncation_warnings: $truncation_warnings
    }'
}
