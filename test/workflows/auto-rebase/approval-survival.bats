#!/usr/bin/env bats
# Integration regression test for issue #929 (part of #926, AC8):
# an APPROVED PR stays approved/mergeable after an eligible auto-rebase update.
#
# Unlike eligibility.bats / comments.bats (which unit-test the pure library
# helpers), this drives the reusable workflow's actual "Update behind
# non-Dependabot PRs" run-block end to end against a stubbed `gh`. The stub
# models the approval-survival semantics under this org's default ruleset
# configuration (dismiss_stale_reviews_on_push: false, require_last_push_approval: false):
#
#   - update-branch with update_method=merge preserves the existing commits
#     (no SHA rewrite) → under this org's ruleset, an existing APPROVED review
#     survives and the PR stays mergeable.
#   - update-branch with update_method=rebase rewrites SHAs → GitHub dismisses
#     the approval (review decision drops back to REVIEW_REQUIRED).
#
# This test proves the #929 scenario (behind + conflict-free + non-draft
# + APPROVED → updated + still APPROVED/mergeable) and confirms the workflow
# uses merge method. The "still-approved" assertion is non-vacuous: a regression
# to rebase would flip the modeled approval and fail this suite. However, this
# test cannot detect a future reversion to a strict ruleset (require_last_push_approval: true)
# — that would require a live integration check against the real ruleset config.

load 'helpers/setup'

REUSABLE="${TT_REPO_ROOT}/.github/workflows/auto-rebase-reusable.yml"

setup() {
  tt_make_tmpdir

  # Working dir for the run-block. The reusable sources its tooling from a
  # checkout at ./.auto-rebase-tooling; point that at this repo so the real
  # eligibility.sh / comments.sh get sourced.
  TT_WORK="${TT_TMP}/work"
  mkdir -p "$TT_WORK"
  ln -s "$TT_REPO_ROOT" "${TT_WORK}/.auto-rebase-tooling"

  # Modeled GitHub state, mutated by the gh stub.
  STATE_DIR="${TT_TMP}/state"
  mkdir -p "$STATE_DIR"
  export STATE_DIR

  # `gh` stub on PATH — never touches the network.
  TT_BIN="${TT_TMP}/bin"
  mkdir -p "$TT_BIN"
  _install_gh_stub
  PATH="${TT_BIN}:${PATH}"
  export PATH

  # Extract the reusable's update run-block verbatim so we exercise the real
  # workflow logic, not a hand-copied paraphrase of it.
  RUN_SCRIPT="${TT_TMP}/run.sh"
  yq -r '.jobs.auto-rebase.steps[]
           | select(.name == "Update behind non-Dependabot PRs")
           | .run' "$REUSABLE" > "$RUN_SCRIPT"
}

teardown() {
  tt_cleanup_tmpdir
}

# Seed one open, non-Dependabot, same-repo PR that is behind, conflict-free,
# non-draft, and already APPROVED.
_seed_approved_behind_pr() {
  printf '1 feature-branch\n' > "${STATE_DIR}/pr_list"
  printf 'main\n'             > "${STATE_DIR}/base_ref"
  printf '3\n'                > "${STATE_DIR}/behind"
  printf 'APPROVED\n'         > "${STATE_DIR}/review_decision"
  printf 'true\n'             > "${STATE_DIR}/mergeable"
}

_install_gh_stub() {
  cat > "${TT_BIN}/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal `gh` modeling the subset of the GitHub API the auto-rebase run-block
# calls, plus the approval-survival semantics of merge vs rebase.
set -euo pipefail

printf '%s\n' "$*" >> "${STATE_DIR}/gh-calls.log"

args="$*"
case "$args" in
  *update-branch*)
    method="merge"
    for a in "$@"; do
      case "$a" in
        update_method=*) method="${a#update_method=}" ;;
      esac
    done
    printf '%s\n' "$method" >> "${STATE_DIR}/update-methods.log"
    # The branch is now up to date regardless of method.
    printf '0\n' > "${STATE_DIR}/behind"
    if [ "$method" != "merge" ]; then
      # rebase rewrites SHAs → GitHub dismisses the existing approval.
      printf 'REVIEW_REQUIRED\n' > "${STATE_DIR}/review_decision"
      printf 'false\n'           > "${STATE_DIR}/mergeable"
    fi
    exit 0
    ;;
  *compare/*)
    cat "${STATE_DIR}/behind"
    exit 0
    ;;
  *state=open*)
    cat "${STATE_DIR}/pr_list"
    exit 0
    ;;
  */pulls/*)
    cat "${STATE_DIR}/base_ref"
    exit 0
    ;;
esac
exit 0
STUB
  chmod +x "${TT_BIN}/gh"
}

# Run the extracted reusable run-block with the same shell flags GitHub Actions
# uses for a default `run:` step (bash -eo pipefail).
_run_workflow() {
  run env \
    STATE_DIR="$STATE_DIR" \
    GH_TOKEN="stub-token" \
    HAS_PAT="false" \
    REPO="owner/repo" \
    ELIGIBILITY="all" \
    bash --noprofile --norc -eo pipefail -c \
      "cd '${TT_WORK}' && exec bash --noprofile --norc -eo pipefail '${RUN_SCRIPT}'"
}

# ── #929: the approved-behind PR gets updated and stays approved ─────────────

@test "approval-survival: an APPROVED behind PR is updated via merge" {
  _seed_approved_behind_pr
  _run_workflow
  [ "$status" -eq 0 ]
  [[ "$output" == *"#1"* ]]
  [[ "$output" == *"Branch updated"* ]]
  # It updated with the approval-preserving method, never rebase.
  grep -qx "merge" "${STATE_DIR}/update-methods.log"
  ! grep -qx "rebase" "${STATE_DIR}/update-methods.log"
}

@test "approval-survival: the PR ends up-to-date after the update" {
  _seed_approved_behind_pr
  _run_workflow
  [ "$status" -eq 0 ]
  [ "$(cat "${STATE_DIR}/behind")" = "0" ]
}

@test "approval-survival: the PR remains APPROVED and mergeable afterward" {
  _seed_approved_behind_pr
  _run_workflow
  [ "$status" -eq 0 ]
  [ "$(cat "${STATE_DIR}/review_decision")" = "APPROVED" ]
  [ "$(cat "${STATE_DIR}/mergeable")" = "true" ]
}

# ── teeth: the "stays APPROVED" claim depends on merge, not luck ─────────────
#
# Directly exercise the modeled endpoint with the rebase method to confirm the
# stub actually dismisses the approval on a SHA rewrite. This proves the
# assertions above are non-vacuous: had the workflow regressed to rebase, the
# approval would drop to REVIEW_REQUIRED and the suite would go red.

@test "approval-survival: a rebase update would dismiss the approval (control)" {
  _seed_approved_behind_pr
  run env STATE_DIR="$STATE_DIR" \
    gh api "repos/owner/repo/pulls/1/update-branch" -X PUT -f update_method=rebase
  [ "$status" -eq 0 ]
  [ "$(cat "${STATE_DIR}/review_decision")" = "REVIEW_REQUIRED" ]
  [ "$(cat "${STATE_DIR}/mergeable")" = "false" ]
}
