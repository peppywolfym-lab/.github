#!/usr/bin/env bash
set -euo pipefail
# cut-standards-release.sh — publish the standards artifact as a versioned
# release channel (issue #1091).
#
# `standards/` is consumed by other repos as a versioned artifact, but no
# standards/* tag has ever been cut, so every consumer effectively tracks this
# repo's default branch (the #1707 outage). This script makes cutting the
# channel a scripted, idempotent, clobber-refusing operation instead of a
# one-off hand action — a human still decides WHEN, the mechanism decides HOW.
#
# It mirrors the org's release-channel vocabulary and guardrails
# (standards/ci-standards.md → "Reusable workflow versioning"; scripts/canary-
# rollout.sh) — one immutable release, one moving channel — but standards are
# per-repo, so there are no concentric rings: a single moving channel
# standards/v<major>-stable.
#
#   Immutable release : standards/vX.Y.Z        (audit trail; never moved/deleted)
#   Moving channel    : standards/v<major>-stable  (what consumers pin)
#
# The decision logic (tag naming, N-1 selection, refuse-to-clobber) lives in the
# pure, unit-tested core scripts/lib/standards-release.sh (AGENTS.md → "Decision
# Logic Lives in a Pure, Tested Script"); this file is thin I/O glue.
#
# Usage:
#   cut-standards-release.sh cut <vX.Y.Z> [--commit <sha>] [--dry-run]
#       Cut the immutable release standards/vX.Y.Z at <sha> (default: local HEAD)
#       and move standards/v<major>-stable onto it. Re-running is a NOOP when the
#       release already points at <sha>; it REFUSES to clobber a release that
#       resolves to a different commit. --dry-run reads but never writes.
#   cut-standards-release.sh versions
#       List published standards/vX.Y.Z versions, highest first.
#   cut-standards-release.sh resolve
#       Print the current published version and the one before it (N-1, #1448),
#       plus the moving channel each resolves to.
#   cut-standards-release.sh channel <vX.Y.Z>
#       Print the moving channel a given version belongs to.
#
# Env:
#   SR_REPO    owner/name of the repo that owns the standards tags
#              (default: $GITHUB_REPOSITORY, else petry-projects/.github).
#   GH_TOKEN   credential for the tag-write API path (the release-channel-tags
#              ruleset grants the authorized mover an update-bypass on the
#              protected tag; see standards/rulesets/release-channel-tags.json).

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/standards-release.sh
source "${_HERE}/lib/standards-release.sh"

SR_REPO="${SR_REPO:-${GITHUB_REPOSITORY:-petry-projects/.github}}"

_usage() {
  cat >&2 <<EOF
Usage: $0 <command> [args]

  cut <vX.Y.Z> [--commit <sha>] [--dry-run]   cut the release + move the channel
  versions                                    list published standards/vX.Y.Z
  resolve                                     print current + N-1 versions
  channel <vX.Y.Z>                            print the moving channel for a version

Immutable release: standards/vX.Y.Z   Moving channel: standards/v<major>-stable
EOF
  exit 2
}

# _normalize_version <arg> — strip an optional leading "v" and validate. Echoes
# the bare X.Y.Z or exits non-zero with a clear error.
_normalize_version() {
  local v="${1#v}"
  if ! sr_valid_version "$v"; then
    echo "::error::'$1' is not a strict semantic version (expected vX.Y.Z / X.Y.Z)" >&2
    exit 2
  fi
  printf '%s' "$v"
}

# _gh_tag_commit <repo> <tag> — echo the COMMIT sha <tag> resolves to on <repo>
# via the GitHub API, dereferencing an annotated tag object. Echoes empty for a
# genuinely ABSENT tag (HTTP 404) and returns 0. For any OTHER failure (network,
# 5xx, auth) it returns non-zero WITHOUT echoing, so a transient error is never
# silently read as "tag absent" and mis-routed onto the CREATE path (#1091
# review): the caller's `existing="$(_gh_tag_commit ...)"` under `set -e` aborts.
_gh_tag_commit() {
  local repo="$1" tag="$2" ref_info obj type err rc
  err="$(mktemp)"
  ref_info="$(gh api "repos/$repo/git/ref/tags/$tag" \
    --jq '[(.object?.sha // "" | tostring), (.object?.type // "" | tostring)] | @tsv' 2>"$err")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    if grep -qiE 'HTTP 404|not found|does not exist' "$err"; then
      rm -f "$err"; return 0   # tag genuinely absent → empty
    fi
    echo "::error::_gh_tag_commit: could not resolve $tag on $repo (treating as unavailable, not absent): $(tr '\n' ' ' <"$err")" >&2
    rm -f "$err"; return 1
  fi
  rm -f "$err"
  [ -z "$ref_info" ] && return 0
  IFS=$'\t' read -r obj type <<< "$ref_info"
  if [ "$type" = "tag" ]; then
    gh api "repos/$repo/git/tags/$obj" --jq '(.object?.sha // "" | tostring)' 2>/dev/null || true
  else
    printf '%s\n' "$obj"
  fi
}

# _gh_release_versions <repo> — echo the bare X.Y.Z of every published
# standards/vX.Y.Z release tag on <repo>, via the GitHub API. Channel tags are
# dropped by sr_version_from_tag. Empty (rc 0) on any API error — a read used
# only to enumerate; the callers tolerate a transient empty list.
_gh_release_versions() {
  local repo="$1" ref v
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    v="$(sr_version_from_tag "${ref#refs/tags/}")"
    [ -n "$v" ] && printf '%s\n' "$v"
  done < <(gh api "repos/$repo/git/matching-refs/tags/standards/v" --jq '.[].ref' 2>/dev/null || true)
}

# _published_versions — list published standards/vX.Y.Z versions, highest first,
# from the repo cut reads/writes (SR_REPO) via the GitHub API. Always queries
# the API to ensure reported tags correspond to SR_REPO and are not stale local
# refs (#1091 review). Channel tags dropped by sr_version_from_tag.
_published_versions() {
  local v out=()
  while IFS= read -r v; do [ -n "$v" ] && out+=("$v"); done < <(_gh_release_versions "$SR_REPO")
  # Numeric-desc sort via the pure comparator (repeatedly extract the max).
  local remaining=("${out[@]+"${out[@]}"}") max
  while [ "${#remaining[@]}" -gt 0 ]; do
    max="$(sr_max_version "${remaining[@]}")"
    [ -z "$max" ] && break
    printf '%s\n' "$max"
    local next=() r
    for r in "${remaining[@]}"; do [ "$r" != "$max" ] && next+=("$r"); done
    remaining=("${next[@]+"${next[@]}"}")
  done
}

# _cmd_versions — print published versions, highest first.
_cmd_versions() { _published_versions; }

# _cmd_resolve — print current + N-1 published versions and their channels (AC #4).
_cmd_resolve() {
  local versions=() v cur prev
  while IFS= read -r v; do [ -n "$v" ] && versions+=("$v"); done < <(_published_versions)
  IFS=$'\t' read -r cur prev < <(sr_current_and_previous "${versions[@]+"${versions[@]}"}")
  if [ -z "$cur" ]; then
    echo "current:  (none published yet — run 'cut' to publish standards/v1.0.0)"
    echo "previous: (none)"
    return 0
  fi
  printf 'current:  standards/v%s   (channel %s)\n' "$cur" "$(sr_channel_for "$cur")"
  if [ -n "$prev" ]; then
    printf 'previous: standards/v%s   (channel %s)\n' "$prev" "$(sr_channel_for "$prev")"
  else
    echo 'previous: (none — single-version starting state; a consumer accepting'
    echo '           current OR previous simply accepts current until a second cut)'
  fi
}

# _cmd_channel <version> — print the moving channel a version belongs to.
_cmd_channel() {
  local v; v="$(_normalize_version "${1:-}")"
  printf '%s\n' "$(sr_channel_for "$v")"
}

# _cmd_cut <version> [--commit sha] [--dry-run] — cut the immutable release and
# move the channel.
_cmd_cut() {
  local raw="${1:-}"; shift || true
  [ -n "$raw" ] || _usage
  local version commit="" dry_run=0
  version="$(_normalize_version "$raw")"
  while [ $# -gt 0 ]; do
    case "$1" in
      --commit) commit="${2:-}"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *) echo "::error::unknown flag '$1'" >&2; _usage ;;
    esac
  done
  [ -n "$commit" ] || commit="$(git rev-parse HEAD 2>/dev/null || true)"
  if [ -z "$commit" ]; then
    echo "::error::could not resolve a target commit (no --commit and no local HEAD)" >&2
    exit 1
  fi

  local release_tag channel_tag
  release_tag="$(sr_release_tag "$version")"
  channel_tag="$(sr_channel_for "$version")"

  # Resolve where the immutable release currently points (read-only, safe in a
  # dry run) and decide the action via the pure core.
  local existing decision
  existing="$(_gh_tag_commit "$SR_REPO" "$release_tag")"
  decision="$(sr_cut_decision "$existing" "$commit")"

  echo "repo:      $SR_REPO"
  echo "release:   $release_tag -> ${commit:0:12}"
  echo "channel:   $channel_tag -> ${commit:0:12}"
  echo "decision:  $decision${existing:+ (existing $release_tag -> ${existing:0:12})}"

  case "$decision" in
    REFUSE)
      echo "::error::$release_tag already exists at ${existing:0:12}, not ${commit:0:12} — REFUSE to clobber an immutable release. Cut a new version instead." >&2
      exit 1
      ;;
    NOOP)
      echo "immutable release already published at the requested commit; ensuring channel is aligned."
      ;;
    CREATE)
      : # publish below
      ;;
  esac

  if [ "$dry_run" -eq 1 ]; then
    echo "[dry-run] no tags written."
    return 0
  fi

  if [ "$decision" = "CREATE" ]; then
    echo "creating immutable release $release_tag at ${commit:0:12}..."
    _gh_create_annotated_tag "$SR_REPO" "$release_tag" "$commit" "standards release $version"
  fi

  # Race guard (#1091 review): two concurrent cuts of DIFFERENT versions on the
  # same major both pass refuse-to-clobber (distinct immutable tags) and then race
  # to move the shared channel; the one that writes last would win, letting an
  # OLDER cut drag the channel backward off a newer release. Re-enumerate the
  # published releases (now including this cut's own, just created above) right
  # before the move and only advance the channel when THIS version is the highest
  # on its major. A lower concurrent cut sees the newer release and skips the move
  # instead of regressing the channel; the highest cut always converges it forward.
  local major highest v
  major="$(sr_major "$version")"
  local -a same_major=("$version")
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    if [ "$(sr_major "$v" || true)" = "$major" ]; then same_major+=("$v"); fi
  done < <(_gh_release_versions "$SR_REPO")
  highest="$(sr_max_version "${same_major[@]}")"
  if [ "$highest" != "$version" ]; then
    echo "channel $channel_tag: a newer release standards/v$highest is already published on the v$major line; leaving the channel on the newer release (skipping backward move)."
    echo "done."
    return 0
  fi

  echo "moving channel $channel_tag onto ${commit:0:12}..."
  # Re-check before moving to close the race window (#1119): a concurrent higher cut
  # could have published since the prior rescan. If so, skip the move to avoid
  # regressing the channel to an older version; the higher cut will move it forward.
  local -a check_major=("$version")
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    if [ "$(sr_major "$v" || true)" = "$major" ]; then check_major+=("$v"); fi
  done < <(_gh_release_versions "$SR_REPO")
  local check_highest
  check_highest="$(sr_max_version "${check_major[@]}")"
  if [ "$check_highest" != "$version" ]; then
    echo "channel $channel_tag: release standards/v$check_highest is now published; leaving the channel on that newer release (skipping backward move)."
    return 0
  fi
  # A cut is not atomic: the immutable release is created first, the channel moved
  # second. If the move fails, the release is already published but consumers
  # pinning the channel cannot reach it (#1119). Fail LOUDLY and name the exact
  # recovery — the release is NOOP-safe, so re-running the same cut converges the
  # channel without re-creating (or clobbering) the release.
  if ! _gh_move_tag "$SR_REPO" "$channel_tag" "$commit"; then
    local script_path
    script_path="$(printf '%s\n' "$0")"
    echo "::error::partial cut: $release_tag is published at ${commit:0:12} but the channel $channel_tag could NOT be moved onto it — consumers pinning $channel_tag will not see this release. Re-run \"$script_path\" cut $version --commit $commit to converge the channel (the release stays NOOP; it is never re-created or clobbered)." >&2
    return 1
  fi
  echo "done."
}

# _gh_create_annotated_tag <repo> <tag> <sha> <message> — create the immutable
# annotated tag object <tag> at <sha> on <repo> and publish its ref, via the
# GitHub API (mirrors canary-rollout.sh). Fails non-zero on API error.
_gh_create_annotated_tag() {
  local repo="$1" tag="$2" sha="$3" message="$4" obj
  obj="$(gh api -X POST "repos/$repo/git/tags" \
      -f tag="$tag" -f message="$message" -f object="$sha" -f type=commit \
      --jq '.sha // empty')" || {
    echo "::error::could not create annotated tag $tag on $repo" >&2; return 1;
  }
  [ -n "$obj" ] || { echo "::error::annotated tag $tag created but object SHA unreadable" >&2; return 1; }
  gh api -X POST "repos/$repo/git/refs" \
      -f ref="refs/tags/$tag" -f sha="$obj" >/dev/null 2>&1 || {
    echo "::error::created tag object $obj on $repo but could not publish ref refs/tags/$tag" >&2; return 1;
  }
}

# _gh_move_tag <repo> <tag> <sha> — force-move (or create) the lightweight ref
# refs/tags/<tag> to <sha> via the GitHub API: PATCH an existing ref, else POST
# to create it (mirrors canary-rollout.sh). The release-channel-tags ruleset
# grants the authorized mover the update-bypass this path relies on.
_gh_move_tag() {
  local repo="$1" tag="$2" sha="$3" out low
  out="$(gh api -X PATCH "repos/$repo/git/refs/tags/$tag" \
      -f sha="$sha" -F force=true 2>&1)" && return 0
  # Portable lowercase for the case-insensitive "not found" match below. A bash-4
  # case-modification expansion (the double-comma parameter form) is a fatal "bad
  # substitution" on the macOS system bash 3.2 — this script is operator-run from a
  # workstation, so that is a real execution environment (#1119). tr is POSIX.
  low="$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')"
  if [[ "$low" != *"not found"* && "$low" != *"http 404"* && "$low" != *"reference does not exist"* ]]; then
    echo "::error::_gh_move_tag: could not move refs/tags/$tag -> ${sha:0:12} on $repo: ${out//$'\n'/ }" >&2
    return 1
  fi
  gh api -X POST "repos/$repo/git/refs" \
      -f ref="refs/tags/$tag" -f sha="$sha" >/dev/null 2>&1 || {
    echo "::error::_gh_move_tag: could not create refs/tags/$tag -> ${sha:0:12} on $repo" >&2; return 1;
  }
}

main() {
  [ $# -ge 1 ] || _usage
  local cmd="$1"; shift
  case "$cmd" in
    cut)      _cmd_cut "$@" ;;
    versions) _cmd_versions ;;
    resolve)  _cmd_resolve ;;
    channel)  _cmd_channel "$@" ;;
    -h|--help|help) _usage ;;
    *) echo "::error::unknown command '$cmd'" >&2; _usage ;;
  esac
}

main "$@"
