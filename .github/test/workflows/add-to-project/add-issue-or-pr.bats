#!/usr/bin/env bats
# Tests for add-issue-or-pr.sh — noise gate (env-driven) + reconcile:
# qualifying content is added (idempotent), content that stops qualifying
# is removed from the board.

bats_require_minimum_version 1.5.0

load 'helpers/setup'

setup() {
  tt_make_tmpdir
  tt_install_gh_stub
  export PROJECT_ID="PVT_test_project"
  export PROJECT_URL="https://example.invalid/projects/1"
  export GH_TOKEN="t_test"
  export GH_STUB_LOG="${TT_TMP}/gh.log"
  # shellcheck source=/dev/null
  . "${TT_SCRIPTS_DIR}/add-issue-or-pr.sh"
}

teardown() {
  tt_cleanup_tmpdir
}

labels_of() {
  jq -nc '$ARGS.positional | map({name: .})' --args "$@"
}

# A one-page items response whose nodes are issue/PR items keyed by content
# id (matches find_project_item content-id). With no args → an empty page.
write_content_page() {
  local out_path="$1"; shift
  local has_next="$1"; shift
  local end_cursor="$1"; shift
  local nodes='[]'
  for cid in "$@"; do
    local id_suffix
    if command -v sha256sum >/dev/null 2>&1; then
      id_suffix=$(printf '%s' "$cid" | sha256sum | cut -c1-10)
    else
      id_suffix=$(printf '%s' "$cid" | shasum -a 256 | cut -c1-10)
    fi
    nodes=$(jq --arg cid "$cid" --arg id "PVTI_${id_suffix}" \
      '. + [{id: $id, content: {id: $cid, title: ("item " + $cid)}}]' <<<"$nodes")
  done
  jq --argjson nodes "$nodes" \
     --argjson hasNext "$has_next" \
     --arg endCursor "$end_cursor" \
     '{data:{node:{items:{pageInfo:{endCursor:$endCursor, hasNextPage:$hasNext}, nodes:$nodes}}}}' \
     <<<"{}" >"$out_path"
}

gh_script_line() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3"
}

# Drive the gh stub with a single find call that returns an empty board.
stub_empty_board() {
  local page="${TT_TMP}/empty.json"
  write_content_page "$page" false ""
  local script="${TT_TMP}/script.txt"
  gh_script_line 0 "$page" "-" >"$script"
  export GH_STUB_SCRIPT="$script"
}

assert_invocation_count() {
  local expected="$1"
  local actual=0
  if [ -f "${GH_STUB_LOG}" ]; then
    actual=$(wc -l <"${GH_STUB_LOG}" | tr -d ' ')
  fi
  [ "$actual" -eq "$expected" ] || {
    printf 'expected %d gh invocations, got %d\n' "$expected" "$actual" >&2
    if [ -f "${GH_STUB_LOG}" ]; then cat "${GH_STUB_LOG}" >&2; fi
    return 1
  }
}

assert_last_invocation_contains() {
  local last
  last=$(tail -n 1 "${GH_STUB_LOG}" | sed 's/\\//g')
  for needle in "$@"; do
    [[ "$last" == *"${needle}"* ]] || {
      printf 'expected last invocation to contain %q\nactual: %s\n' "$needle" "$last" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# Arg validation
# ---------------------------------------------------------------------------

@test "reconcile_content_with_project: rejects wrong arg count" {
  run reconcile_content_with_project "N" "U"
  [ "$status" -eq 64 ]
}

@test "reconcile_content_with_project: fails fast without PROJECT_ID" {
  unset PROJECT_ID
  run --separate-stderr reconcile_content_with_project "I_1" "https://x" "[]"
  [ "$status" -eq 64 ]
  [[ "$stderr" == *"PROJECT_ID env var is required"* ]]
}

@test "reconcile_content_with_project: fails fast with ::error:: when GH_TOKEN is empty" {
  unset GH_TOKEN
  run --separate-stderr reconcile_content_with_project "I_1" "https://x" "[]"
  [ "$status" -eq 64 ]
  [[ "$stderr" == *"::error::"* ]]
  [[ "$stderr" == *"GH_TOKEN is empty"* ]]
  [[ "$stderr" == *"petry-projects/.github#387"* ]]
}

@test "find_content_item_id: rejects wrong arg count" {
  run find_content_item_id
  [ "$status" -eq 64 ]
}

# ---------------------------------------------------------------------------
# Noise gate — non-qualifying content not on the board → clean skip
# (one find call to confirm it is not present, no mutation)
# ---------------------------------------------------------------------------

@test "no dev-lead label, not on board → skip, only the find call" {
  stub_empty_board
  run reconcile_content_with_project "I_1" "https://example.invalid/issues/1" "$(labels_of bug enhancement)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skip"* ]]
  [[ "$output" == *"not on board"* ]]
  [[ "$output" == *"missing required label 'dev-lead'"* ]]
  assert_invocation_count 1
}

@test "dev-lead + compliance-audit, not on board → skip (noise gate), find only" {
  stub_empty_board
  run reconcile_content_with_project "I_1" "https://example.invalid/issues/1" "$(labels_of dev-lead compliance-audit)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"has excluded label 'compliance-audit'"* ]]
  assert_invocation_count 1
}

@test "dev-lead + health-check, not on board → skip" {
  stub_empty_board
  run reconcile_content_with_project "I_1" "https://example.invalid/issues/1" "$(labels_of dev-lead health-check)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"has excluded label 'health-check'"* ]]
  assert_invocation_count 1
}

@test "dev-lead + fleet-tracker, not on board → skip" {
  stub_empty_board
  run reconcile_content_with_project "I_1" "https://example.invalid/issues/1" "$(labels_of dev-lead fleet-tracker)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"has excluded label 'fleet-tracker'"* ]]
  assert_invocation_count 1
}

@test "dev-lead + daily-report, not on board → skip" {
  stub_empty_board
  run reconcile_content_with_project "I_1" "https://example.invalid/issues/1" "$(labels_of dev-lead daily-report)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"has excluded label 'daily-report'"* ]]
  assert_invocation_count 1
}

# ---------------------------------------------------------------------------
# Happy path — qualifying content → idempotent add, no find-first
# ---------------------------------------------------------------------------

@test "dev-lead alone → exactly one addProjectV2ItemById with the content id" {
  local script="${TT_TMP}/script.txt"
  gh_script_line 0 "-" "-" >"$script"
  export GH_STUB_SCRIPT="$script"

  run reconcile_content_with_project "I_node_xyz" "https://example.invalid/issues/1" "$(labels_of dev-lead)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Adding https://example.invalid/issues/1"* ]]
  assert_invocation_count 1
  assert_last_invocation_contains "addProjectV2ItemById" "I_node_xyz"
}

@test "dev-lead + non-excluded other label → still qualifies, one add call" {
  local script="${TT_TMP}/script.txt"
  gh_script_line 0 "-" "-" >"$script"
  export GH_STUB_SCRIPT="$script"

  run reconcile_content_with_project "I_node_xyz" "https://example.invalid/issues/1" "$(labels_of dev-lead bug enhancement)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Adding"* ]]
  assert_invocation_count 1
  assert_last_invocation_contains "addProjectV2ItemById"
}

# ---------------------------------------------------------------------------
# Reconcile remove path (#415 §2): content that stops qualifying but is on
# the board → find by content id, then delete that item.
# ---------------------------------------------------------------------------

@test "dev-lead removed but item on board → deleteProjectV2Item with the found item id" {
  local page="${TT_TMP}/page1.json"
  write_content_page "$page" false "" "I_onboard"
  local expected_id
  expected_id=$(jq -r '.data.node.items.nodes[0].id' <"$page")

  local script="${TT_TMP}/script.txt"
  {
    gh_script_line 0 "$page" "-"   # find by content id
    gh_script_line 0 "-" "-"       # delete
  } >"$script"
  export GH_STUB_SCRIPT="$script"

  run reconcile_content_with_project "I_onboard" "https://example.invalid/issues/1" "$(labels_of bug)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removing https://example.invalid/issues/1"* ]]
  [[ "$output" == *"no longer qualifies"* ]]
  assert_invocation_count 2
  assert_last_invocation_contains "deleteProjectV2Item" "$expected_id"
}

@test "excluded label added to an on-board item → removed" {
  local page="${TT_TMP}/page1.json"
  write_content_page "$page" false "" "I_onboard"
  local script="${TT_TMP}/script.txt"
  {
    gh_script_line 0 "$page" "-"
    gh_script_line 0 "-" "-"
  } >"$script"
  export GH_STUB_SCRIPT="$script"

  run reconcile_content_with_project "I_onboard" "https://example.invalid/issues/1" "$(labels_of dev-lead compliance-audit)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removing"* ]]
  assert_invocation_count 2
  assert_last_invocation_contains "deleteProjectV2Item"
}

# ---------------------------------------------------------------------------
# Payload defense: malformed LABELS_JSON → treated as empty, clean skip
# ---------------------------------------------------------------------------

@test "labels_json='null' → empty array, skip (not on board)" {
  stub_empty_board
  run reconcile_content_with_project "I_1" "https://example.invalid/issues/1" "null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skip"* ]]
  [[ "$output" == *"missing required label"* ]]
  assert_invocation_count 1
}

@test "labels_json is an object (not array) → empty, skip" {
  stub_empty_board
  run reconcile_content_with_project "I_1" "https://example.invalid/issues/1" '{"name":"dev-lead"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skip"* ]]
  [[ "$output" == *"missing required label"* ]]
  assert_invocation_count 1
}

# ---------------------------------------------------------------------------
# Programmer error path: non-1, non-64 from evaluate_noise_gate is NOT swallowed
# ---------------------------------------------------------------------------

@test "evaluate_noise_gate: returns 64 on wrong arg count (propagated, not swallowed)" {
  run evaluate_noise_gate
  [ "$status" -eq 64 ]
}

# ---------------------------------------------------------------------------
# evaluate_noise_gate direct API — defaults
# ---------------------------------------------------------------------------

@test "evaluate_noise_gate: returns 0 for qualifying labels" {
  run evaluate_noise_gate "$(labels_of dev-lead)"
  [ "$status" -eq 0 ]
}

@test "evaluate_noise_gate: returns 1 for missing required label" {
  run evaluate_noise_gate "$(labels_of bug)"
  [ "$status" -eq 1 ]
}

@test "evaluate_noise_gate: returns 1 for any excluded label" {
  run evaluate_noise_gate "$(labels_of dev-lead daily-report)"
  [ "$status" -eq 1 ]
}

@test "evaluate_noise_gate: 'null' labels → treated as empty, returns 1 (not crash)" {
  run evaluate_noise_gate "null"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# evaluate_noise_gate — env-driven label config (#415 §3)
# ---------------------------------------------------------------------------

@test "evaluate_noise_gate: REQUIRED_LABEL override gates on a different label" {
  export REQUIRED_LABEL="triage"
  run evaluate_noise_gate "$(labels_of triage)"
  [ "$status" -eq 0 ]
  run evaluate_noise_gate "$(labels_of dev-lead)"
  [ "$status" -eq 1 ]
}

@test "evaluate_noise_gate: empty REQUIRED_LABEL un-gates (any labels qualify)" {
  export REQUIRED_LABEL=""
  run evaluate_noise_gate "$(labels_of bug)"
  [ "$status" -eq 0 ]
  run evaluate_noise_gate "$(labels_of)"
  [ "$status" -eq 0 ]
}

@test "evaluate_noise_gate: empty REQUIRED_LABEL still honours excluded labels" {
  export REQUIRED_LABEL=""
  run --separate-stderr evaluate_noise_gate "$(labels_of bug compliance-audit)"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"has excluded label 'compliance-audit'"* ]]
}

@test "evaluate_noise_gate: empty EXCLUDED_LABELS disables exclusions entirely" {
  # An explicitly empty value (not unset) means "no exclusions" — the
  # ${VAR-default} form respects it instead of falling back to the default set.
  export EXCLUDED_LABELS=""
  run evaluate_noise_gate "$(labels_of dev-lead compliance-audit)"
  [ "$status" -eq 0 ]
}

@test "evaluate_noise_gate: EXCLUDED_LABELS override replaces the default exclusions" {
  export EXCLUDED_LABELS="wontfix, spam"
  # compliance-audit is no longer excluded under the override → qualifies
  run evaluate_noise_gate "$(labels_of dev-lead compliance-audit)"
  [ "$status" -eq 0 ]
  # the new exclusion blocks (and tolerates surrounding whitespace in config)
  run --separate-stderr evaluate_noise_gate "$(labels_of dev-lead spam)"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"has excluded label 'spam'"* ]]
}
