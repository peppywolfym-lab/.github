#!/usr/bin/env bats
# Unit tests for scripts/lib/ring-pins.sh — the canary-ring pin model shared by
# compliance-audit.sh (check_centralized_workflow_stubs) and
# deploy-standard-workflows.sh (is_already_compliant). The lib has no `main`, so
# it is sourced directly and its pure helpers are exercised in-process.

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/ring-pins.sh"
}

# #1092: ring_tier_for_repo is now agent-aware and derived from canary-rings.json.
# The tier is resolved from the given agent's rings[], falling back to the ring
# whose members contain "*" (today: stable). The meta-repo tiers are identical for
# every agent (next/ring0 are host-relative in the registry), so a representative
# agent exercises them.
@test "ring_tier_for_repo maps each tier (agent-aware, #1092)" {
  [ "$(ring_tier_for_repo agent-shield .github-private)" = "next" ]
  [ "$(ring_tier_for_repo agent-shield .github)" = "ring0" ]
  [ "$(ring_tier_for_repo agent-shield TalkTerm)" = "ring1" ]
  [ "$(ring_tier_for_repo agent-shield bmad-bgreat-suite)" = "ring1" ]
  [ "$(ring_tier_for_repo agent-shield markets)" = "stable" ]
  [ "$(ring_tier_for_repo agent-shield anything-else)" = "stable" ]
}

# #1092 AC4 — the point cases the issue enumerates verbatim.
@test "ring_tier_for_repo: markets is ring1 ONLY for apply-repo-settings (#1092 AC4)" {
  [ "$(ring_tier_for_repo apply-repo-settings markets)" = "ring1" ]
  [ "$(ring_tier_for_repo dev-lead markets)" = "stable" ]
  # markets is stable for every other agent, too.
  [ "$(ring_tier_for_repo auto-rebase markets)" = "stable" ]
  [ "$(ring_tier_for_repo pr-auto-review markets)" = "stable" ]
}

@test "ring_tier_for_repo: TalkTerm/.github/.github-private are agent-invariant (#1092 AC4)" {
  local a
  for a in $(jq -r '(.agents // {}) | keys[]?' "${REPO_ROOT}/standards/canary-rings.json"); do
    [ "$(ring_tier_for_repo "$a" TalkTerm)" = "ring1" ]
    [ "$(ring_tier_for_repo "$a" .github)" = "ring0" ]
    [ "$(ring_tier_for_repo "$a" .github-private)" = "next" ]
  done
}

# #1092 AC2 — the whole risk of the change: every agent EXCEPT apply-repo-settings
# must resolve identically to the old agent-agnostic hardcoded logic, for every
# repo. The old logic is inlined here as an independent oracle (NOT the impl).
@test "ring_tier_for_repo: no behaviour change for the other 15 agents (#1092 AC2)" {
  old_tier() {  # the pre-#1092 hardcoded case statement, verbatim
    case "$1" in
      .github-private)              printf 'next'  ;;
      .github)                      printf 'ring0' ;;
      TalkTerm | bmad-bgreat-suite) printf 'ring1' ;;
      *)                            printf 'stable' ;;
    esac
  }
  local a repo
  local -a repos=(.github-private .github TalkTerm bmad-bgreat-suite markets
                  broodly ContentTwin google-app-scripts some-unlisted-repo)
  for a in $(jq -r '(.agents // {}) | keys[]?' "${REPO_ROOT}/standards/canary-rings.json"); do
    [ "$a" = "apply-repo-settings" ] && continue
    for repo in "${repos[@]}"; do
      [ "$(ring_tier_for_repo "$a" "$repo")" = "$(old_tier "$repo")" ] \
        || { echo "drift: $a $repo -> $(ring_tier_for_repo "$a" "$repo") (old: $(old_tier "$repo"))"; false; }
    done
  done
  # apply-repo-settings is the ONE intended difference: markets moves to ring1.
  [ "$(ring_tier_for_repo apply-repo-settings markets)" != "$(old_tier markets)" ]
  [ "$(ring_tier_for_repo apply-repo-settings markets)" = "ring1" ]
}

# #1092 AC4 — the registry-conformance regression (analogue of #1088's
# "RING_REUSABLES equals the registry"): for every (agent, repo) pair the resolved
# tier equals an INDEPENDENT derivation straight from canary-rings.json.
@test "ring_tier_for_repo equals the canary-rings.json derivation for every pair (#1092 AC4)" {
  local rings="${REPO_ROOT}/standards/canary-rings.json"
  # Independent oracle: expand $host/$org_infra tokens, return the first ring
  # (registry order = tier order) whose members contain the repo basename, else
  # the ring whose members contain "*".
  expected_tier() {
    jq -r --arg a "$1" --arg repo "${2##*/}" '
      .agents[$a] as $ag
      | ($ag.host | sub(".*/";"")) as $host
      | ([.org_infra_repos[]? | sub(".*/";"")] - [$host]) as $orginfra
      | ( $ag.rings
          | map({ channel,
                  m: (reduce (.members[]?) as $x ([];
                        if   $x == "$host"      then . + [$host]
                        elif $x == "$org_infra" then . + $orginfra
                        else . + [($x | sub(".*/";""))] end)) }) ) as $r
      | ( ([$r[] | select(.m | index($repo)) | .channel][0])
          // ([$r[] | select(.m | index("*")) | .channel][0]) )' "$rings"
  }
  # The repo universe: every explicitly-named member plus the meta-repos and a
  # couple of fleet repos not named in any ring.
  local -a repos
  mapfile -t repos < <(
    { jq -r '.agents[].rings[].members[] | select(startswith("$")|not) | select(. != "*") | sub(".*/";"")' "$rings"
      printf '%s\n' .github .github-private markets broodly some-unlisted-repo
    } | sort -u)
  local a repo want got
  for a in $(jq -r '(.agents // {}) | keys[]?' "$rings"); do
    for repo in "${repos[@]}"; do
      want="$(expected_tier "$a" "$repo")"
      got="$(ring_tier_for_repo "$a" "$repo")"
      [ "$got" = "$want" ] || { echo "mismatch: $a $repo -> got=$got want=$want"; false; }
    done
  done
}

# #1096 — fail CLOSED on an unreadable/corrupt registry rather than silently
# returning `stable`. A missing or unparseable source of truth must surface as an
# error (non-zero) so the audit/deploy cannot accept or emit incorrect stable pins
# during an infra outage — mirroring ring_host_current_channel_major's fail-closed
# probe (#870). A genuine no-match on a READABLE registry still falls back to stable.
@test "ring_tier_for_repo: fails closed on an unreadable/corrupt registry (#1096)" {
  RING_PINS_REGISTRY="${BATS_TEST_TMPDIR}/does-not-exist.json" \
    run ring_tier_for_repo agent-shield markets
  [ "$status" -eq 3 ]
  [[ "$output" != "stable" ]]
  printf 'not-json{' > "${BATS_TEST_TMPDIR}/corrupt.json"
  RING_PINS_REGISTRY="${BATS_TEST_TMPDIR}/corrupt.json" \
    run ring_tier_for_repo agent-shield markets
  [ "$status" -eq 3 ]
  [[ "$output" != "stable" ]]
  # a readable registry with a genuine no-match (unknown agent) still returns stable
  run ring_tier_for_repo not-a-real-agent markets
  [ "$status" -eq 0 ]
  [ "$output" = "stable" ]
}

@test "ring_is_ring_reusable recognises the ring set (incl. dev-lead)" {
  ring_is_ring_reusable auto-rebase
  ring_is_ring_reusable pr-review-mention
  ring_is_ring_reusable dev-lead
  # channel-ified in #606 (Story B of the shim-identity epic #604)
  ring_is_ring_reusable feature-ideation
  ring_is_ring_reusable pr-auto-review
  # #1088: the 7 agents that had drifted OUT of RING_REUSABLES are all registered
  # in canary-rings.json, so they are ring-managed too. Before #1088 they returned
  # false here, so emit_ref_for returned empty and the deploy shipped their template
  # verbatim (hardcoded @<agent>/v1-stable) instead of the repo's tier channel.
  ring_is_ring_reusable add-to-project
  ring_is_ring_reusable apply-repo-settings
  ring_is_ring_reusable ci-failure-analyst
  ring_is_ring_reusable idea-enhancer
  ring_is_ring_reusable idea-triage
  ring_is_ring_reusable initiative-planner
  ring_is_ring_reusable persona-mention
  # a name that is NOT a registered agent is still not ring-managed
  ! ring_is_ring_reusable not-a-real-agent
}

# #1088 (AC1/AC3): RING_REUSABLES must not drift from the registry. It MUST equal
# `.agents | keys` in standards/canary-rings.json so every REGISTERED agent is
# ring-managed by the deploy sweep (emit_ref_for) and the audit — mirroring the
# "the agent choice list agrees with the registry" assertion in canary_rollout.bats.
@test "RING_REUSABLES equals the canary-rings.json agent registry (#1088)" {
  local reusables_sorted registry_sorted
  reusables_sorted="$(printf '%s\n' "${RING_REUSABLES[@]}" | sort -u)"
  registry_sorted="$(jq -r '(.agents // {}) | keys[]?' "${REPO_ROOT}/standards/canary-rings.json" | sort -u)"
  [ -n "$reusables_sorted" ]
  [ "$reusables_sorted" = "$registry_sorted" ]
}

@test "ring_canonical_ref: feature-ideation and pr-auto-review resolve to tier channels (#606)" {
  [ "$(ring_canonical_ref feature-ideation markets)" = "feature-ideation/stable" ]
  [ "$(ring_canonical_ref feature-ideation TalkTerm)" = "feature-ideation/ring1" ]
  [ "$(ring_canonical_ref pr-auto-review markets)" = "pr-auto-review/stable" ]
  [ "$(ring_canonical_ref pr-auto-review TalkTerm)" = "pr-auto-review/ring1" ]
}

@test "ring_canonical_ref is the repo's tier channel" {
  [ "$(ring_canonical_ref agent-shield TalkTerm)" = "agent-shield/ring1" ]
  [ "$(ring_canonical_ref agent-shield markets)" = "agent-shield/stable" ]
  [ "$(ring_canonical_ref dev-lead .github-private)" = "dev-lead/next" ]
}

# #1092 — end-to-end: because the tier is now agent-aware, ring_canonical_ref (and
# thus the deploy/audit that consume it) computes markets as apply-repo-settings's
# ring1 channel, but every other agent still gets markets/stable.
@test "ring_canonical_ref: apply-repo-settings markets resolves to ring1, others to stable (#1092)" {
  [ "$(ring_canonical_ref apply-repo-settings markets)" = "apply-repo-settings/ring1" ]
  [ "$(ring_canonical_ref apply-repo-settings markets 1)" = "apply-repo-settings/v1-ring1" ]
  [ "$(ring_canonical_ref auto-rebase markets)" = "auto-rebase/stable" ]
}

@test "ring_canonical_ref: major-aware form yields <agent>/v<major>-<tier> (#657 F3)" {
  # A major argument opts the ref into the major-scoped channel line; the tier
  # is still the repo's ring tier.
  [ "$(ring_canonical_ref agent-shield markets 2)" = "agent-shield/v2-stable" ]
  [ "$(ring_canonical_ref agent-shield TalkTerm 2)" = "agent-shield/v2-ring1" ]
  [ "$(ring_canonical_ref dev-lead .github-private 5)" = "dev-lead/v5-next" ]
  # No major argument is backward-compatible: the legacy bare-tier ref.
  [ "$(ring_canonical_ref agent-shield markets)" = "agent-shield/stable" ]
}

@test "ring_pinned_major: extracts M from v<M>-<tier>, empty for bare tier (#657 F3)" {
  [ "$(ring_pinned_major agent-shield/v3-stable)" = "3" ]
  [ "$(ring_pinned_major agent-shield/v12-ring1)" = "12" ]
  # Bare-tier (legacy/unmajored) refs carry no major.
  [ -z "$(ring_pinned_major agent-shield/stable)" ]
  [ -z "$(ring_pinned_major agent-shield/ring0)" ]
}

@test "ring_accepted_refs: canonical first, then the ring-channel grace" {
  run ring_accepted_refs auto-rebase TalkTerm
  [ "${lines[0]}" = "auto-rebase/ring1" ]                 # canonical = tier channel
  printf '%s\n' "${lines[@]}" | grep -qx "auto-rebase/stable"  # higher tier accepted
  # the pre-ring @v1/@v2 grace was dropped in #870 — migration complete
  ! printf '%s\n' "${lines[@]}" | grep -qx "v1"
  ! printf '%s\n' "${lines[@]}" | grep -qx "v2"
}

@test "ring_legacy_csv excludes the canonical and comma-joins the ring channels" {
  run ring_legacy_csv auto-rebase markets
  [[ "$output" == *"auto-rebase/next"* ]]
  [[ "$output" == *"auto-rebase/ring1"* ]]
  [[ "$output" != *"auto-rebase/stable"* ]]
  # no pre-ring grace
  [[ "$output" != *"v1"* ]]
  [[ "$output" != *"v2"* ]]
}

# ══ major-scoped channels tooling: F5 shared helpers (epic #657) ═══════════════

@test "ring_highest_major: picks the MAJOR of the highest strict semver" {
  [ "$(ring_highest_major 1.2.3 2.0.1 1.9.9)" = "2" ]
  [ "$(ring_highest_major 10.0.0 9.9.9)" = "10" ]
  # tolerate a leading v on the token
  [ "$(ring_highest_major v3.1.0 v2.9.9)" = "3" ]
}

@test "ring_highest_major: ignores non-semver tokens; empty when none valid" {
  [ "$(ring_highest_major 2.0.0 not-a-version 1.0.0)" = "2" ]
  [ -z "$(ring_highest_major)" ]
  [ -z "$(ring_highest_major 2-next latest '')" ]
}

# ── channel major (#870): the CALLER-CONTRACT major, not the release major ──────

@test "ring_highest_channel_major: picks the highest v<M>-<tier> channel token" {
  # channel tokens are `<M>-<tier>` (the `v` prefix is already stripped by the
  # caller, mirroring ring_host_current_channel_major's sed).
  [ "$(ring_highest_channel_major 1-stable 1-ring1 1-next)" = "1" ]
  [ "$(ring_highest_channel_major 2-stable 3-ring0 2-ring1)" = "3" ]
  [ "$(ring_highest_channel_major 10-stable 9-ring1)" = "10" ]
}

@test "ring_highest_channel_major: ignores RELEASE semver; empty when no channel token (#870)" {
  # The dev-lead regression: a high release major (14.0.0) must NOT be picked up —
  # only the channel tokens count, so v1 is the caller-contract major.
  [ "$(ring_highest_channel_major 14.0.0 1-stable 1-ring1)" = "1" ]
  # release-only input (no channel token) yields empty → callers fall back to bare.
  [ -z "$(ring_highest_channel_major 14.0.0 13.9.9)" ]
  [ -z "$(ring_highest_channel_major)" ]
  # a bare tier (no v<M>- major) is not a channel-major token.
  [ -z "$(ring_highest_channel_major stable ring1)" ]
}

@test "ring_repin_uses: rewrites the reusable uses: ref, preserving the trailing comment" {
  local stub="jobs:
  auto-rebase:
    uses: petry-projects/.github/.github/workflows/auto-rebase-reusable.yml@auto-rebase/stable  # NOSONAR keep
    secrets: inherit"
  run bash -c 'source "'"$REPO_ROOT"'/scripts/lib/ring-pins.sh"; ring_repin_uses auto-rebase auto-rebase/v2-stable <<<"$1"' _ "$stub"
  [ "$status" -eq 0 ]
  [[ "$output" == *"auto-rebase-reusable.yml@auto-rebase/v2-stable  # NOSONAR keep"* ]]
  [[ "$output" != *"@auto-rebase/stable "* ]]
}

@test "ring_repin_uses: also rewrites a matching agent_ref (dev-lead stub)" {
  local stub="    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/stable
    with:
      agent_ref: dev-lead/stable"
  run bash -c 'source "'"$REPO_ROOT"'/scripts/lib/ring-pins.sh"; ring_repin_uses dev-lead dev-lead/v4-ring1 <<<"$1"' _ "$stub"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev-lead-reusable.yml@dev-lead/v4-ring1"* ]]
  [[ "$output" == *"agent_ref: dev-lead/v4-ring1"* ]]
}

# The apply-repo-settings stub forwards a checkout_ref input that MUST stay in
# lockstep with the uses: channel pin (the reusable checks out .github at that
# ref). Re-pinning uses: without also re-pinning checkout_ref would run the
# ring-tier reusable while checking out the stable scripts — a version mismatch.
@test "ring_repin_uses: also rewrites a matching checkout_ref in lockstep, preserving the trailing comment" {
  local stub="    uses: petry-projects/.github/.github/workflows/apply-repo-settings-reusable.yml@apply-repo-settings/v1-stable  # NOSONAR keep
    with:
      checkout_ref: apply-repo-settings/v1-stable  # keep in lockstep with the uses: channel pin"
  run bash -c 'source "'"$REPO_ROOT"'/scripts/lib/ring-pins.sh"; ring_repin_uses apply-repo-settings apply-repo-settings/v1-ring1 <<<"$1"' _ "$stub"
  [ "$status" -eq 0 ]
  [[ "$output" == *"apply-repo-settings-reusable.yml@apply-repo-settings/v1-ring1  # NOSONAR keep"* ]]
  [[ "$output" == *"checkout_ref: apply-repo-settings/v1-ring1  # keep in lockstep with the uses: channel pin"* ]]
  [[ "$output" != *"apply-repo-settings/v1-stable"* ]]
}

@test "ring_vform_tier_aligned: true only for the repo's tier v-form (any major)" {
  ring_vform_tier_aligned auto-rebase/v2-ring1 auto-rebase TalkTerm    # ring1 repo
  ring_vform_tier_aligned auto-rebase/v9-stable auto-rebase markets    # stable repo
  # wrong tier for the repo → not aligned
  ! ring_vform_tier_aligned auto-rebase/v2-ring0 auto-rebase TalkTerm
  # bare tier (no v<M>-) → not a v-form
  ! ring_vform_tier_aligned auto-rebase/ring1 auto-rebase TalkTerm
}

# ── meta-repo self-host vs channel-consumer discrimination (#704) ──────────────

@test "ring_stub_selfhosts: true for a local ./ self-host ref" {
  # .github hosts agent-shield's reusable itself, so its own stub uses a local ref.
  local stub="jobs:
  agent-shield:
    uses: ./.github/workflows/agent-shield-reusable.yml  # local ref — always current
    secrets: inherit"
  run ring_stub_selfhosts agent-shield <<< "$stub"
  [ "$status" -eq 0 ]
}

@test "ring_stub_selfhosts: false for a channel-pinned consumer ref" {
  # .github does NOT host dev-lead (it lives in .github-private) — its stub is a
  # channel consumer, so it must be re-pinned, not treated as self-host.
  local stub="jobs:
  dev-lead:
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/ring0
    with:
      agent_ref: dev-lead/ring0"
  run ring_stub_selfhosts dev-lead <<< "$stub"
  [ "$status" -ne 0 ]
}

@test "ring_stub_selfhosts: false when the stub does not reference the reusable at all" {
  local stub="jobs:
  something-else:
    uses: ./.github/workflows/other-reusable.yml"
  run ring_stub_selfhosts dev-lead <<< "$stub"
  [ "$status" -ne 0 ]
}

# ── gh-backed channel-major / tag-existence helpers (#870) ──────────────────────
# These read the host repo's tags via `gh api`, so a fake gh is put on PATH. It
# serves matching-refs (already `--jq '.[]?.ref'`-projected, one ref per line) and
# single-ref existence probes.

_install_gh_stub() {
  local bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "api" ]; then
  case "$2" in
    *git/ref/tags/*)
      tag="${2##*/git/ref/tags/}"
      printf '%s\n' "${GH_EXISTING_TAGS:-}" | grep -qxF "$tag" && exit 0
      printf 'Not Found\n' >&2
      exit 1 ;;
    *matching-refs/tags/*)
      [ -n "${GH_MATCHING_REFS:-}" ] && printf '%s\n' "${GH_MATCHING_REFS}"
      exit 0 ;;
  esac
fi
exit 0
STUB
  chmod +x "$bin/gh"
  PATH="${bin}:${PATH}"; export PATH
}

@test "ring_host_current_channel_major: picks v1 for dev-lead despite a v14 release tag (#870)" {
  export GH_MATCHING_REFS="refs/tags/dev-lead/v14.0.0
refs/tags/dev-lead/v1-stable
refs/tags/dev-lead/v1-next
refs/tags/dev-lead/v1-ring0
refs/tags/dev-lead/v1-ring1"
  _install_gh_stub
  [ "$(ring_host_current_channel_major petry-projects/.github-private dev-lead)" = "1" ]
}

@test "ring_host_current_channel_major: empty when only release tags exist (#870)" {
  export GH_MATCHING_REFS="refs/tags/auto-rebase/v2.3.1
refs/tags/auto-rebase/v1.0.0"
  _install_gh_stub
  [ -z "$(ring_host_current_channel_major petry-projects/.github auto-rebase)" ]
}

@test "ring_tag_exists: true only for a ref present on the host (#870)" {
  export GH_EXISTING_TAGS="dev-lead/v1-ring1
dev-lead/v1-stable"
  _install_gh_stub
  run ring_tag_exists petry-projects/.github-private dev-lead/v1-ring1
  [ "$status" -eq 0 ]
  run ring_tag_exists petry-projects/.github-private dev-lead/v1-ring0
  [ "$status" -ne 0 ]
}

# ── ring_reusable_file / ring_caller_stub — registry-derived names (#1166) ──
# pinned-version-report.sh scans each ring agent's caller stub for the reusable it
# pins. Both filenames are derived from the registry so a grandfathered agent that
# breaks the `<agent>.yml` / `<agent>-reusable.yml` convention (pr-review: engine
# `pr-review.yml` invoked by `pr-review-trigger.yml`, #1127) is matched rather than
# silently omitted from the report.
@test "ring_reusable_file: convention for a normally-named agent (#1166)" {
  [ "$(ring_reusable_file dev-lead)" = "dev-lead-reusable.yml" ]
  [ "$(ring_reusable_file pr-auto-review)" = "pr-auto-review-reusable.yml" ]
}

@test "ring_reusable_file: grandfathered engine name for pr-review (#1166)" {
  # Must be the legacy `pr-review.yml`, NOT the conventional `pr-review-reusable.yml` —
  # the report's `uses:` matcher keys on this, and the wrong suffix omits pr-review.
  [ "$(ring_reusable_file pr-review)" = "pr-review.yml" ]
}

@test "ring_reusable_file: falls back to the convention for an unknown agent (#1166)" {
  [ "$(ring_reusable_file not-an-agent)" = "not-an-agent-reusable.yml" ]
}

@test "ring_caller_stub: convention for an agent without an override (#1166)" {
  [ "$(ring_caller_stub dev-lead)" = ".github/workflows/dev-lead.yml" ]
  [ "$(ring_caller_stub not-an-agent)" = ".github/workflows/not-an-agent.yml" ]
}

@test "ring_caller_stub: registry caller_stub override for pr-review (#1166)" {
  # The engine `pr-review.yml` is workflow_call-only and carries no self-referencing
  # `uses:`; the real pinned caller is the separate `pr-review-trigger.yml` stub.
  [ "$(ring_caller_stub pr-review)" = ".github/workflows/pr-review-trigger.yml" ]
}
