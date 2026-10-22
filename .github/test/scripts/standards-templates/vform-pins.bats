#!/usr/bin/env bats
# Template-guard for the caller-stub templates under standards/workflows/ (#860).
#
# A "deployable" template is one that pins a first-party reusable through a
# channel ref — the `uses:` line carrying the inline
#   # NOSONAR(githubactions:S7637) first-party channel ref
# marker. Every such pin must use the major-scoped `<agent>/v<M>-stable` channel
# and never the bare `<agent>/stable` form (a bare pin cannot be migrated by the
# major-scope tooling and silently rides whatever the tip of the channel is).
#
# The 4 verbatim templates (ci, copilot-setup-steps, initiative-driver,
# sonarcloud) have no first-party reusable `uses:` line and are exempt.

REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
WF_DIR="${REPO_ROOT}/standards/workflows"

# The templates that carry no first-party channel-ref `uses:` line.
VERBATIM="ci.yml copilot-setup-steps.yml initiative-driver.yml sonarcloud.yml"

# Emit each first-party channel-ref line in a file (marker-tagged uses lines).
channel_ref_lines() {
  grep -nE 'S7637\) first-party channel ref' "$1" || true
}

# Extract the `@<ref>` channel from a `uses: …-reusable.yml@<ref>  # …` line.
ref_of() {
  sed -E 's/.*-reusable\.yml@([^[:space:]]+).*/\1/' <<<"$1"
}

@test "every deployable template pins <agent>/v<M>-stable, never bare <agent>/stable" {
  local violations=()
  local f name lines line ref
  for f in "${WF_DIR}"/*.yml; do
    name="$(basename "$f")"
    lines="$(channel_ref_lines "$f")"
    [ -n "$lines" ] || continue
    while IFS= read -r line; do
      ref="$(ref_of "$line")"
      # Must be the major-scoped v-form: <agent>/v<M>-stable.
      if [[ ! "$ref" =~ ^[a-z0-9-]+/v[0-9]+-stable$ ]]; then
        violations+=("${name}: '${ref}' is not <agent>/v<M>-stable")
      fi
    done <<<"$lines"
  done
  if [ "${#violations[@]}" -ne 0 ]; then
    printf 'bad pin -> %s\n' "${violations[@]}"
    return 1
  fi
}

@test "agent_ref is byte-equal to the uses: channel where present" {
  local f name uses_ref agent_ref
  for f in "${WF_DIR}"/*.yml; do
    name="$(basename "$f")"
    grep -qE '^[[:space:]]*agent_ref:' "$f" || continue
    uses_ref="$(ref_of "$(channel_ref_lines "$f")")"
    agent_ref="$(grep -oE 'agent_ref:[[:space:]]*[^[:space:]]+' "$f" | sed -E 's/agent_ref:[[:space:]]*//')"
    [ "$agent_ref" = "$uses_ref" ] || {
      echo "${name}: agent_ref='${agent_ref}' != uses channel='${uses_ref}'"
      return 1
    }
  done
}

@test "the 4 verbatim templates carry no first-party channel-ref line" {
  local name lines
  for name in $VERBATIM; do
    [ -f "${WF_DIR}/${name}" ] || { echo "missing ${name}"; return 1; }
    lines="$(channel_ref_lines "${WF_DIR}/${name}")"
    [ -z "$lines" ] || { echo "${name} unexpectedly has a channel-ref line"; return 1; }
  done
}

@test "every non-verbatim template HAS a marker-tagged channel-ref line" {
  # Guards against a deployable template silently losing its channel pin (or the
  # NOSONAR marker): without this, the first test's `[ -n "$lines" ] || continue`
  # would skip an unmarked file and pass. Any non-verbatim template must carry a
  # first-party channel-ref line so it stays under the v-form pin check.
  local f name missing=()
  for f in "${WF_DIR}"/*.yml; do
    name="$(basename "$f")"
    case " $VERBATIM " in *" $name "*) continue ;; esac
    [ -n "$(channel_ref_lines "$f")" ] || missing+=("$name")
  done
  if [ "${#missing[@]}" -ne 0 ]; then
    printf 'non-verbatim template missing a first-party channel-ref line -> %s\n' "${missing[@]}"
    return 1
  fi
}
