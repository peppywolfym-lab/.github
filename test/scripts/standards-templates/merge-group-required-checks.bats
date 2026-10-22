#!/usr/bin/env bats
# Template-guard for `merge_group` on the org-standard required-check caller-stub
# templates under standards/workflows/ (#1157).
#
# A GitHub merge queue only merges a PR once its required status checks report on
# the queue's temporary `gh-readonly-queue/*` ref, which means every workflow that
# provides a required check MUST trigger on the `merge_group` event. Two org
# required-check stubs are owned here as thin caller stubs:
#
#   - agent-shield.yml       → required check `agent-shield / AgentShield`
#   - dependency-audit.yml   → required check `dependency-audit / Detect ecosystems`
#
# Consumer repos may NOT add `merge_group` themselves (the stubs forbid editing
# trigger events), so the trigger belongs in the template. This guard fails in CI
# the moment either required-check stub loses its `merge_group` trigger or renames
# the job that provides the required-status-check context.

REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
WF_DIR="${REPO_ROOT}/standards/workflows"

# workflow-file : required-check job id (the job name is the required-status-check
# context and MUST NOT change — see each stub's header).
REQUIRED_CHECK_STUBS=(
  "agent-shield.yml:agent-shield"
  "dependency-audit.yml:dependency-audit"
)

# Print the top-level `merge_group` trigger key line ONLY when it is a direct
# child of the top-level `on:` block (at that block's own child indentation) —
# never a key nested under another trigger, a `#` comment, or a prose mention.
# A bare `grep` for `merge_group:` at any indentation/location would falsely
# pass on such a nested key even when `on:` lacks the event (#1157).
merge_group_lines() {
  awk '
    /^on:[[:space:]]*$/       { in_on = 1; child = 0; next }
    /^[^[:space:]#]/          { in_on = 0 }
    in_on && /^[[:space:]]*#/ { next }
    in_on && /^[ ]+[^[:space:]]/ {
      match($0, /^[ ]+/); ind = RLENGTH
      if (child == 0) child = ind
      if (ind == child && $0 ~ /^[ ]+merge_group:[[:space:]]*$/)
        print FNR ":" $0
    }
  ' "$1"
}

# Print `jobs.<id>:` header lines for the given job id at jobs-child indentation.
job_header_lines() {
  local file="$1" job="$2"
  grep -E "^[[:space:]]+${job}:[[:space:]]*$" "$file" || true
}

@test "every required-check stub template triggers on merge_group" {
  local violations=()
  local entry wf f
  for entry in "${REQUIRED_CHECK_STUBS[@]}"; do
    wf="${entry%%:*}"
    f="${WF_DIR}/${wf}"
    [ -f "$f" ] || { violations+=("${wf}: template missing"); continue; }
    if [ -z "$(merge_group_lines "$f")" ]; then
      violations+=("${wf}: no top-level 'merge_group:' trigger in on: block")
    fi
  done
  if [ "${#violations[@]}" -ne 0 ]; then
    printf 'missing merge_group trigger -> %s\n' "${violations[@]}"
    return 1
  fi
}

@test "required-check stub job names are unchanged (required-status-check contexts)" {
  # The job id is the left half of `<job-id> / <reusable-job-name>` in the
  # required-status-check context, so renaming it silently breaks branch
  # protection / the merge queue. Adding merge_group must not touch it.
  local violations=()
  local entry wf job f
  for entry in "${REQUIRED_CHECK_STUBS[@]}"; do
    wf="${entry%%:*}"
    job="${entry#*:}"
    f="${WF_DIR}/${wf}"
    [ -f "$f" ] || { violations+=("${wf}: template missing"); continue; }
    if [ -z "$(job_header_lines "$f" "$job")" ]; then
      violations+=("${wf}: required-check job '${job}:' not found")
    fi
  done
  if [ "${#violations[@]}" -ne 0 ]; then
    printf 'required-check job name drift -> %s\n' "${violations[@]}"
    return 1
  fi
}

@test "merge_group_lines ignores a nested merge_group and requires a real on: child" {
  # Negative control: a `merge_group:` nested under another trigger (not a direct
  # child of the top-level `on:` block) must NOT count as the required trigger.
  local nested pos
  nested="$(mktemp)"
  pos="$(mktemp)"
  printf 'on:\n  push:\n    branches: [main]\n    merge_group:\njobs:\n  x:\n    runs-on: ubuntu-latest\n' > "$nested"
  printf 'on:\n  push:\n    branches: [main]\n  merge_group:\njobs:\n  x:\n    runs-on: ubuntu-latest\n' > "$pos"
  [ -z "$(merge_group_lines "$nested")" ] || { echo "nested merge_group wrongly matched"; rm -f "$nested" "$pos"; return 1; }
  [ -n "$(merge_group_lines "$pos")" ]    || { echo "top-level merge_group not matched"; rm -f "$nested" "$pos"; return 1; }
  rm -f "$nested" "$pos"
}

@test "the guard actually inspects the required-check stub templates" {
  # Positive control: fail loudly if the stub list or the WF_DIR path is wrong,
  # so the checks above can never pass vacuously.
  [ "${#REQUIRED_CHECK_STUBS[@]}" -ge 2 ] || { echo "expected >=2 required-check stubs"; return 1; }
  local entry wf
  for entry in "${REQUIRED_CHECK_STUBS[@]}"; do
    wf="${entry%%:*}"
    [ -f "${WF_DIR}/${wf}" ] || { echo "required-check stub template not found: ${wf}"; return 1; }
  done
}
