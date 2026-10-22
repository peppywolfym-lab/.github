#!/usr/bin/env bats
# Contract tests for scripts/agents-md-cycle-log.sh — the pure, tested helper
# that reads the append-only committed AGENTS.md structural cycle log
# (docs/initiatives/agents-md-validation-cycle-log.md) and reports (a) whether
# the log is well-formed with every false-positive determination attributed to
# a named maintainer, and (b) whether the promotion gate's clean-cycle
# precondition is met — WITHOUT ever promoting anything (#647, Phase 4 of epic
# #642).
#
# The gate: the informational structural check is promoted to blocking only
# after (1) two consecutive audit cycles with zero confirmed false positives
# AND (2) explicit maintainer sign-off — never automatically. This script is the
# pure decision core for precondition (1); precondition (2) and the flip itself
# are human actions. Reference doc: docs/initiatives/agents-md-validation.md.
#
# The script's main() is guarded, so sourcing only defines its pure helpers; the
# CLI subcommands (validate, eligibility) are exercised via `bash "$SCRIPT" ...`.
# No network, no gh — the cycle log is a committed file.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/agents-md-cycle-log.sh"
COMMITTED_LOG="$REPO_ROOT/docs/initiatives/agents-md-validation-cycle-log.md"

setup() {
  TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

# write_log <body> — write a cycle-log fixture (header + given data rows) to a
# temp file and echo its path.
write_log() {
  local f="$TMPDIR_TEST/cycle-log.md"
  {
    printf '# Cycle Log\n\n'
    printf '| Cycle | Structural findings | Confirmed false positives | False-positive details | Determined by | Clean? |\n'
    printf '|-------|---------------------|---------------------------|------------------------|---------------|--------|\n'
    printf '%b' "$1"
  } > "$f"
  printf '%s' "$f"
}

# ---------------------------------------------------------------------------
# validate — well-formed rows with attribution pass; malformed / unattributed
# rows fail loudly.
# ---------------------------------------------------------------------------

@test "validate accepts a baseline log with no recorded cycles" {
  local log
  log="$(write_log '')"
  run bash "$SCRIPT" validate "$log"
  [ "$status" -eq 0 ]
}

@test "validate accepts two clean, attributed cycles" {
  local log
  log="$(write_log '| 2026-10-01 | 3 | 0 | — | @alice | yes |\n| 2026-11-01 | 1 | 0 | — | @bob | yes |\n')"
  run bash "$SCRIPT" validate "$log"
  [ "$status" -eq 0 ]
}

@test "validate rejects a false-positive determination with no maintainer named (AC #5)" {
  # A confirmed false positive that names no maintainer is exactly the
  # reward-hacking hole the append-only + attribution rule closes.
  local log
  log="$(write_log '| 2026-10-01 | 3 | 1 | anchor false alarm |  | no |\n')"
  run bash -c 'bash "$1" validate "$2" 2>&1' _ "$SCRIPT" "$log"
  [ "$status" -eq 1 ]
  [[ "$output" == *maintainer* ]]
}

@test "validate rejects a clean cycle with no reviewing maintainer named (AC #5)" {
  # Even a zero-false-positive cycle must name the maintainer who reviewed it,
  # so a 'clean cycle' claim is never anonymous.
  local log
  log="$(write_log '| 2026-10-01 | 0 | 0 | — |  | yes |\n')"
  run bash -c 'bash "$1" validate "$2" 2>&1' _ "$SCRIPT" "$log"
  [ "$status" -eq 1 ]
  [[ "$output" == *maintainer* ]]
}

@test "validate rejects a non-integer finding count" {
  local log
  log="$(write_log '| 2026-10-01 | many | 0 | — | @alice | yes |\n')"
  run bash "$SCRIPT" validate "$log"
  [ "$status" -eq 1 ]
}

@test "validate rejects a clean flag that contradicts the false-positive count" {
  # clean=yes but a confirmed false positive is recorded — an inconsistent row
  # that could fake a clean cycle.
  local log
  log="$(write_log '| 2026-10-01 | 3 | 2 | two false alarms | @alice | yes |\n')"
  run bash "$SCRIPT" validate "$log"
  [ "$status" -eq 1 ]
}

@test "validate rejects a non-integer false-positive count" {
  # The non-negative-integer guard must apply to the confirmed-false-positive
  # count too, not only the structural-findings count.
  local log
  log="$(write_log '| 2026-10-01 | 0 | several | some detail | @alice | no |\n')"
  run bash "$SCRIPT" validate "$log"
  [ "$status" -eq 1 ]
}

@test "validate accepts a well-formed non-clean cycle (fps=1, Clean?=no)" {
  # Pins the count/clean agreement invariant in the POSITIVE direction: a genuine
  # confirmed false positive with details, a handle and Clean?=no is valid.
  local log
  log="$(write_log '| 2026-10-01 | 3 | 1 | anchor false alarm | @alice | no |\n')"
  run bash "$SCRIPT" validate "$log"
  [ "$status" -eq 0 ]
}

@test "validate rejects a maintainer that is not a GitHub @handle" {
  # "Determined by" must be a GitHub @handle; arbitrary attribution text like
  # "Alice" is not attribution the log can hold anyone to.
  local log
  log="$(write_log '| 2026-10-01 | 0 | 0 | — | Alice | yes |\n')"
  run bash -c 'bash "$1" validate "$2" 2>&1' _ "$SCRIPT" "$log"
  [ "$status" -eq 1 ]
  [[ "$output" == *handle* ]]
}

@test "validate rejects more confirmed false positives than structural findings" {
  # False positives are selected FROM the findings, so fps > findings is malformed.
  local log
  log="$(write_log '| 2026-10-01 | 0 | 1 | phantom false positive | @alice | no |\n')"
  run bash -c 'bash "$1" validate "$2" 2>&1' _ "$SCRIPT" "$log"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot exceed"* ]]
}

@test "validate rejects a nonzero false-positive count with empty details" {
  # A confirmed false positive with no details omits what was confirmed from the
  # committed audit record.
  local log
  log="$(write_log '| 2026-10-01 | 3 | 1 | — | @alice | no |\n')"
  run bash -c 'bash "$1" validate "$2" 2>&1' _ "$SCRIPT" "$log"
  [ "$status" -eq 1 ]
  [[ "$output" == *details* ]]
}

# ---------------------------------------------------------------------------
# amcl_data_rows parsing robustness — a pipe in the free-text details cell, a
# CRLF line ending, and an out-of-range date must not silently shift fields or
# admit an impossible date. These assert on the PARSED FIELD VALUES, not just the
# exit status, so a shifted-field regression cannot pass.
# ---------------------------------------------------------------------------

# split_row <parsed-line> — populate the global array `field` from one
# amcl_data_rows output line, splitting on the 0x1f field separator.
split_row() {
  local IFS=$'\037'
  # shellcheck disable=SC2034  # `field` is read by callers
  read -r -a field <<< "$1"
}

@test "amcl_data_rows keeps an escaped pipe inside details and does not shift later fields" {
  # shellcheck source=/dev/null
  source "$SCRIPT"
  local log
  # '\|' is the documented way to write a literal pipe in a Markdown cell.
  log="$(write_log '| 2026-10-01 | 3 | 1 | anchor \\| alias | @alice | no |\n')"
  run amcl_data_rows "$log"
  [ "$status" -eq 0 ]
  local field
  split_row "$output"
  [ "${field[0]}" = "2026-10-01" ]
  [ "${field[1]}" = "3" ]
  [ "${field[2]}" = "1" ]
  [ "${field[3]}" = 'anchor \| alias' ]   # escaped pipe restored, still in details
  [ "${field[4]}" = "@alice" ]            # maintainer NOT shifted
  [ "${field[5]}" = "no" ]                # Clean? NOT shifted
}

@test "amcl_data_rows rejects a row with an unescaped literal pipe loudly (wrong field count)" {
  # shellcheck source=/dev/null
  source "$SCRIPT"
  local log
  log="$(write_log '| 2026-10-01 | 3 | 1 | anchor | alias | @alice | no |\n')"
  # Capture stdout and stderr separately: the reason must go to stderr and NO
  # (shifted) row may reach stdout.
  local out err rc=0
  out="$(amcl_data_rows "$log" 2>"$TMPDIR_TEST/err")" || rc=$?
  err="$(cat "$TMPDIR_TEST/err")"
  [ "$rc" -ne 0 ]
  [ -z "$out" ]                                        # no shifted row emitted
  [[ "$err" == *"found 9"* ]]                          # reason names the field count
}

@test "validate rejects a row with an unescaped literal pipe (exit 1, names the field count)" {
  local log
  log="$(write_log '| 2026-10-01 | 3 | 1 | anchor | alias | @alice | no |\n')"
  run bash -c 'bash "$1" validate "$2" 2>&1' _ "$SCRIPT" "$log"
  [ "$status" -eq 1 ]
  [[ "$output" == *"8 pipe-delimited fields but found 9"* ]]
}

@test "amcl_data_rows strips a CRLF line ending so Clean? has no trailing carriage return" {
  # shellcheck source=/dev/null
  source "$SCRIPT"
  local log="$TMPDIR_TEST/crlf.md"
  {
    printf '# Cycle Log\r\n\r\n'
    printf '| Cycle | Structural findings | Confirmed false positives | False-positive details | Determined by | Clean? |\r\n'
    printf '|-------|---------------------|---------------------------|------------------------|---------------|--------|\r\n'
    printf '| 2026-10-01 | 3 | 0 | — | @alice | yes |\r\n'
  } > "$log"
  run amcl_data_rows "$log"
  [ "$status" -eq 0 ]
  local field
  split_row "$output"
  [ "${field[5]}" = "yes" ]               # exactly "yes", not "yes"+CR
  [ "${#field[5]}" -eq 3 ]
}

@test "validate accepts a CRLF-saved log (Clean?/fps agreement survives \\r stripping)" {
  local log="$TMPDIR_TEST/crlf-valid.md"
  {
    printf '# Cycle Log\r\n\r\n'
    printf '| Cycle | Structural findings | Confirmed false positives | False-positive details | Determined by | Clean? |\r\n'
    printf '|-------|---------------------|---------------------------|------------------------|---------------|--------|\r\n'
    printf '| 2026-10-01 | 3 | 0 | — | @alice | yes |\r\n'
  } > "$log"
  run bash "$SCRIPT" validate "$log"
  [ "$status" -eq 0 ]
}

@test "amcl_data_rows rejects an impossible date such as 2026-99-99 (row discriminator, not a date validator)" {
  # shellcheck source=/dev/null
  source "$SCRIPT"
  local log
  # An out-of-range month/day must not count as a data row. The regex still
  # accepts e.g. 2026-02-31 by design — it bounds fields, it is not a calendar.
  log="$(write_log '| 2026-99-99 | 3 | 0 | — | @alice | yes |\n| 2026-13-40 | 1 | 0 | — | @bob | yes |\n')"
  run amcl_data_rows "$log"
  [ "$status" -eq 0 ]
  [ -z "$output" ]                        # neither impossible-date row is emitted
}

@test "amcl_data_rows still accepts a valid bounded date" {
  # shellcheck source=/dev/null
  source "$SCRIPT"
  local log
  log="$(write_log '| 2026-12-31 | 0 | 0 | — | @alice | yes |\n')"
  run amcl_data_rows "$log"
  [ "$status" -eq 0 ]
  local field
  split_row "$output"
  [ "${field[0]}" = "2026-12-31" ]
}

# ---------------------------------------------------------------------------
# eligibility — reports the clean-cycle precondition only, and NEVER signals an
# automatic promotion.
# ---------------------------------------------------------------------------

@test "eligibility reports met after two consecutive clean cycles" {
  local log
  log="$(write_log '| 2026-10-01 | 3 | 0 | — | @alice | yes |\n| 2026-11-01 | 1 | 0 | — | @bob | yes |\n')"
  run bash "$SCRIPT" eligibility "$log" 2
  [ "$status" -eq 0 ]
  [[ "$output" == *clean-cycles-met=true* ]]
}

@test "eligibility counts a same-date correction once — the superseding row wins" {
  # A correction reuses the same Cycle date; the reader collapses rows by date and
  # counts only the last one, so a duplicate-date correction supersedes the earlier
  # row rather than inflating the distinct-cycle count. Here 2026-10-01's first
  # (non-clean) row is superseded by a clean correction, leaving two clean cycles.
  local log
  log="$(write_log '| 2026-10-01 | 3 | 1 | first pass | @alice | no |\n| 2026-10-01 | 3 | 0 | — | @alice | yes |\n| 2026-11-01 | 1 | 0 | — | @bob | yes |\n')"
  run bash "$SCRIPT" eligibility "$log" 2
  [ "$status" -eq 0 ]
  [[ "$output" == *clean-cycles-met=true* ]]
}

@test "eligibility handles out-of-order dates — the two latest distinct cycles are used" {
  # Rows recorded out of chronological order must still be collapsed and ordered
  # by Cycle date; the two latest distinct cycles (11-01, 12-01) are clean.
  local log
  log="$(write_log '| 2026-12-01 | 0 | 0 | — | @carol | yes |\n| 2026-10-01 | 2 | 1 | real fp | @alice | no |\n| 2026-11-01 | 1 | 0 | — | @bob | yes |\n')"
  run bash "$SCRIPT" eligibility "$log" 2
  [ "$status" -eq 0 ]
  [[ "$output" == *clean-cycles-met=true* ]]
}

@test "eligibility is NOT met with only one clean cycle recorded" {
  local log
  log="$(write_log '| 2026-11-01 | 1 | 0 | — | @bob | yes |\n')"
  run bash "$SCRIPT" eligibility "$log" 2
  [ "$status" -eq 0 ]
  [[ "$output" == *clean-cycles-met=false* ]]
}

@test "a confirmed false positive in the latest cycle breaks the clean streak" {
  local log
  log="$(write_log '| 2026-10-01 | 3 | 0 | — | @alice | yes |\n| 2026-11-01 | 2 | 1 | anchor false alarm | @bob | no |\n')"
  run bash "$SCRIPT" eligibility "$log" 2
  [ "$status" -eq 0 ]
  [[ "$output" == *clean-cycles-met=false* ]]
}

@test "eligibility validates the log first: a Clean?=no / fps=0 row makes clean-cycles-met=false, not true" {
  # eligibility must never compute a promotion precondition over an unvalidated
  # log. A row that claims Clean?=no while recording zero false positives is
  # malformed (the Clean?/fps agreement invariant is violated); it must NOT be
  # counted as clean. Two such rows would count as a met streak if eligibility
  # skipped validation, so this pins that eligibility runs amcl_validate_log
  # first and reports false (with the reason on stderr).
  local log
  log="$(write_log '| 2026-10-01 | 0 | 0 | — | @alice | no |\n| 2026-11-01 | 0 | 0 | — | @bob | no |\n')"
  run bash -c 'bash "$1" eligibility "$2" 2 2>&1' _ "$SCRIPT" "$log"
  [ "$status" -eq 0 ]
  [[ "$output" == *clean-cycles-met=false* ]]
  [[ "$output" != *clean-cycles-met=true* ]]
  [[ "$output" == *"expected \"yes\""* ]]   # the validation reason reaches stderr
}

@test "eligibility reports false on a log with an unescaped literal pipe (validate-first)" {
  local log
  log="$(write_log '| 2026-10-01 | 0 | 0 | — | @alice | yes |\n| 2026-11-01 | 3 | 1 | anchor | alias | @bob | no |\n')"
  run bash "$SCRIPT" eligibility "$log" 2
  [ "$status" -eq 0 ]
  [[ "$output" == *clean-cycles-met=false* ]]
}

@test "eligibility always states sign-off is required and never auto-promotes (AC #4)" {
  local log
  log="$(write_log '| 2026-10-01 | 0 | 0 | — | @alice | yes |\n| 2026-11-01 | 0 | 0 | — | @bob | yes |\n')"
  run bash "$SCRIPT" eligibility "$log" 2
  [ "$status" -eq 0 ]
  # Even when the clean-cycle precondition is met, the tool must NOT signal an
  # automatic promotion and MUST restate the maintainer sign-off requirement.
  [[ "$output" == *maintainer_sign_off_required=true* ]]
  [[ "$output" == *auto_promote=false* ]]
}

# ---------------------------------------------------------------------------
# The committed log ships INERT: it is well-formed but records no clean cycles
# yet, so the shipped state cannot claim promotion eligibility (AC #4).
# ---------------------------------------------------------------------------

@test "the committed cycle log exists and is well-formed" {
  [ -f "$COMMITTED_LOG" ]
  run bash "$SCRIPT" validate "$COMMITTED_LOG"
  [ "$status" -eq 0 ]
}

@test "the committed cycle log is not promotion-eligible on merge (ships inert)" {
  run bash "$SCRIPT" eligibility "$COMMITTED_LOG" 2
  [ "$status" -eq 0 ]
  [[ "$output" == *clean-cycles-met=false* ]]
}
