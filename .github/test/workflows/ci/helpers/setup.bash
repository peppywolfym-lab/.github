#!/usr/bin/env bash
# Common test helpers for the ci.yml bats suite.
# Mirrors the pattern in test/workflows/pr-review-mention/helpers/setup.bash.

# Repo root, regardless of where bats is invoked from.
TT_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)"
export TT_REPO_ROOT

TT_WORKFLOW="${TT_REPO_ROOT}/.github/workflows/ci.yml"
export TT_WORKFLOW
