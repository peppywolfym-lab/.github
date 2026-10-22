#!/usr/bin/env bats
# Dry-run tests for scripts/sync-gitignore-baseline.sh (#798)
#
# The helper append-or-replaces the org secrets baseline (L1) in a repo's
# .gitignore via a PR, reusing upsert_gitignore_baseline() (never touching L2)
# and the sd_deploy_via_pr() PR primitive. These tests drive the dry-run path
# with a fake `gh`:
#   - a repo missing .gitignore            → plans a PR (INSERT)
#   - a repo whose .gitignore is current   → skip (already carries the baseline)
#   - a repo with a marker-less .gitignore → plans a PR (INSERT), L2 preserved
# --dry-run guarantees no mutating gh calls.

setup() {
  TT_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/sync-gitignore-baseline.sh"
  CANONICAL="${REPO_ROOT}/.gitignore"
  GH_CALLS="${TT_TMP}/gh-calls.log"; export GH_CALLS
  : > "$GH_CALLS"
}

teardown() { rm -rf "$TT_TMP"; }

# Fake gh. GH_CONTENT_B64 unset → contents API 404s (file absent); set → returned
# as the .gitignore body.
install_gh_stub() {
  local bin="${TT_TMP}/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
{ printf 'gh'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$GH_CALLS"
if [ "${1:-}" = "api" ]; then
  case "$2" in
    *contents*)
      if [ -n "${GH_CONTENT_B64:-}" ]; then
        printf '{"sha":"abc123","content":"%s"}' "$GH_CONTENT_B64"
        exit 0
      fi
      exit 1 ;;   # simulate 404 — file absent
  esac
fi
exit 0
STUB
  chmod +x "$bin/gh"
  PATH="${bin}:${PATH}"; export PATH
}

b64() { base64 -w 0 2>/dev/null || base64 -b 0; }

@test "dry-run plans a PR to INSERT the baseline into a repo missing .gitignore" {
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'DRY RUN'
  echo "$output" | grep -qi 'markets'
  echo "$output" | grep -q '.gitignore'
  echo "$output" | grep -qiE 'would open pr|insert'
  # no mutation
  ! grep -q 'git/refs --method POST' "$GH_CALLS"
  ! grep -q 'pr create' "$GH_CALLS"
}

@test "dry-run skips a repo whose .gitignore already carries the current baseline" {
  # "Current" = the raw canonical .gitignore. Per #817 the negation tail is now
  # conditional, so upsert(canonical) == canonical again (its L2 re-hides nothing
  # and its bare-# separator is preserved) — the raw canonical is the steady state.
  GH_CONTENT_B64="$(b64 < "$CANONICAL")"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'already carries the current baseline'
  echo "$output" | grep -viq 'would open pr'
}

@test "dry-run plans a PR for a marker-less .gitignore (INSERT, L2 preserved)" {
  printf 'node_modules/\ndist/\n' > "$TT_TMP/existing"
  GH_CONTENT_B64="$(b64 < "$TT_TMP/existing")"; export GH_CONTENT_B64
  install_gh_stub
  run env GH_TOKEN=x bash "$SCRIPT" --dry-run --repo markets
  [ "$status" -eq 0 ]
  echo "$output" | grep -qiE 'would open pr|insert'
}

@test "errors when the canonical baseline is unreadable" {
  install_gh_stub
  run env GH_TOKEN=x GITIGNORE_CANONICAL="$TT_TMP/nope" bash "$SCRIPT" --dry-run --repo markets
  [ "$status" -ne 0 ]
}
