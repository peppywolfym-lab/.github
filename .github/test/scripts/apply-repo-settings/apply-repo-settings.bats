#!/usr/bin/env bats
# Unit tests for scripts/apply-repo-settings.sh — the persona opt-out label family
# (petry-projects/.github#756).
#
# The <id>:hands-off labels are DERIVED from the persona manifests
# (personas/<id>/persona.yml in the PUBLIC .github-private repo), never hand-listed:
# adding a persona must require no edit to this script. These tests stub `gh` so the
# derivation, idempotent apply, dry-run, and graceful-degradation paths are exercised
# hermetically.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
APPLY="$SCRIPT_DIR/scripts/apply-repo-settings.sh"

setup() {
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"; export PATH="$STUB_BIN:$PATH"
  CALLS="$STUB_BIN/calls.log"; export CALLS
  MANIFEST_DIR="$(mktemp -d "$BATS_TEST_TMPDIR/manifest.XXXXXX")"; export MANIFEST_DIR
  export GH_TOKEN=stub-token
  # Default fixture: one persona (qa-lead) whose manifest declares the conventional
  # <id>:hands-off label. The listing also carries a non-dir entry that MUST be
  # ignored (validate-personas.py actually lives beside the persona dirs today).
  export PERSONA_DIRS_JSON='[{"type":"dir","name":"qa-lead"},{"type":"file","name":"validate-personas.py"}]'
  printf 'triggers:\n  opt_out_label: qa-lead:hands-off\n' > "$MANIFEST_DIR/qa-lead.yml"
  _stub_gh
  source "$APPLY"
}

teardown() {
  [ -n "${STUB_BIN:-}" ] && rm -rf "$STUB_BIN"
  [ -n "${MANIFEST_DIR:-}" ] && rm -rf "$MANIFEST_DIR"
  return 0
}

# gh stub:
#   - contents/personas/<id>/persona.yml → the fixture manifest for <id> (raw YAML)
#   - contents/personas                  → $PERSONA_DIRS_JSON (directory listing)
#   - label create ...                   → recorded to $CALLS (a write we assert on);
#                                          exits 1 for the label named in $FAIL_LABEL
#   - check-suites/preferences (GET)     → $CHECK_SUITE_GET_JSON (default {}, exit $CHECK_SUITE_GET_RC)
#   - check-suites/preferences (PATCH)   → recorded to $CALLS; emits $CHECK_SUITE_PATCH_STDERR
#                                          on stderr and exits $CHECK_SUITE_PATCH_RC (default 0)
#   - anything else                      → {}
# The check-suites env vars default to the no-op path, so tests that don't touch
# apply_check_suite_prefs behave exactly as before.
_stub_gh() {
  cat > "$STUB_BIN/gh" <<EOF
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"contents/personas/"*"persona.yml"*)
    id=\$(printf '%s' "\$args" | sed -n 's#.*contents/personas/\([^/?]*\)/persona.yml.*#\1#p')
    # A real `gh api` on an unreachable/absent manifest exits NON-zero (404).
    # The stub must too, or the fetch-failure path is untestable.
    if [ -f "$MANIFEST_DIR/\$id.yml" ]; then cat "$MANIFEST_DIR/\$id.yml"; exit 0; fi
    exit 1 ;;
  *"contents/personas"*)
    printf '%s' "\${PERSONA_DIRS_JSON:-[]}"; exit 0 ;;
  *"label create"*)
    printf '%s\n' "\$args" >> "$CALLS"
    # Simulate a failing \`gh label create\` for one specific label so AC6a can
    # assert per-label failure is recorded (and the remaining labels still apply).
    if [ -n "\${FAIL_LABEL:-}" ] && [[ "\$args" == *"label create \${FAIL_LABEL} "* ]]; then
      exit 1
    fi
    exit 0 ;;
  *"check-suites/preferences"*)
    # The script distinguishes the GET (read prefs) from the PATCH (write) by the
    # -X PATCH flag; mirror that so both legs of apply_check_suite_prefs are exercised.
    if [[ "\$args" == *PATCH* ]]; then
      printf 'PATCH %s\n' "\$args" >> "$CALLS"
      [ -n "\${CHECK_SUITE_PATCH_STDERR:-}" ] && printf '%s\n' "\${CHECK_SUITE_PATCH_STDERR}" >&2
      exit "\${CHECK_SUITE_PATCH_RC:-0}"
    fi
    printf '%s' "\${CHECK_SUITE_GET_JSON:-{}}"; exit "\${CHECK_SUITE_GET_RC:-0}" ;;
  *) printf '{}'; exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN/gh"
}

# JSON the check-suites/preferences GET returns to advertise a given auto-trigger
# setting for BOTH configured app_ids (1236702 Claude, 347564 CodeRabbit). "true"
# means auto-trigger is ON → apply_check_suite_prefs must PATCH it off.
# Pass a second argument to set a different value for the second app (mixed-state tests).
_check_suite_prefs_json() {
  local s1="$1" s2="${2:-$1}"
  printf '{"preferences":{"auto_trigger_checks":[{"app_id":1236702,"setting":%s},{"app_id":347564,"setting":%s}]}}' \
    "$s1" "$s2"
}

# The verbatim error a fine-grained PAT / GITHUB_TOKEN gets from the legacy
# check-suites API (captured from the TalkTerm canary run, issue #1042). This is the
# environmental failure apply_check_suite_prefs must absorb rather than fail on.
_CHECK_SUITE_403_ERR='gh: You must authenticate with a personal access token, or basic auth, or via a GitHub App in order to change check suite permissions. (HTTP 403)
{"message":"You must authenticate with a personal access token, or basic auth, or via a GitHub App in order to change check suite permissions.","documentation_url":"https://docs.github.com/rest/checks/suites#update-repository-preferences-for-check-suites","status":"403"}'
# Separate single-form fixtures so each detection branch is exercised in isolation.
_CHECK_SUITE_403_PHRASE_ONLY='gh: You must authenticate with a personal access token. (HTTP 403)'
_CHECK_SUITE_403_JSON_ONLY='{"message":"Forbidden","status":"403"}'

# Call functions loaded into BATS via setup()'s source "$APPLY".
_run_fn() { run "$@"; }

# ── derivation ────────────────────────────────────────────────────────────────
@test "derives <id>:hands-off from a persona manifest, with the family color" {
  _run_fn persona_opt_out_label_configs
  [ "$status" -eq 0 ]
  [[ "$output" == "qa-lead:hands-off|ededed|"* ]]
}

@test "one consistent color is used for the whole opt-out family" {
  export PERSONA_DIRS_JSON='[{"type":"dir","name":"qa-lead"},{"type":"dir","name":"scrum-master"}]'
  printf 'triggers:\n  opt_out_label: scrum-master:hands-off\n' > "$MANIFEST_DIR/scrum-master.yml"
  _run_fn persona_opt_out_label_configs
  [ "$status" -eq 0 ]
  # Every emitted config carries the same color in field 2.
  run bash -c "printf '%s\n' \"$output\" | awk -F'|' 'NF{print \$2}' | sort -u"
  [ "$output" = "ededed" ]
}

@test "honors the manifest's declared opt_out_label when it overrides the convention" {
  printf 'triggers:\n  opt_out_label: qa-lead:leave-me-be\n' > "$MANIFEST_DIR/qa-lead.yml"
  _run_fn persona_opt_out_label_configs
  [ "$status" -eq 0 ]
  [[ "$output" == "qa-lead:leave-me-be|"* ]]
}

@test "falls back to <id>:hands-off when the manifest omits opt_out_label" {
  printf 'triggers:\n  default_mode: advisory\n' > "$MANIFEST_DIR/qa-lead.yml"
  _run_fn persona_opt_out_label_configs
  [ "$status" -eq 0 ]
  [[ "$output" == "qa-lead:hands-off|"* ]]
}

@test "ignores non-directory entries in the personas listing" {
  _run_fn persona_opt_out_label_configs
  [ "$status" -eq 0 ]
  [[ "$output" != *"validate-personas"* ]]
  run bash -c "printf '%s\n' \"$output\" | grep -c ':hands-off'"
  [ "$output" = "1" ]
}

@test "adding a persona requires no script edit — a new dir yields a new label" {
  export PERSONA_DIRS_JSON='[{"type":"dir","name":"qa-lead"},{"type":"dir","name":"business-analyst"}]'
  printf 'triggers:\n  opt_out_label: business-analyst:hands-off\n' > "$MANIFEST_DIR/business-analyst.yml"
  _run_fn persona_opt_out_label_configs
  [ "$status" -eq 0 ]
  [[ "$output" == *"qa-lead:hands-off|"* ]]
  [[ "$output" == *"business-analyst:hands-off|"* ]]
}

# ── failure is reported, not swallowed (#755) ─────────────────────────────────
# The static label set still lands on a hiccup — that resilience is deliberate —
# but the run must NEVER report success while the mandated <id>:hands-off escape
# hatch is absent. "Applied ✅" with no opt-out label is worse than a red run:
# nobody learns until they tell a persona to back off and it ignores them.
@test "unavailable manifest listing returns NON-ZERO (does not fail open)" {
  export PERSONA_DIRS_JSON='not-json'  # jq parse failure on the listing
  _run_fn persona_opt_out_label_configs
  [ "$status" -ne 0 ]
  # Still emits no label to stdout; only a WARN (which run merges from stderr).
  [[ "$output" != *":hands-off"* ]]
  [[ "$output" != *"|ededed|"* ]]
}

@test "an unreadable manifest returns NON-ZERO even though it guesses the label" {
  # <id>:hands-off is only a CONVENTION (§4 rule 4); the schema lets a persona
  # declare any opt_out_label. If the manifest cannot be read we may create a label
  # nobody uses while the real one stays absent — so emit the guess, but say so.
  rm -f "$MANIFEST_DIR/qa-lead.yml"
  _run_fn persona_opt_out_label_configs
  [ "$status" -ne 0 ]
  [[ "$output" == *"qa-lead:hands-off"* ]]   # the best guess is still emitted
}

# ── integration with apply_labels ─────────────────────────────────────────────
@test "apply_labels applies the 7 static labels AND the derived opt-out label" {
  _run_fn apply_labels acme
  [ "$status" -eq 0 ]
  # 7 canonical + 1 derived = 8 label-create writes.
  [ "$(grep -c 'label create' "$CALLS")" -eq 8 ]
  grep -q 'label create security' "$CALLS"
  grep -q 'qa-lead:hands-off' "$CALLS"
}

@test "derived labels are created idempotently via --force" {
  _run_fn apply_labels acme
  [ "$status" -eq 0 ]
  run grep 'qa-lead:hands-off' "$CALLS"
  [[ "$output" == *"--force"* ]]
}

@test "apply_labels --dry-run reports the derived label and writes nothing" {
  export DRY_RUN=true
  _run_fn apply_labels acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"qa-lead:hands-off"* ]]
  [ ! -f "$CALLS" ]
}

@test "apply_labels still applies the static 7 when persona derivation is unavailable" {
  # The resilience half: a persona hiccup must not block unrelated label work.
  export PERSONA_DIRS_JSON='not-json'
  _run_fn apply_labels acme
  [ "$status" -eq 0 ]
  [ "$(grep -c 'label create' "$CALLS")" -eq 7 ]
  ! grep -q 'hands-off' "$CALLS"
}

# _apply_labels <repo> — run apply_labels in THIS shell and record its status in
# $APPLY_RC. Must NOT echo the status: $( ) is a subshell, and the whole point is
# to observe the flag mutations apply_labels makes in the CURRENT shell.
# `|| true` would mask an unexpected non-zero and let a flag assertion pass on a
# broken function, so the status is captured explicitly with errexit off.
_apply_labels() {
  set +e; apply_labels "$1" >/dev/null 2>&1; APPLY_RC=$?; set -e
}

@test "apply_labels records the failure so the run cannot claim success" {
  # The honesty half: the static labels landed, but _PERSONA_OPT_OUT_SYNC_FAILED is
  # set, and main() turns that into a non-zero exit.
  export PERSONA_DIRS_JSON='not-json'
  _PERSONA_OPT_OUT_CONFIGS_CACHED=false
  _PERSONA_OPT_OUT_SYNC_FAILED=false
  _apply_labels acme
  [ "$APPLY_RC" -eq 0 ]
  [ "$_PERSONA_OPT_OUT_SYNC_FAILED" = true ]
}

@test "a healthy derivation leaves the failure flag unset" {
  _PERSONA_OPT_OUT_CONFIGS_CACHED=false
  _PERSONA_OPT_OUT_SYNC_FAILED=false
  _apply_labels acme
  [ "$APPLY_RC" -eq 0 ]
  [ "$_PERSONA_OPT_OUT_SYNC_FAILED" = false ]
}

@test "a failed derivation is NOT cached — later repos retry and recover" {
  # --all sweeps share the cache. Caching a failure would let one transient blip on
  # the first repo deny opt-out labels to every later repo even after the API
  # recovers, turning a hiccup into a fleet-wide gap.
  _PERSONA_OPT_OUT_CONFIGS_CACHED=false
  _PERSONA_OPT_OUT_SYNC_FAILED=false
  export PERSONA_DIRS_JSON='not-json'          # repo 1: derivation fails
  _apply_labels repo-one
  [ "$APPLY_RC" -eq 0 ]
  [ "$_PERSONA_OPT_OUT_CONFIGS_CACHED" = false ]   # must NOT have cached the failure
  export PERSONA_DIRS_JSON='[{"type":"dir","name":"qa-lead"}]'  # repo 2: API recovers
  _apply_labels repo-two
  [ "$APPLY_RC" -eq 0 ]
  grep -q 'qa-lead:hands-off' "$CALLS"           # repo 2 DID get the label
  [ "$_PERSONA_OPT_OUT_SYNC_FAILED" = true ]     # but the run still cannot claim success
}

@test "a successful derivation IS cached — no refetch per repo" {
  _PERSONA_OPT_OUT_CONFIGS_CACHED=false
  _apply_labels repo-one
  [ "$APPLY_RC" -eq 0 ]
  [ "$_PERSONA_OPT_OUT_CONFIGS_CACHED" = true ]
}

@test "an opt_out_label containing spaces is not truncated at the first word" {
  # opt_out_label is free-form in the schema and GitHub labels may contain spaces.
  # Truncating would provision "needs" and leave the real hatch absent.
  printf 'triggers:\n  opt_out_label: "needs human review"\n' > "$MANIFEST_DIR/qa-lead.yml"
  _run_fn persona_opt_out_label_configs
  [ "$status" -eq 0 ]
  [[ "$output" == "needs human review|"* ]]
}

@test "a trailing YAML comment is stripped from opt_out_label" {
  printf 'triggers:\n  opt_out_label: qa-lead:hands-off  # the escape hatch\n' > "$MANIFEST_DIR/qa-lead.yml"
  _run_fn persona_opt_out_label_configs
  [ "$status" -eq 0 ]
  [[ "$output" == "qa-lead:hands-off|"* ]]
}

# ── apply_check_suite_prefs — the check-suites/preferences 403 degradation ──────
# The legacy check-suites/preferences endpoint accepts ONLY a classic PAT (or a
# GitHub App); a fine-grained PAT or GITHUB_TOKEN gets HTTP 403. When the configured
# token lacks that capability the whole settings run was reporting apply-repo-settings
# as 100%-failed fleet-wide even though every other setting applied — the exact
# environmental failure the canary caught on TalkTerm (issue #1042). These lock in
# that a 403 here is absorbed (the run continues) while a genuine error still fails.

@test "a 403 on the check-suites PATCH is absorbed — skips loudly, rc 0 (issue #1042)" {
  # Auto-trigger is ON, so the function proceeds to the PATCH, which 403s.
  export CHECK_SUITE_GET_JSON="$(_check_suite_prefs_json true)"
  export CHECK_SUITE_PATCH_RC=1
  export CHECK_SUITE_PATCH_STDERR="$_CHECK_SUITE_403_ERR"
  _run_fn apply_check_suite_prefs acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping check-suite prefs"* ]]
  # Names the tracking issue so the skip is traceable, not silent.
  [[ "$output" == *".github-private#1209"* ]]
  # It really did attempt the PATCH (the 403 came from the API, not a short-circuit).
  grep -q 'PATCH' "$CALLS"
}

@test "a non-403 error on the check-suites PATCH still fails hard, rc 1" {
  # A real fault (e.g. 5xx) must NOT be swallowed — only the 403 capability gap is.
  export CHECK_SUITE_GET_JSON="$(_check_suite_prefs_json true)"
  export CHECK_SUITE_PATCH_RC=1
  export CHECK_SUITE_PATCH_STDERR='gh: Something is broken on our end (HTTP 502)
{"message":"Server Error","status":"502"}'
  _run_fn apply_check_suite_prefs acme
  [ "$status" -eq 1 ]
  [[ "$output" == *"PATCH failed"* ]]
}

@test "403 is absorbed when error is the HTTP-phrase form only (no JSON body)" {
  # Exercises the 'http 403' detection branch in isolation.
  export CHECK_SUITE_GET_JSON="$(_check_suite_prefs_json true)"
  export CHECK_SUITE_PATCH_RC=1
  export CHECK_SUITE_PATCH_STDERR="$_CHECK_SUITE_403_PHRASE_ONLY"
  _run_fn apply_check_suite_prefs acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping check-suite prefs"* ]]
}

@test "403 is absorbed when error is the JSON-status form only (no HTTP phrase)" {
  # Exercises the '"status":"403"' detection branch in isolation.
  export CHECK_SUITE_GET_JSON="$(_check_suite_prefs_json true)"
  export CHECK_SUITE_PATCH_RC=1
  export CHECK_SUITE_PATCH_STDERR="$_CHECK_SUITE_403_JSON_ONLY"
  _run_fn apply_check_suite_prefs acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping check-suite prefs"* ]]
}

@test "apply_check_suite_prefs PATCHes when one app is enabled and one is already disabled" {
  # Mixed state: only app 1236702 (Claude) has auto-trigger ON — function must PATCH.
  export CHECK_SUITE_GET_JSON="$(_check_suite_prefs_json true false)"
  _run_fn apply_check_suite_prefs acme
  [ "$status" -eq 0 ]
  grep -q 'PATCH' "$CALLS"
}

@test "apply_check_suite_prefs is a no-op when auto-trigger is already disabled" {
  # Both configured apps already report setting:false → nothing to PATCH.
  export CHECK_SUITE_GET_JSON="$(_check_suite_prefs_json false)"
  _run_fn apply_check_suite_prefs acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"already correct"* ]]
  touch "$CALLS"
  run grep -q 'PATCH' "$CALLS"
  [ "$status" -eq 1 ]
}

@test "apply_check_suite_prefs treats a never-run app (missing) as no orphaned suite" {
  # Default GET returns {} (no auto_trigger_checks) → both apps "missing" → no PATCH.
  _run_fn apply_check_suite_prefs acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"already correct"* ]]
  touch "$CALLS"
  run grep -q 'PATCH' "$CALLS"
  [ "$status" -eq 1 ]
}

@test "apply_check_suite_prefs --dry-run issues no PATCH" {
  export DRY_RUN=true
  export CHECK_SUITE_GET_JSON="$(_check_suite_prefs_json true)"
  _run_fn apply_check_suite_prefs acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping check-suite prefs PATCH"* ]]
  touch "$CALLS"
  run grep -q 'PATCH' "$CALLS"
  [ "$status" -eq 1 ]
}

# ── apply_repo — a cosmetic step must not abort the security-critical one ────────
# The regression this issue exists for (#1038): the driver ran each step bare under
# `set -e`, so a single failure (originally the check-suites 403) aborted the whole
# script and every later step — including, at the workflow layer, the load-bearing
# ruleset self-heal — never ran. apply_repo must run every apply_* step
# INDEPENDENTLY: a failure is recorded (by name) but never prevents a later step.

# Stub every per-repo apply_* step to append its name to $ORDER when invoked, so a
# test can assert exactly which ran and in what order. Pass a step name as $1 to make
# that one step FAIL (return 1) while still recording that it ran.
_stub_apply_steps() {
  local fail="${1:-}"
  ORDER="$BATS_TEST_TMPDIR/apply-order.log"; export ORDER; : > "$ORDER"
  local step
  for step in apply_settings apply_labels pp_apply_security_and_analysis \
              apply_codeql_default_setup apply_check_suite_prefs; do
    eval "$step() { echo '$step' >> \"\$ORDER\"; [ '$step' = '$fail' ] && return 1; return 0; }"
  done
}

@test "apply_repo runs every step even when an EARLY step fails (issue #1038, AC1)" {
  _stub_apply_steps pp_apply_security_and_analysis   # the security step fails
  FAILED_STEPS=()
  apply_repo acme '{}'
  # Every step ran, in order — the failure did not abort the sequence.
  run cat "$ORDER"
  [ "${lines[0]}" = "apply_settings" ]
  [ "${lines[1]}" = "apply_labels" ]
  [ "${lines[2]}" = "pp_apply_security_and_analysis" ]
  [ "${lines[3]}" = "apply_codeql_default_setup" ]
  [ "${lines[4]}" = "apply_check_suite_prefs" ]
  # The later cosmetic step (check-suite prefs) ran despite the earlier failure.
  grep -qx 'apply_check_suite_prefs' "$ORDER"
}

@test "apply_repo records the failed step BY NAME (issue #1038, AC1)" {
  _stub_apply_steps pp_apply_security_and_analysis
  FAILED_STEPS=()
  apply_repo acme '{}'
  [ "${#FAILED_STEPS[@]}" -eq 1 ]
  printf '%s\n' "${FAILED_STEPS[@]}" | grep -qx 'security_and_analysis'
}

@test "a failing check-suite step is recorded but apply_repo still RETURNS (does not abort — issue #1038, AC4)" {
  # The literal AC4 mechanism: a failing apply_check_suite_prefs (the check-suites 403)
  # must not abort the driver. It is the last step here, so the guarantee that matters
  # is that apply_repo returns SUCCESS despite it — that non-abort is exactly what lets
  # the workflow reach the next step (apply-rulesets.sh; see reusable-contract.bats).
  _stub_apply_steps apply_check_suite_prefs           # the cosmetic step fails
  FAILED_STEPS=()
  # Call directly (not via `run`, whose subshell would hide the FAILED_STEPS mutation)
  # and capture the rc with errexit off, mirroring the _apply_labels helper.
  set +e; apply_repo acme '{}'; local rc=$?; set -e
  [ "$rc" -eq 0 ]                                      # driver did NOT propagate the abort
  printf '%s\n' "${FAILED_STEPS[@]}" | grep -qx 'check_suite_prefs'
}

@test "apply_repo leaves FAILED_STEPS empty when every step succeeds (issue #1038, AC1)" {
  _stub_apply_steps                                   # no step fails
  FAILED_STEPS=()
  apply_repo acme '{}'
  [ "${#FAILED_STEPS[@]}" -eq 0 ]
}

@test "apply_settings returns non-zero when its repo PATCH fails (issue #1038, AC1)" {
  # Once the driver records failures via `step || FAILED_STEPS+=(...)`, set -e is
  # suppressed inside apply_settings — so a genuine PATCH failure must be surfaced by
  # an explicit non-zero return, not left to errexit. Otherwise the failure is
  # swallowed and the run wrongly reports success.
  gh() { [[ "$*" == *PATCH*"repos/$ORG/acme"* ]] && return 1; printf '{}'; }
  # repo_json is compliant except has_issues=false, so exactly one PATCH is attempted.
  run apply_settings acme \
    '{"allow_auto_merge":true,"delete_branch_on_merge":true,"allow_squash_merge":true,"allow_merge_commit":true,"allow_rebase_merge":true,"has_discussions":true,"has_issues":false,"squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"COMMIT_MESSAGES"}'
  [ "$status" -eq 1 ]
}

# ── AC6: three more steps must be able to REPORT failure ────────────────────────
# apply_repo guards every step with `step || FAILED_STEPS+=(...)`. A step that
# returns 0 on failure is therefore invisible — FAILED_STEPS stays empty, main()
# exits 0, and the workflow reports success having applied nothing. These lock in
# that apply_labels, pp_apply_security_and_analysis and apply_codeql_default_setup
# each surface a genuine API failure with a non-zero return, and that the return
# propagates into FAILED_STEPS by name.

# _run_apply_repo <fail-step-name> — run the REAL target step under apply_repo while
# stubbing the OTHER four to succeed, then capture rc with errexit off. FAILED_STEPS
# is observable in the current shell afterward (apply_repo is NOT run via `run`,
# whose subshell would hide the mutation).
_only_real_step() {
  local keep="$1" step
  for step in apply_settings apply_labels pp_apply_security_and_analysis \
              apply_codeql_default_setup apply_check_suite_prefs; do
    [ "$step" = "$keep" ] && continue
    eval "$step() { return 0; }"
  done
}

# ── AC6a — apply_labels ─────────────────────────────────────────────────────────
@test "apply_labels returns non-zero when a label create fails, still applying the rest (AC6a)" {
  export FAIL_LABEL=bug   # the 'bug' label create exits 1; every other label succeeds
  run apply_labels acme
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to apply label 'bug'"* ]]
  # One failure does not abort the loop — labels before AND after 'bug' still applied.
  grep -q 'label create security' "$CALLS"
  grep -q 'label create documentation' "$CALLS"
  grep -q 'qa-lead:hands-off' "$CALLS"
}

@test "a failing apply_labels propagates its name into FAILED_STEPS (AC6a/AC6d)" {
  export FAIL_LABEL=bug
  _only_real_step apply_labels
  FAILED_STEPS=()
  set +e; apply_repo acme '{}'; local rc=$?; set -e
  [ "$rc" -eq 0 ]   # the driver records but does not abort
  printf '%s\n' "${FAILED_STEPS[@]}" | grep -qx 'labels'
}

# ── AC6b — pp_apply_security_and_analysis ───────────────────────────────────────
@test "pp_apply_security_and_analysis returns non-zero when a CORE setting stays non-compliant post-PATCH (AC6b)" {
  # The PATCH 'succeeds' (HTTP 200) but the core secret_scanning setting is still
  # disabled on re-fetch — a silent no-op (wrong scope / plan). That is a real
  # failure the run must not paper over.
  gh() {
    [[ "$*" == *"-X PATCH"* ]] && return 0
    if [[ "$*" == *"repos/$ORG/acme"* ]]; then
      printf '{"secret_scanning":{"status":"disabled"},"secret_scanning_push_protection":{"status":"disabled"}}'
      return 0
    fi
    printf '{}'
  }
  run pp_apply_security_and_analysis acme
  [ "$status" -eq 1 ]
}

@test "pp_apply_security_and_analysis returns 0 when only PLAN-GATED keys remain unset post-PATCH (AC6b)" {
  # Core keys land; the GHAS/Copilot-only keys stay null because the plan does not
  # support them — a legitimate skip, not a failure.
  local SEEN="$BATS_TEST_TMPDIR/sa-seen"
  gh() {
    [[ "$*" == *"-X PATCH"* ]] && return 0
    if [[ "$*" == *"repos/$ORG/acme"* ]]; then
      if [ -f "$SEEN" ]; then
        # post-PATCH re-fetch: core enabled, plan-gated keys still absent (null)
        printf '{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}'
      else
        : > "$SEEN"   # pre-PATCH: everything non-compliant so a PATCH is attempted
        printf '{"secret_scanning":{"status":"disabled"},"secret_scanning_push_protection":{"status":"disabled"}}'
      fi
      return 0
    fi
    printf '{}'
  }
  run pp_apply_security_and_analysis acme
  [ "$status" -eq 0 ]
}

@test "pp_apply_security_and_analysis returns 1 when a PLAN-GATED key is disabled post-PATCH (AC6b)" {
  # A plan-gated key that is "disabled" (not null) is a failure — the key exists
  # on this plan but was not enabled (a genuine API/permission issue).
  gh() {
    [[ "$*" == *"-X PATCH"* ]] && return 0
    if [[ "$*" == *"repos/$ORG/acme"* ]]; then
      # Core keys enabled, but a plan-gated key is "disabled" not "null"
      printf '{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"},"secret_scanning_ai_detection":{"status":"disabled"}}'
      return 0
    fi
    printf '{}'
  }
  run pp_apply_security_and_analysis acme
  [ "$status" -eq 1 ]
  [[ "$output" == *"secret_scanning_ai_detection still disabled after PATCH"* ]]
}

@test "pp_apply_security_and_analysis skips GHAS-gated keys when GHAS is not enabled post-PATCH (AC6b)" {
  # secret_scanning_non_provider_patterns is gated on GitHub Advanced Security.
  # When GHAS is unavailable (status not "enabled"), the key may be "disabled"
  # (present but disabled), but that's a legitimate skip, not a failure.
  gh() {
    [[ "$*" == *"-X PATCH"* ]] && return 0
    if [[ "$*" == *"repos/$ORG/acme"* ]]; then
      # Core keys enabled, GHAS disabled, GHAS-gated key also disabled
      printf '{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"},"advanced_security":{"status":"not_enabled"},"secret_scanning_non_provider_patterns":{"status":"disabled"}}'
      return 0
    fi
    printf '{}'
  }
  run pp_apply_security_and_analysis acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"secret_scanning_non_provider_patterns still disabled"* ]]
}

@test "a failing pp_apply_security_and_analysis propagates its name into FAILED_STEPS (AC6b/AC6d)" {
  _only_real_step pp_apply_security_and_analysis
  gh() {
    [[ "$*" == *"-X PATCH"* ]] && return 0
    if [[ "$*" == *"repos/$ORG/acme"* ]]; then
      printf '{"secret_scanning":{"status":"disabled"},"secret_scanning_push_protection":{"status":"disabled"}}'
      return 0
    fi
    printf '{}'
  }
  FAILED_STEPS=()
  set +e; apply_repo acme '{}'; local rc=$?; set -e
  [ "$rc" -eq 0 ]
  printf '%s\n' "${FAILED_STEPS[@]}" | grep -qx 'security_and_analysis'
}

# ── AC6c — apply_codeql_default_setup ───────────────────────────────────────────
@test "apply_codeql_default_setup returns non-zero on a genuine API error (AC6c)" {
  # A real permission gap ("Resource not accessible…") is NOT a benign not-supported
  # response — it must surface, not be swallowed as success.
  gh() {
    if [[ "$*" == *"-X PATCH"* ]]; then
      printf 'gh: Resource not accessible by personal access token (HTTP 403)\n'
      printf '{"message":"Resource not accessible by personal access token","status":"403"}\n'
      return 1
    fi
    printf 'not-configured\n'   # current-state GET → not configured, so we PATCH
  }
  run apply_codeql_default_setup acme
  [ "$status" -eq 1 ]
}

@test "apply_codeql_default_setup returns 0 on a benign not-supported response (AC6c)" {
  # GHAS unavailable for the repo — GitHub rejects the PATCH but the repo genuinely
  # cannot support CodeQL default setup. A legitimate skip, not a failure.
  gh() {
    if [[ "$*" == *"-X PATCH"* ]]; then
      printf 'gh: Advanced Security must be enabled for this repository to use code scanning. (HTTP 403)\n'
      return 1
    fi
    printf 'not-configured\n'
  }
  run apply_codeql_default_setup acme
  [ "$status" -eq 0 ]
}

@test "apply_codeql_default_setup is a no-op (rc 0) when already configured (AC6c, preserved)" {
  gh() { printf 'configured\n'; }
  run apply_codeql_default_setup acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"already configured"* ]]
}

@test "a failing apply_codeql_default_setup propagates its name into FAILED_STEPS (AC6c/AC6d)" {
  _only_real_step apply_codeql_default_setup
  gh() {
    if [[ "$*" == *"-X PATCH"* ]]; then
      printf 'gh: Resource not accessible by personal access token (HTTP 403)\n'
      return 1
    fi
    printf 'not-configured\n'
  }
  FAILED_STEPS=()
  set +e; apply_repo acme '{}'; local rc=$?; set -e
  [ "$rc" -eq 0 ]
  printf '%s\n' "${FAILED_STEPS[@]}" | grep -qx 'codeql_default_setup'
}
