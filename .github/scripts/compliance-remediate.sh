#!/usr/bin/env bash
# compliance-remediate.sh — Auto-remediate recurring compliance-audit findings
#
# Reads findings.json produced by compliance-audit.sh and closes the
# audit → report → auto-fix → PR loop.
#
# Remediations fall into two categories:
#   1. Direct API fixes  — applied immediately (no PR): repo settings, labels,
#                          check-suite auto-trigger prefs
#   2. PR-based fixes    — open a branch + PR in the target repo: CODEOWNERS,
#                          action SHA pinning
#
# Findings that cannot be safely auto-remediated are logged as skipped so
# a Claude agent or human can pick them up.
#
# Usage:
#   FINDINGS_FILE=/path/to/findings.json bash scripts/compliance-remediate.sh
#   DRY_RUN=true FINDINGS_FILE=/path/to/findings.json bash scripts/compliance-remediate.sh
#
# Environment variables:
#   GH_TOKEN       GitHub token with repo/org scope (required)
#   FINDINGS_FILE  Path to findings.json from compliance-audit.sh (required)
#   REPORT_DIR     Directory for remediation report output (default: mktemp -d)
#   DRY_RUN        Set to "true" to preview changes without applying (default: false)

set -uo pipefail   # no -e so per-repo errors don't abort the whole run

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "[ERROR] Bash 4+ required (associative arrays). Found: $BASH_VERSION" >&2
  echo "        On macOS: brew install bash, then run with /opt/homebrew/bin/bash" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/gitignore-baseline.sh
source "$SCRIPT_DIR/lib/gitignore-baseline.sh"
# shellcheck source=scripts/lib/standards-deploy.sh
source "$SCRIPT_DIR/lib/standards-deploy.sh"
# Shared label source of truth — STANDARD_LABEL_SPECS (fixed set),
# persona_opt_out_label_configs (derived <id>:hands-off family), and the
# std_label_spec() lookup remediate_label uses to resolve colour+description for
# BOTH the fixed set and the derived family (issue #1139, AC#2/AC#4).
# shellcheck source=scripts/lib/labels.sh
source "$SCRIPT_DIR/lib/labels.sh"

ORG="petry-projects"
FINDINGS_FILE="${FINDINGS_FILE:-}"
REPORT_DIR="${REPORT_DIR:-$(mktemp -d)}"
DRY_RUN="${DRY_RUN:-false}"

# Canonical source of the marker-wrapped org secrets baseline (L1). Overridable
# as a test seam, matching scripts/sync-gitignore-baseline.sh.
GITIGNORE_CANONICAL="${GITIGNORE_CANONICAL:-$(cd "$SCRIPT_DIR/.." && pwd)/.gitignore}"

REMEDIATION_REPORT="$REPORT_DIR/remediation-report.md"
SKIPPED_REPORT="$REPORT_DIR/skipped.md"

# Label colours/descriptions come from the shared std_label_spec() (scripts/lib/
# labels.sh) — the SAME source of truth the audit and applier use — so the
# remediator no longer holds its own copy of the fixed-label table and can also
# resolve the derived <id>:hands-off persona family (issue #1139, AC#2/AC#4).

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*" >&2; }
ok()    { echo "[OK]    $*" >&2; }
warn()  { echo "[WARN]  $*" >&2; }
skip()  { echo "[SKIP]  $*" >&2; }
err()   { echo "[ERROR] $*" >&2; }

# ---------------------------------------------------------------------------
# Portable base64 helpers — GNU base64 uses `-w 0` / `-d`, macOS BSD base64
# uses no wrapping by default and `-D` to decode. Feature-detect once.
# ---------------------------------------------------------------------------
b64_encode() {
  if base64 --help 2>&1 | grep -q -- '-w'; then
    base64 -w 0
  else
    base64 | tr -d '\n'
  fi
}

b64_decode() {
  if printf '' | base64 -d >/dev/null 2>&1; then
    base64 -d
  else
    base64 -D
  fi
}

# Counters
remediated_direct=0
remediated_pr=0
skipped_count=0
failed_count=0

# ---------------------------------------------------------------------------
# Append to reports
# ---------------------------------------------------------------------------
report_direct() {
  local repo="$1" check="$2" action="$3"
  echo "| \`$repo\` | \`$check\` | Direct API | $action |" >> "$REMEDIATION_REPORT"
  remediated_direct=$((remediated_direct + 1))
}

report_pr() {
  local repo="$1" check="$2" pr_url="$3"
  echo "| \`$repo\` | \`$check\` | PR | $pr_url |" >> "$REMEDIATION_REPORT"
  remediated_pr=$((remediated_pr + 1))
}

report_skip() {
  local repo="$1" check="$2" reason="$3"
  echo "| \`$repo\` | \`$check\` | $reason |" >> "$SKIPPED_REPORT"
  skipped_count=$((skipped_count + 1))
}

report_fail() {
  local repo="$1" check="$2" detail="$3"
  echo "| \`$repo\` | \`$check\` | FAILED: $detail |" >> "$SKIPPED_REPORT"
  failed_count=$((failed_count + 1))
}

# ---------------------------------------------------------------------------
# Direct API: repository settings
# ---------------------------------------------------------------------------
remediate_setting() {
  local repo="$1" setting="$2" expected_value="$3" check="$4"

  if [ "$DRY_RUN" = "true" ]; then
    skip "[DRY] Would PATCH $ORG/$repo: $setting=$expected_value"
    report_direct "$repo" "$check" "DRY: would PATCH \`$setting=$expected_value\`"
    return 0
  fi

  if gh api -X PATCH "repos/$ORG/$repo" -F "$setting=$expected_value" > /dev/null 2>&1; then
    ok "Fixed $ORG/$repo: $setting=$expected_value"
    report_direct "$repo" "$check" "Set \`$setting=$expected_value\`"
  else
    err "Failed to patch $ORG/$repo: $setting=$expected_value"
    report_fail "$repo" "$check" "PATCH $setting=$expected_value failed"
  fi
}

# ---------------------------------------------------------------------------
# Direct API: nested security_and_analysis settings
# ---------------------------------------------------------------------------
# The security_and_analysis settings live under a nested object on the repo
# resource, so they can't be patched via `gh api -F key=value` (that only
# sends flat form fields). Build the nested JSON and PATCH via stdin.
remediate_security_analysis_setting() {
  local repo="$1" setting="$2" expected_status="$3" check="$4"

  if [[ "$DRY_RUN" == "true" ]]; then
    skip "[DRY] Would PATCH $ORG/$repo: security_and_analysis.$setting.status=$expected_status"
    report_direct "$repo" "$check" \
      "DRY: would PATCH \`security_and_analysis.$setting.status=$expected_status\`"
    return 0
  fi

  local payload
  if ! payload=$(jq -n \
    --arg key "$setting" \
    --arg status "$expected_status" \
    '{security_and_analysis: {($key): {status: $status}}}') || [[ -z "$payload" ]]; then
    err "Failed to build payload for $ORG/$repo: security_and_analysis.$setting.status=$expected_status"
    report_fail "$repo" "$check" \
      "jq failed to build payload for security_and_analysis.$setting.status=$expected_status"
    return 0
  fi

  if printf '%s' "$payload" | gh api -X PATCH "repos/$ORG/$repo" --input - > /dev/null 2>&1; then
    ok "Fixed $ORG/$repo: security_and_analysis.$setting.status=$expected_status"
    report_direct "$repo" "$check" \
      "Set \`security_and_analysis.$setting.status=$expected_status\`"
  else
    err "Failed to patch $ORG/$repo: security_and_analysis.$setting.status=$expected_status"
    report_fail "$repo" "$check" \
      "PATCH security_and_analysis.$setting.status=$expected_status failed (token may lack repo-admin permission)"
  fi
}

# ---------------------------------------------------------------------------
# Direct API: disable check-suite auto-trigger for problematic apps
# ---------------------------------------------------------------------------
remediate_check_suite_auto_trigger() {
  local repo="$1" app_id="$2" check="$3"

  if [ "$DRY_RUN" = "true" ]; then
    skip "[DRY] Would disable check-suite auto-trigger for app $app_id on $ORG/$repo"
    report_direct "$repo" "$check" "DRY: would set \`auto_trigger=false\` for app_id=$app_id"
    return 0
  fi

  # The check-suites/preferences endpoint rejects OAuth-style tokens (gho_*)
  # and GitHub-App user-to-server tokens — only classic PATs (ghp_*) with
  # repo scope work. Skip with a clear reason rather than logging a failure.
  local token="${GH_TOKEN:-}"
  if [[ "$token" == gho_* ]] || [[ "$token" == ghu_* ]]; then
    skip "GH_TOKEN is an OAuth/user-to-server token — check-suites/preferences requires a classic PAT (ghp_*)"
    report_skip "$repo" "$check" \
      "GH_TOKEN type cannot patch \`check-suites/preferences\` — run \`scripts/fix-check-suite-prefs.sh\` with a classic PAT"
    return 0
  fi

  local payload
  payload=$(jq -n --argjson id "$app_id" '{"auto_trigger_checks":[{"app_id":$id,"setting":false}]}')

  local api_response http_status
  api_response=$(echo "$payload" | gh api -X PATCH "repos/$ORG/$repo/check-suites/preferences" \
      --input - 2>&1 > /dev/null)
  http_status=$?

  if [ "$http_status" -eq 0 ]; then
    ok "Disabled check-suite auto-trigger for app $app_id on $ORG/$repo"
    report_direct "$repo" "$check" "Set \`auto_trigger=false\` for app_id=$app_id"
  elif echo "$api_response" | grep -qE '(HTTP 40[34]|Not Found|Resource not accessible)'; then
    # 403/404 on this endpoint typically means the token type is wrong even
    # when prefix detection above didn't catch it (e.g. fine-grained PAT).
    skip "check-suites/preferences PATCH not permitted for $ORG/$repo (likely token type) — converting to skip"
    report_skip "$repo" "$check" \
      "PATCH \`check-suites/preferences\` returned 403/404 — token may lack required scope; use \`scripts/fix-check-suite-prefs.sh\` with a classic PAT"
  else
    err "Failed to disable check-suite auto-trigger for app $app_id on $ORG/$repo: $api_response"
    report_fail "$repo" "$check" "PATCH check-suites/preferences failed for app_id=$app_id"
  fi
}

# ---------------------------------------------------------------------------
# Direct API: create missing label
# ---------------------------------------------------------------------------
remediate_label() {
  local repo="$1" label="$2"

  # Resolve colour+description from the shared source of truth — the fixed set
  # AND the derived <id>:hands-off persona family (scripts/lib/labels.sh). A
  # label outside the standard set falls back to a neutral default so an
  # unexpected finding still produces a usable label.
  local color="e4e669" desc="" spec
  if spec=$(std_label_spec "$label"); then
    IFS='|' read -r _ color desc <<< "$spec"
  fi

  if [ "$DRY_RUN" = "true" ]; then
    skip "[DRY] Would create label '$label' in $ORG/$repo"
    report_direct "$repo" "missing-label-$label" "DRY: would create label \`$label\`"
    return 0
  fi

  if gh label create "$label" \
      --repo "$ORG/$repo" \
      --color "$color" \
      --description "$desc" \
      --force 2>/dev/null; then
    ok "Created/updated label '$label' in $ORG/$repo"
    report_direct "$repo" "missing-label-$label" "Created label \`$label\` (#$color)"
  else
    err "Failed to create label '$label' in $ORG/$repo"
    report_fail "$repo" "missing-label-$label" "gh label create failed"
  fi
}

# ---------------------------------------------------------------------------
# Ensure the compliance-audit label exists in a repo (needed before PR creation)
# ---------------------------------------------------------------------------
ensure_compliance_label() {
  local repo="$1"
  gh label create "compliance-audit" \
    --repo "$ORG/$repo" \
    --color "7057ff" \
    --description "Automated compliance audit finding" \
    --force 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# PR-based: create or replace CODEOWNERS with the standard template
#
# Standard (codeowners-standard.md):
#   * @petry-projects/org-leads
#
# Individual user listings are forbidden. All ownership goes through the team.
# ---------------------------------------------------------------------------
remediate_codeowners() {
  local repo="$1" check="$2"

  info "Generating CODEOWNERS for $ORG/$repo (finding: $check) ..."

  # Standard template per standards/codeowners-standard.md
  local codeowners_content
  codeowners_content="# CODEOWNERS
# Standard: https://github.com/petry-projects/.github/blob/main/standards/codeowners-standard.md

* @petry-projects/org-leads
"

  if [ "$DRY_RUN" = "true" ]; then
    skip "[DRY] Would open CODEOWNERS PR in $ORG/$repo"
    report_pr "$repo" "$check" "DRY: would open PR creating/updating \`.github/CODEOWNERS\` with \`@petry-projects/org-leads\`"
    return 0
  fi

  # Get default branch and its HEAD SHA
  local default_branch
  default_branch=$(gh api "repos/$ORG/$repo" --jq '.default_branch' 2>/dev/null || echo "main")

  local base_sha
  base_sha=$(gh api "repos/$ORG/$repo/git/refs/heads/$default_branch" --jq '.object.sha' 2>/dev/null || echo "")

  if [ -z "$base_sha" ]; then
    warn "Could not get HEAD SHA for $ORG/$repo/$default_branch"
    report_fail "$repo" "$check" "Could not resolve HEAD SHA for $default_branch"
    return 0
  fi

  # Check if CODEOWNERS already exists at .github/CODEOWNERS (prefer that path)
  # Also check root CODEOWNERS and docs/CODEOWNERS for current SHA (needed for updates)
  local existing_file_sha=""
  local existing_path=".github/CODEOWNERS"
  for path in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do
    local existing_resp
    existing_resp=$(gh api "repos/$ORG/$repo/contents/$path" 2>/dev/null || echo "")
    if [ -n "$existing_resp" ] && echo "$existing_resp" | jq -e '.sha' > /dev/null 2>&1; then
      existing_file_sha=$(echo "$existing_resp" | jq -r '.sha')
      existing_path="$path"
      break
    fi
  done

  local branch_name
  branch_name="fix/compliance-codeowners-$(date +%Y%m%d)"
  if gh api "repos/$ORG/$repo/git/refs/heads/$branch_name" > /dev/null 2>&1; then
    branch_name="fix/compliance-codeowners-$(date +%Y%m%d-%H%M%S)"
  fi

  # Create branch
  if ! gh api -X POST "repos/$ORG/$repo/git/refs" \
      -f ref="refs/heads/$branch_name" \
      -f sha="$base_sha" > /dev/null 2>&1; then
    err "Failed to create branch $branch_name in $ORG/$repo"
    report_fail "$repo" "$check" "Could not create branch $branch_name"
    return 0
  fi

  # Create or update the file via Contents API
  local encoded_content
  encoded_content=$(printf '%s' "$codeowners_content" | b64_encode)

  local api_args=(-X PUT "repos/$ORG/$repo/contents/$existing_path"
    -f message="fix: update CODEOWNERS to use @petry-projects/org-leads team (compliance remediation)"
    -f content="$encoded_content"
    -f branch="$branch_name")
  # If the file already exists, we need to supply its SHA so the PUT updates rather than creates
  [ -n "$existing_file_sha" ] && api_args+=(-f sha="$existing_file_sha")

  if ! gh api "${api_args[@]}" > /dev/null 2>&1; then
    err "Failed to create/update CODEOWNERS in $ORG/$repo"
    gh api -X DELETE "repos/$ORG/$repo/git/refs/heads/$branch_name" > /dev/null 2>&1 || true
    report_fail "$repo" "$check" "Could not create/update file via Contents API"
    return 0
  fi

  # Ensure label exists before PR creation
  ensure_compliance_label "$repo"

  local action_verb="Adds"
  [ -n "$existing_file_sha" ] && action_verb="Updates"

  local pr_url
  pr_url=$(gh pr create \
    --repo "$ORG/$repo" \
    --head "$branch_name" \
    --base "$default_branch" \
    --title "fix: update CODEOWNERS to use org-leads team (compliance)" \
    --body "## Summary

$action_verb \`$existing_path\` to use the \`@petry-projects/org-leads\` team per the org CODEOWNERS standard.

**Finding resolved:** \`$check\`

## Standard template applied

\`\`\`
# CODEOWNERS
# Standard: https://github.com/petry-projects/.github/blob/main/standards/codeowners-standard.md

* @petry-projects/org-leads
\`\`\`

The \`@petry-projects/org-leads\` team contains \`@don-petry\` and \`@donpetry-bot\`.
If you need finer-grained path ownership, add additional lines — but **\`@petry-projects/org-leads\` must be the first owner on every line**.
Individual user listings are forbidden per the CODEOWNERS standard.

Ref: \`standards/codeowners-standard.md\`

---
*Auto-generated by \`scripts/compliance-remediate.sh\`.*" \
    --label "compliance-audit" 2>/dev/null || echo "")

  if [ -n "$pr_url" ]; then
    ok "Opened CODEOWNERS PR in $ORG/$repo: $pr_url"
    report_pr "$repo" "$check" "$pr_url"
  else
    warn "Branch created but PR creation failed for $ORG/$repo ($check)"
    report_fail "$repo" "$check" "PR creation failed (branch: $branch_name)"
  fi
}

# ---------------------------------------------------------------------------
# PR-based: pin unpinned GitHub Actions to SHAs
# ---------------------------------------------------------------------------
remediate_unpinned_actions() {
  local repo="$1" workflow_file="$2"

  info "Pinning actions in $ORG/$repo/.github/workflows/$workflow_file ..."

  # Fetch current workflow content
  local raw_content
  raw_content=$(gh api "repos/$ORG/$repo/contents/.github/workflows/$workflow_file" 2>/dev/null || echo "")

  if [ -z "$raw_content" ]; then
    warn "Could not fetch $workflow_file from $ORG/$repo"
    report_fail "$repo" "unpinned-actions-$workflow_file" "Could not fetch workflow file"
    return 0
  fi

  local encoded file_sha
  encoded=$(echo "$raw_content" | jq -r '.content // empty')
  file_sha=$(echo "$raw_content" | jq -r '.sha // empty')

  if [ -z "$encoded" ] || [ -z "$file_sha" ]; then
    report_fail "$repo" "unpinned-actions-$workflow_file" "Could not parse file content or SHA"
    return 0
  fi

  local decoded
  decoded=$(printf '%s' "$encoded" | b64_decode 2>/dev/null || echo "")
  [ -z "$decoded" ] && { report_fail "$repo" "unpinned-actions-$workflow_file" "base64 decode failed"; return 0; }

  # Find all unpinned uses: directives
  local unpinned_refs
  unpinned_refs=$(echo "$decoded" \
    | grep -oE 'uses:[[:space:]]+[^@[:space:]]+@[^#[:space:]]+' \
    | grep -vE '@[0-9a-f]{40}' \
    | grep -vE '(docker://|\.\/)' \
    | awk '{print $2}' \
    | sort -u || true)

  if [ -z "$unpinned_refs" ]; then
    info "No unpinned actions found in $workflow_file (may already be fixed)"
    report_skip "$repo" "unpinned-actions-$workflow_file" "No unpinned actions found in current file (re-audit may resolve)"
    return 0
  fi

  local patched_content="$decoded"
  local pins_applied=0
  local pins_failed=0

  while IFS= read -r ref; do
    [ -z "$ref" ] && continue

    local action_part tag_part repo_part
    action_part="${ref%@*}"
    tag_part="${ref##*@}"

    # `action_part` may be either a direct action (`owner/repo`) or a reusable
    # workflow path (`owner/repo/.github/workflows/file.yml`). The git/refs and
    # commits APIs take `owner/repo`, so peel off any trailing path segments
    # while keeping `action_part` intact for the replacement.
    repo_part=$(echo "$action_part" | awk -F/ 'NF>=2 {print $1"/"$2}')
    if [ -z "$repo_part" ]; then
      warn "Could not parse owner/repo from $ref — skipping"
      pins_failed=$((pins_failed + 1))
      continue
    fi

    # Skip if already a full SHA (shouldn't occur given grep above)
    if echo "$tag_part" | grep -qE '^[0-9a-f]{40}$'; then
      continue
    fi

    # Resolve the tag to a commit SHA.
    # Lightweight tags point directly to a commit (.object.type == "commit").
    # Annotated tags point to a tag object (.object.type == "tag") which
    # must be dereferenced to get the commit SHA.
    local commit_sha=""
    local ref_json
    ref_json=$(gh api "repos/$repo_part/git/refs/tags/$tag_part" 2>/dev/null || echo "")

    if [ -n "$ref_json" ]; then
      local obj_type obj_sha
      obj_type=$(echo "$ref_json" | jq -r '.object.type // empty')
      obj_sha=$(echo "$ref_json" | jq -r '.object.sha // empty')

      if [ "$obj_type" = "tag" ]; then
        # Annotated tag — dereference the tag object
        commit_sha=$(gh api "repos/$repo_part/git/tags/$obj_sha" \
          --jq '.object.sha' 2>/dev/null || echo "")
      else
        commit_sha="$obj_sha"
      fi
    fi

    # Fallback: commits API
    if [ -z "$commit_sha" ]; then
      commit_sha=$(gh api "repos/$repo_part/commits?sha=$tag_part&per_page=1" \
        --jq '.[0].sha' 2>/dev/null || echo "")
    fi

    if [ -z "$commit_sha" ]; then
      warn "Could not resolve SHA for $ref — skipping"
      pins_failed=$((pins_failed + 1))
      continue
    fi

    # Replace `uses:<ws>owner/action@tag` → `uses: owner/action@sha # tag`.
    # Use [[:space:]]+ so any amount of tabs/spaces between `uses:` and the ref
    # matches (still valid YAML). Indentation before `uses:` is preserved
    # because it sits outside the match.
    local escaped_ref
    escaped_ref=$(printf '%s' "$ref" | sed 's/[][\.*^$()+?{|/]/\\&/g')
    patched_content=$(echo "$patched_content" \
      | sed -E "s|uses:[[:space:]]+${escaped_ref}|uses: ${action_part}@${commit_sha} # ${tag_part}|g")

    ok "  Pinned $ref → $commit_sha"
    pins_applied=$((pins_applied + 1))
  done <<< "$unpinned_refs"

  if [ "$pins_applied" -eq 0 ]; then
    info "No actions could be pinned in $workflow_file (all lookups failed)"
    report_fail "$repo" "unpinned-actions-$workflow_file" \
      "SHA resolution failed for all $pins_failed action(s)"
    return 0
  fi

  if [ "$DRY_RUN" = "true" ]; then
    skip "[DRY] Would open PR pinning $pins_applied action(s) in $ORG/$repo/.github/workflows/$workflow_file"
    report_pr "$repo" "unpinned-actions-$workflow_file" \
      "DRY: would open PR pinning $pins_applied action(s)"
    return 0
  fi

  # Create a branch and push the patched file
  local default_branch
  default_branch=$(gh api "repos/$ORG/$repo" --jq '.default_branch' 2>/dev/null || echo "main")

  local base_sha
  base_sha=$(gh api "repos/$ORG/$repo/git/refs/heads/$default_branch" \
    --jq '.object.sha' 2>/dev/null || echo "")

  if [ -z "$base_sha" ]; then
    report_fail "$repo" "unpinned-actions-$workflow_file" "Could not resolve HEAD SHA"
    return 0
  fi

  local wf_slug
  wf_slug=$(echo "$workflow_file" | sed 's/\.[^.]*$//')
  local branch_name
  branch_name="fix/compliance-pin-actions-${wf_slug}-$(date +%Y%m%d)"
  if gh api "repos/$ORG/$repo/git/refs/heads/$branch_name" > /dev/null 2>&1; then
    branch_name="${branch_name}-$(date +%H%M%S)"
  fi

  if ! gh api -X POST "repos/$ORG/$repo/git/refs" \
      -f ref="refs/heads/$branch_name" \
      -f sha="$base_sha" > /dev/null 2>&1; then
    report_fail "$repo" "unpinned-actions-$workflow_file" \
      "Could not create branch $branch_name"
    return 0
  fi

  local new_encoded
  new_encoded=$(printf '%s' "$patched_content" | b64_encode)

  local failed_note=""
  [ "$pins_failed" -gt 0 ] && \
    failed_note="
$pins_failed action(s) could not be resolved and were left unpinned."

  local commit_msg="fix: pin actions to commit SHAs in $workflow_file

Pinned $pins_applied action(s) to full commit SHAs per org security policy.${failed_note}

Ref: standards/ci-standards.md#action-pinning-policy"

  if ! gh api -X PUT "repos/$ORG/$repo/contents/.github/workflows/$workflow_file" \
      -f message="$commit_msg" \
      -f content="$new_encoded" \
      -f sha="$file_sha" \
      -f branch="$branch_name" > /dev/null 2>&1; then
    gh api -X DELETE "repos/$ORG/$repo/git/refs/heads/$branch_name" > /dev/null 2>&1 || true
    report_fail "$repo" "unpinned-actions-$workflow_file" "Contents API PUT failed"
    return 0
  fi

  ensure_compliance_label "$repo"

  local pr_failed_note=""
  [ "$pins_failed" -gt 0 ] && pr_failed_note="

> **Note:** $pins_failed action(s) could not be resolved to SHAs and were left unchanged.
> Review the workflow file and pin them manually."

  local pr_url
  pr_url=$(gh pr create \
    --repo "$ORG/$repo" \
    --head "$branch_name" \
    --base "$default_branch" \
    --title "fix: pin actions to commit SHAs in $workflow_file" \
    --body "## Summary

Pins $pins_applied unpinned GitHub Actions to full commit SHAs in \`.github/workflows/$workflow_file\`.
$pr_failed_note

## Why

Pinning actions to commit SHAs prevents supply-chain attacks where a tag is moved
to a different (potentially malicious) commit.

Ref: \`standards/ci-standards.md#action-pinning-policy\`

---
*Auto-generated by \`scripts/compliance-remediate.sh\` to resolve \`unpinned-actions-$workflow_file\`.*" \
    --label "compliance-audit" 2>/dev/null || echo "")

  if [ -n "$pr_url" ]; then
    ok "Opened action-pinning PR in $ORG/$repo: $pr_url"
    report_pr "$repo" "unpinned-actions-$workflow_file" "$pr_url"
  else
    warn "Branch created but PR creation failed for $ORG/$repo (workflow: $workflow_file)"
    report_fail "$repo" "unpinned-actions-$workflow_file" \
      "PR creation failed (branch: $branch_name)"
  fi
}

# ---------------------------------------------------------------------------
# PR-based: place or refresh the org secrets baseline (L1) in .gitignore
#
# Uses the shared, idempotent upsert_gitignore_baseline() (scripts/lib/gitignore-
# baseline.sh) so a repo's per-repo L2 — every line below the END marker — is
# never touched. Ships the fix via sd_deploy_via_pr(): a PR, never a direct
# default-branch push (rejected by ruleset-protected repos). Idempotency is
# keyed on the `gitignore-baseline` label and shared with sync-gitignore-baseline.sh,
# so an already-open baseline PR (from either tool) is reused, not duplicated.
# ---------------------------------------------------------------------------
remediate_gitignore_baseline() {
  local repo="$1" check="$2"

  info "Remediating .gitignore secrets baseline for $ORG/$repo (finding: $check) ..."

  # Extract the canonical marker-wrapped L1 block from the org /.gitignore. A
  # missing/half-open block is a hard error — never ship a partial baseline.
  local block_file
  block_file="$(mktemp)"
  if ! gib_extract_baseline_block "$GITIGNORE_CANONICAL" > "$block_file" 2>/dev/null; then
    rm -f "$block_file"
    err "Canonical baseline block unreadable at $GITIGNORE_CANONICAL"
    report_fail "$repo" "$check" "canonical secrets-baseline block unreadable at $GITIGNORE_CANONICAL"
    return 0
  fi

  # Fetch the repo's current .gitignore.  A genuine 404 (file absent) is
  # fine — continue with an empty file.  Any other failure (auth, rate-limit,
  # 5xx) means we cannot know what L2 content the file holds; fail fast rather
  # than silently replacing it with a baseline-only file.
  local existing_file api_out api_err
  existing_file="$(mktemp)"
  api_out="$(mktemp)"
  api_err="$(mktemp)"
  if gh api "repos/$ORG/$repo/contents/.gitignore" > "$api_out" 2>"$api_err"; then
    jq -r '.content // empty' "$api_out" 2>/dev/null | b64_decode > "$existing_file" 2>/dev/null || true
    rm -f "$api_out" "$api_err"
  elif grep -qiF 'HTTP 404' "$api_err" 2>/dev/null || grep -qiF 'Not Found' "$api_err" 2>/dev/null; then
    rm -f "$api_out" "$api_err"
  else
    local api_err_msg; api_err_msg="$(cat "$api_err")"
    rm -f "$block_file" "$existing_file" "$api_out" "$api_err"
    err "gh api failed fetching .gitignore for $ORG/$repo: $api_err_msg"
    report_fail "$repo" "$check" "gh api error fetching .gitignore (auth/rate-limit/server error)"
    return 0
  fi

  # Upsert: place/refresh the L1 block on top, preserving L2 below END verbatim.
  # Compare as command-substituted strings (trailing-newline tolerant), matching
  # sync-gitignore-baseline.sh's sync_repo().
  local existing upserted
  existing="$(cat "$existing_file")"
  if ! upserted="$(upsert_gitignore_baseline "$block_file" "$existing_file" 2>/dev/null)"; then
    rm -f "$block_file" "$existing_file"
    err "upsert_gitignore_baseline failed for $ORG/$repo"
    report_fail "$repo" "$check" "upsert failed (half-open markers in the repo's .gitignore?)"
    return 0
  fi

  # Idempotency: identical content means the repo already carries the baseline.
  if [ "$existing" = "$upserted" ]; then
    rm -f "$block_file" "$existing_file"
    info "$ORG/$repo already carries the current baseline — no-op"
    report_skip "$repo" "$check" "\`.gitignore\` already carries the current org secrets-baseline block (no-op)"
    return 0
  fi

  if [ "$DRY_RUN" = "true" ]; then
    rm -f "$block_file" "$existing_file"
    skip "[DRY] Would open .gitignore baseline PR in $ORG/$repo"
    report_pr "$repo" "$check" "DRY: would open PR upserting the org secrets baseline into \`.gitignore\`"
    return 0
  fi

  # Materialize the upserted content for the PR primitive.
  local upserted_file
  upserted_file="$(mktemp)"
  printf '%s\n' "$upserted" > "$upserted_file"
  rm -f "$block_file" "$existing_file"

  local branch title body outcome
  branch="gitignore-baseline/$(date -u +%Y%m%d)"
  title="fix: sync .gitignore org secrets baseline (compliance remediation)"
  body="## Summary

Upserts the marker-wrapped **org secrets baseline (L1)** into \`.gitignore\`, preserving this repo's per-repo L2 entries below the END marker.

**Finding resolved:** \`$check\`

## Why

The baseline is the first layer of the push-protection program — it keeps credential files (\`.env\`, cloud credentials, \`*.tfvars\`, kubeconfigs, key material, …) out of the working tree before any scanning layer runs. It must be present and byte-for-byte identical across every repo.

Ref: \`standards/gitignore-standard.md\`

---
*Auto-generated by \`scripts/compliance-remediate.sh\` to resolve \`gitignore_baseline\`.*"

  outcome="$(sd_deploy_via_pr "$ORG/$repo" ".gitignore" "$upserted_file" \
    "$branch" "gitignore-baseline" "$title" "$body")" || true
  rm -f "$upserted_file"

  case "$outcome" in
    "OPENED "*)
      ok "Opened .gitignore baseline PR in $ORG/$repo: ${outcome#OPENED }"
      report_pr "$repo" "$check" "${outcome#OPENED }" ;;
    "SKIP_PR_OPEN "*)
      skip "$ORG/$repo — baseline PR #${outcome#SKIP_PR_OPEN } already open"
      report_skip "$repo" "$check" "a \`.gitignore\` baseline PR (#${outcome#SKIP_PR_OPEN }) is already open" ;;
    "FAILED "*)
      err "$ORG/$repo — ${outcome#FAILED }"
      report_fail "$repo" "$check" "sd_deploy_via_pr: ${outcome#FAILED }" ;;
    *)
      err "$ORG/$repo — unexpected deploy outcome: ${outcome:-<none>}"
      report_fail "$repo" "$check" "unexpected sd_deploy_via_pr outcome: ${outcome:-<none>}" ;;
  esac
}

# ---------------------------------------------------------------------------
# Dispatch a single finding to the correct remediation handler
# ---------------------------------------------------------------------------
remediate_finding() {
  local repo="$1" category="$2" check="$3"

  case "$category/$check" in

    # ----- Repository boolean settings -----
    settings/has_wiki)
      remediate_setting "$repo" "has_wiki" "false" "$check"
      ;;
    settings/allow_auto_merge)
      remediate_setting "$repo" "allow_auto_merge" "true" "$check"
      ;;
    settings/delete_branch_on_merge)
      remediate_setting "$repo" "delete_branch_on_merge" "true" "$check"
      ;;
    settings/has_discussions)
      remediate_setting "$repo" "has_discussions" "true" "$check"
      ;;
    settings/has_issues)
      remediate_setting "$repo" "has_issues" "true" "$check"
      ;;
    settings/default-branch)
      report_skip "$repo" "$check" \
        "Renaming default branch requires coordinated git history rewrite — manual fix required"
      ;;

    # ----- Check-suite auto-trigger (blocks auto-merge) -----
    settings/check-suite-auto-trigger-*)
      local app_id="${check#check-suite-auto-trigger-}"
      remediate_check_suite_auto_trigger "$repo" "$app_id" "$check"
      ;;

    # ----- Labels -----
    labels/missing-label-*)
      local label="${check#missing-label-}"
      remediate_label "$repo" "$label"
      ;;

    # ----- CODEOWNERS — all variants -----
    settings/missing-codeowners | \
    settings/codeowners-empty | \
    settings/codeowners-org-leads-not-first | \
    settings/codeowners-individual-users | \
    settings/codeowners-no-catchall)
      remediate_codeowners "$repo" "$check"
      ;;

    # ----- Unpinned actions -----
    action-pinning/unpinned-actions-*)
      local wf_file="${check#unpinned-actions-}"
      remediate_unpinned_actions "$repo" "$wf_file"
      ;;

    # ----- Skipped: require workflows token scope or complex human judgment -----
    # Note: more-specific ci-workflows/* patterns must come before ci-workflows/missing-*
    ci-workflows/missing-permissions-*)
      report_skip "$repo" "$check" \
        "Permissions declarations require per-workflow review — fix manually per standards/ci-standards.md#permissions-policy"
      ;;
    ci-workflows/missing-*)
      report_skip "$repo" "$check" \
        "Creating/updating workflow files requires \`workflow\` token scope — use a PAT or push manually from standards/workflows/"
      ;;
    ci-workflows/non-stub-*)
      report_skip "$repo" "$check" \
        "Syncing centralized workflow stub requires \`workflow\` token scope — copy from standards/workflows/ using a PAT"
      ;;
    ci-workflows/codeql-default-setup-not-configured)
      report_skip "$repo" "$check" \
        "Enable via: gh api -X PATCH repos/$ORG/$repo/code-scanning/default-setup -F state=configured -F query_suite=default"
      ;;
    ci-workflows/stray-codeql-workflow)
      report_skip "$repo" "$check" \
        "Deleting workflow files requires \`workflow\` token scope — remove .github/workflows/codeql.yml using a PAT"
      ;;
    ci-workflows/*)
      report_skip "$repo" "$check" \
        "No automatic remediation for this CI workflow finding — review standards/ci-standards.md"
      ;;
    rulesets/*)
      report_skip "$repo" "$check" \
        "Ruleset changes require admin API access and careful configuration — run scripts/apply-rulesets.sh or use the GitHub UI"
      ;;
    dependabot/missing-config)
      report_skip "$repo" "$check" \
        "Generating dependabot.yml requires ecosystem detection — copy from standards/dependabot/ templates"
      ;;
    dependabot/*)
      report_skip "$repo" "$check" \
        "Dependabot config updates require human review — fix using standards/dependabot-policy.md"
      ;;
    push-protection/non_provider_patterns_enabled | push-protection/secret_scanning_non_provider_patterns)
      remediate_security_analysis_setting "$repo" "secret_scanning_non_provider_patterns" "enabled" "$check"
      ;;
    # The two file-based push-protection checks below are NOT settings PATCHes,
    # so apply-repo-settings.sh (security_and_analysis only) cannot fix them.
    # Route each to its real manual step instead of the settings catch-all.
    push-protection/secret_scan_ci_job_present)
      report_skip "$repo" "$check" \
        "Adding the \`secret-scan\` gitleaks job to \`.github/workflows/ci.yml\` requires \`workflow\` token scope — copy the CI secret-scan job from standards/push-protection.md using a PAT"
      ;;
    push-protection/gitignore_baseline)
      remediate_gitignore_baseline "$repo" "$check"
      ;;
    push-protection/*)
      report_skip "$repo" "$check" \
        "Push protection settings require security_and_analysis API scope — run scripts/apply-repo-settings.sh"
      ;;
    standards/missing-claude-md | standards/claude-md-missing-agents-ref)
      report_skip "$repo" "$check" \
        "CLAUDE.md creation/update requires content knowledge — trigger Claude agent on the finding issue"
      ;;
    standards/missing-agents-md | standards/agents-md-missing-org-ref)
      report_skip "$repo" "$check" \
        "AGENTS.md creation/update requires content knowledge — trigger Claude agent on the finding issue"
      ;;
    standards/missing-copilot-instructions | standards/copilot-instructions-missing-*)
      report_skip "$repo" "$check" \
        "\`.github/copilot-instructions.md\` must be created from standards/copilot-instructions-standard.md and tailored to the repo's stack — trigger Claude agent on the finding issue"
      ;;
    settings/check-suite-prefs-unreadable)
      report_skip "$repo" "$check" \
        "Check-suite prefs unreadable — verify GH_TOKEN has repo scope and retry"
      ;;
    settings/repo_metadata_unavailable)
      report_skip "$repo" "$check" \
        "Repo metadata unavailable during audit — retry on the next audit run"
      ;;
    *)
      report_skip "$repo" "$check" \
        "No automatic remediation available for category=$category — review manually"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  if [ -z "$FINDINGS_FILE" ]; then
    err "FINDINGS_FILE is required — set it to the path of findings.json from compliance-audit.sh"
    exit 1
  fi

  if [ ! -f "$FINDINGS_FILE" ]; then
    err "FINDINGS_FILE not found: $FINDINGS_FILE"
    exit 1
  fi

  if [ -z "${GH_TOKEN:-}" ]; then
    err "GH_TOKEN is required"
    exit 1
  fi

  export GH_TOKEN

  info "Starting compliance remediation"
  info "Findings file:  $FINDINGS_FILE"
  info "Report dir:     $REPORT_DIR"
  info "Dry run:        $DRY_RUN"

  mkdir -p "$REPORT_DIR"

  # Initialize report files
  cat > "$REMEDIATION_REPORT" <<'HEADER'
# Compliance Remediation Report

| Repository | Finding | Method | Action |
|------------|---------|--------|--------|
HEADER

  cat > "$SKIPPED_REPORT" <<'HEADER'
# Skipped / Failed Findings

These findings were not automatically remediated and require manual intervention
or a Claude agent to address.

| Repository | Finding | Reason |
|------------|---------|--------|
HEADER

  # Read all findings and group by repo
  local repos jq_stderr
  if ! repos=$(jq -r '[.[].repo] | unique[]' "$FINDINGS_FILE" 2>/tmp/_cr_jq_err); then
    jq_stderr=$(cat /tmp/_cr_jq_err 2>/dev/null || true)
    err "Failed to parse FINDINGS_FILE ($FINDINGS_FILE): $jq_stderr"
    exit 1
  fi

  if [ -z "$repos" ]; then
    info "No findings to remediate — nothing to do"
    exit 0
  fi

  for repo in $repos; do
    info "--- Remediating findings for $ORG/$repo ---"

    while IFS= read -r finding; do
      [ -z "$finding" ] && continue

      local category check
      category=$(echo "$finding" | jq -r '.category')
      check=$(echo "$finding" | jq -r '.check')

      info "  Processing: $category/$check"
      remediate_finding "$repo" "$category" "$check" || {
        err "Unhandled error remediating $category/$check in $repo"
        report_fail "$repo" "$check" "Unhandled script error"
      }
    done < <(jq -c --arg repo "$repo" '.[] | select(.repo == $repo)' "$FINDINGS_FILE")
  done

  # Final summary
  local total=$((remediated_direct + remediated_pr + skipped_count + failed_count))
  info "=== Remediation complete ==="
  info "  Direct fixes applied: $remediated_direct"
  info "  PRs opened:           $remediated_pr"
  info "  Skipped:              $skipped_count"
  info "  Failed:               $failed_count"
  info "  Total processed:      $total"

  cat >> "$REMEDIATION_REPORT" <<SUMMARY

## Summary

| Metric | Count |
|--------|-------|
| Direct API fixes | $remediated_direct |
| PRs opened | $remediated_pr |
| Skipped (manual required) | $skipped_count |
| Failed | $failed_count |
| **Total processed** | **$total** |

*Generated by \`scripts/compliance-remediate.sh\` on $(date -u "+%Y-%m-%d %H:%M UTC").*
SUMMARY

  echo "remediation_report=$REMEDIATION_REPORT"
  echo "skipped_report=$SKIPPED_REPORT"
  echo "remediated_direct=$remediated_direct"
  echo "remediated_pr=$remediated_pr"
  echo "skipped=$skipped_count"
  echo "failed=$failed_count"

  cat "$REMEDIATION_REPORT"

  if [ "$skipped_count" -gt 0 ] || [ "$failed_count" -gt 0 ]; then
    echo ""
    cat "$SKIPPED_REPORT"
  fi

  # Exit non-zero only if there were unexpected failures (skips are normal)
  [ "$failed_count" -gt 0 ] && exit 1 || exit 0
}

main "$@"
