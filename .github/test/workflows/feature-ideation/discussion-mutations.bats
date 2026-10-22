#!/usr/bin/env bats
# Tests for discussion-mutations.sh — verifies DRY_RUN logging contract
# and live-mode delegation to gh-safe.

bats_require_minimum_version 1.5.0

load 'helpers/setup'

setup() {
  tt_make_tmpdir
  tt_install_gh_stub
  export DRY_RUN_LOG="${TT_TMP}/dry-run.jsonl"
  # shellcheck source=/dev/null
  . "${TT_SCRIPTS_DIR}/discussion-mutations.sh"
}

teardown() {
  tt_cleanup_tmpdir
}

# ---------------------------------------------------------------------------
# DRY_RUN mode
# ---------------------------------------------------------------------------

@test "dry-run: create_discussion logs entry and returns it on stdout" {
  DRY_RUN=1 run create_discussion "R_1" "C_ideas" "💡 New idea" "Body text"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"create_discussion"'* ]]
  [[ "$output" == *'"R_1"'* ]]
  [[ "$output" == *'"💡 New idea"'* ]]
  [ -f "$DRY_RUN_LOG" ]
  [ "$(wc -l <"$DRY_RUN_LOG")" -eq 1 ]
}

@test "dry-run: comment_on_discussion logs entry" {
  DRY_RUN=1 run comment_on_discussion "D_1" "Update text"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"comment_on_discussion"'* ]]
  [[ "$output" == *'"D_1"'* ]]
  [[ "$output" == *'"Update text"'* ]]
}

@test "dry-run: add_label_to_discussion logs entry" {
  DRY_RUN=1 run add_label_to_discussion "D_1" "L_enhancement"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"add_label_to_discussion"'* ]]
  [[ "$output" == *'"L_enhancement"'* ]]
}

@test "dry-run: log file is JSONL (one valid object per line)" {
  DRY_RUN=1 create_discussion "R_1" "C_1" "title 1" "body 1"
  DRY_RUN=1 comment_on_discussion "D_1" "comment 1"
  DRY_RUN=1 add_label_to_discussion "D_1" "L_1"
  [ "$(wc -l <"$DRY_RUN_LOG")" -eq 3 ]
  while IFS= read -r line; do
    printf '%s' "$line" | jq -e . >/dev/null
  done <"$DRY_RUN_LOG"
}

@test "dry-run: never invokes gh" {
  log="${TT_TMP}/gh-invocations.log"
  GH_STUB_LOG="$log"
  DRY_RUN=1 create_discussion "R_1" "C_1" "t" "b"
  [ ! -f "$log" ]
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "create_discussion: rejects wrong arg count" {
  DRY_RUN=1 run create_discussion "R_1" "C_1" "title"
  [ "$status" -eq 64 ]
}

@test "comment_on_discussion: rejects wrong arg count" {
  DRY_RUN=1 run comment_on_discussion "D_1"
  [ "$status" -eq 64 ]
}

@test "add_label_to_discussion: rejects wrong arg count" {
  DRY_RUN=1 run add_label_to_discussion "D_1"
  [ "$status" -eq 64 ]
}

# ---------------------------------------------------------------------------
# Live mode (gh stub returns success)
# ---------------------------------------------------------------------------

@test "live: create_discussion calls gh and returns its output" {
  GH_STUB_STDOUT='{"data":{"createDiscussion":{"discussion":{"id":"D_new","number":42,"url":"https://x"}}}}' \
    run create_discussion "R_1" "C_ideas" "title" "body"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"D_new"'* ]]
  [ ! -f "$DRY_RUN_LOG" ]
}

@test "live: comment_on_discussion fails loudly when gh returns errors envelope" {
  GH_STUB_STDOUT='{"errors":[{"message":"forbidden"}],"data":null}' \
    run comment_on_discussion "D_1" "body"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Regression test for Copilot review on PR petry-projects/.github#85:
# add_label_to_discussion previously sent labelIds via -f as the literal
# string `["L_1"]` which the GraphQL API rejects (labelIds is [ID!]!).
# The fix routes through gh_safe_graphql_input with a properly built JSON
# variables block.
# ---------------------------------------------------------------------------

@test "live: add_label_to_discussion variables block has labelIds as JSON array" {
  # Replace the gh stub with one that captures stdin to a file so we can
  # introspect the actual request body that gh would have received.
  body_file="${TT_TMP}/captured-body.json"
  stub_dir="${TT_TMP}/bin"
  mkdir -p "$stub_dir"
  cat >"$stub_dir/gh" <<EOF
#!/usr/bin/env bash
cat >"$body_file"
echo '{"data":{"addLabelsToLabelable":{"clientMutationId":null}}}'
EOF
  chmod +x "$stub_dir/gh"
  PATH="${stub_dir}:${PATH}" add_label_to_discussion "D_1" "L_enhancement"

  [ -f "$body_file" ]
  # Body must parse as JSON and have variables.labelIds as a length-1 array
  # whose sole element is the literal label id.
  jq -e '.variables.labelIds | type == "array"' "$body_file" >/dev/null
  jq -e '.variables.labelIds | length == 1' "$body_file" >/dev/null
  jq -e '.variables.labelIds[0] == "L_enhancement"' "$body_file" >/dev/null
  jq -e '.variables.labelableId == "D_1"' "$body_file" >/dev/null
  jq -e '.query | contains("addLabelsToLabelable")' "$body_file" >/dev/null
}
