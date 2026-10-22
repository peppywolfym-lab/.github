#!/usr/bin/env bats
# Tests for .github/scripts/feature-ideation/lib/filter-bots.sh
#
# Pins R10: bot filter must catch all known automation accounts and be
# extensible via env var.

load 'helpers/setup'

setup() {
  # shellcheck source=/dev/null
  . "${TT_SCRIPTS_DIR}/lib/filter-bots.sh"
}

input_with_bots() {
  cat <<'JSON'
[
  {"number":1,"title":"real issue","author":{"login":"alice"}},
  {"number":2,"title":"dependabot bump","author":{"login":"dependabot[bot]"}},
  {"number":3,"title":"renovate bump","author":{"login":"renovate[bot]"}},
  {"number":4,"title":"copilot suggestion","author":{"login":"copilot[bot]"}},
  {"number":5,"title":"coderabbit","author":{"login":"coderabbitai[bot]"}},
  {"number":6,"title":"another real","author":{"login":"bob"}},
  {"number":7,"title":"github actions","author":{"login":"github-actions[bot]"}}
]
JSON
}

@test "filter-bots: removes default bot authors" {
  result=$(input_with_bots | filter_bots_apply)
  count=$(printf '%s' "$result" | jq 'length')
  [ "$count" = "2" ]
  printf '%s' "$result" | jq -e '.[] | select(.author.login == "alice")' >/dev/null
  printf '%s' "$result" | jq -e '.[] | select(.author.login == "bob")' >/dev/null
}

@test "filter-bots: leaves human authors untouched" {
  result=$(input_with_bots | filter_bots_apply)
  for user in alice bob; do
    printf '%s' "$result" | jq -e --arg u "$user" '.[] | select(.author.login == $u)' >/dev/null
  done
}

@test "filter-bots: handles items without author field" {
  echo '[{"number":1,"title":"orphan"}]' | filter_bots_apply | jq -e '.[0].number == 1' >/dev/null
}

@test "filter-bots: env extension adds custom bot logins" {
  # NOTE: must use `bash -c`, not `sh -c`. On Ubuntu, /bin/sh is dash, which
  # doesn't support `set -o pipefail` and would choke when sourcing a script
  # that uses bash-isms. macOS /bin/sh is bash so it works there but CI fails.
  input='[{"number":1,"title":"x","author":{"login":"my-custom-bot"}},{"number":2,"title":"y","author":{"login":"alice"}}]'
  result=$(FEATURE_IDEATION_BOT_AUTHORS="my-custom-bot" bash -c "
    . '${TT_SCRIPTS_DIR}/lib/filter-bots.sh'
    printf '%s' '$input' | filter_bots_apply
  ")
  count=$(printf '%s' "$result" | jq 'length')
  [ "$count" = "1" ]
  login=$(printf '%s' "$result" | jq -r '.[0].author.login')
  [ "$login" = "alice" ]
}

@test "filter-bots: empty input array round-trips" {
  result=$(echo '[]' | filter_bots_apply)
  [ "$result" = "[]" ]
}
