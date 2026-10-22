#!/usr/bin/env bash
# labels.sh — the single source of truth for the org standard label set.
#
# Sourced by scripts/apply-repo-settings.sh (provisions labels), scripts/
# compliance-audit.sh (reports missing labels), and scripts/compliance-remediate.sh
# (creates missing labels). Before this library each of those three scripts held
# its OWN hardcoded copy of the seven fixed labels — and only the applier knew the
# derived <id>:hands-off persona family — so the audit could not report a missing
# persona label and the remediator could not create one (issue #1139, AC#2).
#
# It defines two things both the fixed set and the derived family flow from:
#   STANDARD_LABEL_SPECS          — the fixed set (name|color|description).
#   persona_opt_out_label_configs — the derived <id>:hands-off family, computed
#                                   from the persona manifests, never enumerated.
# and one lookup helper the remediator uses:
#   std_label_spec <name>         — the spec (name|color|description) for a given
#                                   standard label, fixed set OR derived family.
#
# Source of truth: standards/github-settings.md § "Labels — Standard Set".

# ---------------------------------------------------------------------------
# Persona manifest source (the derived family is computed from these)
# ---------------------------------------------------------------------------
# `.github-private` is PUBLIC (private:false, verified) despite its name, so these
# reads work over the token the sourcing script already uses and need no extra
# auth. See standards/persona-standards.md §1.1 (the manifest is the
# index-of-record) and §4 rule 4 (every persona defines an opt_out_label).
PERSONA_MANIFEST_REPO="${PERSONA_MANIFEST_REPO:-petry-projects/.github-private}"
PERSONA_MANIFEST_REF="${PERSONA_MANIFEST_REF:-main}"

# One consistent color for the entire opt-out family — neutral grey, deliberately
# distinct from the functional labels (security/bug red, dependency/docs blue,
# in-progress yellow). Documented in standards/github-settings.md#labels--standard-set.
PERSONA_OPT_OUT_COLOR="ededed"

# ---------------------------------------------------------------------------
# Fixed set — name|color|description (color without leading #)
# ---------------------------------------------------------------------------
# Matches standards/github-settings.md § "Labels — Standard Set" → "Fixed set".
# `compliance-finding` is deliberately absent: it is a machine-owned label the
# audit provisions itself via its own ensure_audit_label path, not part of the
# label set provisioned to every repo.
STANDARD_LABEL_SPECS=(
  "security|d93f0b|Security-related PRs and issues"
  "dependencies|0075ca|Dependency update PRs"
  "scorecard|d93f0b|OpenSSF Scorecard findings"
  "bug|d73a4a|Bug reports"
  "enhancement|a2eeef|Feature requests"
  "documentation|0075ca|Documentation changes"
  "in-progress|fbca04|An agent is actively working this issue"
)

# ---------------------------------------------------------------------------
# persona_opt_out_label_configs — the derived <id>:hands-off family
# ---------------------------------------------------------------------------
# Emit one "name|color|description" line per persona, deriving the <id>:hands-off
# opt-out label from the persona manifests rather than a hand-maintained list.
# Adding a persona therefore needs NO edit here: the family follows from
# personas/<id>/persona.yml, the index-of-record (persona-standards.md §1.1).
# Draft personas are included — being able to say "hands-off" is exactly what a
# draft needs.
#
# Returns non-zero if the family could not be derived faithfully. It still emits
# whatever it resolved (so a hiccup never blocks the STATIC label set — that
# resilience is deliberate), but callers record the failure and MUST NOT report
# success. Emitting nothing and returning 0 would make "labels applied ✅"
# indistinguishable from "the opt-out hatch is missing" (petry-projects/.github#755).
persona_opt_out_label_configs() {
  local ids id opt_out opt_out_raw rc=0
  ids=$(gh api "repos/$PERSONA_MANIFEST_REPO/contents/personas?ref=$PERSONA_MANIFEST_REF" 2>/dev/null \
        | jq -r '.[]? | select(.type == "dir") | .name' 2>/dev/null) || {
    warn "  Could not list persona manifests from $PERSONA_MANIFEST_REPO — opt-out labels NOT applied"
    return 1
  }
  # A LISTING that returns cleanly but is unparseable (e.g. an HTML error page or a
  # non-array body) yields an empty $ids and a jq that exited 0 above. Treat an
  # empty listing as a derivation failure too — an org always has personas, so
  # "no personas" is the fail-closed signal, never a legitimate "family is empty"
  # (petry-projects/.github#755, issue #1139 AC#3). Without this a garbled listing
  # would read as "no persona labels required".
  if [ -z "$ids" ]; then
    warn "  Persona manifest listing from $PERSONA_MANIFEST_REPO was empty or unparseable — opt-out labels NOT applied"
    return 1
  fi

  while IFS= read -r id; do
    [ -z "$id" ] && continue
    # Prefer the manifest's declared opt_out_label; fall back to the <id>:hands-off
    # convention (persona-standards.md §4 rule 4) when the field cannot be read.
    if opt_out_raw=$(gh api "repos/$PERSONA_MANIFEST_REPO/contents/personas/$id/persona.yml?ref=$PERSONA_MANIFEST_REF" \
                       -H "Accept: application/vnd.github.raw" 2>/dev/null); then
      # `opt_out_label` is a free-form string in the schema, and GitHub label names
      # may contain spaces — so this must NOT truncate at the first word (an
      # `awk '{print $1}'` here would provision "needs" for a label named
      # "needs human review", leaving the real opt-out absent and the hatch broken).
      # Take the whole scalar, then strip: trailing YAML comment (which requires
      # leading whitespace), trailing space, and surrounding quotes.
      opt_out=$(printf '%s' "$opt_out_raw" \
                | sed -n 's/^[[:space:]]*opt_out_label:[[:space:]]*//p' | head -1 \
                | tr -d '\r' \
                | sed -e 's/[[:space:]]\{1,\}#.*$//' \
                      -e 's/[[:space:]]*$//' \
                      -e 's/^"\(.*\)"$/\1/' \
                      -e "s/^'\(.*\)'$/\1/")
    else
      # The convention fallback below is a GUESS. §4 rule 4 makes <id>:hands-off
      # only a convention — the schema lets a persona declare any opt_out_label —
      # so if the manifest is unreadable we may create a label nobody uses while
      # the real one stays absent, leaving opt-out silently broken. Emit it (it is
      # the best guess) but do not call the run a success.
      warn "  Could not read personas/$id/persona.yml — guessing '$id:hands-off' from the convention"
      opt_out=""
      rc=1
    fi
    [ -z "$opt_out" ] && opt_out="$id:hands-off"
    # The label name is the FIRST pipe-delimited field of the emitted spec, so a
    # name that itself contains '|' (opt_out_label is free-form, and GitHub label
    # names may contain a pipe) would shift the color/description fields and
    # corrupt every downstream parser (std_label_spec's `${spec%%|*}`, the audit/
    # applier splits). We cannot represent such a name in this format, so reject
    # it: warn, skip it, and fail the derivation — never emit a corrupt record.
    if [ "${opt_out#*|}" != "$opt_out" ]; then
      warn "  personas/$id opt_out_label '$opt_out' contains '|' (the field delimiter) — skipping; opt-out label NOT applied"
      rc=1
      continue
    fi
    printf '%s|%s|Opt an item out of the %s persona automation entirely\n' \
      "$opt_out" "$PERSONA_OPT_OUT_COLOR" "$id"
  done <<< "$ids"
  return "$rc"
}

# ---------------------------------------------------------------------------
# std_label_spec <name> — the spec for a standard label, fixed set OR derived
# ---------------------------------------------------------------------------
# Emit the "name|color|description" spec for <name>, consulting the fixed set
# first and then the derived persona opt-out family. Returns 1 (and prints
# nothing) if <name> is not a standard label. The derived family is consulted so
# the remediator can create a missing <id>:hands-off label from the SAME source
# of truth — no second table (issue #1139, AC#2/AC#4).
#
# The single-lookup derivation is best-effort: its rc is ignored here (a caller
# resolving one label's colour must not be blocked by an unrelated persona's
# unreadable manifest). Fail-closed reporting of a broken derivation is the
# audit's job (check_labels), not this pointwise lookup's.
std_label_spec() {
  local want="$1" spec name
  for spec in "${STANDARD_LABEL_SPECS[@]}"; do
    name="${spec%%|*}"
    if [ "$name" = "$want" ]; then
      printf '%s\n' "$spec"
      return 0
    fi
  done
  local derived
  derived=$(persona_opt_out_label_configs 2>/dev/null) || true
  while IFS= read -r spec; do
    [ -z "$spec" ] && continue
    name="${spec%%|*}"
    if [ "$name" = "$want" ]; then
      printf '%s\n' "$spec"
      return 0
    fi
  done <<< "$derived"
  return 1
}

# `warn` is provided by every sourcing script (apply-repo-settings.sh,
# compliance-audit.sh, compliance-remediate.sh all define it before sourcing).
# Define a fallback only if the sourcing context lacks one, so the library is
# safe to source standalone (e.g. in unit tests).
if ! declare -F warn >/dev/null 2>&1; then
  warn() { echo "[WARN]  $*" >&2; }
fi
