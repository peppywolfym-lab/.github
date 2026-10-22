#!/usr/bin/env bash
set -euo pipefail
# canary-rollout.sh — ring-staged, health-gated promotion of agent releases by
# moving channel tags only (initiative #495, issue #501; rollback/observability #502).
#
# The ONLY action this performs is moving a channel tag (via `gh api` on the agent's host
# repo, with the release-manager App token — #1076) — it never writes consumer files. A ring advances
# only when the rings already on the candidate pass the soak/health gate (see
# scripts/lib/canary-rollout.sh for the pure decision core).
#
# Channel tags ARE the rollout state (#502): the frontier is derived from where each
# channel tag resolves; there is no separate state store.
#
# The FRONT END that closes the last manual seam (#1069): `autocut` polls each registered
# reusable and, when its blob on the host's main HEAD differs from the current `next`
# candidate, cuts a new immutable <agent>/vX.Y.Z and moves `next` onto it — seeding the soak/
# promote pipeline with no manual `cut-release.sh`. It is gated by CANARY_AUTO_CUT (the single
# kill-switch), runs BEFORE promote-all on the scheduled tick, and is best-effort.
#
# Usage:
#   canary-rollout.sh autocut      [--dry-run]         # cut+seed new candidates for changed reusables (gated by CANARY_AUTO_CUT)
#   canary-rollout.sh evaluate     <agent>             # read-only gate + health report (also the #502 report)
#   canary-rollout.sh evaluate-all                     # read-only evaluate for EVERY registry agent (fleet-wide; the 4h timer)
#   canary-rollout.sh promote  <agent> [--override] [--confirm] [--allow-pre-existing] [--dry-run]  # --confirm clears an AWAITING_CONFIRMATION hold (#668 Layer 3); NOT --override
#   canary-rollout.sh promote-all [--override] [--allow-pre-existing] [--dry-run]  # gated fleet auto-promote (the SCHEDULED arm, #1045b)
#   canary-rollout.sh rollback <agent> <ring> --to <vX.Y.Z> [--dry-run]
#   canary-rollout.sh resolve  <agent> <channel>       # debug: print resolved member repos
#   canary-rollout.sh sync-issues [--dry-run]          # blocker issue per BLOCKED agent + fleet-status table to the job summary (auto-triage)
#   canary-rollout.sh drift    [--emit-stub]           # read-only: report *-reusable.yml on a host but unregistered, + stale registry entries (#1082)
#
# Gate standard: .github#548 — graduated per-transition dwell/sample floors over a
# per-candidate cumulative window (since the candidate's OWN vX.Y.Z cut), a robust
# spike-capped baseline for the sample target, the ring0->ring1 sample waiver, and
# candidate-regression-vs-environmental failure triage. Knobs live in the ring SoT
# under .agents[<agent>].gate (see scripts/lib/canary-rollout.sh for the pure core).
#
# Env:
#   CANARY_RINGS        path to ring SoT (default: standards/canary-rings.json next to this repo)
#   SOAK_WINDOW_DAYS    optional override of the baseline-window length in days
#                       (default: .gate.baseline_window_days, else 14)
#   CANARY_FAILURE_CATEGORY  optional triage hint (comment-cap|rate-limit|infra|data)
#   CANARY_AUTO_CUT     autocut kill-switch — autocut is a no-op unless this == 'true'
#   GH_TOKEN            credential; the workflow mints a GitHub App token and passes it here

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/canary-rollout.sh
source "${_HERE}/lib/canary-rollout.sh"
DEFAULT_RINGS="$(cd "${_HERE}/.." && pwd)/standards/canary-rings.json"
CANARY_RINGS="${CANARY_RINGS:-$DEFAULT_RINGS}"

# The `autocut` front end (#1069) cuts new candidates INLINE via the App-token gh-api path
# (_gh_create_annotated_tag + _gh_move_tag against the agent's registry host) — it no longer
# shells out to a sibling cut-release.sh. That coupling broke when the engine relocated to
# .github (#613): cut-release.sh stayed in .github-private as the human/runbook CLI and does
# not travel with this checkout. Cutting inline keeps the engine self-contained and writes to
# the correct host for every agent (incl. dev-lead, hosted in .github-private).

# THIS_REPO — the repo this checkout belongs to. Agents hosted HERE (dev-lead, pr-review)
# keep their channel/release tags in this checkout and resolve them via local git. A
# cross-repo agent (host != THIS_REPO, e.g. the #482 reusables hosted in petry-projects/
# .github) keeps its <name>/<channel> and <name>/vX.Y.Z tags on ITS host, so those tags
# must be resolved there via `gh api` — reading local refs resolves empty and the frontier
# falsely reports "fully rolled out" (#1049). Mirrors cut-release.sh's CROSS_REPO_TARGET.
THIS_REPO="${GITHUB_REPOSITORY:-petry-projects/.github-private}"

# CANARY_MAX_COMMIT_PAGES — pagination ceiling (100 commits/page) when autocut enumerates a
# commit range for bump signals. A range that cannot be fully enumerated within this many pages
# is treated as UNRESOLVABLE and fails safe to a major bump (#1023 defect 1b), never silently to
# patch. 50 pages = 5000 commits — far beyond any real inter-cut range.
CANARY_MAX_COMMIT_PAGES="${CANARY_MAX_COMMIT_PAGES:-50}"
if ! [[ "$CANARY_MAX_COMMIT_PAGES" =~ ^[0-9]+$ ]] || [ "$CANARY_MAX_COMMIT_PAGES" -le 0 ]; then
  CANARY_MAX_COMMIT_PAGES=50
fi

# CANARY_PROMOTION_FAILURE_ESCALATE_AFTER — how many CONSECUTIVE scheduled runs a tag write may
# fail before its tracking issue escalates to needs-human + dev-lead (#1023 defect 2). Default 2
# (~8h at the 4h cadence) so a single transient rejection self-heals but a stuck write escalates.
CANARY_PROMOTION_FAILURE_ESCALATE_AFTER="${CANARY_PROMOTION_FAILURE_ESCALATE_AFTER:-2}"

_jq()  { jq "$@" "$CANARY_RINGS"; }
_agent_field() { _jq -r --arg a "$1" ".agents[\$a].$2"; }

# ordered_channels <agent> — e.g. "next,ring0,ring1,stable"
ordered_channels() {
  _jq -r --arg a "$1" '.agents[$a].rings | sort_by(.order) | map(.channel) | join(",")'
}

# resolve_members <agent> <channel> — print the member repos, expanding the
# host-relative tokens $host / $org_infra / * (one repo per line).
resolve_members() {
  local agent="$1" channel="$2" host t r
  host="$(_agent_field "$agent" host)"
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    case "$t" in
      '$host') printf '%s\n' "$host" ;;
      '$org_infra')
        while IFS= read -r r; do
          if [ "$r" != "$host" ]; then printf '%s\n' "$r"; fi
        done < <(_jq -r '.org_infra_repos[]') ;;
      '*') printf '%s\n' '*' ;;
      *) printf '%s\n' "$t" ;;
    esac
  done < <(_jq -r --arg a "$agent" --arg c "$channel" \
            '.agents[$a].rings[] | select(.channel==$c) | .members[]')
  return 0
}

# _gh_tag_commit <repo> <tag> — echo the COMMIT sha <tag> resolves to on <repo> via the
# GitHub API, dereferencing an annotated tag object (mirrors cut-release.sh's
# gh_release_commit). Empty on any error / absent tag (never fails the caller).
_gh_tag_commit() {
  local repo="$1" tag="$2" ref_info obj type
  ref_info="$(gh api "repos/$repo/git/ref/tags/$tag" --jq '[(.object?.sha // "" | tostring), (.object?.type // "" | tostring)] | @tsv' 2>/dev/null)" || return 0
  [ -z "$ref_info" ] && return 0
  read -r obj type <<< "$ref_info"
  if [ "$type" = "tag" ]; then
    gh api "repos/$repo/git/tags/$obj" --jq '(.object?.sha // "" | tostring)' 2>/dev/null || true
  else
    printf '%s\n' "$obj"
  fi
}

# _gh_write <gh-args…> — run a `gh` mutation with the repo-scoped WRITE token when one is
# provided (CANARY_WRITE_TOKEN), else the ambient GH_TOKEN. The owner-wide token the workflow
# mints for the fleet gate's cross-repo run-history reads is refused a release-channel-tags
# ruleset bypass on a protected channel-tag PATCH — 403 "Resource not accessible by
# integration" (#745): GitHub evaluates an App's bypass/effective-permissions differently for
# an owner-level token than for a repo-scoped installation token. So tag writes are routed
# through a SECOND token minted repo-scoped (repositories: .github + .github-private) with an
# explicit Contents:write, while reads keep the owner-wide token (don't regress the '*'
# stable-tier enumeration). Absent CANARY_WRITE_TOKEN (e.g. unit tests / local runs) it is a
# transparent pass-through, so every existing GH_TOKEN-only path is unchanged.
_gh_write() {
  if [ -n "${CANARY_WRITE_TOKEN:-}" ]; then
    GH_TOKEN="$CANARY_WRITE_TOKEN" gh "$@"
  else
    gh "$@"
  fi
}

# _gh_move_tag <repo> <tag> <sha> — force-move (or create) the lightweight ref
# refs/tags/<tag> on <repo> to <sha> via the GitHub API. THE channel-tag mover for every
# agent (promote + rollback), this-repo and cross-repo alike (#1076): the API path is
# granted the release-manager App's ruleset bypass for tag UPDATEs, whereas a local
# `git push --force` is not (013 on protected channel tags) and also fails with
# "nonexistent object" for a cross-repo host commit absent from this checkout (#1054).
# Tries PATCH (existing ref) then falls back to POST (create the ref).
# The operative PATCH must NOT swallow stderr (#743): a promotion-due run was failing with
# only the generic caller-side "failed to move" because both calls discarded the API error,
# hiding the real GitHub rejection (ruleset/bypass/permission). Capture the response and
# surface it as a single-line ::error::. The POST create-ref fallback is taken ONLY when the
# PATCH is a genuine 404/"not found" (the ref does not yet exist) — for any OTHER failure a
# POST would 422 "Reference already exists" and MASK the real rejection, so we stop and report.
_gh_move_tag() {
  [ $# -lt 3 ] && return 1
  local repo="$1" tag="$2" sha="$3" out rc
  out="$(_gh_write api -X PATCH "repos/$repo/git/refs/tags/$tag" \
      -f sha="$sha" -F force=true 2>&1)" && return 0
  rc=$?
  # Only a genuinely-absent ref warrants creating it; every other PATCH failure is a real
  # rejection to surface, not to paper over with a create. GitHub reports an absent ref two ways:
  # a 404 "Not Found", and — the case that took the scheduled promote-all red every 4h (#1019) —
  # a PATCH of a never-created channel tag returns 422 "Reference does not exist". Both are
  # create-if-missing signals; "Reference already exists" (a distinct 422) is NOT, so it still
  # falls through to the surfaced rejection below.
  local low="${out,,}"
  if [[ "$low" != *"not found"* && "$low" != *"http 404"* && "$low" != *"reference does not exist"* ]]; then
    # #749: on a 403 "Resource not accessible by integration" — the failure #745/#746 did NOT
    # fix — dump the write token's EFFECTIVE permissions + scope so the next step is decided
    # from data, not another guess. Only runs on the 403 branch (a non-404 that is also a
    # permission 403), before the ::error:: so the diagnostic and the surfaced rejection are
    # co-located in the run log. Best-effort: never alters rc.
    if [[ "$low" == *"403"* || "$low" == *"not accessible by integration"* ]]; then
      _gh_403_diag "$repo" >&2 || true
    fi
    echo "::error::_gh_move_tag: could not move refs/tags/$tag -> ${sha:0:12} on $repo (HTTP): ${out//$'\n'/ }" >&2
    return "$rc"
  fi
  out="$(_gh_write api -X POST "repos/$repo/git/refs" \
      -f ref="refs/tags/$tag" -f sha="$sha" 2>&1)" && return 0
  rc=$?
  echo "::error::_gh_move_tag: could not create refs/tags/$tag -> ${sha:0:12} on $repo (HTTP): ${out//$'\n'/ }" >&2
  return "$rc"
}

# _gh_403_diag <repo> — one-shot effective-permission diagnostic (#749), called only from the
# _gh_move_tag 403 failure path. #745/#746 (repo-scoped write token) did NOT resolve the 403
# "Resource not accessible by integration" on a protected channel-tag PATCH, so before guessing
# again we DUMP DATA, using the SAME token the PATCH used (_gh_write → CANARY_WRITE_TOKEN when
# set). This distinguishes the two possible root causes:
#   (a) the token LACKS effective contents:write → a minting bug (code-fixable), or
#   (b) the token HAS contents:write but the release-channel-tags ruleset bypass lapsed → NOT a
#       code bug (a maintainer must re-save bypass_actors / open GitHub support).
# Emits, to stderr, inside a foldable ::group:::
#   - X-Accepted-GitHub-Permissions from `gh api -i repos/<repo>` (the perms the API advertises),
#   - total_count from /installation/repositories (how many repos the installation token covers).
# Best-effort: every probe is guarded, and the function always returns 0 — a diagnostic must
# never mask the 403 or change the mover's exit status.
_gh_403_diag() {
  local repo="$1" hdr inst count=""
  echo "::group::_gh_move_tag 403 effective-permission diagnostic (#749)"
  if [ -n "${CANARY_WRITE_TOKEN:-}" ]; then
    echo "diag: introspecting with CANARY_WRITE_TOKEN (repo-scoped write token)"
  else
    echo "diag: introspecting with ambient GH_TOKEN (no CANARY_WRITE_TOKEN set)"
  fi
  # (1) What permission does the API advertise for this repo endpoint?
  hdr="$(_gh_write api -i "repos/$repo" 2>/dev/null | grep -i '^x-accepted-github-permissions:' || true)"
  if [ -n "$hdr" ]; then
    printf 'diag: %s\n' "${hdr%$'\r'}"
  else
    echo "diag: X-Accepted-GitHub-Permissions header not present on repos/$repo response"
  fi
  # (2) How many repositories does the installation token cover?
  inst="$(_gh_write api /installation/repositories 2>/dev/null || true)"
  if [ -n "$inst" ]; then
    count="$(jq -r '.total_count? // empty' <<<"$inst" 2>/dev/null || true)"
  fi
  if [ -n "$count" ]; then
    echo "diag: installation/repositories total_count=${count}"
  else
    echo "diag: installation/repositories total_count=<unreadable>"
  fi
  echo "::endgroup::"
  return 0
}

# _gh_create_annotated_tag <repo> <tag> <sha> <message> — create the immutable annotated
# tag object <tag> pointing at commit <sha> on <repo> and publish its ref, via the GitHub
# API with the release-manager App token (mirrors cut-release.sh's gh_create_annotated_tag).
# This is the CUT primitive for `autocut` (#1069): once the engine relocated to .github the
# sibling cut-release.sh no longer travels with it, so the cut runs inline through the same
# App-token path used for every other tag write — no dependency on a script left behind in
# another repo, and it writes to the agent's registry HOST (correct for the this-repo
# dev-lead agent whose reusable lives in .github-private, #613 relocation). Returns non-zero
# on API failure so the caller can degrade best-effort.
_gh_create_annotated_tag() {
  [ $# -lt 4 ] && return 1
  local repo="$1" tag="$2" sha="$3" message="$4" obj
  obj="$(_gh_write api -X POST "repos/$repo/git/tags" \
      -f tag="$tag" -f message="$message" -f object="$sha" -f type=commit \
      --jq '.sha // empty')"
  if [ $? -ne 0 ] || [ -z "$obj" ]; then
      echo "::error::_gh_create_annotated_tag: could not create the annotated release tag on $repo or read back its object SHA" >&2
      return 1
  fi
  _gh_write api -X POST "repos/$repo/git/refs" \
      -f ref="refs/tags/$tag" -f sha="$obj" >/dev/null 2>&1 || {
      echo "::error::_gh_create_annotated_tag: created tag object $obj on $repo but could not publish ref refs/tags/$tag" >&2
      return 1
  }
}

# _agent_current_major <agent> — the MAJOR of the agent's highest vX.Y.Z release on its
# host, empty if none (major-scoped-channels epic #657, Phase F4). This is the "current
# major line" a v-scoped channel tag is derived against; there is no new registry field —
# it is derived from the release tags already present (mirrors _next_release_version).
# This is the RELEASE major and MUST NOT be used to resolve channel-scoped tags: a
# release-v14 / channel-v1 agent (v14 line not yet migrated to channel tags) would key on a
# nonexistent `v14-<tier>` line. Use _agent_current_channel_major for channel resolution (#1065).
declare -A _AGENT_MAJOR_CACHE=()

_agent_current_major() {
  local agent="$1"
  if [[ -v _AGENT_MAJOR_CACHE["$agent"] ]]; then
    echo "${_AGENT_MAJOR_CACHE["$agent"]}"
    return 0
  fi
  local versions highest major=""
  versions="$(_host_release_versions "$agent")"
  # shellcheck disable=SC2086
  highest="$(max_semver $versions)"
  if [ -n "$highest" ]; then
    major="$(major_component "$highest")"
  fi
  _AGENT_MAJOR_CACHE["$agent"]="$major"
  echo "$major"
}

# _channel_tag_commit <agent> <suffix> — commit the tag <agent>/<suffix> resolves to
# (empty if absent). Same host-vs-local resolution as channel_commit, generalized to an
# arbitrary channel suffix so a v-scoped `v<M>-<tier>` can be probed (epic #657 F4).
declare -A _CHANNEL_COMMIT_CACHE=()

_channel_tag_commit() {
  local agent="$1" suffix="$2" host key="${1}:${2}"
  if [[ -v _CHANNEL_COMMIT_CACHE["$key"] ]]; then
    echo "${_CHANNEL_COMMIT_CACHE["$key"]}"
    return 0
  fi
  local commit=""
  host="$(_agent_field "$agent" host)"
  if [ -n "$host" ] && [ "$host" != "$THIS_REPO" ]; then
    commit="$(_gh_tag_commit "$host" "$agent/$suffix")"
  else
    commit="$(git rev-parse -q --verify "refs/tags/$agent/$suffix^{commit}" 2>/dev/null \
      || git rev-parse -q --verify "$agent/$suffix^{commit}" 2>/dev/null || true)"
  fi
  _CHANNEL_COMMIT_CACHE["$key"]="$commit"
  echo "$commit"
}

# _agent_has_channel_major <agent> <major> — return 0 iff the agent's v-scoped channel line
# for <major> has been ESTABLISHED, signalled by the presence of its anchor tag
# `<agent>/v<M>-next`. A major line is always seeded at `next` (autocut opens `v<M>-next` on a
# major bump, #657 F4) and then extended tier-by-tier by promotion, so `v<M>-next` existing is
# the "has a channel major" test — distinct from merely having a vX.Y.Z RELEASE (the legacy
# bare-only fleet has releases but no v-scoped channel tags). Non-zero when the anchor is absent
# or <major> is empty, so resolution for such agents stays byte-identical to pre-F4.
_agent_has_channel_major() {
  local agent="$1" major="$2"
  [ -n "$major" ] || return 1
  _looks_like_oid "$(_channel_tag_commit "$agent" "v${major}-next")"
}

# _agent_current_channel_major <agent> — the highest MAJOR M for which the agent's v-scoped
# channel line has been ESTABLISHED, i.e. the `<agent>/v<M>-next` anchor exists; empty for the
# legacy bare-only fleet (no anchor). This is the CHANNEL major, distinct from _agent_current_major
# (the RELEASE major): a release-v14 / channel-v1 agent resolves to 1 here, so channel resolution
# targets the tags that actually exist (`v1-<tier>`) and never keys on a tagless `v14-<tier>` line
# (#1065). Derived from the same anchors _agent_has_channel_major probes: _host_release_versions
# strips `refs/tags/<agent>/v`, emitting `1-next` alongside `1.0.0`, so the `v<M>-next` anchors
# surface as `<M>-next` lines here.
declare -A _AGENT_CHANNEL_MAJOR_CACHE=()

_agent_current_channel_major() {
  local agent="$1"
  if [[ -v _AGENT_CHANNEL_MAJOR_CACHE["$agent"] ]]; then
    echo "${_AGENT_CHANNEL_MAJOR_CACHE["$agent"]}"
    return 0
  fi
  local major
  major="$(_host_release_versions "$agent" | sed -n 's/^\([0-9][0-9]*\)-next$/\1/p' | sort -n | tail -1)"
  _AGENT_CHANNEL_MAJOR_CACHE["$agent"]="$major"
  echo "$major"
}

# _resolved_channel <agent> <tier> — echo "<tag>\t<commit>" for the channel <agent> uses on
# <tier> (major-scoped-channels epic #657, Phase F4). When the agent has an ESTABLISHED channel
# major (its `v<M>-next` anchor exists) the v-scoped `<agent>/v<M>-<tier>` line is AUTHORITATIVE:
# resolve to it and DO NOT fall back to the bare tier when this tier's v-scoped tag is absent —
# its commit is simply empty, which makes the frontier treat the tier as not-yet-reached and a
# promotion CREATE the tag (#1065 AC1′). The old fallback stranded the v-line at the tier it was
# first seeded at, silently masking the gap until a stub deploy pinned a nonexistent ref. An
# agent with no channel major at all (the legacy bare-only fleet, which may still carry a vX.Y.Z
# release) keeps using the bare tier tag — byte-identical to pre-F4.
_resolved_channel() {
  local agent="$1" tier="$2" major tag suffix
  major="$(_agent_current_channel_major "$agent")"
  if _agent_has_channel_major "$agent" "$major"; then
    tag="$(channel_tag "$agent" "$tier" "$major")"; suffix="${tag#"$agent"/}"
    printf '%s\t%s\n' "$tag" "$(_channel_tag_commit "$agent" "$suffix")"
    return 0
  fi
  tag="$(channel_tag "$agent" "$tier")"; suffix="${tag#"$agent"/}"
  printf '%s\t%s\n' "$tag" "$(_channel_tag_commit "$agent" "$suffix")"
}

# _resolved_channel_tag <agent> <tier> — just the resolved tag name (no commit).
_resolved_channel_tag() { _resolved_channel "$1" "$2" | cut -f1; }

# channel_commit <agent> <channel> — commit the channel <agent> uses on <channel> resolves
# to (empty if the tag does not exist). Resolution is fall-back-safe on the major dimension
# (epic #657 F4): prefer the v-scoped tag, else the bare tier. Agents hosted in THIS repo
# resolve against the local checkout; a cross-repo agent's channel tags live on ITS host, so
# they are resolved there via the GitHub API — reading local refs resolves empty and the
# frontier falsely reports "fully rolled out" (#1049).
channel_commit() {
  _resolved_channel "$1" "$2" | cut -f2
}

# _gate_field <agent> <field> — read .agents[a].gate.<field> (empty if absent).
_gate_field() { _jq -r --arg a "$1" --arg f "$2" '.agents[$a].gate[$f] // empty'; }
# _gate_knob <agent> <transition_key> <field> — read a per-transition knob (empty if absent).
_gate_knob() { _jq -r --arg a "$1" --arg t "$2" --arg f "$3" '.agents[$a].gate.transitions[$t][$f] // empty'; }

# _iso_now_minus_days <ndays> — ISO-8601 Zulu timestamp n days ago (GNU or BSD date).
_iso_now_minus_days() {
  date -u -d "-${1} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v"-${1}d" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo ""
}
_to_z() {   # normalise any parseable timestamp to ISO-8601 Zulu (empty passes through)
  [ -z "${1:-}" ] && { echo ""; return 0; }
  date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || echo "$1"
}
_epoch() {
  date -u -d "$1" +%s 2>/dev/null \
    || date -u -v "$1" +%s 2>/dev/null \
    || echo 0
}

# _gh_candidate_cut_date <repo> <agent> <commit> — ISO-8601 Zulu tagger date of the
# release tag <agent>/vX.Y.Z on <repo> whose (dereferenced) commit equals <commit>. The
# cross-repo analogue of the local for-each-ref path: a cross-repo agent's release tags
# live on its host, not this checkout (#1049). Empty if no matching release tag is found.
#
# matching-refs/tags/<agent>/v matches EVERY <agent>/v… ref by prefix, so it also returns
# the v-scoped channel tags <agent>/v<M>-<tier> — which are lightweight (type=commit) and
# always point at a real commit. Because "-" (0x2D) sorts before "." (0x2E), such a channel
# tag precedes the release <agent>/v<M>.<m>.<p> and, when it points at the candidate commit,
# used to match first with an empty tagger date — wedging the gate at BLOCKED indeterminate
# (#1046). So every ref is filtered to a strict release suffix before it can match; a channel
# tag (or any other non-release <agent>/v… ref) is skipped, never the shadow of a release.
_gh_candidate_cut_date() {
  local repo="$1" agent="$2" commit="$3" ref obj type csha cdate
  while IFS=$'\t' read -r ref obj type; do
    [ -z "$obj" ] && continue
    _is_release_tag_suffix "${ref#refs/tags/"$agent"/}" || continue
    if [ "$type" = "tag" ]; then
      IFS=$'\t' read -r csha cdate < <(gh api "repos/$repo/git/tags/$obj" \
        --jq '[(.object?.sha // "" | tostring), (.tagger?.date // "" | tostring)] | @tsv' 2>/dev/null) || true
    else
      csha="$obj"; cdate=""
    fi
    if [ "$csha" = "$commit" ]; then _to_z "$cdate"; return 0; fi
  done < <(gh api "repos/$repo/git/matching-refs/tags/$agent/v" \
             --paginate \
             --jq '.[]? | [.ref, (.object?.sha // "" | tostring), (.object?.type // "" | tostring)] | @tsv' 2>/dev/null)
  echo ""
}

# candidate_cut_date <agent> <candidate_commit> — ISO-8601 Zulu tagger date of the
# immutable release tag <agent>/vX.Y.Z that points at the candidate commit. This is the
# per-candidate cumulative-window start (#548): health is measured since the candidate's
# OWN cut, NOT a rolling window — so a pre-cut failure of a prior version is excluded.
# For a cross-repo agent (host != THIS_REPO) the release tags live on the host, so the
# date is resolved there via the GitHub API instead of the local for-each-ref (#1049).
#
# The local glob refs/tags/<agent>/v* also matches the v-scoped channel tags
# <agent>/v<M>-<tier>, and for-each-ref sorts them before the release <agent>/v<M>.<m>.<p>
# ("-" < "."). A channel tag is lightweight, so its %(*objectname) is empty and its
# %(creatordate) is the COMMIT date — the same-repo counterpart of the #1046 shadow: the
# path silently reported the candidate's commit date instead of the release's tagger date.
# Refs are filtered to a strict release suffix, and only the annotated tag's dereferenced
# commit + %(creatordate) (its tagger date) is used — a lightweight ref's commit date is
# never substituted. The final fallback is the candidate commit's own date, unchanged.
candidate_cut_date() {
  local agent="$1" commit="$2" host ref deref cdate
  host="$(_agent_field "$agent" host)"
  if [ -n "$host" ] && [ "$host" != "$THIS_REPO" ]; then
    _gh_candidate_cut_date "$host" "$agent" "$commit"
    return 0
  fi
  while IFS='|' read -r ref _ deref cdate; do
    _is_release_tag_suffix "${ref#refs/tags/"$agent"/}" || continue
    [ -z "$deref" ] && continue   # lightweight release-named tag — no tagger date to trust
    if [ "$deref" = "$commit" ]; then _to_z "$cdate"; return 0; fi
  done < <(git for-each-ref \
             --format='%(refname)|%(objectname)|%(*objectname)|%(creatordate:iso-strict)' \
             "refs/tags/${agent}/v*" 2>/dev/null)
  git log -1 --format=%cI "$commit" 2>/dev/null || echo ""
}

# _gh_err_summary <stderr-text> — condense gh's stderr into a single line for the
# ::warning::/::error:: annotations so an operator can tell WHY a read failed (#810):
# a 403 secondary-rate-limit throttle, an auth failure, a transient 5xx, or a network
# blip demand very different responses. Emits "HTTP <status> <class>: <reason>" (or
# just "<class>: <reason>" when no HTTP status is present). Never fails.
_gh_err_summary() {
  local err="$1" status="" class reason="" lc line
  if [[ "$err" =~ HTTP[/\ ]?([0-9]{3}) ]]; then status="${BASH_REMATCH[1]}"; fi
  lc="${err,,}"
  if [[ "$lc" == *"secondary rate limit"* ]]; then class="secondary-rate-limit"
  elif [[ "$lc" == *"rate limit"* ]]; then class="rate-limit"
  elif [ "$status" = "401" ] || [[ "$lc" == *"bad credentials"* ]] || [[ "$lc" == *"requires authentication"* ]]; then class="auth"
  elif [ -n "$status" ] && [ "$status" -ge 500 ]; then class="server-error"
  elif [ "$status" = "403" ]; then class="forbidden"
  elif [ -n "$status" ] && [ "$status" -ge 400 ]; then class="client-error"
  else class="network-or-unknown"; fi
  # first non-blank line of gh's stderr, trimmed, capped so an annotation stays readable
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [ -n "${line//[[:space:]]/}" ]; then reason="$line"; break; fi
  done <<< "$err"
  reason="${reason:0:200}"
  if [ -n "$status" ]; then printf 'HTTP %s %s: %s' "$status" "$class" "$reason"
  else printf '%s: %s' "$class" "$reason"; fi
}

# _gh_retry_after <stderr-text> — seconds to wait per an EXPLICIT throttle hint gh
# surfaced (#810): a `Retry-After: N` header echo, a bare "retry after Ns", or an
# `x-ratelimit-reset: <epoch>` we convert to a delta from now. Empty when none —
# the caller then falls back to exponential+jittered backoff. Honoring the server's
# own hint avoids hammering a secondary-rate-limit window and getting throttled harder.
_gh_retry_after() {
  local err="$1" lc="${1,,}" secs="" now
  if [[ "$lc" =~ retry[-\ ]?after:?[\ ]*([0-9]+) ]]; then
    secs="${BASH_REMATCH[1]}"
  elif [[ "$lc" =~ x-ratelimit-reset:?[\ ]*([0-9]+) ]]; then
    now="$(date +%s)"; secs=$(( BASH_REMATCH[1] - now )); [ "$secs" -lt 0 ] && secs=0
  fi
  printf '%s' "$secs"
}

# _repo_wf_runs_cached <repo> <workflow> — ALL recent runs of one workflow on a repo
# (conclusion,createdAt,databaseId,workflowName), UNBOUNDED by date and memoized for the
# process, so the candidate / baseline / downgrade / correctness windows a single agent
# samples collapse from one `gh run list` per (repo × workflow × window) into ONE read
# per (repo × workflow) (#819). This is the fix for the secondary-rate-limit burst AND
# for the retry storm it caused: a workflow that has never run on a repo makes `gh run
# list --workflow` exit non-zero with "could not find any workflows named …" — a PERMANENT
# condition, not a transient one, so retrying it 6× with backoff (as #810's wrapper did
# for every error class) blew a fleet sweep out to ~20 min and got the job cancelled. We
# now classify that message as a legitimate empty result ([]) and never retry it; only a
# genuine transport error (403/5xx/network/auth) is retried and, if sustained, fails CLOSED.
#
# The cache is FILE-backed under $_RUNS_CACHE_DIR (exported by main() before the fan-out),
# because callers invoke this via command substitution — a subshell — so an in-memory array
# populated in one call would not survive to the next. When the dir is unset (a unit test
# calling _run_json directly), every call fetches. Tunable via CANARY_GH_RETRIES /
# CANARY_GH_RETRY_SLEEP (tests set 0). CANARY_GH_RETRY_AFTER_CAP caps server hints (default 900s).
_repo_wf_runs_cached() {
  local repo="$1" wf="$2" out err summary ra delay span expo errfile cachef key keyhash
  local attempts="${CANARY_GH_RETRIES:-6}" base="${CANARY_GH_RETRY_SLEEP:-2}" attempt=1
  local ra_cap="${CANARY_GH_RETRY_AFTER_CAP:-900}"
  case "$ra_cap" in ''|*[!0-9]*) ra_cap=900 ;; esac
  case "$attempts" in ''|*[!0-9]*) attempts=6 ;; esac
  case "$base" in ''|*[!0-9]*) base=2 ;; esac
  # Cache hit? A non-empty cache file for this (repo, workflow) — including a cached "[]"
  # for a no-runs / not-found workflow, so it is never re-queried within the sweep.
  if [ -n "${_RUNS_CACHE_DIR:-}" ]; then
    # Hash the (repo, workflow) key into the filename so distinct pairs can never collide.
    # A plain char-substitution (e.g. non-alnum → "_") would map a workflow named "A B" and
    # one named "A/B" on the same repo to the same file — cross-contaminating their cached
    # run history and so their gate health. Workflow display names carry spaces and em-dashes,
    # so this is a real collision surface. sha256 (not sha1/md5 — those trip weak-hash linters
    # and are collision-broken) keeps the mapping injective; fall back to substitution only if
    # no hasher exists. This is a filename derivation, not a security context.
    key="${repo}//${wf}"
    # sha256sum on Linux runners, shasum -a 256 on macOS; substitution only if neither
    # exists (and then, at worst, the pre-existing collision surface — never a crash).
    keyhash="$(printf '%s' "$key" | { sha256sum 2>/dev/null || shasum -a 256 2>/dev/null; } | cut -d' ' -f1)"
    [ -n "$keyhash" ] || keyhash="${key//[^A-Za-z0-9._-]/_}"
    cachef="$_RUNS_CACHE_DIR/${keyhash}.json"
    [ -s "$cachef" ] && { cat "$cachef"; return 0; }
  fi
  errfile="$(mktemp)"
  declare -p tmpfiles &>/dev/null || declare -g -a tmpfiles=()
  tmpfiles+=("$errfile")
  # Register the cleanup in THIS (sub)shell: command substitution forks a subshell that
  # does NOT inherit the parent's traps, so registering only on first declaration of
  # tmpfiles would leave every subshell invocation without one. Re-running `trap … EXIT`
  # in the same shell just reinstalls the same idempotent handler.
  trap 'rm -f "${tmpfiles[@]+"${tmpfiles[@]}"}"' EXIT
  while :; do
    if out="$(gh run list --repo "$repo" --workflow "$wf" \
        -L 1000 --json conclusion,createdAt,databaseId,workflowName 2>"$errfile")"; then
      rm -f "$errfile"; out="${out:-[]}"
      [ -n "${cachef:-}" ] && [ -d "$_RUNS_CACHE_DIR" ] && printf '%s' "$out" > "$cachef" 2>/dev/null || true
      printf '%s\n' "$out"; return 0
    fi
    err=""
    if [ -r "$errfile" ]; then
      err="$(<"$errfile")"
    fi
    # A workflow with no runs on this repo is NOT a fetch failure — `gh` just can't resolve
    # the name. Treat it as an empty result (and cache []) so it is neither retried nor
    # counted as an outage; retrying it was the #810→#803 cancellation storm.
    if [[ "${err,,}" == *"could not find any workflow"* ]] || [[ "${err,,}" == *"no workflows"* ]]; then
      rm -f "$errfile"
      [ -n "${cachef:-}" ] && [ -d "$_RUNS_CACHE_DIR" ] && printf '%s' '[]' > "$cachef" 2>/dev/null || true
      echo '[]'; return 0
    fi
    summary="$(_gh_err_summary "$err")"
    if [ "$attempt" -ge "$attempts" ]; then
      echo "::error::_run_json: failed to fetch run list for $repo (workflow=$wf) after $attempts attempt(s) — $summary" >&2
      # Record the fetch failure for the sync-issues resilience layer (#820). A sustained
      # outage does NOT cleanly abort the caller (command substitutions don't inherit errexit),
      # so _frontier_state can limp on and emit a misleadingly-clean line; a file flag survives
      # the subshell and lets _frontier_state_resilient know the data is a partial/failed fetch.
      # No-op unless sync-issues armed the flag, so every other read path is unchanged.
      [ -n "${_CANARY_FETCH_FAIL_FLAG:-}" ] && printf '%s\n' "$repo" >> "$_CANARY_FETCH_FAIL_FLAG" 2>/dev/null || true
      rm -f "$errfile"; return 1
    fi
    # Prefer the server's explicit throttle hint; otherwise exponential + full jitter.
    ra="$(_gh_retry_after "$err")"
    if [ -n "$ra" ] && [ "$ra" -gt 0 ]; then
      delay="$ra"
      [ "$delay" -gt "$ra_cap" ] && delay="$ra_cap"   # honor hint but cap runaway values
    else
      expo=$((attempt - 1)); [ "$expo" -gt 20 ] && expo=20     # guard the exponent from overflow
      delay=$(( base << expo ))
      span=$(( delay - base )); [ "$span" -lt 0 ] && span=0
      delay=$(( base + RANDOM % (span + 1) ))                    # full jitter in [base, delay]
      [ "$delay" -gt 30 ] && delay=30
    fi
    echo "::warning::_run_json: transient failure fetching run list for $repo (workflow=$wf), attempt $attempt/$attempts — $summary — retrying in ${delay}s" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}

# _run_json <repo> <workflow> <since_z> — the target workflow's runs on a repo since the
# given Zulu timestamp, filtered LOCALLY from the per-(repo,workflow) cache so the several
# windows an agent samples share one fetch (#819). Empty repo/wildcard → []. A genuine
# fetch failure fails CLOSED (non-zero) so an empty [] never masks real failures and
# green-lights a bad promotion. Empty since = no lower bound.
_run_json() {
  local repo="$1" wf="$2" since="$3" raw
  if [ -z "$repo" ] || [ "$repo" = '*' ]; then echo '[]'; return 0; fi
  raw="$(_repo_wf_runs_cached "$repo" "$wf")" || return 1
  # Local since cut, inclusive — the same window the old server-side `--created ">=$since"`
  # produced. jq on an empty/garbage payload falls back to [].
  jq -c --arg since "$since" \
    '[ .[]? | select($since == "" or (.createdAt // "") >= $since) ]' \
    <<< "${raw:-[]}" 2>/dev/null || echo '[]'
}

# _tier_sample <agent> <since_z> <repo...> — EXECUTED runs (success+failure) on the
# source tier since the candidate cut. Prints "<executed> <earliest_createdAt|->".
_tier_sample() {
  local agent="$1" since="$2"; shift 2
  local wf repo json executed=0 earliest="" e
  wf="$(_agent_field "$agent" run_workflow)"
  for repo in "$@"; do
    json="$(_run_json "$repo" "$wf" "$since")"
    executed=$(( executed + $(jq '[.[]?|select(.conclusion=="success" or .conclusion=="failure")]|length' 2>/dev/null <<< "${json:-[]}" || echo 0) ))
    e="$(jq -r '[.[]?|select(.conclusion=="success" or .conclusion=="failure")|.createdAt?]|min // empty' 2>/dev/null <<< "$json" || echo "")"
    if [ -n "$e" ] && { [ -z "$earliest" ] || [[ "$e" < "$earliest" ]]; }; then earliest="$e"; fi
  done
  echo "$executed ${earliest:--}"
}

# _benign_patterns <agent> <differs 0|1> — emit the per-reusable known-benign
# failure-class allowlist (#1025 P2) as TSV "<workflow_regex>\t<step_regex>", one entry
# per line. Empty if none apply. differs-aware (#668): when the candidate CHANGED the
# reusable (differs=1) only classes explicitly marked `version_independent: true` are
# emitted — a failure that occurs before/independent of the candidate's own code (e.g. a
# Dependabot-context secrets failure at startup) can never be candidate-caused, so it may
# be excluded even for a changed reusable. Every OTHER class stays disabled at differs=1,
# preserving the invariant that the allowlist cannot mask a candidate-introduced regression.
_benign_patterns() {
  _jq -r --arg a "$1" --arg d "${2:-0}" \
    '.agents[$a]?.gate?.benign_failure_classes? // []
     | map(select($d == "0" or .version_independent == true))
     | .[] | [(.workflow // ""), (.step // "")] | @tsv'
}

# _suspect_patterns <agent> — emit the per-reusable SUSPECT failure-class allowlist
# (#668 increment 2) as TSV "<workflow_regex>\t<step_regex>", one entry per line. Empty if
# none. Unlike benign, suspect classes are emitted regardless of differs: a SUSPECT verdict
# only surfaces at differs=1 (see classify_failure), but the class always participates so a
# differs=1 counted failure is triaged SUSPECT (blocks + carries guidance) instead of a bare
# REGRESSION. Suspect classes are NEVER excluded from cum_fail — they still block.
_suspect_patterns() {
  _jq -r --arg a "$1" \
    '.agents[$a]?.gate?.suspect_failure_classes? // []
     | .[] | [(.workflow // ""), (.step // "")] | @tsv'
}

# _suspect_downgrade_patterns <agent> — emit the per-reusable SUSPECT classes that OPT INTO
# auto_downgrade (#668 increment 6) as TSV
# "<workflow_regex>\t<step_regex>\t<min_baseline_sample>\t<margin_permille>", one per line;
# empty when no suspect class carries `auto_downgrade` (byte-identical increment-2 behaviour:
# an un-flagged SUSPECT is never downgraded). The knobs travel WITH the pattern so the
# orchestrator feeds decide_suspect_downgrade per class without a second registry read.
_suspect_downgrade_patterns() {
  _jq -r --arg a "$1" \
    '.agents[$a]?.gate?.suspect_failure_classes? // []
     | .[] | select(.auto_downgrade? != null)
     | [(.workflow // ""), (.step // ""),
        (.auto_downgrade?.min_baseline_sample? // 0), (.auto_downgrade?.margin_permille? // 0)]
     | @tsv'
}

# _suspect_class_counts <agent> <since_z> <before_z|-> <wf_re> <step_re> <repo...> — over the
# window [since_z, before_z) on the given tier repos, echo "<matched_failures> <executed> <incomplete>":
# executed = success+failure runs; matched = the failures whose failed-step signature matches
# THIS one suspect class (via benign_match, the same matcher triage uses); incomplete = the
# count of failure runs whose signature could not be retrieved (gh run view error — callers
# treat incomplete>0 as HOLD, not DOWNGRADE, since an unreadable run could be a non-match).
# before_z="-" means no upper bound. Powers the candidate-vs-baseline SUSPECT-class failure
# RATE that the auto-downgrade core compares (#668 increment 6). Reuses _run_json /
# _run_signature (the signature cache is warm from the cumulative-health pass on the
# candidate window).
_suspect_class_counts() {
  local agent="$1" since="$2" before="$3" wf_re="$4" step_re="$5"; shift 5
  local wf repo json rid rwf sig sig_rc matched=0 executed=0 incomplete=0 count
  wf="$(_agent_field "$agent" run_workflow)"
  local exec_filter='.[]?|select(.conclusion=="success" or .conclusion=="failure")'
  local fail_filter='.[]?|select(.conclusion=="failure")'
  if [ "$before" != "-" ]; then
    exec_filter="$exec_filter|select(.createdAt < \"$before\")"
    fail_filter="$fail_filter|select(.createdAt < \"$before\")"
  fi
  for repo in "$@"; do
    { [ -z "$repo" ] || [ "$repo" = '*' ]; } && continue
    json="$(_run_json "$repo" "$wf" "$since")"
    count="$(jq "[${exec_filter}]|length" 2>/dev/null <<< "$json" || echo 0)"
    executed=$(( executed + ${count:-0} ))
    while IFS=$'\t' read -r rid rwf || [ -n "$rid" ]; do
      rid="${rid%$'\r'}"
      rwf="${rwf%$'\r'}"
      [ -z "$rid" ] && continue
      sig_rc=0
      sig="$(_run_signature "$repo" "$rid")" || sig_rc=$?  # || prevents set -e on lookup failure
      if [ -z "$sig" ]; then
        [ "$sig_rc" -ne 0 ] && incomplete=$(( incomplete + 1 ))  # lookup failed; genuine empty sig is fine
        continue
      fi
      if [ "$(benign_match "$rwf" "$sig" "$wf_re" "$step_re")" = "yes" ]; then
        matched=$(( matched + 1 ))
      fi
    done < <(jq -r "[${fail_filter}]|.[]|[(.databaseId // \"\"|tostring),(.workflowName // \"\")]|@tsv" 2>/dev/null <<< "$json")
  done
  echo "$matched $executed $incomplete"
}

# Memoization cache for _run_signature: keyed by "repo:run_id".
# Avoids duplicate gh run view calls for the same (repo, run_id) across agents
# in evaluate-all (where multiple agents can share repos).
declare -A _RUN_SIG_CACHE=()

# _run_signature <repo> <run_id> — the failed step names of a run, joined by newlines
# (the "step/error signature" the allowlist matches against). Empty repo/wildcard/id or
# any gh error → "" with exit 1 (fail-closed: an unknown signature is never treated as
# benign, and callers that need to distinguish a lookup failure from a genuine empty
# signature check the exit code). A successful lookup with no failed steps → "" exit 0.
# The $'\x01' sentinel in the cache marks a prior lookup failure so it is not retried.
_run_signature() {
  local repo="$1" id="$2" cache_key sig json
  { [ -z "$repo" ] || [ "$repo" = '*' ] || [ -z "$id" ]; } && { echo ""; return 0; }
  cache_key="${repo}:${id}"
  if [[ -v _RUN_SIG_CACHE["$cache_key"] ]]; then
    if [ "${_RUN_SIG_CACHE[$cache_key]}" = $'\x01' ]; then
      echo ""; return 1  # cached lookup failure — signal to caller
    fi
    echo "${_RUN_SIG_CACHE[$cache_key]}"
    return 0
  fi
  # Use || { } so set -e does not trigger on a failing gh run view; the block caches the
  # sentinel and returns 1 to signal the lookup failure to callers that care (e.g.
  # _suspect_class_counts tracks incomplete evidence and HOLDs the downgrade).
  json="$(gh run view "$id" --repo "$repo" --json jobs 2>/dev/null)" || {
    _RUN_SIG_CACHE["$cache_key"]=$'\x01'
    echo ""; return 1
  }
  sig="$(jq -r '[.jobs[]?|.steps[]?|select(.conclusion=="failure")|.name] | join("\n")' \
    2>/dev/null <<< "$json" || echo "")"
  _RUN_SIG_CACHE["$cache_key"]="$sig"
  echo "$sig"
}

# _failure_benign <repo> <run_id> <workflow_name> <patterns_tsv> — return 0 if this
# in-window failure matches any allowlist entry, else 1. Fail-closed on an empty signature.
_failure_benign() {
  local repo="$1" rid="$2" rwf="$3" patterns="$4" sig wf_re step_re
  sig="$(_run_signature "$repo" "$rid")"
  [ -z "$sig" ] && return 1
  while IFS=$'\t' read -r wf_re step_re; do
    [ -z "$step_re" ] && continue
    if [ "$(benign_match "$rwf" "$sig" "$wf_re" "$step_re")" = "yes" ]; then return 0; fi
  done <<< "$patterns"
  return 1
}

# _failure_suspect <repo> <run_id> <workflow_name> <patterns_tsv> — return 0 if this
# in-window failure matches any SUSPECT allowlist entry (#668 increment 2), else 1. Reuses
# the benign_match pure matcher against the run's failed-step signature; fail-closed on an
# empty signature (an unknown signature is never treated as suspect). A suspect match does
# NOT exclude the failure — it narrows the triage verdict (SUSPECT vs REGRESSION) only.
_failure_suspect() {
  local repo="$1" rid="$2" rwf="$3" patterns="$4" sig wf_re step_re
  sig="$(_run_signature "$repo" "$rid")"
  [ -z "$sig" ] && return 1
  while IFS=$'\t' read -r wf_re step_re || [ -n "$wf_re" ]; do
    wf_re="${wf_re%$'\r'}"
    step_re="${step_re%$'\r'}"
    [ -z "$step_re" ] && continue
    if [ "$(benign_match "$rwf" "$sig" "$wf_re" "$step_re")" = "yes" ]; then return 0; fi
  done <<< "$patterns"
  return 1
}

# _cumulative_health <agent> <since_z> <differs 0|1> <repo...> — failures +
# startup_failures across EVERY given tier repo since the candidate cut. Failures
# matching the per-reusable known-benign allowlist (#1025 P2) are counted separately and
# excluded from the blocking total; which allowlist entries apply depends on whether the
# candidate changed the reusable (differs — see _benign_patterns, #668). A counted (non-
# benign) failure that matches a `suspect_failure_classes` entry sets the suspect flag
# (#668 increment 2) — it still counts toward the blocking total (SUSPECT blocks like
# REGRESSION), but downstream triage renders SUSPECT + guidance instead of a bare
# REGRESSION. Prints "<failures> <startup_failures> <benign_excluded> <suspect_count>".
_cumulative_health() {
  local agent="$1" since="$2" differs="$3"; shift 3
  local wf repo json fail=0 startup=0 benign=0 suspect=0 patterns="" suspect_patterns="" rid rwf
  wf="$(_agent_field "$agent" run_workflow)"
  patterns="$(_benign_patterns "$agent" "$differs")"
  suspect_patterns="$(_suspect_patterns "$agent")"
  for repo in "$@"; do
    json="$(_run_json "$repo" "$wf" "$since")"
    startup=$(( startup + $(jq '[.[]?|select(.conclusion=="startup_failure")]|length' 2>/dev/null <<< "${json:-[]}" || echo 0) ))
    if [ -z "$patterns" ] && [ -z "$suspect_patterns" ]; then
      # No benign or suspect patterns to match — count all failures with one jq pass,
      # avoiding a gh run view call per failure.
      fail=$(( fail + $(jq '[.[]?|select(.conclusion=="failure")]|length' 2>/dev/null <<< "${json:-[]}" || echo 0) ))
    else
      while IFS=$'\t' read -r rid rwf; do
        if [ -n "$patterns" ] && _failure_benign "$repo" "$rid" "$rwf" "$patterns"; then
          benign=$(( benign + 1 ))
        else
          fail=$(( fail + 1 ))
          if [ -n "$suspect_patterns" ] && _failure_suspect "$repo" "$rid" "$rwf" "$suspect_patterns"; then
            suspect=$(( suspect + 1 ))
          fi
        fi
      done < <(jq -r '.[]?|select(.conclusion=="failure")|[(.databaseId // "" | tostring),(.workflowName // "")]|@tsv' 2>/dev/null <<< "$json")
    fi
  done
  echo "$fail $startup $benign $suspect"
}

# _baseline_daily <agent> <window_days> <repo...> — per-day EXECUTED counts on the
# source tier over the trailing window_days (exactly window_days integers, zero-filled),
# feeding the robust spike-capped baseline for the sample target (#548).
_baseline_daily() {
  local agent="$1" window="$2"; shift 2
  local wf since repo json dates="" day i count out=""
  wf="$(_agent_field "$agent" run_workflow)"
  since="$(_iso_now_minus_days "$window")"
  for repo in "$@"; do
    json="$(_run_json "$repo" "$wf" "$since")"
    dates+="$(jq -r '.[]?|select(.conclusion=="success" or .conclusion=="failure")|.createdAt[0:10]?' 2>/dev/null <<< "$json" || true)"$'\n'
  done
  for (( i=0; i<window; i++ )); do
    day="$(date -u -d "-${i} days" +%Y-%m-%d 2>/dev/null || date -u -v"-${i}d" +%Y-%m-%d 2>/dev/null || echo "")"
    count=$(grep -c "^${day}$" 2>/dev/null <<< "$dates" || true)
    out+="${count} "
  done
  echo "${out% }"
}

# _reusable_differs <agent> <candidate_commit> <prior_commit> — 1 if the agent's reusable
# workflow blob differs between the candidate SHA and the prior channel SHA, else 0. Used
# by triage to confirm a CANDIDATE REGRESSION (#548): a failure whose reusable is identical
# to the prior version is pre-existing, not introduced by the candidate.
_reusable_differs() {
  local agent="$1" cand="$2" prior="$3" reusable a b host
  reusable="$(_agent_field "$agent" reusable)"
  [ -z "$reusable" ] || [ -z "$cand" ] || [ -z "$prior" ] && { echo 0; return 0; }
  host="$(_agent_field "$agent" host)"; host="${host:-$THIS_REPO}"
  if [ "$host" = "$THIS_REPO" ]; then
    # This-repo agent: the reusable blob lives in the local checkout.
    a="$(git rev-parse -q --verify "${cand}:${reusable}" 2>/dev/null || echo "")"
    b="$(git rev-parse -q --verify "${prior}:${reusable}" 2>/dev/null || echo "")"
  else
    # Cross-repo agent (#613): the reusable blob lives on the HOST repo, not locally —
    # a local `git rev-parse` would resolve empty and wrongly report "unchanged". Resolve
    # the blob SHA on the host via gh api, like the autocut path does.
    a="$(_gh_blob_sha "$host" "$reusable" "$cand")"
    b="$(_gh_blob_sha "$host" "$reusable" "$prior")"
  fi
  # Fail CLOSED: an unresolvable compare counts as "changed" so the benign-failure
  # allowlist is disabled and a genuine candidate regression is never masked.
  { [ -z "$a" ] || [ -z "$b" ]; } && { echo 1; return 0; }
  [ "$a" != "$b" ] && { echo 1; return 0; }
  echo 0
}

# ── decision telemetry sampling (#668 Layer 2, increment 4) ─────────────────────
# Feeds the pure decision-shift core (decide_decision_shift / decision_class in the lib)
# with real decision-mix tallies gathered from `gh run view --json jobs` step names — the
# same surface the benign/suspect check already fetches. Reserved for agents that opt into
# gate.correctness; every other agent skips this path entirely (byte-identical).

# Memoization for _run_decision_class, keyed "repo:run_id" (the decision class is
# prefix-independent given the run, so the prefix is not part of the key). Distinct from
# _RUN_SIG_CACHE: decision sampling hits SUCCESS runs, the signature cache hits FAILED runs,
# so the two never fetch the same run twice.
declare -A _RUN_DECISION_CACHE=()

# _run_decision_class <repo> <run_id> <prefix> — the decision class a run took (the taken
# `<prefix><class>` no-op step; skipped branches ignored), via `gh run view --json jobs`.
# Empty on missing repo/id or any gh error (fail-open: a run with no decision step simply
# contributes nothing to the tally, degrading toward INSUFFICIENT, never a false SHIFT).
_run_decision_class() {
  local repo="$1" id="$2" prefix="$3" cache_key json cls
  { [ -z "$repo" ] || [ "$repo" = '*' ] || [ -z "$id" ]; } && { echo ""; return 0; }
  cache_key="${repo}:${id}"
  if [[ -v _RUN_DECISION_CACHE["$cache_key"] ]]; then
    echo "${_RUN_DECISION_CACHE[$cache_key]}"; return 0
  fi
  json="$(gh run view "$id" --repo "$repo" --json jobs 2>/dev/null || echo '{}')"
  cls="$(decision_class "$prefix" "$json")"
  _RUN_DECISION_CACHE["$cache_key"]="$cls"
  echo "$cls"
}

# _sample_decision_counts <agent> <prefix> <max_k> <since_z> <before_z|-> <repo...> — tally the
# decision-class mix of up to <max_k> EXECUTED runs (newest first) on the given tier repos in
# the window [since_z, before_z). before_z="-" means no upper bound (all runs since <since_z>).
# Runs with no decision step are skipped (they do not consume a sample slot). Echoes a compact
# JSON object "<class>":<count>; "{}" when nothing qualifies. Pure-core (decide_decision_shift)
# reads the object; the min-sample knobs gate sufficiency.
_sample_decision_counts() {
  local agent="$1" prefix="$2" max_k="$3" since="$4" before="$5"; shift 5
  local wf repo json rid cls sampled=0
  wf="$(_agent_field "$agent" run_workflow)"
  declare -A counts=()
  local filter='.[]?|select(.conclusion=="success" or .conclusion=="failure")'
  [ "$before" != "-" ] && filter="$filter|select(.createdAt < \"$before\")"
  for repo in "$@"; do
    [ "$sampled" -ge "$max_k" ] && break
    { [ -z "$repo" ] || [ "$repo" = '*' ]; } && continue
    json="$(_run_json "$repo" "$wf" "$since")"
    while IFS= read -r rid; do
      [ -z "$rid" ] && continue
      [ "$sampled" -ge "$max_k" ] && break
      cls="$(_run_decision_class "$repo" "$rid" "$prefix")"
      [ -z "$cls" ] && continue
      counts["$cls"]=$(( ${counts["$cls"]:-0} + 1 ))
      sampled=$(( sampled + 1 ))
    done < <(jq -r "[${filter}]|sort_by(.createdAt)|reverse|.[]|(.databaseId|tostring)" 2>/dev/null <<< "$json")
  done
  # Build the counts object in a SINGLE jq pass (one process, not one per key) —
  # jq does the key/value escaping so arbitrary class names stay valid JSON.
  local out k
  out="$(for k in "${!counts[@]}"; do printf '%s\t%s\n' "$k" "${counts[$k]}"; done \
    | jq -Rn '[inputs | split("\t") | {(.[0]): (.[1] | tonumber)}] | add // {}' 2>/dev/null)"
  [ -n "$out" ] || out='{}'
  echo "$out"
}

# _correctness_verdict <agent> <cand_commit> <cut_z> <src_repos_csv> — OK|SHIFT|INSUFFICIENT for
# an agent that opts into gate.correctness (empty when it does not). Candidate mix = source-tier
# runs since the candidate cut; baseline mix = source-tier runs in the trailing window BEFORE the
# cut (the prior version on identical traffic — the enumerable stand-in for "the incumbent on
# comparable traffic", since the stable ring is often the unenumerable `*`). Delegates the gate
# to the pure decide_decision_shift.
_correctness_verdict() {
  local agent="$1" cand="$2" cut_z="$3" src_csv="$4"
  local knobs prefix
  knobs="$(_jq -c --arg a "$agent" '.agents[$a].gate.correctness')"
  prefix="$(jq -r '.decision_step_prefix // "decision: "' <<< "$knobs" 2>/dev/null || echo "decision: ")"
  local src_repos=() r
  IFS=, read -r -a src_repos <<< "$src_csv"
  local win base_since cand_counts base_counts
  win="${SOAK_WINDOW_DAYS:-$(_gate_field "$agent" baseline_window_days)}"; win="${win:-14}"
  base_since="$(_iso_now_minus_days "$win")"
  # K=15 candidate / K=25 baseline — n in the 10–25 band the design targets; the min-sample
  # knobs (below the caps) gate sufficiency, so a thin sample degrades to INSUFFICIENT.
  cand_counts="$(_sample_decision_counts "$agent" "$prefix" 15 "$cut_z" "-" "${src_repos[@]}")"
  base_counts="$(_sample_decision_counts "$agent" "$prefix" 25 "$base_since" "$cut_z" "${src_repos[@]}")"
  decide_decision_shift "$cand_counts" "$base_counts" "$knobs"
}

# _decision_mix_table <agent> <cand_commit> — a markdown table of the candidate vs prior-version
# baseline decision-class share (permille, rounded like decide_decision_shift), for the blocker
# body of a correctness-SHIFT hold (#668 L2). Recomputes the same source-tier samples as
# _correctness_verdict (the per-run classes are memoized in _RUN_DECISION_CACHE, so the second
# pass is cache-warm). Empty when the agent has no gate.correctness or the frontier is resolved.
_decision_mix_table() {
  local agent="$1" cand="$2"
  local knobs; knobs="$(_jq -c --arg a "$agent" '.agents[$a].gate.correctness // ""')"
  [ -z "$knobs" ] || [ "$knobs" = '""' ] && return 0
  local chans frontier="" ch c
  chans="$(ordered_channels "$agent")"
  local chan_array=(); IFS=, read -r -a chan_array <<< "$chans"
  for ch in "${chan_array[@]}"; do
    c="$(channel_commit "$agent" "$ch")"
    if [ "$ch" = "next" ] || [ "$c" = "$cand" ]; then :; else frontier="$ch"; break; fi
  done
  [ -z "$frontier" ] && return 0
  local transition source cut_z prefix
  transition="$(transition_key "$frontier" "$chans")"
  source="${transition%%->*}"
  cut_z="$(candidate_cut_date "$agent" "$cand")"
  [ -z "$cut_z" ] && return 0
  prefix="$(jq -r '.decision_step_prefix // "decision: "' <<< "$knobs" 2>/dev/null || echo "decision: ")"
  local src_repos=() r
  while IFS= read -r r; do [ -n "$r" ] && src_repos+=("$r"); done < <(resolve_members "$agent" "$source")
  local win base_since cand_counts base_counts
  win="${SOAK_WINDOW_DAYS:-$(_gate_field "$agent" baseline_window_days)}"; win="${win:-14}"
  base_since="$(_iso_now_minus_days "$win")"
  cand_counts="$(_sample_decision_counts "$agent" "$prefix" 15 "$cut_z" "-" "${src_repos[@]}")"
  base_counts="$(_sample_decision_counts "$agent" "$prefix" 25 "$base_since" "$cut_z" "${src_repos[@]}")"
  # Guard against an empty sample string — --argjson rejects empty input.
  # (A `${var:-{}}` inline default is NOT usable: the inner `}` closes the
  #  parameter expansion, appending a stray brace and producing invalid JSON.)
  [ -n "$cand_counts" ] || cand_counts='{}'
  [ -n "$base_counts" ] || base_counts='{}'
  jq -nr --argjson c "$cand_counts" --argjson b "$base_counts" --arg win "$win" '
    ([$c[]?]|add // 0) as $ct | ([$b[]?]|add // 0) as $bt
    | (($c|keys) + ($b|keys) | unique) as $classes
    | "| decision class | candidate | baseline | Δ |",
      "|---|---|---|---|",
      ( $classes[]
        | ( if $ct>0 then ((( ($c[.]//0)*1000 + ($ct/2) ) / $ct) | floor) else 0 end ) as $cs
        | ( if $bt>0 then ((( ($b[.]//0)*1000 + ($bt/2) ) / $bt) | floor) else 0 end ) as $bs
        | (($cs - $bs) | if . < 0 then -. else . end) as $d
        | "| `\(.)` | \($cs/10)% (\($c[.]//0)) | \($bs/10)% (\($b[.]//0)) | \($d/10)pp |" ),
      "",
      "_candidate n=\($ct) (source tier since cut) · baseline n=\($bt) (prior version, trailing \($win) d). Share = rounded per-mille; Δ is the absolute shift the gate compares to `max_shift_permille`._"
  ' 2>/dev/null || return 0
}

# _frontier_state <agent> — compute the rollout frontier and graduated gate, echoing:
#   "<cand> <frontier> <transition> <state> <dwell_h> <dwell_floor> <sample> <target> <cum_fail> <cum_startup> <cum_benign> <triage> <mix_shift> <downgrade> <dg_cand_rate> <dg_cand_sample> <dg_base_rate> <dg_base_sample>"
# frontier = first ring (after next) not yet on the candidate commit; triage is "-"
# unless state is BLOCKED (then REGRESSION | PRE_EXISTING | SUSPECT). mix_shift is "SHIFT"
# when a gate.correctness decision-mix shift is holding the promotion (#668 L2), else "-".
# downgrade is "DOWNGRADE" when a SUSPECT was auto-downgraded to PRE_EXISTING (#668 inc6) —
# then triage already reads PRE_EXISTING and dg_* carry the candidate-vs-baseline permille
# rates + sample sizes that drove it; "-"/0 otherwise.
_frontier_state() {
  local agent="$1"
  local cand chans frontier=""
  cand="$(channel_commit "$agent" next)"
  chans="$(ordered_channels "$agent")"

  local chan_array=()
  IFS=, read -r -a chan_array <<< "$chans"
  local ch
  for ch in "${chan_array[@]}"; do
    local c; c="$(channel_commit "$agent" "$ch")"
    if [ "$ch" = "next" ] || [ "$c" = "$cand" ]; then :; else frontier="$ch"; break; fi
  done
  if [ -z "$frontier" ]; then
    echo "$cand - - COMPLETE 0 0 0 0 0 0 0 - -"; return 0
  fi

  local transition source cut_z now_epoch
  transition="$(transition_key "$frontier" "$chans")"
  source="${transition%%->*}"
  cut_z="$(candidate_cut_date "$agent" "$cand")"
  if [ -z "$cut_z" ]; then
    # Cannot determine the per-candidate window start — fail closed to prevent unbounded history queries.
    echo "$cand $frontier $transition BLOCKED 0 0 0 0 0 0 0 - -"; return 0
  fi
  now_epoch="$(date -u +%s)"

  # Source-tier repos (the tier currently running the candidate).
  local src_repos=() r
  while IFS= read -r r; do [ -n "$r" ] && src_repos+=("$r"); done < <(resolve_members "$agent" "$source")

  # Sample on the source tier over the per-candidate window.
  local sample earliest
  read -r sample earliest < <(_tier_sample "$agent" "$cut_z" "${src_repos[@]}")

  # Dwell is always measured from the candidate's own cut (tagger date), per #548 spec.
  local dwell_h=0
  local cut_epoch; cut_epoch="$(_epoch "$cut_z")"
  if [ "$cut_epoch" -gt 0 ]; then
    dwell_h=$(( (now_epoch - cut_epoch) / 3600 ))
  fi
  [ "$dwell_h" -lt 0 ] && dwell_h=0

  # Whether the candidate changed the agent's reusable vs the prior channel on the frontier.
  # At differs=1 the known-benign allowlist narrows to classes marked version_independent
  # (#668) — inherently context-caused failures that can never be candidate-introduced —
  # and every other class is disabled, so the allowlist can never mask a candidate-introduced
  # regression (#1025 P2).
  local prior differs
  prior="$(channel_commit "$agent" "$frontier")"
  differs="$(_reusable_differs "$agent" "$cand" "$prior")"

  # Cumulative health across EVERY concrete tier repo since the candidate's own cut.
  local all_repos=() ch3
  for ch3 in "${chan_array[@]}"; do
    while IFS= read -r r; do [ -n "$r" ] && [ "$r" != '*' ] && all_repos+=("$r"); done \
      < <(resolve_members "$agent" "$ch3")
  done
  local cum_fail cum_startup cum_benign cum_suspect
  read -r cum_fail cum_startup cum_benign cum_suspect < <(_cumulative_health "$agent" "$cut_z" "$differs" "${all_repos[@]}")

  # Per-transition knobs (registry-configurable; #548 defaults live in the ring SoT).
  local dwell_floor waived="false" target=0
  dwell_floor="$(_gate_knob "$agent" "$transition" dwell_hours)"; dwell_floor="${dwell_floor:-0}"
  if [ "$(_gate_knob "$agent" "$transition" waive_sample)" = "true" ]; then
    waived="true"
  elif [ -n "$(_gate_knob "$agent" "$transition" sample_min)" ]; then
    target="$(_gate_knob "$agent" "$transition" sample_min)"
  else
    local win frac cmin cmax spike_cap daily baseline_total
    win="${SOAK_WINDOW_DAYS:-$(_gate_field "$agent" baseline_window_days)}"; win="${win:-14}"
    frac="$(_gate_knob "$agent" "$transition" sample_fraction_permille)"; frac="${frac:-250}"
    cmin="$(_gate_knob "$agent" "$transition" sample_clamp_min)"; cmin="${cmin:-3}"
    cmax="$(_gate_knob "$agent" "$transition" sample_clamp_max)"; cmax="${cmax:-15}"
    spike_cap="$(_gate_field "$agent" baseline_spike_cap_multiple)"; spike_cap="${spike_cap:-3}"
    daily="$(_baseline_daily "$agent" "$win" "${src_repos[@]}")"
    baseline_total=0; for c in $daily; do baseline_total=$(( baseline_total + c )); done
    if [ "$baseline_total" -eq 0 ] && [ "$(_gate_knob "$agent" "$transition" waive_sample_if_no_caller)" = "true" ]; then
      waived="true"   # dwell-only: the source tier has no caller (#548)
    else
      # shellcheck disable=SC2086
      target="$(robust_sample_target "$frac" "$cmin" "$cmax" "$spike_cap" $daily)"
    fi
  fi

  local state; state="$(decide_graduated "$dwell_h" "$dwell_floor" "$sample" "$target" "$waived" "$cum_fail" "$cum_startup")"

  # Layer 2 (#668 increment 4): opt-in DECISION telemetry. When the reliability verdict is
  # PROMOTE and the agent opts into gate.correctness, tally the candidate's decision mix vs a
  # prior-version baseline; a gross distribution SHIFT HOLDS the promotion (BLOCKED, triage
  # SUSPECT — the correctness variant, flagged by mix_shift). INSUFFICIENT/OK are no-ops, so an
  # agent that produces no comparable signal degrades to reliability-only. The overlay fires
  # ONLY from an otherwise-PROMOTE verdict — it never masks or bypasses a reliability BLOCK, and
  # it never rolls back or auto-acts (worst case: a few hours of human latency).
  local mix_shift="-"
  if [ "$state" = "PROMOTE" ] && [ -n "$(_gate_field "$agent" correctness)" ]; then
    local src_csv verdict
    src_csv="$(IFS=,; echo "${src_repos[*]}")"
    verdict="$(_correctness_verdict "$agent" "$cand" "$cut_z" "$src_csv")"
    if [ "$verdict" = "SHIFT" ]; then
      state="BLOCKED"; mix_shift="SHIFT"
    fi
  fi

  # Layer 3 (#668 increment 3): opt-in human confirmation at a ring boundary. When the
  # reliability verdict is PROMOTE but the frontier transition sets require_confirmation, hold
  # in a distinct AWAITING_CONFIRMATION state — SOAKING-like: the scheduled promote-all never
  # auto-advances it. It is cleared only by a deliberate `promote <agent> --confirm` (the
  # dispatch IS the confirmation; no state store). The overlay fires ONLY from an otherwise-
  # PROMOTE (reliability-clean) verdict, so `--confirm` can never bypass a BLOCKED gate.
  if [ "$state" = "PROMOTE" ] && [ "$(_gate_knob "$agent" "$transition" require_confirmation)" = "true" ]; then
    state="AWAITING_CONFIRMATION"
  fi

  # Triage: a correctness SHIFT is SUSPECT (correctness variant, distinguished by mix_shift);
  # any other BLOCK is classified from the failure evidence.
  local triage="-"
  if [ "$state" = "BLOCKED" ] && [ "$mix_shift" = "SHIFT" ]; then
    triage="SUSPECT"
  elif [ "$state" = "BLOCKED" ]; then
    triage="$(classify_failure "$differs" "${CANARY_FAILURE_CATEGORY:-unknown}" "$cum_suspect")"
  fi

  # SUSPECT → PRE_EXISTING auto-downgrade (#668 increment 6, opt-in per suspect class). Only the
  # failure-class SUSPECT variant is eligible — mix_shift="-" excludes the correctness variant,
  # which is never rate-comparable. For each suspect class carrying `auto_downgrade`, compare the
  # candidate's failure RATE for that class (matched/executed over the per-candidate window) with
  # the prior version's over the trailing baseline window; the pure decide_suspect_downgrade
  # decides. DOWNGRADE re-triages PRE_EXISTING (report-only: no needs-human, advances with
  # --allow-pre-existing); HOLD stays SUSPECT (increment-2 behaviour — worse/ambiguous/thin cases
  # keep the human). Byte-identical for a suspect class with no auto_downgrade (empty set → skip).
  local downgrade="-" dg_cand_rate=0 dg_cand_sample=0 dg_base_rate=0 dg_base_sample=0
  if [ "$triage" = "SUSPECT" ] && [ "$mix_shift" = "-" ]; then
    local dg_patterns; dg_patterns="$(_suspect_downgrade_patterns "$agent")"
    # Guard (Thread 1): only attempt per-class rate comparison when EVERY blocking failure
    # has been attributed to a suspect class. If any failure had no matching suspect class,
    # that unrelated failure is an independent regression and must keep the gate blocked.
    if [ -n "$dg_patterns" ] && [ "${cum_suspect:-0}" -ge "$cum_fail" ]; then
      local dg_win dg_base_since dwf dsr dmin dmargin cm ce cmi bm be bei crate brate knobs decision
      dg_win="${SOAK_WINDOW_DAYS:-$(_gate_field "$agent" baseline_window_days)}"; dg_win="${dg_win:-14}"
      dg_base_since="$(_iso_now_minus_days "$dg_win")"
      while IFS=$'\t' read -r dwf dsr dmin dmargin || [ -n "$dwf" ]; do
        dwf="${dwf%$'\r'}"; dsr="${dsr%$'\r'}"; dmin="${dmin%$'\r'}"; dmargin="${dmargin%$'\r'}"
        [ -z "$dsr" ] && continue
        read -r cm ce cmi < <(_suspect_class_counts "$agent" "$cut_z" "-" "$dwf" "$dsr" "${src_repos[@]}")
        read -r bm be bei < <(_suspect_class_counts "$agent" "$dg_base_since" "$cut_z" "$dwf" "$dsr" "${src_repos[@]}")
        # Guard (Thread 2): if any signature lookup failed, baseline class evidence is
        # incomplete. A missing run could be a non-match; fail-closed and skip DOWNGRADE.
        [ "${cmi:-0}" -gt 0 ] || [ "${bei:-0}" -gt 0 ] && continue
        if [ "${ce:-0}" -gt 0 ]; then crate="$(round_div $(( ${cm:-0} * 1000 )) "$ce")"; else crate=0; fi
        if [ "${be:-0}" -gt 0 ]; then brate="$(round_div $(( ${bm:-0} * 1000 )) "$be")"; else brate=0; fi
        knobs="$(printf '{"min_baseline_sample":%s,"margin_permille":%s}' "${dmin:-0}" "${dmargin:-0}")"
        decision="$(decide_suspect_downgrade "$crate" "$brate" "$be" "$knobs")"
        if [ "$decision" = "DOWNGRADE" ]; then
          triage="PRE_EXISTING"; downgrade="DOWNGRADE"
          dg_cand_rate="$crate"; dg_cand_sample="$ce"; dg_base_rate="$brate"; dg_base_sample="$be"
          break
        fi
      done <<< "$dg_patterns"
    fi
  fi

  echo "$cand $frontier $transition $state $dwell_h $dwell_floor $sample $target $cum_fail $cum_startup $cum_benign $triage $mix_shift $downgrade $dg_cand_rate $dg_cand_sample $dg_base_rate $dg_base_sample"
}

cmd_evaluate() {
  local agent="$1"
  echo "== canary-rollout evaluate: $agent (gate standard: .github#548) =="
  local cand_tag cand
  IFS=$'\t' read -r cand_tag cand < <(_resolved_channel "$agent" next)
  echo "candidate (${cand_tag#"$agent"/}) = ${cand:0:12}  cut=$(candidate_cut_date "$agent" "$cand")"
  local chan_array=()
  IFS=, read -r -a chan_array <<< "$(ordered_channels "$agent")"
  local ch
  for ch in "${chan_array[@]}"; do
    local ch_tag c
    IFS=$'\t' read -r ch_tag c < <(_resolved_channel "$agent" "$ch")
    local mark="  "; [ -n "$cand" ] && [ "$c" = "$cand" ] && mark="* "
    printf '  %s%-7s -> %s\n' "$mark" "${ch_tag#"$agent"/}" "${c:0:12}"
  done
  read -r _cand frontier transition state dwell floor sample target cum_fail cum_startup cum_benign triage mix_shift downgrade dg_cand_rate dg_cand_sample dg_base_rate dg_base_sample < <(_frontier_state "$agent")
  echo "----"
  if [ "$frontier" = "-" ]; then
    echo "frontier: none — fully rolled out (all rings on candidate)."
  else
    gate_summary_line "$transition" "$state" "$dwell" "$floor" "$sample" "$target" "$cum_fail" "$cum_startup" "$cum_benign"
    echo "decision for next ring '$frontier' [$transition]: $state"
    if [ "$state" = "BLOCKED" ]; then
      if [ "$triage" = "REGRESSION" ]; then
        echo "::error::triage=REGRESSION — candidate changed the reusable and a run failed since cut. HALT + hold; recommend rollback."
      elif [ "$triage" = "SUSPECT" ] && [ "$mix_shift" = "SHIFT" ]; then
        echo "::warning::triage=SUSPECT (decision-mix shift, #668 Layer 2) — the candidate's decision distribution moved ≥ threshold vs the prior-version baseline. HOLDS the promotion; review the decision-mix table in the blocker issue. Composition drift (e.g. a draft-PR burst) is the usual false positive → promote --override to dismiss; a genuine always/never shift → roll back."
      elif [ "$triage" = "SUSPECT" ]; then
        echo "::warning::triage=SUSPECT — failure matches a suspect class (possibly candidate-caused). BLOCKS + needs a human; see the blocker issue's discriminating question, then promote --override if unrelated or roll back if a real regression."
      elif [ "$downgrade" = "DOWNGRADE" ]; then
        echo "::notice::triage=PRE_EXISTING (auto-downgraded from SUSPECT, #668 increment 6) — the candidate's suspect-class failure rate (${dg_cand_rate}‰ over ${dg_cand_sample} runs) is no worse than the prior version's (${dg_base_rate}‰ over ${dg_base_sample} runs), so the timeout is environmental, not a candidate regression. Report only; the SUSPECT hold auto-cleared (no human needed). Advances with --allow-pre-existing once dwell/sample pass."
      elif [ "$triage" = "PRE_EXISTING" ]; then
        echo "::warning::triage=PRE_EXISTING — failure is pre-existing/environmental. Report only; do NOT rollback. Advances with --allow-pre-existing (or control.allow_pre_existing in the registry) once dwell/sample pass."
      else
        echo "::warning::state=BLOCKED (indeterminate) — could not resolve the candidate's cut date, so the gate fails closed and holds (not a detected failure; cum_fail=$cum_fail). Clears once the candidate's cut date/tag is resolvable."
      fi
    elif [ "$state" = "AWAITING_CONFIRMATION" ]; then
      echo "::notice::state=AWAITING_CONFIRMATION — reliability PASSED; holding for an opt-in human go/no-go at $transition (#668 Layer 3). Review the canary-confirm issue, then dispatch: promote $agent --confirm  (not --override)."
    fi
  fi
}

# cmd_evaluate_all — read-only evaluate for EVERY agent in the ring registry (#1025 P1).
# The 4h schedule runs this so the whole fleet is evaluated on the timer, not just one
# agent. Iterates the registry keys, so newly-registered reusables are picked up with no
# workflow change. Never mutates (evaluate is read-only).
cmd_evaluate_all() {
  local agents rc=0 agent
  agents="$(_jq -r '.agents | keys[]' 2>/dev/null || true)"
  if [ -z "$agents" ]; then
    echo "no agents registered in $CANARY_RINGS — nothing to evaluate."; return 0
  fi
  echo "== canary-rollout evaluate-all: fleet-wide (gate standard: .github#548) =="
  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    echo "──────── agent: $agent ────────"
    cmd_evaluate "$agent" || rc=$?
  done <<< "$agents"
  return "$rc"
}

cmd_promote() {
  local agent="$1"; shift
  local override=false dry=false allow_pre_flag=false confirm=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --override) override=true ;;
      --confirm)  confirm=true ;;
      --dry-run)  dry=true ;;
      --allow-pre-existing) allow_pre_flag=true ;;
      *) echo "::error::unknown promote flag: $1" >&2; return 2 ;;
    esac; shift
  done
  read -r cand frontier transition state _dwell _floor _sample _target cum_fail _cum_startup _cum_benign triage _mix_shift _dg _dgcr _dgcs _dgbr _dgbs < <(_frontier_state "$agent")
  if [ "$frontier" = "-" ]; then
    echo "nothing to promote — $agent is fully rolled out."; return 0
  fi
  # allow_pre: advance a BLOCKED frontier ONLY when triage=PRE_EXISTING (never REGRESSION).
  # Sourced from the per-reusable control block or the --allow-pre-existing flag (#1025 P2).
  local allow_pre
  allow_pre="$(_jq -r --arg a "$agent" '.agents[$a].gate?.control?.allow_pre_existing // false')"
  [ "$allow_pre_flag" = true ] && allow_pre=true
  # REGRESSION and SUSPECT both HALT + need a human: neither advances without --override,
  # and --allow-pre-existing (which only unblocks PRE_EXISTING) never advances them. For a
  # SUSPECT the human answers the class's discriminating question first — `--override` when
  # the timeout is unrelated to the diff, or roll back when the candidate got materially
  # slower (#668 increment 2).
  if [ "$state" = "BLOCKED" ] && { [ "$triage" = "REGRESSION" ] || [ "$triage" = "SUSPECT" ]; } && [ "$override" != true ]; then
    echo "::error::gate=BLOCKED (triage=$triage) for '$frontier' [$transition] — candidate regression suspected; not promoting. Investigate + rollback, do not --override blindly."
    return 0
  fi
  local advance=false
  [ "$state" = "PROMOTE" ] && advance=true
  [ "$override" = true ] && advance=true
  [ "$state" = "BLOCKED" ] && [ "$triage" = "PRE_EXISTING" ] && [ "$allow_pre" = true ] && advance=true
  # Layer 3 (#668 increment 3): a human --confirm advances an AWAITING_CONFIRMATION frontier
  # (reliability is already PROMOTE — the state is only ever set from an otherwise-PROMOTE
  # verdict). --confirm is NOT --override: it clears ONLY this state and can never advance a
  # BLOCKED gate, so it cannot bypass reliability.
  [ "$state" = "AWAITING_CONFIRMATION" ] && [ "$confirm" = true ] && advance=true
  if [ "$advance" != true ]; then
    if [ "$state" = "AWAITING_CONFIRMATION" ]; then
      echo "gate=AWAITING_CONFIRMATION for ring '$frontier' [$transition] — reliability PASSED; holding for an opt-in human go/no-go. Review the canary-confirm issue, then dispatch: promote $agent --confirm  (--confirm advances ONLY this reliability-clean state; it is NOT --override)."
    else
      echo "gate=$state for ring '$frontier' [$transition] (cum_fail=$cum_fail, triage=$triage) — not promoting. (use --override, or --allow-pre-existing for a PRE_EXISTING triage, after investigating)"
    fi
    return 0
  fi
  if [ "$state" = "AWAITING_CONFIRMATION" ] && [ "$confirm" = true ]; then
    echo "::notice::human confirmation received (--confirm) — advancing $agent/$frontier [$transition] past the confirmation go/no-go (reliability was already PROMOTE)."
  elif [ "$state" != "PROMOTE" ]; then
    echo "::warning::advancing $agent/$frontier despite gate state '$state' (triage=$triage)"
  fi
  # Consistent move (#1076): EVERY agent moves its channel tag via `gh api` on its HOST
  # repo — never a local `git push`. A local force-push is NOT granted the release-manager
  # App's ruleset bypass for a tag UPDATE, so it 013s on a protected channel tag such as
  # dev-lead/next; the API path (same App token) IS honored as a bypass actor. host
  # defaults to THIS_REPO for an agent whose registry entry omits it.
  local host
  host="$(_jq -r --arg a "$agent" '.agents[$a].host // "" | tostring')"
  host="${host:-$THIS_REPO}"
  # Move the RESOLVED frontier tag (major-scoped-channels epic #657, F4): advance the
  # v-scoped `<agent>/v<M>-<tier>` within its major line when it exists, else the legacy
  # bare `<agent>/<tier>`. A v2 promotion never touches a v1 tag. The logical tier
  # ($frontier) is unchanged — it still drives the gate + is reported as promoted_ring.
  local frontier_tag; frontier_tag="$(_resolved_channel_tag "$agent" "$frontier")"
  echo "advancing $frontier_tag -> ${cand:0:12} on $host"
  if [ "$dry" = true ]; then
    echo "[DRY-RUN] would: gh api PATCH repos/$host/git/refs/tags/$frontier_tag sha=$cand (force)"
    return 0
  fi
  _gh_move_tag "$host" "$frontier_tag" "$cand" \
    || { echo "::error::failed to move $frontier_tag -> ${cand:0:12} on $host" >&2
         # Persist this FAILED tag write (#1023 defect 2). It is UNEXPECTED — a permission/API
         # rejection on the WRITE — distinct from an expected gate-block, which returns above
         # before ever reaching the move. sync-promotion-failures turns a repeatedly-failing
         # write into a durable, escalating blocker issue instead of a scrolling log line.
         _log_promotion_failure "$agent" "$frontier" "$cand" "$host" "tag write rejected ($frontier_tag on $host)"
         return 1; }
  echo "promoted $frontier_tag -> ${cand:0:12}"
  # Expose the move for the workflow's GitHub Deployment (traceability, #502). The
  # deployment must be created on the repo that OWNS the moved commit: a cross-repo agent's
  # candidate SHA lives on its host, NOT on THIS_REPO — creating the deployment against
  # GITHUB_REPOSITORY 422s with "No ref found" (#1059). So emit the owning repo too.
  local deploy_repo="$host"   # the repo that OWNS the moved commit (#1059); host==THIS_REPO for this-repo agents
  # GITHUB_OUTPUT is single-valued (last write wins), fine for a single `promote`. For
  # `promote-all` (many promotions per run) the workflow reads CANARY_PROMOTIONS_LOG — one
  # TSV line per promotion — so it can record a deployment for EVERY move, not just the last.
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { echo "promoted_agent=$agent"; echo "promoted_ring=$frontier"
      echo "promoted_sha=$cand";   echo "promoted_host=$deploy_repo"; } >> "$GITHUB_OUTPUT"
  fi
  if [ -n "${CANARY_PROMOTIONS_LOG:-}" ]; then
    printf '%s\t%s\t%s\t%s\n' "$agent" "$frontier" "$cand" "$deploy_repo" >> "$CANARY_PROMOTIONS_LOG"
  fi
}

# _log_promotion_failure <agent> <ring> <cand> <host> <reason> — append a FAILED tag-write to the
# SIBLING failure log (#1023 defect 2), the counterpart of the CANARY_PROMOTIONS_LOG success log.
# Only genuine write failures land here (the caller is cmd_promote's post-move error path) — a
# gate-blocked promotion returns before the move and is NEVER recorded, keeping the two concerns
# distinct: an expected gate-block stays the canary-blocker issue's job; an unexpected tag-write
# failure is what this log (and sync-promotion-failures) escalates. No-op when the log is unset.
_log_promotion_failure() {
  [ -n "${CANARY_PROMOTIONS_FAILED_LOG:-}" ] || return 0
  if ! printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$CANARY_PROMOTIONS_FAILED_LOG"; then
    echo "::warning::could not append failure record for $1 to ${CANARY_PROMOTIONS_FAILED_LOG} (unwritable path?); tag-write failure may not be escalated." >&2
  fi
}

# cmd_promote_all [--override] [--allow-pre-existing] [--dry-run] — the gated fleet
# auto-promote and the SCHEDULED arm of the automation (#1045 part b). Iterates every
# registry agent and calls cmd_promote for each, so each PROMOTE-ready agent advances
# exactly one ring per run while BLOCKED/REGRESSION agents are left untouched by the gate
# unless --override is passed (the scheduled workflow never passes it). A per-agent
# failure is logged and skipped so one agent cannot halt the fleet sweep. Flags are
# forwarded verbatim to every cmd_promote.
cmd_promote_all() {
  local agents rc=0 agent
  agents="$(_jq -r '.agents? | keys[]?' 2>/dev/null || true)"
  if [ -z "$agents" ]; then
    echo "no agents registered in $CANARY_RINGS — nothing to promote."; return 0
  fi
  echo "== canary-rollout promote-all: fleet-wide (gate standard: .github#548) =="
  local failed=()
  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    echo "──────── agent: $agent ────────"
    cmd_promote "$agent" "$@" || { rc=$?; echo "::warning::promote of $agent returned $rc (continuing fleet)"; failed+=("$agent($rc)"); }
  done <<< "$agents"
  # A per-agent promote failure is deliberately ISOLATED (logged "continuing fleet" above) so one
  # agent cannot halt the sweep — but propagating its rc also took the whole scheduled promote-all
  # red every 4h (#1019), even for a per-agent failure already surfaced as a ::warning:: and, when
  # it is a held/blocked promotion, tracked by sync-issues. Return success from the fleet sweep;
  # genuine per-agent failures remain visible in the log and the blocker-issue path, not via a red
  # scheduled run. (A single-agent `promote <agent>` still returns that agent's real exit code.)
  #
  # BUT a green run must not imply "everything promoted" (#1019 review): with the rc swallowed, a
  # permission or API rejection would otherwise be indistinguishable from a clean sweep unless
  # someone read the whole log. Emit ONE aggregated summary naming every failed agent, so the
  # failure is visible at a glance in the job summary while the sweep still exits 0.
  if [ ${#failed[@]} -gt 0 ]; then
    echo "::warning title=promote-all: ${#failed[@]} agent(s) failed::${failed[*]} — the sweep still exits 0 by design (#1019); investigate these before trusting a green promote-all."
    echo "promote-all summary: ${#failed[@]} failed — ${failed[*]}"
  else
    echo "promote-all summary: all agents promoted or already current."
  fi
  return 0
}

cmd_rollback() {
  local agent="$1" ring="$2"; shift 2
  local to="" dry=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --to)
        if [ $# -lt 2 ]; then echo "::error::--to requires a value" >&2; return 2; fi
        to="$2"; shift
        ;;
      --dry-run) dry=true ;;
      *) echo "::error::unknown rollback flag: $1" >&2; return 2 ;;
    esac; shift
  done
  [ -z "$to" ] && { echo "::error::rollback requires --to <vX.Y.Z>" >&2; return 2; }
  # Consistent path (#1076), mirroring cmd_promote: the target lookup AND the move both go
  # through gh api on the agent's HOST repo for every agent — never local git. host defaults
  # to THIS_REPO for an agent whose registry entry omits it.
  local host
  host="$(_jq -r --arg a "$agent" '.agents[$a].host // "" | tostring')"
  host="${host:-$THIS_REPO}"
  local target
  target="$(_gh_tag_commit "$host" "$agent/$to")"
  [ -z "$target" ] && { echo "::error::release tag $agent/$to not found on $host" >&2; return 1; }
  echo "rolling back $agent/$ring -> $to (${target:0:12}) on $host"
  if [ "$dry" = true ]; then
    echo "[DRY-RUN] would: gh api PATCH repos/$host/git/refs/tags/$agent/$ring sha=$target (force)"
    return 0
  fi
  _gh_move_tag "$host" "$agent/$ring" "$target" \
    || { echo "::error::failed to move $agent/$ring -> $to on $host" >&2; return 1; }
  echo "rolled back $agent/$ring -> $to"
}

# ── blocker-issue + fleet-status automation (auto-triage of held promotions) ────
# The gate detects + classifies a BLOCKED promotion; sync-issues turns that signal into
# a tracked work item: one idempotent issue per BLOCKED agent (with the failing-run
# evidence pre-attached), auto-closed when the gate clears, plus the whole-fleet status
# table rendered into the run's job summary (a read-only snapshot — not an issue). Runs on
# the schedule after promote-all. All GitHub writes are best-effort — a failure here never
# fails the promotion run.
ISSUE_REPO="${ISSUE_REPO:-$THIS_REPO}"

# _issue_find <label> <marker> — "<number>\t<STATE>" of the newest issue carrying <marker>
# in its body (matched locally over the label's issues, not GitHub search — HTML-comment
# markers are not reliably indexed). Empty if none.
_issue_find() {
  local label="$1" marker="$2"
  gh issue list --repo "$ISSUE_REPO" --label "$label" --state all -L 100 \
      --json number,state,body 2>/dev/null \
    | jq -r --arg m "$marker" \
        '[.[] | select((.body // "") | contains($m))] | sort_by(.number) | last
         | if . == null then "" else "\(.number)\t\(.state | ascii_upcase)" end' 2>/dev/null \
    || echo ""
}

# _gh_issue_create <title> <body> <labels_csv> — create an issue, echo its number.
_gh_issue_create() {
  gh issue create --repo "$ISSUE_REPO" --title "$1" --body "$2" --label "$3" 2>/dev/null \
    | grep -oE '[0-9]+$' | tail -1
}

# _blocker_evidence <agent> <candidate_commit> — markdown bullets for the in-window failing
# runs (repo + run link + failed-step signature), capped at 8. Uses the SAME per-candidate
# window + tier repos the gate counts, so the evidence matches cum_fail.
_blocker_evidence() {
  local agent="$1" cand="$2" wf cut_z repo json r n=0 out=""
  wf="$(_agent_field "$agent" run_workflow)"
  cut_z="$(candidate_cut_date "$agent" "$cand")"
  [ -z "$cut_z" ] && { printf '_(no candidate cut date resolved — cannot list failing runs)_\n'; return 0; }
  local chan_array=() ch all=() seen=" " dedup=()
  IFS=, read -r -a chan_array <<< "$(ordered_channels "$agent")"
  for ch in "${chan_array[@]}"; do
    while IFS= read -r r; do [ -n "$r" ] && [ "$r" != '*' ] && all+=("$r"); done < <(resolve_members "$agent" "$ch")
  done
  for r in "${all[@]}"; do case "$seen" in *" $r "*) ;; *) dedup+=("$r"); seen+="$r ";; esac; done
  for repo in "${dedup[@]}"; do
    json="$(_run_json "$repo" "$wf" "$cut_z")"
    local rid sig
    while IFS= read -r rid; do
      [ -z "$rid" ] && continue
      if [ "$n" -ge 8 ]; then out+="- _(…more failing runs; truncated at 8)_"$'\n'; printf '%s' "$out"; return 0; fi
      sig="$(_run_signature "$repo" "$rid" | tr '\n' ';' | sed 's/;$//')"
      out+="- \`$repo\` — run [$rid](https://github.com/$repo/actions/runs/$rid); failed steps: ${sig:-unknown}"$'\n'
      n=$((n+1))
    done < <(jq -r '.[]?|select(.conclusion=="failure" or .conclusion=="startup_failure")|(.databaseId|tostring)' 2>/dev/null <<< "$json")
  done
  [ -z "$out" ] && out="_(no failing runs in the per-candidate window — cum_fail may be startup_failures or a transient count)_"$'\n'
  printf '%s' "$out"
}

# _suspect_guidance <agent> — emit the discriminating question(s) for the agent's
# suspect_failure_classes (#668 increment 2), one bullet per class, so a SUSPECT blocker
# tells the human exactly how to confirm in ~30 seconds. Empty if the agent has none.
_suspect_guidance() {
  _jq -r --arg a "$1" \
    '.agents[$a]?.gate?.suspect_failure_classes? // []
     | .[] | select((.guidance // "") != "")
     | "- **\(.id):** \(.guidance)"'
}

# _blocker_body <agent> <transition> <cand> <cum_fail> <cum_startup> <triage> <host> <evidence> [<mix_shift>] [<mix_table>] [<downgrade>] [<dg_cand_rate>] [<dg_cand_sample>] [<dg_base_rate>] [<dg_base_sample>] [<data_gap>]
_blocker_body() {
  local agent="$1" transition="$2" cand="$3" cum_fail="$4" cum_startup="$5" triage="$6" host="$7" evidence="$8" mix_shift="${9:--}" mix_table="${10:-}" note
  local downgrade="${11:--}" dg_cand_rate="${12:-0}" dg_cand_sample="${13:-0}" dg_base_rate="${14:-0}" dg_base_sample="${15:-0}" data_gap="${16:-0}"
  # Correctness variant (#668 L2): a decision-mix SHIFT holds as SUSPECT but is NOT a reliability
  # failure — the candidate exited green yet its decision distribution moved. Distinct note + a
  # candidate-vs-baseline mix table replace the failing-runs evidence (there are none).
  if [ "$triage" = "SUSPECT" ] && [ "$mix_shift" = "SHIFT" ]; then
    note="> ⚠️ **SUSPECT (decision-mix shift, #668 Layer 2)** — reliability PASSED (the candidate exits green), but its decision-class distribution shifted materially vs the prior version on comparable traffic. This HOLDS and needs a human (labelled \`needs-human\`): decide whether the shift is an intended behaviour change (\`promote --override\`) or a correctness regression (roll back). The gate never rolls back on its own."
    cat <<EOF
<!-- canary-blocker:$agent -->
**Automated canary-rollout blocker.** The release gate is holding \`$agent\` and will not promote it until this clears. Filed + maintained by the Canary Rollout workflow (gate standard: .github#548); this issue is **regenerated each run and auto-closes** when the gate passes — do not edit the table below by hand.

| field | value |
|---|---|
| agent | \`$agent\` |
| transition | \`$transition\` |
| candidate | \`${cand:0:12}\` |
| host repo | \`$host\` |
| triage | **SUSPECT** (decision-mix shift) |

$note

### Decision-mix (candidate vs prior-version baseline)
${mix_table:-_(mix table unavailable — samples could not be resolved)_}
---
_Whole-fleet status is in the Canary Rollout workflow run's job summary (Actions → Canary Rollout → latest run → Summary)._
EOF
    return 0
  fi
  if [ "$triage" = "REGRESSION" ]; then
    note="> ⛔ **REGRESSION** — the candidate changed the reusable and a run failed since its cut. HALT + hold; investigate and roll back rather than \`--override\`. (labelled \`needs-human\`)"
  elif [ "$triage" = "SUSPECT" ]; then
    local guidance; guidance="$(_suspect_guidance "$agent")"
    [ -z "$guidance" ] && guidance="- _(no per-class guidance registered)_"
    note="> ⚠️ **SUSPECT** — the candidate changed the reusable and a run failed with a *possibly-candidate-caused* signature. This still BLOCKS and needs a human (labelled \`needs-human\`), but answer the discriminating question below to confirm fast: if unrelated to the diff, \`promote --override\`; if the candidate is materially responsible, treat it as a real regression and roll back.
>
> **Discriminating question:**
$(printf '%s\n' "$guidance" | sed 's/^/> /')"
  elif [ "$downgrade" = "DOWNGRADE" ]; then
    note="> ℹ️ **PRE_EXISTING** — *auto-downgraded from SUSPECT (#668 increment 6).* This failure matched a suspect class that opts into data-driven auto-downgrade, and the candidate's failure rate for that class is **no worse** than the prior version's on comparable traffic — so it is environmental, not a candidate regression. The SUSPECT hold auto-cleared: report only, **no human needed**, and the frontier advances with \`--allow-pre-existing\` once dwell/sample pass. (A materially-worse or thin-baseline case would have stayed SUSPECT.)
>
> **Suspect-class failure rate (candidate vs prior-version baseline):**
>
> | version | rate (‰) | runs |
> |---|---|---|
> | candidate | \`$dg_cand_rate\` | $dg_cand_sample |
> | baseline | \`$dg_base_rate\` | $dg_base_sample |"
  elif [ "$triage" = "PRE_EXISTING" ]; then
    note="> ⚠️ **PRE_EXISTING** — the failure is pre-existing/environmental (reusable byte-identical to the prior channel). Report only; the gate will not roll back or advance. Fix-forward, and the armed timer auto-promotes once clean."
  else
    # Fail-closed hold (_frontier_state: cut_z empty) — state=BLOCKED but triage="-" and cum_fail=0.
    # There is no detected failure; the gate could not resolve the candidate's cut date, so it
    # holds rather than evaluate an unbounded window. Do NOT claim PRE_EXISTING here (there is
    # nothing environmental to report) — say what actually happened.
    note="> ℹ️ **INDETERMINATE (gate held — candidate cut date unresolved)** — the gate could not resolve this candidate's cut date, so it fails closed and holds the promotion instead of evaluating an unbounded run history. This is **not** a detected run failure (cumulative failures: $cum_fail). It usually clears on its own once the candidate's release tag/cut date becomes resolvable; if it persists, verify that candidate \`${cand:0:12}\` is a tagged, resolvable commit on \`$host\`."
  fi
  # Data-gap fail-closed (#820): run history was unreadable this tick, so the cumulative counts
  # are NOT reliable and the triage verdict rests on the reusable diff alone. Prepend a banner
  # (before the triage note) and blank out the misleading "0" cumulative-failures cell.
  local cum_row="**$cum_fail** (startup_failures: $cum_startup)"
  if [ "$data_gap" = "1" ]; then
    cum_row="_unknown — run history unavailable this tick_"
    note="> ⚠️ **PARTIAL DATA (run-history fetch failed) — FAILING CLOSED.** The canary gate could not read this agent's recent run history this tick (a sustained GitHub API failure — see the workflow log). Rather than report a false all-clear, the gate holds the promotion and keeps this issue open. The cumulative counts below are **not reliable for this tick**; the triage verdict is derived from the reusable diff alone. This clears automatically once run history is readable again and the gate re-evaluates.
>
$note"
  fi
  cat <<EOF
<!-- canary-blocker:$agent -->
**Automated canary-rollout blocker.** The release gate is holding \`$agent\` and will not promote it until this clears. Filed + maintained by the Canary Rollout workflow (gate standard: .github#548); this issue is **regenerated each run and auto-closes** when the gate passes — do not edit the table below by hand.

| field | value |
|---|---|
| agent | \`$agent\` |
| transition | \`$transition\` |
| candidate | \`${cand:0:12}\` |
| host repo | \`$host\` |
| cumulative failures | $cum_row |
| triage | **$triage** |

$note

### Failing runs in the per-candidate window
$evidence
---
_Whole-fleet status is in the Canary Rollout workflow run's job summary (Actions → Canary Rollout → latest run → Summary)._
EOF
}

# _confirm_body <agent> <transition> <cand> <prior> <host> <sample> <target> — the body of the
# evidence-carrying human-confirmation issue for an AWAITING_CONFIRMATION frontier (#668 Layer 3).
# Reliability has PASSED; a human confirms the candidate is behaving CORRECTLY (not merely exiting
# green) before it reaches the stable tier (all consumers). Marker-keyed (canary-confirm:<agent>)
# so sync-issues upserts it idempotently and auto-closes it on promote/candidate change.
_confirm_body() {
  local agent="$1" transition="$2" cand="$3" prior="$4" host="$5" sample="$6" target="$7"
  local suspect; suspect="$(_suspect_guidance "$agent")"
  local watch=""
  [ -n "$suspect" ] && watch="

### Watch for (suspect classes registered for this agent)
$suspect"
  local diff_link
  if [ -n "$prior" ]; then
    diff_link="https://github.com/$host/compare/${prior}...${cand}"
  else
    diff_link="(no prior stable release)"
  fi
  local display_prior="${prior:0:12}"
  display_prior="${display_prior:-none}"
  cat <<EOF
<!-- canary-confirm:$agent -->
**Canary rollout — human confirmation requested (\`$transition\`).**

The release gate holds \`$agent\` in **AWAITING_CONFIRMATION**: reliability has PASSED (dwell + sample + cumulative health all clean), but this transition is flagged \`require_confirmation\` (#668 Layer 3), so a human confirms the candidate is behaving *correctly* — not merely exiting green — before it reaches the stable tier (all consumers). Filed + maintained by the Canary Rollout workflow; **regenerated each run and auto-closes** when the promotion is confirmed or the candidate changes — do not edit by hand.

| field | value |
|---|---|
| agent | \`$agent\` |
| transition | \`$transition\` |
| candidate | \`${cand:0:12}\` |
| current stable | \`$display_prior\` |
| host repo | \`$host\` |
| reliability | ✅ PROMOTE — source-tier sample **$sample** (target ≥ $target), cumulative health clean |

### Review the candidate
- **Diff (current stable → candidate):** $diff_link
- Skim the changed reusable logic and the recent green runs on the ring1 tier before confirming.$watch

### Confirm or hold
- **Go:** dispatch the **Canary Rollout** workflow → command \`promote\`, agent \`$agent\`, **confirm = true** (or run \`promote $agent --confirm\` locally). \`--confirm\` advances ONLY this reliability-clean state; it is **not** \`--override\` and cannot bypass a failing gate.
- **No-go:** if the candidate looks wrong, roll back instead of confirming (\`rollback $agent <ring> --to <prior release>\`).
---
_Whole-fleet status is in the Canary Rollout workflow run's job summary (Actions → Canary Rollout → latest run → Summary)._
EOF
}

# _dashboard_md <rows_md> <timestamp> — the fleet-status table. This is a read-only snapshot
# (not a work item), so it is rendered into the GitHub Actions run's job summary — NOT filed
# as an issue: it needs no Issues:write, spawns no synthetic pinned issue, and shows on the
# run's Summary page every tick. The per-agent BLOCKED issues remain issues (they are
# trackable, assignable, closable work items).
_dashboard_md() {
  cat <<EOF
# Canary Rollout — fleet status

Last updated: \`$2\` · auto-promote armed: \`${CANARY_AUTO_PROMOTE:-unset}\` · gate standard: .github#548.

| agent | state | transition | cum_fail | triage | blocker |
|---|---|---|---|---|---|
$1

\`PROMOTE\`/\`COMPLETE\`/\`SOAKING\` need no action. \`BLOCKED\` opens a per-agent issue (label \`canary-blocker\`) with the failing-run evidence; it auto-closes when the gate clears. \`AWAITING_CONFIRMATION\` (reliability passed, held for a human go/no-go at a \`require_confirmation\` boundary, #668 Layer 3) opens a \`canary-confirm\` issue with the diff link; confirm via \`promote <agent> --confirm\`.
EOF
}

# _frontier_state_resilient <agent> — sync-issues resilience wrapper (#820). _frontier_state
# reads run history (_run_json), and on a SUSTAINED fetch failure (#738 fail-closed) it does
# NOT cleanly stop: command substitutions don't inherit errexit, so it limps on and emits a
# misleadingly-CLEAN state line (or aborts to empty). Either way sync-issues could no longer
# tell a CLEARED agent from an UNREADABLE one — silently dropping (or auto-closing) a
# regression's tracked issue: the safety net defeated by exactly the failures it should record.
# So _run_json records each fetch failure to a file flag we arm here; when it fires we DISCARD
# _frontier_state's output and instead determine everything that does NOT need run history
# (candidate, frontier, transition, reusable-differs → triage) from tag/blob resolution, and
# FAIL CLOSED to BLOCKED so the tracked issue is upserted (never a green no-op). Emits the 18
# _frontier_state fields PLUS a trailing DATA-GAP flag (0=normal state resolved, 1=partial
# run-history). Returns NON-ZERO only when even the candidate/frontier cannot be resolved — a
# TOTAL inability stays a hard error, surfaced by the caller.
_frontier_state_resilient() {
  local agent="$1" out="" rc=0 fetch_failed=0
  # Arm a file flag that _run_json appends to on a sustained fetch failure. A file (not a shell
  # var) is used because _frontier_state runs in a command-substitution subshell, and a var set
  # there would not survive back to us — the file does.
  local flag; flag="$(mktemp 2>/dev/null || echo "")"
  if [ -z "$flag" ]; then
    # Cannot arm the fetch-failure detector at all — treat as an unreadable tick rather
    # than silently falling back to the old undetectable-outage behavior.
    fetch_failed=1
    out="$(_frontier_state "$agent")" || rc=$?
  else
    # `|| rc=$?` catches any abort so set -e does not tear down the fleet loop on one agent.
    export _CANARY_FETCH_FAIL_FLAG="$flag"
    out="$(_frontier_state "$agent")" || rc=$?
    unset _CANARY_FETCH_FAIL_FLAG
    [ -s "$flag" ] && fetch_failed=1
    rm -f "$flag"
  fi
  # Normal path (no fetch failure, a state line was produced): transparent pass-through, datagap=0.
  if [ "$fetch_failed" -eq 0 ] && [ -n "$out" ] && [ "$rc" -eq 0 ]; then
    printf '%s 0\n' "$out"
    return 0
  fi
  # Non-data-gap _frontier_state failure: the fetch succeeded but _frontier_state still failed —
  # propagate the error rather than mis-annotating it as a data gap and emitting datagap=1.
  if [ "$fetch_failed" -eq 0 ]; then
    [ "$rc" -ne 0 ] && return "$rc"
    return 1
  fi
  # Data gap: the run-history fetch failed — reconstruct the tag-only facts (none read run history).
  local cand chans frontier="" ch c transition prior differs triage
  cand="$(channel_commit "$agent" next || true)"
  chans="$(ordered_channels "$agent" || true)"
  local chan_array=()
  IFS=, read -r -a chan_array <<< "$chans"
  for ch in "${chan_array[@]}"; do
    c="$(channel_commit "$agent" "$ch" || true)"
    if [ "$ch" = "next" ] || [ "$c" = "$cand" ]; then :; else frontier="$ch"; break; fi
  done
  # Total inability: cannot resolve even the candidate or a pending frontier → hard error.
  # Fail closed (never a silent green); the caller surfaces ::error:: and ends non-zero.
  { [ -z "$cand" ] || [ -z "$frontier" ]; } && return 1
  transition="$(transition_key "$frontier" "$chans")"
  prior="$(channel_commit "$agent" "$frontier" || true)"
  differs="$(_reusable_differs "$agent" "$cand" "$prior")"
  # classify_failure with an unknown category + no suspect signal: differs=1 → REGRESSION
  # (fail closed — a changed reusable with UNREADABLE health is treated as a suspected
  # regression that needs a human), differs=0 → PRE_EXISTING (a byte-identical reusable cannot
  # be a candidate regression). Either verdict still tracks the agent as BLOCKED.
  triage="$(classify_failure "$differs" unknown 0)"
  echo "$cand $frontier $transition BLOCKED 0 0 0 0 0 0 0 $triage - - 0 0 0 0 1"
}

# cmd_sync_issues [--dry-run] — upsert one blocker issue per BLOCKED agent, and render the
# fleet-status table into the run's job summary (GITHUB_STEP_SUMMARY). Blocker issues are
# idempotent (marker-keyed) and auto-close when the gate clears. Best-effort for issue-write
# failures (never aborts mid-fleet), but FAILS CLOSED (non-zero) when an agent's state is
# totally undeterminable — a green no-op would mask a regression (#820). Reads ISSUE_REPO
# (default THIS_REPO).
cmd_sync_issues() {
  local dry=false; [ "${1:-}" = "--dry-run" ] && dry=true
  local agents; agents="$(_jq -r '.agents? | keys[]?' 2>/dev/null || true)"
  [ -z "$agents" ] && { echo "no agents registered in $CANARY_RINGS — nothing to sync."; return 0; }
  echo "== canary-rollout sync-issues: repo=$ISSUE_REPO dry=$dry (gate standard: .github#548) =="
  if [ "$dry" != true ]; then
    gh label create canary-blocker --repo "$ISSUE_REPO" --color ededed --description "canary-rollout automation" >/dev/null 2>&1 || true
    # Route blockers so they get ACTIONED, not left sitting: `dev-lead` (dev-lead-intent
    # treats a `dev-lead`-labelled issue as an actionable "issue" intent and picks it up —
    # the App token applies the label, so the `issues: labeled` event DOES trigger the agent,
    # unlike a github.token edit). `needs-human` additionally flags REGRESSION and SUSPECT
    # blockers, which the gate escalates to a human (roll back, or confirm the discriminating
    # question then --override, rather than a blind --override).
    gh label create dev-lead --repo "$ISSUE_REPO" --color 5319e7 --description "Route to the dev-lead agent for action" >/dev/null 2>&1 || true
    gh label create needs-human --repo "$ISSUE_REPO" --color d93f0b --description "Requires human judgement (canary regression)" >/dev/null 2>&1 || true
    # canary-confirm (#668 Layer 3): the human go/no-go issue for an AWAITING_CONFIRMATION
    # frontier — a SEPARATE label/issue from canary-blocker so the two concerns never collide.
    gh label create canary-confirm --repo "$ISSUE_REPO" --color fbca04 --description "canary-rollout: human go/no-go at a require_confirmation ring boundary" >/dev/null 2>&1 || true
  fi
  local rows="" agent hard_fail=0
  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    local cand frontier transition state _d _f _s _t cum_fail cum_startup _cb triage mix_shift host
    local downgrade dg_cand_rate dg_cand_sample dg_base_rate dg_base_sample datagap
    # Resilient read (#820): the wrapper fails closed to a BLOCKED+datagap line on a run-history
    # fetch outage, and returns non-zero (no output) only on a TOTAL inability to determine
    # state. A failed `read` there means we could not even resolve the candidate/frontier —
    # fail closed rather than report a false all-clear (a green no-op could mask a regression).
    if ! read -r cand frontier transition state _d _f _s _t cum_fail cum_startup _cb triage mix_shift downgrade dg_cand_rate dg_cand_sample dg_base_rate dg_base_sample datagap < <(_frontier_state_resilient "$agent"); then
      echo "::error::sync-issues: cannot determine canary state for '$agent' (run-history AND tag resolution unavailable) — failing closed rather than reporting a false all-clear." >&2
      hard_fail=1
      rows+="| \`$agent\` | UNKNOWN | \`-\` | ? | ? | ⚠️ data unavailable (fail-closed) |"$'\n'
      continue
    fi
    host="$(_agent_field "$agent" host)"
    local blk="—" num_state num istate
    # Best-effort (#1081): these substitutions call gh/jq. Under `set -euo pipefail`
    # a bare assignment propagates a non-zero exit and would abort the whole step —
    # before the fleet dashboard renders and before the intended fallback warnings
    # below. `|| true` keeps sync-issues degrading gracefully (empty → handled).
    num_state="$(_issue_find canary-blocker "<!-- canary-blocker:$agent -->" || true)"
    num="${num_state%%$'\t'*}"; istate="${num_state##*$'\t'}"
    if [ "$state" = "BLOCKED" ]; then
      local evidence body title mix_table=""
      if [ "${datagap:-0}" = "1" ]; then
        # Run history was unreadable this tick — there are no listable failing runs to cite.
        evidence="_(⚠️ run-history fetch failed this tick — the failing runs could not be listed. The gate FAILS CLOSED: the promotion is held and this issue stays open until run history is readable again and the gate can re-evaluate.)_"
      else
        evidence="$(_blocker_evidence "$agent" "$cand" || true)"
      fi
      [ "$mix_shift" = "SHIFT" ] && mix_table="$(_decision_mix_table "$agent" "$cand" || true)"
      body="$(_blocker_body "$agent" "$transition" "$cand" "$cum_fail" "$cum_startup" "$triage" "$host" "$evidence" "$mix_shift" "$mix_table" "$downgrade" "$dg_cand_rate" "$dg_cand_sample" "$dg_base_rate" "$dg_base_sample" "${datagap:-0}")"
      if [ "$mix_shift" = "SHIFT" ]; then
        title="Canary blocker: $agent $transition (decision-mix shift, SUSPECT)"
      elif [ "${datagap:-0}" = "1" ]; then
        title="Canary blocker: $agent $transition ($triage, partial run-history — fail-closed)"
      else
        title="Canary blocker: $agent $transition (cum_fail=$cum_fail, $triage)"
      fi
      if [ -z "$num" ]; then
        if [ "$dry" = true ]; then echo "  [DRY] would OPEN blocker issue for $agent ($triage)"; blk="(new)"; else
          num="$(_gh_issue_create "$title" "$body" "canary-blocker" || true)"
          if [ -n "$num" ]; then
            gh issue edit "$num" --repo "$ISSUE_REPO" --add-label dev-lead >/dev/null 2>&1 || true
            { [ "$triage" = "REGRESSION" ] || [ "$triage" = "SUSPECT" ]; } && gh issue edit "$num" --repo "$ISSUE_REPO" --add-label needs-human >/dev/null 2>&1 || true
            echo "  opened blocker issue #$num for $agent"; blk="#$num"
          else echo "::warning::could not open blocker issue for $agent (Issues:write on the App?)"; fi
        fi
      else
        if [ "$dry" = true ]; then echo "  [DRY] would UPDATE blocker issue #$num for $agent"; blk="#$num"; else
          [ "$istate" = "OPEN" ] || gh issue reopen "$num" --repo "$ISSUE_REPO" >/dev/null 2>&1 || true
          gh issue edit "$num" --repo "$ISSUE_REPO" --title "$title" --body "$body" >/dev/null 2>&1 \
            || echo "::warning::could not update blocker issue #$num for $agent"
          gh issue edit "$num" --repo "$ISSUE_REPO" --add-label dev-lead >/dev/null 2>&1 || true
          if [ "$triage" = "REGRESSION" ] || [ "$triage" = "SUSPECT" ]; then
            gh issue edit "$num" --repo "$ISSUE_REPO" --add-label needs-human >/dev/null 2>&1 || true
          else
            gh issue edit "$num" --repo "$ISSUE_REPO" --remove-label needs-human >/dev/null 2>&1 || true
          fi
          echo "  updated blocker issue #$num for $agent"; blk="#$num"
        fi
      fi
    else
      # Not blocked — close a stale open blocker issue (the gate cleared).
      if [ -n "$num" ] && [ "$istate" = "OPEN" ]; then
        if [ "$dry" = true ]; then echo "  [DRY] would CLOSE cleared blocker issue #$num for $agent ($state)"; else
          gh issue close "$num" --repo "$ISSUE_REPO" \
            --comment "✅ Gate cleared — \`$agent\` is now \`$state\`. Closed automatically by canary-rollout." >/dev/null 2>&1 || true
          echo "  closed cleared blocker issue #$num for $agent"
        fi
        blk="#$num (closed)"
      fi
    fi

    # Layer 3 (#668 increment 3): the human go/no-go issue for an AWAITING_CONFIRMATION frontier.
    # A SEPARATE marker/label from the blocker issue (the two concerns are independent), upserted
    # idempotently and auto-closed once the agent is no longer awaiting confirmation (promoted,
    # rolled back, or a new candidate cut). Labelled needs-human — a human confirms, dev-lead does
    # not action it. Best-effort under set -e, like the blocker path (`|| true`).
    local cnum_state cnum cistate
    cnum_state="$(_issue_find canary-confirm "<!-- canary-confirm:$agent -->" || true)"
    cnum="${cnum_state%%$'\t'*}"; cistate="${cnum_state##*$'\t'}"
    if [ "$state" = "AWAITING_CONFIRMATION" ]; then
      local prior cbody ctitle
      prior="$(channel_commit "$agent" "$frontier" || true)"
      cbody="$(_confirm_body "$agent" "$transition" "$cand" "$prior" "$host" "$_s" "$_t" || true)"
      ctitle="Canary confirm: $agent $transition — human go/no-go before stable"
      if [ -z "$cnum" ]; then
        if [ "$dry" = true ]; then echo "  [DRY] would OPEN confirm issue for $agent"; blk="(new confirm)"; else
          cnum="$(_gh_issue_create "$ctitle" "$cbody" "canary-confirm" || true)"
          if [ -n "$cnum" ]; then
            gh issue edit "$cnum" --repo "$ISSUE_REPO" --add-label needs-human >/dev/null 2>&1 || true
            echo "  opened confirm issue #$cnum for $agent"; blk="#$cnum (confirm)"
          else echo "::warning::could not open confirm issue for $agent (Issues:write on the App?)"; fi
        fi
      else
        if [ "$dry" = true ]; then echo "  [DRY] would UPDATE confirm issue #$cnum for $agent"; blk="#$cnum (confirm)"; else
          [ "$cistate" = "OPEN" ] || gh issue reopen "$cnum" --repo "$ISSUE_REPO" >/dev/null 2>&1 || true
          gh issue edit "$cnum" --repo "$ISSUE_REPO" --title "$ctitle" --body "$cbody" >/dev/null 2>&1 \
            || echo "::warning::could not update confirm issue #$cnum for $agent"
          gh issue edit "$cnum" --repo "$ISSUE_REPO" --add-label needs-human >/dev/null 2>&1 || true
          echo "  updated confirm issue #$cnum for $agent"; blk="#$cnum (confirm)"
        fi
      fi
    else
      # No longer awaiting — close a stale open confirm issue (confirmed, rolled back, or recut).
      if [ -n "$cnum" ] && [ "$cistate" = "OPEN" ]; then
        if [ "$dry" = true ]; then echo "  [DRY] would CLOSE cleared confirm issue #$cnum for $agent ($state)"; else
          gh issue close "$cnum" --repo "$ISSUE_REPO" \
            --comment "✅ No longer awaiting confirmation — \`$agent\` is now \`$state\`. Closed automatically by canary-rollout." >/dev/null 2>&1 || true
          echo "  closed cleared confirm issue #$cnum for $agent"
        fi
        blk="#$cnum (confirm closed)"
      fi
    fi

    rows+="| \`$agent\` | $state | \`$transition\` | $cum_fail | $triage | $blk |"$'\n'
  done <<< "$agents"

  # Render the fleet-status table into the run's job summary (a read-only snapshot, not a
  # work item). Falls back to stdout when GITHUB_STEP_SUMMARY is unset (local/manual runs).
  local ts dmd
  ts="$(date -u +%Y-%m-%dT%H:%MZ 2>/dev/null || echo unknown)"
  dmd="$(_dashboard_md "${rows%$'\n'}" "$ts")"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    if printf '\n%s\n' "$dmd" >> "$GITHUB_STEP_SUMMARY"; then
      echo "  wrote fleet-status table to the job summary"
    else
      echo "::warning::could not write the fleet-status job summary"
    fi
  else
    echo "──── fleet status ────"
    printf '%s\n' "$dmd"
  fi
  # Fail closed (#820): if any agent's state was totally undeterminable this tick, end non-zero
  # AFTER rendering the dashboard — a green no-op would mask a possible regression.
  [ "$hard_fail" -eq 1 ] && return 1
  return 0
}

# ── promotion tag-write failure escalation (durable trend + blocker, #1023 defect 2) ──
# A gate-BLOCKED promotion is expected and already tracked (canary-blocker). A FAILED tag WRITE
# (permission/API rejection on the move) is UNEXPECTED and, before #1023, left only a scrolling
# run-log line — no durable artifact, no trend. This turns each run's failed writes (recorded in
# CANARY_PROMOTIONS_FAILED_LOG by cmd_promote) into a per-agent tracking issue whose CONSECUTIVE-
# failure streak escalates to needs-human + dev-lead at CANARY_PROMOTION_FAILURE_ESCALATE_AFTER
# runs — and auto-closes the moment a write succeeds (agent in the CANARY_PROMOTIONS_LOG success
# log). Best-effort GitHub writes; never aborts the run.

# _promo_log_agents <tsv_file> — unique agent (column 1) values in a promotions log, one per line;
# empty when the path is unset or the file is missing/empty.
_promo_log_agents() {
  local f="$1"
  [ -n "$f" ] && [ -s "$f" ] || return 0
  cut -f1 "$f" 2>/dev/null | awk 'NF && !seen[$0]++'
}

# _promo_fail_latest <agent> — the LAST failure-log line's "ring<TAB>cand<TAB>host<TAB>reason" for
# <agent> (the most recent failure this run), empty if none.
_promo_fail_latest() {
  local agent="$1" f="${CANARY_PROMOTIONS_FAILED_LOG:-}"
  [ -n "$f" ] && [ -s "$f" ] || return 0
  awk -F'\t' -v a="$agent" '$1==a{ r=$2"\t"$3"\t"$4"\t"$5 } END{ if (r!="") print r }' "$f"
}

# _promo_fail_body <agent> <count> <threshold> <ring> <cand> <host> <reason> <escalated:0|1>
_promo_fail_body() {
  local agent="$1" count="$2" threshold="$3" ring="$4" cand="$5" host="$6" reason="$7" escalated="$8" note
  if [ "$escalated" = 1 ]; then
    note="> ⛔ **ESCALATED (needs-human).** This tag write has failed on **$count consecutive** scheduled runs (threshold $threshold) — it is not self-healing. Unlike a gate block (expected, timer-cleared), a failing WRITE means the move itself is rejected: check the release-manager App's ruleset bypass + token scopes for \`$ring\` on \`$host\`, then re-run \`promote $agent\`. This issue auto-closes on the next successful promotion."
  else
    note="> ℹ️ **Tracking a failed tag write.** The promotion move for \`$agent\` was rejected this run (not a gate block — the gate would hold *before* the write). Consecutive failures: **$count** of $threshold before escalation to \`needs-human\`. Auto-closes on the next successful promotion."
  fi
  cat <<EOF
<!-- canary-promo-fail:$agent -->
<!-- canary-promo-fail-count:$count -->
**Automated canary-rollout promotion-failure tracker.** A tag WRITE (not a gate decision) is failing for \`$agent\`. Filed + maintained by the Canary Rollout workflow; regenerated each run and **auto-closes** when a promotion succeeds — do not edit by hand.

| field | value |
|---|---|
| agent | \`$agent\` |
| ring | \`$ring\` |
| candidate | \`${cand:0:12}\` |
| host repo | \`$host\` |
| consecutive failing runs | **$count** (escalates at $threshold) |
| latest reason | ${reason:-tag write rejected} |

$note
---
_Distinct from a gate-blocked promotion (tracked by \`canary-blocker\`): this is an unexpected write rejection, tracked so it escalates rather than scrolling past._
EOF
}

# cmd_sync_promotion_failures [--dry-run] — reconcile this run's failed tag writes into durable,
# escalating tracking issues (see section header). Reads CANARY_PROMOTIONS_FAILED_LOG (failures)
# and CANARY_PROMOTIONS_LOG (successes); an agent present in neither was not attempted this run
# and is left untouched. Reads ISSUE_REPO (default THIS_REPO).
cmd_sync_promotion_failures() {
  local dry=false; [ "${1:-}" = "--dry-run" ] && dry=true
  local threshold="${CANARY_PROMOTION_FAILURE_ESCALATE_AFTER:-2}"
  case "$threshold" in ''|*[!0-9]*) threshold=2 ;; esac
  [ "$threshold" -lt 1 ] && threshold=1
  echo "== canary-rollout sync-promotion-failures: repo=$ISSUE_REPO dry=$dry threshold=$threshold =="
  local failed_agents ok_agents attempted
  failed_agents="$(_promo_log_agents "${CANARY_PROMOTIONS_FAILED_LOG:-}")"
  ok_agents="$(_promo_log_agents "${CANARY_PROMOTIONS_LOG:-}")"
  attempted="$(printf '%s\n%s\n' "$failed_agents" "$ok_agents" | awk 'NF && !seen[$0]++')"
  if [ -z "$attempted" ]; then
    echo "  no promotion attempts recorded this run — nothing to reconcile."; return 0
  fi
  if [ "$dry" != true ]; then
    gh label create canary-promotion-failure --repo "$ISSUE_REPO" --color b60205 --description "canary-rollout: a promotion tag WRITE is failing (not a gate block)" >/dev/null 2>&1 || true
    gh label create dev-lead --repo "$ISSUE_REPO" --color 5319e7 --description "Route to the dev-lead agent for action" >/dev/null 2>&1 || true
    gh label create needs-human --repo "$ISSUE_REPO" --color d93f0b --description "Requires human judgement (canary regression)" >/dev/null 2>&1 || true
  fi
  local issues_json
  if ! issues_json="$(gh issue list --repo "$ISSUE_REPO" --label canary-promotion-failure --state all -L 100 --json number,state,body 2>/dev/null)"; then
    echo "::error::could not list canary-promotion-failure issues on $ISSUE_REPO — aborting to avoid creating duplicate tracking issues." >&2
    return 1
  fi
  local -A failed_map=() ok_map=()
  local fa
  while IFS= read -r fa; do
    [ -n "$fa" ] && failed_map["$fa"]=1
  done < <(printf '%s\n' "$failed_agents")
  local oa
  while IFS= read -r oa; do
    [ -n "$oa" ] && ok_map["$oa"]=1
  done < <(printf '%s\n' "$ok_agents")
  local -A promo_failures=()
  local _pf_agent _pf_num _pf_state _pf_count
  while IFS=$'\t' read -r _pf_agent _pf_num _pf_state _pf_count; do
    [ -n "$_pf_agent" ] && promo_failures["$_pf_agent"]="${_pf_num}"$'\t'"${_pf_state}"$'\t'"${_pf_count}"
  done < <(printf '%s\n' "$issues_json" | jq -r '(sort_by(.number) // []) | .[]? | select(.body != null) | (try (.body | capture("<!-- canary-promo-fail:(?<agent>[^ ]+) -->")) catch null) as $c | select($c != null) | ([.body | match("canary-promo-fail-count:([0-9]+)") | .captures[0].string] | first // "0") as $count | "\($c.agent)\t\(.number)\t\(.state | ascii_upcase)\t\($count)"' 2>/dev/null)
  # Parse the failure log once before the per-agent loop to avoid spawning awk on every iteration.
  local -A fail_ring=() fail_cand=() fail_host=() fail_reason=()
  if [ -n "${CANARY_PROMOTIONS_FAILED_LOG:-}" ] && [ -s "$CANARY_PROMOTIONS_FAILED_LOG" ]; then
    local lf_agent lf_ring lf_cand lf_host lf_reason
    while IFS=$'\t' read -r lf_agent lf_ring lf_cand lf_host lf_reason; do
      if [ -n "$lf_agent" ]; then
        fail_ring["$lf_agent"]="$lf_ring"
        fail_cand["$lf_agent"]="$lf_cand"
        fail_host["$lf_agent"]="$lf_host"
        fail_reason["$lf_agent"]="$lf_reason"
      fi
    done < "$CANARY_PROMOTIONS_FAILED_LOG"
  fi
  local agent
  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    local outcome="ok"
    [ -n "${failed_map["$agent"]:-}" ] && [ -z "${ok_map["$agent"]:-}" ] && outcome="failed"
    local ns num istate prior
    ns="${promo_failures["$agent"]:-}"
    num="$(printf '%s' "$ns" | cut -f1)"; istate="$(printf '%s' "$ns" | cut -f2)"; prior="$(printf '%s' "$ns" | cut -f3)"
    [ -z "$prior" ] && prior=0
    # A CLOSED tracking issue means the streak already ended; its stale count must not seed the
    # next streak or one transient failure would escalate on its first occurrence after recovery.
    [ "$istate" = "CLOSED" ] && prior=0
    local count; count="$(promotion_failure_next_count "$prior" "$outcome")"
    if [ "$outcome" = "failed" ]; then
      local ring cand host reason escalate body title
      ring="${fail_ring["$agent"]:-?}"
      cand="${fail_cand["$agent"]:-}"
      host="${fail_host["$agent"]:-?}"
      reason="${fail_reason["$agent"]:-tag write rejected}"
      escalate="$(promotion_failure_should_escalate "$count" "$threshold")"
      body="$(_promo_fail_body "$agent" "$count" "$threshold" "$ring" "$cand" "$host" "$reason" "$escalate")"
      if [ "$escalate" = 1 ]; then
        title="Canary promotion FAILING: $agent (${count}× consecutive tag-write rejection)"
      else
        title="Canary promotion tag-write failed: $agent (${count}× consecutive)"
      fi
      if [ -z "$num" ]; then
        if [ "$dry" = true ]; then echo "  [DRY] would OPEN promotion-failure issue for $agent (count=$count, escalate=$escalate)"; else
          num="$(_gh_issue_create "$title" "$body" "canary-promotion-failure" || true)"
          if [ -n "$num" ]; then
            [ "$escalate" = 1 ] && gh issue edit "$num" --repo "$ISSUE_REPO" --add-label dev-lead --add-label needs-human >/dev/null 2>&1 || true
            echo "  opened promotion-failure issue #$num for $agent (count=$count)"
          else echo "::warning::could not open promotion-failure issue for $agent (Issues:write on the App?)"; fi
        fi
      else
        if [ "$dry" = true ]; then echo "  [DRY] would UPDATE promotion-failure issue #$num for $agent (count=$count, escalate=$escalate)"; else
          [ "$istate" = "OPEN" ] || gh issue reopen "$num" --repo "$ISSUE_REPO" >/dev/null 2>&1 || true
          gh issue edit "$num" --repo "$ISSUE_REPO" --title "$title" --body "$body" >/dev/null 2>&1 \
            || echo "::warning::could not update promotion-failure issue #$num for $agent"
          [ "$escalate" = 1 ] && gh issue edit "$num" --repo "$ISSUE_REPO" --add-label dev-lead --add-label needs-human >/dev/null 2>&1 || true
          echo "  updated promotion-failure issue #$num for $agent (count=$count)"
        fi
      fi
    else
      # A successful write this run resets the streak → close any open tracking issue.
      if [ -n "$num" ] && [ "$istate" = "OPEN" ]; then
        if [ "$dry" = true ]; then echo "  [DRY] would CLOSE recovered promotion-failure issue #$num for $agent"; else
          gh issue close "$num" --repo "$ISSUE_REPO" \
            --comment "✅ Promotion succeeded — \`$agent\` tag write recovered. Closed automatically by canary-rollout." >/dev/null 2>&1 || true
          echo "  closed recovered promotion-failure issue #$num for $agent"
        fi
      fi
    fi
  done <<< "$attempted"
  return 0
}

# ── autocut: cut a new candidate when a reusable changes on main (#1069) ────────
# The FRONT END of the canary pipeline (the promoter's counterpart). At each scheduled
# tick — gated by CANARY_AUTO_CUT — for each registered agent it compares the reusable
# blob at the host's default-branch HEAD against the blob at the current `next` candidate;
# if they differ it cuts a new immutable <agent>/vX.Y.Z (patch bump by default) and moves
# `next` onto it INLINE via the App-token gh-api path (_gh_create_annotated_tag + _gh_move_tag),
# seeding the candidate into the existing soak/promote pipeline. Detection AND the cut both run
# against the agent's registry host via the App token (which reads/writes every host), so no
# cross-repo Actions plumbing — and no sibling cut-release.sh — is needed. Best-effort: never
# fails the run.
#
# Scope/limitation (v1): detection is on the reusable FILE blob only (the registry
# `reusable` path). A change to a shared library the reusable sources — without the
# reusable file itself changing — is not detected. Acceptable for v1; could extend to a
# path-set later.

# _gh_default_branch <repo> — the repo's default branch name (empty on error).
_gh_default_branch() { gh api "repos/$1" --jq '.default_branch' 2>/dev/null || echo ""; }

# _gh_head_sha <repo> <branch> — the commit SHA at <branch> HEAD (empty on error).
_gh_head_sha() { gh api "repos/$1/commits/$2" --jq '.sha' 2>/dev/null || echo ""; }

# _gh_blob_sha <repo> <path> <ref> — the git blob SHA of <path> at <ref> (empty on error).
_gh_blob_sha() { gh api "repos/$1/contents/$2?ref=$3" --jq '.sha' 2>/dev/null || echo ""; }

# ── watched agent_ref paths (#1019) ─────────────────────────────────────────────
# A consumer checks out MORE than the reusable at its pinned channel tag: the reusable checks
# out scripts/ (and prompts/, personas/) at `agent_ref`. Autocut/drift must therefore watch the
# whole agent_ref-consumed path set, not just the reusable blob. The set is DERIVED FROM THE
# REGISTRY (source of truth) — a top-level `agent_ref_paths` default with an optional per-agent
# `.agents[a].agent_ref_paths` override — falling back to this built-in only if the registry
# omits it entirely (defense-in-depth, never the primary source).
_DEFAULT_AGENT_REF_PATHS=$'scripts/\nprompts/\npersonas/'

# _watched_paths <agent> — newline list of host-relative paths a consumer EXECUTES at agent_ref:
# the registry `reusable` file plus the configured `agent_ref_paths` (per-agent override, else
# top-level default, else the built-in fallback). Deduped, blanks dropped.
_watched_paths() {
  local agent="$1" reusable extra
  reusable="$(_agent_field "$agent" reusable)"
  # Distinguish "the registry OMITS agent_ref_paths" (→ built-in fallback) from "the registry
  # sets it to []" (→ an intentional opt-out that must be honoured). Testing the rendered list
  # for emptiness conflates the two, so an agent that deliberately watches only its reusable
  # would silently get scripts/, prompts/ and personas/ back. Probe presence with `has` first.
  local declared
  declared="$(_jq -r --arg a "$agent" \
    'if (.agents[$a]? | type) == "object" and (.agents[$a] | has("agent_ref_paths")) then "agent"
     elif has("agent_ref_paths") then "top"
     else "none" end' 2>/dev/null || echo none)"
  extra="$(_jq -r --arg a "$agent" \
    '(.agents[$a].agent_ref_paths // .agent_ref_paths // []) | .[]?' 2>/dev/null || true)"
  [ -z "$extra" ] && [ "$declared" = "none" ] && extra="$_DEFAULT_AGENT_REF_PATHS"
  { [ -n "$reusable" ] && printf '%s\n' "$reusable"; printf '%s\n' "$extra"; } \
    | awk 'NF && !seen[$0]++'
}

# _gh_changed_files <repo> <base> <head> — filenames changed between <base>..<head> via the
# compare API (one per line; empty on error / no diff). Raw fetch + local jq (mirrors _run_json)
# so a test stub can serve the compare payload without re-implementing --jq.
#
# TRUNCATION (#1019): the compare API caps `.files` at 300 entries and sets
# `.truncated: true` when the range exceeds it. Reading `.files` alone would then
# silently OMIT changed paths — and since autocut ships a new version only when a
# WATCHED path changed, an omitted `scripts/…` entry means the cut is skipped and
# the change never reaches the fleet, with nothing red anywhere. That is exactly the
# silent-non-delivery failure this issue exists to remove, so the truncated case must
# never be treated as "no change". On truncation we fall back to enumerating each
# commit in the range (`.commits[].sha` → `repos/<repo>/commits/<sha>`) and union
# their file lists. Errors still degrade to empty (the caller treats empty as
# "unknown", not "unchanged").
_gh_changed_files() {
  local repo="$1" base="$2" head="$3" json truncated files
  { [ -z "$base" ] || [ -z "$head" ]; } && { echo ""; return 0; }
  json="$(gh api "repos/$repo/compare/$base...$head" 2>/dev/null)" || { echo ""; return 0; }
  [ -z "$json" ] && { echo ""; return 0; }

  truncated="$(jq -r '.truncated // false' <<< "$json" 2>/dev/null || echo false)"
  if [ "$truncated" != "true" ]; then
    jq -r '.files[]?.filename // empty' <<< "$json" 2>/dev/null || echo ""
    return 0
  fi

  # Truncated: union the per-commit file lists. Seed with whatever the compare DID
  # return so a per-commit fetch failure can only ever lose precision, not regress
  # below the un-truncated behaviour.
  files="$(jq -r '.files[]?.filename // empty' <<< "$json" 2>/dev/null || echo "")"
  local sha commit_json
  while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    commit_json="$(gh api "repos/$repo/commits/$sha" 2>/dev/null)" || continue
    [ -z "$commit_json" ] && continue
    files+=$'\n'"$(jq -r '.files[]?.filename // empty' <<< "$commit_json" 2>/dev/null || echo "")"
  done < <(jq -r '.commits[]?.sha // empty' <<< "$json" 2>/dev/null)

  printf '%s\n' "$files" | awk 'NF && !seen[$0]++'
}

# _host_release_versions <agent> — echo every MAJOR.MINOR.PATCH (one per line) that has an
# immutable <agent>/vX.Y.Z tag on the agent's host, via the API (the App token reads every
# host; release tags are on the remote for both this-repo and cross-repo agents).
_host_release_versions() {
  local agent="$1" host
  host="$(_agent_field "$agent" host)"
  [ -z "$host" ] && return 0
  gh api "repos/$host/git/matching-refs/tags/$agent/v" --jq '.[]?.ref' 2>/dev/null \
    | sed -n "s#^refs/tags/${agent}/v##p" || true
}

# _autocut_bump_override <agent> — the EXPLICIT bump override for the agent (registry knob
# .agents[a].autocut.bump), or empty when unset/invalid. Since #712 the knob is an OVERRIDE
# over signal-based detection (not the sole source), so an absent/invalid knob yields empty
# (→ detection decides) rather than defaulting to patch.
_autocut_bump_override() {
  local b
  b="$(_jq -r --arg a "$1" '.agents[$a]?.autocut?.bump // ""')"
  case "$b" in major|minor|patch) echo "$b" ;; *) echo "" ;; esac
}

# _commit_date <host> <sha> — the committer (or author) date of <sha> on <host>, ISO-8601, empty
# on any error. Used to bound the range enumeration with a `since` window (see below).
_commit_date() {
  gh api "repos/$1/commits/$2" --jq '.commit.committer.date // .commit.author.date // empty' 2>/dev/null || echo ""
}

# _autocut_signal_paths <agent> — the repo paths whose commits carry release-bump signals for this
# agent, one per line, de-duplicated. ALWAYS includes the registry `reusable` path; extend it
# with the optional `.agents[a].autocut.watched_paths[]` knob (e.g. a shared library the reusable
# sources). Bump detection is scoped to commits touching THESE paths, so an unrelated commit
# elsewhere in the range never moves the bump (#1023 defect 1a): the classic failure was a
# `docs: feat!:` on an unrelated file forcing a spurious major that seeds a fresh `v<newMAJOR>-next`
# (#657 F4) and strands consumers pinned to the old major.
_autocut_signal_paths() {
  local agent="$1"
  { _agent_field "$agent" reusable
    _jq -r --arg a "$agent" '.agents[$a]?.autocut?.watched_paths? // [] | .[]?'
  } 2>/dev/null | awk 'NF && !seen[$0]++'
}

# _autocut_commit_signals <agent> <host> <next_commit> <mainsha> — scan the commits in
# (next_commit, mainsha] that TOUCH one of the agent's watched paths, echoing "<breaking 0|1>
# <feat 0|1>". breaking=1 iff any such commit is a conventional-commit `!` (`type(scope)!:`) or
# carries a `BREAKING CHANGE:`/`BREAKING-CHANGE:` footer; feat=1 iff any such commit subject is
# `feat:`/`feat(scope):` (non-breaking).
#
# Two defects this closes (#1023 defect 1):
#   • SCOPED — signals come only from `commits?path=<watched>` results (per watched path), so an
#     unrelated `feat!`/`BREAKING CHANGE` elsewhere in the range is invisible to the bump.
#   • ENUMERATED, not truncated — the range is PAGINATED (never a single capped response) and
#     bounded by a `since=<next_commit date>` window, so a breaking change beyond the first
#     page's cap is still seen. The boundary commit itself is EXCLUDED (its message predates the
#     range).
#
# Return codes drive the caller's fail-safe DIRECTION:
#   0  signals resolved            → echo "<b> <f>"
#   1  fetch/parse error (no data) → caller keeps the PATCH fail-safe (never auto-major on a
#                                    transient API failure; a real break can still be forced with
#                                    the .agents[a].autocut.bump knob)
#   3  range UNRESOLVABLE — could not be fully enumerated within CANARY_MAX_COMMIT_PAGES pages →
#                                    caller FAILS SAFE TO MAJOR, loudly: an unenumerable range
#                                    must not silently downgrade a breaking change to a patch
#                                    (#1023 defect 1b), the more dangerous direction.
_autocut_commit_signals() {
  local agent="$1" host="$2" next_commit="$3" mainsha="$4"
  local path page json acc="[]" truncated=0 path_done
  local since; since="$(_commit_date "$host" "$next_commit")"
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    page=1; path_done=0
    while [ "$page" -le "$CANARY_MAX_COMMIT_PAGES" ]; do
      local since_args=(); [ -n "$since" ] && since_args=(-f "since=$since")
      json="$(gh api --method GET "repos/$host/commits" -f path="$path" -f sha="$mainsha" "${since_args[@]}" -F per_page=100 -F page="$page" 2>/dev/null)" || return 1
      # Parse the page and extract found, count, and pre-boundary messages in a single jq invocation
      local parsed found count pre rest
      parsed="$(printf '%s\n' "$json" | jq -r --arg stop "$next_commit" '
        if type != "array" then error("not an array") else . end
        | (map(.sha)) as $shas
        | ([ range(0; length) | select($shas[.] == $stop) ] | first) as $idx
        | (any(.[]?; .sha == $stop) // false) as $found
        | "\($found)\t\(length)\t\(if $idx == null then . else .[0:$idx] end | map(.commit.message // "") | @json)"
      ' 2>/dev/null)" || return 1
      found="${parsed%%$'\t'*}"; rest="${parsed#*$'\t'}"; count="${rest%%$'\t'*}"; pre="${rest#*$'\t'}"
      acc="$(jq -cn --argjson a "$acc" --argjson b "$pre" '$a + $b' 2>/dev/null)" || return 1
      commit_page_done "$found" "${count:-0}" 100 || { path_done=1; break; }
      page=$((page + 1))
    done
    [ "$path_done" -eq 1 ] || truncated=1
  done <<< "$(_autocut_signal_paths "$agent")"
  [ "$truncated" -eq 1 ] && return 3
  [ "$acc" = "[]" ] && return 2
  local out
  out="$(printf '%s\n' "$acc" | jq -r '
    { b: any(.[]?; (. // "") | test("^[\\w-]+(\\([^)]*\\))?!:") or test("(^|\\n)BREAKING[ -]CHANGE:")),
      f: any(.[]?; (. // "") | test("^feat(\\([^)]*\\))?:")) }
    | "\(if .b then 1 else 0 end) \(if .f then 1 else 0 end)"
  ' 2>/dev/null)" || return 1
  [ -z "$out" ] && return 1
  printf '%s\n' "$out"
}

# _autocut_range_signals <host> <base> <head> — the conventional-commit signals over ALL commits
# between <base> and <head> (the compare range), echoing "<breaking 0|1> <feat 0|1>". Used as the
# fallback signal source when the reusable-path-scoped scan finds no boundary (a SCRIPT-ONLY
# change touches no reusable commit, #1019), so a script-only `feat`/`!`/`BREAKING CHANGE` still
# bumps correctly. Detection is byte-identical to _autocut_commit_signals; only the commit source
# differs (compare `.commits[]` — already correctly bounded, no boundary search). Returns non-zero
# on any fetch/parse error so the caller stays fail-safe to patch (never auto-major on missing data).
_autocut_range_signals() {
  local host="$1" base="$2" head="$3" json out
  { [ -z "$base" ] || [ -z "$head" ]; } && return 1
  json="$(gh api "repos/$host/compare/$base...$head" 2>/dev/null)" || return 1
  [ -z "$json" ] && return 1
  out="$(jq -r '
    if (.commits | type) != "array" then error("no commits array") else . end
    | (.commits | map(.commit.message // "")) as $msgs
    | {
        b: any($msgs[]; test("^\\w+(\\([^)]*\\))?!:") or test("(^|\\n)BREAKING[ -]CHANGE:")),
        f: any($msgs[]; test("^feat(\\([^)]*\\))?:"))
      }
    | "\(if .b then 1 else 0 end) \(if .f then 1 else 0 end)"
  ' <<< "$json" 2>/dev/null)" || return 1
  [ -z "$out" ] && return 1
  printf '%s\n' "$out"
}

# _gh_file_content <repo> <path> <ref> — the decoded text of <path> at <ref> on <repo> via the
# contents API (base64 → text). Non-zero on any fetch/decode error.
_gh_file_content() {
  local raw
  raw="$(gh api "repos/$1/contents/$2?ref=$3" --jq '.content // empty' 2>/dev/null)" || return 1
  [ -z "$raw" ] && return 1
  printf '%s' "$raw" | tr -d '\n' | base64 -d 2>/dev/null || return 1
}

# _autocut_iface_break <host> <reusable> <next_commit> <mainsha> — echo 1 if the reusable's
# `on.workflow_call` interface has a BREAKING change (removed/renamed input|secret, or a
# newly-required input) between the `next` candidate and main HEAD, else 0. Non-zero return on
# any fetch error so the caller does not escalate to major on missing interface data.
_autocut_iface_break() {
  local host="$1" reusable="$2" old_ref="$3" new_ref="$4" old_c new_c
  old_c="$(_gh_file_content "$host" "$reusable" "$old_ref")" || return 1
  new_c="$(_gh_file_content "$host" "$reusable" "$new_ref")" || return 1
  interface_break "$(workflow_call_iface "$old_c")" "$(workflow_call_iface "$new_c")"
}

# _autocut_detect_bump <agent> <host> <reusable> <next_commit> <mainsha> — the release bump for
# an autocut, echoed on stdout (a `::notice::` recording the level + driving signal goes to
# stderr so it does not pollute the captured value). The `.agents[a].autocut.bump` knob wins as
# an explicit override (even over a failed signal fetch); otherwise the level is DETECTED from
# the watched-path commit signals and the workflow_call interface diff via decide_bump. Fail-safe
# DIRECTION depends on WHY signals are missing (#1023 defect 1): a transient fetch error fails
# safe to PATCH (never auto-major on missing data — a real break can still be forced with the
# knob), but an UNRESOLVABLE range (too long to enumerate) fails safe to MAJOR, loudly — an
# unenumerable range must not silently downgrade a breaking change to a patch.
_autocut_detect_bump() {
  local agent="$1" host="$2" reusable="$3" next_commit="$4" mainsha="$5"
  local override; override="$(_autocut_bump_override "$agent")"
  if [ -n "$override" ]; then
    echo "::notice::autocut $agent: bump=$override (registry override .agents[$agent].autocut.bump)" >&2
    echo "$override"; return 0
  fi
  local breaking=0 feat=0 driver="" sigs iface rc=0
  sigs="$(_autocut_commit_signals "$agent" "$host" "$next_commit" "$mainsha")" || rc=$?
  if [ "$rc" -eq 0 ]; then
    read -r breaking feat <<< "$sigs"
  elif [ "$rc" -eq 3 ]; then
    # Unresolvable range (#1023 defect 1b): the range could not be fully enumerated, so a
    # breaking change may hide beyond the cap. FAIL SAFE TO MAJOR, loudly — never silently to
    # patch, the more dangerous direction (a breaking change shipped as a patch breaks pinned
    # consumers with no signal). A false major is at worst a spurious fresh v-line + this warning.
    echo "::warning::autocut $agent: commit range ${next_commit:0:12}..${mainsha:0:12} on $host could not be fully enumerated within $CANARY_MAX_COMMIT_PAGES pages — cannot rule out a breaking change; failing safe to bump=major (not patch). Investigate the range." >&2
    breaking=1; feat=0; driver="unresolvable commit range (fail-safe major)"
  elif [ "$rc" -eq 2 ] && sigs="$(_autocut_range_signals "$host" "$next_commit" "$mainsha")"; then
    # Reusable-path-scoped signals unavailable (a script-only change touches no reusable commit,
    # so the boundary scan finds nothing — rc=2): fall back to the compare-range commit messages
    # so a script-only feat/breaking still bumps correctly (#1019). A fetch error (rc=1) falls
    # through to the patch fail-safe instead, preserving watched-path scoping under API failures.
    read -r breaking feat <<< "$sigs"
  else
    echo "::notice::autocut $agent: commit-signal fetch failed — bump=patch (fail-safe)" >&2
    echo "patch"; return 0
  fi
  [ "$breaking" = 1 ] && [ -z "$driver" ] && driver="conventional-commit breaking change"
  # An interface break escalates to major; a fetch error here is non-fatal (keep commit signals)
  # and never invents a major from missing data.
  if iface="$(_autocut_iface_break "$host" "$reusable" "$next_commit" "$mainsha")"; then
    if [ "$iface" = 1 ]; then breaking=1; driver="workflow_call interface break"; fi
  fi
  local bump; bump="$(decide_bump "$breaking" "$feat" "")"
  if [ -z "$driver" ]; then
    case "$bump" in
      minor) driver="feat commit" ;;
      *)     driver="no breaking/feat signal" ;;
    esac
  fi
  echo "::notice::autocut $agent: detected bump=$bump ($driver)" >&2
  echo "$bump"
}

# _next_release_version <agent> <bump> — compute the next release version: bump the highest
# existing <agent>/vX.Y.Z on the host by <bump>. No existing tags → seed from 0.0.0.
_next_release_version() {
  local agent="$1" bump="$2" versions highest
  versions="$(_host_release_versions "$agent")"
  # shellcheck disable=SC2086
  highest="$(max_semver $versions)"
  [ -z "$highest" ] && highest="0.0.0"
  bump_version "$highest" "$bump"
}

# _autocut_agent <agent> <dry:true|false> — cut a new candidate for ONE agent if its reusable
# blob on the host default-branch HEAD differs from the blob at the current `next` candidate.
# Idempotent: no-op when the blobs match or main HEAD already equals the next candidate.
# Best-effort: any resolution gap is a ::warning + skip, never a hard failure.
_autocut_agent() {
  local agent="$1" dry="$2"
  local host reusable defbranch mainsha next_commit main_blob next_blob bump newver
  host="$(_agent_field "$agent" host)"
  reusable="$(_agent_field "$agent" reusable)"
  if [ -z "$host" ] || [ -z "$reusable" ]; then
    echo "::warning::autocut $agent: missing host/reusable in registry — skipping"; return 0
  fi
  defbranch="$(_gh_default_branch "$host")"; [ -z "$defbranch" ] && defbranch="main"
  mainsha="$(_gh_head_sha "$host" "$defbranch")"
  if [ -z "$mainsha" ]; then
    echo "::warning::autocut $agent: could not resolve $host $defbranch HEAD — skipping"; return 0
  fi
  main_blob="$(_gh_blob_sha "$host" "$reusable" "$mainsha")"
  if [ -z "$main_blob" ]; then
    echo "::warning::autocut $agent: reusable '$reusable' not found at $host@${mainsha:0:12} — skipping"; return 0
  fi
  local next_resolved_tag
  IFS=$'\t' read -r next_resolved_tag next_commit < <(_resolved_channel "$agent" next)
  next_blob=""
  [ -n "$next_commit" ] && next_blob="$(_gh_blob_sha "$host" "$reusable" "$next_commit")"
  # Fast no-op: main HEAD already IS the current candidate — nothing merged since the last cut.
  if [ "$mainsha" = "$next_commit" ]; then
    echo "autocut $agent: reusable unchanged on $host (next candidate up to date) — no cut."
    return 0
  fi
  # Decide whether anything a consumer EXECUTES at agent_ref changed between the current `next`
  # candidate and main HEAD (#1019). Previously autocut compared ONLY the reusable FILE blob, so a
  # script-only change — scripts/, prompts/, personas/, what the reusable checks out at agent_ref —
  # shipped NOWHERE (no cut, no soak, no promotion). Detection now covers the reusable blob (the
  # fast path, kept byte-identical for a reusable change) OR any other registry-derived watched
  # path (via the compare API).
  local reusable_changed=0
  if [ -z "$next_commit" ] || [ -z "$next_blob" ]; then
    # Cannot compare the reusable blob (no candidate yet, or reusable absent at the candidate):
    # fail OPEN so a first cut / an unresolved candidate still seeds the pipeline (prior behaviour).
    reusable_changed=1
  elif [ "$main_blob" != "$next_blob" ]; then
    reusable_changed=1
  fi
  local watched_changed=0 watched_hitlist=""
  if [ "$reusable_changed" -eq 0 ] && [ -n "$next_commit" ]; then
    local watched changed_files
    watched="$(_watched_paths "$agent")"
    changed_files="$(_gh_changed_files "$host" "$next_commit" "$mainsha")"
    watched_hitlist="$(watched_hits "$changed_files" "$watched")"
    [ -n "$watched_hitlist" ] && watched_changed=1
  fi
  if [ "$reusable_changed" -eq 0 ] && [ "$watched_changed" -eq 0 ]; then
    echo "autocut $agent: no agent_ref-consumed path changed on $host (reusable + scripts/prompts/personas up to date) — no cut."
    return 0
  fi
  bump="$(_autocut_detect_bump "$agent" "$host" "$reusable" "$next_commit" "$mainsha")"
  newver="$(_next_release_version "$agent" "$bump")"
  # Seed/advance the correct `next` line on the major dimension (major-scoped-channels epic
  # #657, F4): a MAJOR bump opens a FRESH `<agent>/v<newmajor>-next` line (a brand-new major
  # never reuses the prior major's next), whereas a minor/patch bump advances the CURRENT
  # major's `v<M>-next` — falling back to the legacy bare `<agent>/next` on today's bare-tier
  # fleet where no v-line exists yet, so the move stays byte-identical until F5 migrates tags.
  local next_tag newmajor; newmajor="$(major_component "$newver")"
  if [ "$bump" = major ]; then
    next_tag="$(channel_tag "$agent" next "$newmajor")"
  else
    next_tag="$next_resolved_tag"
  fi
  echo "autocut $agent: reusable changed on $host ($defbranch ${mainsha:0:12}) vs next ${next_commit:0:12} — cutting v$newver (bump=$bump), moving $next_tag."
  local relver="$agent/v$newver"
  if [ "$dry" = true ]; then
    echo "[DRY-RUN] would: cut $relver at ${mainsha:0:12} on $host + move $next_tag (gh-api, App token)"
    return 0
  fi
  # Cut inline (no sibling cut-release.sh, #613): create the immutable annotated release tag,
  # then advance `next` onto the same commit — both on the agent's HOST via the App token. If
  # the release tag already exists (e.g. a retry after a partial move), skip the create and just
  # re-point next so the operation stays idempotent. Guard the invariant: if the existing tag
  # resolves to a different commit (manual retag, concurrent run, prior bad state), skip the
  # next move entirely rather than advancing next to an untagged commit.
  local existing_sha
  existing_sha="$(_gh_tag_commit "$host" "$relver")"
  if [ -n "$existing_sha" ]; then
    if [ "$existing_sha" != "$mainsha" ]; then
      echo "::warning::autocut $agent: release $relver on $host points to ${existing_sha:0:12}, not ${mainsha:0:12} — skipping next move to preserve invariant."
      return 0
    fi
    echo "autocut $agent: release $relver already exists on $host — re-pointing next only."
  elif ! _gh_create_annotated_tag "$host" "$relver" "$mainsha" "$agent release v$newver"; then
    echo "::warning::autocut $agent: could not create $relver on $host (best-effort, continuing)"; return 0
  fi
  _gh_move_tag "$host" "$next_tag" "$mainsha" \
    || { echo "::warning::autocut $agent: could not move $next_tag on $host (best-effort, continuing)"; return 0; }
  echo "autocut $agent: cut v$newver from ${mainsha:0:12} and moved $next_tag (on $host)."
}

# cmd_autocut [--dry-run] — the scheduled front end. Gated by CANARY_AUTO_CUT (the single
# kill-switch): a clean no-op unless CANARY_AUTO_CUT == 'true'. Iterates every registry agent;
# a per-agent failure is logged and skipped so one agent cannot halt the fleet sweep. Runs
# BEFORE promote-all so a freshly cut candidate begins soaking the same tick (dwell=0 < floor
# → it SOAKS, does not promote).
cmd_autocut() {
  local dry=false; [ "${1:-}" = "--dry-run" ] && dry=true
  if [ "${CANARY_AUTO_CUT:-}" != "true" ]; then
    echo "== canary-rollout autocut: DISABLED (CANARY_AUTO_CUT != 'true') — no-op. =="
    return 0
  fi
  local agents agent
  agents="$(_jq -r '.agents? | keys[]?' 2>/dev/null || true)"
  [ -z "$agents" ] && { echo "no agents registered in $CANARY_RINGS — nothing to autocut."; return 0; }
  echo "== canary-rollout autocut: fleet-wide dry=$dry (gate standard: .github#548) =="
  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    echo "──────── agent: $agent ────────"
    _autocut_agent "$agent" "$dry" || echo "::warning::autocut of $agent failed (continuing fleet)"
  done <<< "$agents"
  return 0
}

# ── drift: registry vs host reusables (read-only audit, #1082) ──────────────────
# canary-rings.json's .agents{} is the MANUAL source of truth for what the canary
# pipeline manages — both autocut and evaluate-all iterate `.agents | keys`, so ANY
# reusable not registered is covered by nothing (no cut, no soak, no gate, no dashboard).
# There is otherwise no scan of the hosts' .github/workflows/*-reusable.yml, so a
# first-party reusable that was added/renamed but never registered ships with ZERO staged
# rollout until a human remembers to register it.
#
# `drift` closes that observability gap: it enumerates the *-reusable.yml on every
# registered host repo, diffs against the registry's reusable paths, and REPORTS (stdout +
# job summary) two classes of drift. It is read-only — it never registers anything (ring
# topology/members need human intent); `--emit-stub` optionally prints a scaffold
# .agents[<name>] block for a maintainer to fill in.
#   - unregistered: a *-reusable.yml present on a host but absent from canary-rings.json.
#   - missing-file: a registry entry whose reusable file no longer exists on its host.

# _registered_hosts — the set of host repos to scan: the union of every agent's `host`
# and the org_infra_repos list, deduped (one repo per line).
_registered_hosts() {
  _jq -r '([.agents[]?.host // empty] + (.org_infra_repos // []))
          | map(select(. != "")) | unique | .[]'
}

# _gh_list_reusables <repo> [registered_paths] — the full paths of reusable workflow files
# under the repo's .github/workflows (one per line). Reads the directory listing via the
# contents API and filters locally (mirrors _run_json: raw fetch, jq in the caller). Returns
# non-zero when the listing could NOT be enumerated (the API errored or did not return a JSON
# array), so the caller can distinguish "no reusables here" from "could not read the host" —
# the latter must NOT be treated as every registered reusable having been deleted (a false
# missing-file avalanche). A genuinely empty (but readable) workflows dir returns success
# with no output.
#
# A reusable is normally named `*-reusable.yml`. The optional newline-separated
# `registered_paths` (the registry's reusable paths for this host) ALSO admits a present file
# whose name is grandfathered off that convention — e.g. `pr-review.yml`, the pr-review engine
# kept on its legacy name until #1127 — so drift does not false-flag a legitimately-registered,
# actually-present reusable as `missing-file` (petry-projects/.github#1166). Both branches
# require the file to be present in the host listing, so a genuinely-deleted registered
# reusable (registered but NOT in the listing) is still reported missing.
_gh_list_reusables() {
  local repo="$1" registered="${2:-}" json=""
  # Strip CRs so a CRLF-terminated registered path still string-matches a host path (jq
  # splits on "\n" and a trailing "\r" would make every comparison miss).
  registered="${registered//$'\r'/}"
  json="$(gh api "repos/$repo/contents/.github/workflows" 2>/dev/null)" || return 1
  # An empty (but exit-0) body is not a readable listing — treat it as an enumeration
  # failure so the caller skips the host rather than false-flagging every reusable gone.
  [ -n "$json" ] || return 1
  jq -e 'type=="array"' >/dev/null 2>&1 <<< "$json" || return 1
  # The array type is validated above, so iterate with `.[]` (not `.[]?`): the optional
  # operator would silently swallow an iteration error on a malformed element instead of
  # surfacing it. `any(...)` is the idiomatic membership test for the registered paths.
  jq -r --arg reg "$registered" '
    ($reg | split("\n") | map(select(length>0))) as $regpaths
    | [ .[] | select(.type=="file")
        | .path as $p
        | select(($p | endswith("-reusable.yml")) or any($regpaths[]; . == $p))
        | $p ] | .[]' 2>/dev/null <<< "$json" || true
  return 0
}

# _registered_reusables_for_host <host> — the reusable paths registered to <host> (one
# per line, deduped).
_registered_reusables_for_host() {
  _jq -r --arg h "$1" '[.agents[]? | select(.host==$h) | .reusable // empty] | unique | .[]'
}

# _unmanaged_reusables_for_host <host> — reusable paths on <host> INTENTIONALLY out of the
# ring-gate model, recorded in the `unmanaged` block (#651): single-hop channel reusables,
# frozen-major `@vN` infra, or dispatch-only workflows. drift excludes these so its
# "unregistered" signal only flags reusables that genuinely still need onboarding.
_unmanaged_reusables_for_host() {
  _jq -r --arg h "$1" '[.unmanaged[]? | select(.host==$h) | .reusable // empty] | unique | .[]'
}

# _agents_for_reusable <host> <path> — the registry agent name(s) whose (host,reusable)
# match, joined by ", " (for the missing-file finding message).
_agents_for_reusable() {
  _jq -r --arg h "$1" --arg p "$2" \
    '[.agents | to_entries[] | select(.value.host==$h and .value.reusable==$p) | .key] | join(", ")'
}

# _drift_scaffold <host> <path> — a scaffold .agents[<name>] JSON block for an unregistered
# reusable, keyed by the name derived from the filename (foo-reusable.yml → foo). Clones an
# existing agent's ring topology + gate defaults as a starting point (members need human
# intent), resets host/reusable/run_workflow, and empties the per-reusable benign allowlist
# so a new reusable does not silently inherit another agent's benign classes. --emit-stub only.
_drift_scaffold() {
  local host="$1" path="$2" name
  name="${path##*/}"; name="${name%-reusable.yml}"
  _jq --arg h "$host" --arg p "$path" --arg n "$name" '
    (.agents | to_entries | (map(select(.value.host==$h)) + .) | .[0].value) as $tpl
    | { ($n): ($tpl
        | .host = $h
        | .reusable = $p
        | .run_workflow = "TODO: set to the reusable workflow name (the name: value)"
        | (.gate.benign_failure_classes) = []) }'
}

# _channel_tag_major_gaps <agent> — for an agent that has an ESTABLISHED channel major, echo one
# tier per line whose BARE channel tag `<agent>/<tier>` exists but whose v-scoped counterpart
# `<agent>/v<M>-<tier>` does NOT (the #1065 AC3 drift class). Empty for the legacy bare-only fleet
# (no channel major) — such an agent legitimately carries only bare tier tags. This is exactly the
# gap the promotion bootstrap trap (AC1′) could leave: a stub deploy keys the pin on the channel
# major and would pin a nonexistent `<agent>/v<M>-<tier>`, a fleet-wide startup_failure.
_channel_tag_major_gaps() {
  local agent="$1" major tier channels
  major="$(_agent_current_channel_major "$agent")"
  _agent_has_channel_major "$agent" "$major" || return 0
  channels="$(ordered_channels "$agent")"
  for tier in ${channels//,/ }; do
    [ -z "$tier" ] && continue
    [ -n "$(_channel_tag_commit "$agent" "$tier")" ] || continue          # no bare tier tag → nothing to pair
    [ -z "$(_channel_tag_commit "$agent" "v${major}-${tier}")" ] && printf '%s\n' "$tier"
  done
}

# cmd_drift [--emit-stub] — the read-only registry/host drift audit. Exits 0 (report-only);
# each finding is a ::warning:: annotation and a job-summary row. --emit-stub additionally
# prints a scaffold .agents[<name>] block per unregistered reusable.
cmd_drift() {
  local emit_stub=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --emit-stub) emit_stub=true ;;
      *) echo "::error::unknown drift flag: $1" >&2; return 2 ;;
    esac; shift
  done
  echo "== canary-rollout drift: registry vs host reusables (read-only; gate standard: .github#548) =="
  local hosts host rows="" stubs="" u_total=0 m_total=0
  hosts="$(_registered_hosts)"
  if [ -z "$hosts" ]; then
    echo "no host repos resolved from $CANARY_RINGS — nothing to audit."; return 0
  fi
  while IFS= read -r host; do
    [ -z "$host" ] && continue
    echo "──────── host: $host ────────"
    local present registered unmanaged_r unregistered missing p agents
    registered="$(_registered_reusables_for_host "$host")"
    # Pass the registered paths so a present-but-grandfathered-named reusable (e.g.
    # pr-review.yml, #1127/#1166) is recognised as present rather than false-flagged
    # missing-file. A genuinely-deleted registered reusable is still absent from the
    # listing and so still reported.
    if ! present="$(_gh_list_reusables "$host" "$registered")"; then
      # Could not read the host's workflows dir — skip it rather than false-flag every
      # registered reusable as missing-file. Read-only + best-effort: a warning, not a failure.
      echo "::warning::drift $host: could not enumerate .github/workflows (API error / no access) — skipping host this cycle"
      continue
    fi
    unmanaged_r="$(_unmanaged_reusables_for_host "$host")"
    local reg_arr=() pres_arr=() um_arr=() reg_str="" pres_str="" um_str=""
    if [ -n "$registered" ]; then mapfile -t reg_arr <<< "$registered"; fi
    if [ -n "$present" ]; then mapfile -t pres_arr <<< "$present"; fi
    if [ -n "$unmanaged_r" ]; then mapfile -t um_arr <<< "$unmanaged_r"; fi
    [ "${#reg_arr[@]}" -gt 0 ] && reg_str=" ${reg_arr[*]}"
    [ "${#pres_arr[@]}" -gt 0 ] && pres_str=" ${pres_arr[*]}"
    [ "${#um_arr[@]}" -gt 0 ] && um_str=" ${um_arr[*]}"
    echo "  registered reusables (${#reg_arr[@]}):$reg_str"
    echo "  present reusables (${#pres_arr[@]}):$pres_str"
    [ "${#um_arr[@]}" -gt 0 ] && echo "  unmanaged (intentional, out of ring gate) (${#um_arr[@]}):$um_str"
    # unregistered = present on the host, minus registered agents AND intentionally-unmanaged (#651).
    unregistered="$(set_difference "$(set_difference "$present" "$registered")" "$unmanaged_r")"
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      echo "::warning::DRIFT[unregistered] $host: $p present on host but absent from canary-rings.json (no cut/soak/gate/dashboard until registered)"
      rows+="| \`$host\` | unregistered | \`$p\` | not in \`.agents{}\` — register it or delete the file |"$'\n'
      u_total=$((u_total + 1))
      if [ "$emit_stub" = true ]; then stubs+="$(_drift_scaffold "$host" "$p")"$'\n'; fi
    done <<< "$unregistered"
    # missing-file = registered in the registry but the file is gone from the host.
    missing="$(set_difference "$registered" "$present")"
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      agents="$(_agents_for_reusable "$host" "$p")"
      echo "::warning::DRIFT[missing-file] $host: registry agent '${agents:-?}' -> $p not found on host (deleted/renamed reusable; stale registry entry)"
      rows+="| \`$host\` | missing-file | \`$p\` | registry agent \`${agents:-?}\` points at a file that no longer exists |"$'\n'
      m_total=$((m_total + 1))
    done <<< "$missing"
  done <<< "$hosts"

  echo "----"
  local total=$((u_total + m_total))
  echo "drift summary: $u_total unregistered, $m_total missing-file ($total total findings)"
  if [ "$total" -eq 0 ]; then
    echo "no reusable drift detected — the registry and host reusables are in sync."
  fi
  if [ "$emit_stub" = true ] && [ -n "$stubs" ]; then
    echo "---- scaffold .agents[<name>] stubs for unregistered reusables (--emit-stub) ----"
    echo "Paste into standards/canary-rings.json under .agents, then set run_workflow + review ring members:"
    printf '%s' "$stubs"
  fi

  # Render the fleet-drift table into the run's job summary (a read-only snapshot). Falls
  # back to stdout when GITHUB_STEP_SUMMARY is unset (local/manual runs).
  local ts dmd
  ts="$(date -u +%Y-%m-%dT%H:%MZ 2>/dev/null || echo unknown)"
  if [ "$total" -eq 0 ]; then
    dmd="$(printf '# Canary Rollout — reusable drift\n\nLast updated: `%s` · gate standard: .github#548.\n\n_No reusable drift — the registry and host `*-reusable.yml` are in sync._\n' "$ts")"
  else
    dmd="$(printf '# Canary Rollout — reusable drift\n\nLast updated: `%s` · gate standard: .github#548 · findings: **%s** (%s unregistered, %s missing-file).\n\n| host | class | reusable | note |\n|---|---|---|---|\n%s\n> `unregistered` ships with ZERO staged rollout until added to `.agents{}`; `missing-file` is a stale registry entry pointing at a deleted reusable. Report-only — no auto-registration.\n' "$ts" "$total" "$u_total" "$m_total" "${rows%$'\n'}")"
  fi
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    if printf '\n%s\n' "$dmd" >> "$GITHUB_STEP_SUMMARY"; then
      echo "  wrote reusable-drift table to the job summary"
    else
      echo "::warning::could not write the reusable-drift job summary"
    fi
  fi

  # ── per-agent "merged but not shipped" (#1019) ────────────────────────────────
  # For each registered agent, compare the `next` channel commit against host main HEAD across
  # the agent_ref-consumed paths. A non-empty diff means a change merged to host main that the
  # pinned channel has NOT yet shipped — the exact failure mode where a PR merges, CI stays
  # green, the issue closes, and the change reaches nobody. autocut should self-heal this on the
  # next tick; the report makes any lag visible without a hand-run `git diff`.
  echo "----"
  echo "== agent_ref ship-drift: next channel vs host main (agent_ref-consumed paths) =="
  local agents a unshipped_total=0 ship_rows=""
  agents="$(_jq -r '.agents? | keys[]?' 2>/dev/null || true)"
  while IFS= read -r a; do
    [ -z "$a" ] && continue
    local a_host a_defbranch a_main a_next hits hitcsv h changed_files watched
    a_host="$(_agent_field "$a" host)"; a_host="${a_host:-$THIS_REPO}"
    a_next="$(channel_commit "$a" next)"
    a_defbranch="$(_gh_default_branch "$a_host")"; [ -z "$a_defbranch" ] && a_defbranch="main"
    a_main="$(_gh_head_sha "$a_host" "$a_defbranch")"
    if [ -z "$a_next" ] || [ -z "$a_main" ]; then
      echo "  $a: could not resolve next/main HEAD on $a_host — skipping"
      continue
    fi
    if [ "$a_next" = "$a_main" ]; then
      echo "  $a: shipped — next (${a_next:0:12}) == $a_host main HEAD"
      continue
    fi
    watched="$(_watched_paths "$a")"
    changed_files="$(_gh_changed_files "$a_host" "$a_next" "$a_main")"
    hits="$(watched_hits "$changed_files" "$watched")"
    if [ -z "$hits" ]; then
      echo "  $a: shipped — next differs from main but no agent_ref-consumed path changed"
      continue
    fi
    hitcsv=""
    while IFS= read -r h; do [ -z "$h" ] && continue; hitcsv="${hitcsv:+$hitcsv, }$h"; done <<< "$hits"
    echo "::warning::DRIFT[unshipped] $a: $a_host main (${a_main:0:12}) has agent_ref changes not on next (${a_next:0:12}): $hitcsv"
    ship_rows+="| \`$a\` | \`$a_host\` | \`$hitcsv\` | merged to main but not on the \`next\` channel (autocut should cut) |"$'\n'
    unshipped_total=$((unshipped_total + 1))
  done <<< "$agents"
  echo "ship-drift summary: $unshipped_total agent(s) with merged-but-unshipped agent_ref changes"

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ "$unshipped_total" -gt 0 ]; then
    local smd
    smd="$(printf '# Canary Rollout — ship-drift (merged but not shipped)\n\nLast updated: `%s` · %s agent(s) whose `next` channel lags host main across agent_ref-consumed paths.\n\n| agent | host | changed paths | note |\n|---|---|---|---|\n%s\n> autocut (#1069) should cut a new candidate on the next tick; a persistent row means autocut is disabled or blocked.\n' "$ts" "$unshipped_total" "${ship_rows%$'\n'}")"
    printf '\n%s\n' "$smd" >> "$GITHUB_STEP_SUMMARY" \
      || echo "::warning::could not write the ship-drift job summary"
  fi

  # ── channel-tag drift: a bare tier tag lacking its v<M>-<tier> counterpart (#1065 AC3) ──
  # For every agent with an established channel major, a bare `<agent>/<tier>` must have its
  # v-scoped `<agent>/v<M>-<tier>` counterpart. The promotion bootstrap trap (AC1′) could strand
  # the v-line at whatever tier it was first seeded at, leaving a bare-only tier that resolution
  # silently masked but a stub deploy — which keys the pin on the channel major — would pin to a
  # NONEXISTENT ref, a fleet-wide startup_failure. This sweep surfaces the gap in one read-only
  # pass so it never again needs a hand-run audit. Backfilling the missing tag is a maintainer
  # action (it creates a channel tag); drift only reports.
  echo "----"
  echo "== channel-tag drift: bare tier tag without its v<M>-<tier> counterpart (#1065) =="
  local ct_agent ct_major ct_gaps ct_tier ct_total=0 ct_rows=""
  while IFS= read -r ct_agent; do
    [ -z "$ct_agent" ] && continue
    ct_major="$(_agent_current_channel_major "$ct_agent")"
    ct_gaps="$(_channel_tag_major_gaps "$ct_agent")"
    [ -z "$ct_gaps" ] && continue
    for ct_tier in $ct_gaps; do
      [ -z "$ct_tier" ] && continue
      echo "::warning::DRIFT[channel-tag] $ct_agent: has /$ct_tier but NO v${ct_major}-$ct_tier (a stub deploy to this tier would pin a nonexistent @$ct_agent/v${ct_major}-$ct_tier)"
      ct_rows+="| \`$ct_agent\` | \`$ct_tier\` | \`$ct_agent/v${ct_major}-$ct_tier\` | bare tier tag exists but its v-scoped counterpart is missing — a stub deploy pins a nonexistent ref (maintainer backfill) |"$'\n'
      ct_total=$((ct_total + 1))
    done
  done <<< "$agents"
  echo "channel-tag drift summary: $ct_total tier(s) missing a v<M>-<tier> counterpart"

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ "$ct_total" -gt 0 ]; then
    local ctmd
    ctmd="$(printf '# Canary Rollout — channel-tag drift (missing v<M>-<tier>)\n\nLast updated: `%s` · %s tier(s) with a bare channel tag lacking its v-scoped counterpart.\n\n| agent | tier | missing ref | note |\n|---|---|---|---|\n%s\n> A ring-promotion bootstrap gap (#1065). A stub deploy keyed on the channel major pins `<agent>/v<M>-<tier>`; if it does not exist the fleet fails at startup. A maintainer backfills the tag at its bare counterpart'"'"'s commit.\n' "$ts" "$ct_total" "${ct_rows%$'\n'}")"
    printf '\n%s\n' "$ctmd" >> "$GITHUB_STEP_SUMMARY" \
      || echo "::warning::could not write the channel-tag drift job summary"
  fi
  return 0
}

main() {
  local cmd
  for cmd in jq gh git; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "::error::Required command '$cmd' is not installed." >&2
      return 1
    fi
  done
  if [ -n "${SOAK_WINDOW_DAYS:-}" ] && ! [[ "${SOAK_WINDOW_DAYS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "::error::SOAK_WINDOW_DAYS, when set, must be a positive integer" >&2
    return 2
  fi
  # Per-process run-list cache shared across the fan-out's command-substitution subshells
  # (#819) — exported so subshells inherit the path, and reaped on exit. This trap lives in
  # the PARENT shell; _repo_wf_runs_cached's errfile trap lives in the per-call subshells, so
  # the two are in different shells and never clobber each other.
  if [ -z "${_RUNS_CACHE_DIR:-}" ]; then
    _RUNS_CACHE_DIR="$(mktemp -d 2>/dev/null || true)"
    if [ -n "$_RUNS_CACHE_DIR" ]; then
      export _RUNS_CACHE_DIR
      trap 'rm -rf "${_RUNS_CACHE_DIR:-}"' EXIT
    fi
  fi
  local sub="${1:-}"; shift || true
  case "$sub" in
    evaluate)     [ $# -ge 1 ] || { echo "usage: evaluate <agent>" >&2; return 2; }; cmd_evaluate "$@" ;;
    evaluate-all) cmd_evaluate_all ;;
    promote)      [ $# -ge 1 ] || { echo "usage: promote <agent> [--override] [--confirm] [--allow-pre-existing] [--dry-run]" >&2; return 2; }; cmd_promote "$@" ;;
    promote-all)  cmd_promote_all "$@" ;;
    rollback)     [ $# -ge 2 ] || { echo "usage: rollback <agent> <ring> --to <vX.Y.Z>" >&2; return 2; }; cmd_rollback "$@" ;;
    resolve)      [ $# -ge 2 ] || { echo "usage: resolve <agent> <channel>" >&2; return 2; }; resolve_members "$@" ;;
    sync-issues)  cmd_sync_issues "$@" ;;   # upsert blocker issues + dashboard for held promotions
    sync-promotion-failures) cmd_sync_promotion_failures "$@" ;;  # escalate failing tag writes into durable issues (#1023)
    autocut)      cmd_autocut "$@" ;;       # cut a new candidate when a reusable changes on main (#1069)
    drift)        cmd_drift "$@" ;;         # report reusables present on a host but unregistered, + stale registry entries (#1082)
    *) echo "::error::usage: canary-rollout.sh {autocut|drift|evaluate|evaluate-all|promote|promote-all|rollback|resolve|sync-issues|sync-promotion-failures} [args]" >&2; return 2 ;;
  esac
}

# Source-guard: tests source this file to exercise resolve_members etc. without running.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
