#!/usr/bin/env bats
# Tests for the handle-mention job-level `if:` guard in
# .github/workflows/pr-review-mention-reusable.yml.
#
# Pins issue #538: the mention listener must never re-trigger itself. The
# acknowledgement comment the cascade posts @-mentions donpetry-bot and carries
# an `<!-- pr-review-agent … -->` marker; without an exclusion that ack is an
# `issue_comment: created` event the guard reads as a fresh review request, so
# the cascade self-loops (.github-private#860: 1,481 identical acks over ~4.5h).
#
# The guard MUST stay a job-level `if:` (not a runtime step): it gates whether
# the job — and its secrets — start at all, so a bot/agent comment must be
# rejected before the job spins up. These tests therefore assert on the guard
# expression itself rather than a shell reimplementation.

load 'helpers/setup'

# ── recursion kill: bot-authored + agent-marker comments must be excluded ─────

@test "guard: excludes comments authored by donpetry-bot itself" {
  guard="$(tt_job_if)"
  [[ "$guard" == *"github.event.comment.user.login != 'donpetry-bot'"* ]]
}

@test "guard: excludes any comment carrying an <!-- pr-review-agent marker" {
  # Broadened from the exact 'pr-review-agent mention-ack' string so EVERY agent
  # marker (review results, mention-ack, future markers) is caught, not just one.
  guard="$(tt_job_if)"
  [[ "$guard" == *"!contains(github.event.comment.body, '<!-- pr-review-agent')"* ]]
}

@test "guard: no longer keys the exclusion on the narrow mention-ack string alone" {
  # The pre-#538 guard only skipped 'pr-review-agent mention-ack'; any other
  # agent-marked comment slipped through. Assert the narrow-only form is gone.
  guard="$(tt_job_if)"
  [[ "$guard" != *"'pr-review-agent mention-ack'"* ]]
}

# ── the human trigger path must still work ───────────────────────────────────

@test "guard: still fires on an @donpetry-bot mention" {
  guard="$(tt_job_if)"
  [[ "$guard" == *"contains(github.event.comment.body, '@donpetry-bot')"* ]]
}

@test "guard: still gates comment events on trusted author_association" {
  guard="$(tt_job_if)"
  [[ "$guard" == *'OWNER'* ]]
  [[ "$guard" == *'MEMBER'* ]]
  [[ "$guard" == *'COLLABORATOR'* ]]
  [[ "$guard" == *'github.event.comment.author_association'* ]]
}

@test "guard: still fires when donpetry-bot is assigned as reviewer" {
  guard="$(tt_job_if)"
  [[ "$guard" == *"github.event.requested_reviewer.login == 'donpetry-bot'"* ]]
}
