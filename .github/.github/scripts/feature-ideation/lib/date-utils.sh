#!/usr/bin/env bash
# date-utils.sh — cross-platform date arithmetic helpers.
#
# Why this exists:
#   `date -u -d '30 days ago'` is GNU; `date -u -v-30d` is BSD. The original
#   workflow had both forms separated by `||`, but only one branch ever ran
#   on `ubuntu-latest`. Centralizing here gives us one tested helper.

set -euo pipefail

# Print an ISO date (YYYY-MM-DD) for N days ago in UTC.
date_days_ago() {
  # Guard arg count before reading $1: under set -u a zero-arg call would abort
  # the shell with "unbound variable" instead of reaching the validation path.
  # Caught by CodeRabbit review on PR petry-projects/.github#85.
  if [ "$#" -ne 1 ]; then
    printf '[date-utils] expected 1 arg (days), got: %d\n' "$#" >&2
    return 64
  fi
  local days="$1"
  if [ -z "$days" ] || ! printf '%s' "$days" | grep -Eq '^[0-9]+$'; then
    printf '[date-utils] days must be a non-negative integer, got: %s\n' "$days" >&2
    return 64
  fi
  if date -u -d "${days} days ago" +%Y-%m-%d >/dev/null 2>&1; then
    date -u -d "${days} days ago" +%Y-%m-%d
  elif date -u -v-"${days}"d +%Y-%m-%d >/dev/null 2>&1; then
    date -u -v-"${days}"d +%Y-%m-%d
  else
    printf '[date-utils] no supported date(1) variant available\n' >&2
    return 69  # EX_UNAVAILABLE
  fi
}

# Print the current UTC timestamp in ISO-8601 (Zulu).
date_now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Print today's date in UTC (YYYY-MM-DD).
date_today() {
  date -u +%Y-%m-%d
}
