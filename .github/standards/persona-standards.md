# Agentic Persona Standards

Standard for defining, onboarding, and rolling out a new **agentic persona**
across the `petry-projects` fleet.

A persona is an agent **role** — Dev Lead, PR Review, Scrum Master, Business
Analyst, QA Lead — that helps the org **design, build, test, deliver, and
operate** its projects. Roles, never person-names: see principle 6. This
standard turns the pattern that
is already implicit across those personas into an explicit, repeatable
**Persona Definition of Done**: a manifest, a trigger checklist, a file layout,
an eval gate, and a canary onboarding step.

> **Read first.** This standard builds on, and does not restate:
> [`agent-standards.md`](agent-standards.md) (required agent files, AgentShield,
> immutable files), [`ci-standards.md`](ci-standards.md) (stub/reusable tiers,
> channel-tag versioning, canary rings), and
> [`github-settings.md`](github-settings.md) (label taxonomy). Where those apply,
> follow them; this document only adds the persona-level wrapper.

---

## 1. Principles

1. **The manifest is the index-of-record.** Every persona has exactly one
   `persona.yml` (validated against
   [`personas/persona.schema.json`](personas/persona.schema.json)). It is the
   single place a human can point at to see what a persona *is*, where it is
   *defined*, how it is *triggered*, and how it *rolls out*. Everything else
   stays where it already lives; the manifest just references it.

2. **Unify over the frameworks, do not replace them.** We build on BMAD and the
   BMAD Test Architecture module and intend to **contribute back** to them. The
   manifest layers on top of a vendored framework agent — it points *into*
   `frameworks/` at a pinned version and records any local override as an
   explicit upstream-contribution candidate. Vendored files are never
   hand-edited (see [`prompts/bmad/README.md`](https://github.com/petry-projects/.github-private)
   in `.github-private` and each `frameworks/*/VENDOR.md`).

3. **Advisory by default; write is opt-in.** A new persona is assumed to be
   *advisory everywhere* (it comments, reviews, labels) and must **explicitly
   opt into write access** per surface, each with a gate label and a trust
   floor. This inverts the risk correctly: the blast radius of a new persona
   starts at "leaves a comment," not "opens a PR."

4. **Register once.** Ring membership and gate knobs live in exactly one place —
   [`canary-rings.json`](canary-rings.json). The manifest references the registry
   entry by `id`; it never restates rings or gates. `release/registry.yml` in
   `.github-private` is derived from this registry, not maintained in parallel
   (see §6).

5. **No persona reaches `stable` without an eval gate.** The held-out eval
   discipline in `.github-private` `evals/` (dev/holdout split, `holdout-guard.yml`)
   is a promotion gate, not a nicety.

6. **A persona is a role, not a person.** `id` and `name` name the **role** —
   `qa-lead` / "QA Lead", never `murat` / "Murat". This is the naming half of
   principle 2: an upstream framework may give its agent a person-name, and that
   is upstream's business. We reference upstream agents **only** by their
   technical skill id (`definition.layers[].framework.skill`, e.g. `bmad-tea`);
   we never mirror the person-name into our namespace. The reasons are practical,
   not stylistic:

   - **A role is legible.** `@petry-projects/qa-lead` tells a reader in a PR
     comment who is being addressed and why. `@petry-projects/murat` requires
     knowing the BMAD cast list.
   - **A role is stable.** Swapping the framework agent behind a persona, or
     replacing it with a first-party layer, must not change how it is addressed.
     Binding our identity to upstream's cast means their rename is our
     fleet-wide migration.
   - **A role is one namespace.** `dev-lead` and `pr-review` were already
     role-named; only the framework-backed personas drifted. One rule, no
     exceptions.

   Roles come from the org's own vocabulary: `dev-lead`, `qa-lead`,
   `scrum-master`, `business-analyst`, `product-manager`, `pr-review`.

---

## 2. Where a persona lives

Two-repo split, consistent with the org boundary in `AGENTS.md`
("What lives where — .github vs .github-private"):

| Artifact | Repo | Path |
|---|---|---|
| This standard + the manifest schema + the copy-me template | `.github` (org standards) | `standards/persona-standards.md`, `standards/personas/` |
| Ring registry (single source of truth) | `.github` | `standards/canary-rings.json` |
| **Persona instances** (`persona.yml` + layers + evals) | `.github-private` | `personas/<id>/`, plus the layer homes below |
| Framework agents & skills (vendored) | `.github-private` | `frameworks/<framework>/…` |
| Copilot profiles | `.github-private` | `agents/<id>.md` |
| Workflow prompt libraries | `.github-private` | `prompts/<id>/` |
| Caller stub + reusable workflow | per `canary-rings.json` `host` | `.github/workflows/…` |
| Eval sets | `.github-private` | `evals/<id>/` (dev/ + holdout/) |

The **manifest is the spine**: `personas/<id>/persona.yml` names each layer's
path. A persona may use one layer (e.g. a lone Copilot profile) or several (a
framework agent + a workflow-prompt orchestrator + an eval set), but there is
always exactly one manifest.

### Canonical instance layout (in `.github-private`)

```text
personas/<id>/
  persona.yml            # the manifest (required)
  README.md              # short human note: what this persona is, how to invoke

evals/<id>/              # NOT under personas/ — lives in the repo eval tree so it
  dev/cases.jsonl        #   inherits validate-cases.py + holdout-guard.yml for free
  holdout/cases.jsonl    #   (proposer-visible dev split; CODEOWNER-gated holdout)
```

Eval sets deliberately live under the existing `evals/<id>/` tree rather than
beside the manifest: that reuses the held-out validator and the immutability
guard without forking them (co-locating under `personas/<id>/evals/` is possible
later only by extending `HOLDOUT_GUARDED_PREFIXES`, so it is not the default).

The scaffold to copy is [`standards/personas/TEMPLATE/`](personas/TEMPLATE/).

---

## 3. The definition layers

We deliberately support more than one definition format, because the runtimes
genuinely differ. The manifest's `definition.layers[]` blesses whichever a
persona uses and points at it:

| `kind` | What it is | Home | When |
|---|---|---|---|
| `framework-agent` | A vendored BMAD-style agent (`SKILL.md` + `customize.toml`) | `frameworks/<fw>/…` | Persona is backed by an upstream framework we track and contribute to |
| `copilot-profile` | A single `agents/<id>.md` with `name`/`description`/`tools` frontmatter | `agents/` | Human-invocable from GitHub.com / IDEs |
| `workflow-prompts` | A phase-keyed prompt library filled by a shell orchestrator | `prompts/<id>/` | Persona runs as automated CI (like `dev-lead`) |
| `gh-aw` | A GitHub Agentic Workflow `.md` compiled to `.lock.yml` | `.github/workflows/` | Self-contained event-triggered agent |

**Framework-backed personas (the preferred path where a good upstream exists):**

- `definition.layers[].framework` records `name`, `upstream_repo`, `vendor_pin`
  (which **MUST** match the framework's `VENDOR.md`), and `skill`.
- Never hand-edit vendored files. Local behavior is layered via
  `local_overrides` (e.g. a `customize.toml` overlay resolved base → team → user,
  or an orchestration wrapper like `prompts/bmad/scrum-master.md` that runs the
  vendored skill non-interactively).
- Any override that is a **general** improvement MUST set
  `local_overrides.upstream_candidate: true` so it is tracked for contribution
  back rather than becoming permanent private drift.

All `SKILL.md` files still require `name` + `description` frontmatter
(AgentShield `valid-frontmatter`, `agent-standards.md`).

---

## 4. The trigger matrix (the onboarding checklist)

Every persona's `triggers` block is a **checklist of every surface it may act
on**. Fill one row per surface; anything unlisted falls back to `default_mode`.

**Surfaces** (the work-item × event families):

| Surface | Typical events | Notes |
|---|---|---|
| `issues` | `opened`, `labeled`, `commented` | Label gates arm write personas |
| `pull_request` | `opened`, `synchronize`, `ready_for_review`, `review_requested` | |
| `pull_request_review` | `submitted`, `created` (review comment) | |
| `discussion` | `created`, `labeled`, `commented` | Cannot run the agent inline — **must** bridge via `repository_dispatch`/`workflow_dispatch` (see `ci-standards.md`, issue #571) |
| `check_run` | `completed` | CI-failure follow-up |
| `schedule` | cron | Proactive / sweep work |
| `mention` | `@<handle>` in a comment | How a human addresses the persona directly — see §4.1. Reviewer-assignment counts here too |

**Rules:**

1. **`default_mode` is `advisory` or `off` — never `write`.** Write is only ever
   an explicit per-surface opt-in.
2. **Every `mode: write` surface MUST declare a `gate_label`** (the label that
   arms the persona, e.g. `dev-lead`) — schema-enforced.
3. **Every surface honours a trust floor.** Default `[OWNER, MEMBER,
   COLLABORATOR]`; verify `author_association` before consuming agent quota
   (this is the same trust boundary the PR-review and dev-lead paths already
   apply).
4. **Every persona defines an `opt_out_label`** (`<id>:hands-off`) that removes
   an item from its automation entirely. Beyond the opt-out, a persona declares
   its **human-hold brakes** as `stop_markers` in its interaction contract
   (`personas/<id>/interaction.yml`) — e.g. `needs-human-review`,
   `dev-lead:needs-human`, `<id>:hands-off`. Every surface honours the full set,
   including the **mention** router, which derives the markers from the contract
   rather than restating them, so a human hold stops the mentioned persona
   exactly as it stops the event-driven surfaces.

   > **Discussions are the one exception, and it is not a loosening.** A
   > discussion has no labels API surface, so neither the `opt_out_label`, the
   > write-mode `gate_label`, nor the `stop_markers` can be evaluated there. The
   > mention router therefore keeps discussion semantics unchanged: a read-mode
   > (advisory) mention routes, and a write-mode mention is **refused** — its
   > gate cannot be verified, so it fails closed. This is stated in the router's
   > header comment as well, so the divergence is never implicit.
5. **Most personas should be advisory on most surfaces.** The working hypothesis
   — a persona can usefully weigh in on nearly every work-item type — holds *for
   advisory participation*. Reserve `write` for the few surfaces where the
   persona genuinely authors changes, and gate each one.

Label gates and trust checks are defined operationally in `ci-standards.md`
(§ agent-trigger labels) and must reuse the existing labels rather than mint
near-duplicates.

### 4.1 Addressing — `@`-mentioning a persona

A persona that enables the `mention` surface MUST declare an `address` block
(schema-enforced). It is addressed by its **role**, per principle 6:

```yaml
address:
  handle: petry-projects/qa-lead   # an org TEAM — mentioned as @petry-projects/qa-lead
```

**The handle MUST be an org team, never a user account.** This is not a style
preference — it is the whole reason the block exists:

> GitHub's user namespace is **global and first-come**. `@qa-lead`, `@dev-lead`,
> `@scrum-master`, `@business-analyst` and `@murat` are **all real, live GitHub
> accounts today** — none of them ours. A workflow keying on
> `contains(body, '@qa-lead')` would fire correctly and look perfectly healthy
> while every mention publicly tagged a stranger and sent them a notification,
> from a fleet of bots, across public repos. The failure is silent on our side
> and only visible on theirs.

An org team slug lives in the org's namespace and cannot collide. It also buys
two things a bare convention cannot:

- **Autocomplete** — typing `@petry-projects/` in any GitHub comment box lists
  every persona. The addressing scheme *is* the discovery mechanism.
- **A real link** — the mention renders as a resolvable team, not grey text.

**Rules:**

1. **`handle` is `org/team-slug`, and the slug MUST equal `id`.** Routing is
   then a prefix-strip, and "register once" holds: the role name is written in
   exactly one place.
2. **The team MUST be `privacy: closed`.** Secret teams cannot be mentioned at
   all; closed teams are mentionable by org members.
3. **The team MUST set `notification_setting: notifications_disabled`.** The
   handle exists to route a webhook, not to page humans. Membership should be
   empty or bot-only.
4. **Handles are unique across all personas — by construction, not by check.**
   The org is pinned by the pattern, the slug equals `id`, `id` equals the
   persona's directory name, and directory names are unique. Two personas
   therefore *cannot* claim the same handle, so there is deliberately no
   cross-file uniqueness check: it could never fire.

### 4.1.1 Renames — and why there is no `aliases`

An earlier draft of this standard let a persona declare `address.aliases[]` so a
**renamed** role kept routing (`qa-lead` listing `petry-projects/murat`). That
field is gone. Two reasons, one structural and one measured:

- **Index-free routing could never have honoured it.** The router resolves
  `@petry-projects/murat` to `personas/murat/persona.yml` — a 404 after the
  rename. The alias is declared *inside the renamed persona's own manifest*,
  which the router never opens, because it does not know to look there.
- **There is nothing live left to route.** GitHub stops rendering a renamed
  team's old handle as a mention at all — it becomes plain text. Measured:

  ```text
  before rename:  <a class="team-mention" …>@petry-projects/probe</a>
  after rename:   <p>@petry-projects/probe please review</p>
  ```

  So the old handle is not a silently-broken mention that looks live — the
  reader sees grey text and knows instantly it did not resolve. The fix is
  obvious and local: mention the new handle.

**To rename a role:** rename the persona directory, `id`, `name`, `canary.agent`,
`opt_out_label`, `evals.path`, and the org team (its slug must keep matching
`id`). In-flight mentions of the old handle stop resolving, visibly — which is
the correct signal, not a regression. See
[`.github#755`](https://github.com/petry-projects/.github/issues/755) finding 1.

The **live** properties (rules 2 and 3 — does the team exist, is it closed, are
notifications off?) need the network, and `validate-personas.py` is hermetic
with a hermetic test suite. They are verified by a separate CI step and are a
line in the §7 Definition of Done — deliberately **not** in the validator, whose
hermeticity is worth more than the check.

Mention handling is centralised: one router resolves the handle, consults that
persona's own trigger matrix, applies the trust floor and `opt_out_label`, and
dispatches. Personas do **not** each ship a mention workflow — that is the
per-agent drift the manifest exists to prevent.

The router is
[`persona-mention-reusable.yml`](../.github/workflows/persona-mention-reusable.yml),
its decision core is
[`scripts/lib/persona-mention.sh`](../scripts/lib/persona-mention.sh) (pure and
network-free, so `tests/persona_mention.bats` pins the guards without API
access), and repos adopt it by copying the one stub
[`standards/workflows/persona-mention.yml`](workflows/persona-mention.yml).

**There is no persona index, by design.** Because `address.handle`'s slug MUST
equal `id` (rule 1) and `id` MUST equal the persona's directory name, a handle
resolves to `personas/<slug>/persona.yml` by convention — the manifest is the
index-of-record (§1.1), so nothing derives, caches, or duplicates it. A 404 is a
meaningful answer: "not a persona". That is also how a real, non-persona team
(`@petry-projects/org-leads`) falls through harmlessly rather than erroring.

> **Recursion is the hazard here.** Agent comments posted via a PAT re-trigger
> workflows (unlike `GITHUB_TOKEN`), and `.github-private#860` burned 1,481
> identical acks in 4.5 hours from a *single* self-loop. With N mutually
> addressable personas the cycles are combinatorial, not self-loops: `qa-lead`
> answering a thread that mentions `dev-lead` is enough. Every router MUST
> exclude on two independent axes — the **bot actor** and an
> **agent-comment marker** — as `pr-review-mention.yml` already does.

---

## 5. Trust, permissions, and safety

- **Trust floor** — set `trust.author_association_floor`; per-surface
  `trust_floor` may tighten it but never loosen below it.
- **Permissions superset** — if the persona ships a caller stub + reusable,
  `runtime.permissions` records the full set the reusable requests, and the
  **caller stub MUST grant a superset** or the whole fleet fails with
  `startup_failure` (`ci-standards.md`). The stub carries the standard
  `SOURCE OF TRUTH` header, `secrets: inherit`, and channel-tag pin.
- **Immutable files** — a persona never modifies the files in
  [`workflow-exemptions.json`](workflow-exemptions.json) (currently
  `agent-shield.yml`).
- **AgentShield** — every definition layer is subject to the AgentShield scan;
  a persona that fails the scan cannot be onboarded.

### 5.1 Runtime identity — the account a persona acts as

A persona's **identity** is the GitHub account it authenticates as at runtime —
the login it commits, pushes, reviews, or comments as, plus the Actions secret
holding that account's PAT. Declare it in `runtime.identity`:

```yaml
runtime:
  identity:
    account: don-petry        # the login this persona ACTS AS
    credential: GH_PAT_DON_PETRY   # the Actions secret holding its PAT
```

**Identity is not the address handle.** `address.handle` (§4.1) is the org *team*
a human `@`-mentions to *route* work; `runtime.identity.account` is the *account*
that *does* the work. They are orthogonal: a persona addressed as
`@petry-projects/dev-lead` may act as `don-petry`.

**Why it is declarative and per-persona.** Before this field, every write persona
derived its account from one shared `vars.BOT_USER` variable. Two personas that
must act as *different* accounts (dev-lead as `don-petry`, pr-review as the
review-only machine user `donpetry-bot`) shared that one variable, so setting it
for one silently changed the other — a real regression where dev-lead began
committing as the review bot. A per-persona `identity` makes collisions
impossible: the runtime resolves `BOT_USER` from `identity.account`, and CI
asserts the workflow's credential reference matches `identity.credential`.

**Credential naming.** Secrets follow `GH_PAT_<ACCOUNT>[_<QUALIFIER>]`, where
`<ACCOUNT>` is the login upper-snake-cased (`don-petry` → `GH_PAT_DON_PETRY`);
`<QUALIFIER>` distinguishes multiple PATs for one account (e.g.
`GH_PAT_DON_PETRY_COPILOT`). Pre-existing account-named secrets such as
`DON_PETRY_BOT_GH_PAT` are grandfathered.

---

## 6. Canary onboarding (the last step)

Rollout is unchanged from the existing model (`ci-standards.md` §Canary rings,
`canary-rings.json`, `scripts/canary-rollout.sh`) — the persona standard only
makes the **registration** a single action.

1. **Cut** an immutable `<id>/vX.Y.Z` at a merged, CI-passed commit on the host.
2. **Register once — but ONLY if the persona ships its own reusable.** Add one
   entry under `agents.<id>` in [`canary-rings.json`](canary-rings.json): `host`,
   `reusable`, `run_workflow`, `rings[]`, `gate`. This is the **only** place ring
   membership is written.

   > **A shared-runtime persona is NOT registered.** Per ADR-0006 (in
   > `.github-private` `docs/architecture/adr/`), a persona served wholly by the
   > shared persona runtime — the `persona-mention` router dispatching to
   > `persona-runner` — has no dedicated reusable and **no caller pins a
   > per-persona channel tag**, so a ring promotion would advance a tag nothing
   > reads. Such a persona MUST NOT appear in `canary-rings.json`; a registered
   > id is a defect, not a promotion. Its rollout is the runtime's rollout, and
   > its promotion evidence is the reach check (step 4 below), not a ring label.
   > Steps 1, 2, 3 and the ring soak in step 4 apply only to a persona with its
   > own reusable.
3. **Point the manifest at it** — for a registered persona, `persona.yml`'s
   `canary.agent` MUST equal `<id>` and `canary.registry` MUST reference
   `canary-rings.json`; the manifest restates nothing from the registry. A
   shared-runtime persona **omits the `canary` block entirely** (it is optional
   in `persona.schema.json`) rather than pointing at an entry that does not
   exist.
4. **Stage outward** one ring at a time — `next → ring0 → ring1 → stable` — each
   a single central channel-tag move, gated by the soak/dwell defaults in the
   registry. Roll back by moving the tag to the prior immutable `vX.Y.Z`.

   > For a **shared-runtime** persona there is no per-persona tag to stage.
   > `status` advances in the manifest, and the evidence that a promotion is real
   > is `scripts/persona_reach_check.sh` (in `.github-private`) plus a live
   > mention that resolves to the persona — never a ring label. Which repos can
   > reach it is governed by the `persona-mention` router's own rings. Roll back
   > with an ordinary revert PR.
5. **Eval gate** — the persona's `evals.path` must exist and pass by
   `evals.required_before` (recommended: `stable`).

### Single source of truth for rings

`canary-rings.json` (public, in `.github`) is the **only hand-authored** ring
registry. Because all org repos are public, there is no topology to hide, so:

- `.github-private` `release/registry.yml` is **derived from**
  `canary-rings.json`, not maintained alongside it. Do not add a persona to both
  by hand.
- `stable`'s `"*"` member is **resolved at runtime** (all org repos minus the
  repos named in earlier rings). New consumers that adopt the caller stub join
  the `stable` ring automatically; they need not be enumerated.

This eliminates the historical drift between the two registries (divergent
`run_workflow` names and soak encodings) by construction.

---

## 7. Definition of Done — the onboarding checklist

A persona is "done" (ready for `stable`) when all of the following are true:

- [ ] `personas/<id>/persona.yml` exists and validates against `persona.schema.json`.
- [ ] `definition.layers[]` names every implementing layer; framework layers pin
      a `vendor_pin` matching the framework's `VENDOR.md`, and any local override
      sets `upstream_candidate` truthfully.
- [ ] `id` and `name` are the **role**, not a person (§1.6); upstream agents are
      referenced only by `framework.skill`.
- [ ] `triggers` fills one row per surface the persona acts on; `default_mode`
      is `advisory`/`off`; every `write` surface has a `gate_label`; an
      `opt_out_label` is defined.
- [ ] `personas/<id>/interaction.yml` exists and declares the persona's
      **human-hold brakes** as a valid `stop_markers` list — an array of
      non-empty strings (§4 rule 4). Every surface, including the mention router,
      derives its brakes from this contract, so a persona without it cannot be
      routed by label-backed mentions.
- [ ] If the `mention` surface is enabled: `address.handle` is an **org team**
      whose slug equals `id`; the team exists, is `privacy: closed`, and sets
      `notification_setting: notifications_disabled`; the handle and every alias
      are unique fleet-wide (§4.1).
- [ ] `trust.author_association_floor` is set; write surfaces gate on it.
- [ ] If it ships a reusable: caller stub grants a **superset** of
      `runtime.permissions`, carries the `SOURCE OF TRUTH` header, and pins a
      channel tag.
- [ ] If it ships a reusable: `runtime.identity` declares the `account` the
      persona acts as and the `credential` secret holding its PAT; the credential
      follows `GH_PAT_<ACCOUNT>[_<QUALIFIER>]` (or is a grandfathered
      account-named secret), and the runtime workflow resolves `BOT_USER` from
      the account (§5.1).
- [ ] AgentShield passes on all layers; no immutable file is touched.
- [ ] `evals/<id>/` holds `dev/` + `holdout/` splits with ≥ `evals.min_cases`
      held-out cases; `validate-cases.py` passes and the eval gate is green.
- [ ] **If the persona ships its own reusable:** exactly one `agents.<id>` entry
      exists in `canary-rings.json`; `persona.yml` `canary.agent` points at it and
      restates nothing; and the persona has soaked `next → ring0 → ring1` before
      `stable`.
- [ ] **If the persona rides the shared runtime (ADR-0006):** there is **no**
      `agents.<id>` entry and **no** `canary` block; `scripts/persona_reach_check.sh`
      passes for the persona at its declared `status`; and a live
      `@petry-projects/<id>` mention has been observed resolving to it.

Copy [`standards/personas/TEMPLATE/`](personas/TEMPLATE/) to start; the worked
example is **QA Lead** (`personas/qa-lead/` in `.github-private`), which wraps
the vendored `bmad-test-architecture` agent (`framework.skill: bmad-tea`).

---

## 8. References

- [`agent-standards.md`](agent-standards.md) — required agent files, AgentShield, immutable files
- [`ci-standards.md`](ci-standards.md) — stub/reusable tiers, channel-tag versioning, canary rings, trigger labels
- [`canary-rings.json`](canary-rings.json) — the ring registry (single source of truth)
- [`github-settings.md`](github-settings.md) — canonical label taxonomy
- [`personas/persona.schema.json`](personas/persona.schema.json) — the manifest schema
- [`personas/TEMPLATE/`](personas/TEMPLATE/) — copy-me scaffold
