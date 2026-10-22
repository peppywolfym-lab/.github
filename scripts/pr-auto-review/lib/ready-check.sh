#!/usr/bin/env bash
# Ready-check decision logic for the pr-auto-review reusable workflow.
#
# These are pure, side-effect-free functions so they can be unit-tested with
# bats (see test/workflows/pr-auto-review/ready-check.bats). The reusable
# workflow sources this file and uses the predicate to decide whether a PR's
# CI checks satisfy the passing-gate before dispatching the review agent.
#
# Contract: see .github/scripts/pr-auto-review/README.md
# Pins issue #680.

# pr_auto_review_required_contexts
#   Reads a branch-rules JSON array on stdin (the response of
#   `GET /repos/{owner}/{repo}/rules/branches/{branch}`) and emits a compact
#   JSON array of the required status-check context names. Emits `[]` when
#   there is no required_status_checks rule or the input is not an array
#   (e.g. a `{"message": "Not Found"}` error body).
pr_auto_review_required_contexts() {
  jq -c '
    if type == "array" then
      [ .[]
        | select(.type == "required_status_checks")
        | .parameters?.required_status_checks?[]?
        | .context
        | select(type == "string")
      ]
    else
      []
    end
  '
}

# pr_auto_review_checks_ready REQUIRED_JSON SELF_NAME
#   Reads a checks JSON array on stdin (the response of
#   `gh pr checks --json bucket,name`; each element has .name and .bucket) and
#   decides whether the passing-gate is satisfied. Prints a one-line reason to
#   stdout. Returns 0 (ready) or 1 (not ready).
#
#   REQUIRED_JSON  JSON array of required status-check context names (may be []).
#   SELF_NAME      name of this workflow's own check run, excluded from the gate
#                  so an in-progress run does not block itself (may be "").
#
#   A check "matches" a required context when their names are equal, or when the
#   check name ends with " / <context>" (GitHub renders Actions checks as
#   "<workflow> / <job>" while rulesets store the bare job name), or the reverse.
#
#   Decision:
#     * REQUIRED_JSON non-empty → gate on the required contexts only. Not ready
#       if any required context has no matching check reported yet, or a matching
#       check is not in the "pass"/"skipping" bucket. Non-required contexts
#       (including cancelled advisory runs) are ignored entirely — issue #680.
#     * REQUIRED_JSON empty → fallback (option B): ignore the required set and
#       block only when a non-self check is failing or pending; "cancel",
#       "skipping" and "pass" are treated as non-blocking.
pr_auto_review_checks_ready() {
  local required_json="${1:-[]}" self_name="$2" decision reason
  local result
  result=$(jq -r \
    --argjson required "$required_json" \
    --arg self "$self_name" '
      def matches($ctx):
        .name as $n
        | ($n | type == "string") and (
            ($n == $ctx)
            or ($n | endswith(" / " + $ctx))
            or ($ctx | endswith(" / " + $n))
          );

      (map(select(.name != $self))) as $checks
      | if ($required | length) == 0 then
          ([ $checks[] | select(.bucket == "fail" or .bucket == "pending") ]) as $blocking
          | if ($blocking | length) > 0 then
              "not-ready\t\($blocking | length) non-passing check(s) and no required set — skipping"
            else
              "ready\tno required set; no failing or pending checks"
            end
        else
          ([ $required[] as $ctx
             | { ctx: $ctx, runs: [ $checks[] | select(matches($ctx)) ] } ]) as $req
          | ([ $req[] | select(.runs | length == 0) | .ctx ]) as $missing
          | ([ $req[] | .runs[] | select(.bucket != "pass" and .bucket != "skipping") ]) as $notpassing
          | if ($missing | length) > 0 then
              "not-ready\trequired check(s) not reported yet: \($missing | join(", "))"
            elif ($notpassing | length) > 0 then
              "not-ready\t\($notpassing | length) required check(s) not yet passing — skipping"
            else
              "ready\tall \($req | length) required check(s) passing"
            end
        end
    ')
  decision="${result%%$'\t'*}"
  reason="${result#*$'\t'}"
  echo "$reason"
  [[ "$decision" == "ready" ]]
}

# pr_auto_review_blocking_thread_count
#   Reads a review-threads GraphQL response on stdin — the payload of
#   `reviewThreads(first:100){nodes{isResolved isOutdated comments(first:100){nodes{author{__typename}}}}}` under
#   .data.repository.pullRequest — and prints the count of threads that should
#   BLOCK auto-dispatch: those that are unresolved AND not outdated AND not
#   posted exclusively by advisory bots.
#
#   Why isOutdated (issue #806): dev-lead's fix-review cycle often addresses an
#   advisory finding in a follow-up commit but never marks the thread resolved,
#   so the unresolved-threads gate stalls the PR even though the code is fixed.
#   GitHub sets reviewThread.isOutdated == true exactly when the diff position
#   the thread anchors to no longer exists at HEAD (the line changed / file
#   moved) — a heuristic that the diff anchor shifted, not a guarantee the
#   underlying concern was resolved. Treating an
#   unresolved-but-outdated thread as non-blocking clears the stall without the
#   producer having to resolve the thread first.
#
#   Why advisory-bot exclusion (issue #892): threads whose comments are all
#   from advisory bots (author.__typename == "Bot") represent automated
#   nitpick feedback, not human review requests. When CI is green and the only
#   unresolved threads are advisory-bot posts, the PR should still be eligible
#   for dispatch — otherwise the gate stalls on a human to resolve bot threads
#   that dev-lead's fix-review correctly returns no-changes for (empty machine
#   findings). A thread is advisory-bot-only when comments.nodes is non-empty
#   and every author in that set has __typename == "Bot".
#
#   Fail-safe: only an explicit isOutdated == true makes a thread non-blocking;
#   a null / absent isOutdated on an unresolved thread still blocks, so a thread
#   whose staleness we cannot confirm is never silently dropped. Similarly, a
#   thread with absent or empty comments (cannot confirm all-bot) still blocks.
#   A GraphQL error body (no data / null nodes) yields 0.
pr_auto_review_blocking_thread_count() {
  jq -r '
    def is_advisory_bot_thread:
      (.comments?.nodes? // []) as $c
      | ($c | length) > 0 and ([$c[] | .author?.__typename? == "Bot"] | all);

    [
      (.data.repository.pullRequest.reviewThreads.nodes[]? |
      select((.isResolved == false) and (.isOutdated != true) and (is_advisory_bot_thread | not)))?
    ] | length
  '
}

# pr_auto_review_ready STATE IS_DRAFT CHECKS_JSON REQUIRED_JSON SELF_NAME \
#                      REVIEW_DECISION BLOCKING_THREAD_COUNT
#   Unified, pure readiness core for the pr-auto-review reusable workflow. Given
#   the PR facts gathered by the workflow's I/O glue, it evaluates all four
#   readiness criteria in gate order and PRINTS the decision class on stdout —
#   one of the classes Layer 2 decision-telemetry consumes:
#     skip-draft, skip-checks-pending, skip-changes-requested,
#     skip-unresolved-threads, dispatched
#   Returns 0 iff the PR is ready to dispatch (class == dispatched), else 1.
#
#   The workflow does the I/O (gh / GraphQL) and echoes the returned class to
#   `$GITHUB_OUTPUT`; this function makes no external calls.
#
#   STATE             PR state, e.g. OPEN / CLOSED / MERGED (gh: .state).
#   IS_DRAFT          "true" when the PR is a draft (gh: .isDraft).
#   CHECKS_JSON       `gh pr checks --json bucket,name` payload (may be "" / []).
#   REQUIRED_JSON     required status-check contexts (from
#                     pr_auto_review_required_contexts; may be []).
#   SELF_NAME         this workflow's own check-run name, excluded from the gate.
#   REVIEW_DECISION   effective review decision (gh: .reviewDecision; may be "").
#   BLOCKING_THREAD_COUNT  count of blocking threads — unresolved AND not outdated (may be "" → 0).
#
#   Criteria are evaluated in order, so an earlier skip wins over a later one
#   (e.g. a draft PR that also has CHANGES_REQUESTED reports skip-draft). The
#   required-checks gate (#2) is delegated verbatim to pr_auto_review_checks_ready
#   so the required-vs-non-required behaviour (issue #680) is unchanged.
pr_auto_review_ready() {
  local state="$1" is_draft="$2" checks_json="${3:-[]}" required_json="${4:-[]}" \
        self_name="$5" review_decision="$6" blocking_thread_count="${7:-0}"

  # 1. PR must be open and not a draft.
  if [ "$state" != "OPEN" ] || [ "$is_draft" = "true" ]; then
    echo "skip-draft"
    return 1
  fi

  # 2. All REQUIRED CI checks must be completed and passing. No checks reported
  #    at all is treated as still-pending. The required-vs-non-required gate is
  #    delegated to pr_auto_review_checks_ready (issue #680, unchanged).
  local total
  total=$(printf '%s' "$checks_json" | jq 'if type == "array" then length else 0 end' 2>/dev/null)
  if [ -z "$total" ] || [ "$total" -eq 0 ] \
     || ! printf '%s' "$checks_json" \
          | pr_auto_review_checks_ready "$required_json" "$self_name" >/dev/null; then
    echo "skip-checks-pending"
    return 1
  fi

  # 3. Effective review decision must not be CHANGES_REQUESTED.
  if [ "$review_decision" = "CHANGES_REQUESTED" ]; then
    echo "skip-changes-requested"
    return 1
  fi

  # 4. No blocking review threads (unresolved AND not outdated).
  if [ "$blocking_thread_count" -gt 0 ]; then
    echo "skip-unresolved-threads"
    return 1
  fi

  echo "dispatched"
  return 0
}
