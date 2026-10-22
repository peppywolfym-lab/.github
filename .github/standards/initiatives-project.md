# Initiatives Project — operator guide

The **Initiatives** project board
([orgs/petry-projects/projects/1](https://github.com/orgs/petry-projects/projects/1))
is the org's single cross-repo plane for strategic work — items that span
multiple PRs, multiple repos, or multiple agents, the things an
`gh issue list` filter would lose track of.

This doc covers what belongs on the board, how items get there, and how to
operate the project. The pilot itself is tracked in
[#387](https://github.com/petry-projects/.github/issues/387).

## What belongs on the board

The board is the **org-wide portfolio of issues** across every installed repo,
each classified to an Initiative + Theme. **Issues are tracked; Ideas are not.**

### Auto-added (no manual step)

| Content type | Conditions | Result |
|---|---|---|
| **Issues** (all installed repos) | **Un-gated** — every issue, minus the excluded-label noise filter (`compliance-audit`, `health-check`, `fleet-tracker`, `daily-report`) | Linked item appears on the board |
| **Pull requests** | Has label `dev-lead` AND none of the excluded labels | Linked item appears on the board |

Issues are un-gated because an issue is the durable unit of work and the board
is meant to be the full portfolio. PRs keep the `dev-lead` gate: they're
transient, and tracking every dependabot/CI PR would drown the board. The
excluded labels are the noise filter — automation-generated churn (routine
compliance fixes, fleet-monitor failures, daily status reports) stays off.

### Ideas are not on the board

Raw ideas live in **GitHub Discussions**, where deliberation belongs. They are
**not** drafted onto the board. When an idea is worth pursuing, it becomes an
**Epic** — a parent Issue with story sub-issues — which auto-adds via the issue
path (and the board rolls up its sub-issue progress). The Discussion is linked
from the Epic for provenance. Rationale: a Projects v2 board can't hold a
Discussion as real content (only a shadow draft with no sub-issues, status, or
linked PRs), so an Issue is the strictly better board unit for anything being
executed.

### Auto-cleaned

Reconciliation is idempotent and two-directional: an issue that is closed, or
gains an excluded label (or a PR that loses `dev-lead`), is removed from the
board on the next event or reconcile cycle.

### Not auto-added (manual add path)

- **Issues / PRs from repos other than `.github`** — multi-repo rollout is a
  follow-on (see deferred items below).
- **Fork PRs labeled by a maintainer when the author is `FIRST_TIMER` /
  `CONTRIBUTOR`.** The `pull_request_target` gate evaluates the PR author's
  association; this is documented as a known limit in the workflow header.
- **Items the event triggers never fire for.** The event path misses two
  structural cases: issues/PRs created by the default `GITHUB_TOKEN`
  (`app/github-actions`) — GitHub does not fire workflows from default-token
  events — and runs dropped under runner congestion. **A scheduled/manual
  backlog reconcile (`add-to-project-reconcile.yml`, #518) closes both:** it
  scans every App-installed repo's open issues/PRs daily (issues un-gated, PRs
  gated) and reconciles each via the same gate/helpers, so a missed item lands
  within one cycle. It also runs the Initiative/Theme classifier as its second
  step. Run it manually with `dry_run` to preview.

To add a content-linked item manually:

```bash
# Resolve the node ID. issueOrPullRequest returns the PR-typed ID for
# PRs and the Issue-typed ID for issues — addProjectV2ItemById wants
# the content-specific one. REST '/issues/<n>' returns the Issue-typed
# id even for a PR, which is the wrong content type for the mutation.
NODE_ID=$(gh api graphql \
  -F owner=<owner> -F repo=<repo> -F n=<n> \
  -f query='query($owner:String!,$repo:String!,$n:Int!){
    repository(owner:$owner, name:$repo) {
      issueOrPullRequest(number:$n) {
        ... on Issue { id }
        ... on PullRequest { id }
      }
    }
  }' -q '.data.repository.issueOrPullRequest.id')

# Add to the project
gh api graphql -F projectId="PVT_kwDOD2inqs4BZq3-" -F contentId="$NODE_ID" \
  -f query='mutation($projectId:ID!,$contentId:ID!){
    addProjectV2ItemById(input:{projectId:$projectId,contentId:$contentId}){
      item { id }
    }
  }'
```

## Fields

The board has two correlated single-select fields for taxonomy — **Theme**
is the top-level bucket, **Initiative** is the specific program within a
Theme. Roadmap-view grouping uses Initiative; cross-cutting filters
(e.g., "what is Agentic Framework working on?") use Theme.

| Field | Values | Use it for |
|---|---|---|
| **Status** | `Inbox` → `Specced` → `In Dev` → `In Review` → `Deployed` → `Verified` → `Wont do` | Stage tracking. `Inbox` is the default for auto-adds. |
| **Theme** | `Agentic Framework`, `Fleet Operations`, `Compliance`, `Tooling`, `Ad hoc`, + one per product (`TalkTerm`, `Broodly`, `Markets`, `Google App Scripts`, `ContentTwin`) | Top-level bucket. Each product is its own Theme; filter to the product Themes for "all product work". |
| **Initiative** | *see Theme → Initiative table below* | Program-level bucket within a Theme. |
| **Work type** | `Feature`, `Spike`, `Fix`, `Infra`, `Security`, `Docs` | Categorization. (Not `Type` — that name is reserved in Projects v2.) |
| **Priority** | `P0`, `P1`, `P2`, `P3` | Triage / sequencing. |
| **Owner-agent** | `dev-lead`, `claude`, `coderabbit`, `copilot`, `human` | Who's expected to drive this. |
| **Target date** | (date) | Optional commitment date. Used on the Roadmap view. |

### Theme → Initiative

| Theme | Initiatives |
|---|---|
| **Agentic Framework** | `dev-lead agent`, `pr-review agent`, `GH-AW`, `Copilot Instructions`, `Security`, `Model Selection`, `Business Analyst`, `BMAD` |
| **Fleet Operations** | `Fleet Monitor`, `Daily Reports`, `Org Standards`, `Release Strategy`, `Cost Observability` |
| **Compliance** | `Compliance program`, `Compliance Blitz`, `Self-healing`, `Auto-rebase` |
| **Tooling** | `Initiatives Project`, `Tooling` |
| **Ad hoc** | `Ad hoc` |
| **TalkTerm / Broodly / Markets / Google App Scripts / ContentTwin** | one same-named Initiative per product (repo-scoped; cross-cutting infra work in a product repo still classifies to its infra Initiative, e.g. Org Standards) |

**`Org Standards`** specifically covers work *defined in `.github`* and
propagated to other repos: CI baselines, CODEOWNERS, branch rulesets, push
protection, scorecard/sonarcloud, repo settings, org secrets, org apps.

Schema reviews go through
[#387](https://github.com/petry-projects/.github/issues/387). Renaming or
removing single-select options on a populated project is painful —
coordinate before changing.

### Adding or modifying single-select options safely

`updateProjectV2Field` with `singleSelectOptions` is a **full replacement**
of the option list. Any existing option whose `id` is not round-tripped in
the mutation gets dropped and recreated with a fresh `id`. Every project
item that referenced the old `id` then points at nothing — the field reads
as "no value" in the UI.

On 2026-06-08 the Initiative field lost 301 of 313 assignments this way
when a parallel session added a new option without including the existing
options' `id`s in the mutation. Recovery worked (re-categorize from item
titles + bulk re-apply) but cost ~3 min of API churn and depends on
title-pattern heuristics being good enough.

**Safe pattern for any single-select schema change:**

```bash
# 1. Read the existing options FIRST (always, even for a one-option add)
gh api graphql -F fieldId="<FIELD_ID>" -f query='
  query($fieldId: ID!) {
    node(id: $fieldId) {
      ... on ProjectV2SingleSelectField {
        options {
          id
          name
          color
          description
        }
      }
    }
  }
'

# 2. Build the full new option list. Existing entries MUST carry their id;
#    new entries omit the id so the API assigns one.
gh api graphql -f query='mutation {
  updateProjectV2Field(input: {
    fieldId: "<FIELD_ID>"
    singleSelectOptions: [
      {id: "<existing_id_1>", name: "<existing_name_1>", color: GRAY, description: "..."},
      {id: "<existing_id_2>", name: "<existing_name_2>", color: BLUE, description: "..."},
      # ... every existing option, each with its id ...
      {name: "<new_option>", color: PURPLE, description: "..."}  # NEW — no id
    ]
  }) {
    projectV2Field { ... on ProjectV2SingleSelectField { options { id name } } }
  }
}'
```

If you're using a higher-level helper (a Claude session, a script) and
it's not obvious whether existing IDs are being round-tripped, **dump the
options before** the mutation, **diff the option IDs after**, and stop
if any existing `id` changed before you mutate items further.

## Views

The project ships with four views (the API can't create them; they're
configured manually in the UI):

| View | Layout | Use it when |
|---|---|---|
| **Roadmap** | Table, grouped by Initiative, sorted by Status | Planning, weekly review |
| **In flight** | Board, columns = Status, filter `-status:Inbox -status:Verified -status:"Wont do"` | What's actually moving |
| **Ideation** | Table, filter `status:Inbox`, sorted by Created desc | Triage queue for new ideas |
| **By agent** | Board, columns = Owner-agent | "What's on each agent's plate" snapshot |

## How the auto-add works

```text
.github/workflows/add-to-project.yml             # Workflow (events → script call)
.github/workflows/add-to-project-reconcile.yml   # Scheduled/manual backlog reconcile (#518) + classify (#415)
.github/scripts/add-to-project/
    lib.sh                                       # find/add/delete/set-field helpers (DRY_RUN-aware)
    add-issue-or-pr.sh                           # Noise gate (issues un-gated, PRs gated) + addProjectV2ItemById
    reconcile-backlog.sh                         # Scans open issues/PRs, reconciles via the above
    classify-initiative.sh                       # Rule-driven Initiative/Theme back-fill (#415)
    initiative-rules.tsv                         # Ordered "Initiative <TAB> regex" match rules
    initiative-taxonomy.tsv                      # "Initiative <TAB> Theme" roll-up
.github/workflows/add-to-project-tests.yml       # shellcheck + bats CI gate
test/workflows/add-to-project/                   # bats tests, gh stub, fixtures
```

**Auth:** A dedicated GitHub App (`petry-projects-planner`, App ID
`3985527`) installed on the org. The workflow mints a fresh installation
token per run via `actions/create-github-app-token@v3.2.0` — no static
long-lived token. App permissions: Organization Projects `Read+write`,
Repository Issues `Read`, Repository Pull requests `Read`. Org secrets:
`INITIATIVES_APP_ID`, `INITIATIVES_APP_PRIVATE_KEY`.

**Concurrency:** Workflow runs for the same content (same issue / PR number)
serialize via concurrency group, so e.g. `labeled` and `unlabeled` for the
same item can't race against each other.

**Project ID:** `PVT_kwDOD2inqs4BZq3-` (hardcoded in the workflow env).
Multi-Project consumers of the same scripts would parameterize this.

## How Initiative classification works

Adding an item to the board and *categorizing* it are separate concerns. The
add path (above) only sets board membership; it leaves the **Initiative**
field blank. `classify-initiative.sh` (#415) fills it.

- **Deterministic, not AI.** Each item is flattened into a lowercase
  signature `title | labels | owner/repo` and matched against ordered regex
  rules in `initiative-rules.tsv` — **first match wins**, so specific
  initiatives sit above the generic bucket they'd otherwise be swallowed by
  (Compliance Blitz before Compliance program; Org Standards before
  Compliance program). A matched item also gets the **Theme** that Initiative
  rolls up to, from `initiative-taxonomy.tsv`.
- **Gate labels are stripped from the signature.** Every board item carries
  the `dev-lead` required label, so if it stayed in the signature the
  `dev-lead agent` rule would match *every* item. `SIGNATURE_IGNORE_LABELS`
  (default = the required + excluded noise-gate labels) drops it; only labels
  that actually signal an initiative survive. This is the concrete mechanism
  behind the "`dev-lead` is a work-assignment signal, not a classification
  signal" note in **Fields** above.
- **No guessing.** An item that matches no rule is left blank and printed as
  `UNMATCHED` for triage — the classifier never assigns "Ad hoc" as a
  catch-all. Coverage is reported in the job summary on every run. Tune
  coverage by adding rows to `initiative-rules.tsv`.
- **Safe by construction.** It writes only per-item field *values*
  (`updateProjectV2ItemFieldValue`), never the field *schema*
  (`updateProjectV2Field`), so it cannot trip the option-wipe footgun in
  "Adding or modifying single-select options safely" above. It resolves live
  option ids by name at runtime; a rule naming an initiative that isn't a
  live option is skipped with a warning rather than failing the run.
- **Non-destructive.** By default it only fills items whose Initiative is
  empty, so a human's manual assignment is never overwritten. Set
  `RECLASSIFY=all` (workflow input `reclassify_all`) to re-evaluate every
  item.

It runs as the second step of `add-to-project-reconcile.yml`, right after the
backlog reconcile, so items added in a cycle are categorized in the same run.
Manual dispatch defaults to `dry_run` (preview coverage + the UNMATCHED list
before mutating). The first live run back-fills the existing blank items.

## Deferred work (not in the pilot)

Tracked in [#415](https://github.com/petry-projects/.github/issues/415).
Summary:

- **Multi-repo rollout** — workflow only fires for events in `.github`
  today; most of `.github-private`'s strategic work has to be added
  manually.
- **Topic-label gate** — replace the current `dev-lead`-as-inclusion-signal
  with topic labels (`agentic-framework`, `fleet-ops`, `compliance`,
  `tooling`). `dev-lead` remains as a work-assignment signal (orthogonal).
- **Configurable gate** — move the inclusion / exclusion list out of the
  shell and into a versioned config file in `.github`.
- **Issue/PR cleanup-on-label-change** — `process_issue_or_pr` only adds;
  it doesn't reconcile when an existing item later receives an excluded
  label.
- **Fork-PR maintainer-label gate** — `pull_request_target`
  author_association evaluates the PR author, not the labeler.

These belong in one follow-on PR so the underlying mechanism (a generic
`reconcile_content_with_project`) gets designed once instead of three
times.

## Related

- **Tracking:** [#387](https://github.com/petry-projects/.github/issues/387)
- **Founding discussion:**
  [#386](https://github.com/petry-projects/.github/discussions/386)
- **Validation + 30-day review:**
  [#414](https://github.com/petry-projects/.github/issues/414)
- **Multi-repo follow-on:**
  [#415](https://github.com/petry-projects/.github/issues/415)
- **Pilot retrospective:**
  [#416](https://github.com/petry-projects/.github/issues/416)
- **Workflow fix — single-line if:**
  [#418](https://github.com/petry-projects/.github/pull/418)
- **Issue Fields rollout:** discussion
  [#364](https://github.com/petry-projects/.github/discussions/364)
  (waiting on Project schema to stabilize ~30 days)
