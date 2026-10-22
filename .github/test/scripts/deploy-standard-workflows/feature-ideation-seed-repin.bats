#!/usr/bin/env bats
# Issue #836, Part B — the three newly-deployable standard workflows:
#   initiative-driver.yml — self-contained dispatcher (no reusable) → verbatim add.
#   pr-auto-review.yml     — ring reusable → straight add, re-pinned to repo tier.
#   feature-ideation.yml   — ring reusable BUT carries a per-repo project_context,
#                            so it deploys SEED-IF-ABSENT + RE-PIN-IN-PLACE and must
#                            never overwrite an existing tuned body from the template.
#
# All runs are --dry-run (no mutating gh calls), single --repo/--workflow for
# determinism. A fake `gh` returns the reusable's CHANNEL tags (caller-contract
# major derivation — #870) and, when set, the target repo's existing stub content.

setup() {
  TT_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/deploy-standard-workflows.sh"
}

teardown() { rm -rf "$TT_TMP"; }

# Fake gh:
#   GH_MATCHING_REFS newline-separated `refs/tags/<agent>/…` for matching-refs. The
#                    major is derived from the CHANNEL tags (`<agent>/v<M>-<tier>`),
#                    not the release semver (#870); no channel tag → bare-tier form.
#   GH_CONTENT_B64   base64 of the existing stub (unset → contents 404 = absent).
install_gh_stub() {
  local bin="${TT_TMP}/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "api" ]; then
  case "$2" in
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

# A feature-ideation stub with a TUNED project_context sentinel, pinned at <ref>.
fi_stub_pinning() {  # <ref>
  local body="jobs:
  ideate:
    uses: petry-projects/.github/.github/workflows/feature-ideation-reusable.yml@$1
    with:
      project_context: |
        TUNED-REPO-CONTEXT-SENTINEL
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: \${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}"
  base64 -w 0 <<<"$body" 2>/dev/null || base64 -b 0 <<<"$body"
}

# ── feature-ideation: SEED-IF-ABSENT ───────────────────────────────────────────

@test "feature-ideation: a repo WITHOUT the stub gets a fresh seed from the template" {
  export GH_MATCHING_REFS="refs/tags/feature-ideation/v1-stable
refs/tags/feature-ideation/v1-next
refs/tags/feature-ideation/v1-ring0
refs/tags/feature-ideation/v1-ring1"
  install_gh_stub   # no GH_CONTENT_B64 → 404 → stub absent
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets --workflow feature-ideation.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'seed-if-absent: seeding fresh from template'
  # markets is stable tier → v1 major line → @feature-ideation/v1-stable
  echo "$output" | grep -qF '@feature-ideation/v1-stable'
  echo "$output" | grep -qE 'Would open PR for markets .* feature-ideation.yml'
  # must NOT take the re-pin-in-place path
  ! echo "$output" | grep -qF 're-pin uses in place'
}

# ── feature-ideation: RE-PIN-IN-PLACE (no clobber of project_context) ───────────

@test "feature-ideation: a repo WITH a tuned stub is re-pinned in place, body preserved" {
  export GH_MATCHING_REFS="refs/tags/feature-ideation/v1-stable
refs/tags/feature-ideation/v1-next
refs/tags/feature-ideation/v1-ring0
refs/tags/feature-ideation/v1-ring1"
  # Existing tuned stub, still on the bare-tier channel. --force so the bare-tier
  # migration grace does not short-circuit it as already-compliant.
  GH_CONTENT_B64="$(fi_stub_pinning feature-ideation/stable)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --force --repo markets --workflow feature-ideation.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 're-pin uses in place — existing body/project_context preserved'
  echo "$output" | grep -qF '@feature-ideation/v1-stable'
  echo "$output" | grep -qE 'Would open PR for markets .* feature-ideation.yml'
  # must NOT take the seed path (that would overwrite project_context)
  ! echo "$output" | grep -qF 'seeding fresh from template'
}

@test "feature-ideation: an already-compliant tuned stub is left untouched (no PR)" {
  # A stub already at the tier-correct v-form is compliant → no re-pin, no clobber.
  export GH_MATCHING_REFS="refs/tags/feature-ideation/v1-stable
refs/tags/feature-ideation/v1-next
refs/tags/feature-ideation/v1-ring0
refs/tags/feature-ideation/v1-ring1"
  GH_CONTENT_B64="$(fi_stub_pinning feature-ideation/v1-stable)"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets --workflow feature-ideation.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'already compliant'
  ! echo "$output" | grep -q 'Would open PR'
}

# ── initiative-driver: verbatim add (no reusable → no pin) ──────────────────────

@test "initiative-driver: deploys verbatim to the fleet with no uses: pin" {
  install_gh_stub   # 404 → stub absent → verbatim seed
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets --workflow initiative-driver.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE 'Would open PR for markets .* initiative-driver.yml'
  # self-contained dispatcher: no reusable uses: → nothing to pin
  ! echo "$output" | grep -qF 'would pin @'
  ! echo "$output" | grep -qF 'seed-if-absent'
}

@test "initiative-driver: an already-correct stub is left untouched (verbatim-compliant check)" {
  # When the stub already matches the template verbatim, is_already_compliant must
  # return true (no reusable uses: → full-content comparison), so the sweep skips
  # re-deploying on every run (fixes perpetual-drift footgun).
  local template="${REPO_ROOT}/standards/workflows/initiative-driver.yml"
  GH_CONTENT_B64="$(base64 -w 0 < "$template" 2>/dev/null || base64 -b 0 < "$template")"
  export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets --workflow initiative-driver.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'already compliant'
  ! echo "$output" | grep -q 'Would open PR'
}

# ── pr-auto-review: ring add, re-pinned to the repo's tier ──────────────────────

@test "pr-auto-review: deploys pinned to the repo's ring tier" {
  export GH_MATCHING_REFS="refs/tags/pr-auto-review/v2-stable
refs/tags/pr-auto-review/v2-next
refs/tags/pr-auto-review/v2-ring0
refs/tags/pr-auto-review/v2-ring1"
  install_gh_stub   # 404 → stub absent → seed + re-pin from template
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo TalkTerm --workflow pr-auto-review.yml
  [ "$status" -eq 0 ]
  # TalkTerm is ring1 tier → v2 major line → @pr-auto-review/v2-ring1
  echo "$output" | grep -qF '@pr-auto-review/v2-ring1'
  echo "$output" | grep -qE 'Would open PR for TalkTerm .* pr-auto-review.yml'
  # pr-auto-review body is identical fleet-wide — not body-preserving
  ! echo "$output" | grep -qF 'seed-if-absent'
  ! echo "$output" | grep -qF 're-pin uses in place'
}
