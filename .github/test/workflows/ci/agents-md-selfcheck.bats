#!/usr/bin/env bats
# Regression guard for the informational AGENTS.md self-check wired into
# .github/workflows/ci.yml (issue #646, Phase 3 of epic #642).
#
# Phase 3 runs the standalone structural linter (scripts/agents-md-lint.sh)
# against THIS repo's own canonical AGENTS.md on every pull request, in
# INFORMATIONAL mode: it annotates each structural finding with a GitHub
# ::warning:: but must never fail the build (promotion to a failing/required
# check is deferred to Phase 4). These tests pin that contract so a future edit
# cannot silently (a) drop the self-check, (b) point it at the wrong file, or
# (c) flip it to failing mode and turn it into a de-facto blocking gate before
# Phase 4 sign-off.

load 'helpers/setup'

# Emit the `run:` step block whose text contains the given marker substring.
# Steps in ci.yml start at a 6-space "- " (the `steps:` child indent); every
# deeper-indented line belongs to that step. (Mirrors secret-scan-config.bats.)
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
    elif [[ "$line" =~ ^[[:space:]]{8} ]] || [[ "$line" =~ ^[[:space:]]*$ ]]; then
      if [[ -n "$block" ]]; then
        block+="$line"$'\n'
      fi
    else
      if [[ "$block" == "      - "* ]]; then
        [[ "$block" == *"$marker"* ]] && out="$block"
      fi
      block=""
    fi
  done < "$TT_WORKFLOW"
  if [[ "$block" == "      - "* ]]; then
    [[ "$block" == *"$marker"* ]] && out="$block"
  fi
  printf '%s' "$out"
}

@test "agents-md-selfcheck: the ci workflow exists" {
  [[ -f "$TT_WORKFLOW" ]]
}

@test "agents-md-selfcheck: the linter script it invokes exists and is executable" {
  # The self-check runs the Phase-2 standalone linter; if the path drifts the
  # step would fail with file-not-found and red an otherwise-informational job.
  [[ -x "${TT_REPO_ROOT}/scripts/agents-md-lint.sh" ]]
}

@test "agents-md-selfcheck: ci runs the structural linter against this repo's AGENTS.md" {
  local block code
  block="$(step_block_with 'scripts/agents-md-lint.sh')"
  [[ -n "$block" ]]
  # Strip comments so a comment mentioning AGENTS.md cannot satisfy the assertion.
  code="$(printf '%s\n' "$block" | grep -vE '^[[:space:]]*#')"
  [[ "$code" == *"AGENTS.md"* ]]
}

@test "agents-md-selfcheck: the self-check stays informational (no --mode failing)" {
  # Informational default mode always exits 0; passing --mode failing would turn
  # a REQUIRED-level finding into a build failure — that promotion is Phase 4.
  # Strip comment lines first: a header comment saying "do NOT pass --mode
  # failing" is good documentation and must not trip this assertion, which is
  # about the actual invocation.
  local block code
  block="$(step_block_with 'scripts/agents-md-lint.sh')"
  [[ -n "$block" ]]
  code="$(printf '%s\n' "$block" | grep -vE '^[[:space:]]*#')"
  # Verify the linter is invoked with AGENTS.md as its argument, not just mentioned.
  [[ "$code" == *"scripts/agents-md-lint.sh"*"AGENTS.md"* ]]
  [[ "$code" != *"--mode failing"* ]]
  [[ "$code" != *"--mode=failing"* ]]
}

@test "agents-md-selfcheck: findings surface as ::warning:: annotations" {
  # Mirror run-bats.sh's non-fatal-signal convention: findings annotate without
  # failing the build.
  local block
  block="$(step_block_with 'scripts/agents-md-lint.sh')"
  [[ -n "$block" ]]
  [[ "$block" == *"::warning"* ]]
}

@test "agents-md-selfcheck: the self-check itself documents its informational, deferred-to-Phase-4 status" {
  # AC #3: no new branch-protection required check while informational. The
  # self-check's OWN step block must document that it is informational and that
  # promotion to a blocking/required check is deferred to Phase 4, so a reviewer
  # editing it later knows the non-blocking behaviour is deliberate. Scoping the
  # assertion to the step block (not the whole file) keeps it from passing on an
  # unrelated "informational" comment elsewhere in ci.yml.
  local block
  block="$(step_block_with 'scripts/agents-md-lint.sh')"
  [[ -n "$block" ]]
  [[ "$block" == *"informational"* ]]
  [[ "$block" == *"Phase 4"* ]]
}
