#!/usr/bin/env bats
# Tests for check_ruleset_contents in scripts/compliance-audit.sh (issue #766).
#
# Before #766, check_rulesets only verified a ruleset EXISTED BY NAME; the live
# parameters could diverge arbitrarily from the codified source of truth
# (standards/rulesets/{pr-quality,code-quality}.json) and the audit still
# passed. check_ruleset_contents compares each live ruleset's codified
# parameters against those files and raises a finding per drifted parameter.
#
# Comparison semantics (grounded in standards/github-settings.md):
#   - pull_request scalars + allowed_merge_methods → exact match vs codified.
#   - required_status_checks → SUBSET: every codified context must be present;
#     repo-specific ADDITIONS (build-and-test, Go, coverage, …) are allowed by
#     the standard and are NOT drift; a MISSING codified context IS drift.
#   - Only codified keys are compared (API-only fields like id/source/
#     required_reviewers/dismissal_restriction are ignored → no false drift).
#   - Fail closed: an unfetchable/invalid ruleset is a finding, never a pass.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

# Codified parameter blocks, read straight from the source of truth so the
# fixtures below stay in lockstep with what the audit actually compares against.
PRQ_PARAMS="$(jq -c '[.rules[]|select(.type=="pull_request")|.parameters][0]' \
  "$REPO_ROOT/standards/rulesets/pr-quality.json")"
CQ_PARAMS="$(jq -c '[.rules[]|select(.type=="required_status_checks")|.parameters][0]' \
  "$REPO_ROOT/standards/rulesets/code-quality.json")"

setup() {
  TEST_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/compliance-audit.XXXXXX")"
  MOCK_BIN="$TEST_TMP/bin"
  mkdir -p "$MOCK_BIN"
  # No-op sleep so gh_api's retry backoff runs instantly.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/sleep"
  chmod +x "$MOCK_BIN/sleep"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# _run_contents <pr_quality_params_json> <code_quality_params_json>
# Installs a mock `gh` that serves a two-ruleset list plus per-id detail built
# from the supplied parameter blocks, sources the audit script, runs
# check_ruleset_contents on a fake repo, and prints findings.json.
# Passing the literal string "FETCHFAIL" for a detail body makes that ruleset's
# detail GET fail (to exercise the fail-closed path).
_run_contents() {
  local prq="$1" cq="$2"
  # pr-quality detail: a pull_request rule carrying $prq (unless FETCHFAIL).
  # code-quality detail: a required_status_checks rule carrying $cq.
  cat > "$MOCK_BIN/gh" <<MOCK
#!/usr/bin/env bash
# Reconstruct the request path from the args (last non-flag argument).
path=""
for a in "\$@"; do
  case "\$a" in --*|api) : ;; *) path="\$a" ;; esac
done
case "\$path" in
  */rulesets)
    echo '[{"id":101,"name":"pr-quality"},{"id":102,"name":"code-quality"}]'
    ;;
  */rulesets/101)
    prq='$prq'
    if [ "\$prq" = "FETCHFAIL" ]; then echo "gh: Server Error (HTTP 500)" >&2; exit 1; fi
    if [ "\$prq" = "NORULE" ]; then echo '{"name":"pr-quality","id":101,"rules":[{"type":"deletion","parameters":null}]}'; exit 0; fi
    echo "{\"name\":\"pr-quality\",\"id\":101,\"source\":\"petry-projects/demo-repo\",\"rules\":[{\"type\":\"pull_request\",\"parameters\":\$prq}]}"
    ;;
  */rulesets/102)
    cq='$cq'
    if [ "\$cq" = "FETCHFAIL" ]; then echo "gh: Server Error (HTTP 500)" >&2; exit 1; fi
    if [ "\$cq" = "NORULE" ]; then echo '{"name":"code-quality","id":102,"rules":[{"type":"deletion","parameters":null}]}'; exit 0; fi
    echo "{\"name\":\"code-quality\",\"id\":102,\"source\":\"petry-projects/demo-repo\",\"rules\":[{\"type\":\"required_status_checks\",\"parameters\":\$cq}]}"
    ;;
  *)
    echo '[]'
    ;;
esac
MOCK
  chmod +x "$MOCK_BIN/gh"
  PATH="$MOCK_BIN:$PATH" REPORT_DIR="$TEST_TMP" bash -c '
    set -uo pipefail
    echo "[]" > "$REPORT_DIR/findings.json"
    # shellcheck disable=SC1090
    source "'"$REPO_ROOT"'/scripts/compliance-audit.sh"
    rulesets_json='"'"'[{"id":101,"name":"pr-quality"},{"id":102,"name":"code-quality"}]'"'"'
    check_ruleset_contents "demo-repo" "$rulesets_json"
    cat "$REPORT_DIR/findings.json"
  '
}

# ---------------------------------------------------------------------------
# In-sync fleet → no drift finding (a clean repo must stay clean)
# ---------------------------------------------------------------------------
@test "in-sync pr-quality + code-quality → no drift finding" {
  run _run_contents "$PRQ_PARAMS" "$CQ_PARAMS"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ruleset-drift"* ]]
  [[ "$output" != *"ruleset-contents"* ]]
}

# ---------------------------------------------------------------------------
# pull_request scalar drift → a finding per parameter, naming expected/actual
# ---------------------------------------------------------------------------
@test "required_review_thread_resolution:false → finding naming the parameter" {
  drifted="$(echo "$PRQ_PARAMS" | jq -c '.required_review_thread_resolution=false')"
  run _run_contents "$drifted" "$CQ_PARAMS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ruleset-drift-pr-quality-required_review_thread_resolution"* ]]
  [[ "$output" == *"required_review_thread_resolution"* ]]
  [[ "$output" == *"error"* ]]
}

@test "lowered required_approving_review_count → finding" {
  drifted="$(echo "$PRQ_PARAMS" | jq -c '.required_approving_review_count=0')"
  run _run_contents "$drifted" "$CQ_PARAMS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ruleset-drift-pr-quality-required_approving_review_count"* ]]
}

@test "dropped require_code_owner_review → finding" {
  drifted="$(echo "$PRQ_PARAMS" | jq -c '.require_code_owner_review=false')"
  run _run_contents "$drifted" "$CQ_PARAMS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ruleset-drift-pr-quality-require_code_owner_review"* ]]
}

@test "disabled dismiss_stale_reviews_on_push → finding naming expected/actual" {
  drifted="$(echo "$PRQ_PARAMS" | jq -c '.dismiss_stale_reviews_on_push=false')"
  run _run_contents "$drifted" "$CQ_PARAMS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ruleset-drift-pr-quality-dismiss_stale_reviews_on_push"* ]]
  [[ "$output" == *"dismiss_stale_reviews_on_push"* ]]
  [[ "$output" == *"error"* ]]
  [[ "$output" == *'expected `true`'* ]]
  [[ "$output" == *'actual `false`'* ]]
}

# ---------------------------------------------------------------------------
# allowed_merge_methods widened beyond squash-only → drift
# ---------------------------------------------------------------------------
@test "widened allowed_merge_methods → finding" {
  drifted="$(echo "$PRQ_PARAMS" | jq -c '.allowed_merge_methods=["merge","rebase","squash"]')"
  run _run_contents "$drifted" "$CQ_PARAMS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ruleset-drift-pr-quality-allowed_merge_methods"* ]]
}

# ---------------------------------------------------------------------------
# code-quality required_status_checks: subset semantics
# ---------------------------------------------------------------------------
@test "code-quality missing a codified required check → finding" {
  # Drop the codified 'SonarCloud' context; the remaining set is a strict subset.
  drifted="$(echo "$CQ_PARAMS" | jq -c '.required_status_checks |= map(select(.context!="SonarCloud"))')"
  run _run_contents "$PRQ_PARAMS" "$drifted"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ruleset-drift-code-quality-required_status_checks"* ]]
  [[ "$output" == *"SonarCloud"* ]]
}

@test "code-quality with EXTRA repo-specific checks → NO finding (subset allows additions)" {
  # All codified contexts present PLUS repo-specific additions the standard allows.
  extended="$(echo "$CQ_PARAMS" | jq -c '.required_status_checks += [{"context":"build-and-test"},{"context":"coverage"}]')"
  run _run_contents "$PRQ_PARAMS" "$extended"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ruleset-drift"* ]]
}

# ---------------------------------------------------------------------------
# Fail closed: an unfetchable ruleset is a finding, never a silent pass
# ---------------------------------------------------------------------------
@test "code-quality detail fetch failure → finding (fail closed)" {
  run _run_contents "$PRQ_PARAMS" "FETCHFAIL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ruleset-contents-unfetchable-code-quality"* ]]
  [[ "$output" == *"error"* ]]
}

@test "pr-quality detail fetch failure → finding (fail closed)" {
  run _run_contents "FETCHFAIL" "$CQ_PARAMS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ruleset-contents-unfetchable-pr-quality"* ]]
}

# ---------------------------------------------------------------------------
# A ruleset that exists but has lost the codified rule type entirely is drift
# ---------------------------------------------------------------------------
@test "pr-quality present but missing its pull_request rule → finding" {
  run _run_contents "NORULE" "$CQ_PARAMS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ruleset-drift-pr-quality-missing-rule"* ]]
  [[ "$output" == *"error"* ]]
}
