#!/usr/bin/env bash
set -euo pipefail
# apply-rulesets.sh — codified, idempotent application of the org compliance rulesets.
#
# CANONICAL org tooling (petry-projects/.github#580 / #575). Reads the codified source
# of truth in standards/rulesets/*.json (code-quality.json, pr-quality.json) and
# creates/updates the named ruleset on the target repo(s). Re-running converges to the
# file's desired state (a no-op when already in sync).
#
# This REPLACES the retired detection-based builder, which dynamically probed each
# repo's workflow files and *generated* the ruleset in-code. That approach DIVERGED
# from the codified set — e.g. it injected `Dev-Lead Agent / dev-lead` as a required
# context, which standards/github-settings.md#code-quality deliberately excludes
# (per-PR review, not a merge gate). The codified JSON is now the single source of
# truth; there is no in-code generation.
#
# Detection items → codified mapping (nothing org-wide is lost by the retirement):
#   SonarCloud, CodeQL, agent-shield/AgentShield, dependency-audit/Detect ecosystems
#     → carried statically in standards/rulesets/code-quality.json.
#   Dev-Lead Agent → intentionally NOT required (the divergence this retires).
#   CI Pipeline (build-and-test) → repo-specific job name → required per-repo via
#     branch protection, not a fixed org context (see github-settings.md §code-quality).
#   Secret scan (gitleaks) + coverage → produced by the template ci.yml; added to the
#     ruleset fleet-wide only after the coverage backfill (#581), not here.
#
# Rulesets live ON each repo: editing a JSON here changes the desired state, not any
# live ruleset, until this applier runs.
#
# Default set: with NO ruleset name, only the FLEET_RULESETS allowlist (code-quality,
# pr-quality) is applied — NOT every *.json in the dir. standards/rulesets/ also holds
# release-channel-tags.json (a tag ruleset protecting the reusable-hosting meta-repos'
# channel/version tags); it is targeted, not fleet-wide, so it is applied ONLY when
# named explicitly:  ./scripts/apply-rulesets.sh --repo petry-projects/.github release-channel-tags
#
# Usage:
#   GH_TOKEN=<admin> ./scripts/apply-rulesets.sh --repo owner/repo [--dry-run] [<name>...]
#   GH_TOKEN=<admin> ./scripts/apply-rulesets.sh <repo-name>       [--dry-run]   # bare name → $ORG/<name>
#   GH_TOKEN=<admin> ./scripts/apply-rulesets.sh --all             [--dry-run]   # every non-archived org repo
#
# Env:
#   GH_TOKEN       token with administration:write on the target repo(s) (required for writes)
#   ORG            org for --all and bare repo names (default: petry-projects)
#   RULESETS_DIR   directory of ruleset JSONs (default: <repo-root>/standards/rulesets)
#   DRY_RUN        "true" → print intent, make no write calls

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ORG="${ORG:-petry-projects}"
RULESETS_DIR="${RULESETS_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)/standards/rulesets}"
DRY_RUN="${DRY_RUN:-false}"

# The fleet-wide compliance rulesets applied by DEFAULT (when no ruleset name is
# given), on --repo and --all alike. This is an ALLOWLIST, not "every *.json in the
# dir": standards/rulesets/ also holds release-channel-tags.json, which is a targeted
# tag ruleset for the reusable-hosting meta-repos only and must NOT be swept fleet-
# wide — it is applied only when named explicitly (e.g. `--repo <meta> release-channel-tags`).
readonly FLEET_RULESETS=(code-quality pr-quality)

# ruleset_id_by_name <repo> <name> — echo the id of an existing ruleset, or empty.
ruleset_id_by_name() {
  local repo="$1" name="$2"
  local output rc=0
  output=$(gh api --paginate "repos/${repo}/rulesets" 2>/dev/null) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "::error::failed to fetch rulesets for ${repo} (exit code ${rc})" >&2
    return "$rc"
  fi
  echo "$output" | jq -r --arg n "$name" 'if type=="array" then .[] else . end | select(.name==$n) | .id'
}

# apply_one <repo> <json_file> — create or update the ruleset described by json_file.
apply_one() {
  local repo="$1" file="$2"
  local name id id_rc=0
  name="$(jq -r '.name' "$file")"
  [ -n "$name" ] && [ "$name" != "null" ] || { echo "::error::$file has no .name" >&2; return 1; }
  id="$(ruleset_id_by_name "$repo" "$name")" && id_rc=0 || id_rc=$?
  if [ "$id_rc" -ne 0 ]; then
    echo "::error::failed to resolve ruleset ID for '${name}' on ${repo}" >&2
    return "$id_rc"
  fi

  if [ -n "$id" ]; then
    echo "  update ruleset '${name}' (id ${id}) on ${repo}"
    if [ "$DRY_RUN" = "true" ]; then echo "    [dry-run] PUT repos/${repo}/rulesets/${id}"; return 0; fi
    gh api --method PUT "repos/${repo}/rulesets/${id}" --input "$file" >/dev/null || {
      echo "::error::failed to update ruleset '${name}' on ${repo}" >&2
      return 1
    }
  else
    echo "  create ruleset '${name}' on ${repo}"
    if [ "$DRY_RUN" = "true" ]; then echo "    [dry-run] POST repos/${repo}/rulesets"; return 0; fi
    gh api --method POST "repos/${repo}/rulesets" --input "$file" >/dev/null || {
      echo "::error::failed to create ruleset '${name}' on ${repo}" >&2
      return 1
    }
  fi
  return 0
}

# apply_repo <repo> <file...> — apply each ruleset file to one repo.
apply_repo() {
  local repo="$1"; shift
  echo "[apply-rulesets] repo=${repo} dir=${RULESETS_DIR} dry_run=${DRY_RUN}"
  local file rc=0
  for file in "$@"; do
    apply_one "$repo" "$file" || rc=$?
  done
  return "$rc"
}

# resolve_repo <arg> — echo owner/repo: pass through an owner/repo, else prefix $ORG.
resolve_repo() {
  case "$1" in */*) printf '%s' "$1" ;; *) printf '%s/%s' "$ORG" "$1" ;; esac
}

main() {
  local target="" all=false
  local names=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)
        [ "$#" -ge 2 ] || { echo "::error::--repo requires a value" >&2; return 2; }
        target="$2"; shift 2 ;;
      --all)     all=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      --*)       echo "::error::unknown flag: $1" >&2; return 2 ;;
      *)
        # A bare token is the target repo (back-compat with the retired applier's
        # positional <repo-name>) unless --repo/--all already set it, in which case
        # remaining bare tokens filter which ruleset names to apply.
        if [ -z "$target" ] && [ "$all" = false ]; then target="$1"; else names+=("$1"); fi
        shift ;;
    esac
  done

  gh auth status >/dev/null 2>&1 || { echo "::error::GitHub authentication failed — set GH_TOKEN or run 'gh auth login'" >&2; return 1; }
  [ -d "$RULESETS_DIR" ] || { echo "::error::rulesets dir not found: $RULESETS_DIR" >&2; return 1; }

  # Select the ruleset files: the named ones, else the fleet allowlist (NOT every
  # *.json — that would sweep release-channel-tags fleet-wide; see FLEET_RULESETS).
  local files=()
  if [ "${#names[@]}" -eq 0 ]; then names=("${FLEET_RULESETS[@]}"); fi
  local n
  for n in "${names[@]}"; do
    [ -f "${RULESETS_DIR}/${n}.json" ] && files+=("${RULESETS_DIR}/${n}.json") \
      || { echo "::error::no ruleset file ${n}.json in ${RULESETS_DIR}" >&2; return 1; }
  done
  [ "${#files[@]}" -gt 0 ] || { echo "  no ruleset files to apply"; return 0; }

  if [ "$all" = true ]; then
    [ -z "$target" ] || { echo "::error::--all and a repo argument are mutually exclusive" >&2; return 2; }
    echo "[apply-rulesets] fetching non-archived repos in ${ORG} ..."
    local repos repo failed=0 repos_rc=0
    repos="$(gh repo list "$ORG" --no-archived --json name -q '.[].name' --limit 500)" && repos_rc=0 || repos_rc=$?
    if [ "$repos_rc" -ne 0 ]; then
      echo "::error::failed to list repositories for organization ${ORG} (exit code ${repos_rc})" >&2
      return "$repos_rc"
    fi
    [ -n "$repos" ] || { echo "::error::no repositories found in ${ORG} — check GH_TOKEN" >&2; return 1; }
    for repo in $repos; do
      apply_repo "${ORG}/${repo}" "${files[@]}" || { failed=$((failed + 1)); echo "::warning::failed on ${ORG}/${repo}"; }
    done
    [ "$failed" -eq 0 ] || { echo "::error::${failed} repo(s) failed" >&2; return 1; }
    echo "[apply-rulesets] done (${#files[@]} ruleset(s) across the fleet)"
    return 0
  fi

  [ -n "$target" ] || { echo "::error::usage: $0 --repo owner/repo | <repo-name> | --all  [--dry-run] [<name>...]" >&2; return 2; }
  apply_repo "$(resolve_repo "$target")" "${files[@]}"
  echo "[apply-rulesets] done (${#files[@]} ruleset(s))"
}

# Source-guard: tests source this to exercise ruleset_id_by_name / apply_one.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
