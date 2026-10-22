#!/usr/bin/env bash
# Common test helpers for the pr-review-mention bats suite.
# Mirrors the pattern in test/workflows/feature-ideation/helpers/setup.bash.

# Repo root, regardless of where bats is invoked from.
TT_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)"
export TT_REPO_ROOT

TT_WORKFLOW="${TT_REPO_ROOT}/.github/workflows/pr-review-mention-reusable.yml"
export TT_WORKFLOW

TT_STUBS_DIR="${TT_REPO_ROOT}/test/workflows/pr-review-mention/stubs"
export TT_STUBS_DIR

# Per-test scratch dir, auto-cleaned by tt_cleanup_tmpdir in teardown.
tt_make_tmpdir() {
  TT_TMP="$(mktemp -d)"
  export TT_TMP
}

tt_cleanup_tmpdir() {
  if [ -n "${TT_TMP:-}" ] && [ -d "${TT_TMP}" ]; then
    rm -rf "${TT_TMP}"
  fi
}

# Install the fake `gh` binary on PATH for the duration of a test.
# Behavior (body capture) is driven by GH_BODY_FILE — see stubs/gh.
tt_install_gh_stub() {
  local stub_dir="${TT_TMP}/bin"
  mkdir -p "$stub_dir"
  cp "${TT_STUBS_DIR}/gh" "$stub_dir/gh"
  chmod +x "$stub_dir/gh"
  PATH="${stub_dir}:${PATH}"
  export PATH
}

# Extract the job-level `if:` guard of the handle-mention job, with runs of
# whitespace collapsed to single spaces so structural assertions are immune to
# the guard's multi-line YAML formatting.
tt_job_if() {
  yq -r '.jobs.handle-mention.if' "$TT_WORKFLOW" | tr '\n' ' ' | tr -s ' '
}

# Extract the `run:` script of a named step in the handle-mention job.
tt_step_run() {
  local step_name="$1"
  yq -r ".jobs.handle-mention.steps[] | select(.name == \"${step_name}\") | .run" "$TT_WORKFLOW"
}
