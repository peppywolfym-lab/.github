#!/usr/bin/env bats
# Validates fixture signals.json files against the schema.
#
# Kills R3: ensures the producer/consumer contract is enforced in CI
# rather than discovered when Mary's prompt parses an unexpected shape.

load 'helpers/setup'

VALIDATOR="${TT_REPO_ROOT}/.github/scripts/feature-ideation/validate-signals.py"
SCHEMA="${TT_REPO_ROOT}/.github/schemas/signals.schema.json"
FIX="${TT_FIXTURES_DIR}/expected"

@test "schema: validator script exists and is executable" {
  [ -f "$VALIDATOR" ]
  [ -r "$VALIDATOR" ]
  [ -x "$VALIDATOR" ]
}

@test "schema: schema file is valid JSON" {
  jq -e . "$SCHEMA" >/dev/null
}

@test "schema: empty-repo fixture passes" {
  run python3 "$VALIDATOR" "${FIX}/empty-repo.signals.json" "$SCHEMA"
  [ "$status" -eq 0 ]
}

@test "schema: populated fixture passes" {
  run python3 "$VALIDATOR" "${FIX}/populated.signals.json" "$SCHEMA"
  [ "$status" -eq 0 ]
}

@test "schema: truncated fixture passes" {
  run python3 "$VALIDATOR" "${FIX}/truncated.signals.json" "$SCHEMA"
  [ "$status" -eq 0 ]
}

@test "schema: missing required field FAILS validation" {
  run python3 "$VALIDATOR" "${FIX}/INVALID-missing-field.signals.json" "$SCHEMA"
  [ "$status" -eq 1 ]
}

@test "schema: malformed repo string FAILS validation" {
  run python3 "$VALIDATOR" "${FIX}/INVALID-bad-repo.signals.json" "$SCHEMA"
  [ "$status" -eq 1 ]
}

@test "schema: extra top-level field FAILS validation" {
  bad_file="${BATS_TEST_TMPDIR}/extra-field.json"
  jq '. + {unexpected: "value"}' "${FIX}/empty-repo.signals.json" >"$bad_file"
  run python3 "$VALIDATOR" "$bad_file" "$SCHEMA"
  [ "$status" -eq 1 ]
}

@test "schema: invalid date-time scan_date FAILS validation (format checker enforced)" {
  # Caught by Copilot review on PR petry-projects/.github#85:
  # Draft202012Validator does NOT enforce `format` keywords by default.
  # The validator must instantiate FormatChecker explicitly.
  bad_file="${BATS_TEST_TMPDIR}/bad-scan-date.json"
  jq '.scan_date = "not-a-real-timestamp"' "${FIX}/empty-repo.signals.json" >"$bad_file"
  run python3 "$VALIDATOR" "$bad_file" "$SCHEMA"
  [ "$status" -eq 1 ]
}

@test "schema: well-formed date-time scan_date passes" {
  good_file="${BATS_TEST_TMPDIR}/good-scan-date.json"
  jq '.scan_date = "2026-04-08T12:34:56Z"' "${FIX}/empty-repo.signals.json" >"$good_file"
  run python3 "$VALIDATOR" "$good_file" "$SCHEMA"
  [ "$status" -eq 0 ]
}

@test "schema: malformed JSON signals file FAILS with exit code 2" {
  # Validates that the OSError/JSONDecodeError path returns 2 (file/data error)
  # not 1 (schema validation error). Caught by CodeRabbit review on PR #85.
  bad_file="${BATS_TEST_TMPDIR}/malformed.json"
  printf '{"schema_version":"1.0.0",' >"$bad_file"
  run python3 "$VALIDATOR" "$bad_file" "$SCHEMA"
  [ "$status" -eq 2 ]
}

@test "schema: SCHEMA_VERSION constant matches schema file version comment" {
  # CodeRabbit on PR petry-projects/.github#85: enforce that the
  # SCHEMA_VERSION constant in collect-signals.sh stays in lockstep with
  # the version annotation in signals.schema.json. Bumping one without
  # the other is a compatibility break.
  script_version=$(grep -E '^SCHEMA_VERSION=' "${TT_REPO_ROOT}/.github/scripts/feature-ideation/collect-signals.sh" \
    | head -1 | sed -E 's/^SCHEMA_VERSION="([^"]+)".*/\1/')
  schema_version=$(jq -r '."$comment"' "$SCHEMA" \
    | grep -oE 'version: [0-9]+\.[0-9]+\.[0-9]+' | sed 's/version: //')
  [ -n "$script_version" ]
  [ -n "$schema_version" ]
  [ "$script_version" = "$schema_version" ]
}
