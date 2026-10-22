#!/usr/bin/env bats
# Tests for .github/scripts/pr-auto-review/lib/ready-check.sh
#
# Pins issue #680: the pr-auto-review ready-check must gate auto-dispatch on the
# branch's REQUIRED status-check contexts only. Non-required and cancelled
# advisory contexts (e.g. a superseded `dev-lead / ci-relay` run) must not block
# dispatch, while a failing/pending/missing REQUIRED check still does.

load 'helpers/setup'

setup() {
  # shellcheck source=/dev/null
  . "${TT_SCRIPTS_DIR}/lib/ready-check.sh"
}

# ── pr_auto_review_required_contexts ─────────────────────────────────────────

@test "required_contexts: extracts contexts from a required_status_checks rule" {
  run pr_auto_review_required_contexts <<'JSON'
[
  {"type":"pull_request"},
  {"type":"required_status_checks","parameters":{"required_status_checks":[
    {"context":"Lint","integration_id":15368},
    {"context":"SonarCloud Code Analysis"}
  ]}}
]
JSON
  [ "$status" -eq 0 ]
  [ "$output" = '["Lint","SonarCloud Code Analysis"]' ]
}

@test "required_contexts: no required_status_checks rule → empty array" {
  run pr_auto_review_required_contexts <<'JSON'
[{"type":"pull_request"},{"type":"non_fast_forward"}]
JSON
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "required_contexts: rule with missing/null parameters or non-string contexts → empty array" {
  run pr_auto_review_required_contexts <<'JSON'
[
  {"type":"required_status_checks"},
  {"type":"required_status_checks","parameters":null},
  {"type":"required_status_checks","parameters":{"required_status_checks":[
    {"context":null},
    {"context":123}
  ]}}
]
JSON
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "required_contexts: empty rules array → empty array" {
  run pr_auto_review_required_contexts <<<'[]'
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "required_contexts: non-array API error body → empty array" {
  run pr_auto_review_required_contexts <<<'{"message":"Not Found"}'
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

# ── pr_auto_review_checks_ready: the #680 repro ──────────────────────────────

@test "ready: all required green, a CANCELLED non-required advisory present → ready" {
  run pr_auto_review_checks_ready '["Lint","ShellCheck","SonarCloud Code Analysis"]' "" <<'JSON'
[
  {"name":"CI / Lint","bucket":"pass"},
  {"name":"CI / ShellCheck","bucket":"pass"},
  {"name":"SonarCloud Code Analysis","bucket":"pass"},
  {"name":"dev-lead / ci-relay","bucket":"cancel"},
  {"name":"dev-lead / dispatch","bucket":"cancel"}
]
JSON
  [ "$status" -eq 0 ]
}

@test "ready: non-required FAILING advisory does not block" {
  run pr_auto_review_checks_ready '["Lint"]' "" <<'JSON'
[
  {"name":"CI / Lint","bucket":"pass"},
  {"name":"some-advisory","bucket":"fail"}
]
JSON
  [ "$status" -eq 0 ]
}

# ── pr_auto_review_checks_ready: required check still gates ───────────────────

@test "not ready: a required check is failing" {
  run pr_auto_review_checks_ready '["Lint","ShellCheck"]' "" <<'JSON'
[
  {"name":"CI / Lint","bucket":"fail"},
  {"name":"CI / ShellCheck","bucket":"pass"}
]
JSON
  [ "$status" -eq 1 ]
}

@test "not ready: a required check is pending" {
  run pr_auto_review_checks_ready '["Lint","ShellCheck"]' "" <<'JSON'
[
  {"name":"CI / Lint","bucket":"pending"},
  {"name":"CI / ShellCheck","bucket":"pass"}
]
JSON
  [ "$status" -eq 1 ]
}

@test "not ready: a required check is cancelled" {
  run pr_auto_review_checks_ready '["Lint"]' "" <<'JSON'
[
  {"name":"CI / Lint","bucket":"cancel"}
]
JSON
  [ "$status" -eq 1 ]
}

@test "not ready: a required context has no check run reported yet" {
  run pr_auto_review_checks_ready '["Lint","ShellCheck"]' "" <<'JSON'
[
  {"name":"CI / Lint","bucket":"pass"}
]
JSON
  [ "$status" -eq 1 ]
}

@test "ready: a required check that is skipping counts as satisfied" {
  run pr_auto_review_checks_ready '["Lint"]' "" <<'JSON'
[
  {"name":"CI / Lint","bucket":"skipping"}
]
JSON
  [ "$status" -eq 0 ]
}

# ── name matching (bare status context vs "workflow / job") ───────────────────

@test "ready: bare required context matches an exact status check name" {
  run pr_auto_review_checks_ready '["SonarCloud Code Analysis"]' "" <<'JSON'
[{"name":"SonarCloud Code Analysis","bucket":"pass"}]
JSON
  [ "$status" -eq 0 ]
}

@test "ready: bare required job name matches a 'workflow / job' check name" {
  run pr_auto_review_checks_ready '["Agent Security Scan"]' "" <<'JSON'
[{"name":"CI / Agent Security Scan","bucket":"pass"}]
JSON
  [ "$status" -eq 0 ]
}

# ── self-check exclusion ─────────────────────────────────────────────────────

@test "ready: this workflow's own pending check is excluded via SELF_NAME" {
  run pr_auto_review_checks_ready '[]' "PR Auto-Review — Ready Check" <<'JSON'
[
  {"name":"CI / Lint","bucket":"pass"},
  {"name":"PR Auto-Review — Ready Check","bucket":"pending"}
]
JSON
  [ "$status" -eq 0 ]
}

# ── fallback (no required set) — option B semantics ───────────────────────────

@test "fallback: no required set, only cancel/skipping/pass non-self checks → ready" {
  run pr_auto_review_checks_ready '[]' "" <<'JSON'
[
  {"name":"CI / Lint","bucket":"pass"},
  {"name":"dev-lead / ci-relay","bucket":"cancel"},
  {"name":"some-skipped","bucket":"skipping"}
]
JSON
  [ "$status" -eq 0 ]
}

@test "fallback: no required set, a FAILING check → not ready" {
  run pr_auto_review_checks_ready '[]' "" <<'JSON'
[
  {"name":"CI / Lint","bucket":"pass"},
  {"name":"CI / ShellCheck","bucket":"fail"}
]
JSON
  [ "$status" -eq 1 ]
}

@test "fallback: no required set, a PENDING check → not ready" {
  run pr_auto_review_checks_ready '[]' "" <<'JSON'
[
  {"name":"CI / Lint","bucket":"pending"}
]
JSON
  [ "$status" -eq 1 ]
}
