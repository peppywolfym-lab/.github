# Push Protection Standard

Standard for preventing secrets, API keys, credentials, and other sensitive
values from being accidentally committed or pushed to any repository in the
**petry-projects** organization.

This standard is **defense in depth**: local hooks catch most leaks before a
commit lands, GitHub push protection blocks the push at the network boundary,
and CI scanning + secret scanning alerts catch anything that slips past the
first two layers. Any one layer failing is a warning; two layers failing is an
incident.

---

## Scope

This standard applies to **every repository** in `petry-projects`, regardless
of visibility (public or private) or language. It covers:

- Source code, configuration files, and fixtures
- Workflow files (`.github/workflows/*.yml`) and reusable workflows
- Agent configuration (`CLAUDE.md`, `AGENTS.md`, `SKILL.md`, MCP configs)
- Documentation, issue/PR templates, and discussion posts
- Binary artifacts, screenshots, log files, and notebooks checked into git

> **Private repos are in scope.** GitHub secret scanning is now free for
> private repos on the free plan, and a leaked credential in a private repo is
> still a credential that must be rotated.

---

## What Counts as a Secret

The following values MUST NEVER be committed to any repo, even temporarily, and
even in a branch that will be rebased or force-pushed:

| Category | Examples |
|----------|----------|
| **Cloud provider credentials** | AWS access key / secret, GCP service account JSON, Azure connection string |
| **API tokens** | GitHub PAT / fine-grained token, SonarCloud token, Anthropic API key, OpenAI API key, Slack webhook / bot token, Stripe key |
| **Database credentials** | Postgres / MySQL / Mongo connection strings containing passwords, Redis AUTH strings |
| **Private keys** | SSH private keys, TLS private keys, GPG private keys, GitHub App private keys |
| **OAuth secrets** | Client secrets, refresh tokens, long-lived access tokens |
| **Signing keys** | Code signing certificates, Sigstore identities, npm publish tokens |
| **Internal URLs & identifiers** | Unpublished webhook URLs, internal hostnames, customer IDs, account IDs when not already public |
| **Personal data** | Real email addresses, phone numbers, or names in fixtures that are not explicitly test data |

Low-entropy placeholder values (`sk-xxxx`, `AKIA...EXAMPLE`, `changeme`) are
permitted in documentation and tests **only when** they are obviously not real
(e.g., repeated characters, `EXAMPLE` suffix, or documented as placeholder).
When in doubt, use the GitHub-documented [dummy values](https://docs.github.com/en/code-security/secret-scanning/introduction/supported-secret-scanning-patterns).

---

## Layer 1 — GitHub Push Protection (Primary Enforcement)

GitHub's native [secret scanning push protection](https://docs.github.com/en/code-security/secret-scanning/push-protection-for-repositories-and-organizations)
is the **primary enforcement mechanism**. It blocks pushes that contain
detected secrets at the server side, before the commit is accepted, so nothing
ever lands in the repo history in the first place.

### Required org-level settings

Configured once at the organization level and inherited by all repos:

| Setting | Value | Notes |
|---------|-------|-------|
| **Secret scanning** | **Enabled for all repos** | Public and private |
| **Push protection** | **Enabled for all repos** | Blocks pushes containing known secret patterns |
| **Push protection for contributors** | **Enabled** | Applies to forks and contributions |
| **Validity checks** | **Enabled** | Verifies leaked tokens against the provider so rotation can be prioritized |
| **Non-provider patterns** | **Enabled** | Adds generic patterns (private keys, HTTP basic auth, high-entropy strings) |
| **Custom patterns** | **Enabled (see below)** | Org-specific patterns live under Settings → Code security → Secret scanning |
| **Bypass privileges** | **Admin-only, with justification required** | Bypasses MUST include a reason and are audited |

Apply these via:

```bash
# Org-level (requires org admin)
gh api -X PATCH "orgs/petry-projects" \
  -f secret_scanning_enabled_for_new_repositories=true \
  -f secret_scanning_push_protection_enabled_for_new_repositories=true \
  -f secret_scanning_push_protection_custom_link_enabled=true \
  -f secret_scanning_push_protection_custom_link="https://github.com/petry-projects/.github/blob/main/standards/push-protection.md#what-to-do-when-push-protection-blocks-your-push"
```

### Required repo-level settings

Every repository MUST have the following security features turned on. The
compliance audit checks these flags via `GET /repos/{owner}/{repo}`:

| Setting | Path in API response | Required value |
|---------|----------------------|----------------|
| Secret scanning | `security_and_analysis.secret_scanning.status` | `enabled` |
| Secret scanning push protection | `security_and_analysis.secret_scanning_push_protection.status` | `enabled` |
| Secret scanning AI detection | `security_and_analysis.secret_scanning_ai_detection.status` | `enabled` |
| Secret scanning non-provider patterns | `security_and_analysis.secret_scanning_non_provider_patterns.status` | `enabled` |
| Dependabot security updates | `security_and_analysis.dependabot_security_updates.status` | `enabled` |

Apply per repo via:

```bash
gh api -X PATCH "repos/petry-projects/<repo>" --input - <<'JSON'
{
  "security_and_analysis": {
    "secret_scanning": {"status": "enabled"},
    "secret_scanning_push_protection": {"status": "enabled"},
    "secret_scanning_ai_detection": {"status": "enabled"},
    "secret_scanning_non_provider_patterns": {"status": "enabled"},
    "dependabot_security_updates": {"status": "enabled"}
  }
}
JSON
```

`scripts/apply-repo-settings.sh` MUST enforce these values alongside the
existing merge and label settings — it sources
[`scripts/lib/push-protection.sh`](../scripts/lib/push-protection.sh) and
calls `pp_apply_security_and_analysis` after the standard settings and
labels have been applied. The required `security_and_analysis` keys live
in the `PP_REQUIRED_SA_SETTINGS` array in that library — adding a new
required flag there automatically extends both the apply script and the
weekly audit. See [Application](#application-to-a-repository) below.

### Custom secret scanning patterns

The org MUST configure the following custom patterns in addition to the
provider-supplied ones:

| Pattern name | Pattern (illustrative) | Rationale |
|--------------|------------------------|-----------|
| `petry-internal-webhook` | `https://hooks\.petry-projects\.internal/[A-Za-z0-9/_-]{20,}` | Internal webhook URLs |
| `claude-oauth-token` | `sk-ant-oat01-[A-Za-z0-9_-]{40,}` | Anthropic OAuth tokens |
| `gha-pat-scoped` | `github_pat_[A-Za-z0-9_]{82}` | Fine-grained GitHub PATs (provider pattern supplements) |
| `generic-high-entropy` | `(?:_TOKEN\|_SECRET\|_KEY)\s*[:=]\s*["']?[A-Za-z0-9/+=_-]{32,}` | Catches untyped long strings in YAML and `.env` files |

Custom patterns are configured at **Org settings → Code security → Secret
scanning → Custom patterns**. Each new pattern MUST be dry-run against all
repos before being enabled to estimate false-positive rate.

---

## Layer 2 — Local Pre-Commit Prevention

Local prevention catches leaks before they ever reach GitHub, which is both
faster for the developer and leaves no evidence in any remote history. Every
developer workstation and every Claude Code / agent environment SHOULD run
`gitleaks` (or an equivalent) as a pre-commit hook.

### Recommended local tooling

| Tool | Purpose | How it runs |
|------|---------|-------------|
| [`gitleaks`](https://github.com/gitleaks/gitleaks) | Fast, regex + entropy secret scanner | Pre-commit hook + CI |
| [`pre-commit`](https://pre-commit.com/) | Hook orchestrator | Manages the hook lifecycle |
| [`git-secrets`](https://github.com/awslabs/git-secrets) | AWS-focused secret scanner | Optional supplement |

### Standard `.pre-commit-config.yaml` entry

Repositories that adopt pre-commit SHOULD add this block:

```yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.24.0
    hooks:
      - id: gitleaks
        name: gitleaks (secret scan)
        description: Detect hardcoded secrets before commit
```

Install locally with:

```bash
pip install pre-commit
pre-commit install
pre-commit run gitleaks --all-files   # one-off scan of tracked files in the working tree
# For a full git-history scan, use gitleaks directly:
gitleaks git --redact --exit-code 1
```

> **Note:** `pre-commit run --all-files` only scans the current working tree,
> not the full git history. Use `gitleaks git` (or `gitleaks detect
> --log-opts="--all"` on older versions) to scan every commit reachable from
> every branch.

### Agent workstation requirements

Claude Code and other AI agents operating on petry-projects repos MUST:

- Refuse to write real credentials to any file, even when asked. Use
  placeholder values (`<YOUR_TOKEN_HERE>`) in documentation and instruct the
  user to source the value from an environment variable or secrets manager.
- Refuse to commit files containing strings that look like secrets, even when
  explicitly instructed. Ask the user to confirm and route the value through a
  secure store instead.
- When generating `.env.example` files, include key names only — never values.

---

## Layer 3 — CI Secret Scanning (Secondary Defense)

CI scanning is the last line of defense for code that has already made it into
a branch (e.g., historical commits, imported repositories, or pushes from
accounts with bypass privileges).

### Required CI job

Every repository's primary `ci.yml` workflow MUST include a `secret-scan` job
that runs `gitleaks` in full-history mode on every pull request and on every
push to `main`.

```yaml
secret-scan:
  name: Secret scan (gitleaks)
  runs-on: ubuntu-latest
  permissions:
    contents: read
  steps:
    - name: Checkout (full history)
      # Pin to SHA per Action Pinning Policy (ci-standards.md#action-pinning-policy).
      # Look up current SHA: gh api repos/actions/checkout/git/refs/tags/v4 --jq '.object.sha'
      uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
      with:
        fetch-depth: 0

    - name: Install gitleaks
      env:
        GITLEAKS_VERSION: "8.30.1"
        # Named GITLEAKS_CHECKSUM (not GITLEAKS_SHA256) — SonarCloud flags env var names
        # matching *SHA256* containing hex strings as Security Hotspots (false positive).
        GITLEAKS_CHECKSUM: "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"
      run: |
        tarball="gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
        url="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${tarball}"
        wget -q "${url}" -O /tmp/gitleaks.tar.gz
        echo "${GITLEAKS_CHECKSUM}  /tmp/gitleaks.tar.gz" | sha256sum -c
        tar -xzf /tmp/gitleaks.tar.gz -C /usr/local/bin gitleaks

    - name: Run gitleaks
      run: gitleaks detect --source . --config .gitleaks.toml --redact --verbose --exit-code 1
```

> **Why CLI instead of `gitleaks/gitleaks-action`?** The action's v2 release
> requires a paid license for GitHub organization repos. The CLI (installed via
> a direct binary download with SHA256 verification) is free, fully pinned, and
> runs the same scan. If you have a license, you can use the action instead —
> add `GITLEAKS_LICENSE: ${{ secrets.GITLEAKS_LICENSE }}` to the `env:` block
> alongside `GITHUB_TOKEN`.

The job MUST:

- Use `fetch-depth: 0` so the full git history is scanned, not just the
  PR diff
- Pass `--redact` so leaked values are NEVER written to workflow logs
- Fail the build (`--exit-code 1`) when any finding is detected
- Pass `--config .gitleaks.toml` — every adopting repo MUST ship a
  `.gitleaks.toml` at root (see [`.gitleaks.toml` template](#gitleakstoml-template) below)
- Use `GITLEAKS_CHECKSUM` (not `GITLEAKS_SHA256`) for the binary checksum env var —
  SonarCloud's security gate flags env vars matching `*SHA256*` that contain hex
  strings as Security Hotspots (hardcoded credential false positive)
- Run as a **required check** via the `code-quality` ruleset
  (see [`github-settings.md`](github-settings.md#code-quality--required-checks-ruleset-all-repositories))

### `.gitleaks.toml` template

Every repository adopting the `secret-scan` job MUST ship a `.gitleaks.toml`
at root. Without it, `--config .gitleaks.toml` fails with a file-not-found
error. Copy [`standards/gitleaks.toml`](gitleaks.toml) as your starting point
and extend the `paths` allowlist for any repo-specific false-positive paths.

**Why a required config file?** The `generic-api-key` rule in gitleaks fires on
BMAD knowledge file paths (e.g. `api-request.md`, `auth-session.md` inside
`_bmad/` directories) because their names contain substrings gitleaks treats as
API-key indicators. The allowlist suppresses these false positives without
disabling the rule org-wide.

```toml
title = "gitleaks config"

# Add repo-specific allowlists below.
# Common false-positive paths:
#   '''_bmad/'''  — BMAD knowledge/config files (not application secrets)
[allowlist]
description = "Allowlisted paths"
paths = [
  '''_bmad/''',
]
```

### Coordination with AgentShield

For agent-configuration files specifically, [`agent-shield.yml`](workflows/agent-shield.yml)
already runs 10 dedicated secret-detection rules across 14 patterns (see
[`agent-standards.md`](agent-standards.md#layer-1-agentshield-action-deep-security-scan)).
The `secret-scan` CI job is complementary — it covers non-agent files and
runs a broader entropy-based scan over the full history. Both MUST be green
for a PR to merge.

---

## Developer Practices

### Handling real secrets

- Real credentials live in the [GitHub Actions secret store](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions),
  in the developer's local `.env` files (gitignored), or in a dedicated secrets
  manager. They never live in source files, documentation, or chat history.
- The standard org-level secrets (`APP_ID`, `APP_PRIVATE_KEY`,
  `CLAUDE_CODE_OAUTH_TOKEN`, `SONAR_TOKEN`) are documented in
  [`github-settings.md`](github-settings.md#organization-level-secrets-for-standard-ci).
  Reference them via `${{ secrets.<NAME> }}` in workflows.
- When a workflow needs a new secret, add it to the org-level store (if it is
  reusable) or the repo-level store (if it is project-specific). Document the
  purpose in the repo's `README.md` or `CONTRIBUTING.md`.

### Required gitignore entries

The `.gitignore` secrets baseline is codified in its own standard. See
[`gitignore-standard.md`](gitignore-standard.md) for the two-layer (L1
secrets baseline / L2 per-repo) model, the managed-block markers, the
negation-discipline rules, and the `gitignore_baseline` compliance check.

### Writing tests and fixtures

- Use the dummy values listed in the [GitHub secret patterns documentation](https://docs.github.com/en/code-security/secret-scanning/introduction/supported-secret-scanning-patterns)
  for test fixtures. These are whitelisted by GitHub push protection.
- Generate ephemeral test keys at runtime where possible (e.g., a freshly
  created RSA keypair inside a `beforeAll` hook) rather than committing a
  fixed test key.
- If a fixture MUST contain a realistic-looking value, prefix the filename
  with `fixture-` and add a `.gitleaksignore` entry documenting the
  justification.

### Working in a branch that may contain a leaked secret

If you suspect you have committed a secret locally but not yet pushed:

1. **Stop.** Do not push.
2. Run `git log -p -- <file>` to find the commit(s) containing the secret.
3. If the secret is only in uncommitted working tree: remove it and
   `git restore --staged <file>`.
4. If the secret is in local commits not yet pushed: rewrite history with
   `git rebase -i <base>` and amend the offending commit(s) to remove it.
5. Rotate the credential anyway — assume any value you typed into a terminal
   has been logged somewhere.

If you have already pushed:

1. **Rotate the credential immediately** — assume it is compromised.
2. Follow the [Incident Response](#incident-response) procedure below.
3. Do NOT attempt to rewrite remote history as a first response — the value
   is already in forks, caches, and CI logs. Rotation is faster and safer.

---

## What to Do When Push Protection Blocks Your Push

When `git push` fails with a push protection error, GitHub returns a URL
pointing to the blocked secret. The correct response is:

1. **Do not bypass.** Bypassing push protection is an admin-only action,
   requires a written justification, and is audited org-wide.
2. **Identify whether the value is a real secret or a false positive.**
   - **Real secret:** remove it from the commit (see the rewrite procedure
     above), rotate the credential, and force-push the rewritten branch. Open
     an incident issue per the [Incident Response](#incident-response)
     procedure.
   - **False positive:** confirm with the org security owner, then add a
     `.gitleaksignore` entry (for CI) and request a push protection bypass
     with a `used_in_tests` or `false_positive` reason.
3. **Never** commit a modified version of the secret (e.g., adding a space,
   splitting across lines, base64-encoding) to work around detection. This
   is treated as the same severity as committing the original value.

---

## Incident Response

When a secret is confirmed leaked — whether caught by push protection bypass,
CI scanning, a secret scanning alert, or an external report — follow this
procedure:

| Step | Action | Owner | Target |
|------|--------|-------|--------|
| 1 | **Rotate the credential** in the upstream provider (AWS, GitHub, Anthropic, etc.) | First responder | Immediately |
| 2 | **Revoke any derived tokens** (OAuth grants, downstream integrations) | First responder | Immediately |
| 3 | **Open a private security advisory** in the affected repo | First responder | Within 1 hour |
| 4 | **Audit access logs** for the credential to determine blast radius | Org admin | Within 24 hours |
| 5 | **Remove the secret from history** if appropriate (BFG, `git filter-repo`), recognizing that forks and caches may retain copies | Org admin | Within 24 hours, only after rotation |
| 6 | **Post-mortem** — document root cause, why existing layers did not catch it, and what changes prevent recurrence | Org admin | Within 7 days |
| 7 | **Update this standard** with any new patterns or lessons learned | Standards owner | Within 7 days |

Rotation ALWAYS comes first. History rewriting is a cleanup step, not a
mitigation.

---

## Application to a Repository

When onboarding a repository to this standard:

1. **Enable secret scanning + push protection** via the API call in
   [Required repo-level settings](#required-repo-level-settings). `scripts/apply-repo-settings.sh`
   enforces this on every run.
2. **Verify gitignore** contains the standard entries listed in
   [Required gitignore entries](#required-gitignore-entries).
3. **Add the `secret-scan` job** to `ci.yml` per [Layer 3](#layer-3--ci-secret-scanning-secondary-defense).
4. **Add `secret-scan` as a required check** in the `code-quality` ruleset —
   add the `Secret scan (gitleaks)` context to the codified
   [`standards/rulesets/code-quality.json`](rulesets/code-quality.json), then
   re-apply org-wide with `scripts/apply-rulesets.sh`. Do this **only after** the
   fleet backfill (every repo must produce the check first — see #581), and update
   [`github-settings.md`](github-settings.md#code-quality--required-checks-ruleset-all-repositories)
   to move the row from staged to required.
5. **Scan existing history** one time with `gitleaks git --redact --exit-code 1`
   before enabling enforcement, to surface any pre-existing secrets across all
   commits (not just the current working tree).
6. **Rotate anything found** during the initial scan — do not whitelist
   existing findings without rotation.

---

## Compliance Audit Checks

The weekly compliance audit
([`scripts/compliance-audit.sh`](../scripts/compliance-audit.sh)) verifies the
following for every repository. The check logic lives in
[`scripts/lib/push-protection.sh`](../scripts/lib/push-protection.sh) and is
sourced by both the audit and the apply script so a single edit to
`PP_REQUIRED_SA_SETTINGS` (or the gitignore baseline list) propagates to
both at once:

| Check | Severity | Detail |
|-------|----------|--------|
| `secret_scanning_enabled` | error | `security_and_analysis.secret_scanning.status == "enabled"` |
| `push_protection_enabled` | error | `security_and_analysis.secret_scanning_push_protection.status == "enabled"` |
| `ai_detection_enabled` | warning | `security_and_analysis.secret_scanning_ai_detection.status == "enabled"` |
| `non_provider_patterns_enabled` | warning | `security_and_analysis.secret_scanning_non_provider_patterns.status == "enabled"` |
| `dependabot_security_updates_enabled` | warning | `security_and_analysis.dependabot_security_updates.status == "enabled"` |
| `open_secret_alerts` | error | `GET /repos/{owner}/{repo}/secret-scanning/alerts?state=open` returns an empty array |
| `secret_scan_ci_job_present` | error | `.github/workflows/ci.yml` contains a job using `gitleaks/gitleaks-action` |
| `gitignore_baseline` | error | `.gitignore` secrets-baseline marker block matches the org canonical block (SHA-256) |
| `push_protection_bypasses_recent` | warning | No bypasses in the last 30 days without a documented justification |

Findings are reported as GitHub Issues labeled `security` + `compliance-audit`
per the existing audit flow.

### Token scope requirement

The `security_and_analysis` field in `GET /repos/{owner}/{repo}` is only
populated when the requesting token has **admin access** to the repository or
the **`security_events` OAuth scope**. When the audit token (`ORG_SCORECARD_TOKEN`)
lacks these, the check falls back to a proxy verification:

1. If `GET /repos/{owner}/{repo}/secret-scanning/alerts` returns a valid array,
   secret scanning is confirmed active and the finding is downgraded to
   `security_and_analysis_unverifiable` (warning) — the specific settings
   (push protection, AI detection, etc.) cannot be individually confirmed.
2. If the alerts endpoint also fails, `security_and_analysis_unavailable`
   (warning) is reported.

**To enable audit verification:** regenerate the classic PAT backing
`ORG_SCORECARD_TOKEN` (Developer Settings → Personal access tokens) with the
`security_events` scope, then update the stored value in org Settings →
Secrets → Actions. **To enforce required settings:** run
`scripts/apply-repo-settings.sh <repo>` with a repository-admin token.
Note: running the apply script configures settings but does not grant the
audit token the visibility it needs — both steps may be needed.

---

## Related Standards

- [`gitignore-standard.md`](gitignore-standard.md) — the secrets-baseline `.gitignore` (L1/L2 model, managed-block markers, negation rules) that is this program's first layer
- [`advanced-security.md`](advanced-security.md) — org-wide GHAS enablement (the code security configuration that turns push protection on), licensing model, and push-protection live-fire verification
- [`github-settings.md`](github-settings.md) — repo settings, rulesets, org secrets
- [`agent-standards.md`](agent-standards.md) — AgentShield scanner and agent-config hygiene
- [`ci-standards.md`](ci-standards.md) — workflow templates and required checks
- [`dependabot-policy.md`](dependabot-policy.md) — dependency vulnerability updates
