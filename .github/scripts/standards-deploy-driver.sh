#!/usr/bin/env bash
# standards-deploy-driver.sh — scheduled fleet-sweep driver for the org-standard
# workflow deployer (petry-projects/.github#851, Epic #850).
#
# The compliance audit only *files* remediation issues; bringing the fleet to
# standard still required a human running deploy-standard-workflows.sh by hand.
# This driver closes that gap: the standards-deploy.yml workflow runs it on the
# org cadence (and on demand), so drifted repos get standards-sync PRs opened
# automatically.
#
# It is deliberately THIN — it adds NO deploy logic. All drift detection,
# SKIP_REPOS / SKIP_OVERRIDES handling, ring/channel pinning, idempotency, and
# PR creation live in deploy-standard-workflows.sh and its libs. This driver only
# maps workflow_dispatch inputs (environment variables) onto that script's flags
# and runs it, so the dispatch surface stays unit-testable.
#
# Inputs (environment variables, all optional):
#   TARGET_REPO      Limit the sweep to a single repo (--repo). Blank = whole fleet.
#   TARGET_WORKFLOW  Limit to a single workflow (--workflow). Blank = all deployable.
#   DRY_RUN          "true" -> pass --dry-run (plan only, open no PRs).
#
# Overridable for tests:
#   DEPLOY_SCRIPT    Path to the deploy script (default: sibling in this dir).
#
# Requires GH_TOKEN to be a cross-repo WRITE identity — contents:write +
# pull_requests:write on the target repos (e.g. GH_PAT_DON_PETRY / the legacy
# GH_PAT_WORKFLOWS). The audit token (ORG_SCORECARD_TOKEN) is read-only for
# Contents and cannot deploy stubs — see petry-projects/.github#864.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="${DEPLOY_SCRIPT:-$SCRIPT_DIR/deploy-standard-workflows.sh}"

TARGET_REPO="${TARGET_REPO:-}"
TARGET_WORKFLOW="${TARGET_WORKFLOW:-}"
DRY_RUN="${DRY_RUN:-false}"

# Build the flag list from the inputs. An empty list means "whole fleet, all
# deployable workflows" — the scheduled default.
declare -a args=()
[[ -n "$TARGET_REPO" ]]     && args+=(--repo "$TARGET_REPO")
[[ -n "$TARGET_WORKFLOW" ]] && args+=(--workflow "$TARGET_WORKFLOW")
[[ "$DRY_RUN" == "true" ]]  && args+=(--dry-run)

echo "[driver] standards-deploy sweep — repo=${TARGET_REPO:-<all>} workflow=${TARGET_WORKFLOW:-<all>} dry_run=${DRY_RUN}"

exec bash "$DEPLOY_SCRIPT" "${args[@]}"
