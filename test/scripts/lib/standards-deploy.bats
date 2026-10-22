#!/usr/bin/env bats
# Tests for scripts/lib/standards-deploy.sh — sd_deploy_via_pr()
#
# The function shells out to `gh` for every GitHub interaction, so each test
# installs a fake `gh` on PATH that logs its invocations to $GH_CALLS and whose
# behaviour is driven by GH_* env vars. Assertions check both the returned
# outcome token and the sequence of gh calls (e.g. that an idempotent skip makes
# no mutating calls, that a failed branch-create still falls back to reuse).

load 'helpers/setup'

# ---------------------------------------------------------------------------
# Fake gh installed on PATH
# ---------------------------------------------------------------------------
install_gh_stub() {
  local bin="${TT_TMP}/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
{ printf 'gh'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$GH_CALLS"
sub="${1:-}"; shift || true
args="$*"
case "$sub" in
  pr)
    case "${1:-}" in
      list)   printf '%s' "${GH_EXISTING_PR:-}" ;;
      create)
        [ "${GH_PR_CREATE_RC:-0}" -ne 0 ] && exit "${GH_PR_CREATE_RC}"
        printf '%s\n' "${GH_PR_URL:-https://github.com/o/r/pull/1}" ;;
    esac
    ;;
  api)
    endpoint="${1:-}"
    case "$endpoint" in
      */git/refs)          exit "${GH_REF_CREATE_RC:-0}" ;;
      */git/ref/heads/*)
        if printf '%s' "$args" | grep -q 'object.sha'; then
          printf '%s' "${GH_BASE_SHA-basesha111}"
        else
          exit "${GH_REF_EXISTS_RC:-0}"
        fi ;;
      *contents*"?"ref=*)
        # contents GET used to resolve a file's blob sha on the branch.
        #   GH_GET_RC!=0            -> the GET errors (prints GH_GET_ERR to stderr)
        #   GH_FILE_SHA unset       -> file absent on the branch (404 create path)
        #   GH_FILE_SHA set (maybe
        #     empty)                -> file present; echo the (maybe empty) sha
        if [ "${GH_GET_RC:-0}" -ne 0 ]; then
          printf '%s\n' "${GH_GET_ERR:-gh: Something went wrong (HTTP 500)}" >&2
          exit "${GH_GET_RC}"
        fi
        if [ -z "${GH_FILE_SHA+x}" ]; then
          printf '%s\n' 'gh: Not Found (HTTP 404)' >&2
          exit 1
        fi
        printf '%s' "${GH_FILE_SHA}" ;;
      *contents*)
        # contents PUT. On failure surface an HTTP-status-bearing stderr message.
        if [ "${GH_PUT_RC:-0}" -ne 0 ]; then
          printf '%s\n' "${GH_PUT_ERR:-gh: sha was not supplied (HTTP 422)}" >&2
          exit "${GH_PUT_RC}"
        fi
        exit 0 ;;
      repos/*)
        # repos/<repo>: the default-branch lookup AND the preflight write probe
        # (--jq .permissions.push) both land here — differentiate on the jq arg.
        if printf '%s' "$args" | grep -q 'permissions.push'; then
          if [ -n "${GH_PERM_RC:-}" ] && [ "${GH_PERM_RC}" != "0" ]; then
            printf '%s\n' "${GH_PERM_ERR:-gh: Not Found (HTTP 404)}" >&2
            exit "${GH_PERM_RC}"
          fi
          printf '%s' "${GH_CAN_PUSH:-true}"
        else
          printf '%s' "${GH_DEFAULT_BRANCH:-main}"
        fi ;;
    esac
    ;;
esac
exit 0
STUB
  chmod +x "$bin/gh"
  PATH="${bin}:${PATH}"
  export PATH
}

setup() {
  tt_make_tmpdir
  GH_CALLS="${TT_TMP}/gh-calls.log"; export GH_CALLS
  : > "$GH_CALLS"

  # A real local file to deploy.
  LOCAL_FILE="${TT_TMP}/add-to-project.yml"
  printf 'name: stub\non: [issues]\n' > "$LOCAL_FILE"

  install_gh_stub
  # shellcheck source=/dev/null
  source "${TT_SCRIPTS_LIB_DIR}/standards-deploy.sh"
}

teardown() { tt_cleanup_tmpdir; }

# Convenience wrapper with stable args.
deploy() {
  sd_deploy_via_pr "petry-projects/markets" ".github/workflows/add-to-project.yml" \
    "$LOCAL_FILE" "standards-sync/add-to-project" "standards-sync" \
    "chore: sync add-to-project.yml" "PR body here"
}

# ---------------------------------------------------------------------------
# Happy path: no existing PR, fresh file → branch, PUT, PR opened
# ---------------------------------------------------------------------------
@test "opens a PR and reports OPENED with the url" {
  run deploy
  [ "$status" -eq 0 ]
  [ "$output" = "OPENED https://github.com/o/r/pull/1" ]
}

@test "happy path makes the full create call sequence" {
  run deploy
  [ "$status" -eq 0 ]
  grep -q 'gh pr list --repo petry-projects/markets --label standards-sync' "$GH_CALLS"
  grep -q 'gh api repos/petry-projects/markets/git/refs --method POST' "$GH_CALLS"
  grep -q 'gh api repos/petry-projects/markets/contents/.github/workflows/add-to-project.yml --method PUT' "$GH_CALLS"
  grep -q 'gh pr create --repo petry-projects/markets --head standards-sync/add-to-project --base main' "$GH_CALLS"
  grep -q -- '--label standards-sync' "$GH_CALLS"
}

# The multi-file primitive: two stubs deploy as a single PR (two PUTs, one
# pr create) — the per-repo batching used by the fleet re-sync.
@test "deploys multiple files in a single PR" {
  local f2="${TT_TMP}/dependency-audit.yml"
  printf 'name: stub2\non: [push]\n' > "$f2"
  run sd_deploy_files_via_pr "petry-projects/markets" "standards-sync/workflows" \
    "standards-sync" "chore: sync 2 stubs" "body" \
    ".github/workflows/add-to-project.yml" "$LOCAL_FILE" \
    ".github/workflows/dependency-audit.yml" "$f2"
  [ "$status" -eq 0 ]
  [ "$output" = "OPENED https://github.com/o/r/pull/1" ]
  grep -q 'contents/.github/workflows/add-to-project.yml --method PUT' "$GH_CALLS"
  grep -q 'contents/.github/workflows/dependency-audit.yml --method PUT' "$GH_CALLS"
  # exactly one PR opened for the batch
  [ "$(grep -c 'gh pr create' "$GH_CALLS")" -eq 1 ]
}

@test "rejects an odd number of file arguments" {
  run sd_deploy_files_via_pr "petry-projects/markets" "b" "l" "t" "body" \
    ".github/workflows/only-a-path.yml"
  [ "$status" -ne 0 ]
  [ "$output" = "FAILED bad-file-args" ]
}

# Regression: consumer repos don't carry the standards-sync label, and
# `gh pr create --label` fails outright if it's absent — so the lib must ensure
# the label exists, before the PR is created. (petry-projects/.github#480.)
@test "ensures the label exists before opening the PR" {
  run deploy
  [ "$status" -eq 0 ]
  grep -q 'gh label create standards-sync --repo petry-projects/markets' "$GH_CALLS"
  local label_line prc_line
  label_line=$(grep -n 'gh label create' "$GH_CALLS" | head -1 | cut -d: -f1)
  prc_line=$(grep -n 'gh pr create' "$GH_CALLS" | head -1 | cut -d: -f1)
  [ "$label_line" -lt "$prc_line" ]
}

# ---------------------------------------------------------------------------
# Idempotency: an open PR already exists → skip, no mutations
# ---------------------------------------------------------------------------
@test "skips when an open PR already exists on the branch" {
  GH_EXISTING_PR="42"; export GH_EXISTING_PR
  run deploy
  [ "$status" -eq 0 ]
  [ "$output" = "SKIP_PR_OPEN 42" ]
}

@test "idempotent skip makes no branch/PUT/PR-create calls" {
  GH_EXISTING_PR="42"; export GH_EXISTING_PR
  run deploy
  [ "$status" -eq 0 ]
  ! grep -q 'git/refs --method POST' "$GH_CALLS"
  ! grep -q 'contents/.* --method PUT' "$GH_CALLS"
  ! grep -q 'gh pr create' "$GH_CALLS"
}

# ---------------------------------------------------------------------------
# Branch reuse: create returns non-zero but the ref already exists
# ---------------------------------------------------------------------------
@test "reuses an existing branch and still opens the PR" {
  GH_REF_CREATE_RC="1"; export GH_REF_CREATE_RC   # POST refs fails (already exists)
  GH_REF_EXISTS_RC="0"; export GH_REF_EXISTS_RC    # ref lookup succeeds
  run deploy
  [ "$status" -eq 0 ]
  [ "$output" = "OPENED https://github.com/o/r/pull/1" ]
  grep -q 'gh pr create' "$GH_CALLS"
}

# ---------------------------------------------------------------------------
# Update path: file already present on the branch → PUT carries its blob SHA
# ---------------------------------------------------------------------------
@test "passes the existing blob sha when updating a drifted stub" {
  GH_FILE_SHA="deadbeefsha"; export GH_FILE_SHA
  run deploy
  [ "$status" -eq 0 ]
  grep -q 'contents/.github/workflows/add-to-project.yml --method PUT.*--raw-field sha=deadbeefsha' "$GH_CALLS"
}

# ---------------------------------------------------------------------------
# Failure modes
# ---------------------------------------------------------------------------
@test "fails cleanly when the base sha cannot be resolved" {
  GH_BASE_SHA=""; export GH_BASE_SHA
  run deploy
  [ "$status" -ne 0 ]
  [ "$output" = "FAILED no-base-sha" ]
}

@test "fails when the branch can neither be created nor found" {
  GH_REF_CREATE_RC="1"; export GH_REF_CREATE_RC
  GH_REF_EXISTS_RC="1"; export GH_REF_EXISTS_RC
  run deploy
  [ "$status" -ne 0 ]
  [ "$output" = "FAILED no-branch" ]
}

@test "fails when the PUT is rejected and surfaces the real HTTP status" {
  GH_PUT_RC="1"; export GH_PUT_RC
  GH_PUT_ERR='gh: "sha" wasn'\''t supplied. (HTTP 422)'; export GH_PUT_ERR
  run deploy
  [ "$status" -ne 0 ]
  [[ "$output" == FAILED\ put-failed:* ]]
  [[ "$output" == *"HTTP 422"* ]]
}

@test "fails when the PR cannot be created" {
  GH_PR_CREATE_RC="1"; export GH_PR_CREATE_RC
  run deploy
  [ "$status" -ne 0 ]
  [ "$output" = "FAILED pr-create-failed" ]
}

@test "fails when the local file is missing" {
  run sd_deploy_via_pr "petry-projects/markets" ".github/workflows/x.yml" \
    "${TT_TMP}/does-not-exist.yml" "standards-sync/x" "standards-sync" "t" "b"
  [ "$status" -ne 0 ]
  [ "$output" = "FAILED missing-local-file" ]
}

# ---------------------------------------------------------------------------
# Fix 2 (petry-projects/.github#864): preflight write check + real error
# surfacing + never a sha-less PUT on an existing file.
# ---------------------------------------------------------------------------

# Preflight: a token without contents/PR write is reported as a clear finding,
# not an opaque per-file put-failed. No branch or PUT is attempted.
@test "fails loudly when the token lacks write access (preflight probe)" {
  GH_CAN_PUSH="false"; export GH_CAN_PUSH
  run deploy
  [ "$status" -ne 0 ]
  [ "$output" = "FAILED no-write-access" ]
  ! grep -q 'git/refs --method POST' "$GH_CALLS"
  ! grep -q 'contents/.* --method PUT' "$GH_CALLS"
}

# Preflight: an ERROR on the probe itself (transient / auth / 404) is surfaced
# distinctly with its HTTP status — NOT misreported as "no-write-access". No
# branch or PUT is attempted.
@test "preflight probe error is surfaced distinctly, not as no-write-access" {
  GH_PERM_RC="1"; export GH_PERM_RC
  GH_PERM_ERR='gh: Resource not accessible by integration (HTTP 403)'; export GH_PERM_ERR
  run deploy
  [ "$status" -ne 0 ]
  [[ "$output" == FAILED\ perm-probe-failed:* ]]
  [[ "$output" == *"HTTP 403"* ]]
  [[ "$output" != *"no-write-access"* ]]
  ! grep -q 'git/refs --method POST' "$GH_CALLS"
  ! grep -q 'contents/.* --method PUT' "$GH_CALLS"
}

# Regression guard for the reported bug: when the stub file already exists on the
# branch, the update PUT must ALWAYS carry its blob sha — a sha-less PUT against
# an existing file is a guaranteed 422.
@test "existing-file update always supplies a sha in the PUT" {
  GH_FILE_SHA="deadbeefsha"; export GH_FILE_SHA
  run deploy
  [ "$status" -eq 0 ]
  local put_lines
  put_lines=$(grep 'contents/.* --method PUT' "$GH_CALLS")
  [ -n "$put_lines" ]
  while IFS= read -r line; do
    printf '%s' "$line" | grep -q -- '--raw-field sha=deadbeefsha' \
      || { echo "PUT without sha: $line"; return 1; }
  done <<< "$put_lines"
}

# The contents GET must not swallow errors: a non-404 failure (e.g. a token-scope
# 403) is surfaced with its HTTP status, and no PUT is attempted.
@test "fails loudly when the contents GET errors with a non-404 status" {
  GH_GET_RC="1"; export GH_GET_RC
  GH_GET_ERR='gh: Resource not accessible by integration (HTTP 403)'; export GH_GET_ERR
  run deploy
  [ "$status" -ne 0 ]
  [[ "$output" == FAILED\ contents-get-failed:* ]]
  [[ "$output" == *"HTTP 403"* ]]
  ! grep -q 'contents/.* --method PUT' "$GH_CALLS"
}

# The file exists on the branch (GET 200) but its sha cannot be resolved: fail
# loudly rather than issue a sha-less PUT that is guaranteed to 422.
@test "fails loudly when an existing file's sha cannot be resolved" {
  GH_FILE_SHA=""; export GH_FILE_SHA   # present (GET 200) but empty sha
  run deploy
  [ "$status" -ne 0 ]
  [[ "$output" == FAILED\ sha-unresolved:* ]]
  ! grep -q 'contents/.* --method PUT' "$GH_CALLS"
}
