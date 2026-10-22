# ADR: Pull-Request-Limits Mechanism + Policy Decision

- **Status:** Proposed (pending human sign-off on §6 numbers and §7 mechanism)
- **Date:** 2026-06-21
- **Epic:** [#505](https://github.com/petry-projects/.github/issues/505)
- **Story:** [#506](https://github.com/petry-projects/.github/issues/506) — Phase 1 (decision record only)
- **Scope of this story:** documentation only. **No** repository setting, ruleset, or org
  policy is mutated here (AC #5).

This ADR pins down *how* GitHub exposes a "limit on open pull requests" so the
follow-on implementation stories (Story 2 = config, Story 3 = apply path) encode
the real mechanism instead of guessing the API or baking in unconfirmed numbers.

---

## 1. Context — why this decision is needed

Automation in this org opens pull requests faster than they merge. A measured
baseline (§5) shows **47 open, non-draft PRs across the org**, **44 of them
machine-authored**. Each open PR is not free: with `code-quality`'s
`strict_required_status_checks_policy: true` (branches must be up to date), every
merge to `main` re-stales the rest, and the auto-rebase fan-out re-runs CI on the
behind PRs. The epic's goal is to cap how many automation PRs are open at once.

The planner's working assumption was that GitHub ships a first-party
"pull request limits" feature (analogous to Dependabot's per-ecosystem cap) and
that we just need to find its API. **This ADR's first job was to verify that
assumption against GitHub's own docs rather than guess** (org standard: API
surfaces and SHAs are looked up, never guessed — see
[CLAUDE.md](../../CLAUDE.md) and [AGENTS.md](../../AGENTS.md)).

---

## 2. Decision (summary)

1. **GitHub exposes no native "maximum number of open pull requests"
   limit** as a repository setting, an organization setting, *or* a repository
   ruleset rule. This was verified first-hand against three canonical GitHub doc
   surfaces (§3). The only native, count-based PR cap GitHub offers is
   **Dependabot's `open-pull-requests-limit`**, which is *per-ecosystem* and
   Dependabot-only — not a general gate over all PR authors.
2. Because no native surface exists, the limit **cannot** live in
   `apply-repo-settings.sh` (no repo-settings field) or in `apply-rulesets.sh`
   (no ruleset rule). The enforceable mechanism is therefore **at the automation
   source** — the workflows/scripts that *create* the PRs — plus the existing
   Dependabot ecosystem cap. See §7 for the Story 2 integration point.
3. All limit values and the exempt-actor list in §6 are **proposals pending
   human sign-off**, not final numbers.

> If a reviewer knows of a brand-new or preview "PR limits" feature that the
> three doc surfaces below do not yet describe, that is the one gap this story
> could not close from inside CI (§8). The decision above should be re-opened
> with a citation if so.

---

## 3. Mechanism research — what GitHub actually exposes (AC #1, #2)

Each surface below was fetched first-hand during this story and read for any
field/rule that caps the *count* of open PRs.

| Surface | Source consulted | Result |
|---|---|---|
| **Repository ruleset rule** | [Available rules for rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets) | All rule types enumerated (restrict creations/updates/deletions, linear history, required deployments, signed commits, require PR before merge, required status checks, block force pushes, code-scanning / code-quality results, file-path / file-size / file-extension restrictions). **No rule limits the number of open pull requests.** |
| **Repository setting (REST)** | [`PATCH /repos/{owner}/{repo}`](https://docs.github.com/en/rest/repos/repos?apiVersion=2022-11-28) | Settable repo fields cover merge methods, feature toggles, and PR-creation *permission* (who may open PRs) — but **no field sets a maximum count of open PRs.** |
| **Organization setting** | [Managing PR reviews in your organization](https://docs.github.com/en/organizations/managing-organization-settings/managing-pull-request-reviews-in-your-organization) | The only org-level PR control is "code review limits" (restricting *who* can approve/request changes on public repos). **No org setting caps the number of open PRs** per repo or per actor. |
| **Dependabot (the one native count cap)** | [`.github/dependabot.yml`](../../.github/dependabot.yml) (`open-pull-requests-limit: 10`) and [dependabot-policy.md](../../standards/dependabot-policy.md) | A real count cap, but scoped to a single `package-ecosystem` and only governs Dependabot's own version-update PRs. Not a general limit. |

**Conclusion (AC #2):** there is **no REST/GraphQL endpoint and no
settings/ruleset field** that sets a general "max open PRs" limit, and it is
**not** a UI-only-with-hidden-API feature either — the capability simply is not
present on the repo-settings, org-settings, or ruleset surfaces that GitHub
documents. Any enforcement must be built by us at the PR *source*, not configured
on GitHub's side. Stories 2 and 3 must be planned on that basis.

---

## 4. Automation PR sources this targets (AC #3)

| Source | Authors PRs? | Identity / branch signal | Notes |
|---|---|---|---|
| **Dependabot** | Yes | `dependabot[bot]`, `dependabot/*` branches | Already capped per-ecosystem via `open-pull-requests-limit` (§7 reconciliation). |
| **dev-lead** | Yes | `dev-lead/*` branches | Largest single source in the baseline (§5). One PR per assigned issue. |
| **Claude / agentic PRs** | Yes | `claude/*` branches | Code-agent PRs; a distinct source the planner did not separately name but the baseline surfaced. |
| **initiative-driver / initiative-planner** | Yes (intermittent) | initiative branches | None open at measurement time, but a known burst source when an epic is fanned out. |
| **auto-rebase fan-out** | **No** | n/a | Important correction: [auto-rebase-reusable.yml](../../.github/workflows/auto-rebase-reusable.yml) **updates the branches of existing PRs** — it does not open new ones. It is a **CI-load amplifier**, not a PR source. A count limit on open PRs will not throttle it directly; the relevant lever for it is its `eligibility` input (default: `all` — every behind PR). |

---

## 5. Measured baseline (AC #3)

Measured with `gh search prs --owner petry-projects --state open --draft=false`
on 2026-06-21, then classified by head-branch prefix.

**Org-wide (all repos), open + non-draft:**

| Source (branch prefix / author) | Open PRs |
|---|---|
| `dev-lead/*` | 30 |
| `dependabot/*` (`dependabot[bot]`) | 10 |
| `claude/*` | 4 |
| human / ad-hoc (`fix/*`, `add/*`, non-bot author) | 3 |
| **Total** | **47** |

Machine-authored share: **44 / 47 (~94%)**.

**This repo (`petry-projects/.github`) only, open + non-draft:** 10 total —
7 agent-authored + 3 Dependabot.

These are the volumes a limit would reduce. The dominant lever is **dev-lead**
fan-out, followed by Dependabot and Claude.

---

## 6. Proposed limits + exemptions — PROPOSALS, NOT FINAL (AC #3)

> Everything in this section is a **proposal pending human sign-off**. The
> numbers are anchored to the §5 baseline, not to any GitHub-imposed maximum
> (none exists).

**Candidate cap (org-wide, automation PRs only):** a soft cap of **~15–20
concurrent open automation PRs org-wide**, implemented as a *source-side
admission gate* (a source stops opening new PRs while the count of open
automation PRs at/above its tier is over the cap). Rationale: current machine
volume is 44; ~15–20 leaves headroom for in-flight review while roughly halving
the standing queue that the auto-rebase fan-out has to service.

**Candidate per-source sub-caps (alternative / complementary):**

| Source | Proposed concurrent cap | Reasoning |
|---|---|---|
| dev-lead | 8–10 | Largest source; one-per-issue, naturally bounded by ready-for-dev backlog. |
| Claude / agentic | 3–4 | Keep at roughly today's level; bursts are the risk. |
| initiative-driver | 5 (burst budget) | Bound epic fan-out so a single epic cannot flood the queue. |
| Dependabot | **unchanged** — keep existing `open-pull-requests-limit` | Do not double-cap (see §7). |

**Proposed exempt-actor list** (PRs that must never be blocked by the cap):

| Actor | Why exempt |
|---|---|
| `dependabot[bot]` | Already capped per-ecosystem; security PRs must never be starved. |
| `OrganizationAdmin` / `@petry-projects/org-leads` | Human break-glass and maintainer PRs. |
| `dependabot-automerge-petry` (App) | Operates on existing PRs (merge/approve), does not add to the queue. |
| Security/hotfix-labeled PRs (e.g. `security`) | Urgent fixes must bypass any throttle. |

Final values, the exact tier boundaries, and whether to use a single org-wide
cap vs. per-source sub-caps are **deferred to human sign-off** before Story 2.

---

## 7. Mapping onto this repo's settings-application pattern + Story 2 integration point (AC #4)

### 7.1 Existing pattern (ground truth, verified this story)

This repo applies fleet configuration through **two manual, admin-token scripts**,
neither of which is invoked by any in-repo workflow (verified by grep over
`.github/workflows/`):

- [`scripts/apply-repo-settings.sh`](../../scripts/apply-repo-settings.sh) —
  `gh api PATCH repos/{owner}/{repo}` for repo settings + labels + check-suite
  prefs + CodeQL default setup.
- [`scripts/apply-rulesets.sh`](../../scripts/apply-rulesets.sh) — builds
  `pr-quality` / `code-quality` ruleset JSON **programmatically** (`build_ruleset_json`)
  and PUT/POSTs it via `gh api repos/{owner}/{repo}/rulesets`.

> **Issue-premise correction:** the story's Dev Notes reference a checked-in
> `.github/rulesets/code-quality.json`. **That file does not exist in this repo**
> — rulesets are generated in-code by `apply-rulesets.sh`, not stored as static
> JSON. Story 2 must edit the script, not a JSON file. The "no workflow applies
> the ruleset / settings" gap the planner flagged is real and confirmed: both
> scripts are run by hand (or referenced as manual remediation steps in
> [`scripts/compliance-remediate.sh`](../../scripts/compliance-remediate.sh)).
>
> **Update (2026-07, #575 / #580):** the premise above no longer holds. The codified
> [`standards/rulesets/{code-quality,pr-quality}.json`](../../standards/rulesets/) now
> exist and ARE the source of truth, and the detection-based in-code generation was
> retired — `apply-rulesets.sh` now reads those JSON files and PUTs them. The §7.2 /
> §7.3 conclusion is unaffected: PR limits remain a source-side admission gate, not an
> `apply-rulesets.sh` field.

### 7.2 Where PR limits land

Because §3 establishes there is **no repo-settings field and no ruleset rule**
for an open-PR count cap, **neither apply script is the integration point for a
native limit** — there is nothing for them to PATCH or PUT. Instead:

- **Native, already-present cap:** Dependabot's `open-pull-requests-limit` in
  [`.github/dependabot.yml`](../../.github/dependabot.yml) (and the
  [dependabot templates](../../standards/dependabot-policy.md)). This stays the
  authoritative limit for Dependabot.
- **New, non-Dependabot cap:** must be a **source-side admission check** added to
  the PR-creating automation (dev-lead, initiative-driver, agentic workflows):
  before opening a PR, count open automation PRs (via `gh search prs`, exactly as
  [`list-prs.sh`](../../.dev-lead/scripts/list-prs.sh) already enumerates them)
  and skip/defer if over the §6 cap, honoring the §6 exempt list.

### 7.3 Named Story 2 integration point

> **Story 2 should add the cap as a source-side admission gate in the
> PR-creating automation, with the limit value(s) and exempt list defined as
> shared config — NOT as a field in `apply-repo-settings.sh` or
> `apply-rulesets.sh` (no such GitHub surface exists to receive it).**

Concretely, Story 2's unambiguous touch points are:

1. A small shared limits config (proposed: a new `standards/pr-limits.md` plus a
   machine-readable list of caps + exempt actors) — single source of truth,
   matching how other caps are documented in `standards/`.
2. A pre-open count guard in the dev-lead / initiative / agentic PR-creation
   path, reusing the `gh search prs` enumeration pattern from
   [`list-prs.sh`](../../.dev-lead/scripts/list-prs.sh).
3. **Story 3** is then the *apply path*: because no workflow runs the existing
   apply scripts today, any "enable it across the fleet" step (including keeping
   the Dependabot caps in sync) needs a real invocation path. Note the org likely
   applies fleet config from central automation (this standards repo's scripts run
   by an admin, or `petry-projects/.github-private` scheduled automation) rather
   than from per-repo workflows — Story 3 must confirm and wire that.

### 7.4 Reconciliation with the existing Dependabot cap (AC #4)

The new cap **must exclude Dependabot** to avoid double-capping:

- Dependabot PRs are already bounded by `open-pull-requests-limit`
  (`10` for `github-actions` in this repo; `0` for app ecosystems per
  [dependabot-policy.md](../../standards/dependabot-policy.md), which suppresses
  routine version updates while letting security PRs through).
- Therefore `dependabot[bot]` is on the §6 **exempt list**, and the new org-wide
  automation cap counts/limits **only non-Dependabot** sources. Dependabot's
  volume stays governed solely by its own ecosystem-scoped limit. This keeps a
  single source of truth per actor and prevents a security PR from being starved
  by a general throttle.

---

## 8. Residual gap / what this story could not close (AC #2 honesty)

- **WebSearch was unavailable** in the CI environment (permission not granted);
  WebFetch of GitHub's *blog/changelog* index returned 404. The three
  **documentation** surfaces in §3 (ruleset rules, repo REST endpoint, org
  PR-review settings) **were** fetched first-hand and are the basis for the
  decision. If a preview/early-access "PR limits" feature exists that those docs
  pages do not yet describe, a human with changelog access should confirm and, if
  found, re-open §2 with the citation. The decision is otherwise grounded in
  GitHub's own current docs, not guesswork.

---

## 9. Consequences

- Stories 2/3 are **build**, not **configure**: there is no GitHub toggle to
  flip, so the work is a source-side admission gate + an apply path, plus keeping
  Dependabot's existing cap as-is.
- The §6 numbers are explicitly provisional; Story 2 starts with a human-signed
  set of caps and exempt actors.
- The auto-rebase fan-out is **not** throttled by a PR-count cap (it opens no
  PRs); its lever remains its `eligibility` input.

## 10. References

- [`scripts/apply-repo-settings.sh`](../../scripts/apply-repo-settings.sh)
- [`scripts/apply-rulesets.sh`](../../scripts/apply-rulesets.sh)
- [`.github/dependabot.yml`](../../.github/dependabot.yml)
- [`standards/dependabot-policy.md`](../../standards/dependabot-policy.md)
- [`standards/github-settings.md`](../../standards/github-settings.md)
- [`.dev-lead/scripts/list-prs.sh`](../../.dev-lead/scripts/list-prs.sh)
- [`.github/workflows/auto-rebase-reusable.yml`](../../.github/workflows/auto-rebase-reusable.yml)
- GitHub docs: [Available rules for rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)
- GitHub docs: [REST `PATCH /repos/{owner}/{repo}`](https://docs.github.com/en/rest/repos/repos?apiVersion=2022-11-28)
- GitHub docs: [Managing PR reviews in your organization](https://docs.github.com/en/organizations/managing-organization-settings/managing-pull-request-reviews-in-your-organization)
