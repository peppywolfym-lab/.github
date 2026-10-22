#!/usr/bin/env bats
# Tests for .github/scripts/feature-ideation/lib/date-utils.sh

load 'helpers/setup'

setup() {
  # shellcheck source=/dev/null
  . "${TT_SCRIPTS_DIR}/lib/date-utils.sh"
}

@test "date_days_ago: returns ISO date format" {
  run date_days_ago 30
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

@test "date_days_ago: 0 returns today" {
  # Use the helper function rather than the raw system `date` call so the test
  # validates behaviour consistently on both GNU and BSD systems.
  # Caught by CodeRabbit review on PR petry-projects/.github#85.
  today=$(date_today)
  run date_days_ago 0
  [ "$status" -eq 0 ]
  [ "$output" = "$today" ]
}

@test "date_days_ago: rejects non-integer input" {
  run date_days_ago "abc"
  [ "$status" -ne 0 ]
}

@test "date_days_ago: rejects empty input" {
  run date_days_ago ""
  [ "$status" -ne 0 ]
}

@test "date_days_ago: 30 days ago is earlier than today" {
  today=$(date_today)
  past=$(date_days_ago 30)
  [ "$past" \< "$today" ]
}

@test "date_now_iso: returns ISO-8601 Zulu" {
  run date_now_iso
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "date_today: returns YYYY-MM-DD" {
  run date_today
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}
