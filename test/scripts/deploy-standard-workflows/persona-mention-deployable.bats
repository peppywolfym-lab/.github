#!/usr/bin/env bats
# Issue #1156 — persona-mention.yml must be in DEPLOYABLE_WORKFLOWS so the weekly
# standards sweep can carry the caller stub beyond .github-private (the qa-lead
# reach epic, petry-projects/.github-private#1643 Phase 2).
#
# This is the SAME shape as #1128 (apply-repo-settings Step D): the template
# (standards/workflows/persona-mention.yml) and the ring registry entry already
# exist — the stub was simply not in the deployable list, so no sweep could ever
# carry it. Gating precondition (#783 ring soak): the stable-tier channel tag
# @persona-mention/v1-stable must exist before listing, or the assert-exists guard
# (#1088/#870) would refuse the stable-tier pin and break the sweep fleet-wide.
#
# Coverage (AC #5):
#   1. persona-mention.yml is in DEPLOYABLE_WORKFLOWS (is_deployable_workflow true).
#   2. ring-pin emission for persona-mention in a STABLE-tier repo resolves to the
#      major-scoped channel tag @persona-mention/v1-stable.
#   3. regression: the assert-exists guard still refuses a computed pin whose tag
#      does not resolve (the #783 precondition that gated this issue).
#
# All emission runs are --dry-run against a single --repo/--workflow with a fake
# `gh`, mirroring emit-vform.bats — deterministic, no network, no mutations.

bats_require_minimum_version 1.5.0

setup() {
  TT_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/persona.XXXXXX")"
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/deploy-standard-workflows.sh"
}

teardown() { rm -rf "$TT_TMP"; }

# Fake gh — same contract as emit-vform.bats:
#   GH_MATCHING_REFS  newline `refs/tags/<agent>/…` for matching-refs (channel-major derivation).
#   GH_CONTENT_B64    base64 of the existing stub (unset → contents 404 = missing stub).
#   GH_EXISTING_TAGS  newline `<agent>/<ref>` the assert-exists probe treats as resolvable
#                     (unset → every ref resolves).
install_gh_stub() {
  local bin="${TT_TMP}/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "api" ]; then
  case "$2" in
    *git/ref/tags/*)
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

# Channel tags for an agent at major <M> across every ring tier.
channel_refs() {  # <agent> <M> [extra refs...]
  local agent="$1" m="$2"; shift 2
  printf 'refs/tags/%s/v%s-stable\n' "$agent" "$m"
  printf 'refs/tags/%s/v%s-next\n'   "$agent" "$m"
  printf 'refs/tags/%s/v%s-ring0\n'  "$agent" "$m"
  printf 'refs/tags/%s/v%s-ring1\n'  "$agent" "$m"
  if [ "$#" -gt 0 ]; then printf '%s\n' "$@"; fi
  return 0
}

@test "persona-mention.yml is in DEPLOYABLE_WORKFLOWS (is_deployable_workflow true)" {
  run bash -c 'source "$1" >/dev/null 2>&1; is_deployable_workflow persona-mention.yml' _ "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "ring-pin emission for persona-mention in a stable-tier repo resolves to @persona-mention/v1-stable" {
  # markets is not named in any persona-mention ring → falls to the `*` (stable) tier.
  GH_MATCHING_REFS="$(channel_refs persona-mention 1)"; export GH_MATCHING_REFS
  install_gh_stub   # no GH_CONTENT_B64 → missing stub → deploy plans a fresh pin
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets --workflow persona-mention.yml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF '@persona-mention/v1-stable'
  echo "$output" | grep -qE 'Would open PR for markets .* persona-mention.yml'
}

@test "assert-exists refuses a persona-mention pin whose computed tag does not resolve (#783 precondition)" {
  # Channel major resolves to 1, but the stable tier tag v1-stable was never cut —
  # the exact state that gated this issue. The sweep must refuse the non-resolving
  # @persona-mention/v1-stable pin rather than open a fleet-breaking PR.
  export GH_MATCHING_REFS="refs/tags/persona-mention/v1-next
refs/tags/persona-mention/v1-ring0
refs/tags/persona-mention/v1-ring1"
  export GH_EXISTING_TAGS="persona-mention/v1-next
persona-mention/v1-ring0
persona-mention/v1-ring1"   # v1-stable absent
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets --workflow persona-mention.yml
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi 'does not resolve'
  echo "$output" | grep -qF '@persona-mention/v1-stable'
  run grep -qi 'Would open PR' <<< "$output"
  [ "$status" -eq 1 ]
}
