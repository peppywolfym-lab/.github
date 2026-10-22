#!/usr/bin/env bats
# Issue #856 — codify the SKIP_REPOS → SKIP_OVERRIDES opt-in as the canonical way
# a self-managing meta-repo satisfies a universal-required workflow, and guard the
# invariant that the required-workflow audit and the deploy config AGREE.
#
# The audit (scripts/compliance-audit.sh) requires every REQUIRED_WORKFLOW on
# EVERY repo, including the SKIP_REPOS (.github / .github-private) that the deploy
# sweep otherwise exempts. So for each SKIP_REPO, every workflow that is both
# universal-required AND deployable by the sweep must have a reconciliation path:
#   - opted into the sweep via SKIP_OVERRIDES, OR
#   - explicitly declared self-managed via SKIP_SELF_MANAGED.
# Otherwise that repo is flagged required-but-missing forever with no opt-in — the
# exact drift #847 hit ad-hoc for .github-private / pr-auto-review.
#
# reconcile_skip_repo_required_workflows() is the pure guard: given the audit's
# REQUIRED_WORKFLOWS, it prints every UNRECONCILED (repo, workflow) pair and
# returns non-zero if any exist.
#
# REQUIRED_WORKFLOWS is read from the real audit script in a SEPARATE subshell
# (setup) and passed to the deploy config as args, so the test wires the two real
# configs together without hand-copied lists — and without sourcing both scripts
# in one shell (they both `source lib/ring-pins.sh`, whose readonly vars collide
# on a double load).

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  DEPLOY="${REPO_ROOT}/scripts/deploy-standard-workflows.sh"
  AUDIT="${REPO_ROOT}/scripts/compliance-audit.sh"
  # The audit's REQUIRED_WORKFLOWS, straight from the source of truth.
  mapfile -t REQUIRED < <(
    bash -c 'source "$1" >/dev/null 2>&1; printf "%s\n" "${REQUIRED_WORKFLOWS[@]}"' _ "$AUDIT"
  )
}

# run_reconcile [pre-source snippet] — source the deploy config, optionally mutate
# it (to synthesize a gap), then run reconcile against the real REQUIRED list.
run_reconcile() {
  local mutate="${1:-}"
  run bash -c '
    source "$1" >/dev/null 2>&1
    shift
    '"$mutate"'
    reconcile_skip_repo_required_workflows "$@"
  ' _ "$DEPLOY" "${REQUIRED[@]}"
}

@test "shipped deploy config reconciles every required+deployable workflow on every SKIP_REPO" {
  run_reconcile
  # No unreconciled pairs → empty output, status 0.
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "reconcile flags a gap when an opt-in is dropped" {
  # Remove pr-auto-review's opt-in for .github-private without adding it to
  # SKIP_SELF_MANAGED → the pair (.github-private pr-auto-review.yml) becomes an
  # unreconciled required+deployable workflow.
  run_reconcile 'unset "SKIP_OVERRIDES[pr-auto-review.yml]"'
  [ "$status" -ne 0 ]
  grep -qF ".github-private pr-auto-review.yml" <<< "$output"
}

@test "reconcile flags a gap when a self-managed entry is dropped" {
  # Drop .github-private's self-managed declaration entirely → every required
  # workflow it self-manages (not opted in) becomes unreconciled.
  run_reconcile 'unset "SKIP_SELF_MANAGED[.github-private]"'
  [ "$status" -ne 0 ]
  grep -qF ".github-private feature-ideation.yml" <<< "$output"
}

@test "reconcile ignores required-but-NON-deployable workflows (ci.yml / sonarcloud.yml)" {
  # ci.yml and sonarcloud.yml are required org-wide but set up manually per tech
  # stack — they are not in DEPLOYABLE_WORKFLOWS, so the sweep never owns them and
  # they must NOT appear as reconciliation gaps for any SKIP_REPO.
  run_reconcile
  [ "$status" -eq 0 ]
  ! grep -qF "ci.yml" <<< "$output"
  ! grep -qF "sonarcloud.yml" <<< "$output"
}

# ---------------------------------------------------------------------------
# The individual predicates are pure and independently testable.
# ---------------------------------------------------------------------------

@test "is_deployable_workflow: true for a deployable stub, false otherwise" {
  run bash -c 'source "$1" >/dev/null 2>&1; is_deployable_workflow pr-auto-review.yml' _ "$DEPLOY"
  [ "$status" -eq 0 ]
  run bash -c 'source "$1" >/dev/null 2>&1; is_deployable_workflow ci.yml' _ "$DEPLOY"
  [ "$status" -ne 0 ]
}

@test "skip_repo_self_manages: .github-private self-manages initiative-driver but NOT pr-auto-review" {
  run bash -c 'source "$1" >/dev/null 2>&1; skip_repo_self_manages .github-private initiative-driver.yml' _ "$DEPLOY"
  [ "$status" -eq 0 ]
  # pr-auto-review is satisfied by the SKIP_OVERRIDES opt-in, not self-managed.
  run bash -c 'source "$1" >/dev/null 2>&1; skip_repo_self_manages .github-private pr-auto-review.yml' _ "$DEPLOY"
  [ "$status" -ne 0 ]
}
