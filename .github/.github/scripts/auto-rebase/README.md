# auto-rebase scripts

Supporting logic for the org-level **auto-rebase** reusable workflow
(`.github/workflows/auto-rebase-reusable.yml`). All bash/jq decision logic
lives here so it can be unit-tested with bats
(`test/workflows/auto-rebase/`) instead of being trapped inline in YAML.

The reusable workflow checks this repo out at `inputs.tooling_ref` and sources
`lib/eligibility.sh` to decide which out-of-date PRs to update. `tooling_ref`
defaults to empty, which resolves to the reusable's own commit
(`github.job_workflow_sha`) so the predicate always matches the pinned
workflow version. Set `tooling_ref` only to test a branch end-to-end.

## `lib/eligibility.sh`

Pure, side-effect-free predicate. Source the file, then call:

| Function | Input | Returns |
|----------|-------|---------|
| `auto_rebase_pr_eligible MODE` | mode string | `0` eligible, `2` unknown mode |

### Eligibility modes (the tunable `eligibility` workflow input)

| Mode | Meaning |
|------|---------|
| `all` (default) | every behind PR, including drafts |

New modes (e.g. a future "front-of-queue N") can be added here and selected by
callers via the `eligibility` input with no change to the workflow file.

## `lib/comments.sh`

Thin best-effort I/O wrapper around `gh pr comment` (not a pure predicate).
Source the file, then call:

| Function | Input | Returns |
|----------|-------|---------|
| `auto_rebase_post_comment_best_effort PR_NUMBER REPO BODY` | PR number, `owner/repo`, comment body | always `0` — posts the comment; on failure logs a `::warning::` and swallows the error |

### Why best-effort (issue #594)

The reusable posts a conflict-resolution comment when a branch update hits a
merge conflict. That `gh pr comment` used to run unguarded under
`shell: bash -e`, so a single PR that had hit GitHub's **2500-comment cap**
(`Commenting is disabled on issues with more than 2500 comments`) failed the
whole step — starving every *other* open PR of its rebase in the same run. A
best-effort notification must never be fatal to the core function of rebasing
the other PRs, so this helper logs a warning and returns `0` on any
comment-side error (comment cap, secondary rate limit, transient 5xx).
