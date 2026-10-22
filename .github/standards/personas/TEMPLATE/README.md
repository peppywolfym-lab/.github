# Persona scaffold — copy me

Copy `persona.yml` into **`.github-private/personas/<id>/`** to onboard a new
agentic persona. It is governed by
[`standards/persona-standards.md`](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md)
and validated against
[`persona.schema.json`](https://github.com/petry-projects/.github/blob/main/standards/personas/persona.schema.json).
(Links are absolute so they still resolve after this file is copied into the
`.github-private` repo.)

## What's here

```text
persona.yml            # the manifest (index-of-record) — fill every CHANGE-ME
README.md              # this file — replace with a short note about your persona
evals/                 # STARTER dev/ + holdout/ pair — copy it OUT to the repo
                       #   eval tree (see below); do not keep it in personas/<id>/
```

A persona **instance directory** (`.github-private/personas/<id>/`) holds only
`persona.yml` + `README.md`. Every implementation layer lives in its **canonical
repo-level home**, and the manifest just points at it:

| Layer | Canonical home (in `.github-private`) |
|---|---|
| Framework agent | `frameworks/<framework>/…` (vendored) |
| Copilot profile | `agents/<id>.md` |
| Workflow prompt library | `prompts/<id>/` |
| Eval set | `evals/<id>/` (`dev/` + `holdout/`) |

Author those files directly in their homes — don't nest `agents/` or `prompts/`
inside `personas/<id>/`.

## Onboarding order

1. **Copy & rename.** `cp standards/personas/TEMPLATE/persona.yml .github-private/personas/<id>/persona.yml` (and add a short `README.md`).
   Pick `<id>` as a **role** — `qa-lead`, not a person name, even if the agent
   you are wrapping has one upstream ([§1.6](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md)).
2. **Pick your definition layer(s)** in `persona.yml` `definition.layers[]`, each
   `path` pointing at its canonical home above. Prefer wrapping a vendored
   framework agent where a good upstream exists (pin `vendor_pin` to its
   `VENDOR.md`); layer local behavior via `local_overrides`, never by
   hand-editing `frameworks/`. A Copilot profile goes at
   `.github-private/agents/<id>.md`; a prompt library at
   `.github-private/prompts/<id>/`.
3. **Fill the trigger matrix.** One row per surface. `default_mode: advisory`.
   Every `write` surface needs a `gate_label`. Define an `opt_out_label`.
4. **Set the trust floor** (`[OWNER, MEMBER, COLLABORATOR]` unless you have a
   reason to differ).
5. **If the `mention` surface is enabled, fill `address`** and create the org
   team `petry-projects/<id>` — `privacy: closed`,
   `notification_setting: notifications_disabled`, membership empty or bot-only.
   The handle **must** be a team; a bare `@<role>` is a real stranger's account
   ([§4.1](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md)).
6. **Add evals.** Copy the `evals/` starter into `.github-private` `evals/<id>/`:
   ≥ `min_cases` held-out cases under `evals/<id>/holdout/` and proposer-visible
   cases under `evals/<id>/dev/`. See `.github-private` `evals/README.md`.
7. **Register the canary entry** — one `agents.<id>` block in
   `standards/canary-rings.json` (the *only* place rings are written). Point
   `persona.yml` `canary.agent` at it.
8. **Validate & scan.** Manifest validates against the schema; AgentShield passes;
   no immutable file touched.
9. **Roll out** `next → ring0 → ring1 → stable`, eval gate green before `stable`.

The full gate is the **Definition of Done** checklist in
[`persona-standards.md` §7](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md).

## Worked example

**QA Lead** (`.github-private/personas/qa-lead/`) wraps the vendored
`bmad-test-architecture` agent (`framework.skill: bmad-tea`) — the reference for
the *wrap-a-vendored-agent*, advisory-everywhere path.

Note the naming: the persona is `qa-lead`, the **role**, even though the
upstream framework gives that agent a person-name. Roles are legible in a PR
comment, survive swapping the agent underneath, and keep one namespace across
the fleet. See [§1.6](https://github.com/petry-projects/.github/blob/main/standards/persona-standards.md).
