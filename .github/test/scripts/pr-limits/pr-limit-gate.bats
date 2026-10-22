#!/usr/bin/env bats
# Tests for scripts/lib/pr-limit-gate.sh — the source-side admission gate that,
# before automation opens a PR, decides allow / defer by counting open non-draft
# automation PRs against the caps in standards/pr-limits.json (#561, Phase 2b).
#
# Context (#561, ADR docs/initiatives/pull-request-limits-adr.md §7.2–§7.4):
# GitHub exposes no native "max open PRs" surface, so the cap is enforced at the
# PR-creating source. This guard is the reusable library; wiring it into the live
# dev-lead / initiative-driver / agentic path is #508. The guard reads its caps +
# exempt list from standards/pr-limits.json (#507), counts open non-draft PRs via
# `gh search prs`, and returns allow (exit 0) or defer (exit 1).
#
# `gh` is stubbed via the env-driven fake under
# test/scripts/compliance-remediate/stubs/gh (no live API), so the only thing the
# decision depends on is the stubbed search payload + the config caps.

bats_require_minimum_version 1.5.0

LIB="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/scripts/lib/pr-limit-gate.sh"
GH_STUB_SRC="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/scripts/compliance-remediate/stubs/gh"

setup() {
  TMP="$(mktemp -d)"
  export TMP

  # Put the env-driven gh stub on PATH and log every invocation so we can assert
  # the gate never issues a mutating gh subcommand.
  mkdir -p "$TMP/bin"
  cp "$GH_STUB_SRC" "$TMP/bin/gh"
  chmod +x "$TMP/bin/gh"
  PATH="$TMP/bin:$PATH"
  export PATH
  export GH_STUB_LOG="$TMP/gh.log"
  : >"$GH_STUB_LOG"

  export ORG="petry-projects"
}

teardown() {
  if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
    rm -rf "$TMP"
  fi
}

# Write a pr-limits config with the given org-wide cap and dev-lead sub-cap, and
# export PR_LIMITS_CONFIG pointing at it.
write_config() {
  local org_cap="$1" devlead_cap="$2"
  export PR_LIMITS_CONFIG="$TMP/pr-limits.json"
  jq -n \
    --argjson org_cap "$org_cap" \
    --argjson devlead_cap "$devlead_cap" \
    '{
      status: "provisional",
      _schema_version: 1,
      org_wide: { automation_open_pr_cap: $org_cap },
      per_source_caps: { "dev-lead": $devlead_cap },
      exempt_actors: ["dependabot[bot]"],
      exempt_labels: ["security"]
    }' >"$PR_LIMITS_CONFIG"
}

# Make the gh stub return a search payload of N open non-draft PRs, all authored
# by a non-exempt actor with no exempt labels.
stub_open_prs() {
  local count="$1"
  export GH_STUB_STDOUT
  GH_STUB_STDOUT="$(jq -nc --argjson n "$count" \
    '[range(0; $n) | { author: { login: "donpetry-bot" }, labels: [] }]')"
}

run_gate() {
  run bash -c "source '$LIB'; plg_admission_gate \"\$@\"" _ "$@"
}

# --------------------------------------------------------------------------
# AC #1 — under the cap: allow
# --------------------------------------------------------------------------
@test "under the org-wide cap returns allow" {
  write_config 18 9
  stub_open_prs 5
  run_gate "claude"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

# --------------------------------------------------------------------------
# AC #1 — at / over the org-wide cap: defer
# --------------------------------------------------------------------------
@test "at the org-wide cap returns defer" {
  write_config 5 9
  stub_open_prs 5
  run_gate "claude"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

@test "over the org-wide cap returns defer" {
  write_config 3 9
  stub_open_prs 7
  run_gate "claude"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

# --------------------------------------------------------------------------
# AC #1 — per-source sub-cap: defer even when under the org-wide cap
# --------------------------------------------------------------------------
@test "over the per-source sub-cap returns defer while under the org-wide cap" {
  write_config 100 2
  stub_open_prs 5
  run_gate "dev-lead"
  [ "$status" -eq 1 ]
  [[ "$output" == *"decision=defer"* ]]
}

# --------------------------------------------------------------------------
# AC #2 — exempt actor is always allowed, even over the cap, and never counted
# --------------------------------------------------------------------------
@test "exempt actor over the cap returns allow" {
  write_config 1 1
  stub_open_prs 50
  run_gate "dependabot[bot]"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
  [[ "$output" == *"exempt"* ]]
}

# --------------------------------------------------------------------------
# AC #3 — dry-run: prints the computed decision + allow, performs no mutation
# --------------------------------------------------------------------------
@test "dry-run over the cap prints the would-be defer but returns allow" {
  write_config 3 9
  stub_open_prs 7
  DRY_RUN=true run_gate "claude"
  [ "$status" -eq 0 ]
  # The computed (would-be) decision is surfaced...
  [[ "$output" == *"defer"* ]]
  # ...but the gate returns allow so the caller proceeds.
  [[ "$output" == *"decision=allow"* ]]
  # And no mutating gh subcommand was ever issued (read-only search only).
  ! grep -qE 'pr create|pr edit|api -X (POST|PATCH|PUT|DELETE)' "$GH_STUB_LOG"
}

@test "DEV_LEAD_DRY_RUN is honored as an alias for DRY_RUN" {
  write_config 3 9
  stub_open_prs 7
  DEV_LEAD_DRY_RUN=true run_gate "claude"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}

# --------------------------------------------------------------------------
# Counting honors exemptions: exempt-actor and exempt-labeled PRs in the queue
# do not count toward the org-wide cap (ADR §7.4).
# --------------------------------------------------------------------------
@test "exempt-actor and exempt-labeled open PRs are not counted toward the cap" {
  write_config 3 9
  # 2 countable + 3 non-countable (1 exempt actor, 2 security-labeled) = 5 total,
  # but only 2 count, which is under the cap of 3 -> allow.
  export GH_STUB_STDOUT
  GH_STUB_STDOUT="$(jq -nc '[
    { author: { login: "donpetry-bot" }, labels: [] },
    { author: { login: "donpetry-bot" }, labels: [] },
    { author: { login: "dependabot[bot]" }, labels: [] },
    { author: { login: "donpetry-bot" }, labels: [{ name: "security" }] },
    { author: { login: "donpetry-bot" }, labels: [{ name: "security" }] }
  ]')"
  run_gate "claude"
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
}
