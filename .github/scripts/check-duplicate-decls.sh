#!/usr/bin/env bash
# check-duplicate-decls.sh — required CI gate against the #1485 corruption class,
# ported from petry-projects/.github-private (#1520) into this repo (#1025).
#
# Fails when a load-bearing file declares the same TOP-LEVEL symbol more than
# once. Three detectors, each targeting a duplication that a merge can introduce
# while every existing test stays green (so nothing else catches it):
#
#   shell (*.sh)    duplicate top-level FUNCTION declaration. Bash last-wins
#                   semantics mean a duplicated function silently shadows its
#                   earlier copy, so the suite passes while the file is wrong —
#                   the signature that landed on trunk wholesale in #1292/#1378
#                   (see #1485 for the incident record). Detection is identical
#                   to .github-private's scripts/lib/conflict-integrity.sh.
#   markdown (*.md) duplicate top-level HEADING (H1/H2). A shell-only sweep would
#                   not catch the AGENTS.md duplication in PR #1024 (23 vs 12
#                   top-level headings); standards docs here are equally
#                   load-bearing. Fence-aware, so `#`-comments inside code blocks
#                   are not mistaken for headings, and sub-headings (H3+) that
#                   legitimately repeat across sections are not gated.
#   json (*.json)   duplicate object KEY, or an unparseable file. jq and most
#                   loaders silently keep the last value for a duplicated key, so
#                   a corrupted ruleset/standard parses "fine" while dropping
#                   config; we fail loud instead.
#
# Deliberately narrow (matches #1520's AC):
#   - Tree-state, not diff-aware: standing corruption fails, whoever introduced
#     it. This is the merge-blocking backstop, not an introduction detector.
#   - Functions only for shell. Top-level VARIABLE reassignment at column 0 is
#     legitimate (defaults overwritten conditionally), so var duplicates are not
#     gated — the corruption signature that reached trunk was duplicated bodies.
#   - Top-level headings only for markdown. Repeated H3+ sub-headings (e.g.
#     "### Agentic Directives" under several sections of AGENTS.md) are normal.
#   - No escape hatch by design. If an intentional duplicate is ever genuinely
#     needed, amend this script in a reviewed diff.
#
# Usage: check-duplicate-decls.sh [dir]   (default: the repo root this file lives
#        under). Scans recursively, skipping the excluded dirs below.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCAN_DIR="${1:-$REPO_ROOT}"

if [ ! -d "$SCAN_DIR" ]; then
  echo "::error::check-duplicate-decls: scan directory does not exist: ${SCAN_DIR}" >&2
  exit 2
fi

# Directories never scanned: VCS/vendored trees (.git, node_modules) and dirs
# that legitimately hold intentional-duplicate fixtures or vendored agent
# tooling (test, tests, .dev-lead). Pruning is by basename at any depth.
_find_files() {
  local ext="$1"
  find "$SCAN_DIR" \
    \( -type d \( -name .git -o -name node_modules -o -name test -o -name tests -o -name .dev-lead \) -prune \) \
    -o \( -type f -name "*.${ext}" -print0 \)
}

# extract_shell_functions <file>
# Emit one line per top-level function declaration, in file order. "Top-level"
# means column 0 (no leading whitespace), so nested functions are ignored. Awk
# body is a verbatim copy of .github-private's extract_top_level_symbols (the fn
# arms only) so shell detection is byte-identical to the private gate.
extract_shell_functions() {
  tr -d '\r' < "$1" | awk '
    # Skip lines inside a heredoc body (close on bare delimiter line).
    inheredoc {
      stripped = $0
      sub(/^\t*/, "", stripped)
      if (stripped == hd) { inheredoc = 0; hd = "" }
      next
    }
    # NAME() {   (POSIX + ksh, brace same line), column 0 only.
    /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/ {
      name = $0
      sub(/[[:space:]]*\(\).*$/, "", name)
      print name
      next
    }
    # NAME()      (brace on next line), column 0 only.
    /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*$/ {
      name = $0
      sub(/[[:space:]]*\(\).*$/, "", name)
      print name
      next
    }
    # function NAME   (with or without trailing parens).
    /^function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ {
      name = $2
      sub(/\(.*$/, "", name)
      print name
      next
    }
    # Detect heredoc opening (<<[-] followed by quoted or bare delimiter).
    /<</ {
      tmp = $0
      sub(/.*<<-?[[:space:]]*/, "", tmp)
      if (substr(tmp, 1, 1) == "\047" || substr(tmp, 1, 1) == "\"") {
        tmp = substr(tmp, 2)
        sub(/[\047"].*$/, "", tmp)
      } else {
        sub(/[^A-Za-z0-9_].*$/, "", tmp)
      }
      if (tmp ~ /^[A-Za-z_][A-Za-z0-9_]*$/) { inheredoc = 1; hd = tmp }
    }
  '
}

# extract_markdown_headings <file>
# Emit the text of each top-level (H1/H2) ATX heading, fence-aware: lines inside
# ``` / ~~~ fenced code blocks are skipped, so bash `#`-comments are not treated
# as headings. H3+ sub-headings are intentionally not emitted.
extract_markdown_headings() {
  tr -d '\r' < "$1" | awk '
    # Toggle fenced code blocks. A fence is ``` or ~~~ (3+), optionally indented.
    # Track fence length so a 3-backtick line cannot close a 4+-backtick fence.
    /^[[:space:]]*(`{3,}|~{3,})/ {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      ch = substr(line, 1, 1)
      len = 0; while (substr(line, len+1, 1) == ch) len++
      if (!infence) { infence = 1; fence = ch; fencelen = len }
      else if (ch == fence && len >= fencelen) { infence = 0; fence = ""; fencelen = 0 }
      next
    }
    infence { next }
    # Track HTML comment blocks <!-- ... --> (may span lines); skip headings inside.
    {
      line_in_html = inhtml
      tmp = $0
      while (length(tmp) > 0) {
        if (!inhtml) {
          if (!match(tmp, /<!--/)) break
          tmp = substr(tmp, RSTART + 4); inhtml = 1
        } else {
          if (!match(tmp, /-->/)) break
          tmp = substr(tmp, RSTART + 3); inhtml = 0
        }
      }
      if (line_in_html) next
    }
    /^#{1,2}[[:space:]]+[^[:space:]]/ {
      text = $0
      sub(/^#{1,2}[[:space:]]+/, "", text)   # strip leading hashes
      sub(/[[:space:]]+$/, "", text)          # strip trailing whitespace
      sub(/[[:space:]]+#+[[:space:]]*$/, "", text)  # strip closing ATX hashes
      print text
      next
    }
  '
}

# duplicates_with_counts — read symbols on stdin, emit "SYMBOL<TAB>COUNT" for
# each symbol appearing more than once. Empty input yields empty output.
duplicates_with_counts() {
  LC_ALL=C sort | uniq -c | awk '$1 > 1 { line = $0; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", line); print line "\t" $1 }'
}

fail=0
report=""

_record() {
  # _record <file> <kind> <findings>   (<findings> is "SYMBOL<TAB>COUNT" lines)
  local file="$1" kind="$2" findings="$3" sym count IFS
  [ -n "$findings" ] || return 0
  fail=1
  report="${report}- \`${file}\` — duplicated top-level ${kind}:
"
  while IFS="$(printf '\t')" read -r sym count; do
    [ -n "$sym" ] || continue
    report="${report}  - \`${sym}\` (declared ${count} times)
"
  done <<EOF
$findings
EOF
}

# ── shell: duplicate top-level function declarations ─────────────────────────
while IFS= read -r -d '' f; do
  [ -n "$f" ] || continue
  findings="$(extract_shell_functions "$f" | duplicates_with_counts)"
  _record "$f" "function declarations" "$findings"
done < <(_find_files sh | LC_ALL=C sort -z)

# ── markdown: duplicate top-level headings ───────────────────────────────────
while IFS= read -r -d '' f; do
  [ -n "$f" ] || continue
  findings="$(extract_markdown_headings "$f" | duplicates_with_counts)"
  _record "$f" "headings" "$findings"
done < <(_find_files md | LC_ALL=C sort -z)

# ── json: duplicate object keys / unparseable files ──────────────────────────
json_files=()
while IFS= read -r -d '' f; do
  [ -n "$f" ] || continue
  json_files+=("$f")
done < <(_find_files json | LC_ALL=C sort -z)

if [ "${#json_files[@]}" -gt 0 ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "::error::check-duplicate-decls: python3 is required to validate JSON files but was not found" >&2
    exit 2
  fi
  json_report="$(python3 - "${json_files[@]}" <<'PY'
import json, sys, re
from collections import Counter

# Python's json decoder accepts NaN/Infinity by default; reject them explicitly
# so we don't pass non-standard JSON that strict consumers would reject.
_NAN_RE = re.compile(r'(?<!["\w])(-?Infinity|NaN)(?!["\w])')

rc = 0
out = []
for path in sys.argv[1:]:
    dups = []
    def hook(pairs, _dups=dups):
        for key, count in Counter(k for k, _ in pairs).items():
            if count > 1:
                _dups.append((key, count))
        return dict(pairs)
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
        if _NAN_RE.search(raw):
            raise ValueError("non-standard JSON literal (NaN/Infinity)")
        json.loads(raw, object_pairs_hook=hook)
    except (ValueError, OSError) as exc:
        rc = 1
        out.append("- `%s` — not parseable as JSON: %s" % (path, exc))
        continue
    if dups:
        rc = 1
        out.append("- `%s` — duplicated object keys:" % path)
        for key, count in dups:
            out.append("  - `%s` (declared %d times)" % (key, count))
print("\n".join(out))
sys.exit(rc)
PY
)" || {
    fail=1
    report="${report}${json_report}
"
  }
fi

if [ "$fail" -ne 0 ]; then
  echo "::error::Duplicate top-level declarations found — the #1485 corruption class. This merge is blocked."
  printf '%s\n' "$report"
  echo "This is the signature of a botched automated conflict resolution or a"
  echo "wholesale content duplication (see #1485 for the incident record and #1520"
  echo "for the private-repo gate this ports; #1025 for this port)."
  echo "Fix by removing the duplicated definitions — do not patch around the check."
  exit 1
fi

echo "duplicate-decl-gate: no duplicate top-level declarations under ${SCAN_DIR}"
