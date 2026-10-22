#!/usr/bin/env bats
# Tests for scripts/standards-deploy-driver.sh — the scheduled fleet-sweep driver
# for the org-standard workflow deployer (petry-projects/.github#851).
#
# The driver is intentionally thin: it maps workflow_dispatch inputs (env vars)
# into flags for scripts/deploy-standard-workflows.sh and runs it. Two layers are
# exercised here:
#   1. argv mapping — a fake deploy script records the flags it is handed, so the
#      env→flag translation (repo / workflow / dry-run / default fleet) is pinned.
#   2. drift-detection + no-op paths — the driver runs the REAL deploy script
#      against a fake `gh`, proving a drifted repo plans a PR and a compliant repo
#      opens nothing (idempotent), the same guarantees the schedule relies on.

setup() {
  TT_TMP="$(mktemp -d)"
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  DRIVER="${REPO_ROOT}/scripts/standards-deploy-driver.sh"
  ARGV_LOG="${TT_TMP}/argv.log"; export ARGV_LOG
  GH_CALLS="${TT_TMP}/gh-calls.log"; export GH_CALLS
  : > "$GH_CALLS"
}

teardown() { rm -rf "$TT_TMP"; }

# A fake deploy script that records exactly the argv the driver hands it. Wired in
# via the DEPLOY_SCRIPT override so the argv-mapping tests never touch the network.
install_fake_deploy() {
  local fake="${TT_TMP}/fake-deploy.sh"
  cat > "$fake" <<'FAKE'
#!/usr/bin/env bash
{ for a in "$@"; do printf '%s\n' "$a"; done; } > "$ARGV_LOG"
FAKE
  chmod +x "$fake"
  DEPLOY_SCRIPT="$fake"; export DEPLOY_SCRIPT
}

# Fake `gh` mirroring the deploy script's own tests: contents API 404s when
# GH_CONTENT_B64 is unset (stub missing → drift) and returns it as the file body
# when set (stub present → compliant). `gh repo list` echoes $GH_REPO_LIST.
install_gh_stub() {
  local bin="${TT_TMP}/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
{ printf 'gh'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$GH_CALLS"
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "list" ]; then
  printf '%s\n' ${GH_REPO_LIST:-}
  exit 0
fi
if [ "${1:-}" = "api" ]; then
  case "$2" in
    *contents*)
      if [ -n "${GH_CONTENT_B64:-}" ]; then
        printf '{"sha":"abc123","content":"%s"}' "$GH_CONTENT_B64"
        exit 0
      fi
      exit 1 ;;   # simulate 404 — file absent
  esac
fi
exit 0
STUB
  chmod +x "$bin/gh"
  PATH="${bin}:${PATH}"; export PATH
}

# ---------------------------------------------------------------------------
# argv mapping
# ---------------------------------------------------------------------------
@test "maps target_repo, target_workflow, and dry_run to script flags" {
  install_fake_deploy
  run env TARGET_REPO=markets TARGET_WORKFLOW=dev-lead.yml DRY_RUN=true \
    bash "$DRIVER"
  [ "$status" -eq 0 ]
  # Flags recorded in order, one per line.
  run cat "$ARGV_LOG"
  [ "${lines[0]}" = "--repo" ]
  [ "${lines[1]}" = "markets" ]
  [ "${lines[2]}" = "--workflow" ]
  [ "${lines[3]}" = "dev-lead.yml" ]
  [ "${lines[4]}" = "--dry-run" ]
}

@test "no inputs sweeps the whole fleet (no --repo / --workflow flags)" {
  install_fake_deploy
  run bash "$DRIVER"
  [ "$status" -eq 0 ]
  run cat "$ARGV_LOG"
  # Empty argv => whole-fleet, all-workflows sweep.
  [ ! -s "$ARGV_LOG" ]
}

@test "dry_run defaults off — no --dry-run flag when unset" {
  install_fake_deploy
  run env TARGET_REPO=markets bash "$DRIVER"
  [ "$status" -eq 0 ]
  ! grep -qx -- '--dry-run' "$ARGV_LOG"
}

# ---------------------------------------------------------------------------
# drift-detection + no-op paths (driver over the REAL deploy script)
# ---------------------------------------------------------------------------
@test "drift path: a missing stub is planned as a PR" {
  install_gh_stub
  run env GH_TOKEN=x TARGET_REPO=markets TARGET_WORKFLOW=add-to-project.yml DRY_RUN=true \
    bash "$DRIVER"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'Would open PR for markets .* add-to-project.yml'
  # dry-run must not mutate.
  ! grep -q 'git/refs --method POST' "$GH_CALLS"
  ! grep -q 'gh pr create' "$GH_CALLS"
}

@test "no-op path: a compliant stub opens nothing" {
  local template="${REPO_ROOT}/standards/workflows/add-to-project.yml"
  GH_CONTENT_B64="$(base64 -w 0 "$template" 2>/dev/null || base64 -b 0 "$template")"
  export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x TARGET_REPO=markets TARGET_WORKFLOW=add-to-project.yml DRY_RUN=true \
    bash "$DRIVER"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'already compliant'
  # True absence check: fail if any line plans a PR. `grep -vq` was wrong — it
  # succeeds whenever *any* line doesn't match, so it can't prove absence.
  ! echo "$output" | grep -q 'Would open PR'
}

@test "fleet sweep iterates every repo from gh repo list" {
  GH_REPO_LIST="markets TalkTerm"; export GH_REPO_LIST
  install_gh_stub
  run env GH_TOKEN=x TARGET_WORKFLOW=add-to-project.yml DRY_RUN=true bash "$DRIVER"
  [ "$status" -eq 0 ]
  # Both fleet repos are drifted (stub absent) => both planned, none skipped.
  echo "$output" | grep -qE 'Would open PR for markets'
  echo "$output" | grep -qE 'Would open PR for TalkTerm'
}
