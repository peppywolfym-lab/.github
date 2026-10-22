#!/usr/bin/env bats
# Issue #847 — reconcile the universal-required standard (#844) with the
# SKIP_REPOS self-manage carve-out. `.github-private` is a SKIP_REPO (it
# self-manages its workflow fleet), so the blanket sweep exempts it — which left
# it missing `pr-auto-review.yml` while the compliance audit now requires it in
# ALL repos. Fix: opt `.github-private` into `pr-auto-review.yml` via
# SKIP_OVERRIDES (the same mechanism already used for add-to-project.yml), so the
# sweep deploys the stub at the repo's COMPUTED canary tier instead of a
# hand-pinned (wrong) one. `.github-private` maps to the `next` ring tier, and
# pr-auto-review is a ring-managed reusable, so the emitted pin must be
# `@pr-auto-review/next` (bare) or `@pr-auto-review/v<M>-next` (with a channel tag).
#
# All runs are --dry-run (no mutating gh calls), single --repo/--workflow for
# determinism. A fake `gh` returns the reusable's channel tags (caller-contract
# major derivation) and 404s the contents API (the stub is absent — the bug state).

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
#   Contents API always 404s → stub absent (the missing-stub bug state).
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
      exit 1 ;;   # simulate 404 — stub absent
  esac
fi
exit 0
STUB
  chmod +x "$bin/gh"
  PATH="${bin}:${PATH}"; export PATH
}

@test "pr-auto-review: .github-private (opted-in SKIP_REPO) gets the stub pinned at its next tier" {
  export GH_MATCHING_REFS="refs/tags/pr-auto-review/v2-stable
refs/tags/pr-auto-review/v2-next
refs/tags/pr-auto-review/v2-ring0
refs/tags/pr-auto-review/v2-ring1"
  install_gh_stub   # 404 → stub absent → seed + re-pin from template
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo .github-private --workflow pr-auto-review.yml
  [ "$status" -eq 0 ]
  # .github-private is the `next` tier canary → v2 major line → @pr-auto-review/v2-next
  echo "$output" | grep -qF '@pr-auto-review/v2-next'
  echo "$output" | grep -qE 'Would open PR for \.github-private .* pr-auto-review.yml'
  # the opt-in must NOT hit the meta-repo exempt path
  ! echo "$output" | grep -qF '.github-private/pr-auto-review.yml (exempt)'
}

@test "pr-auto-review: bare @pr-auto-review/next form on .github-private when the reusable has no channel tag" {
  unset GH_MATCHING_REFS   # matching-refs empty → no channel major
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo .github-private --workflow pr-auto-review.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF '@pr-auto-review/next'
  ! echo "$output" | grep -qF '@pr-auto-review/v'
  echo "$output" | grep -qE 'Would open PR for \.github-private .* pr-auto-review.yml'
}

# Regression guard: the opt-in must be surgical. A ring workflow NOT listed in
# SKIP_OVERRIDES (auto-rebase) stays exempt on .github-private when absent — the
# self-manage carve-out is unchanged for everything except pr-auto-review.
@test "auto-rebase: a non-opted-in ring workflow stays exempt on .github-private" {
  export GH_MATCHING_REFS="refs/tags/auto-rebase/v2-stable"
  install_gh_stub   # 404 → absent
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo .github-private --workflow auto-rebase.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF '.github-private/auto-rebase.yml (exempt)'
  ! echo "$output" | grep -qi 'Would open PR'
}
