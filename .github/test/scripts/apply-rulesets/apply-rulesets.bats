#!/usr/bin/env bats
# Unit tests for scripts/apply-rulesets.sh — the codified, file-driven applier that
# replaced the retired detection-based builder (petry-projects/.github#580 / #575).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
APPLY="$SCRIPT_DIR/scripts/apply-rulesets.sh"
RULESETS_DIR="$SCRIPT_DIR/standards/rulesets"

setup() {
  STUB_BIN="$(mktemp -d)"; export PATH="$STUB_BIN:$PATH"
  CALLS="$STUB_BIN/calls.log"; export CALLS
}
teardown() { [ -n "${STUB_BIN:-}" ] && rm -rf "$STUB_BIN"; return 0; }

# gh stub: records writes (POST/PUT) to $CALLS (args line then --input body);
# returns $RULESETS_LIST for the rulesets LIST (default [] → create path);
# returns $REPO_LIST for `repo list`.
_stub_gh() {
  cat > "$STUB_BIN/gh" <<EOF
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"--method POST"*|*"--method PUT"*)
    echo "\$args" >> "$CALLS"
    prev=""
    for arg in "\$@"; do
      [ "\$prev" = "--input" ] && { cat "\$arg" >> "$CALLS"; break; }
      prev="\$arg"
    done
    echo '{}' ;;
  *"repo list"*) printf '%s' "\${REPO_LIST:-}" ;;
  *"rulesets"*)  printf '%s' "\${RULESETS_LIST:-[]}" ;;
  *) echo '{}' ;;
esac
EOF
  chmod +x "$STUB_BIN/gh"
}

# ── codified source of truth: shape + the anti-divergence guard (#580) ────────
@test "code-quality.json: requires exactly the 4 codified contexts" {
  run jq -r '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context] | sort | join(",")' "$RULESETS_DIR/code-quality.json"
  [ "$status" -eq 0 ]
  [ "$output" = "CodeQL,SonarCloud,agent-shield / AgentShield,dependency-audit / Detect ecosystems" ]
}

@test "code-quality.json: does NOT require 'Dev-Lead Agent' (the retired divergence)" {
  run jq -e '[.rules[]?.parameters?.required_status_checks?[]?.context] | any(. // "" | test("Dev-Lead"))' "$RULESETS_DIR/code-quality.json"
  # jq `any` over no match exits 1 (false) — that is the pass condition.
  [ "$status" -ne 0 ]
}

@test "pr-quality.json + code-quality.json carry both bypass actors (OrgAdmin + Integration)" {
  local f
  for f in pr-quality code-quality; do
    run jq -e '[.bypass_actors[].actor_type] | (index("OrganizationAdmin") and index("Integration"))' "$RULESETS_DIR/$f.json"
    [ "$status" -eq 0 ]
  done
}

@test "pr-quality.json: allows squash merges only (allowed_merge_methods == [squash])" {
  # Anti-divergence guard (#771): the pr-quality ruleset enforces squash-only merges.
  # Widening this to include merge/rebase is exactly the drift the compliance audit's
  # check_ruleset_contents() flags. Lock the codified source of truth so it can never
  # silently regress to [merge, rebase, squash].
  run jq -c '.rules[]? | select(.type=="pull_request") | .parameters.allowed_merge_methods' "$RULESETS_DIR/pr-quality.json"
  [ "$status" -eq 0 ]
  [ "$output" = '["squash"]' ]
}

@test "pr-quality.json: requires last-push approval (require_last_push_approval == true)" {
  # Anti-divergence guard (#957): the pr-quality ruleset requires that the last
  # push be re-approved, so a substantive push after approval cannot merge on the
  # stale review (github-settings.md#pr-quality). Flipping this to false is exactly
  # the drift the compliance audit's check_ruleset_contents() flags. Lock the
  # codified source of truth so it can never silently regress to false.
  run jq -r '.rules[]? | select(.type=="pull_request") | .parameters.require_last_push_approval' "$RULESETS_DIR/pr-quality.json"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "pr-quality.json: dismisses stale reviews on push (dismiss_stale_reviews_on_push == true)" {
  # Anti-divergence guard (#958): the pr-quality ruleset dismisses existing approvals
  # when a new commit is pushed, so a stale review cannot carry a substantive push to
  # merge (github-settings.md#pr-quality). Flipping this to false is exactly the drift
  # the compliance audit's check_ruleset_contents() flags. Lock the codified source of
  # truth so it can never silently regress to false.
  run jq -r '.rules[]? | select(.type=="pull_request") | .parameters.dismiss_stale_reviews_on_push' "$RULESETS_DIR/pr-quality.json"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "pr-quality.json: omits 'automatic_copilot_code_review_enabled' (Free-plan API rejects it)" {
  # GitHub's rulesets API 422s ("Unexpected parameter") on this pull_request
  # parameter for Free-plan orgs, which blocks apply-rulesets from creating or
  # updating pr-quality fleet-wide. It must stay out of the codified ruleset.
  run jq '.rules[] | select(.type=="pull_request") | .parameters | has("automatic_copilot_code_review_enabled")' "$RULESETS_DIR/pr-quality.json"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "release-channel-tags.json: tag ruleset, generic refs/tags/** include, update+deletion only" {
  run jq -er '.target == "tag"
    and (.conditions.ref_name.include == ["refs/tags/**"])
    and ([.rules[].type] | sort == ["deletion","update"])' "$RULESETS_DIR/release-channel-tags.json"
  [ "$status" -eq 0 ]
}

@test "release-channel-tags.json: carries OrgAdmin + both Integration apps (automation 3167543 + release-manager 4193127)" {
  run jq -er '([.bypass_actors[] | select(.actor_type=="Integration") | .actor_id] | sort == [3167543,4193127])
    and ([.bypass_actors[].actor_type] | index("OrganizationAdmin"))' "$RULESETS_DIR/release-channel-tags.json"
  [ "$status" -eq 0 ]
}

# ── repo self-host guard: dependency-audit.yml publishes the codified context ─
# code-quality.json requires `dependency-audit / Detect ecosystems` (asserted
# above). GitHub composes that context as `<caller-job-id> / <reusable-job
# displayName>`, so this repo's OWN dependency-audit.yml must be the thin caller
# stub (job id `dependency-audit` → dependency-audit-reusable.yml, whose detect
# job is displayName "Detect ecosystems"), matching agent-shield.yml's self-host
# pattern. The pre-centralization inline workflow ran a top-level `detect` job
# directly, publishing the bare `Detect ecosystems` context and drifting the
# live ruleset off the codified name (#772).
DEP_AUDIT_WF="$SCRIPT_DIR/.github/workflows/dependency-audit.yml"

@test "dependency-audit.yml: is a caller stub with job 'dependency-audit' using the reusable" {
  run grep -Eq '^  dependency-audit:[[:space:]]*$' "$DEP_AUDIT_WF"
  [ "$status" -eq 0 ]
  run grep -Eq '^[[:space:]]*uses:[[:space:]]*.*dependency-audit-reusable\.yml' "$DEP_AUDIT_WF"
  [ "$status" -eq 0 ]
}

@test "dependency-audit.yml: carries no inline 'detect' job (would publish bare 'Detect ecosystems')" {
  run grep -Eq '^  detect:[[:space:]]*$' "$DEP_AUDIT_WF"
  [ "$status" -eq 1 ]
}

# ── apply behavior: create / update / dry-run ─────────────────────────────────
@test "apply --repo: creates rulesets when absent (POST per file)" {
  _stub_gh
  export RULESETS_LIST='[]'
  run bash "$APPLY" --repo petry-projects/acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"done (2 ruleset(s))"* ]]
  [ "$(grep -c 'method POST' "$CALLS")" -eq 2 ]
  ! grep -q 'method PUT' "$CALLS"
}

@test "apply --repo: updates when present (PUT by id)" {
  _stub_gh
  export RULESETS_LIST='[{"id":7,"name":"code-quality"},{"id":9,"name":"pr-quality"}]'
  run bash "$APPLY" --repo petry-projects/acme
  [ "$status" -eq 0 ]
  grep -q 'method PUT' "$CALLS"
  ! grep -q 'method POST' "$CALLS"
}

@test "apply: --dry-run makes no write calls" {
  _stub_gh
  export RULESETS_LIST='[]'
  run bash "$APPLY" --repo petry-projects/acme --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS" ]
  [[ "$output" == *"dry-run"* ]]
}

@test "apply --repo: pr-quality POST payload includes dismiss_stale_reviews_on_push=true" {
  # Verifies that apply-rulesets.sh actually sends dismiss_stale_reviews_on_push in
  # the request body — not just that the field exists in the checked-in JSON. If the
  # script ever strips or transforms the payload before sending, this test catches it.
  _stub_gh
  export RULESETS_LIST='[]'
  run bash "$APPLY" --repo petry-projects/acme pr-quality
  [ "$status" -eq 0 ]
  jq -e '
    any(.rules[]?;
      .type == "pull_request" and
      .parameters.dismiss_stale_reviews_on_push == true)
  ' < <(tail -n +2 "$CALLS") >/dev/null
}

# ── target resolution: bare name (back-compat) + name filter ──────────────────
@test "apply: a bare <repo-name> resolves to \$ORG/<name>" {
  _stub_gh
  export RULESETS_LIST='[]'
  run bash "$APPLY" acme --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo=petry-projects/acme"* ]]
}

@test "apply: a name filter applies only that ruleset" {
  _stub_gh
  export RULESETS_LIST='[]'
  run bash "$APPLY" --repo petry-projects/acme code-quality --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"code-quality"* ]]
  [[ "$output" != *"pr-quality"* ]]
  [[ "$output" == *"done (1 ruleset(s))"* ]]
}

@test "apply: default set is the fleet allowlist only — release-channel-tags is NOT swept in" {
  _stub_gh
  export RULESETS_LIST='[]'
  run bash "$APPLY" --repo petry-projects/acme
  [ "$status" -eq 0 ]
  # code-quality + pr-quality applied; release-channel-tags excluded despite being in the dir.
  [[ "$output" == *"done (2 ruleset(s))"* ]]
  [[ "$output" != *"release-channel-tags"* ]]
}

@test "apply: release-channel-tags applies only when named explicitly" {
  _stub_gh
  export RULESETS_LIST='[]'
  run bash "$APPLY" --repo petry-projects/.github release-channel-tags --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"release-channel-tags"* ]]
  [[ "$output" == *"done (1 ruleset(s))"* ]]
}

@test "apply: unknown ruleset name errors" {
  _stub_gh
  run bash "$APPLY" --repo petry-projects/acme no-such-ruleset
  [ "$status" -ne 0 ]
  [[ "$output" == *"no ruleset file no-such-ruleset.json"* ]]
}

# ── fleet mode ────────────────────────────────────────────────────────────────
@test "apply --all: iterates every non-archived org repo" {
  _stub_gh
  export RULESETS_LIST='[]' REPO_LIST=$'alpha\nbeta'
  run bash "$APPLY" --all --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo=petry-projects/alpha"* ]]
  [[ "$output" == *"repo=petry-projects/beta"* ]]
  [[ "$output" == *"across the fleet"* ]]
}

@test "apply: --all and --repo are mutually exclusive" {
  _stub_gh
  run bash "$APPLY" --all --repo petry-projects/acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "apply: a bare token after --all is a ruleset-name filter (unknown → errors)" {
  _stub_gh
  export REPO_LIST=$'alpha'
  run bash "$APPLY" --all not-a-ruleset --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"no ruleset file not-a-ruleset.json"* ]]
}

# ── sourced helpers ───────────────────────────────────────────────────────────
@test "ruleset_id_by_name: resolves id from the list" {
  _stub_gh
  export RULESETS_LIST='[{"id":42,"name":"pr-quality"},{"id":7,"name":"code-quality"}]'
  run bash -c "source '$APPLY' && ruleset_id_by_name petry-projects/acme code-quality"
  [ "$status" -eq 0 ]; [ "$output" = "7" ]
}
