#!/usr/bin/env bats
# Tests for the copilot-setup-steps job-name detection in
# scripts/compliance-audit.sh (check_copilot_setup_steps).
#
# GitHub only picks up .github/workflows/copilot-setup-steps.yml when it
# contains a job named exactly `copilot-setup-steps`. The audit decodes the
# file and runs a small indentation-aware parser (not a loose grep) so that a
# comment or a similarly named key elsewhere cannot falsely satisfy the check.
# These tests pin that parser: a correctly named job is recognised, and every
# near-miss (misnamed job, name only in a comment, name at the wrong indent)
# still raises the `copilot-setup-steps-invalid-job-name` finding.

bats_require_minimum_version 1.5.0

# Mirrors the parser embedded in check_copilot_setup_steps
# (scripts/compliance-audit.sh). Reads a workflow on stdin; exits 0 when a
# direct `jobs.copilot-setup-steps` key is present, 1 otherwise.
_has_job() {
  python3 -c '
import re
import sys

lines = sys.stdin.read().splitlines()
jobs_indent = None
child_indent = None
in_jobs = False
found = False

for raw in lines:
    # Skip empty lines and comments
    if re.match(r"^[ \t]*(#.*)?$", raw):
        continue

    indent = len(raw) - len(raw.lstrip(" \t"))
    line = raw.strip()

    if not in_jobs:
        if re.match(r"^jobs:[ \t]*(#.*)?$", line):
            in_jobs = True
            jobs_indent = indent
        continue

    # Left jobs section
    if indent <= jobs_indent:
        break

    # Determine direct-child indentation under jobs (first mapping key)
    if child_indent is None and re.match(r"^[^:#][^:]*:[ \t]*(#.*)?$", line):
        child_indent = indent

    # Match the exact required direct child key (quoted or unquoted YAML key)
    if child_indent is not None and indent == child_indent and re.match(r"^[\"\x27]?copilot-setup-steps[\"\x27]?:[ ]*(#.*)?$", line):
        found = True
        break

sys.exit(0 if found else 1)
'
}

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

# ---------------------------------------------------------------------------
# Compliant workflows are recognised
# ---------------------------------------------------------------------------

@test "this repo's copilot-setup-steps.yml is recognised as compliant" {
  if [ ! -f "$REPO_ROOT/.github/workflows/copilot-setup-steps.yml" ]; then
    skip "copilot-setup-steps.yml not present"
  fi
  run _has_job < "$REPO_ROOT/.github/workflows/copilot-setup-steps.yml"
  [ "$status" -eq 0 ]
}

@test "minimal workflow with the job is recognised" {
  run _has_job <<'YAML'
name: Copilot Setup Steps
on:
  workflow_dispatch:
jobs:
  copilot-setup-steps:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
YAML
  [ "$status" -eq 0 ]
}

@test "quoted job key is recognised" {
  run _has_job <<'YAML'
jobs:
  "copilot-setup-steps":
    runs-on: ubuntu-latest
YAML
  [ "$status" -eq 0 ]
}

@test "single-quoted job key is recognised" {
  run _has_job <<'YAML'
jobs:
  'copilot-setup-steps':
    runs-on: ubuntu-latest
YAML
  [ "$status" -eq 0 ]
}

@test "job is recognised even when it is not the first job" {
  run _has_job <<'YAML'
jobs:
  lint:
    runs-on: ubuntu-latest
  copilot-setup-steps:
    runs-on: ubuntu-latest
YAML
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Near-misses still trigger the finding (status 1)
# ---------------------------------------------------------------------------

@test "a differently named job is flagged" {
  run _has_job <<'YAML'
jobs:
  setup:
    runs-on: ubuntu-latest
YAML
  [ "$status" -eq 1 ]
}

@test "name present only in a comment is flagged" {
  run _has_job <<'YAML'
jobs:
  # copilot-setup-steps: this is just a comment, not a real job
  setup:
    runs-on: ubuntu-latest
YAML
  [ "$status" -eq 1 ]
}

@test "name at the wrong indent (a step, not a job) is flagged" {
  run _has_job <<'YAML'
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: copilot-setup-steps
        run: echo not-a-job
YAML
  [ "$status" -eq 1 ]
}

@test "workflow with no jobs section is flagged" {
  run _has_job <<'YAML'
name: Copilot Setup Steps
on:
  workflow_dispatch:
YAML
  [ "$status" -eq 1 ]
}
