#!/usr/bin/env bash
# Org-wide SonarCloud audit → idempotent GitHub issues.
#
# Scans every SonarCloud project in the organization, groups open findings
# per (GitHub repo × rule-family workstream), and creates/updates/closes one
# GitHub issue per group. Issues carry:
#   - dev-lead            → autonomous remediation pickup (all findings)
#   - sonarcloud-audit    → marker label for idempotent listing/closing
#   - priority:<severity> → prioritization from the bucket's worst Sonar severity
#   - security            → when the family or any finding is a vulnerability
#
# Idempotency: one issue per (repo, family), keyed by a STABLE title
# "SonarCloud: <family title>". Re-runs update the body/comment and re-trigger
# dev-lead on persistent findings; groups that drop to zero are auto-closed.
#
# Env:
#   ORG            GitHub owner            (default: petry-projects)
#   SONAR_ORG      SonarCloud organization (default: petry-projects)
#   SONAR_URL      SonarCloud base URL     (default: https://sonarcloud.io)
#   SONAR_TOKEN    optional; enables auth (private projects, higher rate limits)
#   REPORT_DIR     output dir              (default: mktemp -d)
#   TARGET_REPO    limit to one repo (owner/name or name); blank = all
#   DRY_RUN        "true" → scan + report, no issue writes   (default: false)
#   CREATE_ISSUES  "true" → manage issues                    (default: true)
#
# Standard: https://github.com/<owner>/.github/tree/main/standards
set -euo pipefail

ORG="${ORG:-petry-projects}"
SONAR_ORG="${SONAR_ORG:-petry-projects}"
SONAR_URL="${SONAR_URL:-https://sonarcloud.io}"
SONAR_AUDIT_LABEL="sonarcloud-audit"
DRY_RUN="${DRY_RUN:-false}"
CREATE_ISSUES="${CREATE_ISSUES:-true}"
TARGET_REPO="${TARGET_REPO:-}"
REPORT_DIR="${REPORT_DIR:-$(mktemp -d)}"

FINDINGS_FILE="$REPORT_DIR/findings.json"
GROUPS_FILE="$REPORT_DIR/groups.json"
SUMMARY_FILE="$REPORT_DIR/summary.md"
COUNTS_FILE="$REPORT_DIR/issue-counts.json"

ISSUES_ADDED=0
ISSUES_EXISTING=0
ISSUES_RETRIGGERED=0
ISSUES_REMOVED=0

# Shared dev-lead retrigger helpers — dl_dev_lead_active() and
# dl_cycle_trigger_label(). Only sourced when present (skipped under bats).
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/dev-lead-retrigger.sh"
# shellcheck source=/dev/null
[ -f "$_LIB" ] && source "$_LIB"

info() { echo "[info] $*" >&2; }
warn() { echo "[warn] $*" >&2; }

# ---------------------------------------------------------------------------
# Pure helpers (unit-tested via bats; keep free of side effects)
# ---------------------------------------------------------------------------

# Map a SonarCloud project key → GitHub repo name.
# Strips the "<org>_" prefix; a small override table handles projects whose
# key diverges from the repo (e.g. a re-provisioned project with a "2" suffix).
sonar_project_to_repo() {
  local key="$1"
  local stripped="${key#"${SONAR_ORG}"_}"
  case "$stripped" in
    broodminder-export2) echo "broodminder-export" ;;
    *)                   echo "$stripped" ;;
  esac
}

# Classify a Sonar rule into a stable workstream family.
# Ordering matters: more specific rules first.
classify_workstream() {
  case "$1" in
    githubactions:S7635)                 echo "s7635" ;;
    githubactions:S1135)                 echo "misc" ;;
    githubactions:*|text:S8564|text:S8565) echo "ghactions" ;;
    shelldre:*)                          echo "shell" ;;
    pythonsecurity:*)                    echo "pysec" ;;
    *:S3776)                             echo "complexity" ;;
    javascript:S5906)                    echo "tests" ;;
    javascript:*|typescript:*)           echo "jsquality" ;;
    *)                                   echo "misc" ;;
  esac
}

# Human-readable title for a family (used verbatim in the stable issue title).
family_title() {
  case "$1" in
    s7635)      echo "S7635 secrets-inherit caller stubs" ;;
    ghactions)  echo "GitHub Actions / dependency hardening" ;;
    pysec)      echo "code security review (pythonsecurity)" ;;
    complexity) echo "cognitive complexity (S3776)" ;;
    shell)      echo "shell script hygiene" ;;
    tests)      echo "test assertion quality (S5906)" ;;
    jsquality)  echo "JavaScript/TypeScript code quality" ;;
    *)          echo "miscellaneous findings" ;;
  esac
}

# Families that are inherently security-relevant (get the `security` label even
# when Sonar classifies the item as a CODE_SMELL).
family_is_security() {
  case "$1" in
    s7635|ghactions|pysec) return 0 ;;
    *)                     return 1 ;;
  esac
}

# Stable idempotency key, embedded as a hidden HTML comment in each issue body.
# Keyed on repo/family so matching survives human title edits and lets the audit
# ADOPT (rather than duplicate) a pre-existing issue that carries the marker.
# args: <repo> <family>
issue_marker() {
  echo "<!-- sonarcloud-audit:key=$1/$2 -->"
}

# Numeric rank for a Sonar severity (higher = worse). Used to pick a bucket's
# worst severity for its priority label.
severity_rank() {
  case "$1" in
    BLOCKER)  echo 5 ;;
    CRITICAL) echo 4 ;;
    MAJOR)    echo 3 ;;
    MINOR)    echo 2 ;;
    INFO)     echo 1 ;;
    *)        echo 0 ;;
  esac
}

# Map a Sonar severity → prioritization label (faithful 1:1 with Sonar's scale).
severity_priority_label() {
  case "$1" in
    BLOCKER)  echo "priority:blocker" ;;
    CRITICAL) echo "priority:critical" ;;
    MAJOR)    echo "priority:major" ;;
    MINOR)    echo "priority:minor" ;;
    INFO)     echo "priority:info" ;;
    *)        echo "priority:minor" ;;
  esac
}

# Hex color for a priority label (escalating red→grey).
priority_label_color() {
  case "$1" in
    priority:blocker)  echo "b60205" ;;
    priority:critical) echo "d93f0b" ;;
    priority:major)    echo "fbca04" ;;
    priority:minor)    echo "0e8a16" ;;
    priority:info)     echo "c5def5" ;;
    *)                 echo "ededed" ;;
  esac
}

# ---------------------------------------------------------------------------
# SonarCloud API
# ---------------------------------------------------------------------------
_sonar_get() {
  local path="$1"
  local auth=()
  [ -n "${SONAR_TOKEN:-}" ] && auth=(-u "${SONAR_TOKEN}:")
  curl -sf "${auth[@]}" "${SONAR_URL}${path}"
}

# Echo the list of SonarCloud project keys in the org.
sonar_list_projects() {
  local page=1 resp total page_count
  while :; do
    resp=$(_sonar_get "/api/components/search?organization=${SONAR_ORG}&qualifiers=TRK&ps=500&p=${page}") \
      || { warn "sonar_list_projects: page ${page} fetch failed — results may be incomplete"; return 1; }
    echo "$resp" | jq -r '.components[].key'
    total=$(echo "$resp" | jq '.paging.total')
    page_count=$(echo "$resp" | jq '.components | length')
    { [ "$((page * 500))" -ge "$total" ] || [ "$page_count" -eq 0 ]; } && break
    page=$((page + 1))
  done
}

# Fetch all open issues for a project as a JSON array (paginated).
sonar_project_issues() {
  local key="$1" page=1 out="[]" resp total fetched=0
  while :; do
    resp=$(_sonar_get "/api/issues/search?organization=${SONAR_ORG}&componentKeys=${key}&resolved=false&ps=500&p=${page}") \
      || { warn "sonar_project_issues: page ${page} fetch failed for ${key} — results may be incomplete"; return 1; }
    total=$(echo "$resp" | jq '.total')
    out=$(jq -s '.[0] + .[1]' <(echo "$out") <(echo "$resp" | jq '.issues'))
    fetched=$(echo "$out" | jq 'length')
    { [ "$fetched" -ge "$total" ] || [ "$(echo "$resp" | jq '.issues | length')" -eq 0 ]; } && break
    page=$((page + 1))
    [ "$page" -gt 40 ] && break   # 20k-issue backstop
  done
  echo "$out"
}

# ---------------------------------------------------------------------------
# Scan: build findings.json (flat) then groups.json (per repo × family)
# ---------------------------------------------------------------------------
scan() {
  local target_name=""
  if [ -n "$TARGET_REPO" ]; then
    target_name="${TARGET_REPO#"$ORG/"}"
  fi

  local ndjson_file="$REPORT_DIR/findings.ndjson"
  : > "$ndjson_file"
  local project repo issues family

  for project in $(sonar_list_projects); do
    repo=$(sonar_project_to_repo "$project")
    [ -n "$target_name" ] && [ "$repo" != "$target_name" ] && continue
    info "Scanning $project -> $repo"
    issues=$(sonar_project_issues "$project")

    # Emit one NDJSON object per issue with its computed family.
    while IFS= read -r row; do
      [ -z "$row" ] && continue
      local rule sev typ msg comp
      rule=$(echo "$row" | jq -r '.rule')
      sev=$(echo "$row" | jq -r '.severity // "MINOR"')
      typ=$(echo "$row" | jq -r '.type // "CODE_SMELL"')
      msg=$(echo "$row" | jq -r '.message // ""')
      comp=$(echo "$row" | jq -r '.component // "" | sub("^[^:]+:";"")')
      family=$(classify_workstream "$rule")
      jq -n --arg repo "$repo" --arg project "$project" --arg rule "$rule" \
         --arg severity "$sev" --arg type "$typ" --arg family "$family" \
         --arg message "$msg" --arg file "$comp" \
         '{repo:$repo,project:$project,rule:$rule,severity:$severity,type:$type,family:$family,message:$message,file:$file}' \
         >> "$ndjson_file"
    done < <(echo "$issues" | jq -c '.[]')
  done

  # Convert NDJSON to a JSON array in a single O(n) pass.
  if [ -s "$ndjson_file" ]; then
    jq -s '.' "$ndjson_file" > "$FINDINGS_FILE"
  else
    echo "[]" > "$FINDINGS_FILE"
  fi

  # Aggregate into per (repo, family) groups.
  jq '
    def sevrank: {"BLOCKER":5,"CRITICAL":4,"MAJOR":3,"MINOR":2,"INFO":1}[.] // 0;
    sort_by(.repo, .family) | group_by([.repo, .family])
    | map({
        repo: .[0].repo,
        project: .[0].project,
        family: .[0].family,
        count: length,
        has_vuln: (any(.[]; .type == "VULNERABILITY")),
        max_severity: (max_by(.severity | sevrank) | .severity),
        rules: (sort_by(.rule) | group_by(.rule) | map({rule: .[0].rule, count: length, message: .[0].message}) | sort_by(-.count)),
        files: (sort_by(.file) | group_by(.file) | map({file: .[0].file, count: length}) | sort_by(-.count))
      })
    | sort_by(.repo, .family)
  ' "$FINDINGS_FILE" > "$GROUPS_FILE"
}

# ---------------------------------------------------------------------------
# Issue management
# ---------------------------------------------------------------------------
ensure_labels() {
  local repo="$1"
  local specs=(
    "sonarcloud-audit|1f6feb|SonarCloud audit finding (idempotent marker)"
    "dev-lead|8B5CF6|For dev-lead agent pickup"
    "security|d93f0b|Security-related PRs and issues"
    "priority:blocker|b60205|SonarCloud BLOCKER severity"
    "priority:critical|d93f0b|SonarCloud CRITICAL severity"
    "priority:major|fbca04|SonarCloud MAJOR severity"
    "priority:minor|0e8a16|SonarCloud MINOR severity"
    "priority:info|c5def5|SonarCloud INFO severity"
  )
  local name color desc
  for spec in "${specs[@]}"; do
    IFS='|' read -r name color desc <<< "$spec"
    gh label create "$name" --repo "$ORG/$repo" --color "$color" \
      --description "$desc" --force 2>/dev/null || true
  done
}

# Render the issue body (dashboard) for a group JSON object.
render_body() {
  local group="$1"
  local repo family project count max_sev title
  repo=$(echo "$group" | jq -r '.repo')
  family=$(echo "$group" | jq -r '.family')
  project=$(echo "$group" | jq -r '.project')
  count=$(echo "$group" | jq -r '.count')
  max_sev=$(echo "$group" | jq -r '.max_severity')
  title=$(family_title "$family")

  local rules_tbl files_tbl
  rules_tbl=$(echo "$group" | jq -r '
    .rules[] | "| [\(.rule)](https://rules.sonarsource.com/\(.rule | split(":")[0])/RULE/\(.rule | split(":")[1])/) | \(.count) | \((.message // "")[0:90] | gsub("\\|";"\\\\|")) |"')
  files_tbl=$(echo "$group" | jq -r '.files[0:20][] | "- `\(.file)` (\(.count))"')

  cat <<BODY
## SonarCloud: ${title}

**${count}** open SonarCloud finding(s) in \`${ORG}/${repo}\`, worst severity **${max_sev}**. Generated by the org [SonarCloud Audit](https://github.com/${ORG}/.github/blob/main/.github/workflows/sonarcloud-audit.yml).

[View in SonarCloud →](${SONAR_URL}/project/issues?id=${project}&resolved=false)

### Findings
| Rule | Count | Representative message |
|---|---:|---|
${rules_tbl}

### Affected files
${files_tbl}

### Priority
Labeled \`$(severity_priority_label "$max_sev")\` — mapped from this bucket's worst SonarCloud severity (\`${max_sev}\`).

### Acceptance
- [ ] All findings in this workstream resolved to zero in SonarCloud
- [ ] No behavior change; CI green
- [ ] Real fixes (no blanket \`NOSONAR\` unless a confirmed false positive, noted inline)

---
*Idempotent issue — updated automatically each audit run; auto-closed when the finding count reaches zero.*

$(issue_marker "$repo" "$family")
BODY
}

# Create or update the issue for a single group.
manage_group_issue() {
  local group="$1"
  local repo family title stable_title max_sev prio labels
  repo=$(echo "$group" | jq -r '.repo')
  family=$(echo "$group" | jq -r '.family')
  max_sev=$(echo "$group" | jq -r '.max_severity')
  stable_title="SonarCloud: $(family_title "$family")"
  prio=$(severity_priority_label "$max_sev")

  labels="$SONAR_AUDIT_LABEL,dev-lead,$prio"
  if family_is_security "$family" || [ "$(echo "$group" | jq -r '.has_vuln')" = "true" ]; then
    labels="$labels,security"
  fi

  local body
  body=$(render_body "$group")

  if [ "$DRY_RUN" = "true" ] || [ "$CREATE_ISSUES" != "true" ]; then
    info "[dry-run] $repo :: $stable_title [$labels]"
    return
  fi

  ensure_labels "$repo"

  # Match on the hidden body marker (repo/family), not the human title — robust
  # to title edits and lets the audit adopt a pre-existing marker-bearing issue.
  local existing marker
  marker="sonarcloud-audit:key=${repo}/${family}"
  existing=$(gh issue list --repo "$ORG/$repo" --label "$SONAR_AUDIT_LABEL" --state open \
    --json number,body --limit 200 2>/dev/null \
    | jq -r --arg m "$marker" '.[] | select((.body // "") | contains($m)) | .number' 2>/dev/null | head -1 || echo "")

  if [ -n "$existing" ]; then
    # Refresh the dashboard body + ensure current priority label, drop stale ones.
    gh issue edit "$existing" --repo "$ORG/$repo" --body "$body" \
      --add-label "$prio" 2>/dev/null || true
    local other
    for other in priority:blocker priority:critical priority:major priority:minor priority:info; do
      [ "$other" != "$prio" ] && gh issue edit "$existing" --repo "$ORG/$repo" \
        --remove-label "$other" 2>/dev/null || true
    done
    gh issue comment "$existing" --repo "$ORG/$repo" \
      --body "**SonarCloud Audit** ($(date -u +%Y-%m-%d)): still open — $(echo "$group" | jq -r '.count') finding(s), worst severity \`${max_sev}\`." 2>/dev/null || true
    ISSUES_EXISTING=$((ISSUES_EXISTING + 1))
    info "Updated #$existing in $repo :: $stable_title"

    # Re-engage dev-lead on persistent findings (cycle the trigger label unless
    # dev-lead is already working the issue).
    if declare -f dl_dev_lead_active >/dev/null 2>&1 && dl_dev_lead_active "$ORG" "$repo" "$existing"; then
      info "#$existing in $repo — dev-lead already active, not re-triggering"
    elif declare -f dl_cycle_trigger_label >/dev/null 2>&1 && dl_cycle_trigger_label "$ORG" "$repo" "$existing" "dev-lead" "$DRY_RUN"; then
      ISSUES_RETRIGGERED=$((ISSUES_RETRIGGERED + 1))
    else
      gh issue edit "$existing" --repo "$ORG/$repo" --add-label "dev-lead" 2>/dev/null || true
    fi
    return
  fi

  local url
  url=$(gh issue create --repo "$ORG/$repo" --title "$stable_title" \
    --label "$labels" --body "$body" 2>/dev/null || echo "")
  if [ -n "$url" ]; then
    ISSUES_ADDED=$((ISSUES_ADDED + 1))
    info "Created $url"
  else
    warn "Failed to create issue in $repo :: $stable_title"
  fi
}

# Close audit issues whose (repo, family) group no longer has findings.
# Reads the family from each issue's hidden body marker (not its title), so a
# renamed issue is still matched to its group.
close_resolved() {
  local repo="$1"
  local open_issues
  open_issues=$(gh issue list --repo "$ORG/$repo" --label "$SONAR_AUDIT_LABEL" --state open \
    --json number,body --limit 200 2>/dev/null \
    | jq -r '.[] | "\(.number)\t" + ((.body // "") | (try (capture("sonarcloud-audit:key=[^/]+/(?<fam>[a-z0-9]+)").fam) catch ""))' 2>/dev/null || echo "")
  [ -z "$open_issues" ] && return

  # Families currently present for this repo.
  local current_fams
  current_fams=$(jq -r --arg repo "$repo" '.[] | select(.repo == $repo) | .family' "$GROUPS_FILE" 2>/dev/null)

  local num fam
  while IFS=$'\t' read -r num fam; do
    [ -z "$num" ] && continue
    [ -z "$fam" ] && continue   # not a marker-bearing audit issue — leave it alone
    if ! echo "$current_fams" | grep -qxF "$fam"; then
      gh issue close "$num" --repo "$ORG/$repo" \
        --comment "Resolved! No open SonarCloud findings remain in this workstream as of $(date -u +%Y-%m-%d). Closing automatically." 2>/dev/null \
        && { ISSUES_REMOVED=$((ISSUES_REMOVED + 1)); info "Closed resolved #$num in $repo"; } || true
    fi
  done <<< "$open_issues"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
generate_summary() {
  local total repos_n
  total=$(jq 'length' "$FINDINGS_FILE")
  repos_n=$(jq '[.[].repo] | unique | length' "$FINDINGS_FILE")

  {
    echo "# SonarCloud Audit — $(date -u +%Y-%m-%d)"
    echo ""
    echo "**Org:** \`${SONAR_ORG}\` · **Open findings:** ${total} · **Repos with findings:** ${repos_n}"
    echo ""
    echo "## By severity"
    echo "| Severity | Count |"
    echo "|---|---:|"
    jq -r '
      def rank: {"BLOCKER":5,"CRITICAL":4,"MAJOR":3,"MINOR":2,"INFO":1}[.] // 0;
      group_by(.severity) | sort_by(-(.[0].severity | rank))
      | .[] | "| \(.[0].severity) | \(length) |"' "$FINDINGS_FILE"
    echo ""
    echo "## By repo × workstream (one issue each)"
    echo "| Repo | Workstream | Findings | Worst severity | Priority |"
    echo "|---|---|---:|---|---|"
    jq -c '.[]' "$GROUPS_FILE" | while IFS= read -r g; do
      local r f c s
      r=$(echo "$g" | jq -r '.repo'); f=$(family_title "$(echo "$g" | jq -r '.family')")
      c=$(echo "$g" | jq -r '.count'); s=$(echo "$g" | jq -r '.max_severity')
      echo "| $r | $f | $c | $s | $(severity_priority_label "$s") |"
    done
    echo ""
    echo "## Issue actions"
    echo "| Action | Count |"
    echo "|---|---:|"
    echo "| Added | $ISSUES_ADDED |"
    echo "| Updated | $ISSUES_EXISTING |"
    echo "| dev-lead re-triggered | $ISSUES_RETRIGGERED |"
    echo "| Closed (resolved) | $ISSUES_REMOVED |"
    echo ""
    echo "---"
    echo "*Generated by the SonarCloud Audit workflow.*"
  } > "$SUMMARY_FILE"
}

# ---------------------------------------------------------------------------
main() {
  mkdir -p "$REPORT_DIR"
  info "SonarCloud audit — org=$SONAR_ORG dry_run=$DRY_RUN create_issues=$CREATE_ISSUES"
  scan

  if [ "$CREATE_ISSUES" = "true" ] && [ "$DRY_RUN" != "true" ]; then
    while IFS= read -r group; do
      manage_group_issue "$group"
    done < <(jq -c '.[]' "$GROUPS_FILE")
    # Close resolved issues per repo that had (or previously had) findings.
    while IFS= read -r repo; do
      [ -n "$repo" ] && close_resolved "$repo"
    done < <(gh repo list "$ORG" --no-archived --limit 100 --json name -q '.[].name' 2>/dev/null || jq -r '[.[].repo]|unique[]' "$GROUPS_FILE")
  else
    while IFS= read -r group; do manage_group_issue "$group"; done < <(jq -c '.[]' "$GROUPS_FILE")
  fi

  jq -n --argjson added "$ISSUES_ADDED" --argjson existing "$ISSUES_EXISTING" \
        --argjson retriggered "$ISSUES_RETRIGGERED" --argjson removed "$ISSUES_REMOVED" \
        '{added:$added,existing:$existing,retriggered:$retriggered,removed:$removed}' > "$COUNTS_FILE"

  generate_summary
  info "Done. Findings: $(jq length "$FINDINGS_FILE"); groups: $(jq length "$GROUPS_FILE"); added=$ISSUES_ADDED existing=$ISSUES_EXISTING removed=$ISSUES_REMOVED"
}

# Guard: only run when executed directly (sourcing defines functions for bats).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
