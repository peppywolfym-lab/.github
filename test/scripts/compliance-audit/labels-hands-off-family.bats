#!/usr/bin/env bats
# Tests for check_labels()'s coverage of the derived <id>:hands-off persona
# opt-out label family in scripts/compliance-audit.sh (issue #1139).
#
# Before this, check_labels iterated only the seven fixed labels; the derived
# family (one <id>:hands-off per persona, derived from the persona manifests
# exactly as apply-repo-settings.sh does) was never consulted, so a repo missing
# a persona opt-out label was never reported. These tests pin:
#
#   fixed    — the seven fixed labels are still checked (regression guard).
#   derived  — a repo missing one persona label yields a
#              missing-label-<id>:hands-off finding.
#   closed   — an unreadable manifest listing fails CLOSED: an error finding, not
#              a silent "no persona labels required" pass (#755 / AC#3).
#   clean    — a repo carrying every fixed AND derived label produces no finding.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

setup() {
  TEST_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/clf.XXXXXX")"
  MOCK_BIN="$TEST_TMP/bin"
  mkdir -p "$MOCK_BIN"

  # The existing labels the mocked labels API reports for the repo under test.
  # Newline-separated, one label name per line.
  EXISTING_LABELS_FILE="$TEST_TMP/existing-labels.txt"
  : > "$EXISTING_LABELS_FILE"
  # The persona directory listing JSON the manifest API returns.
  PERSONA_DIRS_FILE="$TEST_TMP/persona-dirs.json"
  printf '[{"type":"dir","name":"qa-lead"}]' > "$PERSONA_DIRS_FILE"
  # Per-persona manifest fixtures (personas/<id>/persona.yml raw YAML).
  MANIFEST_DIR="$TEST_TMP/manifests"
  mkdir -p "$MANIFEST_DIR"
  printf 'triggers:\n  opt_out_label: qa-lead:hands-off\n' > "$MANIFEST_DIR/qa-lead.yml"

  # gh mock:
  #   api .../<repo>/labels                    -> $EXISTING_LABELS_FILE contents
  #   api .../contents/personas?ref=...        -> $PERSONA_DIRS_FILE contents
  #   api .../contents/personas/<id>/persona.yml -> the fixture (exit 1 if absent)
  #   label create ...                         -> recorded, exit 0
  #   anything else                            -> {}
  cat > "$MOCK_BIN/gh" << 'GH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"/labels"*)
    cat "$EXISTING_LABELS_FILE" ;;
  *"contents/personas/"*"persona.yml"*)
    id=$(printf '%s' "$args" | sed -n 's#.*contents/personas/\([^/?]*\)/persona.yml.*#\1#p')
    if [ -f "$MANIFEST_DIR/$id.yml" ]; then cat "$MANIFEST_DIR/$id.yml"; exit 0; fi
    exit 1 ;;
  *"contents/personas"*)
    cat "$PERSONA_DIRS_FILE" ;;
  *"label create"*)
    printf '%s\n' "$args" >> "$TEST_TMP/label-creates.log" ;;
  *) printf '{}' ;;
esac
exit 0
GH
  chmod +x "$MOCK_BIN/gh"
}

teardown() { rm -rf "$TEST_TMP"; }

# _check_labels <repo> — source the audit (read-only default) and run check_labels
# once against the mocked gh, then leave findings.json in $TEST_TMP for asserts.
_check_labels() {
  EXISTING_LABELS_FILE="$EXISTING_LABELS_FILE" PERSONA_DIRS_FILE="$PERSONA_DIRS_FILE" \
  MANIFEST_DIR="$MANIFEST_DIR" TEST_TMP="$TEST_TMP" \
  PATH="$MOCK_BIN:$PATH" REPORT_DIR="$TEST_TMP" bash -c '
    set -uo pipefail
    export EXISTING_LABELS_FILE PERSONA_DIRS_FILE MANIFEST_DIR TEST_TMP
    echo "[]" > "'"$TEST_TMP"'/findings.json"
    # shellcheck disable=SC1090
    source "'"$REPO_ROOT"'/scripts/compliance-audit.sh"
    check_labels "$1"
  ' _ "$1" 2>/dev/null
}

# _findings — the finding "check" ids emitted by the last _check_labels run.
_finding_checks() { jq -r '.[].check' "$TEST_TMP/findings.json"; }

_seed_fixed_labels() {
  printf '%s\n' security dependencies scorecard bug enhancement documentation in-progress \
    > "$EXISTING_LABELS_FILE"
}

@test "fixed set is still checked — a missing fixed label yields a finding (regression)" {
  # All fixed labels present EXCEPT 'bug'; plus the derived label so the family is clean.
  printf '%s\n' security dependencies scorecard enhancement documentation in-progress qa-lead:hands-off \
    > "$EXISTING_LABELS_FILE"
  _check_labels demo
  run _finding_checks
  [[ "$output" == *"missing-label-bug"* ]]
}

@test "derived family: a repo missing one persona opt-out label produces a finding" {
  _seed_fixed_labels   # fixed set complete, but qa-lead:hands-off absent
  _check_labels demo
  run _finding_checks
  [[ "$output" == *"missing-label-qa-lead:hands-off"* ]]
}

@test "derived family: the finding is derived from the manifest's declared opt_out_label" {
  _seed_fixed_labels
  printf 'triggers:\n  opt_out_label: qa-lead:leave-me-be\n' > "$MANIFEST_DIR/qa-lead.yml"
  _check_labels demo
  run _finding_checks
  [[ "$output" == *"missing-label-qa-lead:leave-me-be"* ]]
  [[ "$output" != *"missing-label-qa-lead:hands-off"* ]]
}

@test "adding a persona requires no script edit — a new dir yields a new finding" {
  _seed_fixed_labels
  printf '[{"type":"dir","name":"qa-lead"},{"type":"dir","name":"business-analyst"}]' > "$PERSONA_DIRS_FILE"
  printf 'triggers:\n  opt_out_label: business-analyst:hands-off\n' > "$MANIFEST_DIR/business-analyst.yml"
  _check_labels demo
  run _finding_checks
  [[ "$output" == *"missing-label-business-analyst:hands-off"* ]]
  [[ "$output" == *"missing-label-qa-lead:hands-off"* ]]
}

@test "fail closed: an unreadable manifest listing yields an error finding, not a silent pass" {
  _seed_fixed_labels
  printf 'not-json' > "$PERSONA_DIRS_FILE"   # jq parse failure on the listing
  _check_labels demo
  run _finding_checks
  # The derivation failure is reported as its own finding …
  [[ "$output" == *"persona-opt-out-derivation-failed"* ]]
  # … and the derivation failure is recorded at error severity.
  run jq -r '.[] | select(.check=="persona-opt-out-derivation-failed") | .severity' "$TEST_TMP/findings.json"
  [ "$output" = "error" ]
}

@test "fail closed: an unreadable listing does NOT mask the missing family as absent" {
  # With no persona labels present and the listing unreadable, the run must not
  # report "everything fine" — the derivation-failed finding must be present.
  _seed_fixed_labels
  printf 'not-json' > "$PERSONA_DIRS_FILE"
  _check_labels demo
  run bash -c 'jq "length" "'"$TEST_TMP"'/findings.json"'
  [ "$output" -ge 1 ]
}

@test "clean: a repo with every fixed AND derived label produces no finding" {
  printf '%s\n' security dependencies scorecard bug enhancement documentation in-progress qa-lead:hands-off \
    > "$EXISTING_LABELS_FILE"
  _check_labels demo
  run bash -c 'jq "length" "'"$TEST_TMP"'/findings.json"'
  [ "$output" -eq 0 ]
}
