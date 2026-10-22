#!/usr/bin/env bash
# migrate-major-channels.sh — tooling to roll the canary-ring fleet from the bare
# `<agent>/<tier>` channel tags onto the major-scoped `<agent>/v<M>-<tier>` form
# (major-scoped-channels epic #657, Phase F5). This script is TOOLING ONLY: it is
# DRY_RUN-aware and, when it mutates, does so exclusively through the gh Git-refs
# API under an App token — it NEVER direct-pushes and NEVER force-moves a tag.
#
# Three operations (default = create):
#   (default)          For every ring tier of each agent, create
#                      `<agent>/v<M>-<tier>` pointing at the SAME commit as the
#                      bare `<agent>/<tier>` tag. Idempotent: a v-tag that already
#                      exists is skipped. <M> is the agent's current release major
#                      (from its `<agent>/vX.Y.Z` release tags on the host repo);
#                      an agent with no release is skipped (nothing to major-scope).
#   --emit-repins      List the enrolled-consumer stubs still pinned to a bare tier
#                      and the `v<M>-<tier>` ref each should be re-pinned to. Read
#                      only — never edits a consumer (deploy-standard-workflows.sh
#                      owns the re-pin PRs). Scans EVERY stub a consumer ships for
#                      the agent's reusable (e.g. `<agent>.yml` plus companions like
#                      `<agent>-retry.yml` / `<agent>-health.yml`), naming each file.
#   --retire-bare <a>  Delete the bare `<agent>/<tier>` tags — but ONLY once no
#                      enrolled-consumer stub still pins a bare tier. Every stub
#                      calling the reusable is checked (not just `<agent>.yml`); if
#                      any bare pin remains it REFUSES (non-zero) and names the
#                      offending files, deleting nothing.
#
# Options:
#   --dry-run          Print intended mutations without performing them. Also
#                      honored via the DRY_RUN env var (DRY_RUN=true).
#   --agent <name>     Restrict create/--emit-repins to a single agent.
#   --retire-bare <a>  Run the guarded bare-tag retirement for agent <a>.
#
# Registry: CANARY_RINGS (default standards/canary-rings.json) — the same ring
# registry the canary-rollout engine reads.
#
# Requirements: GH_TOKEN (App token) with contents+ refs scope on the host and the
# enrolled consumer repos; jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/ring-pins.sh
source "$SCRIPT_DIR/lib/ring-pins.sh"

CANARY_RINGS="${CANARY_RINGS:-$REPO_ROOT/standards/canary-rings.json}"
DRY_RUN="${DRY_RUN:-false}"

log()  { echo "[migrate] $*"; }
err()  { echo "[migrate] ERROR $*" >&2; }

# ── gh Git-refs wrappers ──────────────────────────────────────────────────────

# _tag_exists <host> <tag> -> 0 if refs/tags/<tag> exists on <host>.
_tag_exists() {
  gh api "repos/$1/git/ref/tags/$2" >/dev/null 2>&1
}

# _tag_commit <host> <tag> -> the commit sha the tag resolves to (first field of
# the ref object's sha), or empty if the tag does not exist.
_tag_commit() {
  local host="$1" tag="$2" out
  out="$(gh api "repos/${host}/git/ref/tags/${tag}" --jq '.object.sha' 2>&1)" || {
    if <<< "$out" grep -q "404"; then
      return 0
    fi
    echo "Error fetching tag commit for ${host}/${tag}: ${out}" >&2
    return 1
  }
  printf '%s' "${out%%[[:space:]]*}"
}

# _create_tag_ref <host> <tag> <sha> -> create refs/tags/<tag> at <sha> (POST).
_create_tag_ref() {
  gh api --method POST "repos/$1/git/refs" \
    -f "ref=refs/tags/$2" -f "sha=$3" >/dev/null
}

# _delete_tag_ref <host> <tag> -> delete refs/tags/<tag> (DELETE).
_delete_tag_ref() {
  gh api --method DELETE "repos/$1/git/refs/tags/$2" >/dev/null
}

# ── registry helpers ──────────────────────────────────────────────────────────

_agent_host()  { jq -r --arg a "$1" '.agents[$a]?.host?'            "$CANARY_RINGS"; }
_agent_tiers() { jq -r --arg a "$1" '.agents[$a]?.rings[]?.channel?' "$CANARY_RINGS"; }
_agent_names() { jq -r '.agents | keys[]'                         "$CANARY_RINGS"; }

# _agent_reusable_file <agent> -> the reusable's workflow FILENAME (basename), e.g.
# `dev-lead-reusable.yml`, used to identify which consumer stubs call this agent's
# reusable. Falls back to `<agent>-reusable.yml` if the registry omits `reusable`.
_agent_reusable_file() {
  local agent="$1" path
  path="$(jq -r --arg a "$agent" '.agents?[$a]?.reusable? // empty' "$CANARY_RINGS")"
  [ -z "$path" ] && path="${agent}-reusable.yml"
  printf '%s' "${path##*/}"
}

# _enrolled_consumers <agent> -> the concrete repos enrolled in <agent>'s rings,
# expanding the `$host` and `$org_infra` member tokens. The `*` fleet wildcard is
# not enumerable and is skipped (bare retirement only guards the explicitly
# enrolled canaries).
_enrolled_consumers() {
  local agent="$1" host m
  host="$(_agent_host "$agent")"
  local -a org_infra=()
  mapfile -t org_infra < <(jq -r '.org_infra_repos[]?' "$CANARY_RINGS")
  while IFS= read -r m; do
    case "$m" in
      '*')          ;;
      '$host')      printf '%s\n' "$host" ;;
      '$org_infra') [ "${#org_infra[@]}" -gt 0 ] && printf '%s\n' "${org_infra[@]}" ;;
      *)            printf '%s\n' "$m" ;;
    esac
  done < <(jq -r --arg a "$agent" '.agents[$a]?.rings[]?.members[]?' "$CANARY_RINGS") | sort -u
}

# _consumer_agent_stubs <repo> <agent> -> every channel ref pinned by every workflow
# stub in <repo> that calls <agent>'s reusable, emitted one per line as
# `<workflow-file><TAB><pinned-ref>` (e.g. `dev-lead-retry.yml\tdev-lead/next`). Two
# dimensions of coverage, both load-bearing for the retire guard:
#   • MULTI-STUB (#707): a consumer may ship more than one stub for the same reusable
#     — the canonical `<agent>.yml` PLUS companions like `<agent>-retry.yml` /
#     `<agent>-health.yml` — and the guard/emitter must see them ALL, or a bare
#     companion is silently missed.
#   • MULTI-REF PER STUB (#715): each stub carries BOTH a `uses:` pin (`@<agent>/<tier>`)
#     AND an `agent_ref:` input (`<agent>/<tier>`, no `@`). The reusable checks out its
#     tooling at agent_ref, so a bare agent_ref keeps the bare tag load-bearing (retiring
#     it while agent_ref was bare broke dev-lead, #657). Emit a line for EACH.
# Reads the consumer's `.github/workflows/` listing, then each candidate file's content,
# and keeps only files that pin THIS agent's reusable. Fail-closed: a read error that is
# NOT a 404 returns non-zero so callers abort rather than under-report.
_consumer_agent_stubs() {
  local repo="$1" agent="$2" reusable listing wf response content uses_refs agentref_refs r b64 decoded
  reusable="$(_agent_reusable_file "$agent")"
  local cache_dir="/tmp/migrate-wf-cache-$$/${repo}"
  local listing_file="${cache_dir}/.listing"

  if [ ! -d "$cache_dir" ]; then
    mkdir -p "$cache_dir"
    listing="$(gh api "repos/${repo}/contents/.github/workflows" --jq '.[].name' 2>&1)" || {
      if [[ "$listing" == *404* ]]; then
        touch "$listing_file"
        return 0
      fi
      echo "Error listing workflows for ${repo}: ${listing}" >&2
      rm -rf "$cache_dir"
      return 1
    }
    listing="${listing//$'\r'/}"
    printf '%s\n' "$listing" > "$listing_file"

    while IFS= read -r wf || [ -n "$wf" ]; do
      [ -z "$wf" ] && continue
      case "$wf" in *.yml | *.yaml) ;; *) continue ;; esac
      response="$(gh api "repos/${repo}/contents/.github/workflows/${wf}" 2>&1)" || {
        if [[ "$response" == *404* ]]; then
          continue
        fi
        echo "Error fetching ${repo}/.github/workflows/${wf}: ${response}" >&2
        rm -rf "$cache_dir"
        return 1
      }
      # Decode the stub content — FAIL-CLOSED. A workflow stub always carries content,
      # so empty `.content` (the contents-API >1MB case returns content:"", encoding:none)
      # or a base64 failure means we did NOT actually read the stub. Abort rather than
      # cache an empty file and silently skip it — otherwise --retire-bare could delete
      # bare tags for a consumer whose stubs were never verified (the #657 breakage class
      # this guard exists to prevent). Mirrors the non-404 error handling above.
      b64="$(jq -r '.content // empty' <<< "$response")"
      if [ -z "$b64" ]; then
        echo "Error: empty/oversized content for ${repo}/.github/workflows/${wf} (contents API >1MB?) — aborting (fail-closed)" >&2
        rm -rf "$cache_dir"; return 1
      fi
      if ! decoded="$(base64 -d <<< "$b64" 2>/dev/null)"; then
        echo "Error: base64 decode failed for ${repo}/.github/workflows/${wf} — aborting (fail-closed)" >&2
        rm -rf "$cache_dir"; return 1
      fi
      printf '%s' "$decoded" > "${cache_dir}/${wf}"
    done < "$listing_file"
  fi

  [ -f "$listing_file" ] || return 0
  while IFS= read -r wf || [ -n "$wf" ]; do
    [ -z "$wf" ] && continue
    case "$wf" in *.yml | *.yaml) ;; *) continue ;; esac
    local cached_file="${cache_dir}/${wf}"
    [ -f "$cached_file" ] || continue
    content="$(cat "$cached_file")"
    [[ "$content" == *"${reusable}@"* ]] || continue
    # Both refs the stub carries, @-stripped: the `uses:` pin AND the `agent_ref:` input
    # (see #715 note above). `|| true` on each grep so a stub with a `uses:` pin but no
    # `agent_ref:` (the common case) does NOT fail-close under `set -o pipefail`.
    uses_refs="$(grep -oE "@${agent}/[^[:space:]\"']+" "$cached_file" | sed 's/^@//' || true)"
    agentref_refs="$(grep -oE "agent_ref: *${agent}/[^[:space:]\"']+" "$cached_file" | sed -E 's/^agent_ref: *//' || true)"
    while IFS= read -r r; do
      [ -z "$r" ] && continue
      printf '%s\t%s\n' "$wf" "$r"
    done < <(printf '%s\n%s\n' "$uses_refs" "$agentref_refs" | grep -v '^[[:space:]]*$' | sort -u)
  done < "$listing_file"
}

# _is_bare_tier_ref <agent> <ref> -> 0 if <ref> is a bare `<agent>/<tier>` pin
# (i.e. carries no `v<M>-` major scope).
_is_bare_tier_ref() {
  local agent="$1" ref="$2" tier
  while IFS= read -r tier; do
    [ "$ref" = "${agent}/${tier}" ] && return 0
  done < <(_agent_tiers "$agent")
  return 1
}

# ── operations ────────────────────────────────────────────────────────────────

# create_vtags <agent>: cut <agent>/v<M>-<tier> at the bare tier tag's commit for
# every ring tier, idempotent.
create_vtags() {
  local agent="$1" host major tier bare vtag commit
  host="$(_agent_host "$agent")"
  [[ -z "$host" ]] && { log "skip $agent — host not found"; return 0; }
  major="$(ring_host_current_major "$host" "$agent")"
  if [ -z "$major" ]; then
    log "skip $agent — no release major (nothing to major-scope)"
    return 0
  fi
  log "$agent — major line v${major} (host $host)"
  while IFS= read -r tier; do
    [ -z "$tier" ] && continue
    bare="${agent}/${tier}"
    vtag="${agent}/v${major}-${tier}"
    if _tag_exists "$host" "$vtag"; then
      log "skip ${vtag} — already exists"
      continue
    fi
    commit="$(_tag_commit "$host" "$bare")"
    if [ -z "$commit" ]; then
      log "skip ${vtag} — bare tag ${bare} not found"
      continue
    fi
    if [ "$DRY_RUN" = "true" ]; then
      log "would create ${vtag} at ${commit} (same commit as ${bare})"
    else
      _create_tag_ref "$host" "$vtag" "$commit"
      log "created ${vtag} at ${commit} (same commit as ${bare})"
    fi
  done < <(_agent_tiers "$agent")
}

# emit_repins <agent>: list every enrolled-consumer stub still on a bare tier and
# the v-form it should move to, naming the specific workflow file. Read only.
emit_repins() {
  local agent="$1" host major c stubs wf ref tier
  trap 'rm -rf "/tmp/migrate-wf-cache-$$"' EXIT
  host="$(_agent_host "$agent")"
  major="$(ring_host_current_major "$host" "$agent")"
  if [ -z "$major" ]; then
    log "skip $agent — no release major"
    return 0
  fi
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    if ! stubs="$(_consumer_agent_stubs "$c" "$agent")"; then
      err "could not read ${c} workflow stubs — aborting (fail-closed)"
      return 1
    fi
    [ -z "$stubs" ] && continue
    stubs="${stubs//$'\r'/}"
    while IFS=$'\t' read -r wf ref || [ -n "$wf" ]; do
      tier=""
      [ -z "$ref" ] && continue
      if _is_bare_tier_ref "$agent" "$ref"; then
        tier="${ref##*/}"
        log "repin ${c}/${wf}: ${ref} -> ${agent}/v${major}-${tier}"
      fi
    done <<< "$stubs"
  done < <(_enrolled_consumers "$agent")
}

# retire_bare <agent>: delete the bare tier tags, but only once no enrolled
# consumer still pins a bare tier. Refuses (non-zero) otherwise.
retire_bare() {
  local agent="$1" host c stubs wf ref tier
  trap 'rm -rf "/tmp/migrate-wf-cache-$$"' EXIT
  host="$(_agent_host "$agent")"
  [[ -z "$host" ]] && { err "unknown agent: $agent"; return 1; }
  local -a offenders=()
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    if ! stubs="$(_consumer_agent_stubs "$c" "$agent")"; then
      err "could not read ${c} workflow stubs — aborting (fail-closed)"
      return 1
    fi
    [ -z "$stubs" ] && continue
    stubs="${stubs//$'\r'/}"
    while IFS=$'\t' read -r wf ref || [ -n "$wf" ]; do
      [ -z "$ref" ] && continue
      if _is_bare_tier_ref "$agent" "$ref"; then
        offenders+=("${c}/${wf} (${ref})")
      fi
    done <<< "$stubs"
  done < <(_enrolled_consumers "$agent")

  if [ "${#offenders[@]}" -gt 0 ]; then
    err "refuse to retire bare ${agent} tiers — still pinned by an enrolled consumer:"
    printf '[migrate]   - %s\n' "${offenders[@]}" >&2
    return 1
  fi

  while IFS= read -r tier; do
    [ -z "$tier" ] && continue
    if [ "$DRY_RUN" = "true" ]; then
      log "would delete ${agent}/${tier}"
    else
      _delete_tag_ref "$host" "${agent}/${tier}"
      log "deleted ${agent}/${tier}"
    fi
  done < <(_agent_tiers "$agent")
}

# ── entrypoint ────────────────────────────────────────────────────────────────

main() {
  local mode="create" agent_filter="" retire_agent=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)     DRY_RUN=true; shift ;;
      --agent)
        if [[ $# -lt 2 ]]; then
          err "--agent requires an argument"
          exit 1
        fi
        agent_filter="$2"; shift 2 ;;
      --emit-repins) mode="emit-repins"; shift ;;
      --retire-bare)
        if [[ $# -lt 2 ]]; then
          err "--retire-bare requires an argument"
          exit 1
        fi
        mode="retire-bare"; retire_agent="$2"; shift 2 ;;
      -h|--help)     sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) err "Unknown option: $1"; exit 1 ;;
    esac
  done

  [ "$DRY_RUN" = "true" ] && log "DRY RUN — no tags will be created or deleted"

  if [ ! -f "$CANARY_RINGS" ]; then
    err "canary-rings registry not found: $CANARY_RINGS"
    exit 1
  fi

  case "$mode" in
    retire-bare)
      retire_bare "$retire_agent"
      ;;
    emit-repins)
      if [ -n "$agent_filter" ]; then
        emit_repins "$agent_filter"
      else
        while IFS= read -r a; do emit_repins "$a"; done < <(_agent_names)
      fi
      ;;
    create)
      if [ -n "$agent_filter" ]; then
        create_vtags "$agent_filter"
      else
        while IFS= read -r a; do create_vtags "$a"; done < <(_agent_names)
      fi
      ;;
  esac
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
