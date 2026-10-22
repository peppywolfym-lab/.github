#!/usr/bin/env bash
# scripts/agents-md-cycle-log.sh — pure, deterministic reader for the
# APPEND-ONLY, COMMITTED AGENTS.md structural cycle log
# (docs/initiatives/agents-md-validation-cycle-log.md), the tamper-evident
# durable record behind the informational → blocking promotion gate (#647,
# Phase 4 of epic #642). Reference doc: docs/initiatives/agents-md-validation.md.
#
# The promotion gate is human-gated by design. The structural check ships
# INFORMATIONAL and is promoted to BLOCKING only after (1) two consecutive audit
# cycles with zero confirmed false positives AND (2) explicit maintainer
# sign-off — never automatically. This script is the pure decision core for
# precondition (1) ONLY: it reports whether the recorded cycles are well-formed
# and whether the clean-cycle streak is met. It NEVER performs a promotion, never
# writes the log, and never signals an automatic flip — precondition (2) and the
# discrete toggle flip are deliberate human actions (see the reference doc).
#
# Why a committed log and not just the audit summary issue: an editable issue can
# be silently edited to fabricate a "two clean cycles" claim. Persisting per-cycle
# finding counts and each false-positive determination — every one attributed to
# a NAMED maintainer — to an append-only file under git makes the baseline record
# immutable (git history is the tamper-evidence) and independently auditable.
#
# The log's machine-readable surface is a Markdown table. A DATA ROW is a table
# line whose first cell is an ISO date (YYYY-MM-DD); the header and separator
# rows are ignored. Columns, in order:
#   1. Cycle                      — audit date (YYYY-MM-DD)
#   2. Structural findings        — non-negative integer (from the audit summary)
#   3. Confirmed false positives  — non-negative integer
#   4. False-positive details     — free text ('—' when none)
#   5. Determined by              — the maintainer who made the determination
#   6. Clean?                     — 'yes' iff confirmed false positives == 0
#
# Caller contract: the pure helpers below are `source`-able and side-effect-free
# (they run nothing and call no `set` at source time), so tests can source this
# file and exercise them directly. Only when executed directly does it
# `set -euo pipefail` and run the CLI.
#
# Usage:
#   agents-md-cycle-log.sh validate    <log-file>
#   agents-md-cycle-log.sh eligibility <log-file> [required-clean-cycles]
#
#   validate     exit non-zero if any recorded row is malformed or a
#                determination is not attributed to a named maintainer.
#   eligibility  report whether the last <required-clean-cycles> (default 2)
#                cycles are all clean; always exit 0 (it is a report, not a gate).

# Field separator for the parsed-row stream emitted by amcl_data_rows and read
# back by the validators. It is the ASCII Unit Separator (0x1f) — a NON-whitespace
# char — deliberately, not a tab: `read` with a whitespace IFS collapses runs of
# the delimiter, which would silently swallow an EMPTY cell (e.g. an unattributed
# "Determined by"). Empty cells must survive so the attribution guard can catch
# them, so the separator must not be whitespace.
AMCL_FS=$'\037'

# ---------------------------------------------------------------------------
# amcl_data_rows <log> — emit one line per DATA ROW (first cell is an ISO date),
# fields separated by AMCL_FS (0x1f), in order:
#   <cycle> <findings> <false_positives> <details> <maintainer> <clean>
# Header/separator/prose lines are skipped. Cells are trimmed. Pure.
# ---------------------------------------------------------------------------
amcl_data_rows() {
  local log="$1"
  [ -f "$log" ] || return 0
  # Strip CR before splitting so a CRLF-saved log does not leave a trailing '\r'
  # on the last cell (Clean?), which would break the Clean?/fps agreement check
  # in amcl_validate_log. Returns non-zero (via awk's END exit) if a dated row is
  # structurally malformed, so callers can treat that as a validation failure.
  tr -d '\r' < "$log" | awk -F'|' -v US='\037' '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    {
      # A literal "\|" is the documented way to put a pipe inside a Markdown
      # cell, but awk -F has no notion of backslash escaping and would split on
      # it, shifting every later field. Protect escaped pipes with a sentinel
      # (0x01) before the fields are used, then restore them in the details cell.
      # Assigning via gsub on $0 re-splits the record on FS with the sentinel in
      # place.
      gsub(/\\\|/, "\001")
      cycle = trim($2)
      # The date field is only a row discriminator, not a real calendar
      # validator: it bounds month (01-12) and day (01-31) so an impossible date
      # like 2026-99-99 or 2026-13-40 cannot pass, but it deliberately still
      # accepts e.g. 2026-02-31. A leap-year-correct check in awk would be far
      # more code than a manually hand-typed bad date in a committed table
      # warrants; do not add one here.
      if (cycle !~ /^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$/) next
      # It IS a data row (first cell is a date). A well-formed Markdown row has an
      # empty leading and trailing cell around 6 data cells, so NF must be exactly
      # 8. A remaining UNescaped literal "|" in a cell yields NF>8 and shifts the
      # maintainer/Clean? fields; reject such a row loudly instead of parsing it
      # with silently shifted columns.
      if (NF != 8) {
        printf "cycle %s: malformed table row — expected 8 pipe-delimited fields but found %d (unescaped \"|\" in a cell? escape it as \"\\|\")\n", cycle, NF > "/dev/stderr"
        rc = 1
        next
      }
      details = trim($5)
      gsub(/\001/, "\\|", details)
      printf "%s%s%s%s%s%s%s%s%s%s%s\n", \
        cycle, US, trim($3), US, trim($4), US, details, US, trim($6), US, trim($7)
    }
    END { exit rc }
  '
}

# ---------------------------------------------------------------------------
# amcl_is_uint <s> — 0 (true) iff <s> is a non-negative integer. Pure.
# ---------------------------------------------------------------------------
amcl_is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

# ---------------------------------------------------------------------------
# amcl_validate_log <log> — 0 iff every data row is well-formed:
#   - findings and false-positive counts are non-negative integers,
#   - a maintainer is named (attribution guard — never anonymous),
#   - the Clean? flag agrees with the false-positive count (yes iff 0).
# Emits a per-row reason to stderr and returns 1 on the first violation. An empty
# log (no data rows — the shipped baseline) is valid. Pure (reads only).
# ---------------------------------------------------------------------------
amcl_validate_log() {
  local log="$1" cycle findings fps details maintainer clean rc=0 rows
  # Capture the parsed rows first so a non-zero exit from amcl_data_rows (a dated
  # row with the wrong field count — it already printed the reason to stderr)
  # counts as a validation failure rather than being lost in a process
  # substitution.
  if ! rows="$(amcl_data_rows "$log")"; then
    rc=1
  fi
  while IFS="$AMCL_FS" read -r cycle findings fps details maintainer clean; do
    [ -n "$cycle" ] || continue
    : "${details:-}"
    if ! amcl_is_uint "$findings"; then
      printf 'cycle %s: structural-findings count "%s" is not a non-negative integer\n' "$cycle" "$findings" >&2
      rc=1; continue
    fi
    if ! amcl_is_uint "$fps"; then
      printf 'cycle %s: confirmed-false-positive count "%s" is not a non-negative integer\n' "$cycle" "$fps" >&2
      rc=1; continue
    fi
    if [ -z "$maintainer" ] || [ "$maintainer" = "—" ] || [ "$maintainer" = "-" ]; then
      printf 'cycle %s: no maintainer named in "Determined by" — every determination must name a maintainer\n' "$cycle" >&2
      rc=1; continue
    fi
    if ! [[ "$maintainer" =~ ^@[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
      printf 'cycle %s: "Determined by" must contain a valid GitHub @handle (got "%s")\n' "$cycle" "$maintainer" >&2
      rc=1; continue
    fi
    # Confirmed false positives are SELECTED FROM the structural findings, so the
    # count can never exceed the finding count; a row that claims otherwise is
    # malformed (both are validated as non-negative integers above).
    if [ "$fps" -gt "$findings" ]; then
      printf 'cycle %s: confirmed false positives (%s) cannot exceed structural findings (%s) — false positives are selected from the findings\n' \
        "$cycle" "$fps" "$findings" >&2
      rc=1; continue
    fi
    # A nonzero false-positive count must record WHAT was confirmed; an empty (or
    # placeholder "—"/"-") details cell would leave the committed audit record
    # silent about the determination it claims to make.
    if [ "$fps" -ne 0 ] && { [ -z "$details" ] || [ "$details" = "—" ] || [ "$details" = "-" ]; }; then
      printf 'cycle %s: %s confirmed false positive(s) recorded but the "False-positive details" cell is empty — record what was confirmed\n' \
        "$cycle" "$fps" >&2
      rc=1; continue
    fi
    local expected_clean
    if [ "$fps" -eq 0 ]; then expected_clean="yes"; else expected_clean="no"; fi
    local clean_lc
    clean_lc=$(printf '%s' "$clean" | tr '[:upper:]' '[:lower:]')
    if [ "$clean_lc" != "$expected_clean" ]; then
      printf 'cycle %s: Clean? is "%s" but %s confirmed false positive(s) recorded (expected "%s")\n' \
        "$cycle" "$clean" "$fps" "$expected_clean" >&2
      rc=1; continue
    fi
  done <<< "$rows"
  return "$rc"
}

# ---------------------------------------------------------------------------
# amcl_clean_cycles_met <log> <required> — print "true" iff the last <required>
# recorded cycles all have zero confirmed false positives AND a named maintainer;
# otherwise "false". Fewer than <required> recorded cycles is "false". Pure.
# ---------------------------------------------------------------------------
amcl_clean_cycles_met() {
  local log="$1" required="$2"
  # A promotion precondition must never be computed over an unvalidated log. If
  # the log is malformed (bad field count, a Clean?/fps disagreement, an
  # unattributed determination), the invariants amcl_validate_log enforces are
  # absent, and a shifted or inconsistent row could otherwise be miscounted as
  # clean. Validate first and refuse — loudly, with the reason already on stderr
  # from amcl_validate_log — instead of duplicating the per-field checks below
  # (#647). One copy of the invariant, in amcl_validate_log.
  if ! amcl_validate_log "$log"; then
    printf 'false'
    return 0
  fi
  local rows deduped recent count clean=0
  rows="$(amcl_data_rows "$log")"
  # Deduplicate by cycle date: retain only the last row for each distinct cycle
  # date, so duplicate-date corrections count once and out-of-order rows are
  # handled correctly. Build a map of cycle → line, then emit only the latest
  # line for each cycle.
  deduped=$(printf '%s' "$rows" | awk -v FS="$AMCL_FS" '
    {
      if (NF >= 1 && $1 != "") {
        seen[$1] = $0
      }
    }
    END {
      for (cycle in seen) {
        print seen[cycle]
      }
    }' | sort)
  count="$(printf '%s' "$deduped" | grep -c . || true)"
  if [ "$count" -lt "$required" ]; then
    printf 'false'
    return 0
  fi
  recent="$(printf '%s' "$deduped" | tail -n "$required")"
  local cycle findings fps details maintainer cln
  while IFS="$AMCL_FS" read -r cycle findings fps details maintainer cln; do
    [ -n "$cycle" ] || continue
    : "${findings:-}" "${details:-}" "${cln:-}"
    if amcl_is_uint "$fps" && [ "$fps" -eq 0 ] && [ -n "$maintainer" ] \
       && [ "$maintainer" != "—" ] && [ "$maintainer" != "-" ]; then
      clean=$((clean + 1))
    fi
  done < <(printf '%s\n' "$recent")
  if [ "$clean" -eq "$required" ]; then
    printf 'true'
  else
    printf 'false'
  fi
  return 0
}

# ---------------------------------------------------------------------------
# amcl_usage — print CLI usage to stdout.
# ---------------------------------------------------------------------------
amcl_usage() {
  sed -n 's/^# \{0,1\}//p' <<'USAGE'
# agents-md-cycle-log.sh validate    <log-file>
# agents-md-cycle-log.sh eligibility <log-file> [required-clean-cycles]
#
# Reads the append-only AGENTS.md structural cycle log and either validates its
# rows (every determination attributed to a named maintainer) or reports whether
# the clean-cycle promotion precondition is met. It never promotes.
USAGE
}

# ---------------------------------------------------------------------------
# amcl_main <args...> — CLI entry point. Returns 2 on usage/environment errors,
# 1 when `validate` finds a malformed/unattributed row, else 0.
# ---------------------------------------------------------------------------
amcl_main() {
  local cmd="${1:-}"
  case "$cmd" in
    validate)
      local log="${2:-}"
      if [ -z "$log" ]; then
        printf 'agents-md-cycle-log: validate needs a <log-file>\n\n' >&2
        amcl_usage >&2
        return 2
      fi
      if [ ! -f "$log" ]; then
        printf 'agents-md-cycle-log: log file not found: %s\n' "$log" >&2
        return 2
      fi
      if amcl_validate_log "$log"; then
        printf 'cycle log is well-formed: %s\n' "$log"
        return 0
      fi
      return 1
      ;;
    eligibility)
      local log="${2:-}" required="${3:-2}"
      if [ -z "$log" ]; then
        printf 'agents-md-cycle-log: eligibility needs a <log-file>\n\n' >&2
        amcl_usage >&2
        return 2
      fi
      if [ ! -f "$log" ]; then
        printf 'agents-md-cycle-log: log file not found: %s\n' "$log" >&2
        return 2
      fi
      if ! amcl_is_uint "$required" || [ "$required" -lt 1 ]; then
        printf 'agents-md-cycle-log: required-clean-cycles must be a positive integer, got "%s"\n' "$required" >&2
        return 2
      fi
      local met
      met="$(amcl_clean_cycles_met "$log" "$required")"
      # The report is deliberately explicit that meeting the clean-cycle
      # precondition is NOT a promotion: sign-off is still required and the flip
      # is never automatic (AC #4). A consumer must not read `clean-cycles-met`
      # alone as authorization to promote.
      printf 'clean-cycles-required=%s\n' "$required"
      printf 'clean-cycles-met=%s\n' "$met"
      printf 'maintainer_sign_off_required=true\n'
      printf 'auto_promote=false\n'
      if [ "$met" = "true" ]; then
        printf 'note=clean-cycle precondition met; promotion still requires explicit maintainer sign-off and a deliberate, reviewable flip — it is never automatic\n'
      else
        printf 'note=clean-cycle precondition NOT met; the check remains informational\n'
      fi
      return 0
      ;;
    -h|--help)
      amcl_usage
      return 0
      ;;
    *)
      printf 'agents-md-cycle-log: unknown or missing command: %s\n\n' "$cmd" >&2
      amcl_usage >&2
      return 2
      ;;
  esac
}

# Run the CLI only when executed directly, not when sourced by the bats tests
# that exercise the pure helper functions above.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  set -euo pipefail
  amcl_main "$@"
fi
