# Copilot Instructions Standard

This standard defines how to create and maintain GitHub Copilot custom instruction files across
the **petry-projects** organization.

## Purpose and Benefits

GitHub Copilot generates suggestions based on the open file and surrounding context, but it
cannot infer project-specific facts from code alone: which test runner is in use, what the exact
local dev commands are, which bounded contexts a repo defines, or what coverage thresholds are
enforced in CI. Without instruction files, every developer and every agent session must
re-discover this context through trial-and-error or by reading the README.

Instruction files solve this by surfacing the right context to Copilot automatically:

| Benefit | How instruction files deliver it |
|---------|----------------------------------|
| **Consistent suggestions** | Copilot sees org coding standards on every request — SOLID, DDD, TDD, structured logging — without requiring the developer to repeat them |
| **Reduced onboarding friction** | New contributors and agents get the project's stack, structure, and commands immediately, not after reading multiple docs |
| **Enforced standards** | Language-specific files (TypeScript, Go, Terraform, …) embed org linting, formatting, and security rules so Copilot proposes compliant code by default |
| **Less review churn** | Fewer review comments on style and convention violations; agents are less likely to introduce drift |
| **Faster agent execution** | Copilot coding agents pre-load the right dependencies and follow the right patterns without a bootstrapping phase |

The org-level baseline (`petry-projects/.github`) covers rules that apply everywhere. Repo-level
files add the project-specific context that makes suggestions accurate for that repo in particular.

## Overview

GitHub Copilot supports two types of instruction files, both scoped to the individual
repository they live in:

| Type | File | Scope |
|------|------|-------|
| **Repo-wide** | `.github/copilot-instructions.md` | Applies to all Copilot requests in that repo |
| **Path-specific** | `.github/instructions/<name>.instructions.md` | Applies when the file being edited matches the `applyTo` glob pattern |

> **There is no automatic org-wide propagation.** Placing `copilot-instructions.md` in the
> `petry-projects/.github` repository makes it apply to that repo only — it does not broadcast
> to other repos in the org. Org-wide coverage is achieved by deploying the file to every repo,
> which the weekly compliance audit enforces (see [Compliance](#compliance) below).

Path-specific files use YAML frontmatter to declare which files they apply to:

```yaml
---
description: "Purpose of these instructions"
applyTo: "**/*.ts,**/*.tsx"
---
```

The `excludeAgent` frontmatter key restricts which Copilot tools use the instructions
(`"code-review"` or `"cloud-agent"`).

Priority order within a repository (highest to lowest): Personal instructions → Repository
instructions.

## Canonical Instruction Files (source of truth in this repo)

The following files live in `petry-projects/.github` and serve as the **canonical templates**
that every repo should adopt. They apply to this repo only as-is; each other repo gets its own
copy via the per-repo rollout described in [Creating a Repo-Level copilot-instructions.md](#creating-a-repo-level-copilot-instructionsmd).

| File | Languages / Scope |
|------|-------------------|
| `.github/copilot-instructions.md` | Repo-wide baseline (copy to each repo) |
| `.github/instructions/typescript.instructions.md` | `**/*.ts`, `**/*.tsx` |
| `.github/instructions/javascript.instructions.md` | `**/*.js`, `**/*.mjs`, `**/*.cjs` |
| `.github/instructions/python.instructions.md` | `**/*.py` |
| `.github/instructions/go.instructions.md` | `**/*.go` |
| `.github/instructions/terraform.instructions.md` | `**/*.tf`, `**/*.tfvars`, `**/*.tftest.hcl` |
| `.github/instructions/shell.instructions.md` | `**/*.sh`, `**/*.bash` |

## Adding a New Language

To add a new language instruction file:

1. Create `.github/instructions/<language>.instructions.md` in this repo.
2. Add the `applyTo` frontmatter with glob patterns for the language's file extensions.
3. Base the content on the relevant [awesome-copilot template](https://awesome-copilot.github.com/instructions/)
   and adapt it to org conventions defined in `AGENTS.md`.
4. Add an entry to the table above in this document.
5. Open a PR to `petry-projects/.github` following the standard PR workflow.

## Creating a Repo-Level copilot-instructions.md

Each repository SHOULD provide its own `.github/copilot-instructions.md` that adds repo-specific
context on top of the org-level defaults. Repo-level instructions inherit all org-level rules —
only document what differs or adds detail.

### Required Sections

A repo-level `copilot-instructions.md` MUST include the following sections. Keep the file to
approximately two pages — concise, specific, and actionable.

The `## Org Standards` section MUST list every language-specific `.instructions.md` file deployed
to `.github/instructions/` in that repo, each with a one-line scope description. This makes the
path-specific files discoverable without requiring contributors to browse the directory.

---

```markdown
# Copilot Instructions — [Repo Name]

## About

[One sentence describing what this repo does and its role in the petry-projects org.]

## Tech Stack

- **Runtime:** Node.js 22 / Python 3.12 / Go 1.23 / [adjust]
- **Framework:** React 19 · Electron 41 / FastAPI / [adjust]
- **Testing:** Vitest · Playwright / pytest / go test [adjust]
- **Linting:** ESLint (flat config) + Prettier / ruff + black / golangci-lint [adjust]
- **Key libraries:** [list major dependencies]

## Project Structure

[Describe key directories and naming conventions. Example:]

src/
  domain/          # Domain models, value objects, aggregates
  application/     # Use cases, command/query handlers
  infrastructure/  # Adapters, persistence, external services
  presentation/    # UI components, API routes

## Local Dev Commands

- Install:    `npm install`
- Dev run:    `npm run dev`
- Test:       `npm test`
- Lint:       `npm run lint`
- Typecheck:  `npm run typecheck`

## Required Environment Variables

- `DATABASE_URL`: PostgreSQL connection string (e.g., `postgres://user:pass@host/db`)
- `API_KEY`: External service API key (obtain from the team vault)

## Testing Framework

- Runner: Vitest [or Jest / pytest / go test]
- Coverage threshold: 85% statements / 80% branches [repo-specific]
- Mutation testing: Stryker (runs in CI) [if applicable]

## Repo-Specific Overrides

[List any rules that differ from the org-level copilot-instructions.md. Reference the specific
AGENTS.md section being overridden. Leave this section blank (or remove it) if no overrides
apply.]

## Org Standards

See [petry-projects/.github — AGENTS.md](https://github.com/petry-projects/.github/blob/main/AGENTS.md)
for org-wide development standards.

**Language-specific instructions** (applied automatically by Copilot when you open matching file types):

- [TypeScript / TSX](instructions/typescript.instructions.md) — [strict config, branded types, DDD/CQRS, pino, React/Electron as applicable]
- [JavaScript](instructions/javascript.instructions.md) — [style, JSDoc, error handling]
- [Go](instructions/go.instructions.md) — [naming, gofmt, slog, error wrapping, concurrency, testing]
- [Shell](instructions/shell.instructions.md) — [safety flags, ShellCheck, quoting, error handling]
- [Python](instructions/python.instructions.md) — [black/ruff, type annotations, structlog, pytest]
- [Terraform](instructions/terraform.instructions.md) — [fmt, tflint, security scanning, state management]

_List only the files actually deployed to `.github/instructions/` for this repo.
Omit this block entirely if no language instruction files were deployed._
```

---

### What to Include vs. What to Omit

**Include in repo-level instructions:**

- Specific framework versions and major library choices
- Bounded context names and directory layout
- Exact local dev commands with correct flags
- Coverage thresholds and testing tools specific to this repo
- Architecture patterns unique to this repo (e.g., Electron IPC conventions, GAS extraction pattern)
- Any rule that overrides or refines the org-level defaults
- Links to every language-specific `.instructions.md` file deployed to `.github/instructions/`, each with a one-line scope description (list only files that are actually present)

**Do NOT include in repo-level instructions:**

- Org-wide rules already covered in `copilot-instructions.md` (SOLID, TDD, logging format, etc.)
- Rules already covered in language-specific `.instructions.md` files
- Content already documented in `AGENTS.md`
- Secrets, API keys, credentials, or example tokens with real values
- Links to language instruction files that were not deployed to this repo's `.github/instructions/`

## Content Quality Rules

- **Max length:** ~two pages. Copilot applies instructions most effectively when they are
  concise and broadly applicable. Longer files may be truncated.
- **Repo-wide, not task-specific:** Instructions should apply to all work in the repo, not
  to a single task or PR.
- **Actionable language:** Prefer imperatives ("use `pino` for logging") over descriptions
  ("this repo uses pino for logging").
- **No duplication with AGENTS.md:** AGENTS.md is the authoritative source for AI agent
  standards. Copilot instruction files summarize or extend it — they don't replace it.
- **Keep in sync:** When the tech stack changes (major version bump, new framework, tool
  replacement), update `copilot-instructions.md` in the same PR.

## Compliance

The weekly compliance audit (`scripts/compliance-audit.sh`) enforces this standard
automatically. Four `warning`-severity checks run against every repository in the org:

| Check ID | Trigger | Remediation |
|----------|---------|-------------|
| `missing-copilot-instructions` | `.github/copilot-instructions.md` is absent | Copy the template below and fill in the repo-specific sections |
| `copilot-instructions-missing-tech-stack` | File exists but `## Tech Stack` section is absent | Add the section — list runtimes, frameworks, and major library versions |
| `copilot-instructions-missing-local-dev-commands` | File exists but `## Local Dev Commands` section is absent | Add the section — include exact install, dev-run, test, lint, and typecheck commands |
| `copilot-instructions-missing-language-links` | Files exist in `.github/instructions/` but are not listed in `## Org Standards` | Ensure files in `.github/instructions/` are listed in `## Org Standards` and that each listed link resolves to the correct relative path (no broken links) |

Findings are reported as `warning` (not `error`) because the org-level baseline in
`petry-projects/.github` ensures minimum Copilot guidance even without a repo-level file.
However, all warnings are tracked in the weekly compliance report and surfaced as GitHub issues
for remediation.

The `petry-projects/.github` repo itself is exempt from the repo-level check — its
`.github/copilot-instructions.md` is the org-level baseline that applies to all repos.
