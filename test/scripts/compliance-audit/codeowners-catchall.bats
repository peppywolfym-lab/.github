#!/usr/bin/env bats
# Tests for the `codeowners-no-catchall` advisory in
# scripts/compliance-audit.sh (check_codeowners).
#
# A CODEOWNERS file should carry a default `*` catch-all so files not matched by
# any path-specific rule still have an owner — otherwise `require_code_owner_review`
# silently does not apply to them. The audit raises a `settings` /
# `codeowners-no-catchall` warning when no owner line uses `*` as its pattern.
# This suite locks in that detection and confirms the repo's own CODEOWNERS
# complies (the fix for issue #371).

bats_require_minimum_version 1.5.0

# ---------------------------------------------------------------------------
# Mirrors the catch-all detection in check_codeowners
# (scripts/compliance-audit.sh): strip comment/blank lines, then look for an
# owner line whose pattern (first field) is exactly `*`.
# Returns 0 when a catch-all is present, 1 when it is absent.
# ---------------------------------------------------------------------------
_has_catchall() {
  local content="$1" owner_lines
  owner_lines=$(printf '%s\n' "$content" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$')
  printf '%s\n' "$owner_lines" | awk '{print $1}' | grep -qxF '*'
}

# Repo root, derived from this test file's location (test/scripts/compliance-audit).
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

# ---------------------------------------------------------------------------
# Catch-all present → no finding
# ---------------------------------------------------------------------------

@test "a sole catch-all line is detected" {
  run _has_catchall '* @petry-projects/org-leads'
  [ "$status" -eq 0 ]
}

@test "a catch-all alongside path-specific rules is detected" {
  body=$'* @petry-projects/org-leads\n/security/ @petry-projects/org-leads @petry-projects/security-leads'
  run _has_catchall "$body"
  [ "$status" -eq 0 ]
}

@test "comments and blank lines around the catch-all do not hide it" {
  body=$'# CODEOWNERS\n\n# Default catch-all\n* @petry-projects/org-leads\n'
  run _has_catchall "$body"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Catch-all absent → finding (status 1)
# ---------------------------------------------------------------------------

@test "only path-specific rules (no catch-all) is reported" {
  body=$'/docs/ @petry-projects/org-leads\n/security/ @petry-projects/org-leads @petry-projects/security-leads'
  run _has_catchall "$body"
  [ "$status" -eq 1 ]
}

@test "a commented-out catch-all does not count" {
  body=$'# * @petry-projects/org-leads\n/docs/ @petry-projects/org-leads'
  run _has_catchall "$body"
  [ "$status" -eq 1 ]
}

@test "a pattern merely containing '*' (not equal to it) does not count" {
  run _has_catchall '*.md @petry-projects/org-leads'
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# The repo's own CODEOWNERS complies (issue #371)
# ---------------------------------------------------------------------------

@test "the repository CODEOWNERS file has a catch-all" {
  [ -f "$REPO_ROOT/.github/CODEOWNERS" ]
  run _has_catchall "$(cat "$REPO_ROOT/.github/CODEOWNERS")"
  [ "$status" -eq 0 ]
}
