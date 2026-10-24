# yasirbm-projects/.github

Organization-wide GitHub configuration, governance standards, and workflows maintained by **Yasir Bin Mudassir** (`peppywolf.ym@gmail.com`).

---

## Contents

| Path | Purpose |
|------|---------|
| [`profile/`](profile/) | Public org profile page shown on the organization's GitHub landing |
| [`standards/`](standards/) | Engineering standards, security guidelines, and governance policy documents |
| [`standards/workflows/`](standards/workflows/) | Reusable CI/CD workflow templates consumed across organization repositories |

---

## Engineering Standards

The `standards/` directory contains the authoritative architecture and security policies for this organization.

| Standard | Topic | Key Topics |
|----------|-------|------------|
| [`advanced-security`](standards/advanced-security.md) | GitHub Advanced Security configuration | Code Security Configurations, secret push-protection canary tests, licensing, compliance audits |
| [`agent-rate-limits`](standards/agent-rate-limits.md) | Agent token-budget & rate-limit policy | Consumption caps, circuit breakers, daily per-agent cost boundaries, exempt actors, operator runbooks |
| [`agent-standards`](standards/agent-standards.md) | AI agents & copilot workflow standards | Configuration security, runtime validation workflows, decision-making reusables, BMAD methodology |
| [`ci-standards`](standards/ci-standards.md) | CI pipeline conventions and enforcement | Concentric ring promotion, reusable workflow versioning (`stable` track), SHA action pinning, least-privilege tokens |
| [`codeowners-standard`](standards/codeowners-standard.md) | CODEOWNERS policy | Approval rules, team definitions, automated bot governance, protected branch requirements |
| [`copilot-instructions-standard`](standards/copilot-instructions-standard.md) | AI coding instructions conventions | Canonical instruction sets, multi-language guidelines, context injection hygiene, compliance checks |
| [`dependabot-policy`](standards/dependabot-policy.md) | Dependency automation & auto-merge | Dependency review configurations, auto-merge criteria, approval timing, vulnerability triage |
| [`feature-ideation-sources`](standards/feature-ideation-sources.md) | Feature research & architecture intake | Upstream lab feeds, tooling release notes, platform updates, security disclosures |
| [`github-settings`](standards/github-settings.md) | Baseline repository configuration | Organization rulesets, environment secrets, approved GitHub Apps, standardized label suites |
| [`gitignore-standard`](standards/gitignore-standard.md) | Organization baseline `.gitignore` | Managed block markers, secret prevention, agent worktree exclusions, build artifact baselines |
| [`initiatives-project`](standards/initiatives-project.md) | GitHub Projects tracking standards | Organization project board architecture, custom fields, epic-to-task routing, automated triage views |
| [`persona-standards`](standards/persona-standards.md) | Agent persona definitions | Persona trigger matrix, canary onboarding stages, trust & scope boundaries, Definition of Done |
| [`pr-limits`](standards/pr-limits.md) | Pull request size & review velocity | Line-change caps, single-responsibility scoping, bot exceptions, author runbooks |
| [`push-protection`](standards/push-protection.md) | Secret scanning & push protection | Layered protection (local hooks, push protection, CI sweeps), breach triage runbooks |
| [`ruleset-remediation-runbook`](standards/ruleset-remediation-runbook.md) | Branch protection & ruleset remediation | Ruleset audit checklists, rollback snapshots, bypass permission controls, migration runbooks |
| [`standards-versioning`](standards/standards-versioning.md) | Versioning and release governance | Release tagging schemas, backwards compatibility, upstream sync, opt-in procedures |

---

## Reporting & Auditing Workflows

Scheduled maintenance workflows run across the fleet to preserve security baselines, detect drift, and surface status reports.

| Workflow | Schedule | Purpose |
|----------|----------|---------|
| [`compliance-audit.yml`](.github/workflows/compliance-audit.yml) | Weekly | Full standards compliance audit and branch health survey with automated remediation issues |
| [`daily-org-status.yml`](.github/workflows/daily-org-status.yml) | Daily | Organization operational status digest opened as an issue for maintainer review |
| [`org-scorecard.yml`](.github/workflows/org-scorecard.yml) | Weekly | OpenSSF Scorecard security evaluation across public repositories |
| [`standards-sync.yml`](.github/workflows/standards-sync.yml) | Weekly | Automated PR engine keeping member repositories aligned with the latest baseline templates |

---

## Maintainer & Contact

- **Owner:** Yasir Bin Mudassir
- **Contact:** [peppywolf.ym@gmail.com](mailto:peppywolf.ym@gmail.com)
- **Private Automation:** Companion private repository handles internal agents, custom workflows, and secret-bearing CI runners.
