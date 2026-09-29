# petry-projects/.github

Organization-wide GitHub configuration and workflows for the `petry-projects` org.

## Contents

| Path | Purpose |
|------|---------|
| [`profile/`](profile/) | Public org profile page shown on the org's GitHub landing |
| [`standards/`](standards/) | Engineering standards and policy documents |
| [`standards/workflows/`](standards/workflows/) | Reusable CI workflow templates called by org repositories |

## Engineering Standards

The `standards/` directory contains the authoritative policy documents for this org.

| Standard | Topic | Key topics |
|----------|-------|------------|
| [`advanced-security`](standards/advanced-security.md) | GitHub Advanced Security configuration | Code Security Configurations, push-protection live-fire test (canary), licensing & billing, verification, compliance audit checks |
| [`agent-rate-limits`](standards/agent-rate-limits.md) | Agent token-budget and rate-limit policy | What is limited, token-budget breaker, daily budget as per-agent cost bound, exempt actors, operator runbook |
| [`agent-standards`](standards/agent-standards.md) | Copilot and agentic workflow standards | Required files, agent configuration security, AgentShield CI workflow, Decision-Making Reusables, BMAD Method Workflows |
| [`ci-standards`](standards/ci-standards.md) | CI pipeline conventions and enforcement | Staged promotion through concentric rings, reusable workflow versioning (`stable` channel), action pinning policy, permissions policy, required workflows |
| [`codeowners-standard`](standards/codeowners-standard.md) | CODEOWNERS file policy | Rule, team composition, required setup for new bots, branch protection |
| [`copilot-instructions-standard`](standards/copilot-instructions-standard.md) | Copilot instructions file conventions | Canonical instruction files, adding a new language, content quality rules, compliance |
| [`dependabot-policy`](standards/dependabot-policy.md) | Dependabot configuration and auto-merge rules | Policy, configuration files, auto-merge workflow, CODEOWNERS approval timing, vulnerability audit CI check |
| [`feature-ideation-sources`](standards/feature-ideation-sources.md) | Sources and process for feature ideation | AI/ML vendor & lab sources, developer tooling changelogs, security & compliance, newsletters, podcasts |
| [`github-settings`](standards/github-settings.md) | Repository settings policy | Repository rulesets, organization-level secrets, GitHub Apps & integrations, labels — standard set, compliance audit process |
| [`gitignore-standard`](standards/gitignore-standard.md) | gitignore policy and org-managed baseline (covering secrets, agent worktrees, and CI artifacts) | Two-Layer Model, L1 baseline (verbatim, required), managed-block markers, negation discipline, compliance check |
| [`initiatives-project`](standards/initiatives-project.md) | GitHub Projects board conventions | What belongs on the board, fields, Theme → Initiative, how the auto-add works, views |
| [`persona-standards`](standards/persona-standards.md) | Agent and persona definition standards | The trigger matrix, canary onboarding, trust & permissions, definition layers, Definition of Done |
| [`pr-limits`](standards/pr-limits.md) | Pull request size and scope limits | What is limited, exempt actors, reconciliation with Dependabot cap, operator runbook |
| [`push-protection`](standards/push-protection.md) | Secret push protection configuration | Layer 1 — GitHub Push Protection, Layer 2 — local pre-commit prevention, Layer 3 — CI secret scanning, incident response, compliance audit checks |
| [`ruleset-remediation-runbook`](standards/ruleset-remediation-runbook.md) | Runbook for resolving ruleset violations | Snapshot (rollback insurance), bypass actors, legacy ruleset migration, verify, 2026-06-10 fleet remediation |
| [`standards-versioning`](standards/standards-versioning.md) | Standards artifact versioning and release process | The two tag forms, cutting a release, N-1 resolvability, who/what moves it, opting in and staying out |

## Reporting & Dashboards

Scheduled workflows in this repo post audit reports and status digests as issues or run summaries for maintainers.

| Workflow | Purpose |
|----------|---------|
| [`compliance-audit-and-improvement.yml`](https://github.com/petry-projects/.github/blob/main/.github/workflows/compliance-audit-and-improvement.yml) | Weekly org standards compliance audit + runtime health survey, with per-finding remediation issues |
| [`daily-org-status.yml`](https://github.com/petry-projects/.github/blob/main/.github/workflows/daily-org-status.yml) | Daily "Org Status" digest posted as an issue for maintainers |
| [`org-scorecard.yml`](https://github.com/petry-projects/.github/blob/main/.github/workflows/org-scorecard.yml) | Weekly OpenSSF Scorecard security-posture review across public repos; findings tracked as issues |
| [`standards-deploy.yml`](https://github.com/petry-projects/.github/blob/main/.github/workflows/standards-deploy.yml) | Weekly fleet sweep that opens standards-sync PRs for repos drifted off the org-standard workflow stubs |

## Related# petry-projects/.github

Organization-wide GitHub configuration and workflows for the `petry-projects` org.

## Contents

| Path | Purpose |
| ------ | ------- |
| [`profile/`](profile/) | Public org profile page shown on the org's GitHub landing page |
| [`standards/`](standards/) | Engineering standards and policy documents |
| [`standards/workflows/`](standards/workflows/) | Reusable CI workflow templates called by org repositories |

## Engineering Standards

The `standards/` directory contains the authoritative policy documents for this org.

| Standard | Topic | Key topics |
| -------- | ----- | ---------- |
| [`advanced-security`](standards/advanced-security.md) | GitHub Advanced Security configuration | Code Security Configurations, push-protection live-fire test (canary), licensing & billing, verification, compliance audit checks |
| [`agent-rate-limits`](standards/agent-rate-limits.md) | Agent token-budget and rate-limit policy | What is limited, token-budget breaker, daily budget as per-agent cost bound, exempt actors, operator runbook |
| [`agent-standards`](standards/agent-standards.md) | Copilot and agentic workflow standards | Required files, agent configuration security, AgentShield CI workflow, Decision-Making Reusables, RMAD |


The companion repository [`petry-projects/.github-private`](https://github.com/petry-projects/.github-private) holds private automation:
Copilot custom agents, agentic workflow scripts, installed frameworks, and scheduled CI.
