#!/usr/bin/env bats
# Tests for pp_check_gitignore_baseline in scripts/lib/push-protection.sh
# (invoked by scripts/compliance-audit.sh via pp_run_all_checks).
#
# Issue #799 (ENFORCE): the old pp_check_gitignore_secrets_block only verified
# 3 substrings (.env, *.pem, *.key) at `warning` severity, so a repo missing
# hundreds of baseline lines still passed. The upgraded check locates the
# `BEGIN … END petry-projects secrets baseline` marker span and compares it —
# by content hash — against the org canonical block, firing at `error`
# severity on a missing file, a missing block, or block drift. Everything
# BELOW the END marker (L2 ecosystem/OS entries) is never inspected.
bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

# The canonical marker text the check keys off of — must match the constants
# in scripts/lib/push-protection.sh byte-for-byte (note the em dash).
BEGIN_MARKER='# >>> BEGIN petry-projects secrets baseline (managed by .github — do not edit) >>>'
END_MARKER='# <<< END petry-projects secrets baseline <<<'

# A small synthetic canonical L1 block. The real block is ~390 lines; the
# check is block-agnostic, so a compact stand-in keeps the fixtures readable.
canonical_block() {
  cat <<EOF
$BEGIN_MARKER
.env
.env.*
!.env.example
*.pem
*.key
$END_MARKER
EOF
}

setup() {
  TEST_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/gib.XXXXXX")"
  MOCK_BIN="$TEST_TMP/bin"
  mkdir -p "$MOCK_BIN"
  # No-op sleep so the gh_api retry path runs instantly.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/sleep"
  chmod +x "$MOCK_BIN/sleep"

  # A canonical .gitignore the check treats as the org source of truth. It has
  # an L2 note below the END marker to prove canonical extraction stops at END.
  CANON="$TEST_TMP/canonical.gitignore"
  { canonical_block; printf '\n# L2 — per-repo entries below\nnode_modules/\n'; } > "$CANON"
}

teardown() { rm -rf "$TEST_TMP"; }

# _run_check <gh-mock-body>: install a mock gh, source the audit with the
# synthetic canonical block, run pp_check_gitignore_baseline, print findings.
_run_check() {
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$MOCK_BIN/gh"
  chmod +x "$MOCK_BIN/gh"
  PATH="$MOCK_BIN:$PATH" REPORT_DIR="$TEST_TMP" ORG="petry-projects" \
    PP_CANONICAL_GITIGNORE="$CANON" bash -c '
      set -uo pipefail
      echo "[]" > "$REPORT_DIR/findings.json"
      # shellcheck disable=SC1090
      source "'"$REPO_ROOT"'/scripts/compliance-audit.sh"
      pp_check_gitignore_baseline "demo-repo"
      cat "$REPORT_DIR/findings.json"
    '
}

# gh mock that returns $1 (a repo .gitignore body) base64-encoded, as the
# contents API `--jq .content` extraction would.
_gh_returns_gitignore() {
  local b64
  b64="$(printf '%s' "$1" | base64 | tr -d '\n')"
  printf 'printf "%s\\n"; exit 0' "$b64"
}

# ---------------------------------------------------------------------------
# Fixture 1 — compliant: block copied verbatim → no finding
# ---------------------------------------------------------------------------
@test "compliant .gitignore (verbatim block) → no finding" {
  run _run_check "$(_gh_returns_gitignore "$(canonical_block)")"
  [ "$status" -eq 0 ]
  [[ "$output" != *"gitignore_baseline"* ]]
}

@test "verbatim block with extra trailing newlines still passes (trailing-newline tolerant)" {
  body="$(printf '%s\n\n\n' "$(canonical_block)")"
  run _run_check "$(_gh_returns_gitignore "$body")"
  [ "$status" -eq 0 ]
  [[ "$output" != *"gitignore_baseline"* ]]
}

# ---------------------------------------------------------------------------
# Fixture 2 — missing block: file exists but has no markers → error
# ---------------------------------------------------------------------------
@test "undecodable API response (non-base64 content) → error finding (not silent skip)" {
  # Simulate an API error body leaking through the gh wrapper; not valid base64
  # so base64 decode fails and gi_content ends up empty.
  run _run_check 'printf "error: repository not found\n"; exit 0'
  [ "$status" -eq 0 ]
  [[ "$output" == *"gitignore_baseline"* ]]
  [[ "$output" == *"error"* ]]
}


@test "no .gitignore at all → error finding" {
  run _run_check 'echo "gh: Not Found (HTTP 404)" >&2; exit 1'
  [ "$status" -eq 0 ]
  [[ "$output" == *"gitignore_baseline"* ]]
  [[ "$output" == *"error"* ]]
}

@test ".gitignore without the marker block → error finding" {
  body=$'node_modules/\n.env\n*.pem\n*.key\n.DS_Store\n'
  run _run_check "$(_gh_returns_gitignore "$body")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gitignore_baseline"* ]]
  [[ "$output" == *"error"* ]]
}

# ---------------------------------------------------------------------------
# Fixture 3 — drifted block: markers present but content edited → error
# ---------------------------------------------------------------------------
@test "block with an edited line inside the markers → drift error" {
  # Drop `.env` from inside the block.
  body="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$BEGIN_MARKER" ".env.*" "!.env.example" "*.pem" "*.key" "$END_MARKER")"
  run _run_check "$(_gh_returns_gitignore "$body")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gitignore_baseline"* ]]
  [[ "$output" == *"error"* ]]
  [[ "$output" == *"drift"* ]]
}

@test "block with an extra line injected inside the markers → drift error" {
  body="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$BEGIN_MARKER" ".env" ".env.*" "!.env.example" "*.pem" "*.key" "$END_MARKER" \
    | sed "s#\*.key#*.key\nid_rsa#")"
  run _run_check "$(_gh_returns_gitignore "$body")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gitignore_baseline"* ]]
  [[ "$output" == *"error"* ]]
}

# ---------------------------------------------------------------------------
# Fixture 4 — block present + L2 extensions below END → passes (L2 is free)
# ---------------------------------------------------------------------------
@test "verbatim block followed by L2 ecosystem/OS entries → no finding" {
  body="$(printf '%s\n\n# L2 ecosystem/OS extensions\nnode_modules/\n__pycache__/\ntarget/\n.DS_Store\n' "$(canonical_block)")"
  run _run_check "$(_gh_returns_gitignore "$body")"
  [ "$status" -eq 0 ]
  [[ "$output" != *"gitignore_baseline"* ]]
}

@test "L2 re-adding a broad pattern below END does not trip the check (only the block is inspected)" {
  # A repo appends `*.pem` again in L2 — questionable practice, but the check
  # only inspects the marker span, so this must NOT be flagged as drift.
  body="$(printf '%s\n\n# L2\n*.pem\nbuild/\n' "$(canonical_block)")"
  run _run_check "$(_gh_returns_gitignore "$body")"
  [ "$status" -eq 0 ]
  [[ "$output" != *"gitignore_baseline"* ]]
}
