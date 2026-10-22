#!/usr/bin/env bats
# Tests for stub_pin_acceptable() in scripts/compliance-audit.sh — the pin-match
# used by check_centralized_workflow_stubs.
#
# During the #482 channel migration a stub is compliant if it pins the reusable
# at the canonical <name>/stable channel OR, transitionally, an accepted legacy
# @vN ref — so the audit neither flags nor reverts a stub mid-migration. A SHA
# pin, a commented-out line, or the wrong reusable must NOT satisfy the check.
#
# #657 F5 (#861): the RING acceptance in check_centralized_workflow_stubs now
# REQUIRES the major-scoped v<M>-<tier> form — a bare <agent>/<tier> pin on a
# stable-tier repo is drift, and only a tier-correct v<M>-<tier> (any major) is
# accepted. The pure helpers stub_pin_acceptable (bare) / ring_major_form_acceptable
# (v-form) are unchanged and still unit-tested below; the integration section at
# the end exercises the whole-check decision through a mocked gh_api.
#
# The script is sourced in an isolated subshell (its `main` is guarded, so
# sourcing only defines functions) and the real helper is exercised directly.

bats_require_minimum_version 1.5.0

SCRIPT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/scripts/compliance-audit.sh"

# Run the real helper with the given uses-line and (canonical, legacy) spec.
accept() {
  local line="$1" canonical="$2" legacy="$3"
  run bash -c 'source "$1" >/dev/null 2>&1; stub_pin_acceptable "$2" agent-shield-reusable "$3" "$4"' \
    _ "$SCRIPT" "$line" "$canonical" "$legacy"
}

C="agent-shield/stable"   # canonical channel for these tests (a stable-tier repo)
# Retained grace = the other ring channels (a repo pinned to a higher tier than
# its own is never flagged). The pre-ring @v1/@v2 grace was dropped in #870.
L="agent-shield/next,agent-shield/ring0,agent-shield/ring1"
R="petry-projects/.github/.github/workflows/agent-shield-reusable.yml"

@test "canonical channel pin is accepted" {
  accept "    uses: $R@$C" "$C" "$L"
  [ "$status" -eq 0 ]
}

@test "a higher-tier ring channel is accepted (promotion grace)" {
  accept "    uses: $R@agent-shield/ring1" "$C" "$L"
  [ "$status" -eq 0 ]
}

@test "a pre-ring @v1 pin is now rejected (grace dropped, #870)" {
  accept "    uses: $R@v1" "$C" "$L"
  [ "$status" -ne 0 ]
}

@test "a pre-ring @v2 pin is now rejected (grace dropped, #870)" {
  accept "    uses: $R@v2" "$C" "$L"
  [ "$status" -ne 0 ]
}

@test "a SHA pin is rejected (must move to the channel)" {
  accept "    uses: $R@376a4fcb1117444595e3e702fa450873d0e54310 # v2" "$C" "$L"
  [ "$status" -ne 0 ]
}

@test "a commented-out uses line does not satisfy the check" {
  accept "    # uses: $R@$C" "$C" "$L"
  [ "$status" -ne 0 ]
}

@test "the wrong reusable is rejected" {
  accept "    uses: petry-projects/.github/.github/workflows/dependency-audit-reusable.yml@v1" "$C" "$L"
  [ "$status" -ne 0 ]
}

@test "with no legacy grace, only the canonical ref is accepted" {
  # A fixed-pin entry with an empty legacy CSV: only the exact canonical ref
  # passes. (feature-ideation used this shape before #606 channel-ified it.)
  accept "    uses: $R@v1" "v1" ""
  [ "$status" -eq 0 ]
  accept "    uses: $R@v2" "v1" ""
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# #606 — feature-ideation and pr-auto-review are now RING reusables. Their
# stubs resolve the canonical pin through the same ring model as the others,
# so a `<name>/stable` channel pin on a stable-tier repo is accepted and the
# pre-ring @v1/@v2 pin is rejected (grace dropped, #870).
# ---------------------------------------------------------------------------
accept_reusable() {
  local reusable="$1" line="$2" canonical="$3" legacy="$4"
  run bash -c 'source "$1" >/dev/null 2>&1; stub_pin_acceptable "$2" "$3" "$4" "$5"' \
    _ "$SCRIPT" "$line" "$reusable" "$canonical" "$legacy"
}

@test "feature-ideation stub: @feature-ideation/stable accepted, @v1 rejected (#606)" {
  local reusable="feature-ideation-reusable"
  local ref="petry-projects/.github/.github/workflows/${reusable}.yml"
  accept_reusable "$reusable" "    uses: $ref@feature-ideation/stable" "feature-ideation/stable" ""
  [ "$status" -eq 0 ]
  accept_reusable "$reusable" "    uses: $ref@v1" "feature-ideation/stable" ""
  [ "$status" -ne 0 ]
}

@test "pr-auto-review stub: @pr-auto-review/stable accepted, @v2 rejected (#606)" {
  local reusable="pr-auto-review-reusable"
  local ref="petry-projects/.github/.github/workflows/${reusable}.yml"
  accept_reusable "$reusable" "    uses: $ref@pr-auto-review/stable" "pr-auto-review/stable" ""
  [ "$status" -eq 0 ]
  accept_reusable "$reusable" "    uses: $ref@v2" "pr-auto-review/stable" ""
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# #657 F3 — ring_major_form_acceptable(): the RING branch of
# check_centralized_workflow_stubs additionally accepts a stub pinned to the
# major-scoped form <agent>/v<M>-<tier-for-repo> for ANY major M, as long as the
# TIER matches the repo's ring tier. This is backward-compatible: it ADDS the
# v<M>- form without removing the bare-tier grace (F5 migrates consumers later),
# so today's bare-tier fleet keeps passing. Wrong tier in the v-form is drift.
#
# The helper returns status 0 when the v-form ref is acceptable, non-zero
# otherwise (bare-tier refs are handled by stub_pin_acceptable, not here).
# ---------------------------------------------------------------------------
maj_accept() {
  local reusable="$1" line="$2" repo="$3"
  local chan="${reusable%-reusable}"
  run bash -c 'source "$1" >/dev/null 2>&1; ring_major_form_acceptable "$2" "$3" "$4" "$5"' \
    _ "$SCRIPT" "$line" "$reusable" "$chan" "$repo"
}

@test "v-form: v1-<tier> on a stable-tier repo is accepted (#657 F3)" {
  maj_accept "agent-shield-reusable" "    uses: $R@agent-shield/v1-stable" "markets"
  [ "$status" -eq 0 ]
}

@test "v-form: any major M with the correct tier is accepted (#657 F3)" {
  maj_accept "agent-shield-reusable" "    uses: $R@agent-shield/v7-stable" "markets"
  [ "$status" -eq 0 ]
  # An older major on the correct tier is NOT drift.
  maj_accept "agent-shield-reusable" "    uses: $R@agent-shield/v1-ring1" "TalkTerm"
  [ "$status" -eq 0 ]
}

@test "v-form: wrong tier for the repo is drift even in the v-form (#657 F3)" {
  # v1-ring0 on a stable-tier repo — right form, wrong tier → not accepted here.
  maj_accept "agent-shield-reusable" "    uses: $R@agent-shield/v1-ring0" "markets"
  [ "$status" -ne 0 ]
}

@test "v-form: a bare-tier pin is not matched by the v-form helper (#657 F3)" {
  # Bare <tier> carries no major, so the v-form helper declines it; the bare
  # grace (stub_pin_acceptable) is what keeps it clean during the transition.
  maj_accept "agent-shield-reusable" "    uses: $R@agent-shield/stable" "markets"
  [ "$status" -ne 0 ]
}

@test "v-form: a commented-out v-form line does not satisfy the helper (#657 F3)" {
  maj_accept "agent-shield-reusable" "    # uses: $R@agent-shield/v1-stable" "markets"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# #657 F5 (#861) — integration: check_centralized_workflow_stubs now REQUIRES the
# v<M>-<tier> form for RING reusables. A bare <agent>/<tier> pin on a stable-tier
# repo is drift (FLAGGED); a tier-correct v<M>-<tier> (any major) is accepted; a
# wrong-tier v-form is still drift. These exercise the whole check by sourcing the
# script and mocking gh_api so the pin decision surfaces as a FINDING, not just a
# pure-helper return.
# ---------------------------------------------------------------------------
stub_check() {  # <workflow-yaml> — run the check for a stable-tier repo (markets)
  FIXTURE_B64=$(printf '%s' "$1" | base64 | tr -d '\n'); export FIXTURE_B64
  run bash -c '
    source "$1" >/dev/null 2>&1
    ORG=petry-projects
    gh_api() {
      case "$1" in
        */contents/.github/workflows) printf "agent-shield.yml\n" ;;
        */contents/.github/workflows/agent-shield.yml) printf "%s" "$FIXTURE_B64" ;;
      esac
    }
    add_finding() { printf "FLAGGED:%s\n" "$3"; }
    check_centralized_workflow_stubs markets
  ' _ "$SCRIPT"
}

@test "F5 integration: a bare <agent>/<tier> RING pin is FLAGGED on a stable repo (#861)" {
  stub_check "jobs:
  agent-shield:
    uses: $R@agent-shield/stable
    secrets: inherit"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'FLAGGED:non-stub-agent-shield.yml'
}

@test "F5 integration: a tier-correct v<M>-<tier> RING pin is accepted (no finding) (#861)" {
  stub_check "jobs:
  agent-shield:
    uses: $R@agent-shield/v3-stable
    secrets: inherit"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "F5 integration: a wrong-tier v<M> RING pin is FLAGGED (#861)" {
  stub_check "jobs:
  agent-shield:
    uses: $R@agent-shield/v3-ring0
    secrets: inherit"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'FLAGGED:non-stub-agent-shield.yml'
}

# ---------------------------------------------------------------------------
# ring_tier_for_repo() — maps a (repo) to its canary-ring tier for a given AGENT
# (epic #495; agent-aware since #1092). The tier is derived from the agent's
# rings[] in canary-rings.json, so it takes the agent as its first argument.
# ---------------------------------------------------------------------------
tier() {  # <agent> <repo>
  run bash -c 'source "$1" >/dev/null 2>&1; ring_tier_for_repo "$2" "$3"' _ "$SCRIPT" "$1" "$2"
}

@test "ring tier: .github-private is next" {
  tier "agent-shield" ".github-private"
  [ "$status" -eq 0 ]
  [ "$output" = "next" ]
}

@test "ring tier: .github is ring0 (dogfood)" {
  tier "agent-shield" ".github"
  [ "$output" = "ring0" ]
}

@test "ring tier: TalkTerm and bmad-bgreat-suite are ring1" {
  tier "agent-shield" "TalkTerm"
  [ "$output" = "ring1" ]
  tier "agent-shield" "bmad-bgreat-suite"
  [ "$output" = "ring1" ]
}

@test "ring tier: any other repo defaults to stable" {
  tier "agent-shield" "markets"
  [ "$output" = "stable" ]
  tier "agent-shield" "broodly"
  [ "$output" = "stable" ]
}

# #1092: markets is ring1 for apply-repo-settings ONLY, stable for everyone else.
@test "ring tier: markets is ring1 for apply-repo-settings, stable otherwise (#1092)" {
  tier "apply-repo-settings" "markets"
  [ "$output" = "ring1" ]
  tier "dev-lead" "markets"
  [ "$output" = "stable" ]
}
