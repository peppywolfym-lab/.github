#!/usr/bin/env bash
# org_report.sh — programmatic markdown report builder for daily org status.
# Sourced by org_status.sh after data collection completes.
#
# Required env vars (all set by org_status.sh):
#   ALL_PRS, PR_BY_REPO, NEEDS_REVIEW_PRS, ISSUE_PR_MAP,
#   MERGE_DAILY, MERGE_BY_REPO_DAY, ISSUES_BY_REPO_TRIMMED,
#   DISCUSSIONS, TODAY, NEEDS_REBASE_COUNT, ISSUE_LIMIT

# fmt_month_day <YYYY-MM-DD> → "Mon-DD"
fmt_month_day() {
  date -u -d "$1" +"%b-%d" 2>/dev/null || date -u -jf "%Y-%m-%d" "$1" +"%b-%d"
}

# ci_label <ci_value> → "PASS" | "FAIL" | "PENDING" | "N/A"
ci_label() {
  case "$1" in
    SUCCESS)           printf 'PASS'    ;;
    FAILURE|ERROR)     printf 'FAIL'    ;;
    PENDING|EXPECTED)  printf 'PENDING' ;;
    *)                 printf 'N/A'     ;;
  esac
}

# ── Section: Org Summary ──────────────────────────────────────────────────────
section_org_summary() {
  local total_prs total_issues total_merges open_discussions
  total_prs=$(printf '%s' "$ALL_PRS" | jq 'length')
  total_issues=$(printf '%s' "$ISSUES_BY_REPO_TRIMMED" | jq '[.[].count] | add // 0')
  total_merges=$(printf '%s' "$MERGE_DAILY" | jq '[.[].org] | add // 0')
  open_discussions=$(printf '%s' "$DISCUSSIONS" | jq '[.[].discussions | length] | add // 0')

  printf '## Org Summary — %s\n\n' "$TODAY"
  printf '| Metric | Value |\n|---|---|\n'
  printf '| Total open PRs | %s |\n'           "$total_prs"
  printf '| PRs needing rebase | %s |\n'        "$NEEDS_REBASE_COUNT"
  printf '| Total open issues | %s |\n'         "$total_issues"
  printf '| PR merges (last 8 days) | %s |\n'   "$total_merges"
  printf '| Open discussions | %s |\n\n'        "$open_discussions"

  # Mermaid pie chart — PR categories
  printf '```mermaid\npie title Open PRs by Status\n'
  printf '%s' "$PR_BY_REPO" | jq -r '
    {
      "Draft":              ([.[].draft]             | add // 0),
      "CI Failing":         ([.[].ci_failing]        | add // 0),
      "CI Pending":         ([.[].ci_pending]        | add // 0),
      "Changes Requested":  ([.[].changes_requested] | add // 0),
      "Approved":           ([.[].approved]          | add // 0),
      "Awaiting Review":    ([.[].awaiting_review]   | add // 0),
      "No CI / No Policy":  ([.[].no_ci_policy]      | add // 0)
    } | to_entries | map(select(.value > 0)) | sort_by(-.value)[] |
    "    \"" + .key + "\" : " + (.value | tostring)'
  printf '```\n\n'
}

# ── Section: Open PRs — Why They're Unmerged ─────────────────────────────────
section_open_prs() {
  local total_prs
  total_prs=$(printf '%s' "$ALL_PRS" | jq 'length')
  printf "## Open PRs — Why They're Unmerged (%s total)\n\n" "$total_prs"

  # Org-wide category bar chart
  local chart_data labels values
  chart_data=$(printf '%s' "$PR_BY_REPO" | jq -c '
    {
      "Draft":              ([.[].draft]             | add // 0),
      "CI Failing":         ([.[].ci_failing]        | add // 0),
      "CI Pending":         ([.[].ci_pending]        | add // 0),
      "Changes Requested":  ([.[].changes_requested] | add // 0),
      "Approved":           ([.[].approved]          | add // 0),
      "Awaiting Review":    ([.[].awaiting_review]   | add // 0),
      "No CI / No Policy":  ([.[].no_ci_policy]      | add // 0)
    } | to_entries | map(select(.value > 0)) | sort_by(-.value)')
  labels=$(printf '%s' "$chart_data" | jq -r 'map("\"" + .key + "\"") | join(", ")')
  values=$(printf '%s' "$chart_data" | jq -r 'map(.value | tostring) | join(", ")')

  printf '```mermaid\nxychart-beta\n'
  printf '    title "Open PRs by Blocker Category"\n'
  printf '    x-axis [%s]\n' "$labels"
  printf '    y-axis "Count"\n'
  printf '    bar [%s]\n' "$values"
  printf '```\n\n'

  # Per-repo grouped bar chart — 4 key categories, repos sorted by total desc
  local repos_sorted short_names nc_vals ar_vals cf_vals ap_vals
  repos_sorted=$(printf '%s' "$PR_BY_REPO" | jq -c 'map(select(.total > 0)) | sort_by(-.total)')
  short_names=$(printf '%s' "$repos_sorted" | jq -r 'map("\"" + (.repo | split("/")[1]) + "\"") | join(", ")')
  nc_vals=$(printf '%s' "$repos_sorted" | jq -r 'map(.no_ci_policy  | tostring) | join(", ")')
  ar_vals=$(printf '%s' "$repos_sorted" | jq -r 'map(.awaiting_review | tostring) | join(", ")')
  cf_vals=$(printf '%s' "$repos_sorted" | jq -r 'map(.ci_failing    | tostring) | join(", ")')
  ap_vals=$(printf '%s' "$repos_sorted" | jq -r 'map(.approved      | tostring) | join(", ")')

  printf '```mermaid\nxychart-beta\n'
  printf '    title "Open PRs per Repo by Category"\n'
  printf '    x-axis [%s]\n' "$short_names"
  printf '    y-axis "PRs"\n'
  printf '    bar [%s]\n' "$nc_vals"
  printf '    bar [%s]\n' "$ar_vals"
  printf '    bar [%s]\n' "$cf_vals"
  printf '    bar [%s]\n' "$ap_vals"
  printf '```\n\n'
}

# ── Section: PR Merge Activity ────────────────────────────────────────────────
section_merge_activity() {
  printf '## PR Merge Activity — Last 8 Days\n\n'

  # Daily bar chart — build label/value arrays via bash loop (needs fmt_month_day)
  local date_labels="" daily_counts=""
  while IFS=$'\t' read -r d c; do
    local lbl
    lbl=$(fmt_month_day "$d")
    date_labels="${date_labels}\"${lbl}\","
    daily_counts="${daily_counts}${c},"
  done < <(printf '%s' "$MERGE_DAILY" | jq -r '.[] | [.date, (.org | tostring)] | @tsv')
  date_labels="${date_labels%,}"
  daily_counts="${daily_counts%,}"

  printf '```mermaid\nxychart-beta\n'
  printf '    title "petry-projects Merges — Last 8 Days"\n'
  printf '    x-axis [%s]\n' "$date_labels"
  printf '    y-axis "Merges"\n'
  printf '    bar [%s]\n' "$daily_counts"
  printf '```\n\n'

  # Per-repo per-day table
  local -a dates_arr
  mapfile -t dates_arr < <(printf '%s' "$MERGE_DAILY" | jq -r '.[].date')

  # Build header
  local header_dates="" sep_dates=""
  for d in "${dates_arr[@]}"; do
    local hdr
    hdr=$(fmt_month_day "$d")
    header_dates="${header_dates} ${hdr} |"
    sep_dates="${sep_dates}---|"
  done
  printf '| Repo |%s Total |\n' "$header_dates"
  printf '|---|%s---|\n' "$sep_dates"

  # Accumulate column totals
  local -a date_totals
  for _ in "${dates_arr[@]}"; do date_totals+=(0); done
  local grand_total=0

  while IFS= read -r row; do
    local repo row_total
    repo=$(printf '%s' "$row" | jq -r '.repo')
    row_total=$(printf '%s' "$row" | jq -r '.total')
    [[ "$row_total" =~ ^[0-9]+$ ]] && [ "$row_total" -eq 0 ] && continue

    printf '| [%s](https://github.com/%s) |' "$repo" "$repo"
    local i=0
    for d in "${dates_arr[@]}"; do
      local cnt
      cnt=$(printf '%s' "$row" | jq -r --arg d "$d" '.by_date[$d] // 0')
      printf ' %s |' "$cnt"
      date_totals[$i]=$(( ${date_totals[$i]} + cnt ))
      i=$(( i + 1 ))
    done
    grand_total=$(( grand_total + row_total ))
    printf ' **%s** |\n' "$row_total"
  done < <(printf '%s' "$MERGE_BY_REPO_DAY" | jq -c '.[]')

  # Grand total row
  printf '| **TOTAL** |'
  for cnt in "${date_totals[@]}"; do
    printf ' %s |' "$cnt"
  done
  printf ' **%s** |\n\n' "$grand_total"

  # Trend sentence
  local -a counts_arr
  mapfile -t counts_arr < <(printf '%s' "$MERGE_DAILY" | jq -r '.[].org')
  local n=${#counts_arr[@]}
  if [ "$n" -ge 6 ]; then
    local first3=0 last3=0
    first3=$(( ${counts_arr[0]} + ${counts_arr[1]} + ${counts_arr[2]} ))
    last3=$(( ${counts_arr[n-3]} + ${counts_arr[n-2]} + ${counts_arr[n-1]} ))
    local trend="Flat"
    [ "$last3" -gt "$first3" ] && trend="Increasing"
    [ "$last3" -lt "$first3" ] && trend="Decreasing"
    printf 'Grand total: **%s** merges over 8 days. Trend: **%s**.\n\n' "$grand_total" "$trend"
  fi
}

# ── Section: PRs Needing Human Review ────────────────────────────────────────
section_needs_review() {
  printf '## Open PRs — Needs Human Review\n\n'

  local count
  count=$(printf '%s' "$NEEDS_REVIEW_PRS" | jq 'length')
  if [ "$count" -eq 0 ]; then
    printf '_none_\n\n'
    return
  fi

  printf '| Repo | PR | Opened | CI | Approvals |\n|---|---|---|---|---|\n'
  while IFS= read -r pr; do
    local repo number title url opened ci approvals
    repo=$(printf '%s' "$pr" | jq -r '.repo')
    number=$(printf '%s' "$pr" | jq -r '.number')
    title=$(printf '%s' "$pr" | jq -r '.title | gsub("[|]"; "\\|")')
    url=$(printf '%s' "$pr" | jq -r '.url')
    opened=$(printf '%s' "$pr" | jq -r '.opened')
    ci=$(printf '%s' "$pr" | jq -r '.ci // ""')
    approvals=$(printf '%s' "$pr" | jq -r '.approvals')
    printf '| %s | [#%s — %s](%s) | %s | %s | %s |\n' \
      "$repo" "$number" "$title" "$url" "$opened" "$(ci_label "$ci")" "$approvals"
  done < <(printf '%s' "$NEEDS_REVIEW_PRS" | jq -c 'sort_by(.opened) | .[]')
  printf '\n'
}

# ── Section: Dependency Bumps ─────────────────────────────────────────────────
section_dep_bumps() {
  printf '## Open PRs — Automation (Dependency Bumps)\n\n'

  local rows
  rows=$(printf '%s' "$PR_BY_REPO" | jq -r 'map(select(.dep_bumps > 0)) | sort_by(-.dep_bumps)[] |
    [.repo, (.dep_bumps | tostring)] | @tsv')

  if [ -z "$rows" ]; then
    printf '_none_\n\n'
    return
  fi

  printf '| Repo | # Dep PRs |\n|---|---|\n'
  while IFS=$'\t' read -r repo cnt; do
    printf '| [%s](https://github.com/%s) | %s |\n' "$repo" "$repo" "$cnt"
  done <<< "$rows"
  printf '\n'
}

# ── Section: Open Issues ──────────────────────────────────────────────────────
section_open_issues() {
  local total_issues
  total_issues=$(printf '%s' "$ISSUES_BY_REPO_TRIMMED" | jq '[.[].count] | add // 0')
  printf '## Open Issues (%s total)\n\n' "$total_issues"

  local count
  count=$(printf '%s' "$ISSUES_BY_REPO_TRIMMED" | jq 'length')
  if [ "$count" -eq 0 ]; then
    printf '_none_\n\n'
    return
  fi

  while IFS= read -r repo_block; do
    local repo issue_count truncated
    repo=$(printf '%s' "$repo_block" | jq -r '.repo')
    issue_count=$(printf '%s' "$repo_block" | jq -r '.count')
    truncated=$(printf '%s' "$repo_block" | jq -r '.truncated')

    if [ "$truncated" = "true" ]; then
      printf '### [%s](https://github.com/%s) (showing %s of %s issues)\n\n' \
        "$repo" "$repo" "$ISSUE_LIMIT" "$issue_count"
    else
      printf '### [%s](https://github.com/%s) (%s issues)\n\n' \
        "$repo" "$repo" "$issue_count"
    fi

    printf '| Issue | Opened | Labels | Linked PR |\n|---|---|---|---|\n'
    while IFS= read -r issue; do
      local number title url opened labels linked_pr
      number=$(printf '%s' "$issue" | jq -r '.number')
      title=$(printf '%s' "$issue" | jq -r '.title | gsub("[|]"; "\\|")')
      url=$(printf '%s' "$issue" | jq -r '.url')
      opened=$(printf '%s' "$issue" | jq -r '.createdAt | split("T")[0]')
      labels=$(printf '%s' "$issue" | jq -r '[.labels[].name] | join(", ")')
      linked_pr=$(printf '%s' "$ISSUE_PR_MAP" | jq -r \
        --arg key "${repo}#${number}" \
        'if has($key) then [.[$key][] | "[#" + (.number|tostring) + "](" + .url + ")"] | join(", ") else "—" end')
      printf '| [#%s — %s](%s) | %s | %s | %s |\n' \
        "$number" "$title" "$url" "$opened" "${labels:- }" "$linked_pr"
    done < <(printf '%s' "$repo_block" | jq -c '.issues[]')
    printf '\n'
  done < <(printf '%s' "$ISSUES_BY_REPO_TRIMMED" | jq -c '.[]')
}

# ── Section: Open Discussions ─────────────────────────────────────────────────
section_open_discussions() {
  printf '## Open Discussions\n\n'

  local total
  total=$(printf '%s' "$DISCUSSIONS" | jq '[.[].discussions | length] | add // 0')
  if [ "$total" -eq 0 ]; then
    printf '_none_\n\n'
    return
  fi

  printf '| Repo | Discussion | Opened | Replies |\n|---|---|---|---|\n'
  while IFS= read -r repo_block; do
    local repo
    repo=$(printf '%s' "$repo_block" | jq -r '.repo')
    while IFS= read -r disc; do
      local number title url opened replies
      number=$(printf '%s' "$disc" | jq -r '.number')
      title=$(printf '%s' "$disc" | jq -r '.title | gsub("[|]"; "\\|")')
      url=$(printf '%s' "$disc" | jq -r '.url')
      opened=$(printf '%s' "$disc" | jq -r '.createdAt | split("T")[0]')
      replies=$(printf '%s' "$disc" | jq -r '.comments.totalCount')
      printf '| %s | [#%s — %s](%s) | %s | %s |\n' \
        "$repo" "$number" "$title" "$url" "$opened" "$replies"
    done < <(printf '%s' "$repo_block" | jq -c '.discussions[]')
  done < <(printf '%s' "$DISCUSSIONS" | jq -c '.[]')
  printf '\n'
}

# ── Entry Point ───────────────────────────────────────────────────────────────
# generate_org_report — writes the complete daily org status report to stdout
generate_org_report() {
  printf '@org-leads\n\n'
  section_org_summary
  section_open_prs
  section_merge_activity
  section_needs_review
  section_dep_bumps
  section_open_issues
  section_open_discussions
}
