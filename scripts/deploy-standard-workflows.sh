#!/usr/bin/env bash
# deploy-standard-workflows.sh — Deploy org-standard workflow stubs to all repos.
#
# Reads canonical stubs from standards/workflows/ and deploys them into every
# repo in the petry-projects org by opening a pull request per repo (via the
# shared scripts/lib/standards-deploy.sh primitive). Only workflows that have a
# template in standards/workflows/ AND appear in the DEPLOYABLE_WORKFLOWS list
# below are eligible — tech-stack-specific workflows (ci.yml, sonarcloud.yml)
# must be set up manually.
#
# Deployment is PR-based, never a direct push to the default branch: a direct
# Contents-API push is rejected (HTTP 409) on repos whose ruleset enforces
# required status checks, and bypasses review/CI on the repos where it would
# succeed. Opening a PR works uniformly on protected and unprotected repos and
# leaves an auditable, CI-gated record. The PRs are labeled `standards-sync` and
# left for the normal review/auto-merge pipeline — this script never merges and
# never uses --admin. See petry-projects/.github#478.
#
# Usage:
#   deploy-standard-workflows.sh [options]
#
# Options:
#   --dry-run              Print planned actions without opening any PRs.
#   --workflow <name.yml>  Deploy only this workflow (default: all deployable).
#   --repo <name>          Target a single repo instead of all org repos.
#   --force                Re-deploy even if the file looks correct (re-syncs).
#
# Requirements:
#   GH_TOKEN (or gh auth login) with repo scope (branch + PR creation).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/standards-deploy.sh
source "$SCRIPT_DIR/lib/standards-deploy.sh"
# Canary-ring pin model — shared with compliance-audit.sh so this sweep's notion
# of "drift" matches the audit's "non-compliant" and never reverts a repo's
# intentional ring/next pin back to the template's stable channel (#482).
# shellcheck source=scripts/lib/ring-pins.sh
source "$SCRIPT_DIR/lib/ring-pins.sh"

# Global temp-file registry — cleaned up by EXIT trap even on premature exit.
declare -a _TMPFILES=()
trap 'rm -f "${_TMPFILES[@]+"${_TMPFILES[@]}"}"' EXIT

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ORG="petry-projects"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STANDARDS_DIR="$REPO_ROOT/standards/workflows"

# Branch prefix + label for the PRs this script opens.
SYNC_BRANCH_PREFIX="standards-sync"
SYNC_LABEL="standards-sync"

# Repos exempt from blanket standard-workflow deployment.
#   .github         — self-host source of truth; its own callers use local refs
#                     (e.g. add-to-project.yml pins ./.github/...), which a
#                     channel-pinned stub must never overwrite.
#   .github-private — self-manages its workflow fleet (dev-lead runs inline, etc).
# A repo here may still opt into a *specific* workflow via SKIP_OVERRIDES below.
SKIP_REPOS=(".github" ".github-private")

# Per-workflow opt-ins for otherwise-skipped repos. Keyed by workflow filename;
# value is a space-separated list of SKIP_REPOS that should still receive it.
# .github-private participates in the org Initiatives board, so it receives the
# add-to-project.yml caller (the org board is a single shared target — the stub
# is identical for every repo) while staying exempt from all other stubs.
#
# pr-auto-review.yml (#847): #844 made feature-ideation / pr-auto-review /
# initiative-driver universally required. The sweep landed them fleet-wide except
# on .github-private, which — as a SKIP_REPO — was exempted, leaving it missing
# pr-auto-review while the audit now flags it non-compliant. Opting it in here
# lets the sweep deploy the stub at .github-private's COMPUTED canary tier
# (`next`, via emit_ref_for) rather than a hand-pinned wrong tier — the other two
# are already present (feature-ideation re-pinned in place as a channel consumer,
# initiative-driver a verbatim self-managed stub), so only pr-auto-review opts in.
declare -A SKIP_OVERRIDES=(
  ["add-to-project.yml"]=".github-private"
  ["pr-auto-review.yml"]=".github-private"
)

# Required workflows a SKIP_REPO satisfies by SELF-MANAGING the file in its own
# tree (present verbatim / re-pinned in place as a channel consumer), rather than
# by opting into the blanket sweep via SKIP_OVERRIDES. Keyed by repo; value is a
# space-separated list of workflow filenames.
#
# #856 codifies why this declaration exists. The compliance audit requires every
# universal-required workflow (#844) on EVERY repo — including the SKIP_REPOS the
# sweep otherwise exempts. So for each SKIP_REPO, every workflow that is both
# universal-required AND deployable must be reconciled EITHER by a SKIP_OVERRIDES
# opt-in (sweep deploys it) OR by a SKIP_SELF_MANAGED entry here (the repo hosts
# it itself). A required+deployable workflow with neither is drift: the sweep
# skips it and the audit flags it required-but-missing forever — the exact gap
# #847 hit ad-hoc for .github-private / pr-auto-review. reconcile_skip_repo_required_workflows
# (bats-covered) fails if any such gap exists, keeping audit and deploy config in
# lockstep.
#
#   .github         self-hosts the full standard fleet (this repo is the source of
#                   truth; its callers use local ./ refs), so it self-manages ALL
#                   required+deployable workflows.
#   .github-private self-manages its fleet except pr-auto-review.yml, which it now
#                   receives via the SKIP_OVERRIDES opt-in above (#847).
declare -A SKIP_SELF_MANAGED=(
  [".github"]="dev-lead.yml dependabot-automerge.yml dependency-audit.yml agent-shield.yml pr-review-mention.yml feature-ideation.yml pr-auto-review.yml initiative-driver.yml"
  [".github-private"]="dev-lead.yml dependabot-automerge.yml dependency-audit.yml agent-shield.yml pr-review-mention.yml feature-ideation.yml initiative-driver.yml"
)

# Workflows deployable from standards/workflows/<name>.
# Excludes only ci.yml and sonarcloud.yml (tech-stack-specific — set up manually).
# Most deploy verbatim (thin caller stubs, identical fleet-wide). feature-ideation
# is the exception: it carries a per-repo `project_context` edit, so it deploys
# SEED-IF-ABSENT and otherwise re-pins its OWN body in place — never overwriting
# the tuned body from the template. See BODY_PRESERVING_WORKFLOWS below.
DEPLOYABLE_WORKFLOWS=(
  pr-review-mention.yml
  persona-mention.yml
  dev-lead.yml
  agent-shield.yml
  auto-rebase.yml
  dependabot-automerge.yml
  dependabot-rebase.yml
  dependency-audit.yml
  add-to-project.yml
  initiative-driver.yml
  pr-auto-review.yml
  feature-ideation.yml
)

# Deployable workflows whose stub BODY carries a documented per-repo edit the
# sweep must never clobber. feature-ideation's `project_context` (its only
# required per-repo customisation) is such an edit: re-syncing the body from the
# template would revert every repo's tuned context to the template default on
# every sweep — the config-loss footgun that forced #813's manual per-repo adds.
# A workflow listed here deploys SEED-IF-ABSENT: seeded from the template only
# when the stub is missing, and otherwise re-pinned in place from its OWN body
# (preserving project_context). Non-listed workflows keep the verbatim-overwrite
# re-sync (correct where the body is identical fleet-wide).
readonly BODY_PRESERVING_WORKFLOWS=(
  feature-ideation.yml
)

# is_body_preserving_workflow <name.yml> -> 0 if the workflow's body must be
# preserved on re-deploy (seed-if-absent + re-pin-in-place).
is_body_preserving_workflow() {
  local w="$1" p
  for p in "${BODY_PRESERVING_WORKFLOWS[@]}"; do
    [[ "$w" == "$p" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DRY_RUN=false
TARGET_WORKFLOW=""
TARGET_REPO=""
FORCE=false

# parse_args populates the DRY_RUN/TARGET_*/FORCE globals from the CLI. Called by
# main() (not at top level) so sourcing the script for tests defines functions
# without treating the sourcing harness's args as deploy options.
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)   DRY_RUN=true; shift ;;
      --force)     FORCE=true;   shift ;;
      --workflow)  TARGET_WORKFLOW="$2"; shift 2 ;;
      --repo)      TARGET_REPO="$2";     shift 2 ;;
      -h|--help)
        sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[deploy] $*"; }
skip() { echo "[deploy] SKIP  $*"; }
dry()  { echo "[deploy] DRY   $*"; }
ok()   { echo "[deploy] OK    $*"; }
err()  { echo "[deploy] ERROR $*" >&2; }

is_skipped_repo() {
  local repo="$1" s
  for s in "${SKIP_REPOS[@]}"; do
    [[ "$repo" == "$s" ]] && return 0
  done
  return 1
}

# True if a normally-skipped repo has opted into this specific workflow via
# SKIP_OVERRIDES — lets a self-managed repo receive one stub while staying
# exempt from the rest.
repo_opts_into() {
  local repo="$1" workflow="$2"
  local opt_in="${SKIP_OVERRIDES[$workflow]:-}"
  [[ -z "$opt_in" ]] && return 1

  # Split the space-separated opt-in list into an array (read -r -a avoids the
  # pathname expansion an unquoted expansion would be subject to).
  local -a allowed_repos
  read -r -a allowed_repos <<< "$opt_in"
  local r
  for r in "${allowed_repos[@]}"; do
    [[ "$repo" == "$r" ]] && return 0
  done
  return 1
}

# True if <name.yml> is one of the workflows the sweep is responsible for
# deploying (DEPLOYABLE_WORKFLOWS). ci.yml / sonarcloud.yml are required org-wide
# but set up manually per tech stack, so the sweep never owns them.
is_deployable_workflow() {
  local w="$1" d
  for d in "${DEPLOYABLE_WORKFLOWS[@]}"; do
    [[ "$w" == "$d" ]] && return 0
  done
  return 1
}

# True if a SKIP_REPO satisfies <workflow> by self-managing it (declared in
# SKIP_SELF_MANAGED) rather than via a SKIP_OVERRIDES opt-in.
skip_repo_self_manages() {
  local repo="$1" workflow="$2"
  local managed="${SKIP_SELF_MANAGED[$repo]:-}"
  [[ -z "$managed" ]] && return 1

  local -a arr
  read -r -a arr <<< "$managed"
  local m
  for m in "${arr[@]}"; do
    [[ "$workflow" == "$m" ]] && return 0
  done
  return 1
}

# reconcile_skip_repo_required_workflows <required_wf...> — consistency guard
# (#856). Given the audit's REQUIRED_WORKFLOWS, print one line ("<repo> <wf>") per
# UNRECONCILED pair: a workflow that is both universal-required AND deployable,
# targeted at a SKIP_REPO, with NO reconciliation path — neither a SKIP_OVERRIDES
# opt-in nor a SKIP_SELF_MANAGED declaration. Returns 0 (no output) when the
# deploy config fully accounts for every required+deployable workflow on every
# SKIP_REPO; non-zero (listing the gaps) otherwise. Pure — no I/O beyond stdout.
reconcile_skip_repo_required_workflows() {
  local -a required=("$@")
  local gaps=0 repo wf
  for repo in "${SKIP_REPOS[@]}"; do
    for wf in "${required[@]}"; do
      is_deployable_workflow "$wf" || continue
      repo_opts_into "$repo" "$wf" && continue
      skip_repo_self_manages "$repo" "$wf" && continue
      echo "$repo $wf"
      gaps=$((gaps + 1))
    done
  done
  [[ "$gaps" -eq 0 ]]
}

# Fetch a file from the repo API in one call; outputs "sha<TAB>decoded-content".
# Returns empty string on 404.
fetch_existing() {
  local repo="$1" path="$2"
  local raw
  raw=$(gh api "repos/$ORG/$repo/contents/$path" 2>/dev/null) || { echo ""; return; }
  local sha encoded decoded
  sha=$(echo "$raw" | jq -r '.sha // empty')
  encoded=$(echo "$raw" | jq -r '.content // empty')
  decoded=$(echo "$encoded" | base64 -d 2>/dev/null || echo "")
  printf '%s\t%s' "$sha" "$decoded"
}

# template_requires_s7635_marker <template> -> 0 if the template carries a REAL
# `secrets: inherit` YAML line (indented key, not a `#`-comment/prose mention). Such
# stubs hand the reusable every org secret and must carry the inline
# `# NOSONAR(githubactions:S7635)` marker, else SonarCloud re-flags any consumer that
# copied the marker-less stub (#875/#876). Anchors `secrets:` to start-of-line-after-
# indent — mirrors the s7635-secrets-inherit.bats template guard.
template_requires_s7635_marker() {
  grep -qE '^[[:space:]]*secrets:[[:space:]]+inherit([[:space:]]|$)' "$1"
}

# stub_has_s7635_marker — 0 if the stub content on stdin carries the
# `# NOSONAR(githubactions:S7635)` marker on a real `secrets: inherit` line.
stub_has_s7635_marker() {
  grep -qE '^[[:space:]]*secrets:[[:space:]]+inherit[[:space:]].*NOSONAR\(githubactions:S7635\)'
}

# is_already_compliant <existing_content> <template> <repo> -> 0 if the deployed
# stub needs no re-deploy. A stub is compliant only when it is BOTH pin-compliant
# (is_pin_compliant, below) AND — when its template carries a real `secrets: inherit`
# line — still carries the S7635 NOSONAR marker on that line. A pin-correct stub that
# dropped the marker is DRIFT (#877): #875/#876 restored the marker in the templates
# but not the driver, so a re-sweep skipped already-pinned consumers (broodminder-
# export, bmad-bgreat-suite, …) whose stubs merged marker-less during #857. Flagging
# the missing marker as drift re-deploys and restores it. Kept targeted (pin + marker
# presence), NOT a byte-compare, to avoid churn on cosmetic diffs.
is_already_compliant() {
  local existing_content="$1" template="$2" repo="$3"
  is_pin_compliant "$existing_content" "$template" "$repo" || return 1
  if template_requires_s7635_marker "$template" \
     && ! stub_has_s7635_marker <<< "$existing_content"; then
    return 1
  fi
  return 0
}

# True if the existing decoded content already has the canonical uses: reference
# for this workflow (extracted from the template itself, so it tracks version bumps).
#
# Ring-aware (#482): templates pin a moving channel tag `<base>/stable`, but a
# repo on a non-stable ring tier legitimately pins `<base>/<tier>` (e.g.
# `<base>/ring1`). For those reusables the stub is compliant when it pins ANY ref
# the shared ring model accepts for THIS repo (its tier channel + the transitional
# legacy grace) — so the sweep never reverts an intentional ring/next pin. A non-ring
# template — one whose reusable is not registered in canary-rings.json, hence absent
# from RING_REUSABLES — keeps the exact-match rule.
is_pin_compliant() {
  local existing_content="$1" template="$2" repo="$3"
  local expected_uses
  expected_uses=$(grep -E '^[[:space:]]*uses:' "$template" | head -1 | sed 's/^[[:space:]]*uses:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | tr -d '\r' || true)
  # Verbatim-managed template (no reusable uses: line — e.g. initiative-driver which
  # dispatches directly via gh CLI). Compare full content (CRLF-normalized) so a
  # correctly-deployed stub is never flagged as drifted on every sweep.
  if [[ -z "$expected_uses" ]]; then
    local template_content normalized_existing
    template_content=$(tr -d '\r' < "$template")
    normalized_existing=$(printf '%s' "$existing_content" | tr -d '\r')
    [[ "$normalized_existing" == "$template_content" ]] && return 0 || return 1
  fi

  local prefix="${expected_uses%@*}" ref_after="${expected_uses##*@}" base
  if [[ "$prefix" =~ /([a-z0-9-]+)-reusable\.yml$ ]]; then
    base="${BASH_REMATCH[1]}"
    # Only treat it as ring-managed if the reusable is on the ring model AND the
    # template pins a channel tag (not a frozen @vX / SHA). The template ref may be
    # the bare `<base>/<tier>` OR the major-scoped `<base>/v<M>-<tier>` form (#657
    # F5) — post-migration the templates pin the v-form, so both must enter here.
    if ring_is_ring_reusable "$base" && [[ "$ref_after" =~ ^${base}/(v[0-9]+-)?(stable|next|ring[0-9]+)$ ]]; then
      # Major-scoped channels (#657 F5, #861, #870): the bare-tier grace is now
      # major-AWARE, keyed on the CHANNEL major (the highest `<base>/v<M>-<tier>`
      # channel tag that exists) — NOT the release major. A bare `<base>/<tier>`
      # stub stays compliant only while the agent has NO channel tag (nothing to
      # major-scope onto yet). Once a channel tag exists, a bare stub is drift and
      # must migrate to the tier's `v<M>-<tier>` form. Using the channel major (not
      # the release major) is what keeps dev-lead — release v14, channel v1 — pinned
      # to the tag that actually resolves (@dev-lead/v1-<tier>, not @dev-lead/v14-…).
      local host major
      host="$(cut -d/ -f1-2 <<< "$prefix")"
      major="$(ring_host_current_channel_major "$host" "$base")" || return 1
      if [[ -z "$major" ]]; then
        local ref
        while IFS= read -r ref; do
          [[ -n "$ref" ]] && grep -qF "${prefix}@${ref}" <<< "$existing_content" && return 0
        done < <(ring_accepted_refs "$base" "$repo")
      fi
      # A stub already pinned to the repo's tier-correct `v<M>-<tier>` form (any
      # major) is compliant regardless of release state. A WRONG-tier v-form — or a
      # bare stub once the agent has a release — is not accepted here and stays drift.
      local existing_ref
      existing_ref=$(grep -oE "@${base}/[^[:space:]\"']+" <<< "$existing_content" | head -1)
      existing_ref="${existing_ref#@}"
      if [[ -n "$existing_ref" ]] && ring_vform_tier_aligned "$existing_ref" "$base" "$repo"; then
        return 0
      fi
      return 1
    fi
  fi

  grep -qF "$expected_uses" <<< "$existing_content" && return 0 || return 1
}

# reusable_uses_of <template> -> the template's first reusable `uses:` value
# (org/repo/…/<base>-reusable.yml@<ref>), comment/CR stripped, or empty.
reusable_uses_of() {
  grep -E '^[[:space:]]*uses:' "$1" | head -1 \
    | sed 's/^[[:space:]]*uses:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | tr -d '\r' || true
}

# reusable_base_of <template> -> the ring channel base (e.g. `auto-rebase`) of the
# template's reusable, or empty if the template does not call a `-reusable.yml`.
reusable_base_of() {
  local prefix; prefix="$(reusable_uses_of "$1")"; prefix="${prefix%@*}"
  [[ "$prefix" =~ /([a-z0-9-]+)-reusable\.yml$ ]] && printf '%s' "${BASH_REMATCH[1]}"
  return 0
}

# reusable_host_of <template> -> the org/repo that HOSTS the reusable (and thus
# carries its release tags), e.g. `petry-projects/.github-private` for dev-lead.
reusable_host_of() {
  local prefix; prefix="$(reusable_uses_of "$1")"; prefix="${prefix%@*}"
  cut -d/ -f1-2 <<< "$prefix"
  return 0
}

# emit_ref_for <template> <repo> -> the channel ref a (re)deployed stub in <repo>
# should pin (#657 F5). For a ring-managed reusable it is the repo's tier channel,
# major-scoped `v<M>-<tier>` when the agent has a CHANNEL tag, else the bare `<tier>`
# form. The major is the CHANNEL major (highest existing `<base>/v<M>-<tier>` tag),
# NOT the release major — so dev-lead (release v14, channel v1) pins the resolving
# `@dev-lead/v1-<tier>`, never the tagless `@dev-lead/v14-<tier>` (#870). Empty for
# a non-ring template (deployed verbatim). Requires GH_TOKEN.
emit_ref_for() {
  local template="$1" repo="$2" base host major
  base="$(reusable_base_of "$template")"
  [[ -z "$base" ]] && return 0
  ring_is_ring_reusable "$base" || return 0
  host="$(reusable_host_of "$template")"
  if ! major="$(ring_host_current_channel_major "$host" "$base")"; then
    return 1
  fi
  ring_canonical_ref "$base" "$repo" "$major"
  return 0
}

# Build the PR body for a batched stub deployment (one PR per repo).
batch_pr_body() {
  local w lines=""
  for w in "$@"; do lines+="- \`${w}\`"$'\n'; done
  printf 'Syncs the following org-standard workflow stub(s) from `%s/.github` (`standards/workflows/`), deployed verbatim:\n\n%s\nOpened by `scripts/deploy-standard-workflows.sh`. Stubs are thin callers; all behaviour lives in the reusables. See `standards/ci-standards.md`. Labeled `%s` and left for the normal review/auto-merge pipeline — the deploy script never merges directly.\n' \
    "$ORG" "$lines" "$SYNC_LABEL"
}

# ---------------------------------------------------------------------------
# Deploy all drifted stubs for a single repo as ONE batched standards-sync PR.
# ---------------------------------------------------------------------------
deploy_repo() {
  local repo="$1"

  # NOTE: a skipped meta-repo (.github / .github-private) is NOT short-circuited
  # here — the per-workflow loop below fetches each stub to tell a self-host `./`
  # ref (stays exempt) from a channel-pinned consumer ref (re-pinned by the F5
  # sweep, #704). Each exempt workflow still logs its own `(exempt)` line.

  # Collect the drifted stubs for this repo (path/template pairs + names). For
  # ring-managed reusables the deployed template is REWRITTEN to pin the repo's
  # tier channel (major-scoped `v<M>-<tier>` when the agent has a release) — the
  # emit ref (#657 F5). Rewritten templates land in temp files cleaned up below.
  local -a paths=() templates=() names=() emits=() modes=()
  local workflow template target_path raw existing_sha existing_content emit deploy_template base repin_source mode
  for workflow in "${WORKFLOWS[@]}"; do
    base=""; repin_source=""; emit=""; deploy_template=""; mode=""
    template="$STANDARDS_DIR/$workflow"
    target_path=".github/workflows/$workflow"
    if [[ ! -f "$template" ]]; then
      err "No template at $template — skipping $workflow for $repo"
      continue
    fi
    raw=$(fetch_existing "$repo" "$target_path")
    existing_sha="${raw%%$'\t'*}"
    existing_content="${raw#*$'\t'}"

    # Meta-repo handling (#704). A skipped repo is exempt from blanket stub
    # deployment because it self-hosts most reusables via local `./` refs — a
    # channel-pinned template must never overwrite those. But a meta-repo also
    # CONSUMES the reusables it does not host (e.g. .github consumes dev-lead from
    # .github-private), and those channel-pinned consumer stubs must be re-pinned
    # by the F5 sweep or the major-scope migration skips them (freezing the inner
    # canary rings) and --retire-bare stays blocked. So process a skipped repo's
    # workflow only when its existing stub is a ring-managed channel CONSUMER; a
    # missing stub, a non-ring reusable, or a local `./` self-host ref stays exempt
    # (opt-ins via SKIP_OVERRIDES keep their verbatim-template path unchanged).
    repin_source="$template"
    if is_skipped_repo "$repo" && ! repo_opts_into "$repo" "$workflow"; then
      base="$(reusable_base_of "$template")"
      if [[ -z "$existing_sha" ]] || [[ -z "$base" ]] || ! ring_is_ring_reusable "$base" \
         || ring_stub_selfhosts "$base" <<< "$existing_content"; then
        skip "$repo/$workflow (exempt)"
        continue
      fi
      # A channel consumer stub: re-pin the meta-repo's OWN stub body in place —
      # never overwrite its bespoke content with the generic template.
      if [[ "$DRY_RUN" != "true" ]]; then
        repin_source="$(mktemp)"; _TMPFILES+=("$repin_source")
        printf '%s\n' "$existing_content" > "$repin_source"
      fi
    elif is_body_preserving_workflow "$workflow"; then
      # feature-ideation carries a per-repo project_context the sweep must never
      # clobber. Seed the generic template ONLY when the stub is absent; when it
      # already exists, re-pin its OWN body in place (preserving project_context)
      # — the same "re-pin OWN body" mechanism the meta-repo branch above uses,
      # extended to regular target repos.
      if [[ -z "$existing_sha" ]]; then
        mode="seed"
      else
        mode="repin-in-place"
        if [[ "$DRY_RUN" != "true" ]]; then
          repin_source="$(mktemp)"; _TMPFILES+=("$repin_source")
          printf '%s\n' "$existing_content" > "$repin_source"
        fi
      fi
    fi

    # When repin_source is a copy of existing_content (meta-repo consumer or body-
    # preserving repin-in-place) and the template requires the S7635 marker but the
    # copy lacks it, inject the marker now. Without this, the deployed stub would
    # still be marker-less after the PR lands and is_already_compliant would flag it
    # as drift again on every subsequent sweep — an infinite redeployment loop (#878).
    if [[ "$repin_source" != "$template" ]] && [[ "$DRY_RUN" != "true" ]]; then
      if template_requires_s7635_marker "$template" && ! stub_has_s7635_marker < "$repin_source"; then
        local patched; patched="$(mktemp)"; _TMPFILES+=("$patched")
        sed -E 's/^([[:space:]]*secrets:[[:space:]]+inherit)([[:space:]]*#.*)?$/\1  # NOSONAR(githubactions:S7635) first-party trusted reusable/' "$repin_source" > "$patched"
        repin_source="$patched"
      fi
    fi

    if [[ -n "$existing_sha" ]] && [[ "$FORCE" == "false" ]] && is_already_compliant "$existing_content" "$template" "$repo"; then
      skip "$repo/$target_path already compliant"
      continue
    fi
    if ! emit="$(emit_ref_for "$template" "$repo")"; then
      err "$repo/$workflow — channel-major probe failed; skipping"
      _OVERALL_FAILED=1
      continue
    fi
    # assert-exists (#870): never pin a stub to a channel ref that has no tag. A
    # computed `v<M>-<tier>` (or bare tier) that does not resolve on the host would
    # break the caller's workflow on the next run, so refuse it here rather than
    # open a PR carrying a non-resolving pin.
    if [[ -n "$emit" ]]; then
      local emit_host
      emit_host="$(reusable_host_of "$template")"
      if ! ring_tag_exists "$emit_host" "$emit"; then
        err "$repo/$workflow — computed channel ref @${emit} does not resolve to a tag on ${emit_host}; refusing to deploy a non-resolving pin"
        _OVERALL_FAILED=1
        continue
      fi
    fi
    deploy_template="$repin_source"
    if [[ -n "$emit" ]] && [[ "$DRY_RUN" != "true" ]]; then
      base="$(reusable_base_of "$template")"
      deploy_template="$(mktemp)"
      ring_repin_uses "$base" "$emit" < "$repin_source" > "$deploy_template"
      _TMPFILES+=("$deploy_template")
    fi
    paths+=("$target_path"); templates+=("$deploy_template"); names+=("$workflow"); emits+=("$emit"); modes+=("$mode")
  done

  if [[ "${#names[@]}" -eq 0 ]]; then
    rm -f "${_TMPFILES[@]+"${_TMPFILES[@]}"}"; _TMPFILES=(); return  # nothing drifted for this repo
  fi

  local n="${#names[@]}" list branch
  list=$(IFS=', '; echo "${names[*]}")
  branch="${SYNC_BRANCH_PREFIX}/workflows-$(date -u +%Y%m%d)"
  local title="chore: sync ${n} org-standard workflow stub(s) from ${ORG}/.github"

  local n="${#names[@]}" list branch
  list=$(IFS=', '; echo "${names[*]}")
  branch="${SYNC_BRANCH_PREFIX}/workflows-$(date -u +%Y%m%d)"
  local title="chore: sync ${n} org-standard workflow stub(s) from ${ORG}/.github"

  if [[ "$DRY_RUN" == "true" ]]; then
    local i
    for (( i = 0; i < n; i++ )); do
      [[ -n "${emits[i]}" ]] && dry "$repo/${names[i]} would pin @${emits[i]}"
      case "${modes[i]}" in
        seed)           dry "$repo/${names[i]} seed-if-absent: seeding fresh from template" ;;
        repin-in-place) dry "$repo/${names[i]} re-pin uses in place — existing body/project_context preserved" ;;
      esac
    done
    dry "Would open PR for $repo (branch $branch) — ${n} stub(s): $list"
    rm -f "${_TMPFILES[@]+"${_TMPFILES[@]}"}"; _TMPFILES=(); return
  fi

  # Interleave (path, template) into the variadic file-pair args.
  local -a filepairs=() k
  for (( k = 0; k < n; k++ )); do filepairs+=("${paths[k]}" "${templates[k]}"); done

  local body outcome
  body=$(batch_pr_body "${names[@]}")
  outcome=$(sd_deploy_files_via_pr "$ORG/$repo" "$branch" "$SYNC_LABEL" "$title" "$body" "${filepairs[@]}") || true

  [[ "${#_TMPFILES[@]}" -gt 0 ]] && rm -f "${_TMPFILES[@]}"; _TMPFILES=()

  case "$outcome" in
    "OPENED "*)       ok   "$repo — opened ${outcome#OPENED } (${n} stub(s): $list)" ;;
    "SKIP_PR_OPEN "*) skip "$repo — sync PR #${outcome#SKIP_PR_OPEN } already open" ;;
    "FAILED "*)       err  "$repo — ${outcome#FAILED }" ;;
    *)                err  "$repo — unexpected outcome: ${outcome:-<none>}" ;;
  esac
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  [[ "$DRY_RUN" == "true" ]] && log "DRY RUN — no PRs will be opened"

  # Resolve target repos using pagination (handles orgs with >100 repos).
  declare -a REPOS
  if [[ -n "$TARGET_REPO" ]]; then
    REPOS=("$TARGET_REPO")
  else
    mapfile -t REPOS < <(gh repo list "$ORG" --limit 500 --no-archived --json name -q '.[].name')
  fi

  # Resolve target workflows
  declare -a WORKFLOWS
  if [[ -n "$TARGET_WORKFLOW" ]]; then
    WORKFLOWS=("$TARGET_WORKFLOW")
  else
    WORKFLOWS=("${DEPLOYABLE_WORKFLOWS[@]}")
  fi

  log "Deploying ${#WORKFLOWS[@]} workflow(s) to ${#REPOS[@]} repo(s)"

  _OVERALL_FAILED=0
  local repo
  for repo in "${REPOS[@]}"; do
    deploy_repo "$repo"
  done

  if [[ "$_OVERALL_FAILED" -ne 0 ]]; then
    err "Completed with errors — one or more workflows were refused or failed; see above"
    exit 1
  fi
  log "Done."
}

# Run main only when executed directly, not when sourced (e.g. by bats tests
# that exercise individual helper functions like reconcile_skip_repo_required_workflows).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
