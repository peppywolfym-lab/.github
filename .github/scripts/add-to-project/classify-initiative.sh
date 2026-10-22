#!/usr/bin/env bash
# classify-initiative.sh — assign the Initiative single-select field (and its
# rolled-up Theme) on Initiatives-project items that don't have one yet.
#
# Why this exists (petry-projects/.github#415): the add-to-project automation
# only ever places items ON the board (addProjectV2ItemById); nothing set the
# Initiative field, so nearly every item sat on the board unassociated with any
# initiative. This is the continuous, deterministic classifier that fills that
# gap — and its first run back-fills the existing blank items.
#
# Classification is RULE-DRIVEN, not AI: each item's title + labels + repo are
# flattened into a lowercase "signature" and matched against ordered regex
# rules (initiative-rules.tsv, first match wins). A matched item gets its
# Initiative set, plus the Theme that Initiative rolls up to
# (initiative-taxonomy.tsv). An item that matches NO rule is left blank and
# reported for triage — the classifier never guesses a bucket.
#
# Safety: this only ever writes per-item field VALUES
# (updateProjectV2ItemFieldValue via lib.sh's set_item_single_select_value).
# It never touches the field SCHEMA (updateProjectV2Field), so it cannot trip
# the single-select option-wipe footgun documented in
# standards/initiatives-project.md. By default it only fills items whose
# Initiative is currently empty, so a human's manual assignment is never
# overwritten; RECLASSIFY=all re-evaluates every item.
#
# Required env:
#   PROJECT_ID        ProjectV2 node ID of the Initiatives project
#   GH_TOKEN          Token with org Projects: Read+write
#
# Optional env:
#   PROJECT_URL       Logged in human-readable messages only
#   DRY_RUN=1         Log intended writes, mutate nothing
#   RECLASSIFY=all    Re-evaluate items that already have an Initiative
#   RULES_FILE        Override path to the rules TSV
#   TAXONOMY_FILE     Override path to the Initiative→Theme TSV
#   PAGE_SIZE         Items fetched per GraphQL page (default 100)
#   INITIATIVE_FIELD  Initiative field name (default "Initiative")
#   THEME_FIELD       Theme field name (default "Theme")
#
# Functions (sourceable / unit-tested):
#   normalize_signature <title> <labels_json> <repo>
#   classify_by_rules   <signature>          → Initiative name or "" (no match)
#   theme_for           <initiative>         → Theme name or ""
#   decide_for_signature <signature>         → "<initiative>\t<theme>" or ""
#   resolve_fields                           → populate field-id / option maps
#   sweep_project                            → paginate + reconcile the board

set -euo pipefail

_ci_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "${_ci_dir}/lib.sh"

# Field ids + name→optionId maps, resolved once per run by resolve_fields.
declare -gA CI_INIT_OPT CI_THEME_OPT
CI_INIT_FIELD_ID=""
CI_THEME_FIELD_ID=""

# normalize_signature <title> <labels_json> <repo>
#   Flatten an item into one lowercase line "title | l1,l2 | owner/repo" that
#   the regex rules match against. A non-array labels_json (null/object from
#   odd payloads) degrades to no labels rather than aborting under set -e.
#
#   Gate labels are STRIPPED from the signature (SIGNATURE_IGNORE_LABELS,
#   default = the required + excluded noise-gate labels). This matters:
#   every board item carries the `dev-lead` required label, so leaving it in
#   would make the `dev-lead agent` rule match every single item. Only labels
#   that actually signal an initiative survive into the signature.
normalize_signature() {
  if [ "$#" -ne 3 ]; then
    printf '[normalize_signature] expected 3 args (title labels_json repo), got %d\n' "$#" >&2
    return 64
  fi
  local title="$1" labels_json="$2" repo="$3" labels=""
  # Drop routing/process labels that carry no initiative signal, so they can't
  # drive a classification. Two mechanisms:
  #   1. an explicit ignore list (SIGNATURE_IGNORE_LABELS) — the noise-gate
  #      labels (dev-lead + the excluded set);
  #   2. a family-prefix strip for `dev-lead*` and `initiative*`, which also
  #      removes their colon-variants (`dev-lead:needs-human`,
  #      `initiative:auto`, …). Those variants contain "dev-lead"/"initiative"
  #      and would otherwise make the `dev-lead agent` / `Initiatives Project`
  #      rule tokens match every pipeline-routed item.
  local ignore="${SIGNATURE_IGNORE_LABELS-dev-lead,compliance-audit,health-check,fleet-tracker,daily-report}"
  if printf '%s' "${labels_json}" | jq -e 'type == "array"' >/dev/null 2>&1; then
    labels=$(printf '%s' "${labels_json}" | jq -r --arg ig "${ignore}" '
      ($ig | ascii_downcase | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0))) as $drop
      | [ .[].name
          | select((ascii_downcase) as $n
              | (($drop | index($n)) | not)
                and (($n | test("^(dev-lead|initiative)(:|$)")) | not)) ]
      | join(",")')
  fi
  printf '%s | %s | %s' "${title}" "${labels}" "${repo}" | tr '[:upper:]' '[:lower:]'
}

# classify_by_rules <signature> → first-matching Initiative name, or "".
classify_by_rules() {
  if [ "$#" -ne 1 ]; then
    printf '[classify_by_rules] expected 1 arg (signature), got %d\n' "$#" >&2
    return 64
  fi
  local sig="$1" name rx
  local rules="${RULES_FILE:-${_ci_dir}/initiative-rules.tsv}"
  if [ ! -f "${rules}" ]; then
    printf '[classify_by_rules] rules file not found: %s\n' "${rules}" >&2
    return 65
  fi
  while IFS=$'\t' read -r name rx || [ -n "${name}" ]; do
    name="${name%$'\r'}"
    rx="${rx%$'\r'}"
    case "${name}" in ''|'#'*) continue ;; esac
    [ -n "${rx}" ] || continue
    if printf '%s' "${sig}" | grep -Eiq -- "${rx}"; then
      printf '%s' "${name}"
      return 0
    fi
  done < "${rules}"
  return 0
}

# theme_for <initiative> → the Theme it rolls up to, or "".
theme_for() {
  if [ "$#" -ne 1 ]; then
    printf '[theme_for] expected 1 arg (initiative), got %d\n' "$#" >&2
    return 64
  fi
  local want="$1" init theme
  local tax="${TAXONOMY_FILE:-${_ci_dir}/initiative-taxonomy.tsv}"
  if [ ! -f "${tax}" ]; then
    printf '[theme_for] taxonomy file not found: %s\n' "${tax}" >&2
    return 65
  fi
  while IFS=$'\t' read -r init theme || [ -n "${init}" ]; do
    init="${init%$'\r'}"
    theme="${theme%$'\r'}"
    case "${init}" in ''|'#'*) continue ;; esac
    if [ "${init}" = "${want}" ]; then
      printf '%s' "${theme}"
      return 0
    fi
  done < "${tax}"
  return 0
}

# decide_for_signature <signature> → "<initiative>\t<theme>" (theme may be
# empty), or "" when no rule matches.
decide_for_signature() {
  if [ "$#" -ne 1 ]; then
    printf '[decide_for_signature] expected 1 arg (signature), got %d\n' "$#" >&2
    return 64
  fi
  local sig="$1" init theme
  init=$(classify_by_rules "${sig}") || return $?
  [ -n "${init}" ] || return 0
  theme=$(theme_for "${init}") || return $?
  printf '%s\t%s' "${init}" "${theme}"
}

# resolve_fields — query the project once for the Initiative + Theme
# single-select field ids and their live option name→id maps. Fails loudly
# (75) if the project node is unreachable, (65) if the Initiative field is
# absent. Theme is best-effort: its absence is not fatal.
resolve_fields() {
  _atp_require_env resolve_fields || return $?
  local json
  # shellcheck disable=SC2016  # $projectId/$initName/$themeName are GraphQL variables
  json=$(gh api graphql \
    -F projectId="${PROJECT_ID}" \
    -F initName="${INITIATIVE_FIELD:-Initiative}" \
    -F themeName="${THEME_FIELD:-Theme}" \
    -f query='query($projectId:ID!,$initName:String!,$themeName:String!){
      node(id:$projectId){
        ... on ProjectV2 {
          initiative: field(name:$initName){ ... on ProjectV2SingleSelectField { id options{ id name } } }
          theme:      field(name:$themeName){ ... on ProjectV2SingleSelectField { id options{ id name } } }
        }
      }
    }')

  if [ "$(printf '%s' "${json}" | jq -r '.data.node?')" = "null" ]; then
    printf '[resolve_fields] GraphQL returned data.node:null for PROJECT_ID=%s — token may lack access, or the project was deleted.\n' "${PROJECT_ID}" >&2
    return 75
  fi
  CI_INIT_FIELD_ID=$(printf '%s' "${json}" | jq -r '.data.node.initiative.id? // ""')
  CI_THEME_FIELD_ID=$(printf '%s' "${json}" | jq -r '.data.node.theme.id? // ""')
  if [ -z "${CI_INIT_FIELD_ID}" ]; then
    printf '[resolve_fields] Initiative single-select field %q not found on the project.\n' "${INITIATIVE_FIELD:-Initiative}" >&2
    return 65
  fi

  local id name
  while IFS=$'\t' read -r id name; do
    [ -n "${id}" ] && CI_INIT_OPT["${name}"]="${id}"
  done < <(printf '%s' "${json}" | jq -r '.data.node.initiative.options?[]? | "\(.id)\t\(.name)"')
  while IFS=$'\t' read -r id name; do
    [ -n "${id}" ] && CI_THEME_OPT["${name}"]="${id}"
  done < <(printf '%s' "${json}" | jq -r '.data.node.theme.options?[]? | "\(.id)\t\(.name)"')
}

# _ci_report <total> <already> <matched> <unmatched> <skipped> <failed>
_ci_report() {
  local total="$1" already="$2" matched="$3" unmatched="$4" skipped="$5" failed="${6:-0}"
  local mode="apply"; [ "${DRY_RUN:-}" = "1" ] && mode="dry-run"
  printf '\n=== classify-initiative summary (%s) ===\n' "${mode}"
  printf '  board items scanned : %d\n' "${total}"
  printf '  already associated  : %d (skipped; RECLASSIFY=all to re-evaluate)\n' "${already}"
  printf '  newly matched       : %d\n' "${matched}"
  printf '  unmatched (blank)   : %d\n' "${unmatched}"
  printf '  option-missing skip : %d\n' "${skipped}"
  printf '  transient set fails : %d (left blank; refilled next sweep)\n' "${failed}"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      printf '### classify-initiative (%s)\n\n' "${mode}"
      printf '| scanned | already | matched | unmatched | skipped | failed |\n'
      printf '|--:|--:|--:|--:|--:|--:|\n'
      printf '| %d | %d | %d | %d | %d | %d |\n' "${total}" "${already}" "${matched}" "${unmatched}" "${skipped}" "${failed}"
    } >> "${GITHUB_STEP_SUMMARY}"
  fi
}

# sweep_project — resolve fields, page through every board item, and set the
# Initiative (+ Theme) on each qualifying item. Idempotent; DRY_RUN-aware.
sweep_project() {
  _atp_require_env sweep_project || return $?
  resolve_fields || return $?

  local page_size="${PAGE_SIZE:-100}" items
  # --paginate concatenates one JSON document per page; jq -s slurps them and
  # flattens all item nodes into a single array.
  # shellcheck disable=SC2016  # GraphQL variables, not shell
  items=$(gh api graphql --paginate \
    -F projectId="${PROJECT_ID}" \
    -F pageSize="${page_size}" \
    -F initName="${INITIATIVE_FIELD:-Initiative}" \
    -f query='query($projectId:ID!,$pageSize:Int!,$endCursor:String,$initName:String!){
      node(id:$projectId){
        ... on ProjectV2 {
          items(first:$pageSize, after:$endCursor){
            pageInfo{ hasNextPage endCursor }
            nodes{
              id
              initiative: fieldValueByName(name:$initName){ ... on ProjectV2ItemFieldSingleSelectValue { name } }
              content{
                __typename
                ... on Issue        { title labels(first:20){ nodes{ name } } repository{ nameWithOwner } }
                ... on PullRequest  { title labels(first:20){ nodes{ name } } repository{ nameWithOwner } }
                ... on DraftIssue   { title }
              }
            }
          }
        }
      }
    }' | jq -s '[.[].data.node.items.nodes?[]?]')

  local total=0 already=0 matched=0 unmatched=0 skipped=0 failed=0
  local node
  while IFS= read -r node; do
    [ -n "${node}" ] || continue
    total=$((total + 1))

    local item_id cur title labels repo sig decided init theme optid
    item_id=$(printf '%s' "${node}" | jq -r '.id?')
    cur=$(printf '%s' "${node}" | jq -r '.initiative.name? // ""')
    title=$(printf '%s' "${node}" | jq -r '.content.title? // ""')
    labels=$(printf '%s' "${node}" | jq -c '.content.labels.nodes? // []')
    repo=$(printf '%s' "${node}" | jq -r '.content.repository.nameWithOwner? // ""')

    if [ -n "${cur}" ] && [ "${RECLASSIFY:-}" != "all" ]; then
      already=$((already + 1))
      continue
    fi

    sig=$(normalize_signature "${title}" "${labels}" "${repo}")
    decided=$(decide_for_signature "${sig}")
    init="${decided%%$'\t'*}"
    theme="${decided#*$'\t'}"

    if [ -z "${init}" ]; then
      unmatched=$((unmatched + 1))
      printf 'UNMATCHED  %-20s «%s»\n' "${repo:-draft}" "${title}"
      continue
    fi

    optid="${CI_INIT_OPT[${init}]:-}"
    if [ -z "${optid}" ]; then
      printf '::warning::rule matched Initiative %q which is not a live project option; skipping «%s»\n' "${init}" "${title}" >&2
      skipped=$((skipped + 1))
      continue
    fi

    # Per-item resilience: a transient API error (network blip, secondary rate
    # limit) on one item must NOT abort a sweep of hundreds. Log it, count it,
    # and carry on — the next scheduled run refills whatever stayed blank
    # (this is a fill-blanks-only sweep, so retries are idempotent). Mirrors
    # reconcile-backlog.sh's per-item error isolation.
    if ! set_item_single_select_value "${item_id}" "${CI_INIT_FIELD_ID}" "${optid}"; then
      printf '::warning::failed to set Initiative %q on «%s» (transient?); will retry next sweep\n' "${init}" "${title}" >&2
      failed=$((failed + 1))
      continue
    fi
    printf 'MATCH  %-22s <- %-20s «%s»\n' "${init}" "${repo:-draft}" "${title}"
    matched=$((matched + 1))

    # Theme is best-effort: co-assign only when the field and matching option
    # both exist live. A missing Theme field/option is silently tolerated, and
    # a transient set failure is non-fatal (Initiative already landed).
    if [ -n "${theme}" ] && [ -n "${CI_THEME_FIELD_ID}" ]; then
      local topt="${CI_THEME_OPT[${theme}]:-}"
      if [ -n "${topt}" ] && ! set_item_single_select_value "${item_id}" "${CI_THEME_FIELD_ID}" "${topt}"; then
        printf '::warning::failed to set Theme %q on «%s» (transient?); retry requires RECLASSIFY=all (Initiative already set)\n' "${theme}" "${title}" >&2
      fi
    fi
  done < <(printf '%s' "${items}" | jq -c '.[]')

  _ci_report "${total}" "${already}" "${matched}" "${unmatched}" "${skipped}" "${failed}"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  sweep_project
fi
