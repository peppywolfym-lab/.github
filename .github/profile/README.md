# Petry Projects

A collection of open-source tools and experiments spanning terminal UX, market data, AI content tooling,
beekeeping tech, and agent orchestration.

---

## Projects

| Repository | Description | Language |
| --- | --- | --- |
| [TalkTerm](https://github.com/petry-projects/TalkTerm) | Terminal-based communication tool | HTML |
| [markets](https://github.com/petry-projects/markets) | Market data and analysis tooling (dual-licensed AGPL / Commercial) | HTML |
| [broodly](https://github.com/petry-projects/broodly) | A test implementation of the BMAD method | HTML |
| [broodminder-export](https://github.com/petry-projects/broodminder-export) | Extract all of your data from the BroodMinder API into portable files — resumable, rate-limit-aware. | Python |
| [ContentTwin](https://github.com/petry-projects/ContentTwin) | AI-powered Social Media Agent for small organizations — enterprise-quality social presence at non-profit pricing | Shell |
| [bmad-bgreat-suite](https://github.com/petry-projects/bmad-bgreat-suite) | BMad Operations Suite — SRE and DevOps agents and workflows for the BMad Method ecosystem | Shell |
| [google-app-scripts](https://github.com/petry-projects/google-app-scripts) | A place to share Google AppScripts for personal productivity | JavaScript |
| [incubator](https://github.com/petry-projects/incubator) | Product incubator: pre-product idea Discussions, decision briefs/PRD-lite, and disposable POCs. Ideas graduate to their own product repo once a POC proves out. Front-of-funnel for the `.github-private` ideation pipeline. | Shell |
| [repo-template](https://github.com/petry-projects/repo-template) | Org template repository: one-click scaffold for new petry-projects repos. Files via 'Use this template'; non-file standards via bootstrap. | Shell |
| [.github-private](https://github.com/petry-projects/.github-private) | Org-wide Copilot custom agents, automated workflows, prompts, and scripts | Shell |
| [.github](https://github.com/petry-projects/.github) | Organization-wide GitHub configuration, CI templates, and engineering standards | Shell |

---

## Standards & Practices

All repositories in this org follow shared engineering standards defined in
[`.github`](https://github.com/petry-projects/.github):

- **[CI Standards](https://github.com/petry-projects/.github/blob/main/standards/ci-standards.md)** — Reusable workflow versioning via the `stable` channel;
  staged promotion through concentric rings; action pinning policy; permissions policy; workflow patterns
  by tech stack (Node.js, Go, Python, Electron).

- **[Advanced Security](https://github.com/petry-projects/.github/blob/main/standards/advanced-security.md)** — Code Security Configurations for the org
  fleet; push-protection live-fire canary test; backend liveness (secret scanning); compliance audit checks.

- **[Push Protection](https://github.com/petry-projects/.github/blob/main/standards/push-protection.md)** — GitHub push protection (primary enforcement);
  local pre-commit prevention; CI secret scanning (secondary defense); incident response runbook.

- **[Gitignore Standard](https://github.com/petry-projects/.github/blob/main/standards/gitignore-standard.md)** — Two-layer model (L1 org-managed secrets
  baseline, L2 ecosystem extension); managed-block markers; negation discipline; compliance check.

- **[Agent Standards](https://github.com/petry-projects/.github/blob/main/standards/agent-standards.md)** — AgentShield deep security scan; required agent
  files and compliance exemptions; BMAD Method workflows; decision-making reusables.

- **[Agent Rate Limits](https://github.com/petry-projects/.github/blob/main/standards/agent-rate-limits.md)** — Token-budget breaker; daily budget as the
  per-agent cost bound; exempt actors; canary / dry-run rollout; operator runbook.

- **[Dependabot Policy](https://github.com/petry-projects/.github/blob/main/standards/dependabot-policy.md)** — Stack-specific templates (npm, Go, Rust,
  Python, Terraform, Actions); auto-merge workflow; vulnerability audit CI check; CODEOWNERS approval
  timing.

- **[GitHub Settings](https://github.com/petry-projects/.github/blob/main/standards/github-settings.md)** — Repository rulesets (`pr-quality`,
  `code-quality`); auto-merge configuration; bypass actors; labels — standard set; org-level secrets.

- **[CODEOWNERS Standard](https://github.com/petry-projects/.github/blob/main/standards/codeowners-standard.md)** — Branch protection; team composition;
  required setup for new bots.

- **[Copilot Instructions Standard](https://github.com/petry-projects/.github/blob/main/standards/copilot-instructions-standard.md)** — Canonical
  instruction files (source of truth in `.github`); adding a new language; content quality rules.

- **[Feature Ideation Sources](https://github.com/petry-projects/.github/blob/main/standards/feature-ideation-sources.md)** — AI/ML vendor & lab primary
  sources; research & trends; developer tooling and platform changelogs; security & compliance feeds;
  newsletters, podcasts, and conferences.

- **[Initiatives Project](https://github.com/petry-projects/.github/blob/main/standards/initiatives-project.md)** — What belongs on the board; fields;
  theme → initiative mapping; views; how the auto-add works.

- **[Persona Standards](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md)** — Trigger matrix (the onboarding checklist);
  canary onboarding (the last step); trust, permissions, and safety.

- **[PR Limits](https://github.com/petry-projects/.github/blob/main/standards/pr-limits.md)** — Exempt actors; operator runbook; reconciliation with the
  Dependabot cap.

- **[Ruleset Remediation Runbook](https://github.com/petry-projects/.github/blob/main/standards/ruleset-remediation-runbook.md)** — Snapshot every ruleset
  for rollback insurance; bypass actor management; legacy ruleset migration; verify and rollback
  procedures.

- **[Standards Versioning](https://github.com/petry-projects/.github/blob/main/standards/standards-versioning.md)** — The two tag forms; cutting a release;
  N-1 resolvability; opting in and staying out.

---

## Reporting & Dashboards

Scheduled reports and dashboards post as issues or run summaries for org maintainers:

- **[Compliance audit & improvement](https://github.com/petry-projects/.github/blob/main/.github/workflows/compliance-audit-and-improvement.yml)**
  — Weekly org standards compliance audit + runtime health survey, with per-finding remediation issues.
- **[Daily org status](https://github.com/petry-projects/.github/blob/main/.github/workflows/daily-org-status.yml)**
  — Daily "Org Status" digest posted as an issue for maintainers.
- **[OpenSSF Scorecard](https://github.com/petry-projects/.github/blob/main/.github/workflows/org-scorecard.yml)**
  — Weekly security-posture review across public repos; findings tracked as issues.
- **[Standards Deploy](https://github.com/petry-projects/.github/blob/main/.github/workflows/standards-deploy.yml)**
  — Weekly fleet sweep that opens standards-sync PRs for repos drifted off the org-standard workflow stubs.

---

## Contributing

1. Fork the relevant repository and create a branch off `main`.
2. Follow the [AGENTS.md](https://github.com/petry-projects/.github/blob/main/AGENTS.md) guidelines
   for commit style, TDD, and CI requirements.
3. Open a pull request — CI must pass before review.

Questions or feedback? Open an issue in the relevant repo.
