#!/usr/bin/env bash
# scripts/lib/standards-release.sh — pure decision core for the standards
# release channel (issue #1091).
#
# `standards/` is consumed by other repos as a versioned artifact. This library
# defines the tag vocabulary and the version math for publishing it, mirroring
# the org's reusable-workflow versioning model (standards/ci-standards.md →
# "Reusable workflow versioning — the stable channel"; scripts/lib/canary-
# rollout.sh's max_semver / channel_tag / _is_release_tag_suffix). Because
# standards are per-repo (one artifact, one channel), the shape is simpler than
# the per-agent concentric rings — there is one immutable release form and one
# moving channel, no ring membership.
#
# Immutable release form : standards/vX.Y.Z   (never moved, never deleted)
# Moving channel         : standards/v<major>-stable  (e.g. standards/v1-stable)
#
# This file is side-effect-free and `source`-able: it defines pure functions
# only (no gh/git/network) so the cut decision can be unit-tested
# deterministically. The orchestrator scripts/cut-standards-release.sh sources
# this and feeds it facts gathered from git/gh (AGENTS.md → "Decision Logic
# Lives in a Pure, Tested Script").
#
# shellcheck shell=bash

# Guard against double-sourcing.
if [ -n "${_STANDARDS_RELEASE_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_STANDARDS_RELEASE_SOURCED=1

# The tag namespace for the standards artifact. A single constant so the release
# form and the channel form can never drift apart.
SR_TAG_PREFIX="standards"

# A single strict-SemVer numeric field: 0, or a leading-1..9 run with no leading
# zeros. Leading-zero fields (e.g. 08) are rejected everywhere so no downstream
# `(( ... ))` step can misread them as invalid octal (#1091 review).
_SR_NUM='(0|[1-9][0-9]*)'

# sr_valid_version <version> — return 0 iff <version> is a strict MAJOR.MINOR.PATCH
# with no leading-zero fields.
sr_valid_version() { [[ "${1:-}" =~ ^${_SR_NUM}\.${_SR_NUM}\.${_SR_NUM}$ ]]; }

# sr_major <version> — echo the MAJOR of a strict MAJOR.MINOR.PATCH; empty (rc 1)
# for anything else.
sr_major() {
  if [[ "${1:-}" =~ ^${_SR_NUM}\.${_SR_NUM}\.${_SR_NUM}$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    return 1
  fi
}

# sr_release_tag <version> — echo the immutable release tag standards/vX.Y.Z.
# Rejects a non-semver version (rc 1) so a caller can never publish a malformed
# release ref.
sr_release_tag() {
  sr_valid_version "${1:-}" || return 1
  printf '%s/v%s' "$SR_TAG_PREFIX" "$1"
}

# sr_channel_tag <major> — echo the major-scoped moving channel standards/v<major>-stable.
# Rejects a non-numeric major (rc 1).
sr_channel_tag() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] || return 1
  printf '%s/v%s-stable' "$SR_TAG_PREFIX" "$1"
}

# sr_channel_for <version> — echo the moving channel a given release version
# belongs to (its major line).
sr_channel_for() {
  local major
  major="$(sr_major "${1:-}")" || return 1
  sr_channel_tag "$major"
}

# sr_is_release_suffix <suffix> — return 0 iff <suffix> (a tag name with the
# leading "standards/" already stripped, e.g. "v1.2.3") is an immutable release
# tag: "v" followed by a strict MAJOR.MINOR.PATCH. This is the filter that keeps
# the moving channel suffix "v<major>-stable" (which sorts adjacent to the
# releases) out of the version math — the same shadowing hazard the canary
# engine guards with _is_release_tag_suffix (#1046).
sr_is_release_suffix() { [[ "${1:-}" =~ ^v${_SR_NUM}\.${_SR_NUM}\.${_SR_NUM}$ ]]; }

# sr_version_from_tag <tag> — echo the bare X.Y.Z of a standards release tag
# (standards/vX.Y.Z). Emits nothing for a channel tag or any non-release ref, so
# a caller can map a raw tag list to versions and drop the channel tags in one pass.
sr_version_from_tag() {
  local tag="${1:-}" suffix
  case "$tag" in
    "$SR_TAG_PREFIX"/*) suffix="${tag#"$SR_TAG_PREFIX"/}" ;;
    *) return 0 ;;
  esac
  sr_is_release_suffix "$suffix" || return 0
  printf '%s' "${suffix#v}"
}

# sr_semver_gt <a> <b> — return 0 iff version a > version b, comparing MAJOR,
# MINOR, PATCH numerically (so 1.10.0 > 1.9.0, which a lexical sort gets wrong).
# A non-semver operand is never "greater".
# Compares by component length first (longer decimal = larger), then lexically.
sr_semver_gt() {
  sr_valid_version "${1:-}" || return 1
  sr_valid_version "${2:-}" || return 1
  local a_major a_minor a_patch b_major b_minor b_patch
  local a="$1" b="$2"
  a_major="${a%%.*}"
  a="${a#*.}"
  a_minor="${a%%.*}"
  a_patch="${a#*.}"
  b_major="${b%%.*}"
  b="${b#*.}"
  b_minor="${b%%.*}"
  b_patch="${b#*.}"

  # Compare major: by length first, then lexically
  if [ ${#a_major} -ne ${#b_major} ]; then
    [ ${#a_major} -gt ${#b_major} ]; return
  fi
  if [[ "$a_major" != "$b_major" ]]; then
    [[ "$a_major" > "$b_major" ]]; return
  fi

  # Compare minor: by length first, then lexically
  if [ ${#a_minor} -ne ${#b_minor} ]; then
    [ ${#a_minor} -gt ${#b_minor} ]; return
  fi
  if [[ "$a_minor" != "$b_minor" ]]; then
    [[ "$a_minor" > "$b_minor" ]]; return
  fi

  # Compare patch: by length first, then lexically
  if [ ${#a_patch} -ne ${#b_patch} ]; then
    [ ${#a_patch} -gt ${#b_patch} ]; return
  fi
  [[ "$a_patch" > "$b_patch" ]]
}

# sr_max_version <version...> — echo the highest strict MAJOR.MINOR.PATCH among
# the args, ignoring any token that is not a strict semver. Empty if none valid.
sr_max_version() {
  local v hi=""
  for v in "$@"; do
    sr_valid_version "$v" || continue
    if [ -z "$hi" ] || sr_semver_gt "$v" "$hi"; then hi="$v"; fi
  done
  printf '%s' "$hi"
}

# sr_current_and_previous <version...> — echo "<current>\t<previous>": the two
# highest DISTINCT published versions (current = highest, previous = the one
# before it), ordered numerically, ignoring invalid tokens and de-duplicating.
#
# This is #1448's N-1 requirement (AC #4): a consumer must be able to determine
# both the current published version and the one before it. When only one
# version exists, <previous> is empty — that is the documented starting state,
# not a special case a consumer has to code around: "accept current OR previous"
# degrades cleanly to "accept current" when previous is empty.
sr_current_and_previous() {
  local -a valid=()
  local v seen
  # Filter to valid, de-duplicated versions.
  for v in "$@"; do
    sr_valid_version "$v" || continue
    seen=0
    local u
    for u in "${valid[@]+"${valid[@]}"}"; do [ "$u" = "$v" ] && { seen=1; break; }; done
    [ "$seen" -eq 0 ] && valid+=("$v")
  done
  local current previous=""
  current="$(sr_max_version "${valid[@]+"${valid[@]}"}")"
  if [ -n "$current" ]; then
    # previous = highest of the remaining versions strictly below current.
    local rest=()
    for v in "${valid[@]+"${valid[@]}"}"; do [ "$v" != "$current" ] && rest+=("$v"); done
    previous="$(sr_max_version "${rest[@]+"${rest[@]}"}")"
  fi
  # Line-terminated: the orchestrator consumes this with `read`, which needs the
  # newline delimiter to succeed (a delimiter-less read returns non-zero and, in
  # a `set -e` caller, would abort). Command substitution strips it for tests.
  printf '%s\t%s\n' "$current" "$previous"
}

# sr_cut_decision <existing_commit> <requested_commit> — decide how a cut of the
# immutable release tag must proceed, given the commit the tag currently resolves
# to (empty if it does not exist) and the commit the cut targets. Echoes exactly
# one of:
#   CREATE  — the tag does not exist yet; publish it.
#   NOOP    — the tag already points at the requested commit; re-running is a
#             harmless no-op (idempotent).
#   REFUSE  — the tag exists at a DIFFERENT commit; never clobber an immutable
#             release (mirrors cut-release.sh's refusal to overwrite and canary-
#             rollout.sh's refusal to re-point a tag that resolves elsewhere).
sr_cut_decision() {
  local existing="${1:-}" requested="${2:-}"
  if [ -z "$existing" ]; then echo "CREATE"; return 0; fi
  if [ "$existing" = "$requested" ]; then echo "NOOP"; return 0; fi
  echo "REFUSE"; return 0
}
