#!/usr/bin/env bash
# lint-caller.sh — guard feature-ideation caller stubs against the #571
# zero-job startup failure.
#
# Why this exists:
#   A reusable-workflow call graph (`jobs.<id>.uses` + its `with:`) is validated
#   at WORKFLOW SETUP — before, and regardless of, the calling job's `if:`. The
#   `inputs` context is only populated for `workflow_dispatch` / `workflow_call`
#   events, so a `with:` value that references `${{ inputs.* }}` fails the whole
#   run (zero jobs, "Invalid workflow file") when the workflow is also triggered
#   by an event that has no `inputs` — e.g. `discussion: created`. The job `if:`
#   does NOT save you. This is petry-projects/.github#571.
#
#   The fix is to resolve dispatch inputs in an ordinary `prep` job (whose step
#   expressions run at job time and are skipped on `discussion`) and pass them to
#   the reusable call via `needs.prep.outputs.*` — an always-valid context that
#   defers the `with:` evaluation to run time.
#
# This linter flags any job-level reusable `uses:` whose `with:` references the
# `inputs` context. `github.event.inputs.*` and step-level action `uses:` are
# intentionally NOT flagged.
#
# Usage:
#   lint-caller.sh [<workflow.yml> ...]
#   With no args, scans the two feature-ideation caller stubs.
#
# Exit codes:
#   0  no issues
#   1  one or more findings
#   2  bad usage / file or parse error

set -euo pipefail

scan_file() {
  local file="$1"

  python3 - "$file" <<'PY'
import re
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("[lint-caller] PyYAML is required (pip install pyyaml)\n")
    sys.exit(2)

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        doc = yaml.safe_load(f)
except (OSError, yaml.YAMLError) as exc:
    sys.stderr.write(f"[lint-caller] cannot parse {path}: {exc}\n")
    sys.exit(2)

if not isinstance(doc, dict):
    sys.exit(0)

jobs = doc.get("jobs")
if not isinstance(jobs, dict):
    sys.exit(0)

# `inputs` used as a context ROOT — i.e. `inputs.foo` or `inputs['foo']` — but
# NOT `github.event.inputs.foo` (where `inputs` is preceded by a `.`). The
# negative lookbehind excludes a leading `.` or word character.
inputs_ctx = re.compile(r"(?<![.\w])inputs\s*[.\[]")
# Non-greedy so adjacent ${{ }} expressions on one line are matched separately.
gh_expr = re.compile(r"\$\{\{(.*?)\}\}", re.DOTALL)


def flatten(value):
    """Yield every scalar string reachable from a `with:` value."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for v in value.values():
            yield from flatten(v)
    elif isinstance(value, list):
        for v in value:
            yield from flatten(v)


findings = []
for job_id, job in jobs.items():
    if not isinstance(job, dict):
        continue
    # Only reusable-workflow calls: a job with a top-level `uses:` key. Step-level
    # `uses:` lives under `steps:` and is never inspected here.
    if "uses" not in job:
        continue
    with_block = job.get("with")
    if not isinstance(with_block, dict):
        continue
    for key, value in with_block.items():
        flagged = False
        for scalar in flatten(value):
            for expr in gh_expr.findall(scalar):
                if inputs_ctx.search(expr):
                    findings.append((job_id, key, scalar.strip()))
                    flagged = True
                    break
            if flagged:
                break

if findings:
    sys.stderr.write(
        f"[lint-caller] {len(findings)} reusable `with:` value(s) in {path} "
        f"reference the `inputs` context.\n"
        f"  On a `discussion` (or other non-dispatch) trigger this fails at "
        f"workflow setup with zero jobs (#571), regardless of the job `if:`.\n"
        f"  Resolve inputs in a `prep` job and pass via `needs.prep.outputs.*`.\n"
    )
    for job_id, key, scalar in findings:
        sys.stderr.write(f"  job '{job_id}', with.{key}: {scalar}\n")
    sys.exit(1)
sys.exit(0)
PY
  return $?
}

main() {
  if [ "$#" -eq 0 ]; then
    # Default: the two feature-ideation caller stubs (template + this repo's own).
    local repo_root
    repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
    set -- \
      "${repo_root}/standards/workflows/feature-ideation.yml" \
      "${repo_root}/.github/workflows/feature-ideation.yml"
  fi

  local exit=0
  local file_rc=0
  for file in "$@"; do
    if [ ! -f "$file" ]; then
      printf '[lint-caller] not found: %s\n' "$file" >&2
      exit=2
      continue
    fi
    # Preserve exit-2 (file/parse error) over exit-1 (lint finding), matching
    # lint-prompt.sh's precedence.
    scan_file "$file" && file_rc=0 || file_rc=$?
    case "$file_rc" in
      0) ;;
      1) if [ "$exit" -eq 0 ]; then exit=1; fi ;;
      2) exit=2 ;;
      *) return "$file_rc" ;;
    esac
  done
  return "$exit"
}

main "$@"
