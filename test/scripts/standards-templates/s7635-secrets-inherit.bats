#!/usr/bin/env bats
# Template-guard for the S7635 NOSONAR marker on caller-stub templates under
# standards/workflows/ (#875, mirrors the #860 v-form/S7637 pin guard).
#
# A caller stub that hands the reusable every org secret via `secrets: inherit`
# trips SonarCloud rule `githubactions:S7635` ("only pass required secrets").
# The reusable is first-party and fully trusted, so the stub carries an inline
#   secrets: inherit  # NOSONAR(githubactions:S7635) <prose>
# marker that suppresses S7635 on exactly that line and travels with the stub to
# every consumer repo. Dropping the marker regresses any consumer that copied
# the stub (re-triggers S7635 in their SonarCloud run). This guard fails in CI
# the moment a template with `secrets: inherit` loses the marker.
#
# Stubs that pass secrets EXPLICITLY (least privilege, no `secrets: inherit`
# line — e.g. add-to-project.yml, pr-review-mention.yml) do not trip S7635 and
# are correctly ignored: the guard only inspects real `secrets: inherit` lines.

REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
WF_DIR="${REPO_ROOT}/standards/workflows"

# The exact NOSONAR token every marked line must carry (grep -F, literal).
MARKER='NOSONAR(githubactions:S7635)'

# Emit `secrets: inherit` lines that are REAL YAML (indented key), never a `#`
# comment mention. Anchors `secrets:` to the start-of-line-after-indent so a
# prose line like `# ... secrets: inherit ...` is not matched.
secrets_inherit_lines() {
  grep -nE '^[[:space:]]*secrets:[[:space:]]+inherit([[:space:]]|$)' "$1" || true
}

@test "every template with 'secrets: inherit' carries the S7635 marker" {
  local violations=()
  local f name lines line lineno content
  for f in "${WF_DIR}"/*.yml; do
    name="$(basename "$f")"
    lines="$(secrets_inherit_lines "$f")"
    [ -n "$lines" ] || continue
    while IFS= read -r line; do
      lineno="${line%%:*}"
      content="${line#*:}"
      if ! grep -qF "$MARKER" <<<"$content"; then
        violations+=("${name}:${lineno}: 'secrets: inherit' line lacks ${MARKER}")
      fi
    done <<<"$lines"
  done
  if [ "${#violations[@]}" -ne 0 ]; then
    printf 'missing S7635 marker -> %s\n' "${violations[@]}"
    return 1
  fi
}

@test "every S7635 marker uses the canonical inline shape" {
  # Two spaces before the '#', then the exact token. Trailing prose is free-form
  # (e.g. 'first-party trusted reusable' vs 'org secrets are scoped ...'), but
  # the marker itself must be byte-consistent so SonarCloud honours it.
  local violations=()
  local f name lines line lineno content
  for f in "${WF_DIR}"/*.yml; do
    name="$(basename "$f")"
    lines="$(secrets_inherit_lines "$f")"
    [ -n "$lines" ] || continue
    while IFS= read -r line; do
      lineno="${line%%:*}"
      content="${line#*:}"
      grep -qF "$MARKER" <<<"$content" || continue
      if ! grep -qE 'secrets: inherit  # NOSONAR\(githubactions:S7635\) ' <<<"$content"; then
        violations+=("${name}:${lineno}: marker is not the canonical 'secrets: inherit  # NOSONAR(githubactions:S7635) <prose>' shape")
      fi
    done <<<"$lines"
  done
  if [ "${#violations[@]}" -ne 0 ]; then
    printf 'bad marker shape -> %s\n' "${violations[@]}"
    return 1
  fi
}

@test "the guard actually inspects at least one 'secrets: inherit' stub" {
  # Positive control: without this, a broken matcher that finds nothing would let
  # the first test pass vacuously (its `[ -n "$lines" ] || continue` skips every
  # file). At least one template uses `secrets: inherit` by design.
  local f found=0
  for f in "${WF_DIR}"/*.yml; do
    [ -n "$(secrets_inherit_lines "$f")" ] && found=1 && break
  done
  [ "$found" -eq 1 ] || { echo "no template with a real 'secrets: inherit' line found"; return 1; }
}
