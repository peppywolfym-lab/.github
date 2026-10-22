#!/usr/bin/env bash
# Common test helpers for the pr-auto-review bats suite.

# Repo root, regardless of where bats is invoked from.
TT_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)"
export TT_REPO_ROOT

TT_SCRIPTS_DIR="${TT_REPO_ROOT}/.github/scripts/pr-auto-review"
export TT_SCRIPTS_DIR
