#!/usr/bin/env bash
# scripts/agents-md-lint.sh — standalone, deterministic AGENTS.md STRUCTURAL
# linter (Phase 2 of epic #642, story #644).
#
# It validates a SINGLE AGENTS.md file against the Phase-1 structural rule set
# (scripts/lib/agents-md-rules.json) and emits deterministic, severity-tagged,
# machine-readable findings. It is file-path-in / findings-out: it never
# enumerates repos and never touches the network (that is Phase 3's audit
# integration). This keeps it unit-testable and reusable by both the audit and a
# local CI self-check. Cost is zero LLM tokens — pure shell + jq.
#
# What is validated is driven by the DATA FILE, not hardcoded: the driver reads
# each rule's id, level (required|recommended), element and applies_to from the
# JSON and dispatches by id. Re-tagging a rule required<->recommended, or adding
# /removing a rule, changes the reported severity with NO code edit — the key
# design constraint from #643 (the upstream agents.md spec is young and moving).
# A `recommended` finding is REPORTED but never fails the check; only `required`
# findings can fail `--mode failing`.
#
# Cross-reference integrity resolves relative links/paths against the AGENTS.md's
# OWN directory; http(s)/mailto/other-scheme URLs and pure '#anchor' targets that
# point outside the file are treated as out of scope for existence checks
# (mirroring how the repo's other validators skip URLs).
#
# Caller contract: the pure classification/parse helpers below are `source`-able
# and side-effect-free (they run nothing and call no `set` at source time), so
# tests/agents_md_lint.bats can source this file and exercise them directly. Only
# when executed directly does it `set -euo pipefail` and run the CLI.
#
# Usage:
#   agents-md-lint.sh [--mode informational|failing] [--scope canonical|downstream]
#                     [--rules PATH] <path-to-AGENTS.md>
#
#   --mode informational  (default) always exit 0 — report only.
#   --mode failing        exit non-zero when any REQUIRED-level finding exists.
#   --scope canonical     (default) skip downstream-only rules (org-import).
#   --scope downstream    also apply rules whose applies_to == "downstream".
#   --rules PATH          rule-set JSON (default: scripts/lib/agents-md-rules.json).
#
# Output (stdout), one finding per line, deterministic TSV:
#   <severity>\t<rule_id>\t<line>\t<message>
# where <severity> is the rule's level and <line> is a 1-based line number or '-'.

AMDL_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AMDL_DEFAULT_RULES="${AMDL_SCRIPT_DIR}/lib/agents-md-rules.json"

# ---------------------------------------------------------------------------
# amdl_trim <string> — strip leading and trailing whitespace. Pure.
# ---------------------------------------------------------------------------
amdl_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"   # ltrim
  s="${s%"${s##*[![:space:]]}"}"   # rtrim
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# amdl_slugify <text> — GitHub-style heading anchor slug: lowercase, drop every
# character that is not alphanumeric / space / hyphen, then spaces -> hyphens.
# Multiple spaces become multiple hyphens (GitHub does not collapse them). Pure.
# ---------------------------------------------------------------------------
amdl_slugify() {
  local text="${1,,}"
  text="${text//[^a-z0-9 -]/}"
  printf '%s' "${text// /-}"
}

# ---------------------------------------------------------------------------
# amdl_extract_headings <file> — emit one line per ATX heading OUTSIDE fenced
# code blocks: "<level>\t<line-number>\t<text>". A '#' inside a ``` or ~~~ fence
# is not a heading. Pure (reads the file, writes stdout only).
# ---------------------------------------------------------------------------
amdl_extract_headings() {
  local file="$1"
  local lineno=0 in_fence=0 fence_char="" fence_len=0 line trimmed hashes text level
  local _fc _flen
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    trimmed="${line#"${line%%[![:space:]]*}"}"
    if [[ "$trimmed" =~ ^(\`{3,}|~{3,}) ]]; then
      _fc="${BASH_REMATCH[1]:0:1}"
      _flen="${#BASH_REMATCH[1]}"
      if [ "$in_fence" -eq 0 ]; then
        in_fence=1
        fence_char="$_fc"
        fence_len="$_flen"
      elif [[ "$trimmed" =~ ^(\`{3,}|~{3,})[[:space:]]*$ ]] && \
           [ "$_fc" = "$fence_char" ] && [ "$_flen" -ge "$fence_len" ]; then
        in_fence=0
        fence_char=""
        fence_len=0
      fi
      continue
    fi
    [ "$in_fence" -eq 0 ] || continue
    if [[ "$line" =~ ^(#{1,6})[[:space:]]+(.*)$ ]]; then
      hashes="${BASH_REMATCH[1]}"
      text="${BASH_REMATCH[2]}"
      level="${#hashes}"
      # Strip leading whitespace
      text="${text#"${text%%[![:space:]]*}"}"
      # Strip trailing closed-ATX run of '#' and surrounding whitespace
      text="${text%"${text##*[![:space:]#]}"}"
      # Strip trailing whitespace
      text="${text%"${text##*[![:space:]]}"}"
      printf '%s\t%s\t%s\n' "$level" "$lineno" "$text"
    fi
  done < "$file"
  return 0
}

# ---------------------------------------------------------------------------
# amdl_check_single_h1 <file> — findings ("<line>\t<msg>") when the file does not
# have exactly one H1 as its first heading. Pure.
# ---------------------------------------------------------------------------
amdl_check_single_h1() {
  local file="$1" headings h1_lines count first_line h1_line extra
  headings="$(amdl_extract_headings "$file")"
  h1_lines="$(printf '%s\n' "$headings" | awk -F'\t' '$1==1{print $2}')"
  count="$(printf '%s\n' "$headings" | awk -F'\t' 'BEGIN{c=0} $1==1{c++} END{print c}')"
  if [ "$count" -eq 0 ]; then
    printf '1\tno level-1 (H1) heading found; exactly one is required\n'
    return 0
  fi
  if [ "$count" -gt 1 ]; then
    extra="$(printf '%s\n' "$h1_lines" | sed -n '2p')"
    printf '%s\tmultiple H1 headings found (%s); exactly one is required\n' "$extra" "$count"
    return 0
  fi
  first_line="$(printf '%s\n' "$headings" | sed -n '1p' | awk -F'\t' '{print $2}')"
  h1_line="$(amdl_trim "$h1_lines")"
  if [ "$first_line" != "$h1_line" ]; then
    printf '%s\tthe single H1 heading is not the first heading in the file\n' "$h1_line"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# amdl_check_heading_hierarchy <file> — findings for any heading that descends
# more than one level below the previous heading (e.g. H2 -> H4). Pure.
# ---------------------------------------------------------------------------
amdl_check_heading_hierarchy() {
  local file="$1"
  amdl_extract_headings "$file" | awk -F'\t' '
    NR==1 { prev=$1; next }
    {
      if ($1 > prev + 1) {
        printf "%s\theading level jumps from H%d to H%d (skips a level)\n", $2, prev, $1
      }
      prev=$1
    }
  '
  return 0
}

# ---------------------------------------------------------------------------
# amdl_check_fenced_code_closure <file> — a finding when a ``` or ~~~ fence is
# opened but never closed by a matching fence. Pure.
# ---------------------------------------------------------------------------
amdl_check_fenced_code_closure() {
  local file="$1"
  local lineno=0 in_fence=0 fence_char="" fence_len=0 open_line=0 line trimmed
  local _fc _flen
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    trimmed="${line#"${line%%[![:space:]]*}"}"
    if [[ "$trimmed" =~ ^(\`{3,}|~{3,}) ]]; then
      _fc="${BASH_REMATCH[1]:0:1}"
      _flen="${#BASH_REMATCH[1]}"
      if [ "$in_fence" -eq 0 ]; then
        in_fence=1
        fence_char="$_fc"
        fence_len="$_flen"
        open_line="$lineno"
      elif [[ "$trimmed" =~ ^(\`{3,}|~{3,})[[:space:]]*$ ]] && \
           [ "$_fc" = "$fence_char" ] && [ "$_flen" -ge "$fence_len" ]; then
        in_fence=0
        fence_char=""
        fence_len=0
      fi
    fi
  done < "$file"
  if [ "$in_fence" -ne 0 ]; then
    printf '%s\tfenced code block opened here is never closed\n' "$open_line"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# amdl_extract_link_targets <line> — emit the raw target of every inline
# Markdown link "[text](target)" and reference definition "[label]: target" on
# the line, one per line. Pure.
# ---------------------------------------------------------------------------
amdl_extract_link_targets() {
  local line="$1"
  printf '%s\n' "$line" | grep -oE '\]\([^)]*\)' | sed -E 's/^\]\(//; s/\)$//' || true
  printf '%s\n' "$line" | grep -oE '^[[:space:]]*\[[^]]+\]:[[:space:]]*[^[:space:]]+' \
    | sed -E 's/^.*\]:[[:space:]]*//' || true
}

# ---------------------------------------------------------------------------
# amdl_classify_reference <target> <base-dir> <slugs> <lineno> — emit a finding
# when a single link target does not resolve. URLs with a scheme (http, https,
# mailto, …) and protocol-relative "//host" links are out of scope. A '#anchor'
# target must match a heading slug in <slugs>; a relative path must exist under
# <base-dir>. Pure.
# ---------------------------------------------------------------------------
amdl_classify_reference() {
  local target="$1" base="$2" slugs="$3" lineno="$4" anchor path
  target="${target%%[[:space:]]*}"   # drop any link title after the URL
  target="${target#<}"
  target="${target%>}"
  [ -n "$target" ] || return 0
  if [[ "$target" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*: ]] || [[ "$target" == //* ]]; then
    return 0
  fi
  if [[ "$target" == \#* ]]; then
    anchor="${target#\#}"
    anchor="${anchor,,}"
    local padded_slugs=$'\n'"$slugs"$'\n'
    if [[ "$padded_slugs" != *$'\n'"$anchor"$'\n'* ]]; then
      printf '%s\tin-document anchor "#%s" does not match any heading\n' "$lineno" "$anchor"
    fi
    return 0
  fi
  path="${target%%#*}"
  path="${path%%\?*}"
  [ -n "$path" ] || return 0
  if [ ! -e "$base/$path" ]; then
    printf '%s\trelative reference "%s" does not resolve to an existing path\n' "$lineno" "$path"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# amdl_check_cross_references <file> — findings for every dangling in-document
# anchor or repo-relative link. Relative paths resolve against the file's own
# directory. Skips content inside fenced code blocks. Pure.
# ---------------------------------------------------------------------------
amdl_check_cross_references() {
  local file="$1" base slugs lvl ln text slug n
  base="$(dirname -- "$file")"
  slugs=""
  declare -A slug_count
  while IFS=$'\t' read -r lvl ln text; do
    : "${lvl:-}" "${ln:-}"
    [ -n "$text" ] || continue
    slug="$(amdl_slugify "$text")"
    n="${slug_count["$slug"]:-0}"
    slug_count["$slug"]=$((n + 1))
    if [ "$n" -eq 0 ]; then
      slugs+="$slug"$'\n'
    else
      slugs+="${slug}-${n}"$'\n'
    fi
  done < <(amdl_extract_headings "$file")

  local lineno=0 in_fence=0 fence_char="" fence_len=0 line trimmed target temp_line
  local _fc _flen
  local inline_regex='(.*)\]\(([^)]*)\)(.*)'
  local ref_regex='^[[:space:]]*\[[^]]+\]:[[:space:]]*(.*)'
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    trimmed="${line#"${line%%[![:space:]]*}"}"
    if [[ "$trimmed" =~ ^(\`{3,}|~{3,}) ]]; then
      _fc="${BASH_REMATCH[1]:0:1}"
      _flen="${#BASH_REMATCH[1]}"
      if [ "$in_fence" -eq 0 ]; then
        in_fence=1
        fence_char="$_fc"
        fence_len="$_flen"
      elif [[ "$trimmed" =~ ^(\`{3,}|~{3,})[[:space:]]*$ ]] && \
           [ "$_fc" = "$fence_char" ] && [ "$_flen" -ge "$fence_len" ]; then
        in_fence=0
        fence_char=""
        fence_len=0
      fi
      continue
    fi
    [ "$in_fence" -eq 0 ] || continue

    # Extract inline links: [text](target)
    temp_line="$line"
    while [[ "$temp_line" =~ $inline_regex ]]; do
      local _pre="${BASH_REMATCH[1]}" _tgt="${BASH_REMATCH[2]}" _post="${BASH_REMATCH[3]}"
      amdl_classify_reference "$_tgt" "$base" "$slugs" "$lineno"
      temp_line="${_pre}${_post}"
    done

    # Extract reference definitions: [label]: target
    if [[ "$line" =~ $ref_regex ]]; then
      target="${BASH_REMATCH[1]}"
      amdl_classify_reference "$target" "$base" "$slugs" "$lineno"
    fi
  done < "$file"
  return 0
}

# ---------------------------------------------------------------------------
# amdl_check_section_present <file> <ext-regex> — a finding when no heading text
# matches the (case-insensitive) extended regex. Pure.
# ---------------------------------------------------------------------------
amdl_check_section_present() {
  local file="$1" regex="$2"
  if amdl_extract_headings "$file" | awk -F'\t' '{print $3}' | grep -qiE "$regex"; then
    return 0
  fi
  printf '%s\tno section heading matching /%s/ is present\n' "-" "$regex"
  return 0
}

# ---------------------------------------------------------------------------
# amdl_check_org_import <file> — a finding when a downstream AGENTS.md contains
# no link back to the canonical petry-projects/.github file. Pure.
# ---------------------------------------------------------------------------
amdl_check_org_import() {
  local file="$1"
  if grep -qE '\[([^]]*)\]\([^)]*petry-projects/\.github[^)]*\)' "$file"; then
    return 0
  fi
  printf '%s\tno link back to the canonical petry-projects/.github AGENTS.md is present\n' "-"
  return 0
}

# ---------------------------------------------------------------------------
# amdl_rule_level <rules-json> <rule-id> — print the rule's level. Non-zero if
# the id is not present in the rule set.
# ---------------------------------------------------------------------------
amdl_rule_level() {
  local rules="$1" id="$2"
  jq -er --arg id "$id" '.rules[] | select(.id==$id) | .level' "$rules"
}

# ---------------------------------------------------------------------------
# amdl_dispatch_rule <rule-id> <file> — run the check implementing <rule-id> and
# emit its raw "<line>\t<msg>" findings. Unknown ids surface a loud drift finding
# rather than being silently ignored.
# ---------------------------------------------------------------------------
amdl_dispatch_rule() {
  local id="$1" file="$2"
  case "$id" in
    single-h1-title)                    amdl_check_single_h1 "$file" ;;
    heading-hierarchy-valid)            amdl_check_heading_hierarchy "$file" ;;
    cross-reference-integrity)          amdl_check_cross_references "$file" ;;
    fenced-code-block-closure)          amdl_check_fenced_code_closure "$file" ;;
    org-repo-import-consistency)        amdl_check_org_import "$file" ;;
    standards-reference-section-present) amdl_check_section_present "$file" 'standard|development standards' ;;
    security-section-present)            amdl_check_section_present "$file" 'security|secret' ;;
    testing-section-present)             amdl_check_section_present "$file" 'test|tdd' ;;
    *) printf '%s\tno linter implementation for rule "%s" (rule-set/linter drift)\n' "-" "$id" ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# amdl_lint <file> [rules-json] [scope] — the data-driven driver. Iterate the
# rules in rule-set order, honour applies_to against <scope>, dispatch by id, and
# prefix each finding with the rule's level (severity) and id. Deterministic
# order: rules in file order, findings in line order. Always returns 0.
# ---------------------------------------------------------------------------
amdl_lint() {
  local file="$1" rules="${2:-$AMDL_DEFAULT_RULES}" scope="${3:-canonical}"
  local id level applies element check_out finding
  if ! jq -e '.rules | length > 0' "$rules" >/dev/null 2>&1; then
    printf 'agents-md-lint: rule-set file is invalid or contains no rules: %s\n' "$rules" >&2
    return 2
  fi
  while IFS=$'\t' read -r id level applies element; do
    : "${element:-}"
    if [ "$applies" != "all" ] && [ "$applies" != "$scope" ]; then
      continue
    fi
    check_out="$(amdl_dispatch_rule "$id" "$file")"
    [ -n "$check_out" ] || continue
    while IFS= read -r finding; do
      [ -n "$finding" ] || continue
      printf '%s\t%s\t%s\n' "$level" "$id" "$finding"
    done < <(printf '%s\n' "$check_out")
  done < <(jq -r '.rules[] | [.id, .level, .applies_to, .element] | @tsv' "$rules")
  return 0
}

# ---------------------------------------------------------------------------
# amdl_usage — print CLI usage to stdout.
# ---------------------------------------------------------------------------
amdl_usage() {
  sed -n 's/^# \{0,1\}//p' <<'USAGE'
# agents-md-lint.sh [--mode informational|failing] [--scope canonical|downstream]
#                   [--rules PATH] <path-to-AGENTS.md>
#
# Validates a single AGENTS.md against the structural rule set and prints
# severity-tagged TSV findings. Default mode is informational (always exit 0);
# --mode failing exits non-zero when any required-level finding is present.
USAGE
}

# ---------------------------------------------------------------------------
# amdl_main <args...> — CLI entry point. Returns 2 on usage/environment errors,
# 1 only in --mode failing with a required-level finding, else 0.
# ---------------------------------------------------------------------------
amdl_main() {
  local mode="informational" scope="canonical" rules="$AMDL_DEFAULT_RULES" target=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode) mode="${2:-}"; shift 2 ;;
      --mode=*) mode="${1#*=}"; shift ;;
      --scope) scope="${2:-}"; shift 2 ;;
      --scope=*) scope="${1#*=}"; shift ;;
      --rules) rules="${2:-}"; shift 2 ;;
      --rules=*) rules="${1#*=}"; shift ;;
      -h|--help) amdl_usage; return 0 ;;
      --) shift; target="${1:-}"; break ;;
      -*) printf 'agents-md-lint: unknown option: %s\n' "$1" >&2; return 2 ;;
      *) target="$1"; shift ;;
    esac
  done

  case "$mode" in
    informational|failing) : ;;
    *) printf 'agents-md-lint: invalid --mode "%s" (want informational|failing)\n' "$mode" >&2; return 2 ;;
  esac
  case "$scope" in
    canonical|downstream) : ;;
    *) printf 'agents-md-lint: invalid --scope "%s" (want canonical|downstream)\n' "$scope" >&2; return 2 ;;
  esac
  if ! command -v jq >/dev/null 2>&1; then
    printf 'agents-md-lint: jq is required but was not found on PATH\n' >&2
    return 2
  fi
  if [ -z "$target" ]; then
    printf 'agents-md-lint: no AGENTS.md path given\n\n' >&2
    amdl_usage >&2
    return 2
  fi
  if [ ! -f "$rules" ]; then
    printf 'agents-md-lint: rule-set file not found: %s\n' "$rules" >&2
    return 2
  fi
  if [ ! -f "$target" ]; then
    printf 'agents-md-lint: target AGENTS.md not found: %s\n' "$target" >&2
    return 2
  fi

  local findings
  findings="$(amdl_lint "$target" "$rules" "$scope")"
  if [ -n "$findings" ]; then
    printf '%s\n' "$findings"
  fi

  if [ "$mode" = "failing" ] && printf '%s\n' "$findings" | grep -q "^required$(printf '\t')"; then
    return 1
  fi
  return 0
}

# Run the CLI only when executed directly, not when sourced by the bats tests
# that exercise the pure helper functions above.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  set -euo pipefail
  amdl_main "$@"
fi
