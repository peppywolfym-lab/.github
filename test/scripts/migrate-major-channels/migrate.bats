#!/usr/bin/env bats
# F5 (epic #657) tests for scripts/migrate-major-channels.sh — the DRY_RUN-aware,
# App-token gh-api migration helper (never direct-push):
#   (a) create <agent>/v<M>-<tier> for every ring tier at the SAME commit as the
#       bare <agent>/<tier>, idempotent (skip if the v-tag already exists);
#   (b) --retire-bare <agent> deletes the bare-tier tags ONLY when no enrolled
#       consumer still pins them — it refuses otherwise.
#
# A fake `gh` supplies the reusable's release tags (for the major), the bare-tier
# tag commits, v-tag existence, and consumer stub contents. Mutating calls are
# logged to GH_CALLS so a DRY_RUN can be proven side-effect-free.

setup() {
  TT_TMP="$(mktemp -d "$BATS_TEST_TMPDIR/stub.XXXXXX")"
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/migrate-major-channels.sh"
  GH_CALLS="${TT_TMP}/gh-calls.log"; export GH_CALLS
  : > "$GH_CALLS"
  RINGS="${TT_TMP}/canary-rings.json"; export RINGS
  cat > "$RINGS" <<'JSON'
{
  "org_infra_repos": ["petry-projects/.github", "petry-projects/.github-private"],
  "agents": {
    "foo": {
      "host": "petry-projects/repoA",
      "reusable": ".github/workflows/foo-reusable.yml",
      "rings": [
        { "channel": "next",   "order": 0, "members": ["$host"] },
        { "channel": "ring0",  "order": 1, "members": ["$org_infra"] },
        { "channel": "ring1",  "order": 2, "members": ["petry-projects/consumerX"] },
        { "channel": "stable", "order": 3, "members": ["*"] }
      ]
    }
  }
}
JSON
}

teardown() { rm -rf "$TT_TMP"; }

# Fake gh. Env knobs:
#   FOO_MAJOR_REFS  matching-refs output for foo's release tags (empty → no major)
#   VTAG_EXISTS     if "true", every foo/v<M>-<tier> lookup reports the tag exists
#   CONSUMER_REF    the ref a single foo.yml stub pins (e.g. foo/ring1 or foo/v2-ring1)
#   STUB_SPEC       space-separated "<file>:<uses-ref>[:<agent_ref>]" tokens describing
#                   EVERY stub a consumer ships under .github/workflows/ (default: a lone
#                   "foo.yml:${CONSUMER_REF:-foo/ring1}"). The directory listing is
#                   derived from these files; each file's body pins foo's reusable at its
#                   <uses-ref> and threads <agent_ref> (default: the uses-ref) as the
#                   agent_ref input — so a stub can be v-form on uses: yet bare on
#                   agent_ref (#715). A <uses-ref> of literal "other" makes the file call
#                   an unrelated reusable (so the agent scan must ignore it).
#   AGENT_REF       overrides the agent_ref for the default single foo.yml stub (used
#                   with CONSUMER_REF to model a v-form uses: pin + bare agent_ref).
#   NO_AGENT_REF    if "true", stubs carry a uses: pin but NO agent_ref input.
install_gh_stub() {
  local bin="${TT_TMP}/bin"; mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
{ printf 'gh'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$GH_CALLS"
[ "${1:-}" = "api" ] || { exit 0; }
# find the path arg (first non-flag after 'api')
path=""
for a in "$@"; do case "$a" in -*|api) ;; *) path="$a"; break ;; esac; done
spec="${STUB_SPEC:-foo.yml:${CONSUMER_REF:-foo/ring1}}"
case "$path" in
  *matching-refs/tags/foo/v*)
    [ -n "${FOO_MAJOR_REFS:-}" ] && printf '%s\n' "${FOO_MAJOR_REFS}"
    exit 0 ;;
  *git/ref/tags/foo/v*)                 # v-tag existence / commit lookup
    if [ "${VTAG_EXISTS:-false}" = "true" ]; then
      printf 'ccccccccccccccccccccccccccccccccccccccc\tcommit\n'; exit 0
    fi
    exit 1 ;;                           # v-tag absent
  *git/ref/tags/foo/*)                  # bare-tier tag → resolves to a commit
    printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\tcommit\n'; exit 0 ;;
  */contents/.github/workflows)         # directory listing (post --jq '.[].name')
    for tok in $spec; do printf '%s\n' "${tok%%:*}"; done
    exit 0 ;;
  */contents/.github/workflows/*)       # a single consumer stub, content as JSON
    wf="${path##*/}"; found=""; uref=""; aref=""
    for tok in $spec; do
      [ "${tok%%:*}" = "$wf" ] || continue
      found=1; rest="${tok#*:}"          # <uses-ref>[:<agent_ref>]
      uref="${rest%%:*}"
      [ "$rest" != "$uref" ] && aref="${rest#*:}"
      break
    done
    [ -z "$found" ] && exit 1           # unknown file → 404
    if [ "$uref" = "emptycontent" ]; then # contents-API >1MB case: content:"" (undecodable)
      printf '{"content":"","encoding":"none"}'; exit 0
    fi
    if [ "$uref" = "other" ]; then       # calls an unrelated reusable — the scan must skip it
      body="    uses: petry-projects/.github/.github/workflows/bar-reusable.yml@bar/stable"
    else
      body="    uses: petry-projects/.github/.github/workflows/foo-reusable.yml@${uref}"
      # agent_ref: line — explicit per-file <agent_ref>, else the AGENT_REF knob, else the
      # uses-ref. NO_AGENT_REF omits it (a stub with a uses: pin but no agent_ref input).
      if [ "${NO_AGENT_REF:-false}" != "true" ]; then
        body="${body}
    with:
      agent_ref: ${aref:-${AGENT_REF:-$uref}}"
      fi
    fi
    b64="$(printf '%s' "$body" | base64 | tr -d '\n')"
    printf '{"content":"%s"}' "$b64"
    exit 0 ;;
  *git/refs*) exit 0 ;;                 # create/delete ref (mutating)
esac
exit 0
STUB
  chmod +x "$bin/gh"
  PATH="${bin}:${PATH}"; export PATH
}

@test "DRY_RUN plans same-commit v-tag creation for every tier, no mutating calls" {
  export FOO_MAJOR_REFS="refs/tags/foo/v2.1.0"
  install_gh_stub
  run env GH_TOKEN=x DRY_RUN=true CANARY_RINGS="$RINGS" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  # all four tiers planned against the SAME bare commit (deadbeef…)
  echo "$output" | grep -qF 'foo/v2-next'
  echo "$output" | grep -qF 'foo/v2-ring0'
  echo "$output" | grep -qF 'foo/v2-ring1'
  echo "$output" | grep -qF 'foo/v2-stable'
  echo "$output" | grep -qF 'deadbeefdeadbeef'
  # DRY_RUN must not create any ref
  ! grep -qE 'POST .*git/refs' "$GH_CALLS"
}

@test "idempotent — skips a tier whose v-tag already exists" {
  export FOO_MAJOR_REFS="refs/tags/foo/v2.1.0"
  export VTAG_EXISTS=true
  install_gh_stub
  run env GH_TOKEN=x DRY_RUN=true CANARY_RINGS="$RINGS" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qiE 'foo/v2-stable.*(exist|skip)'
  # nothing planned for creation since all exist
  ! grep -qi 'would create' <<< "$output"
}

@test "--retire-bare refuses while an enrolled consumer still pins bare" {
  export FOO_MAJOR_REFS="refs/tags/foo/v2.1.0"
  export CONSUMER_REF="foo/ring1"   # consumerX still on the bare tier
  install_gh_stub
  run env GH_TOKEN=x DRY_RUN=true CANARY_RINGS="$RINGS" bash "$SCRIPT" --retire-bare foo
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'refuse'
  echo "$output" | grep -qF 'consumerX'
  # guard must not delete any tag
  ! grep -qE 'DELETE .*git/refs' "$GH_CALLS"
}

@test "--retire-bare proceeds (dry-run) when no enrolled consumer pins bare" {
  export FOO_MAJOR_REFS="refs/tags/foo/v2.1.0"
  export CONSUMER_REF="foo/v2-ring1"   # consumerX already migrated to the v-form (uses: AND agent_ref)
  install_gh_stub
  run env GH_TOKEN=x DRY_RUN=true CANARY_RINGS="$RINGS" bash "$SCRIPT" --retire-bare foo
  [ "$status" -eq 0 ]
  echo "$output" | grep -qiE 'would delete .*foo/(stable|ring1)'
  ! grep -qE 'DELETE .*git/refs' "$GH_CALLS"
}

@test "--retire-bare proceeds when the stub has a v-form uses: pin and NO agent_ref (must not fail-close on the empty grep)" {
  export FOO_MAJOR_REFS="refs/tags/foo/v2.1.0"
  export CONSUMER_REF="foo/v2-ring1"   # uses: v-form
  export NO_AGENT_REF="true"            # stub carries no agent_ref: line (the common case)
  install_gh_stub
  run env GH_TOKEN=x DRY_RUN=true CANARY_RINGS="$RINGS" bash "$SCRIPT" --retire-bare foo
  [ "$status" -eq 0 ]
  echo "$output" | grep -qiE 'would delete .*foo/(stable|ring1)'
  ! echo "$output" | grep -qi 'could not read'   # must NOT fail-close
}

@test "--retire-bare refuses when uses: is v-form but agent_ref: is still bare (regression: broke dev-lead)" {
  export FOO_MAJOR_REFS="refs/tags/foo/v2.1.0"
  export CONSUMER_REF="foo/v2-ring1"   # uses: pin already migrated…
  export AGENT_REF="foo/ring1"          # …but agent_ref: still bare (the load-bearing checkout ref)
  install_gh_stub
  run env GH_TOKEN=x DRY_RUN=true CANARY_RINGS="$RINGS" bash "$SCRIPT" --retire-bare foo
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'refuse'
  echo "$output" | grep -qF 'consumerX'
  ! grep -qE 'DELETE .*git/refs' "$GH_CALLS"
}

@test "--emit-repins lists enrolled consumers still on a bare tier with the v-form to move to" {
  export FOO_MAJOR_REFS="refs/tags/foo/v2.1.0"
  export CONSUMER_REF="foo/ring1"   # consumerX still on the bare tier
  install_gh_stub
  run env GH_TOKEN=x CANARY_RINGS="$RINGS" bash "$SCRIPT" --emit-repins --agent foo
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'consumerX'
  echo "$output" | grep -qF 'foo/v2-ring1'
}

# ── multi-stub coverage (F5 long-tail, #707) ──────────────────────────────────
# A consumer may ship more than one stub calling the same reusable — e.g.
# .github-private's dev-lead.yml PLUS dev-lead-retry.yml / dev-lead-health.yml.
# The guard/emitter must scan EVERY such stub, not just <agent>.yml, or a bare
# secondary stub is silently missed (retirement wrongly proceeds; re-pin never
# listed). ring1 is consumerX's tier, so its bare pins map to foo/v2-ring1.

@test "--retire-bare refuses when a secondary stub is bare even though <agent>.yml is migrated" {
  export FOO_MAJOR_REFS="refs/tags/foo/v2.1.0"
  # foo.yml already on the v-form, but the retry stub is still bare.
  export STUB_SPEC="foo.yml:foo/v2-ring1 foo-retry.yml:foo/ring1"
  install_gh_stub
  run env GH_TOKEN=x DRY_RUN=true CANARY_RINGS="$RINGS" bash "$SCRIPT" --retire-bare foo
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'refuse'
  echo "$output" | grep -qF 'foo-retry.yml'
  ! grep -qE 'DELETE .*git/refs' "$GH_CALLS"
}

@test "--emit-repins lists each bare secondary stub by filename, not just <agent>.yml" {
  export FOO_MAJOR_REFS="refs/tags/foo/v2.1.0"
  export STUB_SPEC="foo.yml:foo/v2-ring1 foo-retry.yml:foo/ring1 foo-health.yml:foo/ring1"
  install_gh_stub
  run env GH_TOKEN=x CANARY_RINGS="$RINGS" bash "$SCRIPT" --emit-repins --agent foo
  [ "$status" -eq 0 ]
  # Both bare secondary stubs are named and targeted at the v-form; the already
  # migrated foo.yml is NOT emitted as a re-pin.
  echo "$output" | grep -qF 'foo-retry.yml'
  echo "$output" | grep -qF 'foo-health.yml'
  echo "$output" | grep -qF 'foo/v2-ring1'
  ! grep -qE 'repin[^\n]*/foo\.yml:' <<< "$output"
}

@test "--retire-bare proceeds (dry-run) when main + retry + health stubs are all migrated" {
  export FOO_MAJOR_REFS="refs/tags/foo/v2.1.0"
  export STUB_SPEC="foo.yml:foo/v2-ring1 foo-retry.yml:foo/v2-ring1 foo-health.yml:foo/v2-ring1"
  install_gh_stub
  run env GH_TOKEN=x DRY_RUN=true CANARY_RINGS="$RINGS" bash "$SCRIPT" --retire-bare foo
  [ "$status" -eq 0 ]
  echo "$output" | grep -qiE 'would delete .*foo/(stable|ring1)'
  ! grep -qE 'DELETE .*git/refs' "$GH_CALLS"
}

@test "an unrelated workflow stub in the consumer is ignored by the scan" {
  export FOO_MAJOR_REFS="refs/tags/foo/v2.1.0"
  # ci.yml calls a DIFFERENT reusable; only foo-retry.yml is a bare foo stub.
  export STUB_SPEC="foo.yml:foo/v2-ring1 ci.yml:other foo-retry.yml:foo/ring1"
  install_gh_stub
  run env GH_TOKEN=x DRY_RUN=true CANARY_RINGS="$RINGS" bash "$SCRIPT" --retire-bare foo
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF 'foo-retry.yml'
  # the unrelated ci.yml must never be named as an offender
  ! echo "$output" | grep -qF 'ci.yml'
}

# ── fail-closed on undecodable content (#708 review finding, blocking) ─────────
# The contents API returns content:"" (encoding:none) for files >1MB, and a
# malformed payload fails base64 decode. Either must ABORT the scan — NOT cache an
# empty file and silently skip the stub, or --retire-bare could delete bare tags
# for a consumer whose stubs were never actually read (the #657 breakage class).

@test "--retire-bare aborts (fail-closed) when a stub's content can't be decoded" {
  export FOO_MAJOR_REFS="refs/tags/foo/v2.1.0"
  # foo.yml is clean v-form, but foo-retry.yml comes back as the >1MB empty-content case.
  export STUB_SPEC="foo.yml:foo/v2-ring1 foo-retry.yml:emptycontent"
  install_gh_stub
  run env GH_TOKEN=x DRY_RUN=true CANARY_RINGS="$RINGS" bash "$SCRIPT" --retire-bare foo
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'fail-closed'
  echo "$output" | grep -qF 'foo-retry.yml'
  # must NOT have proceeded to plan any deletion
  ! echo "$output" | grep -qi 'would delete'
  ! grep -qE 'DELETE .*git/refs' "$GH_CALLS"
}
