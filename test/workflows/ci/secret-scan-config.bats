#!/usr/bin/env bats
# Regression guard for the secret-scan job's gitleaks config in
# .github/workflows/ci.yml.
#
# Pins issue #996: ci.yml's `Run gitleaks` step invoked `gitleaks detect` WITHOUT
# `--config .gitleaks.toml`, so gitleaks fell back to its default ruleset. The
# default `generic-api-key` rule fires false positives on certain file
# paths/names (see standards/push-protection.md — "Why a required config file?"),
# so a run whose commit range touched such a file failed while others passed —
# the content-dependent, intermittent failure behind the fleet failure-rate
# warning (11.1% = 1/9 runs). The canonical Layer-3 spec
# (standards/push-protection.md:241, 257-258) requires `--config .gitleaks.toml`
# and every adopting repo MUST ship that file at root. These tests assert both,
# so a future edit can't silently drop the config and reintroduce the flakiness.

load 'helpers/setup'

# Emit the `run:` step block whose text contains the given marker substring.
# Steps in ci.yml start at a 6-space "- " (the `steps:` child indent); every
# deeper-indented line belongs to that step.
step_block_with() {
  local marker="$1"
  local block="" out="" line=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" == "      - "* ]]; then
      if [[ "$block" == "      - "* ]]; then
        [[ "$block" == *"$marker"* ]] && out="$block"
      fi
      block="$line"$'\n'
    else
      if [[ -n "$block" ]]; then
        block+="$line"$'\n'
      fi
    fi
  done < "$TT_WORKFLOW"
  if [[ "$block" == "      - "* ]]; then
    [[ "$block" == *"$marker"* ]] && out="$block"
  fi
  printf '%s' "$out"
}

@test "secret-scan: the ci workflow exists" {
  [[ -f "$TT_WORKFLOW" ]]
}

@test "secret-scan: gitleaks scan passes --config .gitleaks.toml" {
  # Without --config, gitleaks uses its default ruleset, whose generic-api-key
  # rule false-positives on certain filenames and reds the job intermittently.
  local block command
  block="$(step_block_with 'gitleaks detect')"
  [[ -n "$block" ]]
  # Extract the run: command from the step block
  command="$(printf '%s\n' "$block" | sed -nE 's/^[[:space:]]*run:[[:space:]]*(.*)$/\1/p')"
  [[ "$command" == gitleaks\ detect* ]]
  [[ "$command" == *"--config .gitleaks.toml"* ]]
}

@test "secret-scan: the .gitleaks.toml config ships at repo root" {
  # The --config flag references a file that MUST exist at root, or the scan
  # fails with file-not-found (standards/push-protection.md#gitleakstoml-template).
  [[ -f "${TT_REPO_ROOT}/.gitleaks.toml" ]]
}
