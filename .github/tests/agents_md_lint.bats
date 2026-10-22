#!/usr/bin/env bats
# Unit tests for the standalone AGENTS.md structural linter
# (scripts/agents-md-lint.sh) — Phase 2 of epic #642, story #644.
#
# The linter's pure classification/parse helpers are sourceable and are exercised
# here directly over synthetic fixtures in tests/fixtures/agents-md/ — no network,
# no repo enumeration (that is Phase 3's job). This mirrors the repo's established
# pattern of pure, sourceable helpers gated by pure bats tests (see
# tests/persona_mention.bats sourcing scripts/lib/persona-mention.sh).
#
# Coverage: a structurally-valid AGENTS.md plus one fixture per failure mode
# (missing required section, skipped heading level, dangling cross-reference),
# the informational (exit 0) vs failing (exit nonzero) mode flag, machine-readable
# severity-tagged output, and the individual pure helpers.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/agents-md-lint.sh"
  RULES="$REPO_ROOT/scripts/lib/agents-md-rules.json"
  FIX="$REPO_ROOT/tests/fixtures/agents-md"
  # shellcheck source=/dev/null
  source "$SCRIPT"
}

# --- slugify ---------------------------------------------------------------

@test "amdl_slugify lowercases, hyphenates spaces, strips punctuation" {
  run amdl_slugify "Development Standards"
  [ "$status" -eq 0 ]
  [ "$output" = "development-standards" ]
}

@test "amdl_slugify drops non-alphanumeric characters (matches GitHub anchors)" {
  run amdl_slugify "CI/CD & Secrets!"
  [ "$status" -eq 0 ]
  [ "$output" = "cicd--secrets" ]
}

# --- heading extraction (ignores fenced code) ------------------------------

@test "amdl_extract_headings emits level<TAB>line<TAB>text and skips code fences" {
  run amdl_extract_headings "$FIX/valid.md"
  [ "$status" -eq 0 ]
  headings_out="$output"
  # Exactly one H1, and the '#' inside the bash fence is not emitted.
  h1_count="$(printf '%s\n' "$headings_out" | awk -F'\t' '$1==1' | wc -l | tr -d ' ')"
  [ "$h1_count" -eq 1 ]
  # The commented '#' inside the fenced block must not appear as a heading.
  run grep -q 'inside a fenced code block' <<< "$headings_out"
  [ "$status" -eq 1 ]
  # The H3 sub-detail is captured at level 3.
  printf '%s\n' "$headings_out" | grep -qP '^3\t'
}

# --- single H1 -------------------------------------------------------------

@test "amdl_check_single_h1 passes on the valid fixture (no output)" {
  run amdl_check_single_h1 "$FIX/valid.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "amdl_check_single_h1 flags a file with two H1s" {
  tmp="$(mktemp)"
  printf '# One\n\ntext\n\n# Two\n' > "$tmp"
  run amdl_check_single_h1 "$tmp"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "amdl_check_single_h1 flags a file with zero H1s" {
  tmp="$(mktemp)"
  printf '## Only an H2\n\ntext\n' > "$tmp"
  run amdl_check_single_h1 "$tmp"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# --- heading hierarchy -----------------------------------------------------

@test "amdl_check_heading_hierarchy passes on the valid fixture" {
  run amdl_check_heading_hierarchy "$FIX/valid.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "amdl_check_heading_hierarchy flags a skipped level (H2 -> H4)" {
  run amdl_check_heading_hierarchy "$FIX/skipped-heading.md"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# --- fenced code-block closure --------------------------------------------

@test "amdl_check_fenced_code_closure passes when fences are balanced" {
  run amdl_check_fenced_code_closure "$FIX/valid.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "amdl_check_fenced_code_closure flags an unclosed fence" {
  tmp="$(mktemp)"
  printf '# Title\n\n```bash\necho unclosed\n' > "$tmp"
  run amdl_check_fenced_code_closure "$tmp"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# --- cross-reference integrity --------------------------------------------

@test "amdl_check_cross_references resolves relative link and anchor in the valid fixture" {
  run amdl_check_cross_references "$FIX/valid.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "amdl_check_cross_references flags a dangling relative link" {
  run amdl_check_cross_references "$FIX/dangling-xref.md"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  printf '%s\n' "$output" | grep -q 'does-not-exist.md'
}

@test "amdl_check_cross_references ignores http(s) URLs" {
  run amdl_check_cross_references "$FIX/dangling-xref.md"
  [ "$status" -eq 0 ]
  xref_out="$output"
  run grep -q 'example.com' <<< "$xref_out"
  [ "$status" -eq 1 ]
  run grep -q 'agents.md' <<< "$xref_out"
  [ "$status" -eq 1 ]
}

@test "amdl_check_cross_references flags a broken in-document anchor" {
  tmp="$(mktemp)"
  printf '# Title\n\nSee [broken](#no-such-heading).\n\n## Real Heading\n' > "$tmp"
  run amdl_check_cross_references "$tmp"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# --- section presence ------------------------------------------------------

@test "amdl_check_section_present finds a present section (no output)" {
  run amdl_check_section_present "$FIX/valid.md" 'security|secrets'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "amdl_check_section_present flags an absent section" {
  run amdl_check_section_present "$FIX/missing-section.md" 'security|secrets'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# --- rule-level lookup (data-driven severity) ------------------------------

@test "amdl_rule_level reads the level straight from the rule-set data file" {
  run amdl_rule_level "$RULES" heading-hierarchy-valid
  [ "$status" -eq 0 ]
  [ "$output" = "required" ]
  run amdl_rule_level "$RULES" security-section-present
  [ "$status" -eq 0 ]
  [ "$output" = "recommended" ]
}

# --- end-to-end driver + severity-tagged output ----------------------------

@test "valid fixture produces no required-level findings and exits 0 in both modes" {
  run bash "$SCRIPT" --mode informational "$FIX/valid.md"
  [ "$status" -eq 0 ]
  info_out="$output"
  run grep -q '^required' <<< "$info_out"
  [ "$status" -eq 1 ]
  run bash "$SCRIPT" --mode failing "$FIX/valid.md"
  [ "$status" -eq 0 ]
}

@test "output lines are machine-readable severity-tagged TSV" {
  run bash "$SCRIPT" --mode informational "$FIX/skipped-heading.md"
  [ "$status" -eq 0 ]
  # Each finding: severity<TAB>rule_id<TAB>line<TAB>message, severity is a known tag.
  printf '%s\n' "$output" | grep -qP '^(required|recommended)\t[a-z0-9-]+\t'
}

@test "missing required section is a recommended finding — reported but never fails" {
  run bash "$SCRIPT" --mode informational "$FIX/missing-section.md"
  [ "$status" -eq 0 ]
  missing_out="$output"
  printf '%s\n' "$missing_out" | grep -qP '^recommended\tsecurity-section-present\t'
  # No required-level finding for this structurally-sound-but-section-light file.
  run grep -q '^required' <<< "$missing_out"
  [ "$status" -eq 1 ]
  # And even in failing mode a recommended-only file passes.
  run bash "$SCRIPT" --mode failing "$FIX/missing-section.md"
  [ "$status" -eq 0 ]
}

@test "skipped heading level is a required finding that fails --mode failing" {
  run bash "$SCRIPT" --mode informational "$FIX/skipped-heading.md"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qP '^required\theading-hierarchy-valid\t'
  run bash "$SCRIPT" --mode failing "$FIX/skipped-heading.md"
  [ "$status" -eq 1 ]
}

@test "dangling cross-reference is a required finding that fails --mode failing" {
  run bash "$SCRIPT" --mode informational "$FIX/dangling-xref.md"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qP '^required\tcross-reference-integrity\t'
  run bash "$SCRIPT" --mode failing "$FIX/dangling-xref.md"
  [ "$status" -eq 1 ]
}

@test "default mode is informational (exit 0 even with required findings)" {
  run bash "$SCRIPT" "$FIX/skipped-heading.md"
  [ "$status" -eq 0 ]
}

@test "a missing target file is reported as an error (exit 2)" {
  run bash "$SCRIPT" "$FIX/no-such-file.md"
  [ "$status" -eq 2 ]
}
