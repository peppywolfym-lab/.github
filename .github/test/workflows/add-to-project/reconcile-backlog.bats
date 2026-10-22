#!/usr/bin/env bats
# Tests for reconcile-backlog.sh — the periodic/manual backlog reconcile
# (petry-projects/.github#518). Runs the script with a tailored `gh` stub and
# DRY_RUN=1, and asserts it scans a repo's open issues/PRs and reconciles them
# via the shared event-path helpers (logging intended adds, not mutating).
# Issues are un-gated; PRs keep the required-label gate. Discussions untracked.

bats_require_minimum_version 1.5.0

load 'helpers/setup'

# Write a gh stub whose /issues endpoint returns the given TSV rows
# (node_id<TAB>url<TAB>labels-json<TAB>kind). GraphQL responses:
#   - the membership prefetch query (contains "items(first") returns a single
#     page whose content ids come from STUB_BOARD_IDS (space/comma-separated,
#     default none) — this is what drives the on-board fast path;
#   - any other graphql call returns an empty page (no match / no-op).
write_issue_stub() {
  local rows="$1" bin="${TT_TMP}/bin"; mkdir -p "$bin"
  export STUB_ROWS="$rows"
  export STUB_BOARD_IDS="${STUB_BOARD_IDS:-}"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
emit_board() {
  # Build an items page whose nodes carry the STUB_BOARD_IDS as Issue content.
  local nodes="" id
  for id in ${STUB_BOARD_IDS//,/ }; do
    nodes="${nodes:+${nodes},}$(printf '{"content":{"id":"%s"}}' "$id")"
  done
  printf '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":""},"nodes":[%s]}}}}' "$nodes"
}
case "$*" in
  *"repos/"*"/issues"*) printf '%b' "$STUB_ROWS" ;;
  *"items(first"*) emit_board ;;
  *graphql*) printf '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":""},"nodes":[]}}}}' ;;
esac
STUB
  chmod +x "$bin/gh"; PATH="${bin}:${PATH}"; export PATH
}

setup() {
  tt_make_tmpdir
  write_issue_stub 'I_node1\thttps://example.invalid/issues/1\t[{"name":"bug"}]\tissue\n'
  export PROJECT_ID="PVT_test" PROJECT_URL="https://example.invalid/p/1" GH_TOKEN="t"
  export RECON_REPOS="petry-projects/demo"   # skip installation lookup
  export DRY_RUN="1"
}
teardown() { tt_cleanup_tmpdir; }

run_recon() { run bash "${TT_SCRIPTS_DIR}/reconcile-backlog.sh"; }

@test "un-gated: an issue without dev-lead is still added" {
  run_recon
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '\[dry-run\] would add content I_node1 to project'
}

@test "reports the repo count it scanned" {
  run_recon
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'Reconciling 1 repo(s)'
  echo "$output" | grep -q 'Reconcile complete'
}

@test "an excluded label disqualifies an issue (no add)" {
  write_issue_stub 'I_excl\thttps://example.invalid/issues/2\t[{"name":"bug"},{"name":"compliance-audit"}]\tissue\n'
  run_recon
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'would add content I_excl'
}

@test "a PR WITHOUT dev-lead is NOT added (PR gate kept)" {
  write_issue_stub 'PR_nolabel\thttps://example.invalid/pull/3\t[{"name":"bug"}]\tpr\n'
  run_recon
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'would add content PR_nolabel'
}

@test "a PR WITH dev-lead is added" {
  write_issue_stub 'PR_devlead\thttps://example.invalid/pull/4\t[{"name":"dev-lead"}]\tpr\n'
  run_recon
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'would add content PR_devlead'
}

# --- membership prefetch fast-path (perf: skip per-item API round-trips) ---

@test "prefetch: logs the board item count it cached" {
  STUB_BOARD_IDS="I_node1" run_recon
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'Prefetched 1 board item(s)'
}

@test "fast-path: a qualifying item already on the board is NOT re-added" {
  # Membership prefetch reports I_node1 already on the board → no add attempt
  # (dry-run reports accurate intent: nothing to do).
  STUB_BOARD_IDS="I_node1" run_recon
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'would add content I_node1'
}

@test "fast-path: a qualifying item NOT on the board is still added" {
  # Board has some other item; I_node1 is absent → add proceeds as before.
  STUB_BOARD_IDS="I_other" run_recon
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'would add content I_node1'
}

@test "fast-path: a disqualified item absent from the board skips the find" {
  # Excluded label → disqualifies; with membership showing it absent, the
  # removal find is skipped and it's reported as a clean not-on-board skip.
  STUB_BOARD_IDS="" write_issue_stub 'I_excl\thttps://example.invalid/issues/9\t[{"name":"compliance-audit"}]\tissue\n'
  run_recon
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'Skip https://example.invalid/issues/9 (not on board)'
}
