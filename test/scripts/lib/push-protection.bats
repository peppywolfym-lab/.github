#!/usr/bin/env bats
# Tests for scripts/lib/push-protection.sh — pp_check_security_and_analysis()
#
# Covers the plan-gated feature handling: warning-severity settings whose API
# status is null (absent from the response) must NOT generate a finding, since
# a null status indicates the org plan does not support the feature and there
# is nothing the operator can do to remediate it.

load 'helpers/setup'

# ---------------------------------------------------------------------------
# Helpers: build repo-API JSON payloads
# ---------------------------------------------------------------------------

# Build the full repo JSON object that gh api "repos/ORG/REPO" returns.
# Accepts an inline security_and_analysis JSON fragment as $1.
# The mock gh_api then applies ".security_and_analysis // {}" to this object.
make_repo_json() {
  local sa_json="$1"
  printf '{"security_and_analysis":%s}' "$sa_json"
}

# ---------------------------------------------------------------------------
# Test setup / teardown
# ---------------------------------------------------------------------------

setup() {
  tt_make_tmpdir

  # Log file for add_finding calls — each call appends one line:
  #   "<repo>|<category>|<check>|<severity>|<detail>"
  FINDINGS_LOG="${TT_TMP}/findings.log"
  export FINDINGS_LOG

  # Default: gh_api returns a fully-compliant security_and_analysis object
  # wrapped in the full repo JSON so the jq filter ".security_and_analysis // {}"
  # resolves correctly.
  GH_API_RESPONSE="$(make_repo_json '{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"},"secret_scanning_ai_detection":{"status":"enabled"},"secret_scanning_non_provider_patterns":{"status":"enabled"},"dependabot_security_updates":{"status":"enabled"}}')"
  export GH_API_RESPONSE

  # Second-call response for the secret-scanning alerts proxy check
  # (used only when the primary call returns {}).
  GH_API_ALERTS_RESPONSE='[]'
  export GH_API_ALERTS_RESPONSE

  ORG="test-org"
  export ORG

  # Track how many times gh_api has been called so we can return different
  # responses for the primary (repo) call vs. the proxy (alerts) call.
  GH_API_CALL_COUNT=0
  export GH_API_CALL_COUNT

  gh_api() {
    GH_API_CALL_COUNT=$((GH_API_CALL_COUNT + 1))
    local endpoint="$1"; shift
    local jq_filter=""
    while [ $# -gt 0 ]; do
      if [ "$1" = "--jq" ] && [ $# -gt 1 ]; then
        jq_filter="$2"; shift 2
      else
        shift
      fi
    done
    # First call is always the primary repo endpoint.
    # Subsequent calls are the alerts proxy.
    local response
    if [ "$GH_API_CALL_COUNT" -eq 1 ]; then
      response="$GH_API_RESPONSE"
    else
      response="$GH_API_ALERTS_RESPONSE"
    fi
    if [ -n "$jq_filter" ]; then
      printf '%s' "$response" | jq -r "$jq_filter" 2>/dev/null || echo "{}"
    else
      printf '%s' "$response"
    fi
  }
  export -f gh_api

  add_finding() {
    local repo="$1" category="$2" check="$3" severity="$4" detail="$5"
    printf '%s|%s|%s|%s|%s\n' "$repo" "$category" "$check" "$severity" "$detail" \
      >>"$FINDINGS_LOG"
  }
  export -f add_finding

  # shellcheck source=/dev/null
  . "${TT_SCRIPTS_LIB_DIR}/push-protection.sh"
}

teardown() {
  tt_cleanup_tmpdir
}

findings() {
  if [ -f "$FINDINGS_LOG" ]; then
    cat "$FINDINGS_LOG"
  else
    echo ""
  fi
}

finding_count() {
  if [ -f "$FINDINGS_LOG" ]; then
    wc -l < "$FINDINGS_LOG" | tr -d ' '
  else
    echo "0"
  fi
}

# ---------------------------------------------------------------------------
# Fully-compliant repo — no findings expected
# ---------------------------------------------------------------------------

@test "pp_check_security_and_analysis: no findings when all settings are enabled" {
  pp_check_security_and_analysis "my-repo"
  [ "$(finding_count)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# warning-severity, null actual → plan does not support feature → no finding
# ---------------------------------------------------------------------------

@test "pp_check_security_and_analysis: secret_scanning_ai_detection absent emits no finding (plan-gated)" {
  GH_API_RESPONSE="$(make_repo_json '{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"},"dependabot_security_updates":{"status":"enabled"}}')"
  pp_check_security_and_analysis "my-repo"
  if grep -q "secret_scanning_ai_detection" "$FINDINGS_LOG" 2>/dev/null; then
    echo "unexpected finding for secret_scanning_ai_detection when status is absent" >&2
    false
  fi
}

@test "pp_check_security_and_analysis: secret_scanning_non_provider_patterns absent emits no finding (plan-gated)" {
  GH_API_RESPONSE="$(make_repo_json '{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"},"secret_scanning_ai_detection":{"status":"enabled"},"dependabot_security_updates":{"status":"enabled"}}')"
  pp_check_security_and_analysis "my-repo"
  if grep -q "secret_scanning_non_provider_patterns" "$FINDINGS_LOG" 2>/dev/null; then
    echo "unexpected finding for secret_scanning_non_provider_patterns when status is absent" >&2
    false
  fi
}

@test "pp_check_security_and_analysis: dependabot_security_updates absent emits no finding (warning, plan-gated)" {
  GH_API_RESPONSE="$(make_repo_json '{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"},"secret_scanning_ai_detection":{"status":"enabled"},"secret_scanning_non_provider_patterns":{"status":"enabled"}}')"
  pp_check_security_and_analysis "my-repo"
  if grep -q "dependabot_security_updates" "$FINDINGS_LOG" 2>/dev/null; then
    echo "unexpected finding for dependabot_security_updates when status is absent" >&2
    false
  fi
}

# ---------------------------------------------------------------------------
# warning-severity, disabled actual → feature exists but off → finding emitted
# ---------------------------------------------------------------------------

@test "pp_check_security_and_analysis: secret_scanning_ai_detection disabled emits a warning finding" {
  GH_API_RESPONSE="$(make_repo_json '{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"},"secret_scanning_ai_detection":{"status":"disabled"},"secret_scanning_non_provider_patterns":{"status":"enabled"},"dependabot_security_updates":{"status":"enabled"}}')"
  pp_check_security_and_analysis "my-repo"
  grep -q "secret_scanning_ai_detection" "$FINDINGS_LOG"
  grep -q "|warning|" "$FINDINGS_LOG"
}

@test "pp_check_security_and_analysis: secret_scanning_non_provider_patterns disabled emits a warning finding (GHAS available)" {
  # advanced_security enabled → GitHub Advanced Security is available, so a
  # disabled non-provider-patterns setting is actionable and must be flagged.
  GH_API_RESPONSE="$(make_repo_json '{"advanced_security":{"status":"enabled"},"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"},"secret_scanning_ai_detection":{"status":"enabled"},"secret_scanning_non_provider_patterns":{"status":"disabled"},"dependabot_security_updates":{"status":"enabled"}}')"
  pp_check_security_and_analysis "my-repo"
  grep -q "secret_scanning_non_provider_patterns" "$FINDINGS_LOG"
}

# ---------------------------------------------------------------------------
# GHAS-gated: secret_scanning_non_provider_patterns requires GitHub Advanced
# Security. When GHAS is unavailable on the plan, GitHub reports the setting as
# "disabled" (not absent) and silently ignores any PATCH to enable it, so the
# finding is non-actionable and must be suppressed.
# ---------------------------------------------------------------------------

@test "pp_check_security_and_analysis: non_provider_patterns disabled but advanced_security absent emits no finding (GHAS unavailable)" {
  GH_API_RESPONSE="$(make_repo_json '{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"},"secret_scanning_ai_detection":{"status":"enabled"},"secret_scanning_non_provider_patterns":{"status":"disabled"},"dependabot_security_updates":{"status":"enabled"}}')"
  pp_check_security_and_analysis "my-repo"
  if grep -q "secret_scanning_non_provider_patterns" "$FINDINGS_LOG" 2>/dev/null; then
    echo "unexpected finding for secret_scanning_non_provider_patterns when GHAS is unavailable" >&2
    false
  fi
}

@test "pp_check_security_and_analysis: non_provider_patterns disabled with advanced_security disabled emits no finding (GHAS unavailable)" {
  GH_API_RESPONSE="$(make_repo_json '{"advanced_security":{"status":"disabled"},"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"},"secret_scanning_ai_detection":{"status":"enabled"},"secret_scanning_non_provider_patterns":{"status":"disabled"},"dependabot_security_updates":{"status":"enabled"}}')"
  pp_check_security_and_analysis "my-repo"
  if grep -q "secret_scanning_non_provider_patterns" "$FINDINGS_LOG" 2>/dev/null; then
    echo "unexpected finding for secret_scanning_non_provider_patterns when GHAS is disabled" >&2
    false
  fi
}

# ---------------------------------------------------------------------------
# error-severity, null actual → always emits a finding (not plan-gated)
# ---------------------------------------------------------------------------

@test "pp_check_security_and_analysis: secret_scanning absent emits an error finding" {
  GH_API_RESPONSE="$(make_repo_json '{"secret_scanning_push_protection":{"status":"enabled"},"secret_scanning_ai_detection":{"status":"enabled"},"secret_scanning_non_provider_patterns":{"status":"enabled"},"dependabot_security_updates":{"status":"enabled"}}')"
  pp_check_security_and_analysis "my-repo"
  grep -q "secret_scanning" "$FINDINGS_LOG"
  grep -q "|error|" "$FINDINGS_LOG"
}

@test "pp_check_security_and_analysis: secret_scanning_push_protection absent emits an error finding" {
  GH_API_RESPONSE="$(make_repo_json '{"secret_scanning":{"status":"enabled"},"secret_scanning_ai_detection":{"status":"enabled"},"secret_scanning_non_provider_patterns":{"status":"enabled"},"dependabot_security_updates":{"status":"enabled"}}')"
  pp_check_security_and_analysis "my-repo"
  grep -q "secret_scanning_push_protection" "$FINDINGS_LOG"
  grep -q "|error|" "$FINDINGS_LOG"
}

# ---------------------------------------------------------------------------
# error-severity, disabled actual → always emits a finding
# ---------------------------------------------------------------------------

@test "pp_check_security_and_analysis: secret_scanning disabled emits an error finding" {
  GH_API_RESPONSE="$(make_repo_json '{"secret_scanning":{"status":"disabled"},"secret_scanning_push_protection":{"status":"enabled"},"secret_scanning_ai_detection":{"status":"enabled"},"secret_scanning_non_provider_patterns":{"status":"enabled"},"dependabot_security_updates":{"status":"enabled"}}')"
  pp_check_security_and_analysis "my-repo"
  grep -q "secret_scanning" "$FINDINGS_LOG"
  grep -q "|error|" "$FINDINGS_LOG"
}

# ---------------------------------------------------------------------------
# All plan-gated warning settings absent — no findings from those keys
# ---------------------------------------------------------------------------

@test "pp_check_security_and_analysis: no findings when only error settings are present and compliant" {
  # Only the two required (error-severity) settings are present and enabled.
  # All three warning-severity settings are absent (plan-gated).
  GH_API_RESPONSE="$(make_repo_json '{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}')"
  pp_check_security_and_analysis "my-repo"
  [ "$(finding_count)" -eq 0 ]
}
