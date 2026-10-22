#!/usr/bin/env bats
# Tests for .github/scripts/feature-ideation/lib/gh-safe.sh
#
# These tests kill R1: the original "2>/dev/null || echo '[]'" pattern that
# silently swallowed every kind of failure. Each test pins one failure mode.

bats_require_minimum_version 1.5.0

load 'helpers/setup'

setup() {
  tt_make_tmpdir
  tt_install_gh_stub
  # shellcheck source=/dev/null
  . "${TT_SCRIPTS_DIR}/lib/gh-safe.sh"
}

teardown() {
  tt_cleanup_tmpdir
}

# ---------------------------------------------------------------------------
# gh_safe_is_json
# ---------------------------------------------------------------------------

@test "is_json: accepts valid JSON" {
  run gh_safe_is_json '[]'
  [ "$status" -eq 0 ]
  run gh_safe_is_json '{"a":1}'
  [ "$status" -eq 0 ]
}

@test "is_json: rejects empty string" {
  run gh_safe_is_json ''
  [ "$status" -ne 0 ]
}

@test "is_json: rejects garbage" {
  run gh_safe_is_json 'not json'
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# gh_safe_rest — happy paths
# ---------------------------------------------------------------------------

@test "rest: returns JSON array on 200 OK + populated result" {
  GH_STUB_STDOUT='[{"number":1,"title":"hello"}]' \
    run gh_safe_rest issue list --repo foo/bar
  [ "$status" -eq 0 ]
  [ "$output" = '[{"number":1,"title":"hello"}]' ]
}

@test "rest: returns [] when gh prints empty array" {
  GH_STUB_STDOUT='[]' \
    run gh_safe_rest issue list --repo foo/bar
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "rest: normalizes empty stdout to []" {
  GH_STUB_STDOUT='' \
    run gh_safe_rest issue list --repo foo/bar
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

# ---------------------------------------------------------------------------
# gh_safe_rest — failure modes (R1 kill list)
# ---------------------------------------------------------------------------

@test "rest: EXITS NON-ZERO on auth failure (gh exit 4) and reports the failure category" {
  # CodeRabbit on PR petry-projects/.github#85: the previous assertion
  # ended with `|| true`, so it always passed regardless of the message
  # content. Use --separate-stderr to capture stderr and assert the
  # structured `[gh-safe][rest-failure]` prefix is emitted.
  GH_STUB_EXIT=4 \
  GH_STUB_STDERR='HTTP 401: Bad credentials' \
    run --separate-stderr gh_safe_rest issue list --repo foo/bar
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"rest-failure"* ]]
}

@test "rest: EXITS NON-ZERO on rate limit (gh exit 1 + 403)" {
  GH_STUB_EXIT=1 \
  GH_STUB_STDERR='API rate limit exceeded' \
    run gh_safe_rest issue list --repo foo/bar
  [ "$status" -ne 0 ]
}

@test "rest: EXITS NON-ZERO on 5xx" {
  GH_STUB_EXIT=1 \
  GH_STUB_STDERR='HTTP 502: Bad gateway' \
    run gh_safe_rest pr list --repo foo/bar
  [ "$status" -ne 0 ]
}

@test "rest: EXITS NON-ZERO on network failure" {
  GH_STUB_EXIT=2 \
  GH_STUB_STDERR='dial tcp: lookup api.github.com: connection refused' \
    run gh_safe_rest issue list --repo foo/bar
  [ "$status" -ne 0 ]
}

@test "rest: EXITS NON-ZERO on non-JSON success output" {
  GH_STUB_STDOUT='this is not json at all' \
    run gh_safe_rest issue list --repo foo/bar
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# gh_safe_graphql — happy paths
# ---------------------------------------------------------------------------

@test "graphql: returns full envelope when called without --jq" {
  GH_STUB_STDOUT='{"data":{"repository":{"id":"R_1"}}}' \
    run gh_safe_graphql -f query='q'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"R_1"'* ]]
}

@test "graphql: applies --jq filter and returns its result" {
  GH_STUB_STDOUT='{"data":{"repository":{"discussionCategories":{"nodes":[{"id":"C1","name":"Ideas"}]}}}}' \
    run gh_safe_graphql -f query='q' --jq '.data.repository.discussionCategories.nodes'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"Ideas"'* ]]
}

@test "graphql: --jq returning null normalizes to []" {
  GH_STUB_STDOUT='{"data":{"repository":{"discussionCategories":{"nodes":null}}}}' \
    run gh_safe_graphql -f query='q' --jq '.data.repository.discussionCategories.nodes'
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

# ---------------------------------------------------------------------------
# gh_safe_graphql — failure modes (R1 + R7 kill list)
# ---------------------------------------------------------------------------

@test "graphql: EXITS NON-ZERO on errors[] field present (HTTP 200)" {
  GH_STUB_STDOUT='{"errors":[{"type":"FORBIDDEN","message":"Resource not accessible"}],"data":null}' \
    run gh_safe_graphql -f query='q'
  [ "$status" -ne 0 ]
}

@test "graphql: EXITS NON-ZERO on errors[] even when caller used --jq" {
  GH_STUB_STDOUT='{"errors":[{"message":"bad"}],"data":null}' \
    run gh_safe_graphql -f query='q' --jq '.data.repository.id'
  [ "$status" -ne 0 ]
}

@test "graphql: EXITS NON-ZERO on data:null (no errors field)" {
  GH_STUB_STDOUT='{"data":null}' \
    run gh_safe_graphql -f query='q'
  [ "$status" -ne 0 ]
}

@test "graphql: EXITS NON-ZERO on gh hard failure" {
  GH_STUB_EXIT=1 \
  GH_STUB_STDERR='HTTP 401: Bad credentials' \
    run gh_safe_graphql -f query='q'
  [ "$status" -ne 0 ]
}

@test "graphql: EXITS NON-ZERO on non-JSON success output" {
  GH_STUB_STDOUT='not json' \
    run gh_safe_graphql -f query='q'
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Regression tests for Copilot review feedback on PR petry-projects/.github#85
# ---------------------------------------------------------------------------

@test "graphql: invalid --jq filter EXITS NON-ZERO instead of returning []" {
  # Catches the typo class: previously the wrapper used `jq ... || true`
  # which silently swallowed filter syntax errors and returned an empty
  # array, masking R1-class bugs.
  GH_STUB_STDOUT='{"data":{"repository":{"id":"R_1"}}}' \
    run gh_safe_graphql -f query='q' --jq '.data.repository.does_not_exist | bogus_function'
  [ "$status" -ne 0 ]
}

@test "graphql: --jq returning explicit JSON null still normalizes to []" {
  GH_STUB_STDOUT='{"data":{"repository":{"nodes":null}}}' \
    run gh_safe_graphql -f query='q' --jq '.data.repository.nodes'
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

# ---------------------------------------------------------------------------
# gh_safe_graphql_input — for mutations with array variables
# ---------------------------------------------------------------------------

@test "graphql_input: rejects non-JSON body" {
  run gh_safe_graphql_input 'not json'
  [ "$status" -eq 64 ]
}

@test "graphql_input: forwards body to gh via stdin and returns response" {
  GH_STUB_STDOUT='{"data":{"addLabelsToLabelable":{"clientMutationId":null}}}' \
    run gh_safe_graphql_input '{"query":"mutation{...}","variables":{"labelIds":["L_1"]}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'addLabelsToLabelable'* ]]
}

@test "graphql_input: EXITS NON-ZERO on errors envelope" {
  GH_STUB_STDOUT='{"errors":[{"message":"forbidden"}],"data":null}' \
    run gh_safe_graphql_input '{"query":"q","variables":{}}'
  [ "$status" -ne 0 ]
}

@test "graphql_input: EXITS NON-ZERO on data:null" {
  GH_STUB_STDOUT='{"data":null}' \
    run gh_safe_graphql_input '{"query":"q","variables":{}}'
  [ "$status" -ne 0 ]
}

@test "graphql_input: EXITS NON-ZERO on gh hard failure" {
  GH_STUB_EXIT=1 \
  GH_STUB_STDERR='HTTP 401' \
    run gh_safe_graphql_input '{"query":"q","variables":{}}'
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# gh stub — self-tests for stub defensive behaviour
# ---------------------------------------------------------------------------

@test "gh stub: fails fast when GH_STUB_SCRIPT is set but file is missing" {
  GH_STUB_SCRIPT="/nonexistent/path/script.sh" \
    run --separate-stderr "${TT_TMP}/bin/gh" issue list
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"not found"* ]]
}
