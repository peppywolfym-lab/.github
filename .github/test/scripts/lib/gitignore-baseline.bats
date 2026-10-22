#!/usr/bin/env bats
# Tests for scripts/lib/gitignore-baseline.sh — the shared, idempotent upsert of
# the org secrets baseline (L1) into a repo's .gitignore, preserving per-repo L2.
#
# The lib is pure text transformation (no gh, no network): given the canonical
# marker-wrapped L1 block and an existing .gitignore, it inserts the block on top
# when absent, replaces it in place when present, and never touches the L2 lines
# below the END marker. Shared by bootstrap, deploy/sync, and STORY4 remediation.

load 'helpers/setup'

setup() {
  tt_make_tmpdir
  # shellcheck source=scripts/lib/gitignore-baseline.sh
  source "${TT_SCRIPTS_LIB_DIR}/gitignore-baseline.sh"

  # A small synthetic canonical baseline: markers, a broad pattern carved out by a
  # negation (the discipline the lib must preserve), and the STORY3 anchors.
  BLOCK="${TT_TMP}/canonical.gitignore"
  cat > "$BLOCK" <<EOF
${GIB_BEGIN_MARKER}
# petry-projects baseline — SECRETS ONLY
.env
!.env.example
*.pem
!*.pub
*.key
${GIB_END_MARKER}
EOF
}

teardown() { tt_cleanup_tmpdir; }

# ── extraction ────────────────────────────────────────────────────────────────
@test "gib_extract_baseline_block pulls the BEGIN..END block inclusive" {
  run gib_extract_baseline_block "$BLOCK"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$GIB_BEGIN_MARKER" ]
  [ "${lines[${#lines[@]}-1]}" = "$GIB_END_MARKER" ]
  [[ "$output" == *".env"* ]]
  [[ "$output" == *"!.env.example"* ]]
}

@test "gib_extract_baseline_block fails when no markers are present" {
  local nomarkers="${TT_TMP}/plain"
  printf 'node_modules/\ndist/\n' > "$nomarkers"
  run gib_extract_baseline_block "$nomarkers"
  [ "$status" -ne 0 ]
}

@test "gib_extract_baseline_block works on the real repo /.gitignore (anchors present)" {
  run gib_extract_baseline_block "${TT_REPO_ROOT}/.gitignore"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$GIB_BEGIN_MARKER" ]
  [ "${lines[${#lines[@]}-1]}" = "$GIB_END_MARKER" ]
  # STORY3 anchors must live inside the block.
  grep -qxF '.env' <<< "$output"
  grep -qxF '*.pem' <<< "$output"
  grep -qxF '*.key' <<< "$output"
}

# ── absent → insert on top ────────────────────────────────────────────────────
@test "absent: inserts the block on top, existing content becomes L2 below END" {
  local existing="${TT_TMP}/existing"
  printf '# repo extras\nnode_modules/\ndist/\n' > "$existing"

  run upsert_gitignore_baseline "$BLOCK" "$existing"
  [ "$status" -eq 0 ]

  # Block on top.
  [ "${lines[0]}" = "$GIB_BEGIN_MARKER" ]
  # The END marker precedes the L2 lines.
  local end_ln node_ln
  end_ln="$(printf '%s\n' "$output" | grep -nxF "$GIB_END_MARKER" | head -1 | cut -d: -f1)"
  node_ln="$(printf '%s\n' "$output" | grep -nxF 'node_modules/' | head -1 | cut -d: -f1)"
  [ -n "$end_ln" ] && [ -n "$node_ln" ]
  [ "$end_ln" -lt "$node_ln" ]
  # L2 preserved verbatim.
  grep -qxF 'node_modules/' <<< "$output"
  grep -qxF 'dist/' <<< "$output"
}

@test "absent + empty existing: output is exactly the block" {
  run upsert_gitignore_baseline "$BLOCK"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$GIB_BEGIN_MARKER" ]
  [ "${lines[${#lines[@]}-1]}" = "$GIB_END_MARKER" ]
  # No stray L2.
  [ "$(printf '%s\n' "$output" | grep -cxF "$GIB_BEGIN_MARKER")" -eq 1 ]
}

# ── present → replace in place ────────────────────────────────────────────────
@test "present: replaces a stale block between markers, leaving L2 intact" {
  # A repo whose L1 block is an OLD/short version, with real L2 below END.
  local existing="${TT_TMP}/existing"
  cat > "$existing" <<EOF
${GIB_BEGIN_MARKER}
.env
${GIB_END_MARKER}
# --- repo L2 ---
node_modules/
target/
EOF

  run upsert_gitignore_baseline "$BLOCK" "$existing"
  [ "$status" -eq 0 ]

  # The refreshed block now carries the anchors the stale one lacked.
  grep -qxF '*.pem' <<< "$output"
  grep -qxF '*.key' <<< "$output"
  grep -qxF '!.env.example' <<< "$output"
  # L2 is untouched and still below the (single) END marker.
  grep -qxF 'node_modules/' <<< "$output"
  grep -qxF 'target/' <<< "$output"
  [ "$(printf '%s\n' "$output" | grep -cxF "$GIB_END_MARKER")" -eq 1 ]
  local end_ln l2_ln
  end_ln="$(printf '%s\n' "$output" | grep -nxF "$GIB_END_MARKER" | head -1 | cut -d: -f1)"
  l2_ln="$(printf '%s\n' "$output" | grep -nxF 'target/' | head -1 | cut -d: -f1)"
  [ "$end_ln" -lt "$l2_ln" ]
}

# ── idempotency ───────────────────────────────────────────────────────────────
@test "idempotent: upserting an already-upserted file is a no-op" {
  local existing="${TT_TMP}/existing"
  printf 'node_modules/\ndist/\n' > "$existing"

  local first second
  first="$(upsert_gitignore_baseline "$BLOCK" "$existing")"
  printf '%s\n' "$first" > "${TT_TMP}/after1"
  second="$(upsert_gitignore_baseline "$BLOCK" "${TT_TMP}/after1")"
  [ "$first" = "$second" ]
}

# ── negation discipline ───────────────────────────────────────────────────────
@test "negations survive verbatim and stay immediately after their broad pattern" {
  run upsert_gitignore_baseline "$BLOCK"
  [ "$status" -eq 0 ]
  # !.env.example must appear on the line right after .env (order preserved).
  local env_ln neg_ln
  env_ln="$(printf '%s\n' "$output" | grep -nxF '.env' | head -1 | cut -d: -f1)"
  neg_ln="$(printf '%s\n' "$output" | grep -nxF '!.env.example' | head -1 | cut -d: -f1)"
  [ -n "$env_ln" ] && [ -n "$neg_ln" ]
  [ "$neg_ln" -eq "$((env_ln + 1))" ]
}

@test "replace does not drop a negation the stale block already carried" {
  local existing="${TT_TMP}/existing"
  cat > "$existing" <<EOF
${GIB_BEGIN_MARKER}
.env
!.env.example
${GIB_END_MARKER}
dist/
EOF
  run upsert_gitignore_baseline "$BLOCK" "$existing"
  [ "$status" -eq 0 ]
  grep -qxF '!.env.example' <<< "$output"
  grep -qxF '!*.pub' <<< "$output"
}

# ── half-open marker detection ────────────────────────────────────────────────
@test "upsert fails on a file with only BEGIN marker (half-open state)" {
  local half_open="${TT_TMP}/half-open-begin"
  cat > "$half_open" <<EOF
${GIB_BEGIN_MARKER}
.env
node_modules/
EOF
  run upsert_gitignore_baseline "$BLOCK" "$half_open"
  [ "$status" -eq 2 ]
  [[ "$output" == *"half-open"* ]]
}

@test "upsert fails on a file with only END marker (half-open state)" {
  local half_open="${TT_TMP}/half-open-end"
  cat > "$half_open" <<EOF
.env
node_modules/
${GIB_END_MARKER}
EOF
  run upsert_gitignore_baseline "$BLOCK" "$half_open"
  [ "$status" -eq 2 ]
  [[ "$output" == *"half-open"* ]]
}

# ── #809: baseline negations must win over a re-hiding L2 pattern ──────────────
# Reproduces the fleet dry-run failure on `markets` / `google-app-scripts`: an
# ad-hoc L2 with a broad `*.pem` and no `!public.pem` re-hid the file the L1 block
# re-allows. Assert against real git semantics with `git check-ignore`.

# _gib_check_ignored <gitignore_content> <path>
# Return 0 if <path> is ignored, 1 if not — mirrors the issue's repro probe.
_gib_check_ignored() {
  local content="$1" path="$2" d
  d="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  ( cd "$d" && git init -q )
  printf '%s\n' "$content" > "$d/.gitignore"
  ( cd "$d" && git -c core.excludesfile=/dev/null check-ignore -q "$path" )
  local rc=$?
  rm -rf "$d"
  return "$rc"
}

@test "#809 markets-like: broad *.pem in L2 does not re-hide baseline-negated public.pem" {
  # Use the REAL canonical block (it carries !public.pem after *.pem).
  local realblock="${TT_TMP}/realblock"
  gib_extract_baseline_block "${TT_REPO_ROOT}/.gitignore" > "$realblock"

  local existing="${TT_TMP}/markets"
  printf '# markets ad-hoc\n*.pem\nnode_modules/\n' > "$existing"

  # Capture the upsert output in its own var — bats clobbers $output on every `run`.
  local gi
  gi="$(upsert_gitignore_baseline "$realblock" "$existing")"

  run _gib_check_ignored "$gi" public.pem
  [ "$status" -eq 1 ]   # NOT ignored
  # A genuine secret pem is still ignored by the baseline.
  run _gib_check_ignored "$gi" secret.pem
  [ "$status" -eq 0 ]
  # Genuine L2 survives.
  grep -qxF 'node_modules/' <<< "$gi"
}

@test "#809 google-app-scripts-like: broad *.pem in L2 does not re-hide public.pem" {
  local realblock="${TT_TMP}/realblock"
  gib_extract_baseline_block "${TT_REPO_ROOT}/.gitignore" > "$realblock"

  local existing="${TT_TMP}/gas"
  printf '.clasp.json\n*.pem\n' > "$existing"

  local gi
  gi="$(upsert_gitignore_baseline "$realblock" "$existing")"

  run _gib_check_ignored "$gi" public.pem
  [ "$status" -eq 1 ]   # NOT ignored
  grep -qxF '.clasp.json' <<< "$gi"
}

@test "#809 non-identical: .env* glob in L2 does not re-hide baseline-negated .env.example" {
  # `.env*` is NOT an exact match for `.env` or `.env.*` in the baseline, so
  # the current exact-drop logic leaves it in L2 — but it would re-hide
  # `!.env.example`. The re-allow tail must win.
  local realblock="${TT_TMP}/realblock"
  gib_extract_baseline_block "${TT_REPO_ROOT}/.gitignore" > "$realblock"

  local existing="${TT_TMP}/envglob"
  printf '# project extras\n.env*\nnode_modules/\n' > "$existing"

  local gi
  gi="$(upsert_gitignore_baseline "$realblock" "$existing")"

  run _gib_check_ignored "$gi" .env.example
  [ "$status" -eq 1 ]   # NOT ignored — baseline negation must win
  run _gib_check_ignored "$gi" .env.production
  [ "$status" -eq 0 ]   # ignored — broad coverage still applies
  grep -qxF 'node_modules/' <<< "$gi"
}

@test "#809 non-identical: **/*.pem glob in L2 does not re-hide baseline-negated public.pem" {
  # `**/*.pem` is NOT an exact match for `*.pem` in the baseline, so the
  # exact-drop logic leaves it in L2 — but it would re-hide `!public.pem`.
  # The re-allow tail must win.
  local realblock="${TT_TMP}/realblock"
  gib_extract_baseline_block "${TT_REPO_ROOT}/.gitignore" > "$realblock"

  local existing="${TT_TMP}/doublepem"
  printf '# project extras\n**/*.pem\nnode_modules/\n' > "$existing"

  local gi
  gi="$(upsert_gitignore_baseline "$realblock" "$existing")"

  run _gib_check_ignored "$gi" public.pem
  [ "$status" -eq 1 ]   # NOT ignored — baseline negation must win
  run _gib_check_ignored "$gi" secret.pem
  [ "$status" -eq 0 ]   # ignored — broad coverage still applies
  grep -qxF 'node_modules/' <<< "$gi"
}

# ── #809/#817: migrate an existing unmarkered baseline, don't duplicate it ─────
@test "#809/#817 TalkTerm-like: unmarkered baseline in L2 is folded into one block, no tail, genuine L2 kept" {
  # L2 IS a copy of the old unmarkered baseline (same secret lines, no markers),
  # plus genuine ecosystem/OS entries the repo legitimately added.
  local existing="${TT_TMP}/talkterm"
  cat > "$existing" <<EOF
.env
!.env.example
*.pem
!*.pub
*.key
node_modules/
dist/
*.log
.DS_Store
EOF

  run upsert_gitignore_baseline "$BLOCK" "$existing"
  [ "$status" -eq 0 ]

  # Exactly one marker-wrapped block.
  [ "$(printf '%s\n' "$output" | grep -cxF "$GIB_BEGIN_MARKER")" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -cxF "$GIB_END_MARKER")" -eq 1 ]
  # Broad patterns are folded into the block and appear exactly once.
  [ "$(printf '%s\n' "$output" | grep -cxF '.env')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -cxF '*.pem')" -eq 1 ]
  # #817: the genuine L2 (node_modules/, dist/, *.log, .DS_Store) re-hides none
  # of the baseline-negated paths, so NO negation tail is appended — each
  # negation appears exactly once (inside the block only).
  [ "$(printf '%s\n' "$output" | grep -cxF '!.env.example')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -cxF '!*.pub')" -eq 1 ]
  # Genuine ecosystem/OS L2 entries are preserved.
  grep -qxF 'node_modules/' <<< "$output"
  grep -qxF 'dist/' <<< "$output"
  grep -qxF '*.log' <<< "$output"
  grep -qxF '.DS_Store' <<< "$output"
}

# ── #817: negation tail is CONDITIONAL — only re-emit what L2 actually re-hides ─
@test "#817 clean L2 (no re-hider) appends NO negation tail; upsert is a first-application fixed point" {
  # A marker-wrapped file whose L2 is genuine ecosystem/OS cruft that re-hides
  # nothing the block negates. The steady state must be block + L2 verbatim (no
  # negation tail), and re-upserting it must be a byte-for-byte no-op — on the
  # FIRST application, not only from the second pass on.
  local existing="${TT_TMP}/clean"
  {
    cat "$BLOCK"
    printf 'node_modules/\n.DS_Store\n'
  } > "$existing"

  local out
  out="$(upsert_gitignore_baseline "$BLOCK" "$existing")"

  # No negation tail: !.env.example / !*.pub appear ONLY inside the block (once).
  [ "$(printf '%s\n' "$out" | grep -cxF '!.env.example')" -eq 1 ]
  [ "$(printf '%s\n' "$out" | grep -cxF '!*.pub')" -eq 1 ]
  # Genuine L2 preserved.
  grep -qxF 'node_modules/' <<< "$out"
  grep -qxF '.DS_Store' <<< "$out"
  # Fixed point on the FIRST application: upsert(block + clean-L2) == input.
  [ "$out" = "$(cat "$existing")" ]
}

# ── #817 Part B: dedup migrated baseline comments (never a bare-# or repo one) ──
@test "#817 migrated baseline section comment (block-identical) is dropped; repo comments kept" {
  # Simulate migrating an OLD unmarkered baseline whose section comment is
  # byte-identical to the current block's comment — it must fold away, while
  # the repo's own comment stays put.
  local existing="${TT_TMP}/migrated"
  cat > "$existing" <<EOF
# petry-projects baseline — SECRETS ONLY
.env
!.env.example
*.pem
# repo's own note
node_modules/
EOF

  local out l2
  out="$(upsert_gitignore_baseline "$BLOCK" "$existing")"
  l2="$(printf '%s\n' "$out" | awk -v e="$GIB_END_MARKER" 'seen{print} $0==e{seen=1}')"

  # The block-identical section comment is dropped from L2 (folded away)…
  [ "$(printf '%s\n' "$l2" | grep -cxF '# petry-projects baseline — SECRETS ONLY')" -eq 0 ]
  # …but the block still carries it exactly once (inside the block).
  [ "$(printf '%s\n' "$out" | grep -cxF '# petry-projects baseline — SECRETS ONLY')" -eq 1 ]
  # The repo's own comment and genuine L2 survive.
  grep -qxF "# repo's own note" <<< "$l2"
  grep -qxF 'node_modules/' <<< "$l2"
}

@test "#817 bare-# separator in L2 survives even though the canonical block also uses bare #" {
  # The real canonical block contains bare `#` separator lines. Part B must
  # NEVER drop a bare `#` from L2 — repos legitimately reuse it as a divider,
  # and dropping it would clobber the repo's own layout (and break the
  # already-current fixed point, since the canonical L2 leads with a bare #).
  local realblock="${TT_TMP}/realblock"
  gib_extract_baseline_block "${TT_REPO_ROOT}/.gitignore" > "$realblock"

  local existing="${TT_TMP}/withbarehash"
  printf '#\n# my section\nnode_modules/\n' > "$existing"

  local out l2
  out="$(upsert_gitignore_baseline "$realblock" "$existing")"
  l2="$(printf '%s\n' "$out" | awk -v e="$GIB_END_MARKER" 'seen{print} $0==e{seen=1}')"

  grep -qxF '#' <<< "$l2"            # bare # kept
  grep -qxF '# my section' <<< "$l2"
  grep -qxF 'node_modules/' <<< "$l2"
}

@test "#817 already-current canonical .gitignore is a byte-for-byte fixed point" {
  # With the conditional tail, upsert(block, canonical) == canonical again
  # (the canonical L2 re-hides nothing and its bare-# separator is preserved).
  local realblock="${TT_TMP}/realblock"
  gib_extract_baseline_block "${TT_REPO_ROOT}/.gitignore" > "$realblock"

  local out
  out="$(upsert_gitignore_baseline "$realblock" "${TT_REPO_ROOT}/.gitignore")"
  [ "$out" = "$(cat "${TT_REPO_ROOT}/.gitignore")" ]
}

@test "#809 negation-win + migration is idempotent" {
  local realblock="${TT_TMP}/realblock"
  gib_extract_baseline_block "${TT_REPO_ROOT}/.gitignore" > "$realblock"

  local existing="${TT_TMP}/markets2"
  printf '# markets ad-hoc\n*.pem\nnode_modules/\n' > "$existing"

  local first second
  first="$(upsert_gitignore_baseline "$realblock" "$existing")"
  printf '%s\n' "$first" > "${TT_TMP}/after1"
  second="$(upsert_gitignore_baseline "$realblock" "${TT_TMP}/after1")"
  [ "$first" = "$second" ]
}
