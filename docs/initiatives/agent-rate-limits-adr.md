# ADR: Agent Rate-Limit & Circuit-Breaker Taxonomy (mechanism + policy decision)

- **Status:** Proposed (pending human sign-off on §6 numbers, §7 token-breaker threshold, and the §9 cost cap)
- **Date:** 2026-08-21
- **Epic:** [#636](https://github.com/petry-projects/.github/issues/636)
- **Story:** [#637](https://github.com/petry-projects/.github/issues/637) — Phase 1 (decision record only)
- **Scope of this story:** documentation only. **No** workflow, config file, repo
  setting, or org policy is mutated here (AC #1).

This ADR pins down *how* an org can bound agentic throughput — per-agent-type
controls, a token-budget circuit breaker, the telemetry that feeds them, and the
public/private enforcement boundary — so the follow-on stories (config
single-source-of-truth, source-side gate, and the two wiring stories) encode a
**verified** mechanism instead of guessing APIs or baking in unconfirmed numbers.
It deliberately mirrors the proven staging of the Pull-Request-Limits ADR
([`docs/initiatives/pull-request-limits-adr.md`](pull-request-limits-adr.md),
epic #505 → ADR #506 → config #507 → apply path #508).

---

## 1. Context — why this decision is needed (AC #1)

Agentic automation in this org runs on a schedule and on event fan-out with **no
throughput ceiling of its own.** Three production incidents are the measured
baseline this standard must prevent — cited here as symptoms of missing
throughput controls, **not** as bugs to fix in this story:

| Incident | Symptom | Root cause class |
|---|---|---|
| [#402](https://github.com/petry-projects/.github/issues/402) | A concurrency-group `cancel-in-progress` cancelled in-flight dev-lead issue pickups → **111 stuck issues**. | A single-lane serializer used as if it were a queue; cancellation instead of back-pressure. |
| [#443](https://github.com/petry-projects/.github/issues/443) | Dispatch race between event and schedule fan-out. | No cooldown / de-dupe between overlapping triggers. |
| [#571](https://github.com/petry-projects/.github/issues/571) | feature-ideation zero-job dispatch (reusable `with:` referencing `inputs` on an event where the job is gated off). | No admission/gating discipline around dispatch. |

The external framing is **OWASP ASI08 — Denial of Service & Resource
Exhaustion** (OWASP Top 10 for Agentic Applications, 2026): an agent fleet with
no self-imposed rate limit can exhaust a shared, finite resource — here the
**fixed 5-hour Claude subscription budget** (§4.1) shared across every
Claude-backed agent — and starve the very pipeline that would repair it (the self-hosting
circular dependency already documented in
[`docs/initiatives/agent-canary-rings-adr.md`](agent-canary-rings-adr.md)).

The planner's working assumption was that GitHub or the Claude platform ships a
first-party "per-workflow rate limiter" and a "5-hour budget %" surface, and that
we just need to find the API. **This ADR's first job was to verify that
assumption against the vendors' own docs rather than guess** (org standard: *"SHAs
for action pinning must be looked up via the GitHub API — never guessed"*,
[CLAUDE.md](../../CLAUDE.md); the same skepticism applies to any API surface —
[AGENTS.md](../../AGENTS.md)).

---

## 2. Decision (summary)

1. **In scope: four agent types** — `dev-lead`, `compliance-audit`,
   `feature-ideation`, `initiative-driver` — each bounded on five control
   dimensions: **max concurrent runs, max runtime, cooldown between runs, daily
   execution budget, and a consecutive-failure circuit breaker**
   (open → backoff → half-open). See §5 for the taxonomy and §6 for the proposed
   values (proposals, not final).
2. **GitHub exposes no native per-workflow rate limiter and no run-count budget.**
   Verified first-hand (§4): the `concurrency:` key is a **single-lane
   serializer**, not a rate limiter — it caps *simultaneity*, not *rate over a
   window*, and its `cancel-in-progress` is exactly the lever that caused #402.
   There is no repo/org setting or ruleset rule that caps runs-per-hour or
   runs-per-day. Therefore the per-agent-type controls are **source-side**, in the
   dispatch/engine layer, not a GitHub toggle — the same conclusion the
   PR-Limits ADR reached for open-PR caps.
3. **Claude's *documented* API surfaces do not expose the subscription
   budget — but an undocumented OAuth endpoint does.** Verified first-hand (§4):
   the Messages API exposes only **per-minute** token-bucket limits via
   `anthropic-ratelimit-*` response headers, and the Rate Limits API returns
   *configured* ceilings. Neither reports the subscription window. Two axes are
   easy to conflate here, so state them separately:
   - **Quota scope** — what the number describes. The Messages API headers
     describe a **per-minute, per-API-key** token bucket; the Rate Limits API
     describes **organization/workspace-level** *configured* ceilings. Neither
     describes the **subscription usage window** the fleet actually shares.
   - **Credential type** — what authenticates the read. The Messages API headers
     come back on a normal API-key call; the Rate Limits API accepts an **Admin
     API key or an OAuth token carrying `org:admin`**. Neither is satisfied by the
     subscription-backed `CLAUDE_CODE_OAUTH_TOKEN` the org's agents actually
     authenticate with (verified in the workflow stubs, §3).

   So the documented surfaces are the wrong scope *and* the wrong credential; the
   undocumented OAuth endpoint is the only one that is both subscription-scoped
   and readable with the credential the fleet already holds. That gap is closed by `GET https://api.anthropic.com/api/oauth/usage`
   (§4.1) — the subscription-OAuth-scoped endpoint backing Claude Code's `/usage`
   view. It was probed first-hand (HTTP 200, live window state, 2026-08-20) using
   the same token class the fleet already holds, and returns **both** the 5-hour
   and the 7-day windows with server-computed severity and exact reset timestamps.
   It is **undocumented and unsupported**, which dictates the adapter boundary and
   fail-safe below — not avoidance.
4. **The breaker's telemetry is therefore *queried*, with a *derived* fallback.**
   The §4.1 endpoint is the **source of record**. Because it is undocumented,
   every read goes through a small adapter, and a **derived ledger** in the private
   engine (`petry-projects/.github-private` `scripts/engine.sh`, subscription-cap
   handling, [#206](https://github.com/petry-projects/.github/issues/206)) is
   retained as the documented **degraded path** for when the endpoint is
   unavailable or changes shape. An estimate is strictly worse than an
   authoritative server-side percentage, so it is the fallback, never the primary.
   Enforcement still splits across a **public standard/gate** (this epic) and a
   **private companion change** (§8), because the credential and the poller live
   private.
5. **Not every limit is a fleet-stop.** The endpoint distinguishes account-wide
   windows (`session`, `weekly_all`) from **per-model** windows (`weekly_scoped`).
   Only account-wide windows are pause-worthy; a scoped exhaustion is handled by
   the engine's existing model-fallback chain — swap models, do not stop the fleet.
   The probe caught exactly this case: one model's weekly bucket at
   100%/critical/active while the account-wide weekly window sat at 85%.
6. All numeric values in §6, the §7 thresholds, and the §9 cost cap are
   **proposals pending human sign-off**, not final numbers.

---

## 3. In-scope agent types (AC #2)

Each is a real, deployed org automation whose caller stub was read first-hand for
this ADR (paths below). The "where behavior/concurrency lives today" column is
where the enforceable control must land given §2.2 (no GitHub-side surface).

| Agent type | Caller (this repo) | Trigger surface | Where behavior/concurrency lives today | Auth |
|---|---|---|---|---|
| **dev-lead** | [`standards/workflows/dev-lead.yml`](../../standards/workflows/dev-lead.yml) | PR / review / comment / `issues: labeled` / `check_run` / `repository_dispatch` | Reusable `dev-lead-reusable.yml` (private): per-issue / per-PR concurrency lanes added after #402 | `CLAUDE_CODE_OAUTH_TOKEN` |
| **compliance-audit** | [`.github/workflows/compliance-audit-and-improvement.yml`](../../.github/workflows/compliance-audit-and-improvement.yml) | weekly `schedule` (Fri 12:00 UTC) + `workflow_dispatch` | `concurrency: compliance-audit`, `cancel-in-progress: false`; `audit` job `timeout-minutes: 30` | `ORG_SCORECARD_TOKEN` (deterministic job) + Claude phase |
| **feature-ideation** | [`standards/workflows/feature-ideation.yml`](../../standards/workflows/feature-ideation.yml) | weekly `schedule` (Fri 07:00 UTC) + `workflow_dispatch` + `discussion` | `concurrency: feature-ideation`, `cancel-in-progress: false`; `prep`/`redispatch` `timeout-minutes: 5` | `CLAUDE_CODE_OAUTH_TOKEN` |
| **initiative-driver** | [`standards/workflows/initiative-driver.yml`](../../standards/workflows/initiative-driver.yml) | `issues: [closed, labeled]` + off-peak `schedule` + `workflow_dispatch` | per-repo `concurrency` lane, `cancel-in-progress: true`; dispatch job `timeout-minutes: 5`; **max-in-flight lives in the central driver** (private) | dispatch-only stub; Claude runs in dev-lead it hands off to |

Two facts from this table shape the whole design:

- **The controllable throttle points are already partly in place but are the
  *wrong kind*** — `concurrency` groups bound simultaneity, and `timeout-minutes`
  bounds a single run's wall-clock. Neither bounds *rate over time*, *cooldown*,
  or *daily budget*, and `cancel-in-progress` actively harms (§1, #402).
- **initiative-driver itself runs no LLM** (pure-bash dispatcher); its cost is
  the **dev-lead fan-out it triggers.** Its control dimension is therefore a
  **dispatch budget** (how many sub-issues it releases per window), enforced in
  the central driver, not a per-run LLM budget.

---

## 4. Mechanism research — what the vendors actually expose (AC #4)

Every surface below was fetched **first-hand** during this story (2026-08-21) and
read for a field that caps *rate over a window* or exposes a *5-hour budget*.

| Surface | Source consulted | Result |
|---|---|---|
| **GitHub Actions `concurrency`** | [Using concurrency](https://docs.github.com/en/actions/using-jobs/using-concurrency) | Controls **simultaneous execution only.** The key ensures "only one workflow or job with that key runs at any given time"; `cancel-in-progress` cancels the in-flight run (the #402 lever); `queue: max` allows up to 100 *pending* runs FIFO. **No per-hour/daily execution budget, no run-count-over-time limit, no cost/token telemetry.** |
| **Claude Messages API rate limits** | [Rate limits](https://platform.claude.com/docs/en/api/rate-limits) | Two limit types: **monthly spend cap** and **per-minute** rate limits (RPM / ITPM / OTPM) via a **token-bucket** (continuously replenished, *not* fixed-window). Exposes `anthropic-ratelimit-{requests,tokens,input-tokens,output-tokens}-{limit,remaining,reset}` response headers (reset = RFC 3339) and `retry-after` on 429. **No 5-hour window; no rolling-budget-% surface.** |
| **Claude Rate Limits API** | [Rate Limits API](https://platform.claude.com/docs/en/manage-claude/rate-limits-api) | Reads the org/workspace's *configured* limits programmatically. Returns configured ceilings, **not** live remaining budget for a 5-hour window. |
| **Claude Pro/Max subscription usage** | [Using Claude Code with your Pro/Max plan](https://support.claude.com/en/articles/11145838-using-claude-code-with-your-pro-or-max-plan) | Confirms "usage limits … shared across Claude and Claude Code" and an **interactive** `/status` command that shows "remaining allocation." **No programmatic endpoint is *documented*** — but the interactive view is served by one (next row). |
| **OAuth usage endpoint** (undocumented) | **Probed first-hand 2026-08-20 — HTTP 200, live window state.** No doc page exists; this is the surface behind Claude Code's `/usage` view. | **Reports the subscription windows directly** — 5-hour, 7-day, and per-model — scoped to the subscription OAuth token, with `percent`, server-computed `severity`, and exact `resets_at`. **This is the source of record (§4.1).** |

**Conclusion (AC #4):** there is **no native GitHub surface** for per-workflow
rate limiting — that half of §2.2 stands. For Claude, the *documented* surfaces do
not report the subscription budget, but a **first-hand-verified undocumented
endpoint does**, and it is the telemetry source of record.

### 4.1 Telemetry source of record — the OAuth usage endpoint

```http
GET https://api.anthropic.com/api/oauth/usage
  Authorization: Bearer <CLAUDE_CODE_OAUTH_TOKEN>
  anthropic-beta: oauth-2025-04-20
  User-Agent: claude-code/<version>
```

Probed first-hand on **2026-08-20: HTTP 200 with live window state.** This is the
data behind Claude Code's `/usage` view. It resolves the exact gap the rows above
identify: `anthropic-ratelimit-*` headers are per-minute and **API-key-scoped**,
whereas this endpoint is **subscription-OAuth-scoped** — it authenticates with the
same `CLAUDE_CODE_OAUTH_TOKEN` the fleet already holds and reports the windows
that actually bind the fleet.

Contract notes that follow-on stories must honour:

- **The `User-Agent` is load-bearing, not cosmetic.** Without a
  `claude-code/<version>` value the caller lands in an aggressively rate-limited
  bucket and receives persistent 429s. Rate limiting is **per access token**, not
  per account; polling at **≥180 s** is safe, so an hourly poller sits far inside
  budget.
- **Prefer the `limits[]` array over the flattened `five_hour` / `seven_day`
  keys.** Each entry is `{ kind, group, percent, severity, resets_at, is_active }`
  where `kind` ∈ `session` (5-hour), `weekly_all` (7-day), `weekly_scoped`
  (per-model). The server-computed `severity` (`normal` / `warning` / `critical`)
  gives the gate a graded signal instead of re-deriving one from a bare number.
  Treat the flattened keys as the fallback for older response shapes.
- **These are FIXED windows, not sliding ones — this is the document's single
  window model.** Each `limits[]` entry carries an authoritative `resets_at`: the
  window opens on first use, accumulates until that instant, and empties at it.
  Old usage does **not** age out continuously. Two consequences the rest of this
  ADR depends on: (a) within one window `percent` is **monotonically
  non-decreasing**, so it can never dip back below a threshold on its own; and
  (b) the only event that lowers `percent` is the reset at `resets_at`. Wherever
  a per-minute API bucket is meant instead (§4.2's `anthropic-ratelimit-*`
  token-bucket, which *is* continuously replenished), it is named as such
  explicitly. Do not describe the `session` or `weekly_all` windows as "rolling".
- **`resets_at` is authoritative.** All time-until-reset arithmetic derives from
  this field — never a hardcoded weekday, cron expression, or timezone constant —
  so behaviour self-corrects if the window ever shifts. (The probe returned
  `2026-08-25T15:59:59Z` for the weekly window, i.e. Tuesday ~11:00
  America/Chicago, matching the maintainer's understanding without being
  configured anywhere.)
- **`weekly_scoped` must never trip a fleet pause** (§2.5). Only `session` and
  `weekly_all` are pause-worthy.
- **Both breakers share one call.** The 5-hour breaker (Phase 5) and the 7-day
  glide-path breaker (Phase 6) read `session` and `weekly_all` from the same
  response, behind one adapter.

**Degraded path (retained, demoted).** Because the endpoint is undocumented and
unsupported, it can change shape or disappear. The fallback is the **derived
ledger** in the private engine: `scripts/engine.sh` (which already handles the
subscription cap, #206) records per-run token consumption and rate-limit
timestamps into a private rolling-window ledger. The adapter prefers the endpoint
and falls back to the ledger; the ledger is an estimate and is never the primary
source. **Known modelling mismatch, and its direction.** That ledger is a
*sliding* window, while the real budget is a *fixed* one (§4.1). The ledger's
**horizon and usage scope must be specified before its error direction can be
relied on as a safety argument**, because the two plausible designs fail in
opposite directions:

- **Trailing same-duration horizon (the naive design): over-estimates.** At time
  `t` a trailing 5-hour ledger covers `[t-5h, t]`, whereas the live fixed window
  covers `[window_open, t]`. Since a fixed window is at most 5h long,
  `window_open >= t-5h`, so the trailing span is a **superset**: it contains all
  current-window usage *plus* residual usage from the previous window. It
  therefore reads **high** before `resets_at`, not low. That fails toward
  *blocking* dispatch — the opposite of §7's fail-safe direction, and a
  conservative-but-wrong bias that could pause a fleet that still has budget.
- **`resets_at`-anchored horizon (required): matches.** Anchoring accumulation to
  the last observed `resets_at` and discarding everything before it makes the
  ledger span the same interval as the real window, removing the bias.

**Therefore the ledger MUST be `resets_at`-anchored**, not a naive trailing
window, and must record which usage sources it counts. Where no `resets_at` has
ever been observed, the ledger is explicitly an over-estimate and must be treated
as advisory only — never as authoritative grounds for tripping a breaker. Where an agent path uses an **API key** rather than the subscription
token, `anthropic-ratelimit-tokens-remaining` remains the authoritative live
signal for that path.

**Open verification (carried, not closed).** The probe used a short-lived OAuth
access token from a local credential store; CI authenticates with the long-lived
`claude setup-token` credential. Both are OAuth-issued and share the
`sk-ant-oat01-` prefix, so acceptance is likely but **unproven**. It is verified by
running the poller in **dry-run in CI against the existing secret** — *not* by
minting a fresh setup-token, which risks invalidating the credential the fleet
currently runs on. If the long-lived token is rejected, the fallback is a
dedicated short-lived credential refreshed by the workflow, a materially larger
change that should be re-scoped before implementation.

---

## 5. Per-agent-type control taxonomy (AC #2)

Five control dimensions per agent type. Definitions (uniform across types):

- **Max concurrent runs** — hard cap on simultaneous runs of this agent type.
  Implemented as a *counted* admission check, **not** a `cancel-in-progress`
  concurrency group (which cancels, per #402). Over the cap → **defer**, never
  cancel.
- **Max runtime** — wall-clock ceiling per run. `timeout-minutes` is the native,
  verified lever (§3) and is sufficient for this dimension.
- **Cooldown between runs** — minimum quiet interval after a run of this type
  before another may start, to kill dispatch races (#443) and event/schedule
  double-fire.
- **Daily execution budget** — max runs (or, for initiative-driver, max
  dispatches) per rolling 24h, independent of concurrency.
- **Consecutive-failure circuit breaker** — after *N* consecutive failed runs the
  breaker **opens** (no new runs); after a **backoff** it goes **half-open**
  (a single probe run); a passing probe **closes** it, a failing probe re-opens
  with escalated backoff.

| Dimension | dev-lead | compliance-audit | feature-ideation | initiative-driver |
|---|---|---|---|---|
| Max concurrent runs | per-issue / per-PR lane (already) + a global type cap | 1 (already single-lane, non-cancelling) | 1 (already single-lane, non-cancelling) | 1 dispatch lane per repo (already) |
| Max runtime | per-run `timeout-minutes` (add to reusable) | 30 min audit job (already) | 5 min prep; add cap to `ideate` | 5 min dispatch (already) |
| Cooldown between runs | between issue pickups | n/a (weekly cron) | n/a (weekly cron) | between close-event + schedule fan-out (directly targets #443) |
| Daily execution budget | runs/day cap | n/a (weekly) | n/a (weekly) | **dispatches/day** (bounds the dev-lead fan-out it causes) |
| Consecutive-failure breaker | open→backoff→half-open | same | same | same |

Cells marked "already" are existing, verified levers (§3); the standard's job is
to make them **uniform, named, and single-sourced**, and to add the missing
dimensions (global concurrency cap, cooldown, daily budget, failure breaker) at
the source layer.

---

## 6. Proposed values — PROPOSALS, NOT FINAL (AC #2)

> Everything here is a **proposal pending human sign-off** (epic #636 gate),
> anchored to the §1 baseline and current cadence — not to any vendor-imposed
> maximum (none exists, §4).

| Dimension | dev-lead | compliance-audit | feature-ideation | initiative-driver |
|---|---|---|---|---|
| Max concurrent runs | 3–4 global | 1 | 1 | 1 / repo |
| Max runtime | 30 min | 30 min (keep) | 20 min | 5 min (keep) |
| Cooldown | 2–5 min between pickups | n/a | n/a | 10 min |
| Daily budget | 40–60 runs/day | 1 (weekly) | 1 (weekly) | 20 dispatches/day |
| Failure breaker | open after 3 consecutive; backoff 30 min → half-open | 3 → 60 min | 3 → 60 min | 3 → 30 min |

Final values, and whether dev-lead's cap is global vs. per-repo, are **deferred to
human sign-off** before the config story.

---

## 7. Token-budget circuit breaker (AC #3)

The dimension the discussion specifically requested, distinct from the
per-agent-type breaker in §5.

- **Trigger (5-hour window, `session`):** pause **new agentic dispatch** when the
  **5-hour Claude subscription budget** reaches a **configurable threshold
  (default 90%)** of consumed budget. The window is the subscription's own
  **fixed** 5-hour session window (§4.1) — accumulating until `resets_at` — not a
  continuously-replenished per-minute API bucket.
- **Trigger (7-day window, `weekly_all`):** pause when the weekly budget crosses a
  threshold that **tightens as the reset approaches**, reserving a configurable
  share of the budget per remaining day:

  ```text
  pause when  weekly_all.percent  >=  100 - (reserve_pct_per_day * days_until_reset)
  ```

  With `reserve_pct_per_day = 2` (proposal) that is 98% the day before reset, 96%
  two days before, down to an 86% floor immediately after a reset. `days_until_reset`
  derives from `resets_at` (§4.1) with partial days rounding **up**. The floor is the
  "don't spend the whole week on day one" guard; the near-100% ceiling on reset day
  is deliberate, since a budget minutes from refilling needs no protection. The two
  triggers are orthogonal: the 5-hour breaker bounds a *burst*, the weekly breaker
  bounds the *shape of the week*.
- **Scope guard:** neither trigger fires on `weekly_scoped` (per-model)
  exhaustion — see §2.5.
- **State machine — one rule, derived from the fixed-window model (§4.1).**
  Because `percent` is monotonically non-decreasing inside a window, a utilization
  *dip* cannot occur while the window is open. There is therefore **no dip-based
  half-open state and no percentage resume mark** — such a mark would be
  unreachable by construction. The two breakers close on different events:
  - **5-hour (`session`):** **open** at `percent >= threshold` → hold new
    dispatch; **closed** at the window reset given by `resets_at`. No intermediate
    state.
  - **7-day (`weekly_all`):** **open** while
    `percent >= 100 - (reserve_pct_per_day * days_until_reset)`; **closed** as
    soon as that inequality stops holding. This *can* happen before `resets_at` —
    but never because utilization fell. The glide-path threshold is time-varying
    and **rises** as `days_until_reset` shrinks, so the breaker re-evaluates on
    every poll and may close because **the threshold moved past a static
    `percent`**. It also closes at `resets_at`.

  Re-arming is per-window: a breaker that closed at `resets_at` may trip again in
  the next window under the same rule.
- **Priority on recovery:** when the window drains and dispatch resumes,
  **Claude-backed agents are prioritized** (dev-lead, feature-ideation, and the
  Claude phase of compliance-audit) over lower-value/again-deferrable work, so the
  recovering budget is spent on the pipeline that clears the backlog first.
  initiative-driver dispatch (which *causes* Claude spend downstream) resumes
  after the Claude-backed direct consumers.
- **Telemetry:** the OAuth usage endpoint of §4.1, read through the adapter, with
  the derived private ledger as the documented fallback. Thresholds are read from
  config (the config story), never hardcoded.
- **Fail-safe direction:** stated as behaviour rather than open/closed vocabulary,
  which inverts confusingly. On **telemetry error** — non-200, malformed body, or
  a missing window entry — the breaker **allows dispatch and logs a warning.** An
  outage of an undocumented third-party endpoint must never stop the fleet; that is
  the failure mode this epic exists to prevent, and the engine's reactive exit-2
  fallback (#206) remains the protection of last resort. On a **fresh 429 +
  `retry-after`** the breaker **blocks** — a hard, first-hand signal that the cap
  is already hit.
- **Resume:** the resume triggers are exactly those in the state machine above —
  `resets_at` for the 5-hour breaker; `resets_at` **or** a risen glide-path
  threshold for the weekly breaker. A tripped breaker **never** un-trips on a
  percentage dip, because within a fixed window no such dip exists (§4.1). This is
  the document's only resume rule; §5's per-agent-type breaker and any follow-on
  story (`#641`, `#994`) inherit it verbatim. Where a pause is actuated by a
  persisted switch, the actuator must
  record that *automation* set it, so an automatic resume never clears a pause a
  human set deliberately (see `.github-private#1525`).

The default 90% threshold, `reserve_pct_per_day = 2`, and the exact priority order
are **proposals pending sign-off.** (The previously-proposed **80% resume mark was
removed**, not merely re-tuned: under the fixed-window model it is unreachable —
see the state machine above. Reinstating any percentage-based resume would require
first establishing that the window is sliding, which §4.1's `resets_at` contradicts.)

---

## 8. Cross-repo enforcement boundary (AC #5)

Enforcement splits across two repos. Getting this boundary explicit is the whole
point of a decision record before the config/gate stories.

### 8.1 Lands in the **public** standard/gate (this epic)

- The **standard** (`standards/agent-rate-limits.md`, human-readable) and the
  **single-source-of-truth config** (`standards/agent-rate-limits.json`,
  machine-readable) — the taxonomy of §5, the values of §6, the §7 threshold, the
  §9 metrics/cap. Mirrors the PR-Limits split
  ([`standards/pr-limits.md`](../../standards/pr-limits.md) +
  `standards/pr-limits.json`).
- A **source-side gate library** (`scripts/lib/agent-rate-limit.sh` — the name
  fixed by the Phase 3 story) that reads the config and
  answers admission questions — the per-type concurrency/cooldown/daily-budget
  and failure-breaker checks that need only public inputs (run counts,
  timestamps, failure counters derivable from the GitHub API), analogous to
  [`scripts/lib/pr-limit-gate.sh`](../../scripts/lib/pr-limit-gate.sh).
- The caller stubs in [`standards/workflows/`](../../standards/workflows/) stay
  **thin** (AGENTS.md rule); they gain no new logic — behavior lives in the
  reusable/engine and is promoted centrally via the canary channel
  ([agent-canary-rings-adr](agent-canary-rings-adr.md)).

### 8.2 Requires a **private** companion change (`petry-projects/.github-private`)

- The **token-budget breaker's telemetry** (§4.1/§7): the usage endpoint
  authenticates with `CLAUDE_CODE_OAUTH_TOKEN`, which lives private, so the
  **adapter and the poller** are built there — as is the fallback ledger, since only
  `scripts/engine.sh` sees per-run token usage and the subscription 429s (#206).
  The public gate encodes the *thresholds and policy*; the *live budget read* is
  private.
- **Actuating a fleet-wide pause needs a permission the fleet does not currently
  have.** Writing an **org-level** Actions variable returns
  `403 — must be an org admin or have the actions variables fine-grained
  permission` for a classic token carrying `repo` / `workflow` / `read:org`,
  **even when the caller is already an org admin** (verified 2026-08-20). It
  requires `admin:org` (classic) or the fine-grained org **Variables: write**
  permission. Repo-level variables are writable under plain `repo`. This is a
  genuine new prerequisite, not an existing capability — the fallback is per-repo
  variables at the cost of N writes and a slower fleet-wide stop.
- The **pause switch itself already exists**: `AGENTS_PAUSED=true`, an Actions
  *variable* (visible where secrets are not), delivered by
  `.github-private#1525`. The breaker automates setting and clearing it; it does
  not redesign it.
- **dev-lead's per-issue lanes and the initiative-driver max-in-flight** already
  live in the private reusable/central driver (§3); the new concurrency-cap,
  cooldown, and failure-breaker wiring for those two attach there.
- **Wiring stories** (the two follow-ons after config + gate) are therefore
  cross-repo: one wires the public gate into the private engine's dispatch path;
  the other builds the private 5-hour ledger + proactive breaker and points it at
  the public threshold config.

> **Boundary rule of thumb:** *policy and any control computable from public
> GitHub state* → public gate; *anything that needs the token ledger or the
> subscription 429 stream* → private engine. The public repo owns the numbers and
> the decision; the private repo owns the budget telemetry.

---

## 9. Initiative success metrics & cost cap (AC #6)

Pinned here so Phases 2–5 inherit them (proposals pending sign-off):

### 9.1 Success metrics

- **Zero recurrences** of the #402-class incident: no agent run is ever
  *cancelled* mid-flight by a throughput control (deferral only) → target **0
  stuck-issue events** attributable to concurrency cancellation.
- **No dispatch races** (#443-class) or zero-job dispatches (#571-class) after the
  cooldown/admission discipline lands.
- **Budget headroom:** the 5-hour subscription budget stays **below the §7
  threshold** in normal operation; when it trips, Claude-backed agents recover
  first and the backlog clears without manual intervention.
- **Weekly headroom:** the 7-day budget never exhausts before its reset — the
  glide path leaves usable Claude capacity for humans on every day of the week,
  and a deliberate budget pause is never again diagnosed as a fleet outage
  (`.github-private#1525`).
- **Bounded fan-out:** initiative-driver never releases more than its daily
  dispatch budget, so a single epic cannot flood dev-lead (the §1 fan-out risk).

### 9.2 Operational cost cap the standard installs

- A single, config-declared **org-wide agentic dispatch ceiling** (the aggregate
  daily-budget sum across types) is the standing cost cap. It is expressed in
  `standards/agent-rate-limits.json` and read at run time — changing it is a
  config edit, not a redeploy (mirroring PR-Limits §6.1). The **concrete number is
  deferred to human sign-off**; this ADR fixes only that the cap exists, is
  single-sourced, and is enforced source-side.

---

## 10. Residual gap / what this story could not close (AC #4 honesty)

- **WebSearch was not used;** the four surfaces in §4 were fetched **first-hand**
  via documentation URLs (GitHub Actions concurrency; Claude rate-limits;
  Rate Limits API; Pro/Max subscription support article) and are the basis for the
  decision. The Anthropic docs host redirected `docs.anthropic.com` →
  `platform.claude.com` and `support.anthropic.com` → `support.claude.com`; both
  redirects were followed and the canonical pages read.
- **The telemetry source is undocumented, and that is the standing risk.** §4.1's
  endpoint is real and verified, but it appears on no documentation page and
  carries no compatibility guarantee; it can change shape or disappear without
  notice. Upstream requests for a supported surface are open
  ([anthropics/claude-code#44328](https://github.com/anthropics/claude-code/issues/44328),
  [#32796](https://github.com/anthropics/claude-code/issues/32796)). This is why
  every read is adapter-wrapped, why the derived ledger is retained as the degraded
  path, and why telemetry failure allows rather than blocks (§7). **If Anthropic
  ships a supported endpoint, §4.1 should migrate to it.**
- **The CI credential class is unverified.** See §4.1's open-verification note:
  the probe used a short-lived local OAuth token, not the long-lived
  `claude setup-token` credential CI uses. Closed by a dry-run in CI, not by
  minting a new token.
- **The window's internal mechanics remain undocumented** — the endpoint reports
  `percent` and `resets_at` but not how consumption maps to them, so the ADR
  treats the reported percentage as opaque and authoritative rather than modelling
  it.

---

## 11. Consequences

- The follow-on stories are **build, not configure**: like PR-Limits, there is no
  vendor toggle to flip — the work is a source-side gate, a private telemetry
  adapter and poller over §4.1 (with the derived ledger as its fallback), and
  thin, centrally-promoted wiring.
- The §6/§7/§9 numbers are explicitly provisional; the config story starts from a
  human-signed set.
- `cancel-in-progress` is recorded as an **anti-pattern** for throughput control
  (it cancels, per #402); all new controls **defer**, never cancel.
- The design is cross-repo by necessity (§8): the public repo cannot see the
  budget telemetry, so the token breaker cannot be fully implemented in this epic
  alone — a private companion change is a named dependency, not a surprise.

## 12. References

- [`docs/initiatives/pull-request-limits-adr.md`](pull-request-limits-adr.md) — the staged-epic ADR template mirrored here.
- [`docs/initiatives/agent-canary-rings-adr.md`](agent-canary-rings-adr.md) — the self-hosting circular-dependency + central-promotion model.
- [`standards/pr-limits.md`](../../standards/pr-limits.md) / [`scripts/lib/pr-limit-gate.sh`](../../scripts/lib/pr-limit-gate.sh) — the standard + source-side gate pattern to reuse.
- The four in-scope caller stubs (read first-hand):
  - [`standards/workflows/dev-lead.yml`](../../standards/workflows/dev-lead.yml)
  - [`standards/workflows/feature-ideation.yml`](../../standards/workflows/feature-ideation.yml)
  - [`standards/workflows/initiative-driver.yml`](../../standards/workflows/initiative-driver.yml)
  - [`.github/workflows/compliance-audit-and-improvement.yml`](../../.github/workflows/compliance-audit-and-improvement.yml)
- [AGENTS.md](../../AGENTS.md) / [CLAUDE.md](../../CLAUDE.md) — the "never guess an API surface" org rule.
- GitHub docs: [Using concurrency](https://docs.github.com/en/actions/using-jobs/using-concurrency).
- Claude docs (fetched first-hand):
  - [Rate limits](https://platform.claude.com/docs/en/api/rate-limits)
  - [Rate Limits API](https://platform.claude.com/docs/en/manage-claude/rate-limits-api)
  - [Using Claude Code with your Pro/Max plan](https://support.claude.com/en/articles/11145838-using-claude-code-with-your-pro-or-max-plan)
- **Telemetry source of record (§4.1):** `GET https://api.anthropic.com/api/oauth/usage`
  — undocumented; probed first-hand 2026-08-20 (HTTP 200). Upstream requests for a
  supported equivalent:
  [anthropics/claude-code#44328](https://github.com/anthropics/claude-code/issues/44328),
  [#32796](https://github.com/anthropics/claude-code/issues/32796).
- Follow-on stories reading §4.1: [#641](https://github.com/petry-projects/.github/issues/641)
  (Phase 5, 5-hour breaker) and [#994](https://github.com/petry-projects/.github/issues/994)
  (Phase 6, 7-day glide-path breaker).
- Cross-repo: `petry-projects/.github-private#1525` — `AGENTS_PAUSED` as a
  first-class state (the switch §7 automates); `.github-private#1565` — the
  adapter/poller companion.
- Cross-repo: `petry-projects/.github-private` `scripts/engine.sh` — 5-hour subscription-cap handling ([#206](https://github.com/petry-projects/.github/issues/206)).
- Baseline incidents: [#402](https://github.com/petry-projects/.github/issues/402), [#443](https://github.com/petry-projects/.github/issues/443), [#571](https://github.com/petry-projects/.github/issues/571).
- External framing: OWASP Top 10 for Agentic Applications (2026), **ASI08 — Denial of Service & Resource Exhaustion**.
