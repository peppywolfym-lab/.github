# CLAUDE.md — petry-projects/.github

This file provides project-specific instructions for Claude Code when working in this repository.

## Development Standards

Read [AGENTS.md](./AGENTS.md) before making any changes. It defines the org-wide standards for CI, workflows, labels, agent configuration, and more.

## Repository Purpose

This is the **org-level `.github` repository** for `petry-projects`. It contains:

- **`AGENTS.md`** — org-wide AI agent development standards
- **`standards/`** — canonical standards and workflow templates for all org repos
- **`profile/`** — org profile README
- **`scripts/`** — utility scripts used by CI workflows

## Key Guidelines

- When fixing compliance findings, read the relevant standard in `standards/` first
- Workflow templates in `standards/workflows/` should be copied verbatim, not regenerated
- SHAs for action pinning must be looked up via the GitHub API — never guessed
- All changes to `.github/workflows/` files require reading `standards/ci-standards.md` first
