#!/usr/bin/env bash
# cron-timing.sh — pure, side-effect-free helpers for the off-peak
# scheduled-workflow timing standard (standards/ci-standards.md → "Scheduled
# Workflow Timing", promoted from the petry-projects/.github-private repo-local
# convention). No external calls; safe to `source` from a workflow, the CI
# check (scripts/check-cron-timing.sh), or a bats test.
#
# The same helpers both *detect* a top-of-the-hour cron and *pick* its
# deterministic replacement minute, so the CI check and the chosen values can
# never disagree, and a newly added workflow gets a defensible minute for free.

# Echo the minute field (field 1) of a 5-field cron expression. Leading and
# trailing whitespace is tolerated (default IFS word-splitting trims it).
cron_minute_field() {
  local minute _rest
  read -r minute _rest <<<"$1"
  printf '%s' "$minute"
}

# Return 0 (true) when the cron minute field is a top-of-the-hour start (a bare
# `0`) — the behaviour the off-peak standard forbids (`0 * * * *`, `0 7 * * *`,
# `0 */4 * * *`, …). Any offset minute (17, 41, */15, …) returns non-zero.
cron_minute_is_zero() {
  [[ "$(cron_minute_field "$1")" == "0" ]]
}

# Deterministic off-peak minute (1..59) for a workflow filename. Hashing the
# filename spreads workflows across the hour and moves any minute-0 cron to a
# non-zero minute, letting the check and the suggested value agree without
# hand-picking. Uniqueness across files is not guaranteed — hash collisions are
# possible; the no-duplicate-crons test catches any that occur in practice.
# cksum is POSIX and reproducible on every runner; the basename keeps the result
# path-independent so callers may pass a bare name or a full path.
cron_offset_minute() {
  local name checksum
  name="$(basename -- "$1")"
  checksum="$(printf '%s' "$name" | cksum)"
  checksum="${checksum%% *}"          # keep the leading numeric checksum only
  printf '%s' "$(( checksum % 59 + 1 ))"
}
