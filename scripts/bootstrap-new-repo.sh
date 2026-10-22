#!/usr/bin/env bash
set -euo pipefail
# bootstrap-new-repo.sh — one-shot, DRY_RUN-aware bootstrap that brings a newly
# created repo to full org compliance by ORCHESTRATING the existing apply-*
# scripts. It reimplements no policy (issue #967, epic #964):
#
#   • repo settings + security/GHAS + secret-scanning push protection come from
#     scripts/apply-repo-settings.sh (which sources scripts/lib/push-protection.sh)
#   • the two sanctioned fleet rulesets — pr-quality + code-quality, each carrying
#     the mandatory bypass actors dependabot-automerge-petry (Integration app) +
#     OrganizationAdmin, both bypass_mode "always" — come from
#     scripts/apply-rulesets.sh, which sources them from petry-projects/.github
#     (standards/rulesets/*.json, relocated there under #575). Required status
#     checks are carried in those ruleset JSONs, not wired here. The repo-local
#     `release-channel-tags` ruleset is NOT applied to bootstrapped repos — it
#     protects .github-private's own pr-review/** + dev-lead/** release tags only.
#     No legacy/ad-hoc `main` ruleset is created.
#   • the standard label set + CODEOWNERS-team verification are bootstrap data,
#     applied/verified here.
#
# Steps run in sequence and FAIL FAST: if repo settings or rulesets fail, the
# remaining steps are skipped and the script exits non-zero with a FAIL summary.
#
# It also CONFIRMS the new repo's release ring (issue #968): the ring is a
# deliberate, auditable choice (default stable). The confirmation is always
# recorded (operator + value + timestamp). A non-stable ring is registered in
# BOTH central files — standards/canary-rings.json here AND scripts/lib/ring-pins.sh
# in petry-projects/.github (cross-repo, via the aw-standards-sync.sh PR pattern,
# kept in sync) — and the shipped caller stub is repinned to the matching channel
# tag @<agent>/<ring>, so audit/fleet drift never sees the repo in two rings.
#
# Usage:
#   bash scripts/bootstrap-new-repo.sh owner/new-repo
#   bash scripts/bootstrap-new-repo.sh --ring ring1 owner/new-repo
#   DRY_RUN=true bash scripts/bootstrap-new-repo.sh owner/new-repo
#
# Env:
#   DRY_RUN          "true" → print intent, make no write calls. Bridged onto
#                    apply-repo-settings.sh's DEV_LEAD_DRY_RUN and
#                    apply-rulesets.sh's DRY_RUN from this single flag.
#   GH_TOKEN         classic PAT with repo + admin scope (apply-repo-settings.sh
#                    rejects OAuth app tokens for the check-suites API).
#   CODEOWNERS_TEAM  expected first CODEOWNERS owner (default @petry-projects/org-leads).
#   ORG              passed through to apply-repo-settings.sh (default petry-projects).
#   CANARY_RINGS     ring SoT path (default standards/canary-rings.json next to this repo).
#   STANDARDS_REPO   repo holding the cross-repo ring-pins.sh (default petry-projects/.github).
#   RING_PINS_PATH   ring-pins.sh path within STANDARDS_REPO (default scripts/lib/ring-pins.sh).
#
# Args:
#   --ring <stable|ring1|ring0|next>   release ring to confirm (default stable).
#   --agent <name>                     agent whose rings/stub this repo joins (default dev-lead).
#
# Test seams: APPLY_REPO_SETTINGS / APPLY_RULESETS override the sub-script paths.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Shared, idempotent .gitignore secrets-baseline upsert (issue #798). Sourced so
# the new repo auto-onboards the marker-wrapped L1 block; L2 stays per-repo.
# shellcheck source=scripts/lib/gitignore-baseline.sh
source "$SCRIPT_DIR/lib/gitignore-baseline.sh"

DRY_RUN="${DRY_RUN:-false}"
# Canonical source of the marker-wrapped L1 block: this repo's own /.gitignore
# (maintained under STORY1, #797). Overridable as a test seam.
GITIGNORE_CANONICAL="${GITIGNORE_CANONICAL:-${SCRIPT_DIR}/../.gitignore}"
CODEOWNERS_TEAM="${CODEOWNERS_TEAM:-@petry-projects/org-leads}"
APPLY_REPO_SETTINGS="${APPLY_REPO_SETTINGS:-${SCRIPT_DIR}/apply-repo-settings.sh}"
APPLY_RULESETS="${APPLY_RULESETS:-${SCRIPT_DIR}/apply-rulesets.sh}"
CANARY_RINGS="${CANARY_RINGS:-${SCRIPT_DIR}/../standards/canary-rings.json}"
STANDARDS_REPO="${STANDARDS_REPO:-petry-projects/.github}"
RING_PINS_PATH="${RING_PINS_PATH:-scripts/lib/ring-pins.sh}"
RING="${RING:-stable}"
RING_AGENT="${RING_AGENT:-dev-lead}"

# Standard org label set every repo carries — the labels the shared automation
# keys on. Format: "name|hex-color|description". Applied idempotently (--force).
readonly -a BOOTSTRAP_LABELS=(
  "needs-human-review|d93f0b|Escalated by automation — a human owner must review"
  "ack-test-deletion|5319e7|Maintainer acknowledgement to allow deleting files under tests/"
  "dependencies|0366d6|Dependency updates (Dependabot)"
  "automerge|0e8a16|Eligible for auto-merge once required checks pass"
)

_is_dry() { [ "$DRY_RUN" = "true" ]; }

# ── Release-ring confirmation & registration (issue #968, epic #964) ──────────
# The default ring `stable` is record-only: a new repo is already covered by the
# `*` catch-all member token, so no central-file edit is needed — but the choice
# is still recorded. A non-stable ring is registered explicitly in both central
# files (canary-rings.json here + ring-pins.sh cross-repo) and the caller stub is
# repinned to @<agent>/<ring> so the audit / fleet drift check sees one ring.

_ring_operator()  { printf '%s' "${GITHUB_ACTOR:-${USER:-unknown}}"; }
_ring_timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# _ring_channels <agent> — the agent's known channels, one per line.
_ring_channels() {
  jq -r --arg a "$1" '.agents[$a].rings[].channel' "$CANARY_RINGS" 2>/dev/null
}

# _ring_is_valid <agent> <ring> — true when <ring> is a known channel for <agent>.
_ring_is_valid() {
  local agent="$1" ring="$2" c
  while IFS= read -r c; do
    [ "$c" = "$ring" ] && return 0
  done < <(_ring_channels "$agent")
  return 1
}

# _record_ring_decision <repo> <agent> <ring> — emit the auditable record
# (operator + value + timestamp), always — even when the answer is stable.
_record_ring_decision() {
  local repo="$1" agent="$2" ring="$3" op ts decision line
  op="$(_ring_operator)"
  ts="$(_ring_timestamp)"
  decision="recorded"
  [ "$ring" != "stable" ] && decision="registered"
  line="[ring-audit] repo=${repo} agent=${agent} ring=${ring} operator=${op} at=${ts} decision=${decision}"
  echo "  $line"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$line" >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
  fi
}

# _canary_add_member_json <repo> <agent> <ring> — print canary-rings.json with
# <repo> added to <ring>'s members (idempotent — no-op if already present).
_canary_add_member_json() {
  local repo="$1" agent="$2" ring="$3"
  jq --arg a "$agent" --arg c "$ring" --arg r "$repo" '
    .agents[$a].rings |= map(
      if .channel == $c and ((.members | index($r)) | not)
      then .members += [$r] else . end
    )
  ' "$CANARY_RINGS"
}

# _assert_ring_consistency <repo> <agent> <ring> — read a proposed canary-rings
# JSON on stdin; succeed iff <repo> is an explicit member of <ring> and of NO
# other ring (the no-drift invariant the audit/fleet check enforces).
_assert_ring_consistency() {
  local repo="$1" agent="$2" ring="$3"
  jq -e --arg a "$agent" --arg c "$ring" --arg r "$repo" '
    ((.agents[$a].rings[] | select(.channel==$c) | (.members | index($r))) != null)
    and (([.agents[$a].rings[] | select(.channel!=$c) | .members[] | select(.==$r)] | length) == 0)
  ' >/dev/null 2>&1
}

# _register_ring_pins <repo> <agent> <ring> — keep the cross-repo central file
# scripts/lib/ring-pins.sh (in $STANDARDS_REPO) in sync with canary-rings.json by
# registering <repo> in the <agent>/<ring> mapping. ring-pins.sh is NOT present in
# this repo, so this is a cross-repo edit done via the aw-standards-sync.sh PR
# pattern. DRY_RUN prints the intent.
_register_ring_pins() {
  local repo="$1" agent="$2" ring="$3"
  echo "  [ring] would register ${repo} in ${STANDARDS_REPO}:${RING_PINS_PATH} for channel ${agent}/${ring} (cross-repo PR, keeps central files in sync)"
  if _is_dry; then
    return 0
  fi
  _cross_repo_ring_pins_pr "$repo" "$agent" "$ring"
}

# _repin_stub <repo> <agent> <ring> — a non-stable repo's caller stub must pin
# the channel tag @<agent>/<ring> (and agent_ref) matching its ring, or the audit
# / fleet stub-drift check flags it. DRY_RUN prints the intent.
_repin_stub() {
  local repo="$1" agent="$2" ring="$3"
  echo "  [ring] would repin ${repo} caller stub .github/workflows/${agent}.yml to @${agent}/${ring}"
  if _is_dry; then
    return 0
  fi
  _cross_repo_repin_stub_pr "$repo" "$agent" "$ring"
}

# _cross_repo_file_pr <repo> <path> <new_content> <branch> <commit_msg> <title> <body>
# Opens a PR on <repo> setting <path> to <new_content> via the contents API +
# gh pr create (mirrors scripts/aw-standards-sync.sh). Returns non-zero on failure.
_cross_repo_file_pr() {
  local repo="$1" path="$2" content="$3" branch="$4" msg="$5" title="$6" body="$7"
  local default_branch base_sha sha encoded
  local -a sha_arg=()
  default_branch="$(gh api "repos/${repo}" --jq '.default_branch' 2>/dev/null || echo main)"
  base_sha="$(gh api "repos/${repo}/git/ref/heads/${default_branch}" --jq '.object.sha' 2>/dev/null || true)"
  [ -n "$base_sha" ] || { echo "  [warn] ${repo}: cannot read ${default_branch} head" >&2; return 1; }
  gh api "repos/${repo}/git/refs" --method POST \
    --field "ref=refs/heads/${branch}" --field "sha=${base_sha}" --silent 2>/dev/null \
    || gh api "repos/${repo}/git/ref/heads/${branch}" --silent 2>/dev/null \
    || { echo "  [warn] ${repo}: cannot create branch ${branch}" >&2; return 1; }
  sha="$(gh api "repos/${repo}/contents/${path}?ref=${branch}" --jq '.sha' 2>/dev/null || true)"
  [ -n "$sha" ] && sha_arg=(--field "sha=${sha}")
  # Portable unwrapped base64: GNU wraps at 76 cols and BSD has no -w0, so strip
  # newlines explicitly — the Contents API rejects a wrapped payload.
  encoded="$(printf '%s' "$content" | base64 | tr -d '\n')"
  gh api "repos/${repo}/contents/${path}" --method PUT \
    --field "message=${msg}" --field "content=${encoded}" --field "branch=${branch}" \
    "${sha_arg[@]}" --silent 2>/dev/null \
    || { echo "  [warn] ${repo}: cannot write ${path}" >&2; return 1; }
  # gh/jq availability is checked once in main(); no need to re-check here.
  local existing_pr
  existing_pr="$(gh pr list --repo "$repo" --head "$branch" --state open --json number --jq '.[0].number' 2>/dev/null || true)"
  if [ -n "$existing_pr" ]; then
    echo "  [ring] PR #$existing_pr already open for branch $branch on $repo"
  else
    gh pr create --repo "$repo" --head "$branch" --base "$default_branch" \
      --title "$title" --body "$body" 2>/dev/null \
      || { echo "  [warn] ${repo}: cannot open PR for ${path}" >&2; return 1; }
  fi
}

# _cross_repo_ring_pins_pr <repo> <agent> <ring> — fetch ring-pins.sh from
# $STANDARDS_REPO, register <repo> in the <ring> bash array, and open a PR. The
# assumed format is a per-ring indexed array `<ring>=( "owner/repo" … )` on one
# line (mirrors canary-rings.json per-channel members). If <repo> is already
# present it is a no-op; if the anchor is absent it errors rather than corrupt.
_cross_repo_ring_pins_pr() {
  local repo="$1" agent="$2" ring="$3" content new branch
  content="$(gh api "repos/${STANDARDS_REPO}/contents/${RING_PINS_PATH}" --jq '.content' 2>/dev/null | { base64 -d 2>/dev/null || base64 -D 2>/dev/null; } || true)"
  [ -n "$content" ] || { echo "::error::cannot fetch ${STANDARDS_REPO}:${RING_PINS_PATH} for ring-pins registration" >&2; return 1; }
  # Ring-specific: only treat as in-sync if the repo is already in THIS ring's array
  # line (`<ring>=( … )`). A bare repo-wide match would false-positive when the repo is
  # registered in a *different* ring, leaving canary-rings.json and ring-pins.sh divergent.
  if printf '%s' "$content" | grep -F "${ring}=(" | grep -qF "\"$repo\""; then
    echo "  [ring] ${repo} already present in ${RING_PINS_PATH} for ${ring} — in sync"
    return 0
  fi
  new="$(printf '%s' "$content" | awk -v repo="$repo" -v ring="$ring" '
    { line=$0
      if (!done && line !~ /^[[:space:]]*#/ && index(line, ring "=(") > 0 && match(line, /\)[[:space:]]*$/)) {
        pre=substr(line, 1, RSTART-1); post=substr(line, RSTART)
        sub(/[[:space:]]*$/, "", pre)
        line = pre " \"" repo "\"" post; done=1
      }
      print line }
    END { if (!done) exit 3 }')" \
    || { echo "::error::could not locate a '${ring}=( … )' anchor in ${RING_PINS_PATH} — register manually" >&2; return 1; }
  branch="ring-pins/${agent}-${ring}-$(printf '%s' "$repo" | tr '/' '-')"
  _cross_repo_file_pr "$STANDARDS_REPO" "$RING_PINS_PATH" "$new" "$branch" \
    "chore: register ${repo} in ${agent}/${ring} ring-pins" \
    "chore: register ${repo} in ${agent}/${ring}" \
    "Registers \`${repo}\` in the \`${ring}\` ring, syncing ring-pins.sh with canary-rings.json (bootstrap, #968)."
}

# _cross_repo_repin_stub_pr <repo> <agent> <ring> — fetch the target repo's caller
# stub and repin its channel tag + agent_ref to @<agent>/<ring>, then open a PR.
_cross_repo_repin_stub_pr() {
  local repo="$1" agent="$2" ring="$3" path content new branch
  path=".github/workflows/${agent}.yml"
  content="$(gh api "repos/${repo}/contents/${path}" --jq '.content' 2>/dev/null | { base64 -d 2>/dev/null || base64 -D 2>/dev/null; } || true)"
  [ -n "$content" ] || { echo "  [warn] ${repo}: no ${path} stub to repin" >&2; return 0; }
  new="$(printf '%s' "$content" \
    | sed -E "s#@${agent}/[A-Za-z0-9_-]+#@${agent}/${ring}#g; s#(agent_ref:[[:space:]]*[\"']?)${agent}/[A-Za-z0-9_-]+#\\1${agent}/${ring}#g")"
  if [ "$new" = "$content" ]; then
    echo "  [ring] ${repo} stub already pins @${agent}/${ring}"
    return 0
  fi
  branch="ring-repin/${agent}-${ring}"
  _cross_repo_file_pr "$repo" "$path" "$new" "$branch" \
    "chore: repin ${agent} stub to @${agent}/${ring}" \
    "chore: repin ${agent} stub to @${agent}/${ring}" \
    "Repins the \`${agent}\` caller stub to the \`${ring}\` channel to match this repo's ring (bootstrap, #968)."
}

# step_ring <repo> — confirm + record the release ring; register a non-stable ring.
step_ring() {
  local repo="${1:-}" proposed
  echo "[bootstrap] (1/6) release ring confirmation (${RING_AGENT}/${RING})"
  if [ ! -f "$CANARY_RINGS" ]; then
    echo "::error::ring SoT not found at $CANARY_RINGS" >&2
    return 1
  fi
  if ! _ring_is_valid "$RING_AGENT" "$RING"; then
    echo "::error::unknown ring '${RING}' for agent '${RING_AGENT}' (valid: $(_ring_channels "$RING_AGENT" | paste -sd, -))" >&2
    return 1
  fi
  _record_ring_decision "$repo" "$RING_AGENT" "$RING"

  if [ "$RING" = "stable" ]; then
    echo "  ring=stable — record-only; no central-file change required (covered by the '*' catch-all)"
    return 0
  fi

  # Non-stable: register in canary-rings.json (this repo) and assert no drift on
  # the proposed post-state before writing.
  proposed="$(_canary_add_member_json "$repo" "$RING_AGENT" "$RING")" \
    || { echo "::error::failed to compute canary-rings update for ${repo}" >&2; return 1; }
  if ! _assert_ring_consistency "$repo" "$RING_AGENT" "$RING" <<< "$proposed"; then
    echo "::error::ring drift: ${repo} would not sit solely in '${RING}' — refusing to register" >&2
    return 1
  fi
  if _is_dry; then
    echo "  [dry-run] would add ${repo} to ${RING_AGENT} '${RING}' members in $(basename "$CANARY_RINGS")"
  else
    printf '%s\n' "$proposed" > "$CANARY_RINGS"
    echo "  registered ${repo} in ${RING_AGENT} '${RING}' (canary-rings.json)"
  fi

  _register_ring_pins "$repo" "$RING_AGENT" "$RING" || return 1
  _repin_stub "$repo" "$RING_AGENT" "$RING" || return 1
  echo "  ring consistency OK — ${repo} sits in '${RING}' across both central files and its stub pins @${RING_AGENT}/${RING}"
}

# pass_summary <repo>
pass_summary() {
  local repo="${1:-}"
  local mode="${2:-}"
  echo ""
  echo "[bootstrap] ====================================================="
  echo "[bootstrap] PASS — ${repo} bootstrapped to org compliance${mode:+ (${mode})}"
  echo "[bootstrap] ====================================================="
}

# fail_summary <repo> <stage>
fail_summary() {
  local repo="${1:-}"
  local stage="${2:-}"
  echo ""
  echo "[bootstrap] ====================================================="
  echo "[bootstrap] FAIL — ${repo}: '${stage}' step failed; remaining steps skipped"
  echo "[bootstrap] ====================================================="
}

# step_repo_settings <repo> — repo settings + security/GHAS + push protection.
step_repo_settings() {
  local repo="${1:-}" settings_dry=false
  _is_dry && settings_dry=true
  echo "[bootstrap] (2/6) repo settings + security/GHAS + push protection"
  # Canonical apply-repo-settings.sh (petry-projects/.github) reads DRY_RUN; bridge
  # onto it. DEV_LEAD_DRY_RUN is kept for backward-compat with any older copy.
  DRY_RUN="$settings_dry" DEV_LEAD_DRY_RUN="$settings_dry" bash "$APPLY_REPO_SETTINGS" "$repo"
}

# step_rulesets <repo> — apply the sanctioned fleet rulesets (pr-quality +
# code-quality), which apply-rulesets.sh sources from petry-projects/.github. With
# no explicit RULESETS_DIR the applier is in fleet mode, so exactly those two are
# applied; release-channel-tags is applied by name only (org tag standard) and not
# part of the bootstrap fleet set.
step_rulesets() {
  local repo="${1:-}" rulesets_dry=false
  _is_dry && rulesets_dry=true
  echo "[bootstrap] (3/6) sanctioned fleet rulesets (pr-quality + code-quality)"
  DRY_RUN="$rulesets_dry" RULESETS_DIR="" bash "$APPLY_RULESETS" --repo "$repo"
}

# step_labels <repo> — apply the standard label set (best-effort, idempotent).
step_labels() {
  local repo="${1:-}" spec name color desc
  echo "[bootstrap] (4/6) standard label set"
  for spec in "${BOOTSTRAP_LABELS[@]}"; do
    IFS='|' read -r name color desc <<<"$spec"
    if _is_dry; then
      echo "  [dry-run] would ensure label '${name}' on ${repo}"
      continue
    fi
    if gh label create "$name" --color "$color" --description "$desc" --force --repo "$repo" >/dev/null 2>&1; then
      echo "  ensured label '${name}'"
    else
      echo "  [warn] could not ensure label '${name}' on ${repo}" >&2
    fi
  done
}

# step_codeowners <repo> — verify CODEOWNERS lists $CODEOWNERS_TEAM first. Best-effort.
step_codeowners() {
  local repo="${1:-}" encoded decoded first_owner
  echo "[bootstrap] (5/6) verify CODEOWNERS team (${CODEOWNERS_TEAM} first owner)"
  if _is_dry; then
    echo "  [dry-run] would verify ${CODEOWNERS_TEAM} is the first CODEOWNERS owner on ${repo}"
    return 0
  fi
  encoded=""
  local path
  for path in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do
    encoded="$(gh api "repos/${repo}/contents/${path}" --jq '.content' 2>/dev/null || true)"
    [ -n "$encoded" ] && [ "$encoded" != "null" ] && break
    encoded=""
  done
  if [ -z "$encoded" ]; then
    echo "  [warn] CODEOWNERS not found on ${repo} — cannot verify team ownership" >&2
    return 0
  fi
  decoded="$(printf '%s' "$encoded" | { base64 -d 2>/dev/null || base64 -D 2>/dev/null; } || true)"
  # First owner on the first non-comment, non-blank rule line.
  first_owner="$(printf '%s\n' "$decoded" \
    | sed 's/#.*//' \
    | awk 'NF >= 2 {print $2; exit}')"
  if [ "$first_owner" = "$CODEOWNERS_TEAM" ]; then
    echo "  verified: ${CODEOWNERS_TEAM} is the first CODEOWNERS owner"
  else
    echo "  [warn] CODEOWNERS first owner is '${first_owner:-<none>}', expected ${CODEOWNERS_TEAM}" >&2
  fi
}

# step_gitignore <repo> — seed/refresh the org secrets baseline (L1) in the repo's
# .gitignore so a new repo auto-onboards to the .gitignore standard (#798). Uses the
# shared upsert_gitignore_baseline(): inserts the marker-wrapped block on a fresh
# repo, refreshes it in place on an existing one, and never touches L2 below END.
# The write is PR-based (never a direct default-branch push), like the ring steps.
step_gitignore() {
  local repo="${1:-}" block
  echo "[bootstrap] (6/6) .gitignore secrets baseline"
  if [ ! -f "$GITIGNORE_CANONICAL" ]; then
    echo "::error::canonical .gitignore baseline not found at $GITIGNORE_CANONICAL" >&2
    return 1
  fi
  block="$(gib_extract_baseline_block "$GITIGNORE_CANONICAL")" || {
    echo "::error::could not extract the marker-wrapped baseline block from $GITIGNORE_CANONICAL" >&2
    return 1
  }

  if _is_dry; then
    echo "  [dry-run] would upsert the marker-wrapped secrets baseline into ${repo}:.gitignore"
    echo "  (insert if absent, refresh in place if present; L2 below END preserved)"
    printf '%s\n' "$block" | sed 's/^/    /'
    return 0
  fi

  local blockfile existfile existing upserted current branch
  local -a tmpfiles=()
  trap '[ "${#tmpfiles[@]}" -eq 0 ] || rm -f "${tmpfiles[@]}"' EXIT

  blockfile="$(mktemp)"
  tmpfiles+=("$blockfile")
  printf '%s\n' "$block" > "$blockfile"

  existfile="$(mktemp)"
  tmpfiles+=("$existfile")

  existing="$(gh api "repos/${repo}/contents/.gitignore" --jq '.content? // empty' 2>/dev/null \
    | { base64 -d 2>/dev/null || base64 -D 2>/dev/null; } || true)"
  printf '%s' "$existing" > "$existfile"

  upserted="$(upsert_gitignore_baseline "$blockfile" "$existfile")" || {
    echo "::error::gitignore upsert failed for ${repo}" >&2
    rm -f "${tmpfiles[@]}"
    trap - EXIT
    return 1
  }
  rm -f "${tmpfiles[@]}"
  trap - EXIT

  current="$(printf '%s' "$existing")"
  if [ "$current" = "$upserted" ]; then
    echo "  ${repo}:.gitignore already carries the current baseline — nothing to do"
    return 0
  fi

  branch="gitignore-baseline/$(date -u +%Y-%m-%d)"
  _cross_repo_file_pr "$repo" ".gitignore" "$upserted" "$branch" \
    "chore: seed org secrets baseline in .gitignore" \
    "chore: seed org secrets baseline in .gitignore" \
    "Seeds the marker-wrapped org secrets baseline (L1) into \`.gitignore\`, preserving any existing L2 entries below the END marker. Auto-onboards this repo to the .gitignore standard (bootstrap, #798)." \
    || { echo "  [warn] ${repo}: could not open .gitignore baseline PR" >&2; return 1; }
  echo "  opened .gitignore baseline PR on ${repo}"
}

main() {
  local repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ring)    [ $# -ge 2 ] || { echo "::error::--ring requires a value" >&2; return 2; }; RING="$2"; shift 2 ;;
      --ring=*)  RING="${1#--ring=}"; shift ;;
      --agent)   [ $# -ge 2 ] || { echo "::error::--agent requires a value" >&2; return 2; }; RING_AGENT="$2"; shift 2 ;;
      --agent=*) RING_AGENT="${1#--agent=}"; shift ;;
      --)        shift; break ;;
      -*)        echo "::error::unknown flag: $1" >&2; return 2 ;;
      *)         if [ -z "$repo" ]; then repo="$1"; else echo "::error::unexpected argument: $1" >&2; return 2; fi; shift ;;
    esac
  done
  if [ -z "$repo" ] && [ $# -gt 0 ]; then repo="$1"; fi
  if [ -z "$repo" ]; then
    echo "::error::usage: $0 [--ring <ring>] [--agent <agent>] owner/new-repo   (DRY_RUN=true for a no-write preview)" >&2
    return 2
  fi

  local cmd
  for cmd in gh jq; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
      echo "::error::${cmd} is required but not installed." >&2
      return 1
    fi
  done

  if [ ! -f "$APPLY_REPO_SETTINGS" ]; then
    echo "::error::apply-repo-settings.sh not found at $APPLY_REPO_SETTINGS" >&2
    return 1
  fi

  if [ ! -f "$APPLY_RULESETS" ]; then
    echo "::error::apply-rulesets.sh not found at $APPLY_RULESETS" >&2
    return 1
  fi

  echo "[bootstrap] repo=${repo} dry_run=${DRY_RUN} ring=${RING_AGENT}/${RING}"

  if ! step_ring "$repo"; then fail_summary "$repo" "ring"; return 1; fi
  if ! step_repo_settings "$repo"; then fail_summary "$repo" "repo-settings"; return 1; fi
  if ! step_rulesets "$repo"; then fail_summary "$repo" "rulesets"; return 1; fi
  if ! step_labels "$repo"; then fail_summary "$repo" "labels"; return 1; fi
  if ! step_codeowners "$repo"; then fail_summary "$repo" "codeowners"; return 1; fi
  if ! step_gitignore "$repo"; then fail_summary "$repo" "gitignore"; return 1; fi

  pass_summary "$repo" "$([ "$DRY_RUN" = "true" ] && echo "dry-run")"
}

# Source-guard: tests source this to exercise individual step_* helpers.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
