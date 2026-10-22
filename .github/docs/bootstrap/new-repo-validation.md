# New-repo onboarding — primary path & end-to-end DRY_RUN validation

_Epic #964 · Phase 3 (#970). Validation recorded 2026-06-28._

This is the recorded, end-to-end validation that the documented onboarding path —
**"Use this template" → `scripts/bootstrap-new-repo.sh` → ring confirmation** —
produces a fully org-compliant repo, exercised under `DRY_RUN` with no drift.

## Primary onboarding path (one-click + one-command)

1. **Use this template.** Create the repo from `petry-projects/repo-template`
   (`seed-repo-template.sh` keeps that template in sync with `petry-projects/.github`
   `standards/`). This seeds day-0 only: the thin-caller workflow stubs pinned to
   their published `@<name>/stable` channel tags plus the root/baseline files
   (CODEOWNERS, AGENTS.md/CLAUDE.md pointers, LICENSE, SECURITY.md, `.gitignore`,
   `BOOTSTRAP.md`). Then follow `BOOTSTRAP.md` for the two per-stack picks
   (Dependabot stack, `ci.yml`).
2. **Run the bootstrap.** `bash scripts/bootstrap-new-repo.sh owner/new-repo`
   brings repo settings, security/GHAS + secret-scanning push protection, the two
   sanctioned rulesets (with required checks + bypass actors), the standard label
   set, and CODEOWNERS verification to org compliance by orchestrating the existing
   `apply-*` scripts. It reimplements no policy.
3. **Confirm the release ring.** The ring is an auditable choice (default
   `stable`, record-only). A non-stable ring is registered in both central files
   and the caller stub is repinned to the matching `@<agent>/<ring>` channel tag.

Preview any run with `DRY_RUN=true` first — it prints the full intended state and
makes zero write API calls.

> **Template seeds day-0 only.** Ongoing standards updates to an existing repo
> still flow through the PR-based sync (`deploy-standard-workflows.sh` /
> `aw-standards-sync.sh`), not by re-templating. The legacy manual runbook is the
> **existing-repo fallback**, not the primary path.

## Recorded DRY_RUN walkthrough

Captured with `gh` stubbed to a no-op reader (`echo '{}'`) so the real sub-scripts
(`apply-repo-settings.sh`, `apply-rulesets.sh`) run end-to-end without network or
writes — the same seam the bats suite uses. Executable form:
`tests/test_bootstrap_new_repo.bats` → _"e2e DRY_RUN: covers the whole
intended-state surface with no write calls (#970 AC #2/#3)"_.

### Default ring (`stable`)

```text
$ DRY_RUN=true GITHUB_ACTOR=octocat bash scripts/bootstrap-new-repo.sh petry-projects/acme-service
[bootstrap] repo=petry-projects/acme-service dry_run=true ring=dev-lead/stable
[bootstrap] (1/5) release ring confirmation (dev-lead/stable)
  [ring-audit] repo=petry-projects/acme-service agent=dev-lead ring=stable operator=octocat at=... decision=recorded
  ring=stable — record-only; no central-file change required (covered by the '*' catch-all)
[bootstrap] (2/5) repo settings + security/GHAS + push protection
[dry-run] would patch security_and_analysis on petry-projects/acme-service: secret_scanning secret_scanning_push_protection secret_scanning_ai_detection secret_scanning_non_provider_patterns dependabot_security_updates
[dry-run] would disable auto-trigger for apps 1236702 347564 on petry-projects/acme-service
[bootstrap] (3/5) sanctioned fleet rulesets (pr-quality + code-quality)
[apply-rulesets] repo=petry-projects/acme-service dir=<materialized from petry-projects/.github> dry_run=true
  create ruleset 'code-quality' on petry-projects/acme-service
    [dry-run] POST repos/petry-projects/acme-service/rulesets
  create ruleset 'pr-quality' on petry-projects/acme-service
    [dry-run] POST repos/petry-projects/acme-service/rulesets
[apply-rulesets] done (2 ruleset(s))
[bootstrap] (4/5) standard label set
  [dry-run] would ensure label 'needs-human-review' on petry-projects/acme-service
  [dry-run] would ensure label 'ack-test-deletion' on petry-projects/acme-service
  [dry-run] would ensure label 'dependencies' on petry-projects/acme-service
  [dry-run] would ensure label 'automerge' on petry-projects/acme-service
[bootstrap] (5/5) verify CODEOWNERS team (@petry-projects/org-leads first owner)
  [dry-run] would verify @petry-projects/org-leads is the first CODEOWNERS owner on petry-projects/acme-service

[bootstrap] PASS — petry-projects/acme-service bootstrapped to org compliance (dry-run)
```

### Non-stable ring (`--ring ring1`)

The ring step additionally registers the repo in both central files and repins the
caller stub — and asserts no drift before writing:

```text
[bootstrap] (1/5) release ring confirmation (dev-lead/ring1)
  [ring-audit] repo=petry-projects/acme-service agent=dev-lead ring=ring1 operator=octocat at=... decision=registered
  [dry-run] would add petry-projects/acme-service to dev-lead 'ring1' members in canary-rings.json
  [ring] would register petry-projects/acme-service in petry-projects/.github:scripts/lib/ring-pins.sh for channel dev-lead/ring1 (cross-repo PR, keeps central files in sync)
  [ring] would repin petry-projects/acme-service caller stub .github/workflows/dev-lead.yml to @dev-lead/ring1
  ring consistency OK — petry-projects/acme-service sits in 'ring1' across both central files and its stub pins @dev-lead/ring1
```

## Intended state covered (no drift)

| Surface | Source of truth | Verified in walkthrough |
|---|---|---|
| Repo settings + security/GHAS | `apply-repo-settings.sh` | `security_and_analysis` patch intent |
| Secret-scanning push protection | `lib/push-protection.sh` | `secret_scanning_push_protection` in the patch set |
| Check-suite auto-trigger (Claude/CodeRabbit) | `apply-repo-settings.sh` | `would disable auto-trigger for apps 1236702 347564` |
| `pr-quality` ruleset + bypass actors | `petry-projects/.github` → `standards/rulesets/pr-quality.json` | created; bypass = OrganizationAdmin + Integration (`bypass_mode: always`) |
| `code-quality` ruleset + required checks + bypass | `petry-projects/.github` → `standards/rulesets/code-quality.json` | created; required checks SonarCloud, CodeQL, agent-shield, dependency-audit; same bypass actors |
| Required status checks | carried in the ruleset JSONs | not wired by bootstrap — live in `code-quality.json` |
| Standard labels | `bootstrap-new-repo.sh` `BOOTSTRAP_LABELS` | needs-human-review, ack-test-deletion, dependencies, automerge |
| CODEOWNERS team | new repo's `.github/CODEOWNERS` | first owner verified = `@petry-projects/org-leads` |
| Recorded ring | `standards/canary-rings.json` (+ cross-repo `ring-pins.sh`) | audited; stable record-only / non-stable registered with no drift |
| No drift | — | `DRY_RUN` emits **zero** write API calls |

## AC #1 — cross-repo checklist cutover (petry-projects/.github)

The two onboarding checklists live in **`petry-projects/.github`**, not in this
repo, so they are landed via the standards cross-repo PR pattern
(`STANDARDS_REPO=petry-projects/.github`, as `aw-standards-sync.sh` does), not on
this branch. The cutover content to apply:

- **`standards/github-settings.md` — "Applying to a New Repository":** lead with
  **"Use this template" + `scripts/bootstrap-new-repo.sh`** as the primary,
  one-click + one-command path (it applies repo settings, both rulesets with bypass
  actors + required checks, labels, CODEOWNERS, and secret-scanning push
  protection). Demote the existing 9-step manual settings runbook to an
  **existing-repo fallback**.
- **`standards/ci-standards.md` — "Applying to a New Repository":** same cutover —
  template + bootstrap first; the 13-step CI checklist becomes the existing-repo
  fallback. State explicitly that the template seeds **day-0 only** and ongoing
  CI/standards updates continue to flow through the PR-based sync
  (`deploy-standard-workflows.sh`), which remains the ongoing-sync path for
  existing repos and is out of scope to replace.

## See also

- `scripts/bootstrap-new-repo.sh` — the orchestrator (issues #967, #968)
- `scripts/seed-repo-template.sh` — day-0 template seeding + the generated `BOOTSTRAP.md` (#966)
- `tests/test_bootstrap_new_repo.bats`, `tests/test_seed_repo_template.bats` — the executable validation
