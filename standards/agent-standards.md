# Agent Configuration Standards

Standards for repositories that use AI agent configurations (CLAUDE.md,
AGENTS.md, BMAD modules, Claude plugins, MCP server configs).

---

## Required Files

Every repository MUST have:

| File | Purpose | Compliance Check |
|------|---------|-----------------|
| `CLAUDE.md` | Project-level instructions for Claude Code | error if missing |
| `AGENTS.md` | Development standards for AI agents | error if missing |

## Compliance Exemptions — Files Agents Must Not Modify

The following files are structurally immutable. Agents must not open PRs that
modify them. No compliance finding will ever require a change to these files;
if an existing agent-created PR touches them, close it without merging.

**Canonical source:** [`standards/workflow-exemptions.json`](workflow-exemptions.json)

| File | Reason |
|------|--------|
| `.github/workflows/agent-shield.yml` | Security boundary — agents are not permitted to weaken security scanning; changes require explicit human review |

These files must be adopted verbatim from `standards/workflows/` and updated
only by merging a standards PR from `petry-projects/.github`, which propagates
to all repos via the `@v1` tag bump.

### CLAUDE.md Requirements

- MUST reference `AGENTS.md` for development standards
- MUST NOT contain secrets, API keys, or credentials
- MUST NOT contain overly permissive tool authorization (e.g., `dangerouslySkipPermissions`)
- SHOULD define project-specific context (tech stack, conventions, key files)

### AGENTS.md Requirements

- MUST reference the org-level standards: `petry-projects/.github/AGENTS.md`
- MUST define project-specific development standards (testing, code style, architecture)
- MUST NOT override org-level security policies

## Agent Configuration Security

The workflow uses a **two-layer** approach:

### Layer 1: AgentShield Action (deep security scan)

The [`affaan-m/agentshield`](https://github.com/affaan-m/agentshield) GitHub
Action performs a comprehensive security scan with **102 rules** across 5
categories:

| Category | Rules | Coverage |
|----------|------:|----------|
| Secrets Detection | 10 rules, 14 patterns | API keys, tokens, credentials, env leaks |
| Permission Audit | 10 rules | Wildcard access, missing deny lists, dangerous flags |
| Hook Analysis | 34 rules | Command injection, data exfiltration, silent errors |
| MCP Server Security | 23 rules | High-risk servers, supply chain, hardcoded secrets |
| Agent Config Review | 25 rules | Prompt injection, auto-run, hidden instructions |

The action produces a graded security report (A–F, 0–100 score) and fails
the build if findings at or above `high` severity are detected.

**CLI reference (used via `npx` in CI — no install required):**

```yaml
- name: AgentShield Security Scan
  run: |
    npx ecc-agentshield@1.4.0 scan \
      --path . \
      --min-severity high \
      --format terminal
```

### Layer 2: Org-specific structural checks

Custom checks that enforce petry-projects conventions not covered by the
generic AgentShield scanner:

| Rule | Severity | Description |
|------|----------|-------------|
| `required-files` | error | CLAUDE.md and AGENTS.md must exist |
| `claude-reference` | error | CLAUDE.md must reference AGENTS.md |
| `org-reference` | error | AGENTS.md must reference `petry-projects/.github/AGENTS.md` |
| `valid-frontmatter` | error | All SKILL.md files must have YAML frontmatter with `name` and `description` |

## AgentShield CI Workflow

Every repository MUST include `.github/workflows/agent-shield.yml`.
See [`workflows/agent-shield.yml`](workflows/agent-shield.yml) for the
standard template.

**Standard triggers:** push to main, pull requests to main.

The workflow runs both the AgentShield action and the org structural checks.
Either layer failing causes the build to fail.

## Agent Ecosystem in Dependabot

Repositories with BMAD modules or Claude plugins should track agent
dependencies. While Dependabot does not have a native "agents" ecosystem,
the AgentShield CI workflow performs equivalent version and security checks
on agent configuration files.

For repos with `package.json` referencing BMAD modules (e.g., `bmad-method`,
`bmad-bgreat-suite`), the `npm` ecosystem already covers version tracking.
The AgentShield action adds the agent-specific security layer on top.

## Decision-Making Reusables — Pure, Tested Decision Cores

See [AGENTS.md § Decision Logic Lives in a Pure, Tested Script](../AGENTS.md#decision-logic-lives-in-a-pure-tested-script)
for the full standard, exemplars, and rationale.

## BMAD Method Workflows

Repositories with BMAD Method installed (presence of `_bmad/`, `_bmad-output/`,
or equivalent BMAD planning artifacts) MUST include the **Feature Ideation**
workflow, which runs the BMAD Analyst (Mary) on a weekly schedule to research
the market and produce evidence-grounded feature proposals as GitHub Discussions.

See [CI Standards §8 — Feature Ideation](ci-standards.md#8-feature-ideation-feature-ideationyml--bmad-method-repos)
for the full standard, including the multi-skill ideation pipeline and the
critical configuration gotchas (Opus 4.6 model selection, GitHub token override,
log-secret hygiene). The template is at
[`standards/workflows/feature-ideation.yml`](workflows/feature-ideation.yml).
