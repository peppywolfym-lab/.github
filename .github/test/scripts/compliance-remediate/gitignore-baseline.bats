#!/usr/bin/env bats
# Tests for the push-protection/gitignore_baseline remediation path in
# scripts/compliance-remediate.sh (STORY4 / #800).
#
# Before this change the finding was routed to `report_skip` — a human was told
# to copy the block by hand. It is now auto-remediated: the shared, idempotent
# upsert_gitignore_baseline() (scripts/lib/gitignore-baseline.sh) places or
# refreshes the marker-wrapped L1 block in the target repo's .gitignore and the
# change ships as a PR via sd_deploy_via_pr(), preserving the repo's L2 (every
# line below the END marker) verbatim.
#
# The gh stub scripts the full fetch → branch → PUT → PR flow, so tests assert
# both the remediation-report/skipped outcome and the concrete gh call sequence.

bats_require_minimum_version 1.5.0

load 'helpers/setup'

# ---------------------------------------------------------------------------
# Fake gh installed on PATH. Behaviour is env-driven:
#   GH_GITIGNORE_B64  — base64 of the target repo's current .gitignore. Unset →
#                       the contents fetch 404s (the repo has no .gitignore).
#   GH_FILE_SHA       — blob sha returned for the file on the sync branch.
#   GH_EXISTING_PR    — a pre-existing open PR number (idempotency).
#   GH_PR_CREATE_RC   — non-zero → `gh pr create` fails.
#   GH_PR_URL         — url printed by `gh pr create`.
# All invocations are appended to $GH_CALLS.
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
        printf '%s\n' "${GH_PR_URL:-https://github.com/petry-projects/markets/pull/7}" ;;
    esac
    ;;
  label) exit 0 ;;
  api)
    endpoint="${1:-}"
    case "$endpoint" in
      */git/refs)                    exit "${GH_REF_CREATE_RC:-0}" ;;
      */git/ref/heads/*)
        if printf '%s' "$args" | grep -q 'object.sha'; then
          printf '%s' "${GH_BASE_SHA-basesha111}"
        else
          exit "${GH_REF_EXISTS_RC:-0}"
        fi ;;
      *contents/.gitignore"?"ref=*)
        # Branch-sha lookup. A real 200 always carries a sha; an absent file is a
        # 404. The shared lib (#865) treats GET-success-with-blank-sha as a hard
        # error (sha-unresolved), so the absent case MUST 404 (→ create path),
        # not print empty and exit 0.
        if [ -n "${GH_FILE_SHA:-}" ]; then
          printf '%s' "$GH_FILE_SHA"
        else
          printf 'gh: Not Found (HTTP 404)\n' >&2; exit 1
        fi ;;
      *contents/.gitignore)
        # PUT of the upserted file onto the sync branch.
        if printf '%s' "$args" | grep -q -- '--method PUT'; then
          exit "${GH_PUT_RC:-0}"
        fi
        # Configurable non-404 API error (auth/rate-limit/server-error tests).
        if [ -n "${GH_GITIGNORE_API_RC:-}" ]; then
          printf 'gh: HTTP 429: API rate limit exceeded\n' >&2
          exit "${GH_GITIGNORE_API_RC}"
        fi
        # Plain GET of the target repo's current .gitignore.
        if [ -n "${GH_GITIGNORE_B64:-}" ]; then
          printf '{"sha":"existingsha","content":"%s"}' "$GH_GITIGNORE_B64"
        else
          printf 'gh: Not Found (HTTP 404)\n' >&2
          exit 1   # 404 — .gitignore absent
        fi ;;
      repos/*)
        # The repo endpoint serves BOTH the default-branch lookup and the
        # preflight write probe (--jq .permissions.push, added to the shared
        # sd_deploy_files_via_pr lib in #865). Differentiate on the jq arg so the
        # write probe returns a boolean, not the default-branch string, else the
        # preflight reads "main" != "true" and fails as no-write-access.
        if printf '%s' "$args" | grep -q 'permissions.push'; then
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

b64() { base64 -w 0 2>/dev/null || base64 -b 0; }

setup() {
  tt_make_tmpdir
  GH_CALLS="${TT_TMP}/gh-calls.log"; export GH_CALLS
  : > "$GH_CALLS"
  install_gh_stub
  CANONICAL="${TT_REPO_ROOT}/.gitignore"
}

teardown() {
  tt_cleanup_tmpdir
}

run_remediate() {
  GH_TOKEN=fake \
    FINDINGS_FILE="$1" \
    REPORT_DIR="${TT_TMP}/report" \
    DRY_RUN="${2:-false}" \
    run bash "$TT_SCRIPT"
}

# ---------------------------------------------------------------------------
# INSERT — the repo has no .gitignore at all → open a PR seeding the baseline.
# ---------------------------------------------------------------------------
@test "opens a PR to INSERT the baseline when the repo has no .gitignore" {
  findings="$(tt_write_finding "markets" "push-protection" "gitignore_baseline")"
  run_remediate "$findings"

  [ "$status" -eq 0 ]

  # Lands on the remediation (PR) table with the PR url, never in skipped.
  grep -q 'gitignore_baseline' "${TT_TMP}/report/remediation-report.md"
  grep -q 'pull/7' "${TT_TMP}/report/remediation-report.md"
  ! grep -q 'gitignore_baseline' "${TT_TMP}/report/skipped.md"

  # Full PR flow ran against the target repo.
  grep -q 'gh api repos/petry-projects/markets/contents/.gitignore --method PUT' "$GH_CALLS"
  grep -q 'gh pr create --repo petry-projects/markets' "$GH_CALLS"
}

# ---------------------------------------------------------------------------
# REFRESH — a drifted marker-wrapped block is replaced in place; the repo's L2
# (everything below END) is preserved verbatim in the PUT payload.
# ---------------------------------------------------------------------------
@test "opens a PR to REFRESH a drifted block and preserves L2 below END" {
  printf '%s\n' \
    '# >>> BEGIN petry-projects secrets baseline (managed by .github — do not edit) >>>' \
    '.env' \
    'STALE-DRIFTED-ENTRY' \
    '# <<< END petry-projects secrets baseline <<<' \
    'node_modules/' \
    'dist/' > "${TT_TMP}/existing"
  GH_GITIGNORE_B64="$(b64 < "${TT_TMP}/existing")"; export GH_GITIGNORE_B64

  findings="$(tt_write_finding "markets" "push-protection" "gitignore_baseline")"
  run_remediate "$findings"

  [ "$status" -eq 0 ]
  grep -q 'gitignore_baseline' "${TT_TMP}/report/remediation-report.md"
  ! grep -q 'gitignore_baseline' "${TT_TMP}/report/skipped.md"

  # Decode the content PUT to the branch and confirm the block was refreshed to
  # the canonical L1 while the repo's L2 survived and the drift is gone.
  put_b64="$(grep 'method PUT' "$GH_CALLS" | grep -oE 'content=[A-Za-z0-9+/=]+' | head -1 | cut -d= -f2-)"
  [ -n "$put_b64" ]
  decoded="$(printf '%s' "$put_b64" | base64 -d)"
  printf '%s\n' "$decoded" | grep -qxF 'node_modules/'
  printf '%s\n' "$decoded" | grep -qxF 'dist/'
  printf '%s\n' "$decoded" | grep -qxF '# <<< END petry-projects secrets baseline <<<'
  ! printf '%s\n' "$decoded" | grep -qxF 'STALE-DRIFTED-ENTRY'
}

# ---------------------------------------------------------------------------
# INSERT (marker-less) — a repo with a hand-rolled .gitignore keeps every line
# as L2 below the freshly-inserted block.
# ---------------------------------------------------------------------------
@test "marker-less .gitignore is preserved wholesale as L2 below the block" {
  printf '%s\n' 'node_modules/' '.DS_Store' > "${TT_TMP}/existing"
  GH_GITIGNORE_B64="$(b64 < "${TT_TMP}/existing")"; export GH_GITIGNORE_B64

  findings="$(tt_write_finding "broodly" "push-protection" "gitignore_baseline")"
  run_remediate "$findings"

  [ "$status" -eq 0 ]
  grep -q 'gitignore_baseline' "${TT_TMP}/report/remediation-report.md"

  put_b64="$(grep 'method PUT' "$GH_CALLS" | grep -oE 'content=[A-Za-z0-9+/=]+' | head -1 | cut -d= -f2-)"
  decoded="$(printf '%s' "$put_b64" | base64 -d)"
  printf '%s\n' "$decoded" | grep -qxF 'node_modules/'
  printf '%s\n' "$decoded" | grep -qxF '.DS_Store'
  printf '%s\n' "$decoded" | grep -qxF '# >>> BEGIN petry-projects secrets baseline (managed by .github — do not edit) >>>'
}

# ---------------------------------------------------------------------------
# Idempotency — a repo already carrying the current baseline is a no-op: no PR,
# no mutating call, and it is recorded as a skip (not a failure).
# ---------------------------------------------------------------------------
@test "already-current baseline is an idempotent no-op (no PR opened)" {
  # "Current" = the raw canonical .gitignore. Per #817 the negation tail is now
  # conditional, so upsert(canonical) == canonical again — the raw canonical is
  # the steady state and must be detected as an already-current no-op.
  GH_GITIGNORE_B64="$(b64 < "$CANONICAL")"; export GH_GITIGNORE_B64

  findings="$(tt_write_finding "markets" "push-protection" "gitignore_baseline")"
  run_remediate "$findings"

  [ "$status" -eq 0 ]
  grep -q 'gitignore_baseline' "${TT_TMP}/report/skipped.md"
  ! grep -q 'gitignore_baseline' "${TT_TMP}/report/remediation-report.md"

  ! grep -q 'git/refs --method POST' "$GH_CALLS"
  ! grep -q 'method PUT' "$GH_CALLS"
  ! grep -q 'gh pr create' "$GH_CALLS"
}

# ---------------------------------------------------------------------------
# Dry-run — plan the PR, record it on the remediation report, make no mutation.
# ---------------------------------------------------------------------------
@test "dry-run records a planned PR and issues no mutating gh calls" {
  findings="$(tt_write_finding "markets" "push-protection" "gitignore_baseline")"
  run_remediate "$findings" true

  [ "$status" -eq 0 ]
  grep -q 'gitignore_baseline' "${TT_TMP}/report/remediation-report.md"
  grep -qi 'DRY' "${TT_TMP}/report/remediation-report.md"

  ! grep -q 'git/refs --method POST' "$GH_CALLS"
  ! grep -q 'method PUT' "$GH_CALLS"
  ! grep -q 'gh pr create' "$GH_CALLS"
}

# ---------------------------------------------------------------------------
# Failure — a failed PR creation is reported as a failure (exit non-zero).
# ---------------------------------------------------------------------------
@test "failed PR creation is reported as a failure" {
  GH_PR_CREATE_RC=1; export GH_PR_CREATE_RC

  findings="$(tt_write_finding "markets" "push-protection" "gitignore_baseline")"
  run_remediate "$findings"

  [ "$status" -ne 0 ]
  grep -q 'FAILED' "${TT_TMP}/report/skipped.md"
  grep -q 'gitignore_baseline' "${TT_TMP}/report/skipped.md"
}

# ---------------------------------------------------------------------------
# Idempotency — an already-open baseline PR is reused, not duplicated.
# ---------------------------------------------------------------------------
@test "an already-open baseline PR is reused (skip), not duplicated" {
  GH_EXISTING_PR="99"; export GH_EXISTING_PR

  findings="$(tt_write_finding "markets" "push-protection" "gitignore_baseline")"
  run_remediate "$findings"

  [ "$status" -eq 0 ]
  grep -q 'gitignore_baseline' "${TT_TMP}/report/skipped.md"
  ! grep -q 'gh pr create' "$GH_CALLS"
}

# ---------------------------------------------------------------------------
# Failure — incomplete canonical block (missing END marker) is a hard error.
# ---------------------------------------------------------------------------
@test "incomplete canonical baseline block is reported as a failure" {
  GITIGNORE_CANONICAL="${TT_TMP}/broken-canonical"; export GITIGNORE_CANONICAL
  printf '%s\n' \
    '# >>> BEGIN petry-projects secrets baseline (managed by .github — do not edit) >>>' \
    '.env' > "$GITIGNORE_CANONICAL"  # missing END marker

  findings="$(tt_write_finding "markets" "push-protection" "gitignore_baseline")"
  run_remediate "$findings"

  grep -q 'FAILED' "${TT_TMP}/report/skipped.md"
  grep -q 'gitignore_baseline' "${TT_TMP}/report/skipped.md"
  ! grep -q 'gh pr create' "$GH_CALLS"
}

# ---------------------------------------------------------------------------
# Failure — half-open existing .gitignore (one marker) is refused by upsert.
# ---------------------------------------------------------------------------
@test "half-open existing .gitignore (one marker) is reported as a failure" {
  printf '%s\n' \
    '# >>> BEGIN petry-projects secrets baseline (managed by .github — do not edit) >>>' \
    '.env' \
    'node_modules/' > "${TT_TMP}/half-open"  # missing END marker
  GH_GITIGNORE_B64="$(b64 < "${TT_TMP}/half-open")"; export GH_GITIGNORE_B64

  findings="$(tt_write_finding "markets" "push-protection" "gitignore_baseline")"
  run_remediate "$findings"

  grep -q 'FAILED' "${TT_TMP}/report/skipped.md"
  grep -q 'gitignore_baseline' "${TT_TMP}/report/skipped.md"
  ! grep -q 'gh pr create' "$GH_CALLS"
}

# ---------------------------------------------------------------------------
# Failure — a non-404 gh api error (auth/rate-limit/5xx) fails fast.
# ---------------------------------------------------------------------------
@test "non-404 gh api error fetching .gitignore is reported as a failure" {
  GH_GITIGNORE_API_RC=1; export GH_GITIGNORE_API_RC

  findings="$(tt_write_finding "markets" "push-protection" "gitignore_baseline")"
  run_remediate "$findings"

  grep -q 'FAILED' "${TT_TMP}/report/skipped.md"
  grep -q 'gitignore_baseline' "${TT_TMP}/report/skipped.md"
  ! grep -q 'gh pr create' "$GH_CALLS"
}
