#!/usr/bin/env bats
# Tests for scripts/check-duplicate-decls.sh — the required duplicate-decl CI
# gate ported into petry-projects/.github (#1025). Mirrors the #1485 corruption
# signature (whole-block duplication of a top-level declaration) and covers the
# markdown/JSON extension this repo adds on top of the shell-only gate that
# guards petry-projects/.github-private (#1520).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  GATE="$REPO_ROOT/scripts/check-duplicate-decls.sh"
  WORKDIR="$(mktemp -d "$BATS_TEST_TMPDIR/scan.XXXXXX")"
}

# ── The audit guard (AC: audit main; a green tree stays green) ────────────────

@test "gate: the repo's own tree is clean (green on main)" {
  run bash "$GATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no duplicate"* ]]
}

# ── Shell: duplicate top-level function declarations (the #1485 class) ────────

@test "shell: fails on a duplicated top-level function and names it" {
  cat > "$WORKDIR/dup.sh" <<'EOF'
#!/usr/bin/env bash
run_writer() { echo one; }
other() { echo x; }
run_writer() { echo two; }
EOF
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"run_writer"* ]]
  [[ "$output" == *"2 times"* ]]
}

@test "shell: failure output points at the #1485 incident record" {
  cat > "$WORKDIR/dup.sh" <<'EOF'
#!/usr/bin/env bash
foo() { echo 1; }
foo() { echo 2; }
EOF
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"#1485"* ]]
}

@test "shell: catches duplicates defined with multiline 'name()\\n{' syntax" {
  cat > "$WORKDIR/multiline.sh" <<'EOF'
#!/usr/bin/env bash
foo()
{
  echo 1
}
foo()
{
  echo 2
}
EOF
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"foo"* ]]
}

@test "shell: 'function NAME' keyword-form duplicates are caught" {
  cat > "$WORKDIR/fnkw.sh" <<'EOF'
#!/usr/bin/env bash
function bar { echo 1; }
function bar { echo 2; }
EOF
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bar"* ]]
}

@test "shell: a duplicated top-level VAR alone does not fail (functions only)" {
  cat > "$WORKDIR/vars.sh" <<'EOF'
#!/usr/bin/env bash
RC=0
one() { echo 1; }
RC=1
two() { echo 2; }
EOF
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 0 ]
}

@test "shell: an indented (nested) function repeated is not a top-level dup" {
  cat > "$WORKDIR/nested.sh" <<'EOF'
#!/usr/bin/env bash
outer() {
  inner() { echo a; }
  inner() { echo b; }
}
EOF
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 0 ]
}

@test "shell: scans nested subdirectories" {
  mkdir -p "$WORKDIR/lib"
  cat > "$WORKDIR/lib/dup.sh" <<'EOF'
#!/usr/bin/env bash
dup() { echo 1; }
dup() { echo 2; }
EOF
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"dup"* ]]
}

@test "shell: a 'function NAME' line inside a heredoc is not a declaration" {
  cat > "$WORKDIR/heredoc.sh" <<'OUTER'
#!/usr/bin/env bash
real_fn() { echo real; }
cat <<'EOF'
function fake_fn
function fake_fn
EOF
OUTER
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 0 ]
}

# ── Markdown: duplicate top-level (H1/H2) headings, fence-aware ───────────────

@test "markdown: fails on a duplicated top-level heading" {
  cat > "$WORKDIR/doc.md" <<'EOF'
# Title

## Overview
text

## Details
text

## Overview
duplicated section
EOF
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overview"* ]]
}

@test "markdown: '#'-comments inside a fenced code block are not headings" {
  cat > "$WORKDIR/doc.md" <<'EOF'
# Title

## Usage

```bash
# Run it for real:
do_thing
# Run it for real:
do_thing_again
```
EOF
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 0 ]
}

@test "markdown: heading inside a 4-backtick fence is not detected (3-backtick cannot close 4-backtick)" {
  cat > "$WORKDIR/doc.md" <<'EOF'
# Title

````bash
## Not a real heading
## Not a real heading
````
EOF
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 0 ]
}

@test "markdown: headings inside an HTML comment block are not detected" {
  cat > "$WORKDIR/doc.md" <<'EOF'
# Title

<!--
## Hidden Section
## Hidden Section
-->

## Real Section
EOF
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 0 ]
}

@test "markdown: duplicated sub-headings (H3+) do not fail (top-level only)" {
  cat > "$WORKDIR/doc.md" <<'EOF'
# Title

## Section A
### Agentic Directives
text

## Section B
### Agentic Directives
text
EOF
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 0 ]
}

@test "markdown: a duplicated H1 title is caught" {
  cat > "$WORKDIR/doc.md" <<'EOF'
# The Doc

body

# The Doc

duplicated title
EOF
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"The Doc"* ]]
}

# ── JSON: duplicate keys and parse failures ──────────────────────────────────

@test "json: fails on a duplicated key within the same object" {
  cat > "$WORKDIR/config.json" <<'EOF'
{
  "name": "a",
  "value": 1,
  "name": "b"
}
EOF
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"name"* ]]
}

@test "json: passes on a clean object that repeats a key in a different object" {
  cat > "$WORKDIR/config.json" <<'EOF'
{
  "a": {"context": "x"},
  "b": {"context": "y"}
}
EOF
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 0 ]
}

@test "json: fails on unparseable JSON (fail loud, never silently pass)" {
  cat > "$WORKDIR/broken.json" <<'EOF'
{ "unterminated": true
EOF
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 1 ]
}

@test "json: fails on non-standard JSON literals (NaN, Infinity)" {
  cat > "$WORKDIR/nan.json" <<'EOF'
{"value": NaN}
EOF
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-standard"* ]]
}

# ── Scope: excluded directories are skipped ──────────────────────────────────

@test "scope: excluded directories (tests fixtures, node_modules) are not scanned" {
  for d in tests test node_modules .git .dev-lead; do
    mkdir -p "$WORKDIR/$d"
    cat > "$WORKDIR/$d/dup.sh" <<'EOF'
#!/usr/bin/env bash
fixture() { echo 1; }
fixture() { echo 2; }
EOF
  done
  run bash "$GATE" "$WORKDIR"
  [ "$status" -eq 0 ]
}

@test "gate: non-existent scan directory is an error (exit 2)" {
  run bash "$GATE" "$WORKDIR/does-not-exist"
  [ "$status" -eq 2 ]
}
