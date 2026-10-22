#!/usr/bin/env bash
# lint-prompt.sh — guard against unescaped shell expansions in claude-code-action
# `direct_prompt:` blocks.
#
# Why this exists:
#   The original feature-ideation.yml contained:
#       Date: $(date -u +%Y-%m-%d)
#   inside the `direct_prompt:` heredoc. YAML does NOT expand shell, and
#   claude-code-action passes the prompt verbatim — Mary received the literal
#   string `$(date -u +%Y-%m-%d)` instead of an actual date. This is R2.
#
# This linter scans every workflow file under .github/workflows/ for
# `direct_prompt:` blocks and flags any unescaped `$(...)` or `${VAR}` that
# YAML/the action will not interpolate. ${{ ... }} (GitHub expression syntax)
# is allowed because GitHub Actions evaluates it before the prompt is sent.
#
# Usage:
#   lint-prompt.sh [<workflow.yml> ...]
#
# Exit codes:
#   0  no issues
#   1  one or more findings
#   2  bad usage / file error

set -euo pipefail

scan_file() {
  local file="$1"

  python3 - "$file" <<'PY'
import re
import sys


def _strip_github_expressions(s: str) -> str:
    """Remove ${{ ... }} GitHub Actions expressions from s.

    Uses a stateful scanner instead of `[^}]*` regex so that expressions
    containing `}` inside string literals (e.g. format() calls) are fully
    consumed rather than prematurely terminated. This prevents false-positive
    shell-expansion matches on content that is actually inside a GH expression.
    Caught by CodeRabbit review on PR petry-projects/.github#85.
    """
    result: list[str] = []
    i = 0
    while i < len(s):
        if s[i : i + 3] == "${{":
            # Consume until we find the matching "}}"
            j = i + 3
            while j < len(s):
                if s[j : j + 2] == "}}":
                    j += 2
                    break
                j += 1
            i = j  # skip the whole ${{ ... }} expression
        else:
            result.append(s[i])
            i += 1
    return "".join(result)


path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()
except OSError as exc:
    sys.stderr.write(f"[lint-prompt] cannot read {path}: {exc}\n")
    sys.exit(2)

# Find prompt blocks. claude-code-action v0 used `direct_prompt:`, v1 uses
# plain `prompt:`. Both forms are scanned. We treat everything indented MORE
# than the marker line as part of the block, until we hit a less-indented
# non-blank line.
in_block = False
block_indent = -1
findings = []

# Pattern matches $(...) and ${VAR} but NOT GitHub Actions ${{ ... }}
# (which is evaluated before the prompt is rendered) and NOT \$ or $$
# escapes (which produce literal characters in the rendered prompt).
# Both branches use the same lookbehind so escape handling is consistent.
# Caught by CodeRabbit review on PR petry-projects/.github#85.
shell_expansion = re.compile(r'(?<![\\$])\$\([^)]*\)|(?<![\\$])\$\{[A-Za-z_][A-Za-z0-9_]*\}')

# Recognise both `direct_prompt:` (v0) and `prompt:` (v1) markers, with
# optional `|` or `>` block scalar indicators plus YAML chomping modifiers
# (`-` or `+`) so `prompt: |-`, `prompt: |+`, `prompt: >-`, `prompt: >+`
# are all recognised. Caught by CodeRabbit review on PR petry-projects/.github#85.
prompt_marker = re.compile(r'(?:direct_prompt|prompt):\s*[|>]?[-+]?\s*$')

for lineno, raw in enumerate(lines, start=1):
    stripped = raw.lstrip(" ")
    indent = len(raw) - len(stripped)

    if not in_block:
        if prompt_marker.match(stripped):
            in_block = True
            block_indent = indent
            continue
    else:
        # Blank lines stay in the block.
        if stripped.strip() == "":
            continue
        # If we drop back to or below the marker indent, the block ended.
        if indent <= block_indent:
            in_block = False
            block_indent = -1
            continue

        # We're inside the prompt body. Scan for shell expansions.
        # First, strip out GitHub Actions ${{ ... }} expressions.
        # The naive `[^}]*` regex stops at the first `}`, so expressions that
        # contain `}` internally (e.g. format() calls or string literals) are
        # not fully removed and leave false-positive shell expansion matches.
        # Use a small stateful scanner instead.
        # Caught by CodeRabbit review on PR petry-projects/.github#85.
        no_gh = _strip_github_expressions(raw)
        for match in shell_expansion.finditer(no_gh):
            findings.append((lineno, match.group(0), raw.rstrip()))

if findings:
    sys.stderr.write(f"[lint-prompt] {len(findings)} unescaped shell expansion(s) in {path}:\n")
    for lineno, expr, line in findings:
        sys.stderr.write(f"  line {lineno}: {expr}\n")
        sys.stderr.write(f"    {line}\n")
    sys.exit(1)
sys.exit(0)
PY
  return $?
}

main() {
  if [ "$#" -eq 0 ]; then
    # Default: scan every workflow file.
    local repo_root
    repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
    local files=()
    while IFS= read -r f; do
      files+=("$f")
    done < <(find "${repo_root}/.github/workflows" -type f \( -name '*.yml' -o -name '*.yaml' \))
    set -- "${files[@]}"
  fi

  local exit=0
  local file_rc=0
  for file in "$@"; do
    if [ ! -f "$file" ]; then
      printf '[lint-prompt] not found: %s\n' "$file" >&2
      exit=2
      continue
    fi
    # Capture the actual exit code so we preserve exit-2 (file error) over
    # exit-1 (lint finding). A later lint failure must not overwrite an earlier
    # file error. Caught by CodeRabbit review on PR petry-projects/.github#85.
    if scan_file "$file"; then
      file_rc=0
    else
      file_rc=$?
    fi
    case "$file_rc" in
      0) ;;
      1) if [ "$exit" -eq 0 ]; then exit=1; fi ;;
      2) exit=2 ;;
      *) return "$file_rc" ;;
    esac
  done
  return "$exit"
}

main "$@"
