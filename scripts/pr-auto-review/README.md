# pr-auto-review scripts

Supporting logic for the org-level **PR Auto-Review — Ready Check** reusable
workflow (`.github/workflows/pr-auto-review-reusable.yml`). All bash/jq decision
logic lives here so it can be unit-tested with bats
(`test/workflows/pr-auto-review/`) instead of being trapped inline in YAML.

The reusable workflow checks this repo out at `github.job_workflow_sha` (using
the `GH_PAT_WORKFLOWS` secret for authentication, so no extra caller permission
is required) and sources `lib/ready-check.sh` to decide whether a PR's CI checks
satisfy the passing-gate before the review agent is dispatched. Sourcing from the
reusable's own commit keeps the predicate matched to the pinned workflow version.

## `lib/ready-check.sh`

Pure, side-effect-free helpers. Source the file, then call:

| Function | Input | Returns |
|----------|-------|---------|
| `pr_auto_review_required_contexts` | branch-rules JSON on stdin (`GET /repos/{owner}/{repo}/rules/branches/{branch}`) | prints a compact JSON array of required status-check context names (`[]` if none / non-array) |
| `pr_auto_review_checks_ready REQUIRED_JSON SELF_NAME` | checks JSON on stdin (`gh pr checks --json bucket,name`) | prints a one-line reason; `0` ready, `1` not ready |
| `pr_auto_review_blocking_thread_count` | review-threads JSON on stdin (`reviewThreads(first:100){nodes{isResolved isOutdated comments(first:100){nodes{author{__typename}}}}}`) | prints the count of **blocking** threads — unresolved AND not outdated AND not posted exclusively by advisory bots |
| `pr_auto_review_ready STATE IS_DRAFT CHECKS_JSON REQUIRED_JSON SELF_NAME REVIEW_DECISION BLOCKING_THREAD_COUNT` | the PR facts the workflow gathers (all as arguments — no stdin) | prints the **decision class** on stdout; `0` ready, `1` not ready |

## `lib/sweep.sh`

Pure candidate-selection logic for the catch-up sweep (issue #868).

| Function | Input | Returns |
|----------|-------|---------|
| `pr_auto_review_sweep_candidates MAX` | PR-list JSON on stdin (`gh search prs --json url,isDraft`) | prints ≤`MAX` non-draft PR URLs, one per line, in input order |

## `sweep-dispatch.sh`

The catch-up sweep orchestrator (issue #868). See "The catch-up sweep" below.

### The unified decision core — `pr_auto_review_ready`

`pr_auto_review_ready` is the single pure core the reusable workflow calls. It
evaluates all four readiness criteria, in gate order, and **prints the decision
class** on stdout — one of the classes Layer 2 decision-telemetry (issue #668
increment 4) consumes:

| Class | Meaning | Criterion |
|-------|---------|-----------|
| `skip-draft` | PR is not `OPEN`, or is a draft | #1 |
| `skip-checks-pending` | a required check is missing / not yet passing, or no checks reported at all | #2 |
| `skip-changes-requested` | effective review decision is `CHANGES_REQUESTED` | #3 |
| `skip-unresolved-threads` | ≥1 unresolved review thread | #4 |
| `dispatched` | all criteria satisfied — dispatch the review agent | — |

Exit status is `0` iff the class is `dispatched`. Criteria are checked in order,
so an earlier skip wins (a draft PR that also has `CHANGES_REQUESTED` reports
`skip-draft`). The required-checks gate (#2) is delegated verbatim to
`pr_auto_review_checks_ready`, so the required-vs-non-required behaviour of
issue #680 is unchanged. The function makes **no** external calls — the workflow does
all the gh / GraphQL I/O and echoes the returned class to `$GITHUB_OUTPUT`.

### Passing-gate semantics (issue #680)

The old gate counted **every** check context, so a non-required or **cancelled**
advisory context (e.g. a superseded `dev-lead / ci-relay` run, cancelled by
per-PR concurrency) was scored as "not passing" and silently blocked
auto-dispatch on PRs that were actually mergeable.

`pr_auto_review_checks_ready` instead evaluates only the checks that actually
gate merge:

- **`REQUIRED_JSON` non-empty** — gate on the required contexts only. The PR is
  **not ready** if any required context has no matching check reported yet, or a
  matching check is not in the `pass`/`skipping` bucket (i.e. `fail`, `pending`
  or `cancel`). Every non-required context — including cancelled advisory
  runs — is ignored.
- **`REQUIRED_JSON` empty** — fallback (issue option **B**) for branches with no
  configured required status checks: block only when a non-self check is
  `fail` or `pending`; `cancel`, `skipping` and `pass` are non-blocking.

`SELF_NAME` is this workflow's own check-run name; it is excluded from the gate
so an in-progress run never blocks itself.

### Unresolved-thread semantics (issue #806)

Criterion #4 blocks dispatch on open review threads, but not all open threads
should block. dev-lead's fix-review cycle frequently **addresses an advisory
finding (Copilot / Gemini / CodeRabbit) in a follow-up commit but never marks
the thread resolved**. The code is fixed and CI is green, yet the PR sits
`REVIEW_REQUIRED` until a human resolves the thread by hand.

`pr_auto_review_blocking_thread_count` is the consumer-side, defense-in-depth
fix: it counts a thread as **blocking only when it is unresolved AND not
outdated**. GitHub sets `reviewThread.isOutdated == true` exactly when the diff
position the thread anchors to no longer exists at the current HEAD (the line
changed or the file moved) — a heuristic that the diff anchor shifted, not a
guarantee the concern was resolved. So an
unresolved-but-outdated thread — the signature of a fix that changed the flagged
line without resolving the thread — is treated as non-blocking, and the PR
converges without manual thread resolution.

Fail-safe: only an explicit `isOutdated == true` makes a thread non-blocking. A
`null` or absent `isOutdated` on an unresolved thread still blocks, so a thread
whose staleness cannot be confirmed is never silently dropped. This is
defense-in-depth: the producer side (dev-lead resolving the threads it fixes) is
still the preferred fix; this gate just stops forgotten resolutions from
stalling otherwise-mergeable PRs.

### Context name matching

Rulesets store the bare context (e.g. a job name `Lint`, or a third-party status
context `SonarCloud Code Analysis`), while `gh pr checks` renders Actions checks
as `"<workflow> / <job>"` (e.g. `CI / Lint`). A check matches a required context
when the names are equal, or when either ends with `" / <the other>"`, so both
forms resolve to the same required check.

## The catch-up sweep (issue #868)

The event-driven ready-check has **no catch-up**. Under a bulk `standards-sync`
convergence (Epic #850 / #857) it fires while CI is still mid-flight
(`"N of M checks not yet passing — skipping"`) and, once everything goes green,
**no further event re-evaluates it** — the PR strands `BLOCKED` with all required
checks green and no code-owner approval, indefinitely. Manually re-running the
ready-check often lands during transient CI re-runs and skips again, so a clean
"all-green + fresh event" window is unreliable while bots are active.

`sweep-dispatch.sh` is the missing catch-up, run by the
`PR Auto-Review — Catch-up Sweep` workflow on a schedule (every 15 min) and on
`workflow_dispatch`:

1. Enumerate the open, non-draft PRs carrying the sweep label
   (`standards-sync`) org-wide with a single `gh search prs`.
2. Select a **bounded** set via `pr_auto_review_sweep_candidates MAX_PER_RUN`
   (back-pressure — see below).
3. For each candidate, gather the same PR facts the event path gathers and
   delegate the decision to `pr_auto_review_ready`. Dispatch the review agent
   for the ones that come back `dispatched`.

Because the decision is delegated verbatim, the sweep inherits the #680
required-vs-non-required tolerance for free: a cancelled/superseded **non-required**
context (a `dev-lead / ci-relay` / `dev-lead / dispatch` run cancelled by per-PR
concurrency) never keeps a ready PR from dispatching. Periodic re-evaluation is
also the **debounce**: a PR skipped during a transient *required* re-run is
re-swept next cycle, so no exact settle window has to be caught.

### Back-pressure (donpetry-bot capacity)

donpetry-bot approvals drain at a limited rate (agent/token capacity), so a
10-PR burst that fires every dispatch at once just queues them all behind the
same cap. `MAX_PER_RUN` (default 8) bounds the dispatches per run so a burst
drains over a few cycles instead. `pr_auto_review_sweep_candidates` enforces the
bound and is fail-safe: a non-positive or non-numeric `MAX` selects **nothing**,
so a misconfigured cap can never turn into an unbounded dispatch burst.

Manual `workflow_dispatch` runs default to **dry-run** (log intended dispatches,
fire nothing); scheduled runs are live.

### Per-PR fault isolation (issue #947)

The sweep runs under `set -euo pipefail` on a 15-min schedule, so a single
transient GitHub API error must not abort the whole run. Two guards keep one
flaky PR from failing the scheduled workflow (and stranding the rest):

- **Fact-gathering** — if `gh pr view` or the review-threads GraphQL query fails
  (or returns empty) for a candidate, `evaluate_pr` emits the `skip-error` class
  and that PR is skipped this cycle instead of being dispatched on incomplete
  facts.
- **Dispatch** — the `repository_dispatch` POST is retried up to
  `DISPATCH_RETRIES` times (default 3, `DISPATCH_RETRY_SLEEP`s apart) on
  transient failure. If every attempt fails the PR is logged with a
  `::warning::` and the sweep continues; the run still exits `0`.

Both cases are safe because the sweep is idempotent and re-runs every cycle — a
PR skipped or un-dispatched this run is picked up next time, so a transient error
is a deferral, not a lost dispatch or a failed workflow.
