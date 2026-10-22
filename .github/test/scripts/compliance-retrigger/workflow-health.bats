#!/usr/bin/env bats
# Tests verifying that check_devlead_workflows() and all associated workflow
# manipulation has been removed from scripts/compliance-retrigger.sh.
#
# Acceptance criteria (from issue #438):
#   - compliance-retrigger.sh no longer reads or modifies any repo's dev-lead.yml
#     enablement state.
#   - Dry-run output and step summary no longer mention "workflows re-enabled".

bats_require_minimum_version 1.5.0

load 'helpers/setup'

setup() {
  tt_make_tmpdir
  tt_install_gh_stub
  export GH_STUB_LOG="${TT_TMP}/gh.log"
  export GH_STUB_ENABLE_LOG="${TT_TMP}/gh.enable.log"
  : >"$GH_STUB_LOG"
  : >"$GH_STUB_ENABLE_LOG"
}

teardown() {
  tt_cleanup_tmpdir
}

# ---------------------------------------------------------------------------
# Static checks: removed symbols must not appear in the script source
# ---------------------------------------------------------------------------

@test "check_devlead_workflows function is not defined in the script" {
  run grep -qF "check_devlead_workflows" "$TT_SCRIPT"
  [ "$status" -eq 1 ]
}

@test "WORKFLOWS_DISABLED counter is not referenced in the script" {
  run grep -qF "WORKFLOWS_DISABLED" "$TT_SCRIPT"
  [ "$status" -eq 1 ]
}

@test "WORKFLOWS_ENABLED counter is not referenced in the script" {
  run grep -qF "WORKFLOWS_ENABLED" "$TT_SCRIPT"
  [ "$status" -eq 1 ]
}

@test "dev-lead.yml workflow state is not queried in the script" {
  run grep -qF "dev-lead.yml" "$TT_SCRIPT"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Behavioral: running the script must not call the workflow enable API
# ---------------------------------------------------------------------------

@test "running the script does not call the workflow enable API" {
  # Use DRY_RUN=false so the current code's enable path would fire if present;
  # the fix must prevent it unconditionally, not just in dry-run mode.
  GH_TOKEN=fake \
    ORG=petry-projects \
    DRY_RUN=false \
    GH_STUB_WORKFLOW_STATE=disabled_manually \
    run bash "$TT_SCRIPT"

  # Script must have exited successfully
  [ "$status" -eq 0 ]
  # The enable log must be empty — no workflow was re-enabled
  [ ! -s "$GH_STUB_ENABLE_LOG" ]
}

@test "running the script does not read dev-lead.yml workflow state" {
  GH_TOKEN=fake \
    ORG=petry-projects \
    DRY_RUN=true \
    run bash "$TT_SCRIPT"

  # Script must have exited successfully before inspecting the log
  [ "$status" -eq 0 ]
  # No call to the dev-lead.yml endpoint
  run grep -qF "dev-lead.yml" "$GH_STUB_LOG"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Behavioral: summary output must not mention workflow counts
# ---------------------------------------------------------------------------

@test "script output does not mention Workflows re-enabled" {
  GH_TOKEN=fake \
    ORG=petry-projects \
    DRY_RUN=true \
    run bash "$TT_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" != *"Workflows re-enabled"* ]]
}

@test "script output does not mention Workflows already active" {
  GH_TOKEN=fake \
    ORG=petry-projects \
    DRY_RUN=true \
    run bash "$TT_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" != *"Workflows already active"* ]]
}
