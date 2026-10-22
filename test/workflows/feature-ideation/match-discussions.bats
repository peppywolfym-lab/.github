#!/usr/bin/env bats
# Tests for match-discussions.sh — deterministic matching of proposals
# against existing Ideas Discussions. Kills R5 (fuzzy in-prompt matching)
# and R6 (idempotency hole on retry).

bats_require_minimum_version 1.5.0

load 'helpers/setup'

MATCH="${TT_REPO_ROOT}/.github/scripts/feature-ideation/match-discussions.sh"

setup() {
  tt_make_tmpdir
}

teardown() {
  tt_cleanup_tmpdir
}

# Helper: build a signals.json with the given discussions array.
# Computes the discussions count from the array length so the fixture
# always satisfies the producer/consumer contract (even though the
# matcher only reads .items, validating contracts in test fixtures
# is good hygiene). CodeRabbit on PR petry-projects/.github#85.
build_signals() {
  local discussions="$1"
  local count
  count=$(printf '%s' "$discussions" | jq 'length')
  cat >"${TT_TMP}/signals.json" <<JSON
{
  "schema_version": "1.0.0",
  "scan_date": "2026-04-07T00:00:00Z",
  "repo": "petry-projects/talkterm",
  "open_issues": { "count": 0, "items": [] },
  "closed_issues_30d": { "count": 0, "items": [] },
  "ideas_discussions": { "count": ${count}, "items": ${discussions} },
  "releases": [],
  "merged_prs_30d": { "count": 0, "items": [] },
  "feature_requests": { "count": 0, "items": [] },
  "bug_reports": { "count": 0, "items": [] },
  "truncation_warnings": []
}
JSON
}

build_proposals() {
  printf '%s' "$1" >"${TT_TMP}/proposals.json"
}

@test "match: identical title produces a match" {
  build_signals '[{"id":"D_1","number":1,"title":"💡 Streaming voice responses"}]'
  build_proposals '[{"title":"💡 Streaming voice responses","summary":"x"}]'

  run bash "$MATCH" "${TT_TMP}/signals.json" "${TT_TMP}/proposals.json"
  [ "$status" -eq 0 ]
  matched=$(printf '%s' "$output" | jq '.matched | length')
  [ "$matched" = "1" ]
  new=$(printf '%s' "$output" | jq '.new_candidates | length')
  [ "$new" = "0" ]
}

@test "match: emoji difference does not break a match" {
  build_signals '[{"id":"D_1","number":1,"title":"🎤 Streaming voice responses"}]'
  build_proposals '[{"title":"💡 Streaming voice responses"}]'
  run bash "$MATCH" "${TT_TMP}/signals.json" "${TT_TMP}/proposals.json"
  [ "$status" -eq 0 ]
  matched=$(printf '%s' "$output" | jq '.matched | length')
  [ "$matched" = "1" ]
}

@test "match: case and stopword differences still match" {
  build_signals '[{"id":"D_1","number":1,"title":"Add support for streaming voice responses"}]'
  build_proposals '[{"title":"Streaming Voice Responses"}]'
  run bash "$MATCH" "${TT_TMP}/signals.json" "${TT_TMP}/proposals.json"
  [ "$status" -eq 0 ]
  matched=$(printf '%s' "$output" | jq '.matched | length')
  [ "$matched" = "1" ]
}

@test "match: unrelated proposal is a new candidate" {
  build_signals '[{"id":"D_1","number":1,"title":"💡 Streaming voice responses"}]'
  build_proposals '[{"title":"Dark mode toggle in settings"}]'
  run bash "$MATCH" "${TT_TMP}/signals.json" "${TT_TMP}/proposals.json"
  [ "$status" -eq 0 ]
  matched=$(printf '%s' "$output" | jq '.matched | length')
  new=$(printf '%s' "$output" | jq '.new_candidates | length')
  [ "$matched" = "0" ]
  [ "$new" = "1" ]
}

@test "match: empty existing discussions yields all candidates as new" {
  build_signals '[]'
  build_proposals '[{"title":"A"},{"title":"B"},{"title":"C"}]'
  run bash "$MATCH" "${TT_TMP}/signals.json" "${TT_TMP}/proposals.json"
  [ "$status" -eq 0 ]
  new=$(printf '%s' "$output" | jq '.new_candidates | length')
  [ "$new" = "3" ]
}

@test "match: each existing discussion only matches one proposal" {
  # Two near-identical proposals against one existing discussion.
  # Only the FIRST should match; the second goes to new_candidates.
  build_signals '[{"id":"D_1","number":1,"title":"Streaming voice responses"}]'
  build_proposals '[{"title":"Streaming voice responses"},{"title":"Streaming voice responses"}]'
  run bash "$MATCH" "${TT_TMP}/signals.json" "${TT_TMP}/proposals.json"
  [ "$status" -eq 0 ]
  matched=$(printf '%s' "$output" | jq '.matched | length')
  new=$(printf '%s' "$output" | jq '.new_candidates | length')
  [ "$matched" = "1" ]
  [ "$new" = "1" ]
}

@test "match: result includes similarity score per match" {
  build_signals '[{"id":"D_1","number":1,"title":"Streaming voice responses"}]'
  build_proposals '[{"title":"Streaming voice responses"}]'
  run bash "$MATCH" "${TT_TMP}/signals.json" "${TT_TMP}/proposals.json"
  [ "$status" -eq 0 ]
  sim=$(printf '%s' "$output" | jq '.matched[0].similarity')
  # Identical normalized titles → similarity 1.0
  awk -v s="$sim" 'BEGIN{exit !(s>=0.99)}'
}

@test "match: threshold env var is respected" {
  build_signals '[{"id":"D_1","number":1,"title":"voice"}]'
  build_proposals '[{"title":"voice streaming responses"}]'
  # At default threshold 0.6 these have Jaccard ~0.33, so no match.
  run bash "$MATCH" "${TT_TMP}/signals.json" "${TT_TMP}/proposals.json"
  [ "$status" -eq 0 ]
  matched=$(printf '%s' "$output" | jq '.matched | length')
  [ "$matched" = "0" ]
  # Lower the threshold and they should match.
  MATCH_THRESHOLD=0.2 run bash "$MATCH" "${TT_TMP}/signals.json" "${TT_TMP}/proposals.json"
  [ "$status" -eq 0 ]
  matched=$(printf '%s' "$output" | jq '.matched | length')
  [ "$matched" = "1" ]
}

@test "match: missing signals file causes usage error" {
  build_proposals '[{"title":"x"}]'
  run bash "$MATCH" "${TT_TMP}/no-such-file.json" "${TT_TMP}/proposals.json"
  [ "$status" -eq 64 ]
}

@test "match: missing proposals file causes usage error" {
  build_signals '[]'
  run bash "$MATCH" "${TT_TMP}/signals.json" "${TT_TMP}/no-such-file.json"
  [ "$status" -eq 64 ]
}

@test "match: malformed proposal entries are skipped, valid ones processed" {
  build_signals '[]'
  build_proposals '[{"title":"valid"},"garbage",{"no_title":"x"},{"title":"also valid"}]'
  run --separate-stderr bash "$MATCH" "${TT_TMP}/signals.json" "${TT_TMP}/proposals.json"
  [ "$status" -eq 0 ]
  new=$(printf '%s' "$output" | jq '.new_candidates | length')
  [ "$new" = "2" ]
}

@test "match: proposals as empty array yields empty result" {
  build_signals '[{"id":"D_1","number":1,"title":"x"}]'
  build_proposals '[]'
  run bash "$MATCH" "${TT_TMP}/signals.json" "${TT_TMP}/proposals.json"
  [ "$status" -eq 0 ]
  matched=$(printf '%s' "$output" | jq '.matched | length')
  new=$(printf '%s' "$output" | jq '.new_candidates | length')
  [ "$matched" = "0" ]
  [ "$new" = "0" ]
}

@test "match: rejects non-numeric MATCH_THRESHOLD with usage error" {
  # Caught by Copilot review on PR petry-projects/.github#85: previously
  # a typo in MATCH_THRESHOLD produced an opaque Python traceback.
  build_signals '[]'
  build_proposals '[{"title":"x"}]'
  MATCH_THRESHOLD="not-a-number" run bash "$MATCH" "${TT_TMP}/signals.json" "${TT_TMP}/proposals.json"
  [ "$status" -eq 64 ]
}

@test "match: rejects MATCH_THRESHOLD outside [0, 1]" {
  build_signals '[]'
  build_proposals '[{"title":"x"}]'
  MATCH_THRESHOLD="1.5" run bash "$MATCH" "${TT_TMP}/signals.json" "${TT_TMP}/proposals.json"
  [ "$status" -eq 64 ]
}

@test "match: accepts boundary MATCH_THRESHOLD values 0 and 1" {
  build_signals '[]'
  build_proposals '[{"title":"x"}]'
  MATCH_THRESHOLD="0" run bash "$MATCH" "${TT_TMP}/signals.json" "${TT_TMP}/proposals.json"
  [ "$status" -eq 0 ]
  MATCH_THRESHOLD="1" run bash "$MATCH" "${TT_TMP}/signals.json" "${TT_TMP}/proposals.json"
  [ "$status" -eq 0 ]
}

@test "match: malformed JSON in signals file exits non-zero" {
  # Caught by CodeRabbit review on PR petry-projects/.github#85.
  printf 'not valid json' >"${TT_TMP}/signals.json"
  build_proposals '[{"title":"x"}]'
  run bash "$MATCH" "${TT_TMP}/signals.json" "${TT_TMP}/proposals.json"
  [ "$status" -ne 0 ]
}

@test "match: malformed JSON in proposals file exits non-zero" {
  # Caught by CodeRabbit review on PR petry-projects/.github#85.
  build_signals '[]'
  printf 'not valid json' >"${TT_TMP}/proposals.json"
  run bash "$MATCH" "${TT_TMP}/signals.json" "${TT_TMP}/proposals.json"
  [ "$status" -ne 0 ]
}

@test "match: idempotent re-run of same proposals against existing matches yields all-matched" {
  # Simulates the R6 idempotency case: run 1 created Discussions, run 2
  # finds them and should NOT propose duplicates.
  build_signals '[
    {"id":"D_1","number":1,"title":"💡 Streaming voice responses"},
    {"id":"D_2","number":2,"title":"💡 Dark mode"}
  ]'
  build_proposals '[
    {"title":"💡 Streaming voice responses"},
    {"title":"💡 Dark mode"}
  ]'
  run bash "$MATCH" "${TT_TMP}/signals.json" "${TT_TMP}/proposals.json"
  [ "$status" -eq 0 ]
  matched=$(printf '%s' "$output" | jq '.matched | length')
  new=$(printf '%s' "$output" | jq '.new_candidates | length')
  [ "$matched" = "2" ]
  [ "$new" = "0" ]
}
