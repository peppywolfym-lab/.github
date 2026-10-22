#!/usr/bin/env bash
# filter-bots.sh — strip bot-authored issues/PRs from a JSON array.
#
# Why this exists:
#   The original gather-signals filter only excluded `dependabot[bot]` and
#   `github-actions[bot]`. New bots (renovate, copilot, coderabbit, claude)
#   pollute the signals payload and crowd out real user feedback.
#
# Configurable via FEATURE_IDEATION_BOT_AUTHORS (comma-separated, optional).
# Defaults to a sensible blocklist of known automation accounts. Items
# matching this list are REMOVED from the result. Adopters can add their
# own bot logins via the env var to extend the blocklist.

set -euo pipefail

# Default bot author logins. Override via env to add project-specific bots.
DEFAULT_BOT_AUTHORS=(
  "dependabot[bot]"
  "github-actions[bot]"
  "renovate[bot]"
  "copilot[bot]"
  "coderabbitai[bot]"
  "coderabbit[bot]"
  "claude[bot]"
  "claude-bot[bot]"
  "sonarcloud[bot]"
  "sonarqubecloud[bot]"
  "codeql[bot]"
  "snyk-bot"
  "imgbot[bot]"
  "allcontributors[bot]"
)

# Build the active bot list from defaults + env override.
filter_bots_build_list() {
  local list=("${DEFAULT_BOT_AUTHORS[@]}")
  if [ -n "${FEATURE_IDEATION_BOT_AUTHORS:-}" ]; then
    # Use `IFS=',' read` (not unquoted expansion) to avoid pathname-globbing
    # against the filesystem if any entry contains wildcard characters.
    # Caught by CodeRabbit review on PR petry-projects/.github#85.
    local extras=()
    IFS=',' read -r -a extras <<<"${FEATURE_IDEATION_BOT_AUTHORS}"
    # Trim leading/trailing whitespace from each comma-separated entry so
    # `"bot1, bot2"` resolves to `bot1` and `bot2`, not `bot1` and ` bot2`.
    # Caught by CodeRabbit review on PR petry-projects/.github#85.
    local trimmed=()
    local entry
    for entry in "${extras[@]}"; do
      # Strip leading whitespace, then trailing whitespace.
      entry="${entry#"${entry%%[![:space:]]*}"}"
      entry="${entry%"${entry##*[![:space:]]}"}"
      [ -n "$entry" ] && trimmed+=("$entry")
    done
    list+=("${trimmed[@]}")
  fi
  printf '%s\n' "${list[@]}" | jq -R . | jq -sc .
}

# Filter a JSON array of items, removing any whose .author.login is in the bot list.
# Reads JSON from stdin, writes filtered JSON to stdout.
filter_bots_apply() {
  local bot_list
  bot_list=$(filter_bots_build_list)
  jq --argjson bots "$bot_list" '[.[] | select((.author.login // "") as $a | ($bots | index($a)) | not)]'
}
