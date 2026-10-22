#!/usr/bin/env bash
# add-issue-or-pr.sh — reconcile a single issue or PR with the org
# Initiatives project. An item belongs on the board iff it passes the
# noise gate:
#   - carries the required label (REQUIRED_LABEL) — but an EMPTY
#     REQUIRED_LABEL means "no required label", which is how issues are
#     un-gated (every issue tracked) while PRs keep the `dev-lead` gate;
#   - carries NONE of the excluded labels (EXCLUDED_LABELS, default
#     compliance-audit,health-check,fleet-tracker,daily-report) — the noise
#     filter that keeps automation-generated churn off the board.
#
# Reconcile, not just add (petry-projects/.github#415 §2): if an item that
# was on the board stops qualifying — required label removed, or an excluded
# label added — its project item is removed, built on the shared
# find_project_item / delete_project_item helpers in lib.sh.
#
# Required env:
#   PROJECT_ID            ProjectV2 node ID of the Initiatives project
#   GH_TOKEN              Token with org Projects: Read+write
#
# Optional env:
#   PROJECT_URL           Logged in human-readable messages only
#   REQUIRED_LABEL        Gate's required label (default dev-lead)
#   EXCLUDED_LABELS       Comma-separated excluded labels (default
#                         compliance-audit,health-check,fleet-tracker,daily-report)
#   PAGE_SIZE             Items fetched per GraphQL page (default 100)
#
# Functions (sourceable):
#   evaluate_noise_gate <labels_json>
#       Returns 0 if the labels qualify, 1 if they don't (a clean skip).
#       Returns 64 on bad arg-count and 65 on bad jq input shape — those
#       are programmer/payload bugs and the caller must NOT treat them as a
#       clean skip. Echoes a short reason on stderr when not qualifying.
#   find_content_item_id <content_node_id>
#   reconcile_content_with_project <content_node_id> <content_url> <labels_json>

set -euo pipefail

_atp_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "${_atp_lib_dir}/lib.sh"

evaluate_noise_gate() {
  if [ "$#" -ne 1 ]; then
    printf '[evaluate_noise_gate] expected 1 arg (labels_json), got %d\n' "$#" >&2
    return 64
  fi
  local labels_json="$1"

  # Defensive: GitHub event payloads can deliver labels=null in some
  # delivery variants. Treat any non-array as the empty-labels case rather
  # than letting jq abort the script under set -e.
  if ! printf '%s' "${labels_json}" | jq -e 'type == "array"' >/dev/null 2>&1; then
    labels_json='[]'
  fi

  # ${VAR-default} (no colon): an unset REQUIRED_LABEL falls back to dev-lead,
  # but an explicitly EMPTY value means "no required label" — every item
  # qualifies (subject only to the excluded-labels filter). This is how issues
  # are un-gated while PRs keep the dev-lead requirement.
  local required="${REQUIRED_LABEL-dev-lead}"
  # Use ${VAR-default} (no colon): an unset EXCLUDED_LABELS falls back to the
  # default set, but an explicitly empty value means "no exclusions" so a repo
  # can opt out entirely.
  local excluded_raw="${EXCLUDED_LABELS-compliance-audit,health-check,fleet-tracker,daily-report}"
  # Split the comma-separated excluded list into a JSON array (trim blanks,
  # drop empties) so the gate stays declarative in one jq invocation. `-Rs`
  # slurps the whole input so an empty string yields [] rather than no output.
  local excluded_json
  excluded_json=$(printf '%s' "${excluded_raw}" | jq -Rs 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0))')

  # Excluded labels must not appear together with the required label. Run in
  # ONE jq invocation rather than spawning per-label so we stay cheap and
  # the policy is declarative in one place.
  local result
  result=$(printf '%s' "${labels_json}" | jq -r \
    --arg required "${required}" \
    --argjson excluded "${excluded_json}" \
    '
      [.[].name] as $names
      | if ($required != "" and ($names | index($required) | not)) then
          "missing:" + $required
        else
          ([$excluded[] | select(. as $e | $names | index($e))]) as $hits
          | if ($hits | length) > 0 then "excluded:" + $hits[0]
            else "ok"
            end
        end
    ')

  case "${result}" in
    ok)
      return 0
      ;;
    missing:*)
      printf "missing required label '%s'\n" "${result#missing:}" >&2
      return 1
      ;;
    excluded:*)
      printf "has excluded label '%s'\n" "${result#excluded:}" >&2
      return 1
      ;;
    *)
      printf '[evaluate_noise_gate] unexpected gate result %q\n' "${result}" >&2
      return 65
      ;;
  esac
}

# Thin wrapper over the shared lookup: find the project item linked to a
# given issue/PR node id (or empty string if it isn't on the board).
find_content_item_id() {
  if [ "$#" -ne 1 ]; then
    printf '[find_content_item_id] expected 1 arg (content_node_id), got %d\n' "$#" >&2
    return 64
  fi
  find_project_item content-id "$1"
}

reconcile_content_with_project() {
  if [ "$#" -ne 3 ]; then
    printf '[reconcile_content_with_project] expected 3 args (content_node_id content_url labels_json), got %d\n' "$#" >&2
    return 64
  fi
  _atp_require_env reconcile_content_with_project || return $?
  local content_node_id="$1"
  local content_url="$2"
  local labels_json="$3"

  # Run the gate. Distinguish:
  #   exit 0 → qualifies, ensure it's on the board (idempotent add)
  #   exit 1 → does not qualify; remove it if it's currently on the board
  #   exit 64/65 → programmer or payload bug, fail loudly so the run is
  #               marked failed instead of silently dropping the item.
  local reason
  set +e
  reason=$(evaluate_noise_gate "${labels_json}" 2>&1)
  local gate_status=$?
  set -e

  case "${gate_status}" in
    0)
      printf 'Adding %s to %s\n' "${content_url}" "${PROJECT_URL:-the project}"
      add_content_to_project "${content_node_id}"
      ;;
    1)
      # Batch reconcile: if the prefetched membership cache says this content
      # is NOT on the board, the desired state (absent) already holds — skip
      # the find-to-remove lookup. Gated on _atp_membership_ready so the event
      # path (no cache) still performs the find + conditional remove.
      if _atp_membership_ready && ! _atp_on_board "${content_node_id}"; then
        printf 'Skip %s (not on board): %s\n' "${content_url}" "${reason}"
        return 0
      fi
      local existing
      existing=$(find_content_item_id "${content_node_id}")
      if [ -n "${existing}" ]; then
        printf 'Removing %s from %s (no longer qualifies: %s); item %s\n' \
          "${content_url}" "${PROJECT_URL:-the project}" "${reason}" "${existing}"
        delete_project_item "${existing}"
      else
        printf 'Skip %s (not on board): %s\n' "${content_url}" "${reason}"
      fi
      ;;
    *)
      printf '[reconcile_content_with_project] noise gate returned %d (programmer/payload bug, not a clean skip): %s\n' "${gate_status}" "${reason}" >&2
      return "${gate_status}"
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  reconcile_content_with_project \
    "${CONTENT_NODE_ID:?CONTENT_NODE_ID is required}" \
    "${CONTENT_URL:?CONTENT_URL is required}" \
    "${LABELS_JSON:?LABELS_JSON is required}"
fi
