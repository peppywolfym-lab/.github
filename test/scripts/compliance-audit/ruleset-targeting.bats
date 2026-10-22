#!/usr/bin/env bats
# Tests for the ruleset default-branch targeting jq logic in
# scripts/compliance-audit.sh, covering two correctness fixes:
#
#  1. Pagination: jq -s '[.[]]' correctly merges multiple gh --paginate pages
#     into a single flat array before the audit loop processes them.
#
#  2. Exclude conditions: rulesets that include ~ALL (or ~DEFAULT_BRANCH) but
#     explicitly exclude the default branch must NOT be flagged as targeting it,
#     preventing false-positive bypass-actor findings.

bats_require_minimum_version 1.5.0

# ---------------------------------------------------------------------------
# The jq expression from check_ruleset_bypass_actors, extracted for direct
# testing so the suite doesn't need to stand up the full audit harness.
# ---------------------------------------------------------------------------
JQ_TARGETS_DEFAULT='
  ((.conditions.ref_name.include) // []) as $inc
  | ((.conditions.ref_name.exclude) // []) as $exc
  | (
      (($inc | index("~DEFAULT_BRANCH")) != null)
      or (($inc | index("~ALL")) != null)
      or (($inc | index($db)) != null)
    )
    and (($exc | index("~DEFAULT_BRANCH")) == null)
    and (($exc | index($db)) == null)
'

_targets() {
  local db="$1" rs_json="$2"
  echo "$rs_json" | jq --arg db "refs/heads/$db" "$JQ_TARGETS_DEFAULT"
}

# ---------------------------------------------------------------------------
# Pagination: jq -s '[.[]]' merges multiple gh --paginate pages
# ---------------------------------------------------------------------------

@test "pagination: jq -s '[.[][]]' merges two pages into a single flat array" {
  pages="$(printf '[{"id":1,"name":"pr-quality"}]\n[{"id":2,"name":"code-quality"}]')"
  result=$(echo "$pages" | jq -s '[.[][]]')
  count=$(echo "$result" | jq 'length')
  [ "$count" = "2" ]
}

@test "pagination: merged array preserves all ruleset names" {
  pages="$(printf '[{"id":1,"name":"pr-quality"}]\n[{"id":2,"name":"code-quality"}]')"
  result=$(echo "$pages" | jq -s '[.[][]]')
  first=$(echo "$result" | jq -r '.[0].name')
  second=$(echo "$result" | jq -r '.[1].name')
  [ "$first" = "pr-quality" ]
  [ "$second" = "code-quality" ]
}

@test "pagination: single page still produces a valid flat array" {
  page='[{"id":1,"name":"pr-quality"}]'
  result=$(echo "$page" | jq -s '[.[][]]')
  count=$(echo "$result" | jq 'length')
  [ "$count" = "1" ]
}

# ---------------------------------------------------------------------------
# Positive cases: ruleset DOES target the default branch
# ---------------------------------------------------------------------------

@test "targeting: ~DEFAULT_BRANCH in include → targets default branch" {
  rs='{"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}}}'
  [ "$(_targets "main" "$rs")" = "true" ]
}

@test "targeting: ~ALL in include → targets default branch" {
  rs='{"conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}}}'
  [ "$(_targets "main" "$rs")" = "true" ]
}

@test "targeting: explicit refs/heads/<branch> in include → targets default branch" {
  rs='{"conditions":{"ref_name":{"include":["refs/heads/main"],"exclude":[]}}}'
  [ "$(_targets "main" "$rs")" = "true" ]
}

@test "targeting: non-default branch in exclude does not suppress match" {
  rs='{"conditions":{"ref_name":{"include":["~ALL"],"exclude":["refs/heads/feature"]}}}'
  [ "$(_targets "main" "$rs")" = "true" ]
}

# ---------------------------------------------------------------------------
# Negative cases: ruleset does NOT target the default branch (exclude checks)
# ---------------------------------------------------------------------------

@test "exclude: ~ALL include + ~DEFAULT_BRANCH exclude → does NOT target default branch" {
  rs='{"conditions":{"ref_name":{"include":["~ALL"],"exclude":["~DEFAULT_BRANCH"]}}}'
  [ "$(_targets "main" "$rs")" = "false" ]
}

@test "exclude: ~ALL include + refs/heads/main exclude → does NOT target default branch" {
  rs='{"conditions":{"ref_name":{"include":["~ALL"],"exclude":["refs/heads/main"]}}}'
  [ "$(_targets "main" "$rs")" = "false" ]
}

@test "exclude: ~DEFAULT_BRANCH include + refs/heads/main exclude → does NOT target default branch" {
  rs='{"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":["refs/heads/main"]}}}'
  [ "$(_targets "main" "$rs")" = "false" ]
}

@test "exclude: non-main default branch excluded by name → does NOT target default branch" {
  rs='{"conditions":{"ref_name":{"include":["~ALL"],"exclude":["refs/heads/trunk"]}}}'
  [ "$(_targets "trunk" "$rs")" = "false" ]
}

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

@test "edge: empty include → does NOT target default branch" {
  rs='{"conditions":{"ref_name":{"include":[],"exclude":[]}}}'
  [ "$(_targets "main" "$rs")" = "false" ]
}

@test "edge: no conditions key at all → does NOT target default branch" {
  rs='{}'
  [ "$(_targets "main" "$rs")" = "false" ]
}

@test "edge: no exclude key → treated as empty exclude (no false negatives)" {
  rs='{"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}}}'
  [ "$(_targets "main" "$rs")" = "true" ]
}
