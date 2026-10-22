#!/usr/bin/env bash
# scripts/seed-repo-template.sh — emit standard file content for the
# org repo-template to distribute to all new repos (#798, Story: SEED + DISTRIBUTE).
#
# Usage:
#   STANDARDS_DIR=<path> bash scripts/seed-repo-template.sh --emit-baseline .gitignore
#   STANDARDS_DIR=<path> bash scripts/seed-repo-template.sh --emit-workflow dev-lead.yml
#
# --emit-baseline .gitignore
#   Print the seeded .gitignore: the marker-wrapped L1 secrets baseline on top
#   (sourced from $STANDARDS_DIR/.gitignore), then standard ecosystem/OS L2 entries
#   below the END marker. L2 must NOT re-ignore any path the baseline negates
#   (e.g. .env.example is re-allowed in L1 via !.env.example).
#
# --emit-workflow <name.yml>
#   Print the caller-stub workflow VERBATIM from $STANDARDS_DIR/standards/workflows/,
#   the single source of truth for the org baseline scaffold. The re-seed MUST read
#   the stub through this path — never from a stale embedded copy — so it can never
#   revert repo-template to a wrong-channel pin (repo-template#86 flipped the
#   major-scoped `@<agent>/v<M>-stable` tags back to the BARE `@<agent>/stable` tier
#   tags, undoing the standards-deploy convergence and seeding new repos onto the
#   wrong channel — petry-projects/.github#886). As a fail-loud guard, a stub whose
#   first-party channel-ref pin is a bare `<agent>/<tier>` (missing the `v<M>-` major
#   prefix the compliance audit requires) is REFUSED rather than emitted.
#
# Env:
#   STANDARDS_REF   git reference to the standards artifact (e.g. standards/v1-stable,
#                   standards/v1.0.0). Defaults to standards/v1-stable. The ref is used
#                   for documentation/validation; the actual files are read from
#                   STANDARDS_DIR (not resolved via git).
#   STANDARDS_DIR   path to the petry-projects/.github checkout that holds the
#                   canonical /.gitignore, scripts/lib/gitignore-baseline.sh, and
#                   standards/workflows/. Defaults to the repo root above this script.
set -euo pipefail

STANDARDS_REF="${STANDARDS_REF:-standards/v1-stable}"
STANDARDS_DIR="${STANDARDS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"

_usage() {
  echo "Usage: $0 --emit-baseline <file> | --emit-workflow <name.yml>" >&2
  echo "  --emit-baseline supported files: .gitignore" >&2
  echo "  --emit-workflow reads standards/workflows/<name.yml> verbatim" >&2
  exit 2
}

# _assert_vform_pins <file> — a caller stub delegating to a first-party reusable
# through a channel ref MUST pin the major-scoped `<agent>/v<M>-<tier>` form, never
# the bare `<agent>/<tier>`. Those lines carry the inline S7637 marker, so we scope
# the check to them (mirrors test/scripts/standards-templates/vform-pins.bats).
# Exits non-zero listing every offending pin so the re-seed fails loud.
_assert_vform_pins() {
  local file="$1" bad unmarked agentref_bad
  # Fail-closed (#887 / qodo): the marker-based check below only inspects lines
  # carrying the '# NOSONAR(githubactions:S7637) first-party channel ref' marker.
  # If a deployable template has a first-party reusable `uses:` line but that line
  # LOST the marker, the pin check would see zero lines and pass — emitting an
  # unvalidated (possibly bare) pin. So first refuse any first-party reusable
  # `uses:` line that lacks the marker: the guard cannot validate what it can't
  # see, and must fail closed rather than emit unvalidated. (Local `./` self-host
  # refs and third-party actions are not '<...>-reusable.yml@' and are exempt.)
  unmarked="$(grep -E '^[[:space:]]*uses:[[:space:]]*petry-projects/[^[:space:]]*-reusable\.yml@' "$file" 2>/dev/null \
    | grep -vE 'S7637\) first-party channel ref' || true)"
  if [ -n "$unmarked" ]; then
    echo "::error::refusing to emit '${file#"${STANDARDS_DIR}"/}': first-party reusable uses: line(s) missing the '# NOSONAR(githubactions:S7637) first-party channel ref' marker — cannot validate the channel pin (fail-closed):" >&2
    printf '%s\n' "$unmarked" | sed 's/^/  /' >&2
    exit 3
  fi
  bad="$(grep -E 'S7637\) first-party channel ref' "$file" 2>/dev/null \
    | sed -E 's/.*-reusable\.yml@([^[:space:]]+).*/\1/' \
    | grep -vE '^[a-z0-9-]+/v[0-9]+-(stable|next|ring[0-9]+)$' || true)"
  if [ -n "$bad" ]; then
    echo "::error::refusing to emit '${file#"${STANDARDS_DIR}"/}': bare channel pin(s) — must be major-scoped <agent>/v<M>-<tier>:" >&2
    printf '%s\n' "$bad" | sed 's/^/  /' >&2
    exit 3
  fi
  # Same fail-closed guard for `with: agent_ref:` (CodeRabbit): dev-lead.yml /
  # add-to-project.yml thread the SAME channel into the reusable via agent_ref, so
  # a partial edit could drop it to a bare tier while the marked `uses:` pin stays
  # valid. Templates without an agent_ref match nothing here and pass unaffected.
  agentref_bad="$(grep -E '^[[:space:]]*agent_ref:[[:space:]]' "$file" 2>/dev/null \
    | sed -E 's/.*agent_ref:[[:space:]]*([^[:space:]#]+).*/\1/' \
    | grep -vE '^[a-z0-9-]+/v[0-9]+-(stable|next|ring[0-9]+)$' || true)"
  if [ -n "$agentref_bad" ]; then
    echo "::error::refusing to emit '${file#"${STANDARDS_DIR}"/}': agent_ref value(s) not major-scoped <agent>/v<M>-<tier>:" >&2
    printf '%s\n' "$agentref_bad" | sed 's/^/  /' >&2
    exit 3
  fi
}

# _emit_workflow <name.yml> — verbatim copy of the standards/workflows/ template,
# gated by the v-form pin guard above.
_emit_workflow() {
  local name="$1" src="${STANDARDS_DIR}/standards/workflows/$1"
  case "$name" in
    */*|.*|"") echo "::error::invalid workflow name '${name}'" >&2; exit 2 ;;
  esac
  if [ ! -f "$src" ]; then
    echo "::error::unknown workflow '${name}' — no template at standards/workflows/${name}" >&2
    exit 2
  fi
  _assert_vform_pins "$src"
  cat "$src"
}

[ $# -ge 2 ] || _usage

case "$1" in
  --emit-workflow) _emit_workflow "$2"; exit 0 ;;
  --emit-baseline) : ;;  # handled below
  *) _usage ;;
esac

file="$2"
case "$file" in
  .gitignore)
    # L1 — marker-wrapped org secrets baseline (org-managed, byte-identical).
    # shellcheck source=lib/gitignore-baseline.sh
    source "${STANDARDS_DIR}/scripts/lib/gitignore-baseline.sh"
    gib_extract_baseline_block "${STANDARDS_DIR}/.gitignore"

    # L2 — ecosystem / OS build artifacts (per-repo; edit freely below this line).
    # Do NOT add .env, .env.*, .envrc or any other path the baseline negates —
    # a later ignore silently re-hides a previously-negated file.
    cat <<'EOF'

# ---------------------------------------------------------------------------
# L2 — ecosystem / OS artifacts (edit freely; never re-ignore a baseline path)
# ---------------------------------------------------------------------------

# Node.js
node_modules/
dist/
build/
.cache/
coverage/
*.tgz

# Python
__pycache__/
*.py[cod]
*.egg-info/
.venv/
venv/

# Java / JVM
target/
*.class
*.jar

# OS
.DS_Store
Thumbs.db
EOF
    ;;
  *)
    echo "::error::unknown file '${file}' — only .gitignore is supported" >&2
    exit 2
    ;;
esac
