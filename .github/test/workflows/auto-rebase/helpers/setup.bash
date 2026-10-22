#!/usr/bin/env bash
# Common test helpers for the auto-rebase bats suite.

# Repo root, regardless of where bats is invoked from.
TT_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)"
export TT_REPO_ROOT

TT_SCRIPTS_DIR="${TT_REPO_ROOT}/.github/scripts/auto-rebase"
export TT_SCRIPTS_DIR

# Per-test scratch dir, auto-cleaned by bats.
tt_make_tmpdir() {
  TT_TMP="$(mktemp -d)"
  export TT_TMP
}

tt_cleanup_tmpdir() {
  if [ -n "${TT_TMP:-}" ] && [ -d "${TT_TMP}" ]; then
    rm -rf "${TT_TMP}"
  fi
}
