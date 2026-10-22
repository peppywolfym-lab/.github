#!/usr/bin/env bash
set -euo pipefail
# check-cron-timing.sh — fail if any workflow in .github/workflows/ schedules a
# cron on the top of the hour (minute field 0). Enforces the off-peak
# scheduled-workflow timing standard (standards/ci-standards.md → "Scheduled
# Workflow Timing"). Wired into ci.yml's Lint job and
# .dev-lead/scripts/dev-lead-lint.sh.
#
# Usage: check-cron-timing.sh [workflow-dir]
#   workflow-dir defaults to the repo's own .github/workflows/. The templates in
#   standards/workflows/ are deliberately out of scope — retiming them is
#   downstream fan-out (tracked in petry-projects/.github-private#726), not this
#   repo obeying the convention.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/cron-timing.sh
source "${SCRIPT_DIR}/lib/cron-timing.sh"

WORKFLOW_DIR="${1:-${SCRIPT_DIR}/../.github/workflows}"
STANDARD='standards/ci-standards.md → "Scheduled Workflow Timing"'

violations=0
shopt -s nullglob
for wf in "${WORKFLOW_DIR}"/*.yml "${WORKFLOW_DIR}"/*.yaml; do
  # Pull every quoted cron expression out of the file. A cron line looks like:
  #   - cron: '0 7 * * *'   # comment
  while IFS= read -r expr; do
    [ -n "$expr" ] || continue
    if cron_minute_is_zero "$expr"; then
      {
        printf 'FAIL: %s — cron "%s" fires at minute 0 (top of the hour).\n' \
          "$(basename "$wf")" "$expr"
        printf '      Offset the minute field off :00 per %s.\n' "$STANDARD"
        printf '      Suggested minute for this file: %s\n' "$(cron_offset_minute "$wf")"
      } >&2
      violations=$((violations + 1))
    fi
  done < <(grep -oE "cron:[[:space:]]*['\"][^'\"]+['\"]" "$wf" \
             | sed -E "s/cron:[[:space:]]*['\"]//; s/['\"]$//")
done

if [ "$violations" -gt 0 ]; then
  printf '\n%d scheduled workflow(s) fire on the top of the hour. See %s.\n' \
    "$violations" "$STANDARD" >&2
  exit 1
fi

echo "cron-timing: all scheduled workflows in ${WORKFLOW_DIR} are offset off the top of the hour"
