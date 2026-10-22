#!/usr/bin/env bats
# F5 (epic #657) tests for scripts/deploy-standard-workflows.sh:
#   - a (re)deployed RING stub is pinned to the major-scoped `@<agent>/v<M>-<tier>`
#     form when the agent has a release; the bare `@<agent>/<tier>` form otherwise.
#   - the deploy sweep's drift check (is_already_compliant) honors the `v<M>-` prefix
#     the same way compliance-audit does: a tier-correct v-form stub is compliant,
#     a wrong-tier v-form is still drift.
#
# All runs are --dry-run (no mutating gh calls) against a single --repo/--workflow so
# they are deterministic. A fake `gh` returns the reusable's CHANNEL tags (for the
# caller-contract major derivation — #870), the target repo's existing stub content,
# and single-ref existence probes (the assert-exists guard).

setup() {
  TT_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/deploy-standard-workflows.sh"
}

teardown() { rm -rf "$TT_TMP"; }

# Install a fake gh.
#   GH_MATCHING_REFS newline-separated `refs/tags/<agent>/…` for matching-refs. The
#                    major is derived from the CHANNEL tags (`<agent>/v<M>-<tier>`),
#                    NOT the release tags (`<agent>/vX.Y.Z`) — the #870 fix. Unset/no
#                    channel tag → the agent has no channel major → bare form.
#   GH_CONTENT_B64   base64 of the existing stub (unset → contents 404 = missing stub).
#   GH_EXISTING_TAGS newline-separated `<agent>/<ref>` the assert-exists probe treats
#                    as resolvable. UNSET → every ref resolves (legacy default, so a
#                    test that does not model tag existence is unaffected).
install_gh_stub() {
  local bin="${TT_TMP}/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "api" ]; then
  case "$2" in
    *git/ref/tags/*)
      # Single-ref existence probe (ring_tag_exists). Unset GH_EXISTING_TAGS means
      # "don't model existence" → every ref resolves.
      [ -z "${GH_EXISTING_TAGS:-}" ] && exit 0
      tag="${2##*/git/ref/tags/}"
      printf '%s\n' "$GH_EXISTING_TAGS" | grep -qxF "$tag" && exit 0
      printf 'Not Found\n' >&2
      exit 1 ;;
    *matching-refs/tags/*)
      [ -n "${GH_MATCHING_REFS:-}" ] && printf '%s\n' "${GH_MATCHING_REFS}"
      exit 0 ;;
    *contents*)
      if [ -n "${GH_CONTENT_B64:-}" ]; then
        printf '{"sha":"abc123","content":"%s"}' "$GH_CONTENT_B64"
        exit 0
      fi
      exit 1 ;;   # simulate 404 — stub absent
  esac
fi
exit 0
STUB
  chmod +x "$bin/gh"
  PATH="${bin}:${PATH}"; export PATH
}

# Channel tags for an agent at major <M> across every ring tier — the caller-contract
# tags a deployed stub can legitimately pin. Emitted as matching-refs `refs/tags/…`.
channel_refs() {  # <agent> <M> [extra refs...]
  local agent="$1" m="$2"; shift 2
  printf 'refs/tags/%s/v%s-stable\n' "$agent" "$m"
  printf 'refs/tags/%s/v%s-next\n'   "$agent" "$m"
  printf 'refs/tags/%s/v%s-ring0\n'  "$agent" "$m"
  printf 'refs/tags/%s/v%s-ring1\n'  "$agent" "$m"
  if [ "$#" -gt 0 ]; then printf '%s\n' "$@"; fi
  return 0
}

stub_pinning() {  # <ref> → base64 of a minimal auto-rebase stub pinning the reusable at <ref>
  # Carries the S7635 marker on `secrets: inherit` — the shape a converged consumer
  # holds after #875/#876, so pin-drift fixtures are not falsely tripped by the
  # marker-drift check (#877).
  local body="jobs:
  auto-rebase:
    uses: petry-projects/.github/.github/workflows/auto-rebase-reusable.yml@$1
    secrets: inherit  # NOSONAR(githubactions:S7635) first-party trusted reusable"
  base64 -w 0 <<<"$body" 2>/dev/null || base64 -b 0 <<<"$body"
}

stub_pinning_no_marker() {  # <ref> → base64 of the SAME stub but marker-less (#857 shape)
  local body="jobs:
  auto-rebase:
    uses: petry-projects/.github/.github/workflows/auto-rebase-reusable.yml@$1
    secrets: inherit"
  base64 -w 0 <<<"$body" 2>/dev/null || base64 -b 0 <<<"$body"
}

devlead_stub_pinning() {  # <ref> → base64 of a .github dev-lead CONSUMER stub pinned at <ref>
  local body="jobs:
  dev-lead:
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@$1
    with:
      agent_ref: $1
    secrets: inherit"
  base64 -w 0 <<<"$body" 2>/dev/null || base64 -b 0 <<<"$body"
}

devlead_stub_pinning_with_marker() {  # <ref> → base64 of the same stub but WITH the S7635 marker (#878 post-fix shape)
  local body="jobs:
  dev-lead:
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@$1
    with:
      agent_ref: $1
    secrets: inherit  # NOSONAR(githubactions:S7635) first-party trusted reusable"
  base64 -w 0 <<<"$body" 2>/dev/null || base64 -b 0 <<<"$body"
}

selfhost_stub() {  # <base> → base64 of a meta-repo SELF-HOST stub using a local ./ ref
  local body="jobs:
  $1:
    uses: ./.github/workflows/$1-reusable.yml  # local ref — always current
    secrets: inherit"
  base64 -w 0 <<<"$body" 2>/dev/null || base64 -b 0 <<<"$body"
}

@test "emits @<agent>/v<M>-<tier> when the reusable has a channel major" {
  GH_MATCHING_REFS="$(channel_refs auto-rebase 2 refs/tags/auto-rebase/v2.3.1)"; export GH_MATCHING_REFS
  install_gh_stub   # no GH_CONTENT_B64 → missing stub → deploy plans a (re)pin
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets --workflow auto-rebase.yml
  [ "$status" -eq 0 ]
  # markets is a stable-tier repo → v2 channel line → @auto-rebase/v2-stable
  echo "$output" | grep -qF '@auto-rebase/v2-stable'
  echo "$output" | grep -qE 'Would open PR for markets .* auto-rebase.yml'
}

@test "emits the bare @<agent>/<tier> form when the reusable has no channel tag" {
  # Release tags exist but NO channel tag → no channel major → bare form. Proves the
  # major comes from channel tags, not the release semver (#870).
  export GH_MATCHING_REFS="refs/tags/auto-rebase/v2.3.1"
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets --workflow auto-rebase.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF '@auto-rebase/stable'
  ! echo "$output" | grep -qF '@auto-rebase/v'
}

@test "drift check treats a tier-correct v<M>-tier stub as compliant (no PR)" {
  GH_MATCHING_REFS="$(channel_refs auto-rebase 2)"; export GH_MATCHING_REFS
  GH_CONTENT_B64="$(stub_pinning auto-rebase/v2-ring1)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo TalkTerm --workflow auto-rebase.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'already compliant'
  ! echo "$output" | grep -q 'Would open PR'
}

@test "drift check flags a BARE-tier stub as drift when the agent has a channel major (#861)" {
  GH_MATCHING_REFS="$(channel_refs auto-rebase 2)"; export GH_MATCHING_REFS
  # markets (stable tier) still pins the bare @auto-rebase/stable; with a v2 channel
  # major the bare form is drift → deploy re-pins to the tier v-form.
  GH_CONTENT_B64="$(stub_pinning auto-rebase/stable)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets --workflow auto-rebase.yml
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'already compliant'
  echo "$output" | grep -qF '@auto-rebase/v2-stable'
  echo "$output" | grep -qE 'Would open PR for markets .* auto-rebase.yml'
}

@test "drift check keeps a BARE-tier stub compliant when the agent has NO channel major (#861)" {
  unset GH_MATCHING_REFS   # no channel tag → no current major → bare tier stays compliant
  GH_CONTENT_B64="$(stub_pinning auto-rebase/stable)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets --workflow auto-rebase.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'already compliant'
  ! echo "$output" | grep -q 'Would open PR'
}

@test "drift check still flags a WRONG-tier v<M>-tier stub" {
  GH_MATCHING_REFS="$(channel_refs auto-rebase 2)"; export GH_MATCHING_REFS
  # v2-ring0 on TalkTerm (a ring1 repo) is the wrong tier → drift.
  GH_CONTENT_B64="$(stub_pinning auto-rebase/v2-ring0)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo TalkTerm --workflow auto-rebase.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'Would open PR for TalkTerm .* auto-rebase.yml'
}

# ── #877: a pin-correct stub that DROPPED the S7635 marker is drift ─────────────
# #875/#876 restored the `# NOSONAR(githubactions:S7635)` marker in the templates
# but did NOT touch the driver, so a re-sweep skipped already-pinned consumers
# whose stubs merged marker-less during #857 (broodminder-export, bmad-bgreat-suite,
# …) — the restored marker never reached them. A pin-correct stub MISSING the marker
# is now drift so the sweep re-deploys and restores it.

@test "#877: flags a tier-correct stub that DROPPED the S7635 marker as drift" {
  GH_MATCHING_REFS="$(channel_refs auto-rebase 2)"; export GH_MATCHING_REFS
  # Pin is tier-correct for TalkTerm (ring1) but the `secrets: inherit` line lost the
  # marker → drift → re-deploy to restore it.
  GH_CONTENT_B64="$(stub_pinning_no_marker auto-rebase/v2-ring1)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo TalkTerm --workflow auto-rebase.yml
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'already compliant'
  echo "$output" | grep -qE 'Would open PR for TalkTerm .* auto-rebase.yml'
}

@test "#877: keeps a tier-correct stub that CARRIES the S7635 marker compliant (no churn)" {
  GH_MATCHING_REFS="$(channel_refs auto-rebase 2)"; export GH_MATCHING_REFS
  GH_CONTENT_B64="$(stub_pinning auto-rebase/v2-ring1)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo TalkTerm --workflow auto-rebase.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'already compliant'
  ! echo "$output" | grep -q 'Would open PR'
}

# ── meta-repo consumer stubs (#704) ────────────────────────────────────────────
# The meta-repos (.github / .github-private) are exempt from blanket stub
# deployment because they self-host most reusables via local `./` refs. But they
# ARE channel consumers of the reusables they do NOT host — e.g. .github (ring0)
# consumes dev-lead from .github-private — and those consumer stubs must be
# re-pinned by the F5 sweep like any other consumer, or the major-scope migration
# skips them and --retire-bare stays blocked.

@test "re-pins a meta-repo's channel-pinned CONSUMER stub to the tier v<M>-form" {
  GH_MATCHING_REFS="$(channel_refs dev-lead 3)"; export GH_MATCHING_REFS
  # .github's dev-lead stub is a consumer still on the bare tier channel.
  GH_CONTENT_B64="$(devlead_stub_pinning dev-lead/ring0)"; export GH_CONTENT_B64
  install_gh_stub
  # --force so the bare-tier migration grace does not mark it already-compliant.
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --force --repo .github --workflow dev-lead.yml
  [ "$status" -eq 0 ]
  # .github is a ring0 repo → v3 channel line → @dev-lead/v3-ring0
  echo "$output" | grep -qF '@dev-lead/v3-ring0'
  echo "$output" | grep -qE 'Would open PR for \.github .* dev-lead.yml'
}

@test "leaves a meta-repo's local ./ SELF-HOST stub exempt (never re-pins it)" {
  GH_MATCHING_REFS="$(channel_refs agent-shield 2)"; export GH_MATCHING_REFS
  # .github HOSTS agent-shield's reusable — its stub uses a local ./ ref.
  GH_CONTENT_B64="$(selfhost_stub agent-shield)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --force --repo .github --workflow agent-shield.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF '.github/agent-shield.yml (exempt)'
  ! echo "$output" | grep -qi 'Would open PR'
  ! echo "$output" | grep -qF '@agent-shield/v'
}

# ── #870: derive the CHANNEL major, never the higher RELEASE major ──────────────
# dev-lead ships internal releases (dev-lead/v14.0.0) but its caller-contract channel
# tags are dev-lead/v1-<tier>. The driver must pin the channel major (v1), because
# @dev-lead/v14-<tier> has no tag and fails to resolve — the live bmad regression.

@test "#870: pins the channel major v1, not the release major v14, for a dev-lead consumer" {
  # matching-refs carries a HIGH release tag AND the low v1 channel tags.
  GH_MATCHING_REFS="$(channel_refs dev-lead 1 refs/tags/dev-lead/v14.0.0)"; export GH_MATCHING_REFS
  # bmad-bgreat-suite is a ring1 repo — the exact live-broken consumer.
  install_gh_stub   # missing stub → deploy plans a fresh pin
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo bmad-bgreat-suite --workflow dev-lead.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF '@dev-lead/v1-ring1'
  ! echo "$output" | grep -qF '@dev-lead/v14'
  echo "$output" | grep -qE 'Would open PR for bmad-bgreat-suite .* dev-lead.yml'
}

@test "#870: refuses a computed channel ref that has no tag (assert-exists)" {
  # Only v1-stable exists as a channel tag (channel major still resolves to 1), but
  # the ring1 tier tag v1-ring1 was never cut. The driver must NOT deploy the
  # non-resolving @dev-lead/v1-ring1 pin.
  export GH_MATCHING_REFS="refs/tags/dev-lead/v14.0.0
refs/tags/dev-lead/v1-stable"
  export GH_EXISTING_TAGS="dev-lead/v1-stable"   # v1-ring1 absent
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo bmad-bgreat-suite --workflow dev-lead.yml
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi 'does not resolve'
  run grep -qi 'Would open PR' <<< "$output"
  [ "$status" -eq 1 ]
}

# ── #1088: a NEWLY ring-managed agent is refused when its channel tag is absent ──
# apply-repo-settings had drifted OUT of RING_REUSABLES, so emit_ref_for returned
# empty and the deploy shipped its template VERBATIM — pinning the hardcoded
# @apply-repo-settings/v1-stable, a tag that does not exist. That opened the
# startup_failure PRs TalkTerm#489 / bmad#463. Now that it is ring-managed (AC1),
# the deploy computes the tier channel AND the assert-exists guard (AC2) refuses a
# non-resolving pin with a named error rather than deploying verbatim.

@test "#1088: refuses a newly ring-managed agent whose computed channel tag is absent (assert-exists)" {
  # apply-repo-settings has a v1 channel major, but the ring1 tier tag v1-ring1 was
  # never cut (the fatal case). bmad-bgreat-suite is a ring1 repo → computed
  # @apply-repo-settings/v1-ring1, which does not resolve → refuse.
  export GH_MATCHING_REFS="refs/tags/apply-repo-settings/v1-stable"
  export GH_EXISTING_TAGS="apply-repo-settings/v1-stable"   # v1-ring1 absent
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo bmad-bgreat-suite --workflow apply-repo-settings.yml
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi 'does not resolve'
  echo "$output" | grep -qF '@apply-repo-settings/v1-ring1'
  run grep -qi 'Would open PR' <<< "$output"
  [ "$status" -eq 1 ]
}

# ── #878: marker injection for meta-repo consumer stubs prevents infinite churn ──
# When the driver re-pins a meta-repo consumer stub using repin_source=existing_content
# and that existing content lacks the S7635 marker, the deployed stub would be
# marker-less and is_already_compliant would flag it as drift again on the next sweep
# — an infinite redeployment loop. The fix (non-dry-run path) injects the marker into
# repin_source before computing deploy_template, so the PR's content is immediately
# compliant. The dry-run tests below verify the trigger condition (marker-absent →
# drift) and the post-fix compliant shape (marker-present → no churn).

@test "#878: meta-repo consumer stub at correct v-form but missing S7635 marker is drift" {
  GH_MATCHING_REFS="$(channel_refs dev-lead 3)"; export GH_MATCHING_REFS
  # .github (ring0) is at the correct @dev-lead/v3-ring0 pin but the S7635 marker
  # is absent — the shape a PR opened without the fix would produce. Must be drift.
  GH_CONTENT_B64="$(devlead_stub_pinning dev-lead/v3-ring0)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo .github --workflow dev-lead.yml
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'already compliant'
  echo "$output" | grep -qE 'Would open PR for \.github .* dev-lead.yml'
}

@test "#878: meta-repo consumer stub with S7635 marker at correct v-form is compliant (no churn after fix)" {
  GH_MATCHING_REFS="$(channel_refs dev-lead 3)"; export GH_MATCHING_REFS
  # .github (ring0) stub has the correct @dev-lead/v3-ring0 pin AND the S7635 marker
  # — the shape the fix injects on re-deploy. Must be compliant on the next sweep.
  GH_CONTENT_B64="$(devlead_stub_pinning_with_marker dev-lead/v3-ring0)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo .github --workflow dev-lead.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'already compliant'
  ! echo "$output" | grep -q 'Would open PR'
}
