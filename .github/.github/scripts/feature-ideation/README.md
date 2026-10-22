# Feature Ideation — Scripts & Test Strategy

This directory contains the bash + Python helpers that back
`.github/workflows/feature-ideation-reusable.yml`. Every line of logic that
used to live inside the workflow's heredoc has been extracted here so it can
be unit tested with bats. Downstream BMAD repos call the reusable workflow
via the standards stub at `standards/workflows/feature-ideation.yml`.

## Why this exists

The original workflow was a 500+ line YAML file with bash, jq, and GraphQL
queries inlined into a heredoc, plus a `direct_prompt:` block that asked
the BMAD Analyst (Mary) to call `gh api` and parse responses with no schema
or error handling. Every defect was discovered post-merge by reviewers.
The risks (R1–R11) are documented in the test architect's risk register —
search for "Murat" in the project history.

This refactor moves the parsing surface into testable units so failures are
caught **before UAT** instead of after.

## File map

| File | Purpose | Killed risk |
|------|---------|------------|
| `lib/gh-safe.sh` | Wraps every `gh` and `gh api graphql` call. Fails loud on auth, rate-limit, network, GraphQL errors envelope, or `data: null`. Replaces the original `2>/dev/null` + `echo '[]'` swallow pattern. | R1, R7, R8 |
| `lib/compose-signals.sh` | Validates JSON inputs before `jq --argjson` and assembles the canonical signals.json document. | R3, R4 |
| `lib/filter-bots.sh` | Configurable bot blocklist via `FEATURE_IDEATION_BOT_AUTHORS` (extends the default list of bot logins to remove from results). | R10 |
| `lib/date-utils.sh` | Cross-platform date arithmetic helpers. | R9 |
| `collect-signals.sh` | Orchestrator: drives all `gh` calls, composes signals.json, emits truncation warnings. | R1, R3, R4, R11 |
| `validate-signals.py` | JSON Schema 2020-12 validator for signals.json against `../schemas/signals.schema.json`. | R3 |
| `match-discussions.sh` | Deterministic Jaccard-similarity matcher between Mary's proposals and existing Ideas Discussions. Replaces the prose "use fuzzy matching" instruction. | R5, R6 |
| `discussion-mutations.sh` | `create_discussion`, `comment_on_discussion`, `add_label_to_discussion` wrappers with `DRY_RUN=1` audit-log mode. | Smoke testing |
| `lint-prompt.sh` | Scans every workflow file for unescaped `$()` / `${VAR}` inside `direct_prompt:` (v0) and `prompt:` (v1) blocks (which YAML and `claude-code-action` pass verbatim instead of expanding). | R2 |

## Running the tests

```bash
# Install once
brew install bats-core shellcheck jq        # macOS
sudo apt-get install bats shellcheck jq     # Ubuntu (CI)
pip install jsonschema                      # Python schema validator

# Run everything
bats test/workflows/feature-ideation/

# Run a single suite
bats test/workflows/feature-ideation/gh-safe.bats

# Lint shell scripts
(cd .github/scripts/feature-ideation && \
  shellcheck -x collect-signals.sh lint-prompt.sh match-discussions.sh \
                 discussion-mutations.sh lib/*.sh)

# Lint workflow prompt blocks (direct_prompt: and prompt:)
bash .github/scripts/feature-ideation/lint-prompt.sh
```

CI runs all of the above on every PR that touches this directory or the
workflow file. See `.github/workflows/feature-ideation-tests.yml`.

## DRY_RUN mode

To smoke-test the workflow on a fork without writing to GitHub Discussions:

1. Trigger via `workflow_dispatch` with `dry_run: true`.
2. The `analyze` job will source `discussion-mutations.sh` with `DRY_RUN=1`,
   so every `create_discussion` / `comment_on_discussion` / `add_label_to_discussion`
   call writes a JSONL entry to `$DRY_RUN_LOG` instead of executing.
3. The dry-run log is uploaded as the `dry-run-log` artifact for human review.

## Schema as contract

`/.github/schemas/signals.schema.json` is the **producer/consumer contract**
between `collect-signals.sh` and Mary's prompt. Any change to the shape of
signals.json is a breaking change and must:

1. Bump `SCHEMA_VERSION` in `collect-signals.sh`.
2. Update fixtures under `test/workflows/feature-ideation/fixtures/expected/`.
3. Update Mary's prompt in `.github/workflows/feature-ideation-reusable.yml` if any field references move.

CI validates every fixture against the schema, and the workflow validates
the runtime output before handing it to Mary.
