#!/usr/bin/env bats
# Tests for the repo-template WORKFLOW-STUB generator in
# scripts/seed-repo-template.sh (#886).
#
# The repo-template baseline re-seed ("chore: seed org baseline file scaffold")
# must source its workflow stubs from the canonical standards/workflows/ — which
# pin the major-scoped `<agent>/v<M>-stable` channel and carry the S7637 (uses:)
# and S7635 (secrets: inherit) NOSONAR markers — rather than from a stale
# embedded copy. When it drifted to an embedded copy it re-pinned repo-template
# back to the BARE `<agent>/stable` tier tag (repo-template#86: v1-stable →
# stable, v2-stable → stable), undoing the standards-deploy convergence and
# seeding every new repo onto the wrong channel.
#
# `--emit-workflow <name.yml>` copies standards/workflows/<name.yml> VERBATIM and
# refuses to emit a stub whose first-party channel-ref pin is a bare
# `<agent>/<tier>` (no v<M>- major prefix), so a regression fails loud instead of
# being re-seeded fleet-wide.
#
# STANDARDS_DIR points the seed script at this checkout so templates are read
# from the local standards/workflows/ instead of the network.

setup() {
  REPO_ROOT="$(cd -- "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SEED="${REPO_ROOT}/scripts/seed-repo-template.sh"
  WF_DIR="${REPO_ROOT}/standards/workflows"
  export STANDARDS_DIR="$REPO_ROOT"
}

emit() { STANDARDS_DIR="$REPO_ROOT" bash "$SEED" --emit-workflow "$1"; }

# The stubs the re-seed corrupted in repo-template#86 (the "spot-check" set).
RESEEDED_STUBS="dev-lead.yml auto-rebase.yml dependabot-automerge.yml"

@test "--emit-workflow dev-lead.yml is byte-identical to the standards template" {
  run emit dev-lead.yml
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "${WF_DIR}/dev-lead.yml")" ]
}

@test "emitted dev-lead stub pins @dev-lead/v1-stable, never the bare tier tag" {
  run emit dev-lead.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'dev-lead-reusable.yml@dev-lead/v1-stable'
  echo "$output" | grep -qF 'agent_ref: dev-lead/v1-stable'
  # The exact regression from repo-template#86 must be absent.
  ! echo "$output" | grep -qE '@dev-lead/stable([[:space:]]|$)'
  ! echo "$output" | grep -qE 'agent_ref:[[:space:]]*dev-lead/stable([[:space:]]|$)'
}

@test "every re-seeded stub emits a major-scoped v<M>-stable pin (no bare tier)" {
  local name ref
  for name in $RESEEDED_STUBS; do
    run emit "$name"
    [ "$status" -eq 0 ]
    # Extract the @<ref> from the first-party channel-ref (S7637-marked) uses line.
    ref="$(echo "$output" | grep -E 'S7637\) first-party channel ref' \
      | sed -E 's/.*-reusable\.yml@([^[:space:]]+).*/\1/')"
    [ -n "$ref" ] || { echo "no channel-ref line in $name"; return 1; }
    echo "$ref" | grep -qE '^[a-z0-9-]+/v[0-9]+-stable$' \
      || { echo "$name pins non-v-form '$ref'"; return 1; }
  done
}

@test "every re-seeded stub keeps its S7637 (uses:) and S7635 (secrets: inherit) markers" {
  local name
  for name in $RESEEDED_STUBS; do
    run emit "$name"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF 'NOSONAR(githubactions:S7637)' \
      || { echo "$name lost its S7637 marker"; return 1; }
    echo "$output" | grep -qE '^[[:space:]]*secrets:[[:space:]]+inherit[[:space:]]+# NOSONAR\(githubactions:S7635\)' \
      || { echo "$name lost its S7635 secrets: inherit marker"; return 1; }
  done
}

@test "--emit-workflow rejects an unknown workflow name" {
  run emit no-such-workflow.yml
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'unknown workflow'
}

@test "--emit-workflow rejects path-traversal, dotfile, and empty names before any FS access" {
  # The name guard (case '*/*|.*|"') blocks directory traversal and dotfiles up
  # front, so --emit-workflow can never read outside standards/workflows/.
  run emit '../etc/passwd'
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'invalid workflow'

  run emit 'foo/bar.yml'
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'invalid workflow'

  run emit '.hidden.yml'
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'invalid workflow'

  run emit ''
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'invalid workflow'
}

@test "--emit-workflow refuses a template carrying a bare <agent>/<tier> pin" {
  # Fixture: a standards dir whose dev-lead template regressed to the bare pin.
  local fixture="${BATS_TEST_TMPDIR}/fixture"
  mkdir -p "${fixture}/standards/workflows" "${fixture}/scripts/lib"
  cp "${REPO_ROOT}/scripts/lib/gitignore-baseline.sh" "${fixture}/scripts/lib/"
  sed -E 's#@dev-lead/v[0-9]+-stable#@dev-lead/stable#g' \
    "${WF_DIR}/dev-lead.yml" > "${fixture}/standards/workflows/dev-lead.yml"
  run env STANDARDS_DIR="$fixture" bash "$SEED" --emit-workflow dev-lead.yml
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'bare'
}

@test "--emit-workflow fails CLOSED when a first-party reusable uses: line lost its S7637 marker" {
  # Fixture: a template whose dev-lead uses: line keeps a valid v-form pin but
  # DROPPED the S7637 marker. The marker-based pin check would then inspect zero
  # lines and pass (fail-open, #887/qodo). The guard must refuse instead.
  local fixture="${BATS_TEST_TMPDIR}/fixture-nomarker"
  mkdir -p "${fixture}/standards/workflows" "${fixture}/scripts/lib"
  cp "${REPO_ROOT}/scripts/lib/gitignore-baseline.sh" "${fixture}/scripts/lib/"
  sed -E '/uses:.*-reusable\.yml@/ s/[[:space:]]*# NOSONAR\(githubactions:S7637\).*$//' \
    "${WF_DIR}/dev-lead.yml" > "${fixture}/standards/workflows/dev-lead.yml"
  # Sanity: the pin itself is still valid v-form (only the marker was removed).
  grep -qE 'uses:.*@dev-lead/v[0-9]+-stable[[:space:]]*$' "${fixture}/standards/workflows/dev-lead.yml"
  run env STANDARDS_DIR="$fixture" bash "$SEED" --emit-workflow dev-lead.yml
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'marker'
}

@test "--emit-workflow fails CLOSED when agent_ref regressed to a bare tier (valid uses: pin)" {
  # Fixture: dev-lead template keeps a valid v-form `uses:` pin + its S7637 marker
  # but its `with: agent_ref:` dropped to the bare tier. The uses-pin check alone
  # would pass; the agent_ref guard (CodeRabbit) must refuse instead.
  local fixture="${BATS_TEST_TMPDIR}/fixture-agentref"
  mkdir -p "${fixture}/standards/workflows" "${fixture}/scripts/lib"
  cp "${REPO_ROOT}/scripts/lib/gitignore-baseline.sh" "${fixture}/scripts/lib/"
  sed -E 's#^([[:space:]]*agent_ref:[[:space:]]*)dev-lead/v[0-9]+-stable#\1dev-lead/stable#' \
    "${WF_DIR}/dev-lead.yml" > "${fixture}/standards/workflows/dev-lead.yml"
  # Sanity: the uses: pin is untouched (still valid v-form + S7637 marker).
  grep -qE 'uses:.*@dev-lead/v[0-9]+-stable.*S7637' "${fixture}/standards/workflows/dev-lead.yml"
  run env STANDARDS_DIR="$fixture" bash "$SEED" --emit-workflow dev-lead.yml
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'agent_ref'
}

@test "usage is shown when --emit-workflow is given no name" {
  run bash "$SEED" --emit-workflow
  [ "$status" -ne 0 ]
}

@test "STANDARDS_REF defaults to standards/v1-stable when unset (environment variable resolution)" {
  # Verify that seed-repo-template.sh accepts STANDARDS_REF and defaults to v1-stable
  # when unset. The script should complete successfully with default reference.
  run env -u STANDARDS_REF STANDARDS_DIR="$REPO_ROOT" bash "$SEED" --emit-workflow dev-lead.yml
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "${WF_DIR}/dev-lead.yml")" ]
}

@test "STANDARDS_REF can be explicitly set to a specific version (explicit reference)" {
  # Verify that an explicit STANDARDS_REF value is accepted and does not affect
  # the emission of workflow content (ref is for documentation/validation, not emission).
  run env STANDARDS_REF="standards/v1.2.3" STANDARDS_DIR="$REPO_ROOT" bash "$SEED" --emit-workflow dev-lead.yml
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "${WF_DIR}/dev-lead.yml")" ]
}

@test "STANDARDS_DIR behavior is preserved when explicitly set (backward compatibility)" {
  # Verify that explicit STANDARDS_DIR still works as before, independent of STANDARDS_REF.
  local custom_dir="${BATS_TEST_TMPDIR}/custom-standards"
  mkdir -p "${custom_dir}/standards/workflows"
  cp "${WF_DIR}/dev-lead.yml" "${custom_dir}/standards/workflows/"
  run env STANDARDS_REF="standards/v1-stable" STANDARDS_DIR="$custom_dir" bash "$SEED" --emit-workflow dev-lead.yml
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "${custom_dir}/standards/workflows/dev-lead.yml")" ]
}
