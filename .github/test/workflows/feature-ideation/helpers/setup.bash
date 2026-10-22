#!/usr/bin/env bash
# Common test helpers for feature-ideation bats suites.

# Repo root, regardless of where bats is invoked from.
TT_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)"
export TT_REPO_ROOT

TT_SCRIPTS_DIR="${TT_REPO_ROOT}/.github/scripts/feature-ideation"
export TT_SCRIPTS_DIR

TT_FIXTURES_DIR="${TT_REPO_ROOT}/test/workflows/feature-ideation/fixtures"
export TT_FIXTURES_DIR

TT_STUBS_DIR="${TT_REPO_ROOT}/test/workflows/feature-ideation/stubs"
export TT_STUBS_DIR

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

# Install a fake `gh` binary on PATH for the duration of a test.
# Behavior is driven by env vars set per-test:
#   GH_STUB_STDOUT  — what the stub prints on stdout
#   GH_STUB_STDERR  — what the stub prints on stderr
#   GH_STUB_EXIT    — exit code (default 0)
#   GH_STUB_LOG     — file path to append the invocation argv to (optional)
tt_install_gh_stub() {
  local stub_dir="${TT_TMP}/bin"
  mkdir -p "$stub_dir"
  cp "${TT_STUBS_DIR}/gh" "$stub_dir/gh"
  chmod +x "$stub_dir/gh"
  PATH="${stub_dir}:${PATH}"
  export PATH
}

# Convenience: load a fixture file by relative path.
tt_fixture() {
  cat "${TT_FIXTURES_DIR}/$1"
}
