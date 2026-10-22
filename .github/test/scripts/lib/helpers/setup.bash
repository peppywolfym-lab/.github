#!/usr/bin/env bash
# Common test helpers for scripts/lib bats suites.

TT_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)"
export TT_REPO_ROOT

TT_SCRIPTS_LIB_DIR="${TT_REPO_ROOT}/scripts/lib"
export TT_SCRIPTS_LIB_DIR

tt_make_tmpdir() {
  TT_TMP="$(mktemp -d)"
  export TT_TMP
}

tt_cleanup_tmpdir() {
  if [ -n "${TT_TMP:-}" ] && [ -d "${TT_TMP}" ]; then
    rm -rf "${TT_TMP}"
  fi
}
