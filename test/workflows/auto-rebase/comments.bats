#!/usr/bin/env bats
# Tests for .github/scripts/auto-rebase/lib/comments.sh
#
# Pins issue #594: a failed conflict-resolution comment (e.g. GitHub's
# 2500-comment cap, a secondary rate limit, or a transient 5xx) must NOT abort
# the auto-rebase run. The best-effort post swallows the error, logs a warning,
# and returns success so the surrounding `bash -e` loop keeps rebasing the
# other PRs instead of dying on the first capped PR.

load 'helpers/setup'

setup() {
  tt_make_tmpdir
  # Stub `gh` on PATH so the helper never touches the network.
  TT_STUB_DIR="${TT_TMP}/bin"
  mkdir -p "$TT_STUB_DIR"
  PATH="${TT_STUB_DIR}:${PATH}"
  export PATH
  # shellcheck source=/dev/null
  . "${TT_SCRIPTS_DIR}/lib/comments.sh"
}

teardown() {
  tt_cleanup_tmpdir
}

# Install a `gh` stub that exits with the given code and records its args.
_stub_gh() {
  local exit_code="$1"
  cat > "${TT_STUB_DIR}/gh" <<EOF
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "${TT_TMP}/gh-calls.log"
exit ${exit_code}
EOF
  chmod +x "${TT_STUB_DIR}/gh"
}

@test "post_comment_best_effort: comment-cap failure is non-fatal (returns 0)" {
  _stub_gh 1
  run auto_rebase_post_comment_best_effort 205 owner/repo "conflict body"
  [ "$status" -eq 0 ]
}

@test "post_comment_best_effort: failure logs a continue warning naming the PR" {
  _stub_gh 1
  run auto_rebase_post_comment_best_effort 205 owner/repo "conflict body"
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"#205"* ]]
  [[ "$output" == *"continuing"* ]]
}

@test "post_comment_best_effort: success returns 0, posts the comment, no warning" {
  _stub_gh 0
  run auto_rebase_post_comment_best_effort 341 owner/repo "conflict body"
  [ "$status" -eq 0 ]
  [[ "$output" != *"::warning::"* ]]
  grep -qF "gh pr comment 341 --repo owner/repo --body conflict body" "${TT_TMP}/gh-calls.log"
}

@test "post_comment_best_effort: a capped PR does not abort a bash -e loop over multiple PRs" {
  # Fail for PR 205 (the capped PR), succeed for every other PR — the loop must
  # still reach and process PR 341 after 205's comment fails.
  cat > "${TT_STUB_DIR}/gh" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "205" ]; then exit 1; fi
done
exit 0
EOF
  chmod +x "${TT_STUB_DIR}/gh"

  run bash -e -c '
    # shellcheck source=/dev/null
    . "'"${TT_SCRIPTS_DIR}"'/lib/comments.sh"
    processed=""
    for pr in 205 341; do
      auto_rebase_post_comment_best_effort "$pr" owner/repo "body for $pr"
      processed="$processed $pr"
    done
    echo "PROCESSED:$processed"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROCESSED: 205 341"* ]]
}
