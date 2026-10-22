#!/usr/bin/env bats
# Tests for the "Post acknowledgement comment" step in
# .github/workflows/pr-review-mention-reusable.yml.
#
# Pins issue #538 acceptance: "The ack comment fires no mention webhook." A
# literal `@donpetry-bot` in the ack is itself an issue_comment event that the
# mention listener reads as a review request → self-loop. So when the actor
# being acknowledged IS the bot, the ack must address it by plain login (no
# leading `@`, which fires no mention webhook); a human requester still gets a
# real `@`-mention. The ack always carries the agent marker for defense in depth.
#
# The step's `run:` script is extracted from the workflow and executed for real
# against a fake `gh` that records the exact `--body`, so the assertions exercise
# the shipped logic — not a reimplementation.

load 'helpers/setup'

setup() {
  tt_make_tmpdir
  tt_install_gh_stub
  GH_BODY_FILE="${TT_TMP}/body.txt"
  export GH_BODY_FILE
  ACK_SCRIPT="${TT_TMP}/ack.sh"
  tt_step_run "Post acknowledgement comment" >"$ACK_SCRIPT"
}

teardown() {
  tt_cleanup_tmpdir
}

# Run the extracted ack step with the env a GitHub run: block would receive.
# Any env the caller pre-exports (EVENT_NAME, SENDER_LOGIN, COMMENT_USER) is
# honoured; the rest get harmless defaults.
run_ack() {
  GH_TOKEN="x" \
  PR_URL="https://github.com/petry-projects/.github/pull/1" \
  BOT_LOGIN="donpetry-bot" \
  EVENT_NAME="${EVENT_NAME:-issue_comment}" \
  SENDER_LOGIN="${SENDER_LOGIN:-someone}" \
  COMMENT_USER="${COMMENT_USER:-someone}" \
    bash "$ACK_SCRIPT"
}

body() { cat "$GH_BODY_FILE"; }

# ── human requester: real @-mention, marker present ──────────────────────────

@test "ack: a human commenter is @-mentioned in the acknowledgement" {
  EVENT_NAME="issue_comment" COMMENT_USER="alice" run_ack
  [ -f "$GH_BODY_FILE" ]
  [[ "$(body)" == *"@alice"* ]]
}

@test "ack: the acknowledgement always carries the pr-review-agent marker" {
  EVENT_NAME="issue_comment" COMMENT_USER="alice" run_ack
  [[ "$(body)" == *"<!-- pr-review-agent mention-ack -->"* ]]
}

# ── the #538 self-mention kill ───────────────────────────────────────────────

@test "ack: never emits a literal @donpetry-bot when the bot is the actor (comment path)" {
  EVENT_NAME="issue_comment" COMMENT_USER="donpetry-bot" run_ack
  [[ "$(body)" != *"@donpetry-bot"* ]]
  # still addresses the bot, just without the mention-firing '@'
  [[ "$(body)" == *"donpetry-bot"* ]]
}

@test "ack: never emits a literal @donpetry-bot when the bot self-assigns as reviewer (pull_request path)" {
  EVENT_NAME="pull_request" SENDER_LOGIN="donpetry-bot" run_ack
  [[ "$(body)" != *"@donpetry-bot"* ]]
}

@test "ack: a human reviewer-assigner is still @-mentioned (pull_request path)" {
  EVENT_NAME="pull_request" SENDER_LOGIN="bob" run_ack
  [[ "$(body)" == *"@bob"* ]]
}
