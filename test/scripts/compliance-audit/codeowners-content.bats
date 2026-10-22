#!/usr/bin/env bats
# Tests for the CODEOWNERS content-decoding step in
# scripts/compliance-audit.sh (check_codeowners).
#
# The GitHub contents API returns a file body as base64 under `.content`. On a
# 404, `gh api` prints the error body (e.g. `{"message":"Not Found",...}`) to
# stdout, so the fetch must reject anything that does not cleanly base64-decode.
# Otherwise the error JSON leaks in as a fake owner line and the audit reports a
# bogus `codeowners-org-leads-not-first` finding whose "offending line" is the
# 404 payload — exactly the regression that motivated issue #370.

bats_require_minimum_version 1.5.0

# ---------------------------------------------------------------------------
# Mirrors the decode step in check_codeowners (scripts/compliance-audit.sh).
# Prints the decoded file and returns 0 on success; returns 1 with no output
# when $1 is not base64-decodable file content (empty, or an API error body).
# ---------------------------------------------------------------------------
_decode() {
  local content="$1" decoded
  [ -n "$content" ] || return 1
  decoded=$(printf '%s' "$content" | base64 -d 2>/dev/null) || return 1
  [ -n "$decoded" ] || return 1
  printf '%s' "$decoded"
}

# The exact 404 error body GitHub returns for a missing contents path.
NOT_FOUND='{"message":"Not Found","documentation_url":"https://docs.github.com/rest/repos/contents#get-repository-content","status":"404"}'

# ---------------------------------------------------------------------------
# Valid content is decoded
# ---------------------------------------------------------------------------

@test "valid base64 content decodes to the CODEOWNERS body" {
  content=$(printf '* @petry-projects/org-leads\n' | base64)
  run _decode "$content"
  [ "$status" -eq 0 ]
  [ "$output" = "* @petry-projects/org-leads" ]
}

@test "multi-line base64 (as the contents API wraps it) still decodes" {
  body=$'* @petry-projects/org-leads\n/security/ @petry-projects/org-leads @petry-projects/security-leads\n'
  content=$(printf '%s' "$body" | base64) # GNU base64 wraps at 76 cols
  run _decode "$content"
  [ "$status" -eq 0 ]
  [[ "$output" == *"@petry-projects/org-leads"* ]]
  [[ "$output" == *"@petry-projects/security-leads"* ]]
}

# ---------------------------------------------------------------------------
# API error bodies are rejected (the issue #370 regression)
# ---------------------------------------------------------------------------

@test "a single 404 error body is rejected, not treated as content" {
  run _decode "$NOT_FOUND"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "triple-concatenated 404 bodies (the finding's offending line) are rejected" {
  run _decode "${NOT_FOUND}${NOT_FOUND}${NOT_FOUND}"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Empty / degenerate inputs are rejected
# ---------------------------------------------------------------------------

@test "empty content is rejected" {
  run _decode ""
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "base64 that decodes to an empty string is rejected" {
  run _decode "$(printf '' | base64)"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
