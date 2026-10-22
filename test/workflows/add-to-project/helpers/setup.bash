#!/usr/bin/env bash
# Common test helpers for add-to-project bats suites.
# Mirrors the pattern in test/workflows/feature-ideation/helpers/setup.bash.

TT_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)"
export TT_REPO_ROOT

TT_SCRIPTS_DIR="${TT_REPO_ROOT}/.github/scripts/add-to-project"
export TT_SCRIPTS_DIR

TT_STUBS_DIR="${TT_REPO_ROOT}/test/workflows/add-to-project/stubs"
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
# Behavior driven by env vars (see stubs/gh for the full list).
tt_install_gh_stub() {
  local stub_dir="${TT_TMP}/bin"
  mkdir -p "$stub_dir"
  cp "${TT_STUBS_DIR}/gh" "$stub_dir/gh"
  chmod +x "$stub_dir/gh"
  PATH="${stub_dir}:${PATH}"
  export PATH
}
