#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ring-pins.sh — single source of truth for the canary-ring pin model.
#
# The #482 `.github`-hosted reusables (and dev-lead) are released through the
# concentric-ring channels of epic #495: next → ring0 → ring1 → stable. Both
# the compliance audit (`check_centralized_workflow_stubs` in
# compliance-audit.sh) and the deploy sweep (`is_already_compliant` in
# deploy-standard-workflows.sh) must agree on
#   (a) which repo sits in which ring tier, and
#   (b) which `@<channel>` refs are acceptable for a stub in that repo,
# otherwise "drift" (deploy) and "non-compliant" (audit) diverge — the exact
# three-way inconsistency #482 exists to close. This file is sourced by both so
# they can never drift again.
#
# Keep the topology in sync with petry-projects/.github-private's
# scripts/cut-release.sh channels and docs/release/.
# ---------------------------------------------------------------------------

# Reusable channel base-names on the canary-ring model. These are the basenames
# WITHOUT the `-reusable` suffix (e.g. `auto-rebase`, not `auto-rebase-reusable`)
# and WITHOUT the `.yml` extension. dev-lead is included: it is ring-released too
# (its reusable lives in .github-private but the same tier topology applies).
#
# This list MUST equal `.agents | keys` in standards/canary-rings.json so every
# REGISTERED agent is ring-managed: the deploy sweep computes its repo's tier
# channel (via emit_ref_for) and the audit accepts the tier channels, instead of
# shipping the template's hardcoded @<agent>/v1-stable verbatim (#1088). Agreement
# is asserted by the "RING_REUSABLES equals the canary-rings.json agent registry"
# test in test/scripts/lib/ring-pins.bats — mirroring canary-rollout.yml's dispatch
# `agent` enum, which carries the same registry-agreement contract (#1019).
readonly RING_REUSABLES=(
  add-to-project
  agent-shield
  apply-repo-settings
  auto-rebase
  ci-failure-analyst
  dependabot-automerge
  dependabot-rebase
  dependency-audit
  dev-lead
  feature-ideation
  idea-enhancer
  idea-triage
  initiative-planner
  persona-mention
  pr-auto-review
  pr-review
  pr-review-mention
)

# Path to the ring registry (single source of truth). Overridable via CANARY_RINGS
# for tests, mirroring canary-rollout.sh / migrate-major-channels.sh; defaults to
# standards/canary-rings.json relative to this lib. Resolved at source time so it
# is correct no matter which script sources ring-pins.sh (#1092).
RING_PINS_REGISTRY="${CANARY_RINGS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/standards/canary-rings.json}"

# ring_tier_for_repo <agent> <repo> -> next|ring0|ring1|stable
# Resolve a repo's canary-ring tier FOR A GIVEN AGENT (epic #495 topology),
# derived from that agent's rings[] in standards/canary-rings.json — the single
# source of truth (#1092). Ring membership is per-agent: the tier a repo sits in
# can differ between agents (e.g. `markets` is ring1 for apply-repo-settings but
# stable for every other agent), which a single agent-agnostic map cannot express.
#
# The repo is matched by basename, so callers may pass a bare name (`markets`) or a
# full `petry-projects/<repo>`. The `$host` and `$org_infra` member tokens are
# expanded (host = the agent's own host repo → next; org_infra = the other infra
# repo → ring0), and the first ring (registry order = tier order) whose members
# contain the repo wins. Repos in no explicit ring fall back to the ring whose
# members contain the `"*"` fleet wildcard (today: stable). An unknown agent (not
# in the registry) also falls back to `stable`.
ring_tier_for_repo() {
  local agent="$1" repo="$2"
  if [ -z "$agent" ]; then
    echo "ring_tier_for_repo: missing agent argument (signature is <agent> <repo>)" >&2
    return 2
  fi
  local repo_name="${repo##*/}"
  # Self-initializing per-process cache: within one run the registry is immutable, so
  # (agent, repo-basename) -> tier is a pure function. Cache it to avoid re-parsing the
  # registry with jq on every call — the audit (pinned-version-report.sh) and deploy
  # sweeps invoke this inside nested loops over every repo × agent (#1096). Same
  # pattern as _RING_TAG_EXISTS_CACHE below.
  declare -g -A _RING_TIER_CACHE 2>/dev/null || true
  local cache_key="${agent},${repo_name}"
  if [[ -n "${_RING_TIER_CACHE[$cache_key]+isset}" ]]; then
    printf '%s' "${_RING_TIER_CACHE[$cache_key]}"
    return 0
  fi
  local tier status
  # Resolve tiers in the registry's `order` sequence (not array position) so a
  # reordered registry can never make pin resolution disagree with the rollout
  # promotion order that canary-rollout.sh drives off the same `order` field (#1096).
  tier="$(jq -r --arg a "$agent" --arg repo "$repo_name" '
    .agents[$a] as $ag
    | if $ag == null then "" else
        ($ag.host | sub(".*/";"")) as $host
        | ([.org_infra_repos[]? | sub(".*/";"")] - [$host]) as $orginfra
        | ( $ag.rings
            | sort_by(.order)
            | map({ channel,
                    m: (reduce (.members[]?) as $x ([];
                          if   $x == "$host"      then . + [$host]
                          elif $x == "$org_infra" then . + $orginfra
                          else . + [($x | sub(".*/";""))] end)) }) ) as $r
        | ( ([$r[] | select(.m | index($repo)) | .channel][0])
            // ([$r[] | select(.m | index("*"))  | .channel][0])
            // "" )
      end
  ' "$RING_PINS_REGISTRY" 2>/dev/null)"
  status=$?
  # Fail CLOSED on a registry read/parse error (missing or corrupt file, or a jq
  # failure): silently returning `stable` when the source of truth is unavailable
  # would let the audit accept — and the deploy emit — incorrect stable pins,
  # masking real ring drift (#1096). Mirrors ring_host_current_channel_major's
  # fail-closed probe (#870). A read error is NOT cached, so a transient failure
  # does not poison later lookups.
  if [ "$status" -ne 0 ]; then
    echo "ring_tier_for_repo: failed to read ring registry '$RING_PINS_REGISTRY' (agent=$agent repo=$repo_name)" >&2
    return 3
  fi
  # jq succeeded: an empty result is a genuine no-match — an unknown agent (not in
  # the registry) or a repo in no explicit ring — so fall back to the broad-fleet
  # tier (the `*` ring is `stable` fleet-wide today). This is distinct from the
  # infra read error above and IS a valid, cacheable answer.
  [ -n "$tier" ] || tier="stable"
  _RING_TIER_CACHE[$cache_key]="$tier"
  printf '%s' "$tier"
  return 0
}

# ring_is_ring_reusable <channel-base> -> 0 if the reusable is on the ring model
ring_is_ring_reusable() {
  local name="$1" r
  for r in "${RING_REUSABLES[@]}"; do
    [ "$r" = "$name" ] && return 0
  done
  return 1
}

# ring_reusable_file <agent> -> the reusable workflow FILENAME (basename, incl. `.yml`)
# a caller stub references in its `uses:` line for this agent. Conventionally
# `<agent>-reusable.yml`, but the registry's `reusable` path is the single source of
# truth, so a grandfathered legacy name (e.g. `pr-review.yml`, the pr-review engine kept
# on its pre-convention name until #1127) is returned as-is. Without this, callers that
# hardcode the `-reusable.yml` suffix — e.g. pinned-version-report.sh's `uses:` matcher —
# fail to match the grandfathered reusable and silently omit it from their reports (#1166).
# Falls back to the convention when the agent is unknown/unregistered.
ring_reusable_file() {
  local agent="$1" path
  path="$(jq -r --arg a "$agent" '.agents[$a].reusable // empty' "$RING_PINS_REGISTRY" 2>/dev/null)"
  if [ -n "$path" ]; then
    printf '%s' "${path##*/}"
  else
    printf '%s-reusable.yml' "$agent"
  fi
  return 0
}

# ring_caller_stub <agent> -> the caller-stub workflow PATH (repo-relative) a consumer
# pins this agent's reusable through. Conventionally `.github/workflows/<agent>.yml`, but
# when the engine reusable is grandfathered to a name that collides with that convention
# (the pr-review ENGINE is itself `pr-review.yml`, invoked by the SEPARATE
# `pr-review-trigger.yml` stub — #1127), the convention would point a scanner at the engine
# instead of the real caller. The registry's optional `caller_stub` overrides the
# convention so pinned-version-report.sh reads the caller that carries the `@<channel>` pin
# rather than the workflow_call-only engine (which has no self-referencing `uses:`) (#1166).
# Falls back to the convention when the agent has no `caller_stub`.
ring_caller_stub() {
  local agent="$1" stub
  stub="$(jq -r --arg a "$agent" '.agents[$a].caller_stub // empty' "$RING_PINS_REGISTRY" 2>/dev/null)"
  if [ -n "$stub" ]; then
    printf '%s' "$stub"
  else
    printf '.github/workflows/%s.yml' "$agent"
  fi
  return 0
}

# ring_canonical_ref <channel-base> <repo> [major] -> the org-standard ref a stub
# in <repo> should pin: the channel tag for the repo's ring tier, e.g.
# `agent-shield/ring1` on a ring1 repo.
#
# With an optional MAJOR argument (major-scoped-channels epic #657, Phase F3) the
# ref becomes the major-scoped form `<channel>/v<major>-<tier>`, e.g.
# `agent-shield/v2-ring1`. Omit MAJOR for the legacy bare-tier form — consumers
# are still pinned to bare `<tier>` today and only migrate to the `v<M>-` form in
# F5, so the no-major call site behavior is unchanged.
ring_canonical_ref() {
  local name="$1" repo="$2" major="${3:-}"
  local tier; tier="$(ring_tier_for_repo "$name" "$repo")"
  if [ -n "$major" ]; then
    printf '%s/v%s-%s' "$name" "$major" "$tier"
  else
    printf '%s/%s' "$name" "$tier"
  fi
  return 0
}

# ring_pinned_major <ref> -> the major a consumer's channel ref has opted into, or
# empty for a legacy/unmajored bare-tier ref (major-scoped-channels epic #657,
# Phase F3). Pure. Given a `uses: …@<agent>/<channel>` ref (or bare channel):
#   `<agent>/v<M>-<tier>` -> `M`   (e.g. agent/v3-stable -> 3)
#   `<agent>/<tier>`      -> ``    (e.g. agent/stable    -> empty)
# Only the channel segment (after the last `/`) is inspected, so the agent/repo
# prefix is irrelevant.
ring_pinned_major() {
  local channel="${1##*/}"
  if [[ "$channel" =~ ^v([0-9]+)- ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
  return 0
}

# ring_accepted_refs <channel-base> <repo> -> newline-separated list of refs that
# a stub in <repo> may pin without being flagged/reverted. The FIRST line is the
# canonical tier channel; the rest are every ring channel, so a repo pinned to a
# HIGHER tier than its own (e.g. a ring1 repo still on /stable, or a /next pin
# promoted toward /stable) is never flagged and cut-release.sh promotions roll
# without the audit tripping mid-promotion.
#
# The pre-ring @v1/@v2 migration grace was DROPPED in #870 once the whole fleet
# was confirmed on `<name>/<tier>` channels (only .github's own dogfood callers
# still carry @v2, and both consumers skip .github). A stub on @v1/@v2/SHA/@main
# is now flagged — the migration is complete, so those are genuine drift.
ring_accepted_refs() {
  local name="$1" repo="$2"
  local canonical; canonical=$(ring_canonical_ref "$name" "$repo")
  printf '%s\n' "$canonical"
  printf '%s/next\n%s/ring0\n%s/ring1\n%s/stable\n' "$name" "$name" "$name" "$name" | grep -vFx "$canonical"
  return 0
}

# ring_legacy_csv <channel-base> <repo> -> the accepted refs EXCEPT the canonical
# one, comma-joined. Convenience for callers (the audit) that pass canonical and
# legacy separately.
ring_legacy_csv() {
  ring_accepted_refs "$1" "$2" | tail -n +2 | paste -sd, -
  return 0
}

# ══ major-scoped channels tooling — F5 shared helpers (epic #657) ══════════════

# ring_highest_major <version>... -> the MAJOR of the highest strict semver among
# the arguments, or empty if none is a valid `[v]X.Y.Z`. Tolerates a leading `v`
# on a token; non-semver tokens are ignored. Pure; always returns 0.
ring_highest_major() {
  local v major best=""
  for v in "$@"; do
    v="${v#v}"
    [[ "$v" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || continue
    major="${BASH_REMATCH[1]}"
    if [ -z "$best" ] || [ "$major" -gt "$best" ]; then
      best="$major"
    fi
  done
  [ -n "$best" ] && printf '%s' "$best"
  return 0
}

# _ring_fetch_version_tokens <host-repo> <channel-base> -> strips the
# `refs/tags/<base>/v` prefix from each matching-ref, one token per line.
# Returns 0 (with tokens, or empty stdout if no refs match) on success; returns
# 1 if the gh call itself fails. Callers decide the warning and fallback.
_ring_fetch_version_tokens() {
  local out
  out="$(gh api "repos/$1/git/matching-refs/tags/$2/v" \
           --jq '.[]?.ref' 2>/dev/null)" || return 1
  sed -n "s#^refs/tags/$2/v##p" <<< "$out"
}

# ring_host_current_major <host-repo> <channel-base> -> the current major line for
# an agent, derived from its release tags `<base>/vX.Y.Z` on the host repo, or
# empty if the agent has no release (so callers fall back to the bare-tier form).
# gh-backed. Requires GH_TOKEN. Fails open (returns 0) on probe error.
ring_host_current_major() {
  local host="$1" base="$2" refs
  refs="$(_ring_fetch_version_tokens "$host" "$base")" || {
    echo "Warning: failed to fetch matching refs for ${host}/${base}" >&2
    return 0
  }
  # shellcheck disable=SC2086
  ring_highest_major $refs
  return 0
}

# ring_highest_channel_major <token>... -> the highest major M among CHANNEL tokens
# of the form `<M>-<tier>` (tier = stable|next|ring<N>), or empty if none. A release
# semver token like `14.0.0` is NOT a channel token and is ignored. Pure; always 0.
#
# This is the CALLER-CONTRACT major, deliberately distinct from ring_highest_major's
# release major (#870): dev-lead ships releases `dev-lead/v14.0.0` but its channel
# contract is `dev-lead/v1-<tier>`, so a pin must track the channel major (v1). A
# `<base>/v<release>-<tier>` ref has no tag and fails to resolve — the #870 breakage.
ring_highest_channel_major() {
  local tok major best=""
  for tok in "$@"; do
    [[ "$tok" =~ ^([0-9]+)-(stable|next|ring[0-9]+)$ ]] || continue
    major="${BASH_REMATCH[1]}"
    if [ -z "$best" ] || [ "$major" -gt "$best" ]; then
      best="$major"
    fi
  done
  [ -n "$best" ] && printf '%s' "$best"
  return 0
}

# ring_host_current_channel_major <host-repo> <channel-base> -> the highest major M
# for which a CHANNEL tag `<base>/v<M>-<tier>` exists on the host, or empty if the
# agent has no channel tag (so callers fall back to the bare-tier form). This is the
# ref a consumer stub must pin — NOT the release major (#870). gh-backed. Requires
# GH_TOKEN. Fails closed (returns 1) on probe error so callers cannot silently fall
# back to bare-tier pins during an API outage.
ring_host_current_channel_major() {
  local host="$1" base="$2" refs
  refs="$(_ring_fetch_version_tokens "$host" "$base")" || {
    echo "Warning: failed to fetch matching refs for ${host}/${base}" >&2
    return 1
  }
  # shellcheck disable=SC2086
  ring_highest_channel_major $refs
  return 0
}

# ring_tag_exists <host-repo> <ref> -> 0 iff refs/tags/<ref> resolves on <host>.
# The assert-exists guard: a computed channel ref is validated to exist before a
# stub is pinned to it, so the deploy never opens a PR carrying a non-resolving
# `@<base>/v<M>-<tier>` pin (#870). gh-backed. Requires GH_TOKEN.
# Emits a warning when the gh failure is NOT a 404 (auth, rate-limit, network).
# Caches results in a process-global associative array to avoid duplicate calls.
ring_tag_exists() {
  # Self-initializing cache: declare -g creates a global even when called inside a
  # function; the 2>/dev/null silences the no-op when already declared correctly.
  declare -g -A _RING_TAG_EXISTS_CACHE 2>/dev/null || true
  local cache_key="$1/$2"
  if [[ "${_RING_TAG_EXISTS_CACHE[$cache_key]+isset}" ]]; then
    return "${_RING_TAG_EXISTS_CACHE[$cache_key]}"
  fi
  local out status
  out="$(gh api "repos/$1/git/ref/tags/$2" 2>&1)"; status=$?
  if [ "$status" -ne 0 ] && ! grep -qi 'not found\|404' <<< "$out"; then
    echo "Warning: tag-existence lookup failed for $1/$2 (not a 404): ${out}" >&2
  fi
  _RING_TAG_EXISTS_CACHE[$cache_key]="$status"
  return "$status"
}

# ring_repin_uses <channel-base> <newref> -> rewrite a workflow stub read on stdin
# so its reusable `uses:` ref (and any matching `agent_ref:`/`checkout_ref:`) points
# at <newref>. Only lines referencing THIS agent's reusable are touched; the trailing
# comment on a rewritten line is preserved. Pure (sed only).
#
# `checkout_ref:` is a `with:` forward that some stubs (e.g. apply-repo-settings)
# pin to the SAME channel as `uses:` so the reusable checks out the matching version
# of .github's scripts — it must stay in lockstep with the `uses:` channel pin, so it
# is re-pinned alongside `uses:` here. This only re-pins the VALUE of an input the
# stub already forwards (never adds/forwards a new one), so it never introduces the
# undeclared-input channel-skew defect (#1052).
ring_repin_uses() {
  local base="$1" newref="$2"
  sed -E \
    -e "s#^([[:space:]]*uses:[[:space:]]*petry-projects/[^@[:space:]]*/${base}-reusable\.yml)@[^[:space:]]+#\1@${newref}#" \
    -e "s#^([[:space:]]*agent_ref:[[:space:]]*[\"']?)${base}/[^\"'[:space:]]+#\1${newref}#" \
    -e "s#^([[:space:]]*checkout_ref:[[:space:]]*[\"']?)${base}/[^\"'[:space:]]+#\1${newref}#"
  return 0
}

# ring_vform_tier_aligned <pinned-ref> <channel-base> <repo> -> 0 iff <pinned-ref>
# is a major-scoped v-form `<base>/v<M>-<tier>` whose tier matches <repo>'s ring
# tier (any major). A bare-tier ref (no `v<M>-`) or a wrong-tier v-form is not
# aligned. Pure.
ring_vform_tier_aligned() {
  local ref="$1" base="$2" repo="$3" tier
  tier="$(ring_tier_for_repo "$base" "$repo")"
  [[ "$ref" =~ ^${base}/v[0-9]+-${tier}$ ]]
}

# ring_stub_selfhosts <channel-base> -> 0 iff the workflow stub read on stdin
# references THIS agent's reusable via a LOCAL `./` self-host ref (e.g.
# `uses: ./.github/workflows/<base>-reusable.yml`) rather than a channel-pinned
# consumer ref (`uses: <org>/<repo>/.../<base>-reusable.yml@<base>/<tier>`).
#
# The meta-repos (.github / .github-private) HOST some reusables locally — their
# own stubs pin those via `./`, which the F5 re-pin sweep must never touch — while
# CONSUMING others by channel (e.g. .github consumes dev-lead from .github-private),
# which the sweep must re-pin like any other consumer (#704). Pure (grep only).
ring_stub_selfhosts() {
  local base="$1"
  grep -qE "^[[:space:]]*uses:[[:space:]]*\./[^@[:space:]]*/${base}-reusable\.yml([[:space:]]|\$)"
}
