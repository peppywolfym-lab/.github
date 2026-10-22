#!/usr/bin/env bats
# Tests for scripts/automerge-standards-sync.sh — the merge-side primitive that
# clears the pr-quality reviewer deadlock on `standards-sync` PRs by approving
# from a DISTINCT code-owner identity and enabling GitHub NATIVE auto-merge, so
# the PR merges on required-checks-green THROUGH branch protection (never
# `--admin`).
#
# A fake `gh` returns a single `pr view --json …` blob per PR (env
# GH_PR_VIEW_JSON) and logs every invocation to GH_CALLS so the assertions can
# prove exactly which mutating calls were (not) made — and that no call ever
# carries `--admin`.

setup() {
  TT_TMP="$(mktemp -d)"
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/automerge-standards-sync.sh"
  GH_CALLS="${TT_TMP}/gh-calls.log"; export GH_CALLS
  : > "$GH_CALLS"
  install_gh_stub
}

teardown() { rm -rf "$TT_TMP"; }

install_gh_stub() {
  local bin="${TT_TMP}/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
{ printf 'gh'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$GH_CALLS"
case "$1 ${2:-}" in
  "pr view")  printf '%s' "${GH_PR_VIEW_JSON:-null}" ; exit 0 ;;
  "pr list")  printf '%s' "${GH_PR_LIST_JSON:-[]}" ; exit 0 ;;
  "pr review") exit 0 ;;
  "pr merge")  exit 0 ;;
  "api user") printf '%s' "${GH_API_USER_LOGIN:-donpetry-bot}" ; exit 0 ;;
  "auth status") exit 0 ;;
esac
exit 0
STUB
  chmod +x "$bin/gh"
  PATH="${bin}:${PATH}"; export PATH
}

# Build a pr view JSON blob: $1 author, $2 headRefName, $3 last-commit author,
# $4 comma-separated label list.
pr_json() {
  local author="$1" head="$2" last="$3" labels="$4"
  local labels_json="[]"
  if [ -n "$labels" ]; then
    labels_json="$(printf '%s\n' "$labels" | tr ',' '\n' \
      | jq -R '{name: .}' | jq -sc '.')"
  fi
  jq -nc \
    --arg author "$author" --arg head "$head" --arg last "$last" \
    --argjson labels "$labels_json" '
    { number: 42,
      url: "https://github.com/petry-projects/acme/pull/42",
      author: {login: $author},
      headRefName: $head,
      labels: $labels,
      commits: [ {authors: [ {login: $last} ]} ] }'
}

run_single() {  # extra args passed through
  run env GH_TOKEN=x APPROVER_TOKEN=faketoken bash "$SCRIPT" \
    --repo petry-projects/acme --pr 42 "$@"
}

# ── Eligibility gating ────────────────────────────────────────────────────────

@test "skips a PR that is missing the standards-sync label" {
  GH_PR_VIEW_JSON="$(pr_json don-petry standards-sync/2026-07-21 don-petry "dependencies")"
  export GH_PR_VIEW_JSON
  run_single
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'skip'
  echo "$output" | grep -qi 'standards-sync'
  ! grep -q 'pr review' "$GH_CALLS"
  ! grep -q 'pr merge' "$GH_CALLS"
}

@test "skips a PR whose author is not trusted" {
  GH_PR_VIEW_JSON="$(pr_json mallory standards-sync/2026-07-21 don-petry "standards-sync")"
  export GH_PR_VIEW_JSON
  run_single
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'skip'
  ! grep -q 'pr review' "$GH_CALLS"
  ! grep -q 'pr merge' "$GH_CALLS"
}

@test "skips a PR whose head branch is not a standards-sync branch" {
  GH_PR_VIEW_JSON="$(pr_json don-petry feature/x don-petry "standards-sync")"
  export GH_PR_VIEW_JSON
  run_single
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'skip'
  ! grep -q 'pr review' "$GH_CALLS"
  ! grep -q 'pr merge' "$GH_CALLS"
}

# ── Happy path: distinct reviewer resolves the deadlock ───────────────────────

@test "approves as the distinct code-owner and enables native auto-merge" {
  # author==last-pusher==don-petry frees donpetry-bot as the distinct reviewer.
  GH_PR_VIEW_JSON="$(pr_json don-petry standards-sync/2026-07-21 don-petry "standards-sync")"
  export GH_PR_VIEW_JSON
  run_single
  [ "$status" -eq 0 ]
  # A real approval review was posted…
  grep -q 'pr review 42 --repo petry-projects/acme --approve' "$GH_CALLS"
  # …and native auto-merge (squash) was enabled — merge fires on green THROUGH protection.
  grep -qE 'pr merge 42 --repo petry-projects/acme .*--auto' "$GH_CALLS"
  grep -q -- '--squash' "$GH_CALLS"
  # The chosen approver is the code-owner that is neither author nor last-pusher.
  echo "$output" | grep -q 'donpetry-bot'
  # NEVER an admin bypass — anywhere.
  ! grep -q -- '--admin' "$GH_CALLS"
  echo "$output" | grep -q 'admin=none'
}

@test "never emits an --admin bypass on the happy path" {
  GH_PR_VIEW_JSON="$(pr_json donpetry-bot standards-sync/2026-07-21 donpetry-bot "standards-sync")"
  export GH_PR_VIEW_JSON
  # here don-petry is the free code-owner, so the approver token authenticates as don-petry
  GH_API_USER_LOGIN=don-petry; export GH_API_USER_LOGIN
  run_single
  [ "$status" -eq 0 ]
  ! grep -q -- '--admin' "$GH_CALLS"
  # here don-petry is the free code-owner
  echo "$output" | grep -q 'don-petry'
}

# ── Deadlock: author + last-pusher consume every code-owner ───────────────────

@test "reports the deadlock (no distinct owner) and never uses --admin" {
  GH_PR_VIEW_JSON="$(pr_json don-petry standards-sync/2026-07-21 donpetry-bot "standards-sync")"
  export GH_PR_VIEW_JSON
  run_single
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'deadlock'
  ! grep -q 'pr review' "$GH_CALLS"
  ! grep -q 'pr merge' "$GH_CALLS"
  ! grep -q -- '--admin' "$GH_CALLS"
}

# ── Approver-token identity is verified before any approval is posted ─────────

@test "refuses to approve when APPROVER_TOKEN authenticates as a different login" {
  # Resolved approver is donpetry-bot, but the token authenticates as someone else
  # (misconfiguration / rotation) → refuse rather than post a misattributed approval.
  GH_PR_VIEW_JSON="$(pr_json don-petry standards-sync/2026-07-21 don-petry "standards-sync")"
  export GH_PR_VIEW_JSON
  GH_API_USER_LOGIN=someone-else; export GH_API_USER_LOGIN
  run_single
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'misattributed'
  ! grep -q 'pr review' "$GH_CALLS"
  ! grep -q 'pr merge' "$GH_CALLS"
  ! grep -q -- '--admin' "$GH_CALLS"
}

# ── Dry-run mutates nothing ───────────────────────────────────────────────────

@test "dry-run posts no approval and enables no auto-merge" {
  GH_PR_VIEW_JSON="$(pr_json don-petry standards-sync/2026-07-21 don-petry "standards-sync")"
  export GH_PR_VIEW_JSON
  run_single --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'dry'
  ! grep -q 'pr review' "$GH_CALLS"
  ! grep -q 'pr merge' "$GH_CALLS"
}

# ── Meta-repo (.github-private / SKIP_REPOS) is handled the same way ───────────

@test "processes a .github-private meta-repo PR the same way" {
  GH_PR_VIEW_JSON="$(pr_json don-petry standards-sync/2026-07-21 don-petry "standards-sync")"
  export GH_PR_VIEW_JSON
  run env GH_TOKEN=x APPROVER_TOKEN=faketoken bash "$SCRIPT" \
    --repo petry-projects/.github-private --pr 42
  [ "$status" -eq 0 ]
  grep -q 'pr review 42 --repo petry-projects/.github-private --approve' "$GH_CALLS"
  grep -qE 'pr merge 42 --repo petry-projects/.github-private .*--auto' "$GH_CALLS"
  ! grep -q -- '--admin' "$GH_CALLS"
}
