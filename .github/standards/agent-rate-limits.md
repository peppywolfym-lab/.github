# Standard — Agent Rate Limits & Circuit Breakers

Org-wide policy for bounding agentic throughput: the per-agent-type rate limits
and circuit breakers, the org-wide Claude token-budget breaker, the single source
of truth for their configured values, and which actors are intentionally exempt.

This standard is the human-readable companion to the machine-readable config in
[`standards/agent-rate-limits.json`](agent-rate-limits.json). It exists so a
compliance audit — and any contributor — reads the limits and their exemptions as
**sanctioned policy, not misconfiguration or drift**.

- **Decision record (why this exists / the verified mechanism):**
  [`docs/initiatives/agent-rate-limits-adr.md`](../docs/initiatives/agent-rate-limits-adr.md)
  (Phase 1, [#637](https://github.com/petry-projects/.github/issues/637)).
- **Single source of truth (the values):**
  [`standards/agent-rate-limits.json`](agent-rate-limits.json) (Phase 2,
  [#638](https://github.com/petry-projects/.github/issues/638)).
- **Apply path (where it will be enforced):** a source-side gate library
  (`scripts/lib/agent-rate-limit.sh`) is Phase 3; the org-wide token-budget
  breaker (the public side — thresholds, policy, decision, and the telemetry
  adapter seam) is Phase 5 ([#641](https://github.com/petry-projects/.github/issues/641),
  §4.1 below); the private telemetry poller + live-path wiring land separately
  (ADR §8). The per-agent-type limits and consecutive-failure breakers are now
  enforced at dispatch time (see §3); **the token-budget breaker is not yet
  enforced** — it ships inert behind a flag; see §4.2.

---

## 1. What is limited

Two complementary controls, both drawn from the ADR taxonomy (§5, §7):

- **Per-agent-type controls.** Each in-scope agent type
  (`dev-lead`, `compliance-audit`, `feature-ideation`, `initiative-driver`) is
  bounded on five dimensions: **max concurrent runs, max runtime, cooldown
  between runs, a daily execution budget, and a consecutive-failure circuit
  breaker** (open → backoff → half-open probe). Over a limit → **defer**, never
  cancel — `cancel-in-progress` is recorded as an anti-pattern (it cancelled 111
  in-flight issue pickups in incident #402; ADR §1).
- **The org-wide token-budget breaker.** A single breaker over the shared Claude
  subscription budget that pauses new agentic dispatch when a **fixed** usage
  window crosses a threshold, prioritizing Claude-backed agents on recovery
  (§4 below).

Why limits at all: agentic automation in this org runs on schedules and event
fan-out with no throughput ceiling of its own, and can exhaust the shared,
finite 5-hour Claude subscription budget — starving the very pipeline that would
repair it (OWASP ASI08; ADR §1).

## 2. Source of truth — the configured values

The per-agent limits, the token-budget thresholds, and the exempt lists live
**only** in [`standards/agent-rate-limits.json`](agent-rate-limits.json). This
document deliberately does **not** restate any of the numbers: a changeable value
stated in prose is a second place to forget to update. To read a current value,
read the config — for example:

```bash
# Every per-agent daily execution budget (the per-agent cost bound; see §5):
jq '.agent_types | map_values(.daily_run_budget)' standards/agent-rate-limits.json

# The 5-hour session pause threshold and the Claude-priority flag:
jq '.org_wide.token_budget.limits.session.pause_threshold_pct,
    .org_wide.token_budget.claude_priority' standards/agent-rate-limits.json
```

The config carries its own inline `_note` fields recording the sign-off state and
the ADR rationale for each value. Consumers (the Phase-3 gate and any future
dispatch path) **must** read values from this file — never hardcode them.

Its contract (parseable JSON, required keys present, per-agent numeric limits are
positive integers, each agent carries a circuit breaker, the session threshold is
in range, only account-wide windows are pause-worthy, and no percentage resume
mark exists) is guarded by
[`tests/test_agent_rate_limits_config.bats`](../tests/test_agent_rate_limits_config.bats),
run in CI by
[`.github/workflows/agent-rate-limits-tests.yml`](../.github/workflows/agent-rate-limits-tests.yml).

## 3. Status — signed off and wired (Phase 4)

The per-agent-type limits and consecutive-failure breakers are **signed off**
(`status: signed-off`) — the maintainer sign-off comment on epic
[#636](https://github.com/petry-projects/.github/issues/636) (2026-09-01) cleared
the gate, mirroring the PR-Limits sign-off exactly (ADR §7,
[`pr-limits.md`](pr-limits.md)). They are now **consumed at dispatch time** by the
Phase-4 orchestrator
[`scripts/agent-rate-limit-gate.sh`](../scripts/agent-rate-limit-gate.sh)
([#640](https://github.com/petry-projects/.github/issues/640)), which wraps the
pure gate library.

The org-wide token-budget breaker (§4) is now **wired into that same orchestrator's
decision path but disarmed** ([#1155](https://github.com/petry-projects/.github/issues/1155)):
`scripts/agent-rate-limit-gate.sh` consults both account-wide windows (`session`
and `weekly_all`; `weekly_scoped` is never consulted, ADR §2.5) alongside the
per-agent-type checks, and a `defer` from the token-budget half defers dispatch —
but the whole consultation is gated on `AGENT_TOKEN_BUDGET_ENABLED`, which stays
**unset**, so the breaker is inert and the gate's output is byte-identical to the
per-agent-only behaviour. It is therefore **wired-but-disarmed**, not
signed-off-and-armed: arming it is a deliberate maintainer change that must (a)
set `AGENT_TOKEN_BUDGET_ENABLED` with the private telemetry seam wired
(petry-projects/.github-private#1565),
and (b) flip `org_wide.token_budget.limits.weekly_all.enabled` from `false` to arm
the weekly glide-path half — each a separate, deliberately out-of-scope change
([#994](https://github.com/petry-projects/.github/issues/994)). See §4.2 for the
staged rollout.

### 3.1 Canary scope — enforcing vs log-only, and the promotion path (AC #5)

Only **`initiative-driver` enforces** in this rollout: it is pure bash (no model
spend) and the direct target of the dispatch-race defect
[#443](https://github.com/petry-projects/.github/issues/443). Its stub
(`standards/workflows/initiative-driver.yml` and every enrolled repo's live copy)
calls the orchestrator with `--mode enforce`; a `defer` decision simply skips the
dispatch step (a clean no-op — never a cancel, never a job failure).

**`feature-ideation` runs the gate in `--mode log-only`** (`feature-ideation-reusable.yml`):
the decision is computed from run history and logged, but the emitted decision is
always `allow`, so nothing is acted on. `dev-lead` and `compliance-audit` are not
yet wired because their dispatch workflows live in `petry-projects/.github-private`
and are out of scope for this rollout.

**Because Actions runners are ephemeral, the orchestrator derives all counters
from run history** (`gh run list`) rather than a state file — concurrency,
cooldown's last-run, the rolling daily count, and the breaker's
`consecutive_failures` — and feeds them to the library's pure
`arl_admission_decision` / `arl_breaker_decision`. It never reads or writes
`AGENT_RATE_LIMITS_STATE`.

**To promote another agent type from log-only to enforcing** (a discrete
follow-up change, one agent type at a time):

1. Confirm the agent type's limits in `agent-rate-limits.json` are the intended
   enforcing values (they already are — this file is the source of truth).
2. In that agent's dispatch workflow, change the gate step's `--mode log-only` to
   `--mode enforce`, and add an `if: steps.<gate-step-id>.outputs.decision !=
   'defer'` guard to the dispatch step so a `defer` skips dispatch while an
   empty/missing decision still dispatches (fail-open — an outage of the gate must
   never stop the fleet).
3. Provide `--tracking-repo` / `--tracking-issue` so an open breaker escalates the
   library's marker + `needs-human-review` label onto a tracking issue exactly
   once (deduped).
4. Ship it as its own PR with its own review — never flip several agent types in
   one change.

## 4. The token-budget breaker

The breaker reads the shared Claude subscription budget through the OAuth usage
endpoint that is the telemetry **source of record** (ADR §4.1); because that
endpoint authenticates with a credential that lives in
`petry-projects/.github-private`, the **live budget read and the pause actuation
are private** — this public file holds only the thresholds and the policy (ADR
§8). The threshold values themselves are in the config; the properties that must
not drift into prose-restated numbers, but that a reader must understand, are:

- **The windows are FIXED, not rolling.** The 5-hour `session` window and the
  7-day `weekly_all` window each carry an authoritative `resets_at`. Within a
  window utilization is **monotonically non-decreasing**; the only event that
  lowers it is the reset. (The per-minute `anthropic-ratelimit-*` API bucket is a
  different mechanism and *is* continuously replenished — do not conflate them.)
- **There is no percentage resume mark.** Because a downward percentage dip cannot
  occur inside a fixed window, a resume/hysteresis mark would be unreachable by
  construction and is deliberately absent (ADR §7). The `session` breaker closes
  only at its `resets_at`; the `weekly_all` glide-path breaker closes at
  `resets_at` **or** when its time-varying threshold rises past a static
  utilization — never because usage fell.
- **Only account-wide windows are pause-worthy.** `session` and `weekly_all` are
  pause-worthy; `weekly_scoped` (per-model exhaustion) is handled by the engine's
  model-fallback chain and **never** trips a fleet pause (ADR §2.5). The config
  encodes this distinction on each limit kind rather than leaving it to the
  consumer.
- **Claude-priority on recovery.** When a window drains and dispatch resumes,
  Claude-backed agents are prioritized so the recovering budget clears the backlog
  first (the `claude_priority` flag).
- **Fail-safe direction.** On telemetry error the breaker **allows** dispatch and
  logs a warning — an outage of an undocumented third-party endpoint must never
  stop the fleet (ADR §7). This is policy the gate will honor; it is not itself a
  value in this file.

### 4.1 Where the breaker lives — the gate library + adapter seam

The 5-hour `session` breaker is implemented in the source-side gate library
[`scripts/lib/agent-rate-limit.sh`](../scripts/lib/agent-rate-limit.sh) (Phase 5,
[#641](https://github.com/petry-projects/.github/issues/641)), alongside the
per-agent-type controls:

- `arl_token_budget_gate [window]` orchestrates the breaker for a window
  (default `session`): it reads the threshold from this config, consults the
  telemetry **adapter seam**, and emits `decision=allow` / `decision=defer`.
- The **adapter seam** keeps the credentialed OAuth read private (ADR §8.2). The
  private poller plugs the live read into one of two env vars, which the library
  never sets itself:
  - `AGENT_TOKEN_BUDGET_TELEMETRY_CMD` — a command whose stdout is the normalized
    envelope, or
  - `AGENT_TOKEN_BUDGET_TELEMETRY_FILE` — a file holding the envelope JSON.
  The envelope is `{ "status": <http_status>, "retry_after": <int?>,
  "body": <raw upstream?> }`; the library prefers the ADR §4.1 `limits[]` array
  and falls back to the flattened `five_hour` / `seven_day` keys. **With neither
  var set, the breaker fails safe to allow** (the disabled/degraded mode below).
- The adapter reads both the `session` and `weekly_all` windows from one
  envelope, so the Phase 6 weekly glide-path breaker
  ([#994](https://github.com/petry-projects/.github/issues/994)) extends it
  rather than refactoring. Both breakers share one transport-level fail-safe
  (`arl_token_transport_decision`) so there is a single 429 / non-200 convention.
- When the breaker trips, the pause is surfaced through the same human-clearable
  primitives as the rest of the library: `arl_token_breaker_marker <window>` (a
  deduped HTML marker) plus `arl_breaker_label` (`needs-human-review`). A human
  clears both to acknowledge the pause. `arl_token_priority_rank <agent_type>`
  encodes the Claude-priority-on-recovery order (Claude-backed agents ahead of
  `initiative-driver`) from the `claude_priority` flag.

- `arl_token_weekly_glide_gate` orchestrates the **7-day glide-path** breaker on
  the account-wide `weekly_all` window (Phase 6,
  [#994](https://github.com/petry-projects/.github/issues/994)). Rather than a
  static threshold it evaluates a **time-varying** one read entirely from config —
  `clamp(ceiling_pct − reserve_pct_per_day × days_until_reset, floor_pct,
  ceiling_pct)` — where `days_until_reset` derives from the telemetry payload's
  authoritative `resets_at` (`arl_token_iso_to_epoch` +
  `arl_token_days_until_reset`, partial days rounded **up**), never a hardcoded
  weekday. The schedule is expressible purely from the `weekly_all` config keys
  (`enabled`, `reserve_pct_per_day`, `floor_pct`, `ceiling_pct`); no number is
  hardcoded. On a trip the reason is **machine-readable**
  (`arl_token_glide_trip_reason` → `{window, observed_percent, threshold_pct,
  days_until_reset, resets_at}`), surfaced through the same
  `arl_token_breaker_marker weekly_all` / `arl_breaker_label` primitives.

  **This breaker can close before `resets_at`** — but never because utilization
  fell. Within a fixed window percent is monotonically non-decreasing; the
  glide-path threshold **rises** as the reset approaches, so each poll
  re-evaluates statelessly and the breaker may close because the *threshold moved
  past a static percent*, not because usage dipped. This is the single most
  misread part of the design: it is distinct from the `session` breaker's
  "closes only at `resets_at`" rule, yet there is still no percentage resume mark
  for either breaker.

### 4.2 Rollout — canary / dry-run first, then promotion (AC #5)

Activation is **staged and reversible**, and never overrides a pause a human set
deliberately (ADR §7, `.github-private#1525`):

1. **Inert (default).** The integration into `arl_admission_gate` is gated by the
   `AGENT_TOKEN_BUDGET_ENABLED` env flag, which is **off by default**. With the
   flag unset the gate reads no telemetry and the breaker cannot change any
   dispatch decision — the provisional config (`status: provisional`, §3) stays
   inert until human sign-off, exactly as the pr-limits config did before its own
   gate.
2. **Dry-run.** Run with `AGENT_TOKEN_BUDGET_ENABLED=true` **and** `DRY_RUN=true`
   (or `DEV_LEAD_DRY_RUN=true`). The gate computes and logs the real
   allow/defer decision but always returns allow with no side effects, so a
   canary can observe how often the breaker *would* trip against live telemetry
   before it changes behavior.
3. **Canary.** Enable enforcement (`AGENT_TOKEN_BUDGET_ENABLED=true`, no
   `DRY_RUN`) for a canary slice via the central promotion channel
   ([agent-canary-rings-adr](../docs/initiatives/agent-canary-rings-adr.md)), with
   the telemetry seam wired to the private poller. Watch that deferrals correlate
   with real budget pressure and that Claude-backed agents recover first.
4. **Promote.** Roll the flag out fleet-wide through the same channel once the
   canary is clean. Because the threshold is read from this config at run time,
   tuning it afterward is a config edit (§7.1), not a redeploy.

**The weekly glide-path breaker carries a second, config-level arm.** In addition
to the shared `AGENT_TOKEN_BUDGET_ENABLED` env flag, `arl_token_weekly_glide_gate`
is gated by the `weekly_all.enabled` config flag (**off by default**). This lets
the `session` breaker be enabled while the weekly glide stays inert, so the
glide's own dry-run week — logging the decision it *would* have made against live
telemetry for a full weekly window before it can defer anything (AC #7) — is a
config toggle independent of the session breaker's rollout. With `enabled: false`
the gate reads no telemetry and cannot change any decision.

**Degraded / disabled-behind-flag mode (AC #6).** If the private telemetry
companion is not yet wired (no seam configured) the breaker **allows with a
warning** rather than blocking — the story ships complete regardless of the
telemetry wiring, and no acceptance criterion depends on a source that might be
unavailable. Turning the flag on without a wired seam is therefore safe: it stays
inert-allowing until the seam is present.

## 5. The daily budget is the per-agent cost bound

The per-agent **`daily_run_budget`** key is the concrete, config-declared cost
bound for each agent type: the maximum runs (for `initiative-driver`, dispatches —
ADR §3) that agent may perform per rolling 24h, independent of concurrency. The
epic's operational cost cap is therefore traceable to a specific config key rather
than to prose: the standing org-wide agentic dispatch ceiling is the aggregate of
these per-agent `daily_run_budget` values (ADR §9.2). Changing the cap is a config
edit to this key, not a redeploy — read the values with:

```bash
jq '.agent_types | map_values(.daily_run_budget)' standards/agent-rate-limits.json
```

## 6. Exempt actors — sanctioned, not a misconfiguration

Some agent runs must **never** be blocked or deferred by these limits. The exempt
actors and labels are listed in `exempt_actors` / `exempt_labels` in
[`standards/agent-rate-limits.json`](agent-rate-limits.json) and are the **same
set** as [`standards/pr-limits.json`](pr-limits.json), so one policy governs both
gates. A compliance audit encountering these actors on the exempt list should
treat them as policy, not drift.

| Exempt entry | Kind | Why it is exempt |
|---|---|---|
| `dependabot[bot]` | actor | Already bounded per-ecosystem by `open-pull-requests-limit`; security update runs must never be starved by a general throttle. |
| `OrganizationAdmin` | actor | Human break-glass / admin runs. |
| `@petry-projects/org-leads` | actor | Maintainer traffic — human review, not automation backlog. |
| `dependabot-automerge-petry` | actor (App) | Operates on *existing* PRs; it does not add agentic run volume. |
| `security` | label | Urgent security / hotfix work bypasses any throttle. |

To change this list, follow the runbook in §7.2. Keep this table in sync with the
config so the human-readable rationale does not drift from the machine-readable
list (the same discipline as [`pr-limits.md`](pr-limits.md) §4).

## 7. Operator runbook

All changes here are edits to the single source of truth
[`standards/agent-rate-limits.json`](agent-rate-limits.json), gated by the config
tests. While the config is inert (§3), an edit changes no runtime behavior; once
the values are signed off and the Phase-3+ consumers are wired, enforcement is
source-side and reads the file at run time, so a change takes effect on merge with
no separate apply step (mirroring [`pr-limits.md`](pr-limits.md) §6).

### 7.1 Change a limit

1. Edit the relevant key in
   [`standards/agent-rate-limits.json`](agent-rate-limits.json). Update the
   adjacent `_note` to record the new rationale and sign-off — keep the value out
   of any other prose, this file is the only place it should appear.
2. Validate the contract locally:

   ```bash
   bats --print-output-on-failure tests/test_agent_rate_limits_config.bats
   ```

3. Open a PR. CI
   ([`.github/workflows/agent-rate-limits-tests.yml`](../.github/workflows/agent-rate-limits-tests.yml))
   re-runs the config contract test.

### 7.2 Add or remove an exempt actor

1. Edit the `exempt_actors` array (or `exempt_labels` for a label) and add a short
   justification to `_exempt_note`, matching the style of the existing entries.
2. Keep §6 of this document in sync with the config, and keep the set aligned with
   [`standards/pr-limits.json`](pr-limits.json) unless there is a documented reason
   to diverge.
3. Validate and open a PR as in §7.1.

## 8. References

- [`docs/initiatives/agent-rate-limits-adr.md`](../docs/initiatives/agent-rate-limits-adr.md)
  — decision record (Phase 1, #637): the verified mechanism, the taxonomy, and the
  proposed values this config encodes.
- [`standards/agent-rate-limits.json`](agent-rate-limits.json) — single source of
  truth (Phase 2, #638).
- [`standards/pr-limits.md`](pr-limits.md) / [`standards/pr-limits.json`](pr-limits.json)
  — the sibling standard + config whose single-source-of-truth and
  never-restate-numbers conventions this standard mirrors.
- [`tests/test_agent_rate_limits_config.bats`](../tests/test_agent_rate_limits_config.bats)
  — the config contract test.
