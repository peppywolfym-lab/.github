#!/usr/bin/env bats
# Tests for the repo-template .gitignore generator in
# scripts/seed-repo-template.sh (#798).
#
# The seeded template must carry the marker-wrapped org secrets baseline (L1) on
# top, with the template's own ecosystem/OS entries (L2) below the END marker —
# and it must NOT re-ignore a path the baseline negates (e.g. keep .env.example
# out of L2, since the baseline re-allows it via `!.env.example`).
#
# STANDARDS_DIR points the seed script at this checkout so `.gitignore` is read
# from the local canonical /.gitignore instead of the network.

setup() {
  REPO_ROOT="$(cd -- "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SEED="${REPO_ROOT}/scripts/seed-repo-template.sh"
  export STANDARDS_DIR="$REPO_ROOT"
}

emit() { STANDARDS_DIR="$REPO_ROOT" bash "$SEED" --emit-baseline .gitignore; }

@test "template .gitignore leads with the marker-wrapped L1 block" {
  run emit
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '# >>> BEGIN petry-projects secrets baseline (managed by .github — do not edit) >>>' ]
  echo "$output" | grep -qxF '# <<< END petry-projects secrets baseline <<<'
}

@test "template .gitignore passes the STORY3 anchor check (.env, *.pem, *.key present)" {
  run emit
  [ "$status" -eq 0 ]
  echo "$output" | grep -qxF '.env'
  echo "$output" | grep -qxF '*.pem'
  echo "$output" | grep -qxF '*.key'
}

@test "template .gitignore keeps its L2 ecosystem entries below the END marker" {
  run emit
  [ "$status" -eq 0 ]
  local end_ln node_ln
  end_ln="$(printf '%s\n' "$output" | grep -nxF '# <<< END petry-projects secrets baseline <<<' | head -1 | cut -d: -f1)"
  node_ln="$(printf '%s\n' "$output" | grep -nxF 'node_modules/' | head -1 | cut -d: -f1)"
  [ -n "$end_ln" ] && [ -n "$node_ln" ]
  [ "$end_ln" -lt "$node_ln" ]
  echo "$output" | grep -qxF 'dist/'
}

@test "template .gitignore does not re-ignore a baseline-negated path (no bare .env.* in L2)" {
  run emit
  [ "$status" -eq 0 ]
  # The baseline re-allows .env.example via `!.env.example`; an L2 `.env.*` would
  # silently re-hide it. Assert no L2 line re-ignores it.
  local end_ln l2
  end_ln="$(printf '%s\n' "$output" | grep -nxF '# <<< END petry-projects secrets baseline <<<' | head -1 | cut -d: -f1)"
  l2="$(printf '%s\n' "$output" | tail -n +"$((end_ln + 1))")"
  ! printf '%s\n' "$l2" | grep -qxF '.env.*'
  ! printf '%s\n' "$l2" | grep -qxF '.env'
}
