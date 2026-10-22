#!/usr/bin/env bats
# Integration test for collect-signals.sh end-to-end.
#
# Uses the multi-call gh stub to script the exact sequence of gh invocations
# the collector makes, then validates the resulting signals.json against the
# JSON schema.

load 'helpers/setup'

setup() {
  tt_make_tmpdir
  tt_install_gh_stub
  export REPO="petry-projects/talkterm"
  export GH_TOKEN="fake-token-for-tests"
  export SIGNALS_OUTPUT="${TT_TMP}/signals.json"
}

teardown() {
  tt_cleanup_tmpdir
}

# Build a multi-call gh script for the standard happy path.
# Order MUST match collect-signals.sh:
#   1. gh issue list --state open
#   2. gh issue list --state closed
#   3. gh api graphql (categories)
#   4. gh api graphql (discussions)
#   5. gh release list
#   6. gh pr list --state merged
build_happy_script() {
  local script="${TT_TMP}/gh-script.tsv"
  : >"$script"
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/issue-list-open.json" >>"$script"
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/issue-list-closed.json" >>"$script"
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/graphql-categories.json" >>"$script"
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/graphql-discussions.json" >>"$script"
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/release-list.json" >>"$script"
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/pr-list-merged.json" >>"$script"
  export GH_STUB_SCRIPT="$script"
  rm -f "${TT_TMP}/.gh-stub-counter"
}

# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------

@test "collect-signals: happy path produces valid signals.json" {
  build_happy_script
  run bash "${TT_SCRIPTS_DIR}/collect-signals.sh"
  [ "$status" -eq 0 ]
  [ -f "$SIGNALS_OUTPUT" ]
  run python3 "${TT_SCRIPTS_DIR}/validate-signals.py" "$SIGNALS_OUTPUT"
  [ "$status" -eq 0 ]
}

@test "collect-signals: bot author is filtered out of open_issues" {
  build_happy_script
  bash "${TT_SCRIPTS_DIR}/collect-signals.sh"
  count=$(jq '.open_issues.count' "$SIGNALS_OUTPUT")
  [ "$count" = "2" ]
  bot_present=$(jq '[.open_issues.items[] | select(.author.login == "dependabot[bot]")] | length' "$SIGNALS_OUTPUT")
  [ "$bot_present" = "0" ]
}

@test "collect-signals: closed issues are filtered by 30-day cutoff" {
  build_happy_script
  bash "${TT_SCRIPTS_DIR}/collect-signals.sh"
  # The fixture has one recent (2099) and one ancient (2020) closed issue.
  # Only the future-dated one should survive the 30-day-ago cutoff.
  count=$(jq '.closed_issues_30d.count' "$SIGNALS_OUTPUT")
  [ "$count" = "1" ]
  num=$(jq '.closed_issues_30d.items[0].number' "$SIGNALS_OUTPUT")
  [ "$num" = "95" ]
}

@test "collect-signals: feature_requests derives from labeled open issues" {
  build_happy_script
  bash "${TT_SCRIPTS_DIR}/collect-signals.sh"
  fr_count=$(jq '.feature_requests.count' "$SIGNALS_OUTPUT")
  [ "$fr_count" = "1" ]
  fr_num=$(jq '.feature_requests.items[0].number' "$SIGNALS_OUTPUT")
  [ "$fr_num" = "101" ]
}

@test "collect-signals: bug_reports derives from labeled open issues" {
  build_happy_script
  bash "${TT_SCRIPTS_DIR}/collect-signals.sh"
  br_count=$(jq '.bug_reports.count' "$SIGNALS_OUTPUT")
  [ "$br_count" = "1" ]
  br_num=$(jq '.bug_reports.items[0].number' "$SIGNALS_OUTPUT")
  [ "$br_num" = "102" ]
}

@test "collect-signals: ideas_discussions populated when category exists" {
  build_happy_script
  bash "${TT_SCRIPTS_DIR}/collect-signals.sh"
  idc=$(jq '.ideas_discussions.count' "$SIGNALS_OUTPUT")
  [ "$idc" = "1" ]
  title=$(jq -r '.ideas_discussions.items[0].title' "$SIGNALS_OUTPUT")
  [[ "$title" == *"Streaming voice"* ]]
}

@test "collect-signals: scan_date is ISO-8601 Zulu" {
  build_happy_script
  bash "${TT_SCRIPTS_DIR}/collect-signals.sh"
  d=$(jq -r '.scan_date' "$SIGNALS_OUTPUT")
  [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

# ---------------------------------------------------------------------------
# Failure modes — pipeline must fail loud, NOT silently produce empty data
# ---------------------------------------------------------------------------

@test "collect-signals: FAILS LOUD on open-issues auth failure" {
  script="${TT_TMP}/gh-script.tsv"
  err_file="${TT_TMP}/auth-err.txt"
  printf 'HTTP 401: Bad credentials\n' >"$err_file"
  printf '4\t-\t%s\n' "$err_file" >"$script"
  export GH_STUB_SCRIPT="$script"
  rm -f "${TT_TMP}/.gh-stub-counter"

  run bash "${TT_SCRIPTS_DIR}/collect-signals.sh"
  [ "$status" -ne 0 ]
  [ ! -f "$SIGNALS_OUTPUT" ]
}

@test "collect-signals: FAILS LOUD on GraphQL errors envelope (categories)" {
  script="${TT_TMP}/gh-script.tsv"
  : >"$script"
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/issue-list-open.json" >>"$script"
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/issue-list-closed.json" >>"$script"
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/graphql-errors-envelope.json" >>"$script"
  export GH_STUB_SCRIPT="$script"
  rm -f "${TT_TMP}/.gh-stub-counter"

  run bash "${TT_SCRIPTS_DIR}/collect-signals.sh"
  [ "$status" -ne 0 ]
  [ ! -f "$SIGNALS_OUTPUT" ]
}

@test "collect-signals: missing REPO env causes usage error" {
  unset REPO
  build_happy_script
  run bash "${TT_SCRIPTS_DIR}/collect-signals.sh"
  [ "$status" -eq 64 ]
}

@test "collect-signals: missing GH_TOKEN env causes usage error" {
  unset GH_TOKEN
  build_happy_script
  run bash "${TT_SCRIPTS_DIR}/collect-signals.sh"
  [ "$status" -eq 64 ]
}

@test "collect-signals: malformed REPO causes usage error" {
  export REPO="not-a-slug"
  build_happy_script
  run bash "${TT_SCRIPTS_DIR}/collect-signals.sh"
  [ "$status" -eq 64 ]
}

# ---------------------------------------------------------------------------
# Truncation warnings
# ---------------------------------------------------------------------------

@test "collect-signals: open-issue truncation is detected BEFORE bot filtering" {
  # Caught by Copilot review on PR petry-projects/.github#85: previously the
  # truncation check ran AFTER filter_bots_apply, so a result set composed
  # entirely of bots could drop below ISSUE_LIMIT and mask real truncation.
  # Build a fixture with ISSUE_LIMIT=3 raw items, all bot-authored. Bot
  # filter strips them to 0, but the truncation warning must still fire
  # because the raw count hit the limit.
  bot_file="${TT_TMP}/bot-only.json"
  cat >"$bot_file" <<'JSON'
[
  {"number":1,"title":"a","labels":[],"createdAt":"2026-03-01T00:00:00Z","author":{"login":"dependabot[bot]"}},
  {"number":2,"title":"b","labels":[],"createdAt":"2026-03-02T00:00:00Z","author":{"login":"renovate[bot]"}},
  {"number":3,"title":"c","labels":[],"createdAt":"2026-03-03T00:00:00Z","author":{"login":"copilot[bot]"}}
]
JSON
  empty_file="${TT_TMP}/empty.json"
  echo '[]' >"$empty_file"

  script="${TT_TMP}/gh-script.tsv"
  : >"$script"
  printf '0\t%s\t-\n' "$bot_file"   >>"$script"   # open issues — all bots
  printf '0\t%s\t-\n' "$empty_file" >>"$script"   # closed issues
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/graphql-no-ideas-category.json" >>"$script"
  printf '0\t%s\t-\n' "$empty_file" >>"$script"   # releases
  printf '0\t%s\t-\n' "$empty_file" >>"$script"   # merged PRs
  export GH_STUB_SCRIPT="$script"
  export ISSUE_LIMIT=3
  rm -f "${TT_TMP}/.gh-stub-counter"

  run bash "${TT_SCRIPTS_DIR}/collect-signals.sh"
  [ "$status" -eq 0 ]
  open_count=$(jq '.open_issues.count' "$SIGNALS_OUTPUT")
  [ "$open_count" = "0" ]
  jq -e '.truncation_warnings[] | select(.source == "open_issues")' "$SIGNALS_OUTPUT" >/dev/null
}

@test "collect-signals: emits truncation warning when discussions hasNextPage=true" {
  script="${TT_TMP}/gh-script.tsv"
  : >"$script"
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/issue-list-open.json" >>"$script"
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/issue-list-closed.json" >>"$script"
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/graphql-categories.json" >>"$script"
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/graphql-discussions-truncated.json" >>"$script"
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/release-list.json" >>"$script"
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/pr-list-merged.json" >>"$script"
  export GH_STUB_SCRIPT="$script"
  rm -f "${TT_TMP}/.gh-stub-counter"

  run bash "${TT_SCRIPTS_DIR}/collect-signals.sh"
  [ "$status" -eq 0 ]
  warn_count=$(jq '.truncation_warnings | length' "$SIGNALS_OUTPUT")
  [ "$warn_count" -ge 1 ]
  jq -e '.truncation_warnings[] | select(.source == "ideas_discussions")' "$SIGNALS_OUTPUT" >/dev/null
}

# ---------------------------------------------------------------------------
# No "Ideas" category — graceful skip, not a hard failure
# ---------------------------------------------------------------------------

@test "collect-signals: skips discussions when Ideas category absent" {
  script="${TT_TMP}/gh-script.tsv"
  : >"$script"
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/issue-list-open.json" >>"$script"
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/issue-list-closed.json" >>"$script"
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/graphql-no-ideas-category.json" >>"$script"
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/release-list.json" >>"$script"
  printf '0\t%s\t-\n' "${TT_FIXTURES_DIR}/gh-responses/pr-list-merged.json" >>"$script"
  export GH_STUB_SCRIPT="$script"
  rm -f "${TT_TMP}/.gh-stub-counter"

  run bash "${TT_SCRIPTS_DIR}/collect-signals.sh"
  [ "$status" -eq 0 ]
  idc=$(jq '.ideas_discussions.count' "$SIGNALS_OUTPUT")
  [ "$idc" = "0" ]
}
