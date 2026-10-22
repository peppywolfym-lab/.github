#!/usr/bin/env bats
# Tests that scripts/compliance-remediate.sh can create a missing derived
# <id>:hands-off persona opt-out label (issue #1139, AC#4).
#
# Before this, the remediator held its own hardcoded LABEL_COLORS/LABEL_DESCS
# table of the seven fixed labels only, so a `missing-label-<id>:hands-off`
# finding resolved to the fallback colour and an empty description — it could not
# reproduce the grey (#ededed) persona family. Now it resolves colour+description
# from the shared std_label_spec(), which consults the fixed set AND the derived
# family. The read-only/dry-run default (#1036 AC#4) still stands.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

setup() {
  TEST_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/cld.XXXXXX")"
  MOCK_BIN="$TEST_TMP/bin"
  mkdir -p "$MOCK_BIN"
  MANIFEST_DIR="$TEST_TMP/manifests"; mkdir -p "$MANIFEST_DIR"
  PERSONA_DIRS_FILE="$TEST_TMP/persona-dirs.json"
  printf '[{"type":"dir","name":"dev-lead"}]' > "$PERSONA_DIRS_FILE"
  printf 'triggers:\n  opt_out_label: dev-lead:hands-off\n' > "$MANIFEST_DIR/dev-lead.yml"

  # gh mock:
  #   api .../contents/personas?ref=...          -> $PERSONA_DIRS_FILE
  #   api .../contents/personas/<id>/persona.yml -> fixture (exit 1 if absent)
  #   label create ...                           -> recorded to label-creates.log
  #   anything else                              -> {}
  cat > "$MOCK_BIN/gh" << 'GH'
#!/usr/bin/env bash
args="$*"
case "$args" in
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

_write_finding() {
  local repo="$1" category="$2" check="$3"
  jq -n --arg repo "$repo" --arg category "$category" --arg check "$check" \
    '[{repo:$repo, category:$category, check:$check, severity:"warning", detail:"test", standard_ref:"x"}]' \
    > "$TEST_TMP/findings.json"
  printf '%s' "$TEST_TMP/findings.json"
}

@test "remediator creates a missing dev-lead:hands-off label with the grey family colour" {
  local findings; findings="$(_write_finding demo labels missing-label-dev-lead:hands-off)"
  MANIFEST_DIR="$MANIFEST_DIR" PERSONA_DIRS_FILE="$PERSONA_DIRS_FILE" TEST_TMP="$TEST_TMP" \
    GH_TOKEN=fake FINDINGS_FILE="$findings" REPORT_DIR="$TEST_TMP/report" DRY_RUN=false \
    PATH="$MOCK_BIN:$PATH" run bash "$REPO_ROOT/scripts/compliance-remediate.sh"
  [ "$status" -eq 0 ]
  run cat "$TEST_TMP/label-creates.log"
  [[ "$output" == *"label create dev-lead:hands-off"* ]]
  [[ "$output" == *"ededed"* ]]
}

@test "dry-run resolves the derived label but mutates nothing" {
  local findings; findings="$(_write_finding demo labels missing-label-dev-lead:hands-off)"
  MANIFEST_DIR="$MANIFEST_DIR" PERSONA_DIRS_FILE="$PERSONA_DIRS_FILE" TEST_TMP="$TEST_TMP" \
    GH_TOKEN=fake FINDINGS_FILE="$findings" REPORT_DIR="$TEST_TMP/report" DRY_RUN=true \
    PATH="$MOCK_BIN:$PATH" run bash "$REPO_ROOT/scripts/compliance-remediate.sh"
  [ "$status" -eq 0 ]
  # No label was created (read-only default / dry-run — #1036 AC#4).
  [ ! -f "$TEST_TMP/label-creates.log" ]
  # But the derived label IS named in the remediation report preview.
  grep -q 'dev-lead:hands-off' "$TEST_TMP/report/remediation-report.md"
}

# ── std_label_spec unit coverage (the shared lookup the remediator now uses) ────
_source_lib() {
  MANIFEST_DIR="$MANIFEST_DIR" PERSONA_DIRS_FILE="$PERSONA_DIRS_FILE" TEST_TMP="$TEST_TMP" \
  PATH="$MOCK_BIN:$PATH" bash -c '
    set -uo pipefail
    export MANIFEST_DIR PERSONA_DIRS_FILE TEST_TMP
    # shellcheck disable=SC1090
    source "'"$REPO_ROOT"'/scripts/lib/labels.sh"
    '"$1"'
  '
}

@test "std_label_spec returns the fixed-set colour/description for a fixed label" {
  run _source_lib 'std_label_spec security'
  [ "$status" -eq 0 ]
  [ "$output" = "security|d93f0b|Security-related PRs and issues" ]
}

@test "std_label_spec returns the derived family colour for a persona opt-out label" {
  run _source_lib 'std_label_spec dev-lead:hands-off'
  [ "$status" -eq 0 ]
  [[ "$output" == "dev-lead:hands-off|ededed|"* ]]
}

@test "std_label_spec returns non-zero for a label outside the standard set" {
  run _source_lib 'std_label_spec not-a-standard-label'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ── persona_opt_out_label_configs fail-closed on a garbled listing ──────────────
@test "persona_opt_out_label_configs fails closed when the listing parses to no personas" {
  # A listing that returns cleanly (exit 0) but contains no directory entries —
  # e.g. an org that returns an unexpected/empty body — must NOT read as "no
  # persona labels required". An org always has personas (#755, #1139 AC#3).
  printf '[]' > "$PERSONA_DIRS_FILE"
  run _source_lib 'persona_opt_out_label_configs'
  [ "$status" -ne 0 ]
  [[ "$output" != *":hands-off"* ]]
}

@test "persona_opt_out_label_configs rejects an opt_out_label containing the pipe delimiter" {
  # opt_out_label is free-form and a GitHub label name may contain '|', the field
  # delimiter of the emitted name|color|description spec. Such a name must NOT be
  # emitted (it would shift the color/description fields and corrupt downstream
  # parsers); it is skipped and the derivation fails closed.
  printf 'triggers:\n  opt_out_label: "dev-lead|hands-off"\n' > "$MANIFEST_DIR/dev-lead.yml"
  run _source_lib 'persona_opt_out_label_configs'
  [ "$status" -ne 0 ]
  # The corrupt record is never emitted: no line carries the injected pipe as a
  # name field (the only pipes present are the two legitimate spec delimiters).
  [[ "$output" != *"dev-lead|hands-off|"* ]]
}
