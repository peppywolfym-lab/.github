# AGENTS.md — Petry Projects Organization Standards

This file defines cross-cutting development standards for all repositories in the **petry-projects** organization.
It follows the [AGENTS.md convention](https://agents.md/) and is intended to be imported by each repository's own AGENTS.md or CLAUDE.md.

> Individual repositories extend these standards with project-specific guidance. If a repo-level rule conflicts with this file, the repo-level rule takes precedence.

---

## Organization Standards

The full set of org standards lives at
**[`petry-projects/.github/tree/main/standards/`](https://github.com/petry-projects/.github/tree/main/standards)**.
Read the relevant standard *before* making changes that touch CI, repo settings, agent configuration, or labels.

| Topic | Standard | What it covers |
|-------|----------|----------------|
| **CI/CD workflows** | [`standards/ci-standards.md`](https://github.com/petry-projects/.github/blob/main/standards/ci-standards.md) | Required workflows, action pinning, permissions, job naming, tech-stack patterns |
| **Standards versioning** | [`standards/standards-versioning.md`](https://github.com/petry-projects/.github/blob/main/standards/standards-versioning.md) | How `standards/` is published as a versioned artifact: immutable `standards/vX.Y.Z` releases, the moving `standards/v1-stable` channel consumers pin, the idempotent cut script, and N-1 resolvability |
| **Workflow templates** | [`standards/workflows/`](https://github.com/petry-projects/.github/tree/main/standards/workflows) | Copy-paste-ready templates: `agent-shield.yml`, `dev-lead.yml`, `dependabot-automerge.yml`, `dependabot-rebase.yml`, `dependency-audit.yml`, `feature-ideation.yml` |
| **Agent configuration** | [`standards/agent-standards.md`](https://github.com/petry-projects/.github/blob/main/standards/agent-standards.md) | CLAUDE.md / AGENTS.md / SKILL.md required structure, frontmatter rules, cross-references |
| **Repo settings + labels** | [`standards/github-settings.md`](https://github.com/petry-projects/.github/blob/main/standards/github-settings.md) | Required settings, label set with exact colors, code-quality ruleset, branch protection |
| **Rulesets** | [`standards/rulesets/`](https://github.com/petry-projects/.github/tree/main/standards/rulesets) | Codified source-of-truth JSON for the org-wide `pr-quality`, `code-quality`, and `release-channel-tags` rulesets (applied by `apply-rulesets.sh`) |
| **Dependabot config** | [`standards/dependabot-policy.md`](https://github.com/petry-projects/.github/blob/main/standards/dependabot-policy.md) and [`standards/dependabot/`](https://github.com/petry-projects/.github/tree/main/standards/dependabot) | Per-ecosystem dependabot.yml templates and policy |
| **Advanced Security (GHAS)** | [`standards/advanced-security.md`](https://github.com/petry-projects/.github/blob/main/standards/advanced-security.md) | Org-wide GHAS enablement via the "GitHub recommended" code security configuration, licensing model, and how to verify push protection actually enforces |
| **Push protection** | [`standards/push-protection.md`](https://github.com/petry-projects/.github/blob/main/standards/push-protection.md) | Secret scanning + push protection, local gitleaks hooks, CI secret-scan job, incident response |
| **Ruleset remediation** | [`standards/ruleset-remediation-runbook.md`](https://github.com/petry-projects/.github/blob/main/standards/ruleset-remediation-runbook.md) | Manual admin-token procedure for ruleset bypass-actor + legacy-ruleset findings (snapshot → fix → migrate-then-delete → verify → rollback) |
| **PR limits** | [`standards/pr-limits.md`](https://github.com/petry-projects/.github/blob/main/standards/pr-limits.md) | Org-wide soft cap on concurrent open automation PRs: source-of-truth (`pr-limits.json`), source-side apply path (`pr-limit-gate.sh`), exempt-actor rationale, operator runbook |
| **Agent rate limits** | [`standards/agent-rate-limits.md`](https://github.com/petry-projects/.github/blob/main/standards/agent-rate-limits.md) | Per-agent-type rate limits + circuit breakers and the org-wide Claude token-budget breaker: source-of-truth (`agent-rate-limits.json`), ADR decision record, exempt-actor rationale, operator runbook |

**When fixing a compliance finding, the rule is: read the standard, then copy
the template — do not generate from scratch.** Anything generated from scratch
is, by definition, drift from the standard. If a needed standard or template
is missing, file an issue against `petry-projects/.github` rather than
diverging silently.

### What lives where — `.github` vs `.github-private`

Org-wide **standards and compliance policy are owned by `petry-projects/.github`**
(this repo): everything in the table above, **plus the codified compliance
rulesets** — `code-quality` and `pr-quality` — that `scripts/apply-rulesets.sh`
(and org automation consuming it) apply to every repo. The canonical home for those
ruleset JSONs is `standards/rulesets/`.

**`petry-projects/.github-private` is scoped to agents, skills, and their reusable
workflows/assets.** It must **not** be the source of truth for org-wide policy.
No rulesets should be defined there; all rulesets are owned by `.github/standards/rulesets/`.

**Rule of thumb:** all standards and rulesets belong in `.github/standards/`, whether
they apply fleet-wide (like `pr-quality` and `code-quality`) or are targeted to specific
repos (like `release-channel-tags` for meta-repos). When in doubt, put it in `.github`
and have `.github-private` **consume** it — the way repo-seeding tooling fetches
`standards/workflows/` from `.github`. Do **not** add new org-wide standards or rulesets
to `.github-private`.

> **Known exception being remediated:** `code-quality.json` and `pr-quality.json`
> currently live in `.github-private/.github/rulesets/` (added ad-hoc under
> compliance fix #60, before this boundary was documented) and are being relocated
> to `standards/rulesets/` — see
> [petry-projects/.github#575](https://github.com/petry-projects/.github/issues/575).
> Treat `.github` as the intended canonical home; do not extend the `.github-private`
> copies.

---

## Project Context

- **Assume brownfield.** When exploring a repo, check for existing source code before assuming it is greenfield.
Look at all directories, worktrees, and non-main branches before concluding that code does not exist.

---

## Git Workflow

### Branch Creation

- **Always base new branches off the default branch (`main`)** (not off other feature or PR branches) unless explicitly told otherwise.
- Before creating a branch, ensure your working directory is clean (commit or stash any changes), then run:

  ```bash
  git checkout main && git pull origin main
  ```

### Branch Switching

- **Before switching branches, always commit or stash current work.** Git usually prevents checkouts that would overwrite local changes,
but forced operations (e.g., `git checkout -f` or `git reset --hard`) or resolving conflicts incorrectly can cause you to lose or misplace work.
- After switching, verify you are on the correct branch with `git branch --show-current` before making any changes.

---

## Development Environment

When the user asks to run or launch an app, first check the environment for required dependencies and report blockers immediately rather than attempting extensive debugging. At minimum, verify:

1. **Required runtimes** — Node.js, Go, Python, etc. as specified by `package.json`, `go.mod`, or equivalent
2. **System dependencies** — display server (for Electron/GUI apps), Homebrew, sudo availability
3. **Available ports** — check for conflicts on common dev ports (3000, 5173, 8080)
4. **Package installation** — run `npm install`, `go mod download`, etc. before attempting to build or run

If a dependency cannot be resolved, report the specific blocker and a workaround immediately — do not spend time debugging environment issues repeatedly.

---

## Test-Driven Development (TDD)

- **TDD is mandatory.** Write tests before implementing features or bug fixes. Include tests in the same PR as the implementation.
- **Achieve and maintain excellent test coverage.** Verify locally before pushing. PRs that reduce coverage below repo-defined thresholds will be rejected.
- **NEVER use `.skip()` to avoid failing tests.** If tests fail, fix them. If functionality cannot be directly tested, extract testable logic and test the extraction.
- **NEVER add coverage-ignore comments** (e.g., `/* istanbul ignore next */`, `/* c8 ignore next */`, `// v8 ignore next`) to artificially boost coverage.
  If code is difficult to test, improve mocking strategies or adjust thresholds instead.
- Unit tests MUST be fast, deterministic, and not access external networks.
- Integration tests are allowed but MUST be clearly marked. They may be skipped locally during rapid iteration, but CI MUST always run them (for example, in a separate job or scheduled workflow).
- Mock external services using project-provided helpers where available.

### Decision Logic Lives in a Pure, Tested Script

**A decision-making reusable keeps its decision logic in a pure, side-effect-free, unit-tested script (e.g. `scripts/**` or `.github/scripts/**`), with the workflow as thin I/O glue.**
The workflow gathers facts (via `gh`, GraphQL, git, etc.) and passes them to a `source`-able function that computes the verdict with
no external calls; the glue only echoes the result to `$GITHUB_OUTPUT` or acts on it. **Gate the script with bats in CI on any PR that changes the reusable.**

Exemplars in this org:

- **Canary rollout engine** — `scripts/lib/canary-rollout.sh` (pure gate core) + `tests/canary_rollout.bats`, CI-gated by `canary-rollout-tests.yml` (#685).
  The orchestrator `scripts/canary-rollout.sh` feeds it numbers gathered from `gh`.
- **PR auto-review readiness gate** — `.github/scripts/pr-auto-review/lib/ready-check.sh` (`pr_auto_review_ready` + helpers) + `test/workflows/pr-auto-review/`, CI-gated by
  the **PR Auto-Review Tests** workflow. The reusable `pr-auto-review-reusable.yml` is thin glue that gathers PR state and calls the pure core.

Why it pays off: correctness bugs are caught **pre-merge** by fast unit tests instead of at canary time or in production;
the **whole decision matrix** is covered (every branch, precedence, edge cases) rather than the single fixture point a live run exercises;
and it adds **zero canary-time cost** because the logic is verified before a version ever ships.
Inline bash trapped in YAML can be exercised only by triggering the workflow — extract it.

---

## End-to-End Testing — Validate Real Functional Requirements

E2E tests validate real functional requirements through the full stack. They exist to catch bugs that would affect real users.
**A test that does not verify a real business outcome is a test that provides false confidence and must not exist.**

> Every E2E test must answer one question: **"What functional requirement would be broken for a real user if this test didn't exist?"**
> If the test could pass while the requirement is fundamentally unmet, it is worthless and must be rewritten.

### What E2E Tests MUST Do

1. **Full round-trip verification.** Action → API call → database mutation → response → frontend reflects new state. Not a subset — the whole chain.
2. **Multi-layer assertions.** The frontend shows correct data AND the database contains the correct record AND side effects occurred (events published, notifications queued, cache invalidated).
3. **Verify at the data layer.** After a form submission, query the database directly to verify the record exists with correct fields.
   After a delete, verify it's gone. After auth, verify the token's claims and scopes. Do NOT stop at "success toast appeared."
4. **Test error paths.** For every happy-path test, write corresponding tests for:
   invalid input, unauthorized access, conflict/duplicate states, and not-found resources.
5. **Test authorization boundaries.** Verify user A cannot access user B's resources. Verify regular users cannot hit admin endpoints. Verify expired/revoked tokens are rejected.
6. **Use realistic data.** Factories that produce production-realistic data (unicode names, long strings, special characters, realistic cardinalities) — not `"test"` and `"foo"`.
7. **Deterministic waits.** Wait for specific conditions (element visible, API response received, database row present) using polling with timeouts — never arbitrary sleeps.

### Forbidden Patterns

These are non-negotiable. Tests exhibiting these patterns MUST be rejected:

| Anti-Pattern | Why It Fails | Fix |
|---|---|---|
| **Smoke test disguised as E2E** | Verifies the page loads, not that a functional requirement works | Add assertions on business outcomes after user actions |
| **Frontend-only assertions** | Cached/stale frontend can show "Success" while the write failed | Query the database or API to verify the actual state change |
| **Mocking the entire backend** | Eliminates the integration being tested | Hit the real backend with real databases (containers or dedicated test instances) |
| **Asserting only on HTTP status codes** | A 200 with empty body or wrong data is still a bug | Always verify response body fields and database state |
| **Arbitrary sleeps** | Flaky, slow, hides timing bugs | Poll for a condition with a timeout |
| **Happy path only** | Production bugs live in error paths and edge cases | Test invalid input, unauthorized access, and conflicts |
| **No cleanup / test pollution** | Tests depend on execution order, fail in isolation | Each test creates and cleans up its own data |
| **Frontend for preconditions** | 10x slower, couples test to unrelated frontend flows | Use API calls or direct database inserts for setup |
| **Brittle selectors** | Breaks on any frontend change | Use stable test-ID attributes exclusively — never CSS classes, DOM hierarchy, or text content |
| **Placeholder assertions** | `expect(true).toBe(true)` proves nothing | Assert on specific field values and business outcomes |

### Test Structure — Arrange, Act, Assert, Verify, Cleanup

Every E2E test follows this structure:

1. **Arrange** — Create preconditions via API or direct database insert (never via the frontend)
2. **Act** — Perform the user action under test
3. **Assert** — Check the immediate response (HTTP status + body, or frontend feedback)
4. **Verify** — Check the database/state store to confirm the real outcome
5. **Cleanup** — Remove test data (or use transactional rollback)

### Test Design Patterns

**Page/Screen Object Model (for frontend E2E):**

- Encapsulate page interactions in page/screen objects. Tests read as functional requirements, not DOM/view manipulation.
- Page objects expose user-intent methods (`loginAs(user)`, `submitOrder(items)`) — not element-level methods.
- Selectors live in exactly one place (the page object). Use stable test-ID attributes exclusively.

**Test Data Factories:**

- Every test creates its own data. Never rely on pre-existing seed data.
- Factories produce realistic, randomized data: `createUser({role: "admin"})`, `createOrder({status: "pending", items: 3})`.
- Factories use the API or database — NOT the frontend.

**Multi-Layer Assertion Example:**

```pseudocode
// WRONG — only checks frontend
click("#submit-order")
assert getText(".toast") == "Order placed!"

// RIGHT — checks frontend + API response + database
response = submitOrderAndCapture(orderData)
assert response.status == 201
assert response.body.orderId is not empty

dbOrder = db.orders.findById(response.body.orderId)
assert dbOrder.status == "confirmed"
assert dbOrder.items.length == 3
assert dbOrder.total == expectedTotal

assert getText("[test-id='order-id']") contains dbOrder.orderId
```

### API E2E

- **Write → Read round trips.** Execute a mutation/write, then immediately query for the resource. Verify every field matches. This catches stale cache, serialization mismatches, and silent write failures.
- **Authorization on every endpoint.** For every read and write operation, test with: valid token (succeeds), no token (rejected), wrong user's token (rejected), insufficient scope (rejected).
- **Real-time/subscription delivery.** If the API supports subscriptions or push, open a listener, perform the triggering write, verify the listener receives the correct payload within a timeout.
- **Pagination edge cases.** Test: empty results, exactly one page, last page terminates correctly, cursor/offset stability across inserts, invalid cursors return helpful errors.

### Backend E2E

- **Use containerized or dedicated test databases.** Spin up real database instances per test suite. No mocking the database in E2E — ever.
- **Run the real application server with test configuration.** Tests hit real API endpoints, which hit the real database.
- **Test migrations.** Run database migrations from scratch on test suite startup. If migrations fail, the test fails.
- **Test concurrency.** Double-submit for idempotency verification. Two users editing the same resource for optimistic locking. Fire concurrent requests from the test.
- **Assert beyond status codes.** Verify response body fields, database state, audit log entries, published events.

### Frontend E2E (Web and Mobile)

- **Run against the real backend** — not a mocked API layer. The frontend E2E test environment connects to a real API backed by a real (test) database.
- **Test full navigation flows** — deep links, back navigation, tab switching with state preservation, modal dismissal.
- **Test offline/online transitions** (mobile) — disable network, verify cached data displays and writes queue, re-enable, verify sync.
- **Use stable test-ID attributes exclusively for selectors.** Never match on displayed text (changes with localization), CSS classes, or DOM/view hierarchy.
- **Test on at least two form factors** (mobile). Never hardcode device dimensions.

### Agentic Directives

1. Before writing any E2E test, state the functional requirement in a comment: `// Functional requirement: User creates a project, verifies it appears in the list, and can access it by direct URL.`
2. Every test MUST include a database/state assertion. If the test only asserts on HTTP status or frontend text, it is incomplete.
3. Every test MUST create its own preconditions via API/database. Never assume data exists from a previous test.
4. Every test MUST clean up after itself. Prefer transactional cleanup.
5. For every write operation test, write a corresponding verification read. Create → verify exists. Update → verify changed. Delete → verify gone.
6. Test at least one error case per endpoint/functional requirement: invalid input, missing auth, forbidden access, not-found, duplicate/conflict.
7. Use deterministic waits, not sleeps. Poll for a condition with a timeout.
8. Use stable test-ID attributes for all element selection. If one doesn't exist, add it to the component.
9. Name tests as functional requirement specifications: not `test("submit form")` but `test("submitting a valid order creates a confirmed order record with correct line items and total")`.
10. When testing auth flows, always test both positive AND negative: valid credentials succeed AND invalid credentials fail with the correct error.
11. Never generate placeholder assertions. Every assertion must check a meaningful, specific value.
12. When unsure whether a test is thorough enough, it is not. Add more assertions. Verify at more layers. Test one more error case.

---

## Pre-Commit Quality Checks

Before every commit, agents MUST run and pass the project's full check suite. At minimum:

1. **Format** — run the project's formatter (e.g., `prettier`, `gofmt`)
2. **Lint** — run the project's linter with zero warnings/errors
3. **Type check** — if applicable (e.g., `tsc --noEmit`)
4. **Tests** — run the full test suite with coverage (during iteration, run specific tests for speed — see Agent Operation Guidance)

Pre-commit hooks may not run in agent sessions — apply formatting and checks manually.

---

## Code Style & Commits

- Follow existing code style and lint rules in each repository.
- Keep commits small and focused — include tests with behavior changes.
- Do not introduce new linting, formatting, or build tooling unless essential and approved.
- Follow the repository's established naming conventions.

---

## Coding Standards & Principles

All repositories MUST follow these software engineering principles. They apply to every language, framework, and layer in the stack.
Repository-level AGENTS.md or CLAUDE.md files may specify how each principle maps to project-specific patterns — those specifics take precedence over the general guidance here.

### SOLID Principles

| Principle | Rule | What it means in practice |
|-----------|------|---------------------------|
| **Single Responsibility (SRP)** | Every module, class, or function has exactly one reason to change | Split files that mix concerns (e.g., HTTP handling + business logic + persistence). Each layer owns its own responsibility. |
| **Open/Closed (OCP)** | Extend behavior through new implementations, not by modifying existing code | Use interfaces, strategy patterns, or composition. Avoid editing stable modules to add new variants. |
| **Liskov Substitution (LSP)** | Subtypes must be substitutable for their base types without breaking callers | Ensure implementations honor the full contract of their interface — preconditions, postconditions, and invariants. |
| **Interface Segregation (ISP)** | Clients should not depend on methods they don't use | Prefer small, focused interfaces over large ones. Split fat interfaces into cohesive groups. |
| **Dependency Inversion (DIP)** | Depend on abstractions, not concretions | High-level policy code MUST NOT import low-level infrastructure directly. Inject dependencies via constructors or configuration. |

### CLEAN Code

- **Meaningful names.** Variables, functions, classes, and files must reveal intent. No abbreviations unless they are universally understood in the domain (e.g., `id`, `url`, `db`).
- **Small functions.** Each function does one thing, at one level of abstraction. If a function needs a comment to explain what it does, it should be renamed or split.
- **Minimal arguments.** Prefer fewer function parameters. If a function requires many arguments, consider grouping related parameters into a value object or configuration type.
- **No side-effect surprises.** Functions that appear to be queries must not mutate state. Clearly separate commands (state changes) from queries (reads).
- **Consistent formatting.** Formatting is enforced by the project's configured tooling (see Pre-Commit Quality Checks). Do not manually override or fight the formatter.
- **Error handling is not an afterthought.** Handle errors at the appropriate layer. Don't swallow exceptions silently. Don't return `null` when an error type is more expressive.

### DRY — Don't Repeat Yourself

- **Eliminate knowledge duplication.** Every piece of business knowledge or logic must have a single, authoritative source.
  If the same rule exists in two places, extract it.
- **DRY applies to knowledge, not code.** Two blocks of code that look identical but represent different domain concepts are NOT duplication — do not merge them.
  Two blocks that look different but encode the same business rule ARE duplication — unify them.
- **Premature abstraction is worse than duplication.** Wait until you have at least three concrete instances before extracting a shared abstraction. Two similar cases do not justify a generic helper.

### DDD — Domain-Driven Design

- **Ubiquitous language.** Use the same terminology in code, tests, specs, and conversation. If the domain calls it a "market" or "session", the code uses `Market` or `Session` — not `item` or `context`.
- **Bounded contexts.** Each major subdomain has clear boundaries. Code in one context must not directly depend on the internals of another.
  Communicate across contexts through well-defined interfaces or events.
- **Aggregate roots.** Enforce invariants through aggregate roots. External code accesses an aggregate's children only through the root.
- **Value objects.** Use typed value objects (branded types, newtypes, or equivalent) for identifiers, quantities, and domain-specific data.
  Avoid passing raw primitives (`string`, `int`) when a domain type adds safety and meaning.
- **Repository pattern.** Persistence is abstracted behind repository interfaces that the domain defines. Infrastructure implements those interfaces.
  Domain code never imports ORM, SQL, or storage libraries directly.

### KISS — Keep It Simple

- Choose the simplest solution that satisfies the current requirements.
- Avoid clever code. Readable, boring code is better than compact, clever code.
- Do not add layers of abstraction, configuration, or indirection until complexity demands it.

### YAGNI — You Aren't Gonna Need It

- Do not build features, abstractions, or configuration for hypothetical future requirements.
- Implement exactly what the current story or task requires — no more.
- If a future need arises, it will be specified in a future story with its own tests and acceptance criteria.

### Defensive Coding at System Boundaries

- **Validate all external input.** Data from users, APIs, files, environment variables, and message queues must be validated and sanitized at the system boundary before entering domain logic.
- **Trust internal code.** Once data has crossed a validated boundary, do not re-validate at every function call. Excessive internal checks add noise without value.
- **Fail fast.** When an invariant is violated, fail immediately with a clear error rather than propagating bad state.

### Fail Loud, Never Fake

Prefer a visible failure over a silent fallback. A crashed system with a stack trace is a 5-minute fix; a system silently
returning fake data is a full day lost — and only discovered after the wrong data has caused downstream problems.

**Priority order when something can fail:**

1. **Works correctly** with real data.
2. **Falls back visibly** — degraded mode is signaled by a banner, log warning, metadata flag, or response field. The caller can tell.
3. **Fails with a clear error** — exception, non-zero exit, error response. The failure is observable.
4. **Silently degrades to look "fine"** — never acceptable.

**Forbidden patterns:**

- Bare `except:` / `catch (e) {}` blocks that swallow errors and return empty or default values with no logging.
- Generating plausible-looking sample, mock, or placeholder data when a real fetch, query, or computation fails.
- Returning hardcoded "success" responses from a function whose real work errored.
- Reporting "I've set up X" or "X is working" when X actually failed and a fallback was substituted.
- Disabling, skipping, or weakening tests to make a failing run look green.

**Disclosed fallbacks are fine.** A local model stepping in when a cloud API is down is good engineering — *as long as the
caller can tell.* Examples of acceptable disclosure: a `degraded: true` field on the response, a `WARN` log line with the
reason, a UI banner ("Showing cached data from 2h ago"), a metric increment on a `fallback_used` counter.

**Agentic directives:**

1. NEVER swallow an exception to keep output looking successful. Surface it, log it, or propagate it.
2. NEVER substitute synthetic, sample, or placeholder data for a failed real fetch without an explicit, disclosed fallback path.
3. NEVER report a task as complete if any step errored. Report the actual state — including what failed and why — even when the failure is inconvenient.
4. When adding a fallback, ALWAYS make it observable: log line, response flag, metric, or user-visible indicator.
5. When a test fails, fix the underlying cause. Do not delete, skip, or relax the assertion to make it pass.

### Separation of Concerns

- **Layered architecture.** Maintain clear boundaries between domain logic, application/use-case orchestration, and infrastructure (I/O, persistence, external services).
- **Direction of dependencies.** Dependencies always point inward — infrastructure depends on application, application depends on domain. Never the reverse.
- **No framework bleed.** Framework-specific types and annotations stay at the infrastructure/adapter layer. Domain and application layers must be framework-agnostic.

### Breaking Changes — Human Approval Required

Agents MUST NOT introduce breaking changes without explicit human approval. A breaking change is any modification that causes existing consumers, callers, or dependents to fail,
produce incorrect results, or require changes on their end. **When in doubt, treat it as breaking.**

**What constitutes a breaking change:**

| Layer | Breaking changes include |
|-------|------------------------|
| **API** | Removing/renaming endpoints or response fields, changing field types or response shapes, adding required parameters, tightening validation, changing error formats, changing auth requirements |
| **Database** | Dropping/renaming columns or tables, changing column types, adding NOT NULL without a default, removing defaults, dropping indexes that queries depend on, changing constraints |
| **Frontend** | Removing/renaming exported components/hooks/utilities, changing prop types or function signatures, removing design tokens or CSS variables, changing route paths |
| **Backend** | Removing/renaming exported functions/interfaces/types, changing function signatures or return types, changing event schemas, removing configuration options |
| **Shared contracts** | Removing/renaming fields in API schemas, changing message payload structures, modifying shared type definitions consumed by multiple services |

**Detection — tests are the primary safety net:**

- Existing tests encode existing contracts. If your change causes an existing test to fail, you have likely introduced a breaking change.
- **NEVER modify an existing test to make a breaking change pass.** Changing a test to accommodate new behavior is hiding the break, not fixing it.
New behavior gets new tests; existing tests protect existing contracts.
- If a test seems "wrong" or "outdated," flag it for human review. It may be the only documentation of a contract someone depends on.
- Before removing or changing anything, search the entire codebase for all references (including string-based references like route strings, config keys, and dynamic imports). Report the consumer count.

**When a breaking change is detected — stop and follow this protocol:**

1. **Stop immediately.** Do not commit the breaking change.
2. **Describe it clearly.** State exactly what is changing and why it qualifies as breaking.
3. **List what will break and for whom.** Specific file names, function names, test names, consumer services — not "some things might break."
4. **Propose a non-breaking alternative.** In most cases, one exists (see below).
5. **Wait for explicit human approval.** Do not interpret silence or general task intent as approval.

**Non-breaking alternatives (prefer in this order):**

1. **Additive changes** — Add new fields/endpoints/functions/columns alongside old ones. Do not replace.
2. **Deprecation + migration period** — Mark the old item as deprecated, add the replacement, document the migration path. Removal happens in a separate future change with human approval.
3. **Feature flags / versioning** — Gate new behavior behind a flag so old behavior remains the default.
4. **Adapter / compatibility layers** — Write a thin adapter mapping the old interface to the new implementation.
5. **Staged database changes** — Add new column → migrate data → update application code → deploy and verify →
drop old column in a separate, human-approved change. Never combine add and drop in a single migration.

**Agentic directives:**

1. NEVER remove or rename a public function, type, component, endpoint, field, column, route, event, or config option without human approval.
2. NEVER change the signature of a public function or the shape of an API response, event payload, or shared data structure without human approval.
3. NEVER tighten validation, add required fields, or add NOT NULL constraints without human approval.
4. ALWAYS search for all consumers of any symbol, endpoint, or schema element before modifying or removing it.
5. ALWAYS propose a non-breaking alternative first. Only present the breaking option alongside it.
6. ALWAYS run the existing test suite after changes. Treat test failures as breaking change signals, not as "tests that need updating."
7. ALWAYS use additive changes by default. Deprecate, then remove later in a separate change.
8. NEVER combine a destructive database migration (drop column, drop table, change type) with other changes in the same commit or PR.
9. When uncertain whether something is breaking, treat it as breaking. False positives are cheap. False negatives break production.

### Code Organization

- **Co-locate related code.** Tests live next to the code they test. Types live near the code that uses them. Avoid scattering related files across distant directories.
- **No barrel files** unless the project explicitly requires them. Re-export files (`index.ts`, `__init__.py`) add indirection and circular dependency risk.
- **Consistent file naming.** Follow the repository's documented naming convention for source files, test files, components, and modules.

---

## Pull Request Reviews

- When addressing PR review comments, **mark each resolved comment thread as Resolved** on GitHub after the fix is pushed.
- Use the GitHub GraphQL API via `gh api graphql` with the `resolveReviewThread` mutation:

  ```bash
  gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "PRRT_..."}) { thread { id isResolved } } }'
  ```

  Retrieve thread IDs first with a `reviewThreads` query on the pull request.
- Resolve all addressed threads in one pass after pushing the fix commit.

---

## Security & Secrets

- **Never commit secrets.** Use environment variables, GitHub Actions secrets, or an external secret manager.
- Do not commit `.env` files, credentials, API keys, or tokens.
- Request maintainer review for changes requiring elevated permissions or access to sensitive data.

---

## BMAD Method — Spec-Driven Development

All project repositories MUST install and use the [BMAD Method](https://github.com/bmad-code-org/BMAD-METHOD) to enforce **Spec-Driven Development (SDD)**.
BMAD provides structured agents, workflows, and planning artifacts that ensure every feature is fully specified before implementation begins.

### Setup

- Install BMAD in every new repo: `npx bmad-method install`
- Keep BMAD up to date: `npx bmad-method install` (re-run periodically)

### Required Workflow

1. **Plan before you build.** Every feature, epic, or significant change MUST have planning artifacts before implementation starts. Use BMAD agents (PM, Architect, UX Designer) to produce them.
2. **Planning artifacts live in `_bmad-output/planning-artifacts/`** and include:
   - Product Brief — vision, target users, success criteria
   - PRD — functional and non-functional requirements
   - Architecture — technical decisions, component design, data model
   - UX Design Specification — user flows, wireframes, accessibility
   - Epics & Stories — implementation-ready backlog with acceptance criteria
3. **Always consult planning artifacts before implementing.** They are the source of truth for what to build and how.
If artifacts are missing or outdated, update them first — do not implement against stale specs.
4. **Use BMAD stories for implementation.** Stories created via `bmad-create-story` contain all context an agent needs. Use `bmad-dev-story` to execute them.
5. **Validate readiness before sprints.** Run `bmad-check-implementation-readiness` to ensure specs are complete before starting implementation work.

### BMAD Agents Available

Use BMAD's specialized agents via their slash commands: `bmad-pm` (Product Manager), `bmad-architect` (Solution Architect),
`bmad-ux-designer` (UX Designer), `bmad-dev` (Developer), `bmad-tea` (Test Architect), `bmad-qa` (QA), `bmad-sm` (Scrum Master), and others.
Run `bmad-help` for guidance on which agent or workflow to use next.

---

## CI Quality Gates — Required Checks

All repositories MUST configure and enforce the following CI checks. PRs cannot be merged until all checks pass.

### Security & Code Analysis

| Check | Tool | Purpose |
|-------|------|---------|
| **Static analysis (SAST)** | [CodeQL](https://github.com/github/codeql-action) | Detect security vulnerabilities, bugs, and anti-patterns |
| **Code quality** | [SonarCloud](https://sonarcloud.io/) | Maintainability, reliability, security hotspots, duplication |

### Automated Code Review

| Check | Tool | Purpose |
|-------|------|---------|
| **AI code review** | [CodeRabbit](https://coderabbit.ai/) | Automated PR review for logic errors, best practices, and suggestions |
| **AI code review** | [GitHub Copilot](https://docs.github.com/en/copilot/using-github-copilot/code-review/using-copilot-code-review) | Copilot code review for security, performance, and correctness |

### Code Quality

| Check | Tool | Purpose |
|-------|------|---------|
| **Linting** | Project linter (ESLint, golangci-lint, etc.) | Zero warnings, zero errors |
| **Formatting** | Project formatter (Prettier, gofmt, etc.) | Consistent code style |
| **Type checking** | Language type checker (tsc, etc.) | Type safety (where applicable) |

### Testing

| Check | Tool | Purpose |
|-------|------|---------|
| **Unit & integration tests** | Project test framework (Jest, Vitest, etc.) | All tests must pass |
| **Code coverage** | Coverage reporter | Must meet repo-defined thresholds; PRs that reduce coverage are rejected |

### Enforcement

- All checks above are configured as **required status checks** on the default branch.
- **Iterate until all CI checks pass.** Before requesting review or marking a PR as ready:
  - Run all checks locally (format, lint, typecheck, tests, coverage)
  - If any check fails in CI, investigate locally, fix the issue, and re-run
  - Continue iterating until all checks pass both locally and in CI
- Never bypass CI gates or weaken thresholds to make a PR pass.
- Address CodeRabbit and Copilot review comments the same way you address human reviewer comments — fix or explicitly justify skipping with a reply.

### Branch Protection & Repository Rulesets

This org enforces branch protection via **classic branch protection rules** and **repository rulesets** on all repos. Both layers are active and additive — the strictest requirement wins.

#### Classic Branch Protection (all repos)

| Setting | Value |
|---------|-------|
| **Required status checks** | Repo-specific (see table below) |
| **Require branches to be up to date** | `strict: true` |
| **Require approving reviews** | 1 |
| **Dismiss stale reviews** | No |
| **Require code owner reviews** | No |
| **Enforce for admins** | Yes |
| **Allow force pushes** | No |
| **Allow deletions** | No |

#### Required Status Checks by Repo

| Repo | Required Checks |
|------|----------------|
| **broodly** | `Analyze` (CodeQL) |
| **markets** | `SonarCloud`, `claude` |
| **google-app-scripts** | `build-and-test` |
| **TalkTerm** | `Analyze (Python)` (CodeQL) |
| **ContentTwin** | `SonarCloud` |

#### Repository Rulesets — `pr-quality` (all repos)

| Setting | Value |
|---------|-------|
| **Required approving reviews** | 1 |
| **Required review thread resolution** | **Yes** — all review comment threads must be marked Resolved before merge |
| **Dismiss stale reviews on push** | No |
| **Require code owner review** | No |
| **Require last push approval** | No |
| **Allowed merge methods** | Squash only |

> **google-app-scripts** has an additional ruleset (`protect-branches`) with CodeQL code scanning enforcement and stricter review settings.

#### SonarCloud Check Names

SonarCloud check names may not match exactly across repos — expect check name mismatches. If a merge is blocked by a "check expected" error,
first identify the exact required check name(s), the actual check name reported, and the `app_id`. Then fix the branch protection configuration.
Use `gh pr merge --admin` only with explicit user approval and only after confirming all intended quality gates have passed.

#### Thread Resolution Policy

- **All review threads must be resolved before merge.** This is enforced by the `pr-quality` ruleset.
- Agents MUST address and resolve Copilot, CodeRabbit, and human review comments before merging.
- For Dependabot auto-merge: the auto-merge workflow automatically resolves AI reviewer threads on patch/minor dependency bumps.
- **Do not retry a failing merge more than twice** without telling the user what is blocking it. Surface the specific check name, status, and reason before any override is considered.

#### Dependabot Auto-Merge

The `dependabot-automerge.yml` workflow handles automatic merging of Dependabot PRs:

| Behavior | Detail |
|----------|--------|
| **Eligible updates** | Patch, minor, and indirect dependency bumps |
| **Major version bumps** | Require manual review and approval |
| **Merge strategy** | `gh pr merge --squash --auto` (queues merge until all checks pass) |
| **AI reviewers** | Copilot/CodeRabbit threads are auto-resolved by the workflow |
| **Approval** | GitHub App token provides the required approving review |

#### Pull Request Limits (automation open-PR cap)

The org enforces a **soft ceiling on concurrent open, non-draft automation PRs
org-wide** so automation cannot outrun merge throughput and inflate the
auto-rebase fan-out. Full standard, rationale, and operator runbook:
[`standards/pr-limits.md`](https://github.com/petry-projects/.github/blob/main/standards/pr-limits.md).

- **GitHub has no native "max open PRs" surface** (no repo setting, org setting,
  or ruleset rule — verified in the [ADR](https://github.com/petry-projects/.github/blob/main/docs/initiatives/pull-request-limits-adr.md)),
  so this is enforced **source-side** by [`scripts/lib/pr-limit-gate.sh`](https://github.com/petry-projects/.github/blob/main/scripts/lib/pr-limit-gate.sh):
  a PR-creating workflow asks the gate before opening a PR and **defers** (never
  fails or closes) when the queue is at the cap. Live-path wiring is Story 3 (#508).
- **The configured value lives only in [`standards/pr-limits.json`](https://github.com/petry-projects/.github/blob/main/standards/pr-limits.json)** —
  the single source of truth. Read it with `jq`; never hardcode or restate it.

> **Exempt actors are sanctioned policy, not drift.** `dependabot[bot]`,
> `OrganizationAdmin`, `@petry-projects/org-leads`, the `dependabot-automerge-petry`
> app, and `security`-labeled PRs are on the cap's exempt list — never blocked
> and never counted. This mirrors the ruleset bypass-actor allowance (see
> [Ruleset remediation](https://github.com/petry-projects/.github/blob/main/standards/ruleset-remediation-runbook.md)):
> `dependabot[bot]` is already bounded by its own per-ecosystem
> `open-pull-requests-limit` (so counting it here would double-cap and could
> starve a security PR), the human/admin actors are break-glass and maintainer
> traffic, and the app only operates on existing PRs. A compliance audit should
> treat these as intentional exemptions. To change the cap or the exempt list,
> follow the runbook in [`standards/pr-limits.md`](https://github.com/petry-projects/.github/blob/main/standards/pr-limits.md).

---

## Multi-Agent Isolation — Git Worktrees

When multiple agents work on the same repository concurrently, they MUST use **isolated workspaces** to prevent conflicts.
Git worktrees are the industry-standard isolation primitive — used by Claude Code, Cursor, Windsurf, Augment Intent, and dmux.
Cloud agents (OpenAI Codex, GitHub Copilot, Devin) use containers or ephemeral environments that provide equivalent isolation.

Never have two agents working in the same working directory simultaneously.

### Rules

1. **One workspace per agent.** Every agent performing code changes MUST operate in its own isolated workspace
   (git worktree, container, or ephemeral environment). This applies to Claude Code (`isolation: "worktree"` or `--worktree`),
   Cursor parallel agents, GitHub Copilot coding agent, OpenAI Codex, and any other AI agent tool.
2. **One agent per story/task.** Each workspace maps to exactly one BMAD story, feature, or bug fix. Do not assign the same story to multiple agents.
3. **No overlapping file ownership.** Two agents MUST NOT modify the same file concurrently. If stories touch shared files
   (e.g., a shared type definition, config, or lockfile), serialize those stories — do not run them in parallel.
   This is the single most important rule for multi-agent work.
4. **Branch from the default branch** — unless using a stacked PR workflow
(see [Stacked PRs for Epic/Feature Development](#stacked-prs-for-epicfeature-development)).
Outside a stacked-Epic/Feature workflow, workspaces MUST branch from the repository's configured default branch (for example, `origin/main`).
You MAY use `origin/HEAD` as a shortcut when it is correctly configured, but MUST NOT rely on it being present.
Never branch from another agent's branch **except** when (a) Epics/Features are part of a declared stack and the child Epic/Feature branches
from its parent Epic/Feature's branch, or (b) story worktrees/branches are created from the Epic/Feature integration branch
as defined in the stacked-PR workflow.
5. **One PR per workspace.** Each workspace produces exactly one pull request. Do not combine unrelated changes.
(In a stacked-Epic/Feature workflow, story worktrees may optionally produce short-lived PRs targeting the Epic/Feature branch
for review — these are internal integration PRs, not standalone feature PRs.)
6. **3–5 parallel agents max.** Coordination overhead increases non-linearly. Limit concurrent agents to 3–5 per repository.

### Detecting File Overlap

Before launching parallel agents, verify that stories won't modify the same files:

1. Review each story's acceptance criteria and implementation scope for shared files
2. Use `git log --stat` on recent similar changes to identify likely touched files
3. If any overlap is detected or uncertain, serialize the stories — do not run them in parallel

### Worktree Naming Convention

Use descriptive worktree names that identify the scope. For tools that auto-generate branch names from your input (see table below), the name you choose flows into the branch name automatically.

| Tool | You provide | Branch created |
|------|------------|----------------|
| Claude Code (`--worktree <name>`) | `S-3.1-hive-health-card` | `worktree-S-3.1-hive-health-card` |
| Claude Code subagent (`isolation: "worktree"`) | Agent `name` field | `worktree-<name>` |
| GitHub Copilot coding agent | Task description | `copilot/<descriptive-name>` (auto) |
| Cursor parallel agents | Prompt | `feat-N-<random>` (auto) |
| Manual worktree | Full branch name | Whatever you specify |

**Name format:** `<story-or-task-id>-<short-description>`

Examples: `S-3.1-hive-health-card`, `fix-auth-token-expiry`, `S-2.4-offline-sync-banner`

### Tool-Specific Setup

**Claude Code subagents** — set `isolation: "worktree"` in the agent definition:

```yaml
---
name: S-3.1-hive-health-card
isolation: "worktree"
---
```

**Claude Code CLI sessions** — start in a named worktree:

```bash
claude --worktree S-3.1-hive-health-card
```

**GitHub Copilot coding agent** — assign a task via GitHub Issues or the Copilot panel. Copilot creates its own branch (`copilot/...`) and ephemeral environment automatically.

**OpenAI Codex** — use worktree mode in the Codex app, or assign tasks to the cloud agent which runs in isolated containers.

**Manual worktree** (for tools without built-in support):

```bash
git worktree add .worktrees/<name> -b agent/<story-id>-<description>
cd .worktrees/<name>
# run agent session here
```

### Environment & Dependencies

- Git worktrees are fresh checkouts — gitignored files (`.env`, `.env.local`) are NOT copied automatically.
- For Claude Code: add a **`.worktreeinclude`** file at the repo root listing gitignored files that should be copied into new worktrees:

  ```text
  .env
  .env.local
  ```

- After entering a worktree, **install dependencies** (`npm install`, `go mod download`, etc.) before starting work.

### Cleanup

- If the worktree has **no changes**, it is automatically removed when the agent session ends (Claude Code, Cursor).
- If the worktree has **uncommitted changes**, the agent MUST commit or discard before exiting. Do not leave dirty worktrees.
- After a PR is merged, remove the worktree and its branch:

  ```bash
  git worktree remove <worktree-path>
  git branch -d <branch-name>  # safe delete; may fail after squash/rebase merges
  # If the above fails and you've confirmed the PR is merged:
  git branch -D <branch-name>
  ```

### Repository Configuration

Add worktree directories to the project's `.gitignore`:

```gitignore
# Agent worktrees
.claude/worktrees/
.worktrees/
```

### Multi-Repo Orchestration

When working across multiple repositories, use separate agents to work on each repo in parallel. Each agent MUST:

1. **Use a separate clone or working directory per repo** — never share a working directory between repos; within each repo, use separate worktrees or isolated environments per agent/task
2. **Work only on its assigned repo** — do not modify files in other repos
3. **Report back status when done** — include PR URL, CI status, and any blockers

Do NOT share branches or state between agents operating on different repos.

### Coordination Checklist (for humans orchestrating multiple agents)

Before launching parallel agents, verify:

- [ ] Each agent has a distinct story/task assignment
- [ ] No two agents will modify the same files
- [ ] Shared dependencies (lockfiles, generated types) are up to date on the default branch before agents start
- [ ] If stories share a dependency file, run them sequentially, not in parallel
- [ ] No more than 3–5 agents are running concurrently on the same repository

---

## Multi-Agent Issue Coordination

When multiple autonomous agents work from the same issue queue (e.g., during a compliance remediation run), they MUST
coordinate via GitHub labels and PR checks to prevent duplicate work. This protocol is mandatory for any agent picking
up issues from a shared backlog.

### Claim-Before-Work Protocol

Before starting work on **any** GitHub issue, an agent MUST:

1. **Check the `in-progress` label.** If the issue already has `in-progress`, skip it — another agent owns it.

   ```bash
   gh issue view <issue-number> --repo <owner>/<repo> --json labels \
     --jq '.labels[].name' | grep -q '^in-progress$' && echo "SKIP"
   ```

2. **Check for an open PR referencing the issue.** If one exists, skip the issue or comment on the PR instead.

   ```bash
   gh pr list --repo <owner>/<repo> --state open --search "closes #<issue-number>" --json number | \
     jq 'length > 0'
   ```

3. **Claim the issue immediately** by adding the `in-progress` label — before writing any code.

   ```bash
   gh issue edit <issue-number> --repo <owner>/<repo> --add-label "in-progress"
   ```

4. **Release the claim** if you abandon the issue without opening a PR:

   ```bash
   gh issue edit <issue-number> --repo <owner>/<repo> --remove-label "in-progress"
   ```

The `in-progress` label is created by `apply-repo-settings.sh` and is part of the standard label set for all repos.

### File-Conflict Check

Before creating a new file, check whether any open PR in the repository already creates that file.
If found, comment on the existing PR rather than creating a competing one.

```bash
# Check if any open PR already creates the target file
gh pr list --repo <owner>/<repo> --state open --json files \
  --jq '.[].files[].path' | grep -qx "<path/to/file>" && echo "FILE ALREADY IN OPEN PR"
```

### Compliance Umbrella Issues

The compliance audit creates one **umbrella issue** per run (in `petry-projects/.github`, labeled `claude`) that groups
all findings by remediation category. When picking up compliance work:

- Work from the umbrella issue — not from individual finding issues.
- Address an entire remediation category in a single PR (e.g., all label fixes, all ruleset fixes) to avoid N competing PRs for the same script.
- Individual finding issues have the `compliance-audit` label only; they are NOT labeled `claude` and do not need to be claimed individually.

---

## Stacked PRs for Epic/Feature Development

When a project has multiple Epics/Features with **sequential dependencies** — where Epic 2 builds on the foundation laid by Epic 1,
Epic 3 extends Epic 2, and so on — the standard "branch from main" model forces each Epic/Feature to wait for the previous one's PR
to fully merge before work can begin. Stacked PRs eliminate this bottleneck by letting each Epic/Feature's branch build on the previous
one's branch, forming a chain that merges bottom-up.

Each Epic/Feature produces a **single PR** containing all of its stories. The stack is a chain of Epic/Feature-level PRs:

```text
main ← Epic-1-PR ← Epic-2-PR ← Epic-3-PR ← Epic-4-PR
```

### How It Works

Each Epic/Feature gets one long-lived **Epic/Feature branch** (also called its integration branch).
Multiple agents work stories concurrently in separate worktrees that branch from the Epic/Feature branch,
then merge their completed stories back into it. The Epic/Feature branch accumulates all story work and becomes one PR in the stack.

| PR | Source branch | Target branch |
|----|---------------|---------------|
| Epic 1 PR | `epic-1/foundation` | `main` |
| Epic 2 PR | `epic-2/core-features` | `epic-1/foundation` |
| Epic 3 PR | `epic-3/integrations` | `epic-2/core-features` |
| Epic 4 PR | `epic-4/polish` | `epic-3/integrations` |

When Epic 1's PR merges into `main`, Epic 2's PR is retargeted to `main`, and so on up the stack.

### Rules for Stacked Epic/Feature PRs

1. **One PR per Epic/Feature.** Each Epic/Feature produces exactly one PR. All stories within it are merged into its branch.
2. **Stacks are strictly linear.** No branching within a stack (no diamond or tree shapes). One parent, one child.
3. **Maximum stack depth: 4.** Deeper stacks become fragile and painful to rebase. If a project has more than 4 sequential Epics/Features, look for opportunities to merge intermediate ones before continuing.
4. **Parallel agents within an Epic/Feature.** Multiple agents CAN work on stories within the same Epic/Feature concurrently —
each in its own worktree branching from the Epic/Feature branch. The standard multi-agent isolation rules apply:
no two agents modify the same file. Story worktrees merge back into the Epic/Feature branch when complete.
5. **Sprints within an Epic/Feature may overlap.** If Sprint 2's stories are independent of Sprint 1's stories,
agents may work on both sprints concurrently. Only serialize sprints when later stories depend on earlier ones.
6. **Independent stacks CAN run in parallel.** If your project has two separate dependency chains (e.g., A1→A2 and B1→B2),
run those stacks concurrently with separate agents. The standard multi-agent isolation rules apply — no overlapping file ownership across stacks.
7. **File ownership within a stack is cumulative.** Files touched by Epic 1 may also be touched by Epic 2
(that's the nature of sequential dependency). Ensure agents in the child Epic/Feature coordinate with the parent's completed state.
8. **Bottom-up merge order is mandatory.** Always merge the bottom PR first, then retarget the next PR to `main`, and so on. Never merge out of order.

### Workflow — Planning the Stack

Before any agent starts, the orchestrator (human or planning agent) identifies the Epic/Feature dependency order and documents the stack plan:

```markdown
## Project Stack Plan
1. Epic 1 — Foundation: data model, core types, DB schema (base → main)
2. Epic 2 — Core Features: service layer, business logic (base → Epic 1)
3. Epic 3 — Integrations: API endpoints, external services (base → Epic 2)
4. Epic 4 — Polish: UI refinements, error handling, docs (base → Epic 3)
```

Each Epic/Feature should list its stories, and the plan should call out which files/modules each one owns.

### Workflow — Implementing the Stack

**Step 1: Create the Epic/Feature branch.** The orchestrator (or first agent) creates the branch from its parent:

```bash
# Epic 1 branches from main
git checkout main && git pull origin main
git checkout -b epic-1/foundation
git push -u origin epic-1/foundation

# Open the Epic PR (initially empty or with scaffolding)
gh pr create --base main --title "Epic 1: Foundation" --body "..." --draft
```

**Step 2: Agents work stories in parallel worktrees.** Each agent creates a story worktree branching from the Epic/Feature branch:

```bash
# Agent 1 — Story S-1.1
git worktree add .worktrees/S-1.1-data-model -b epic-1/S-1.1-data-model origin/epic-1/foundation

# Agent 2 — Story S-1.2 (concurrent, no file overlap with S-1.1)
git worktree add .worktrees/S-1.2-core-types -b epic-1/S-1.2-core-types origin/epic-1/foundation

# Agent 3 — Story S-1.3 (concurrent, no file overlap)
git worktree add .worktrees/S-1.3-db-schema -b epic-1/S-1.3-db-schema origin/epic-1/foundation
```

Each agent implements its story, runs quality checks, and pushes.

**Step 3: Merge stories back into the Epic/Feature branch.** As stories complete, merge them into the Epic/Feature branch.
See [Story and Sprint Organization Within an Epic/Feature](#story-and-sprint-organization-within-an-epicfeature) for merge strategies and commands.

**Step 4: Create the next Epic/Feature branch.** Once all stories that the next Epic/Feature depends on have been merged into the previous branch, create the next one:

```bash
# Epic 2 branches from Epic 1
git checkout epic-1/foundation && git pull origin epic-1/foundation
git checkout -b epic-2/core-features
git push -u origin epic-2/core-features
gh pr create --base epic-1/foundation --title "Epic 2: Core Features" --body "..." --draft
```

Agents then work Epic 2's stories in parallel worktrees branching from `epic-2/core-features`, following the same pattern.

**Step 5: Repeat** for each subsequent Epic/Feature in the stack.

### Workflow — Merging the Stack

1. **Merge the bottom PR** (Epic 1 → `main`) using the repo's standard merge strategy.
2. **Retarget the next PR** to `main`:

   ```bash
   gh pr edit <epic-2-PR-number> --base main
   ```

3. **Rebase the next branch** onto `main` to incorporate the merge and resolve any squash/rebase differences:

   ```bash
   # In the Epic 2 worktree
   git fetch origin main
   git rebase origin/main
   git push --force-with-lease
   ```

4. **Review and merge Epic 2** → `main`. Repeat for Epic 3, Epic 4, etc.

### Workflow — Handling Changes to a Lower Epic/Feature PR

If a reviewer requests changes to a lower Epic/Feature PR (e.g., Epic 1), the agent making fixes MUST propagate changes upward:

1. Make the fix on Epic 1's branch and push.
2. For each child branch in order, rebase onto the updated parent:

   ```bash
   # In Epic 2 worktree
   git fetch origin epic-1/foundation
   git rebase origin/epic-1/foundation
   # Resolve any conflicts
   git push --force-with-lease
   ```

3. Repeat for Epic 3 if it exists (rebasing onto Epic 2's updated branch), and so on.

If conflicts are extensive, consider collapsing the stack — merge what you can into `main` and rebuild the remaining Epics/Features from there.

### Keeping Epic/Feature Branches in Sync with Main

If `main` advances while a stack is in progress (e.g., hotfixes or other PRs merge), periodically rebase the bottom Epic/Feature branch
onto `main` and propagate upward through the stack. Do this between Sprints or at natural breakpoints — not while story agents are
actively working. A long-diverged Epic/Feature branch will produce painful conflicts at merge time.

### Story and Sprint Organization Within an Epic/Feature

The Epic/Feature branch accumulates completed stories. Agents do not work directly on the Epic/Feature branch. Instead, each agent works in its own story worktree that branches from it.

**Sprint-level organization:**

Epics/Features are typically broken into Sprints, each containing a set of stories. Within a Sprint, all stories with no file overlap can be worked in parallel by separate agents. Across Sprints:

- **Independent Sprints** (no data/API dependency between them) — run concurrently.
- **Dependent Sprints** (Sprint 2 stories require Sprint 1 output) — run sequentially. Merge all Sprint 1 stories into the Epic/Feature branch before Sprint 2 agents branch from it.

```text
Epic 1 branch
├── Sprint 1 (parallel agents)
│   ├── Agent 1 → S-1.1 worktree
│   ├── Agent 2 → S-1.2 worktree
│   └── Agent 3 → S-1.3 worktree
│   (all merge back into Epic/Feature branch)
├── Sprint 2 (parallel agents, after Sprint 1 merges)
│   ├── Agent 1 → S-1.4 worktree
│   └── Agent 2 → S-1.5 worktree
│   (merge back into Epic/Feature branch)
└── Epic/Feature PR → targets parent branch or main
```

**Story worktree naming convention** (extends the general convention in [Worktree Naming Convention](#worktree-naming-convention) with an Epic/Feature prefix):

```text
.worktrees/<epic-id>-<story-id>-<description>
```

Branch name: `<epic-id>/<story-id>-<description>`

Examples: `epic-1/S-1.1-data-model`, `epic-2/S-2.3-auth-middleware`

**Merging stories back into the Epic/Feature branch:**

Stories can be integrated via direct merge or via short-lived PRs targeting the Epic/Feature branch:

| Method | When to use |
|--------|-------------|
| **Direct merge** (`git merge`) | Small team, high trust, fast iteration |
| **Story PRs** (PR targeting Epic/Feature branch) | Larger team, want per-story review before integration |

Direct merge commands (run from the Epic/Feature branch worktree):

```bash
# Fetch and merge a completed story
git checkout epic-1/foundation
git fetch origin epic-1/S-1.1-data-model
git merge origin/epic-1/S-1.1-data-model
git push origin epic-1/foundation
```

If a story branch has fallen behind the Epic/Feature branch (e.g., other stories merged first), rebase it before merging. Run this from within the story worktree:

```bash
git fetch origin epic-1/foundation
git rebase origin/epic-1/foundation
# resolve any conflicts, push, then merge into the Epic/Feature branch
git push --force-with-lease
```

**Story worktree cleanup:** Remove story worktrees and branches immediately after they are merged into the Epic/Feature branch — do not wait for the Epic/Feature PR to merge into `main`.

Either way, the Epic/Feature-level PR in the stack is the final gate for review and CI before merging into the parent or `main`.

### Combining Stacked Epics/Features with Parallel Agents

Stacked PRs and parallel agents operate at different levels and are fully complementary:

| Level | Parallelism | Constraint |
|-------|-------------|------------|
| **Across independent Epic/Feature chains** | Full parallel — separate stacks run concurrently | No file overlap between chains |
| **Across Epics/Features in the same stack** | Sequential — child starts after parent branch is stable | Child branches from parent |
| **Within an Epic/Feature (across Sprints)** | Parallel if Sprints are independent; sequential if dependent | Dependent Sprints wait for prior Sprint to merge into Epic/Feature branch |
| **Within a Sprint** | Full parallel — multiple agents, one story each | No file overlap between stories |

Example — a project with two Epic/Feature chains and six agents:

| Agent | Chain | Epic/Feature | Sprint | Story | Branch base | Status |
|-------|-------|------|--------|-------|-------------|--------|
| Agent 1 | A | Epic 1 | Sprint 1 | S-1.1 (data model) | `epic-1/foundation` | Active |
| Agent 2 | A | Epic 1 | Sprint 1 | S-1.2 (core types) | `epic-1/foundation` | Active (parallel) |
| Agent 3 | A | Epic 1 | Sprint 1 | S-1.3 (db schema) | `epic-1/foundation` | Active (parallel) |
| Agent 4 | B | Epic 3 | Sprint 1 | S-3.1 (auth) | `epic-3/auth` | Active (parallel, different chain) |
| Agent 5 | B | Epic 3 | Sprint 1 | S-3.2 (sessions) | `epic-3/auth` | Active (parallel) |
| Agent 6 | A | Epic 2 | — | — | `epic-1/foundation` | Waiting (parent incomplete) |

Once Agents 1–3 merge their stories into `epic-1/foundation`, Agent 6 can begin Epic 2's stories. Meanwhile, Agents 4–5 continue independently on Chain B.

### Stack Coordination Checklist

Before starting a stacked Epic/Feature workflow, verify:

- [ ] Epics/Features have genuine sequential dependencies (not just conceptual ordering)
- [ ] Stack depth is 4 or fewer
- [ ] Stack plan is documented with Epic/Feature order, parent relationships, and Sprint breakdown
- [ ] Each Epic/Feature's file/module ownership is identified — no overlap across parallel stacks
- [ ] Within each Epic/Feature, stories are assigned to Sprints with file overlap analysis complete
- [ ] Stories within each Sprint have no file overlap (safe for parallel agents)
- [ ] Dependent Sprints are clearly marked — they wait for prior Sprint to merge into Epic/Feature branch
- [ ] Stories within each Epic/Feature are scoped and ready for implementation (BMAD artifacts complete)
- [ ] No more than 3–5 agents are running concurrently across all active Epics/Features in the repository

### Tooling Notes

- **GitHub natively supports stacked PRs** — each PR targets a non-default base branch. The PR diff shows only the changes introduced by that Epic/Feature, not the full stack.
- **`gh` CLI** supports `--base` for targeting parent branches and `gh pr edit --base` for retargeting after merges.
- **Graphite, git-town, and spr** are dedicated stacked PR tools that automate rebasing and retargeting. Consider adopting one if stacks become a frequent workflow.
- **CI runs on each PR independently.** Ensure CI is configured to run against the PR's base branch, not just `main`. Most CI systems (GitHub Actions, etc.) handle this correctly by default.
- **PR review is incremental.** Reviewers see only the diff between the Epic/Feature branch and its parent — not the entire stack. This keeps reviews focused and manageable.

---

## Agent Operation Guidance

- Prefer interactive or dev commands when iterating; avoid running production-only commands from an agent session.
- Keep dependencies and lockfiles in sync.
- Prefer small, focused commands — run specific tests rather than the full suite when iterating (the full suite is still required before committing; see Pre-Commit Quality Checks).
- Document project-specific dev/test/run commands and required environment variables in the repo's own AGENTS.md or README.
- Every repository-level AGENTS.md or README MUST include sections following this template:

  ```markdown
  ## Local Development Commands
  - Install: `<install command>`
  - Dev run: `<dev command>`
  - Test: `<test command>`
  - Lint: `<lint command>`
  - Typecheck (if applicable): `<typecheck command>`

  ## Required Environment Variables
  - `VAR_NAME`: purpose, allowed values, example
  ```

---

## Structured Logging

All services MUST use structured logging. Structured logs are machine-parseable, correlatable across services, and essential for observability.
These rules apply to every language and framework in the stack.

### Format & Fields

- **Emit all logs as JSON objects in production.** Never use unstructured print statements or string interpolation for application logs.
- **Every log line MUST include these baseline fields.** Configure your logging library at initialization to automatically include
  `timestamp`, `service`, and `version` in every log entry — do not rely on developers adding these per-call.

  | Field | Format | Example |
  |-------|--------|---------|
  | `timestamp` | ISO 8601 / RFC 3339, always UTC | `2026-03-29T14:22:01.123Z` |
  | `level` | `debug`, `info`, `warn`, `error`, `fatal` | `info` |
  | `msg` | Static, human-readable string (no interpolated variables) | `order placed` |
  | `service` | Name of the emitting service | `markets-api` |
  | `version` | Deployed version or git SHA | `a1b2c3d` |

- **Put variable data in fields, not in the message string.**
  - WRONG: `logger.Info("User 1234 placed order 5678")`
  - RIGHT: `logger.Info("order placed", "user_id", "1234", "order_id", "5678")`
- **Use `snake_case` for all field names.** Check existing logs in the codebase for canonical field names before inventing new ones.
- **Canonical field names:** `user_id`, `request_id`, `correlation_id`, `causation_id`, `trace_id`, `span_id`, `duration_ms`,
`http_method`, `http_path`, `http_status`, `error_message`, `error_stack`.
- **Relationship between correlation IDs:** `request_id` is assigned per inbound request. `correlation_id` tracks a logical operation
  across multiple services/events (often equal to the originating `request_id`). `causation_id` identifies the direct parent event
  or command that triggered the current action. `trace_id` and `span_id` are OpenTelemetry-specific and bridge logs to distributed traces.
  When CQRS domain events include `correlation_id`/`causation_id` in metadata, these MUST use the same field names and values
  as the logging context.

### Correlation & Tracing

- **Every inbound request MUST be assigned a `request_id`.** If the caller provides one via `X-Request-ID` header, propagate it. Otherwise, generate a UUIDv4.
- **Attach `request_id` to the logger context at the middleware layer.** All subsequent logs within that request lifecycle inherit it automatically.
- **When making outbound calls (HTTP, gRPC, queues), propagate `request_id` in headers.**
- **If OpenTelemetry is in use, include `trace_id` and `span_id` in every log line.** These fields bridge logs to distributed traces.

### Log Levels

| Level | Use when | Examples |
|-------|----------|----------|
| **DEBUG** | Detailed diagnostics, useful only during development. **Disabled in production by default.** | Variable values, SQL queries, cache hit/miss |
| **INFO** | Normal operational events confirming the system works as expected | Request completed, job finished, service started |
| **WARN** | Something unexpected but the system recovered or can continue | Retry attempted, deprecated API called, slow query detected |
| **ERROR** | An operation failed and could not be completed. Every ERROR must be actionable | External service call failed after retries, database write failed |
| **FATAL** | The process cannot continue and will exit. Use extremely sparingly | Failed to bind port, required config missing at startup |

**Rules:**

- A 404 for a missing resource is INFO, not ERROR.
- Validation failures caused by user input are WARN at most, usually INFO.
- Every ERROR and FATAL log MUST include `error_message` (string) and, where available, `error_stack` (string).
If the logging library supports automatic error serialization (e.g., passing an error object that the library expands
into `error_message` and `error_stack` fields), use that mechanism — but verify the emitted JSON contains the canonical field names.
- If an error is caught and handled with a fallback, log at WARN, not ERROR.

### What to Log

- **Request/response boundaries:** method, path, status, `duration_ms`, request size.
- **State transitions:** job started/completed/failed, circuit breaker changes, cache invalidation.
- **Errors with full context:** the attempted operation, input parameters (sanitized), error message and type, retry count, stack trace for unexpected errors.
- **Security events:** authentication success/failure (without credentials), authorization denial, rate limiting triggered, admin operations.
- **Performance data:** external call durations, database query durations above threshold.

### What NOT to Log

- **NEVER log passwords, API keys, secrets, tokens (JWT, session, bearer), or private keys.**
- **NEVER log full request/response bodies that may contain `Authorization`, `Cookie`, `Set-Cookie`, or `X-API-Key` headers.**
- **NEVER log PII in plain text:** email addresses, phone numbers, physical addresses, SSNs, credit card numbers.
- **NEVER log at DEBUG level in production by default.** DEBUG must be gated behind a runtime flag.
- **NEVER log inside tight loops** (per-item in a batch). Log once before and once after with a count.
- **NEVER use `log.Fatal` or `log.Panic` in library code.** Return errors; let the caller decide.

### Agentic Directives

These rules are deterministic — apply them whenever writing or modifying code:

1. When creating any new HTTP/GraphQL handler, add structured logging middleware that logs: method, path/operation, status, `duration_ms`, `request_id`.
2. When adding a logger call, ALWAYS use structured key-value pairs. NEVER concatenate or interpolate variables into the message string.
3. When handling an error, log with at minimum: `level=error`, `msg=<static description>`, `error_message`, and all context IDs (`request_id`, `user_id`) available in scope.
4. When calling an external service, log before (at DEBUG) and after (ERROR on failure with `duration_ms`, INFO/DEBUG on success with `duration_ms`).
5. When a function receives a `context.Context` (Go) or request object (Node), extract the logger from it. NEVER create a new bare logger inside a handler.
6. NEVER log any variable whose name exactly matches or ends with: `password`, `secret`, `token`, `api_key`, `private_key`,
`secret_key`, `access_key`, `authorization`, `cookie`, `ssn`, `credit_card`, `card_number`.
When in doubt, omit the field rather than risk leaking sensitive data.
7. When adding retry logic, log each retry at WARN with `attempt_number` and `max_retries`.
8. When choosing a log level, ask: "Will someone be paged?" → ERROR. "Degradation?" → WARN. "Normal operation?" → INFO. "Only useful debugging?" → DEBUG.

### Go Patterns

- **Use `log/slog` (Go 1.21+) as the default.** Use `slog.NewJSONHandler` for production, `slog.NewTextHandler` for local development.
- **Propagate loggers via `context.Context`.** Use `slog.InfoContext(ctx, ...)` so OpenTelemetry bridges can extract trace/span IDs.
- **Never use the global `log` package** from the standard library. Always use `slog` or a structured alternative.
- **In tests, use `slog.New(slog.NewTextHandler(io.Discard, nil))` to suppress log output.**
- **Log at the point of handling, not at every intermediate layer.** Wrap errors with `fmt.Errorf("operation: %w", err)` and log once at the top-level handler.

### TypeScript / Node Patterns

- **Use `pino` as the default structured logger.**
- **Use `logger.child({...})` to create request-scoped loggers.** Never add fields to the root logger at runtime.
- **In Express/Fastify, attach the child logger to the request object in middleware.** All downstream code uses `req.log`.
- **Never use `console.log`, `console.error`, or `console.warn` in application code.** `console.*` is acceptable only in CLI tools and build scripts.
- **When logging errors, pass the Error object in a field:** `logger.error({ msg: "payment failed", err })`.

---

## CQRS — Command Query Responsibility Segregation

CQRS separates read and write models to allow independent optimization of each. These rules define when and how to apply CQRS across the organization.
CQRS is a **per-use-case decision**, not an architectural mandate — some operations within a service may use CQRS while others use standard CRUD.

**CQRS is not Event Sourcing.** CQRS only requires separate read and write models. Event Sourcing (persisting state as a sequence of events
rather than current state) is an orthogonal pattern that pairs well with CQRS but is NOT required. Do not conflate them.
Apply Event Sourcing only when there is an explicit requirement for full audit trails, temporal queries, or event replay — not as a default.

### When to Apply

- **Use CQRS** when read and write workloads have significantly different scaling, performance, or modeling requirements.
- **Use CQRS** when the domain has complex business rules on the write side but simple, denormalized read requirements.
- **Use CQRS** when multiple read representations (projections) of the same data are needed.
- **Do NOT use CQRS** for simple CRUD domains where read and write models are nearly identical.
- **Do NOT apply CQRS to every bounded context.** Apply it selectively to contexts that benefit from it.

### Separation Rules

- The **write model** (command side) is optimized for enforcing invariants and business rules. It is the source of truth.
- The **read model** (query side) is optimized for query performance. It MAY be denormalized, pre-aggregated, or stored in a different database.
- **Commands MUST NOT return domain data.** They return either nothing (success), an ID of a created resource, or an error.
- **Queries MUST NOT mutate state.** A query handler is side-effect-free with respect to domain state. (Logging, metrics, and cache population are acceptable side effects.)

### Naming Conventions

| Concept | Convention | Examples |
|---------|-----------|----------|
| **Command** | Imperative verb + noun | `PlaceOrder`, `CancelSubscription`, `AssignRole` |
| **Event** | Past-tense verb + noun | `OrderPlaced`, `SubscriptionCancelled`, `RoleAssigned` |
| **Query** | `Get`/`List`/`Search`/`Count` + noun | `GetOrderById`, `ListActiveUsers`, `SearchProducts` |
| **Command handler** | `Handle(cmd)` or `<CommandName>Handler` | `PlaceOrderHandler` |
| **Event handler** | `On<EventName>` or `<EventName>Handler` | `OnOrderPlaced` |
| **Projection** | Noun describing the view | `OrderSummaryProjection`, `UserDashboardView` |

Mixing these conventions (e.g., a command named `OrderPlaced` or an event named `PlaceOrder`) is a design error.

### Command Patterns

- A command MUST be a plain data structure (DTO) with no behavior. It carries the intent and the data needed to fulfill it.
- Every command that creates or mutates state MUST be idempotent, or the system MUST detect and reject duplicates.
Strategies: idempotency key from client, natural idempotency ("set X" not "append X"), or conditional/versioned updates (`expectedVersion`/`ETag`).
- Each command MUST have exactly one handler.
- A command handler's responsibilities are: (1) validate, (2) load aggregate/entity, (3) invoke domain logic, (4) persist changes, (5) publish domain events.
- **One command = one transaction = one aggregate mutation.** Do NOT mutate multiple aggregates in one command handler. Use domain events and sagas for cross-aggregate coordination.
- **Domain logic belongs in the aggregate/entity, not the handler.** If the handler has `if/else` business logic, move it into the domain model.

### Command Validation

- **Structural/syntactic validation** on the command object before it reaches the handler (required fields, format, lengths). This can be middleware.
- **Domain/business validation** inside the aggregate/entity (e.g., "user has sufficient balance"). MUST NOT be in the handler or middleware.
- Return validation errors as typed, structured responses — not exceptions for flow control.

### Query Patterns

- A query MUST be a plain data structure containing only retrieval parameters: filters, pagination, sorting, field selection.
- Query handlers MUST NOT invoke command handlers or emit domain events.
- Query handlers MAY read from a dedicated read database, cache, search index, or materialized view.
- Build projections (materialized views) shaped exactly for the UI/API consumer. One projection per distinct read use case is acceptable.

### Domain Events

- Events MUST be immutable. Once published, an event's schema and data MUST NOT change. To evolve, publish new event types and deprecate old ones.
- Events SHOULD carry enough data for consumers to process them without querying back to the source ("fat" events over "thin" events).
- Every event MUST include: `event_id` (unique), `event_type`, `aggregate_id`, `aggregate_type`, `timestamp`,
`version`/`sequence_number`, `payload`, `metadata` (`correlation_id`, `causation_id`, `user_id`).
The `correlation_id` and `causation_id` in event metadata use the same field names and semantics defined in the Structured Logging section —
propagate them from the request/command context that triggered the event.
- Event handlers (projectors, reactors, sagas) MUST be idempotent. Use `sequence_number` or `event_id` to detect and skip already-processed events.
- **Outbox pattern:** When a command handler writes to the database AND publishes events, use the transactional outbox pattern —
write events to an outbox table in the same transaction as the aggregate, then publish from the outbox asynchronously.
This prevents dual-write problems.

### Eventual Consistency

- Accept that the read model will lag behind the write model. Design UIs to handle this: optimistic updates, "your change is being processed" messaging, polling/subscriptions for completion.
- Define and monitor consistency SLAs — the acceptable lag time between a command and the read model update.
- Do NOT read from the write model after a command as a consistency workaround. This defeats CQRS and creates coupling.

### GraphQL + CQRS Integration

- **Mutations map to commands.** Each mutation field corresponds to a single command. The mutation name matches the command name.
- **Queries map to read models.** Each query field reads from the query side. Never route a GraphQL query through a command handler.
- **Subscriptions map to domain events** or projection change streams. Use event-driven push, not database polling.
- Use GraphQL union types or typed error fields for command validation and domain errors. Do NOT rely solely on the `errors` array for business-logic errors.

### Agentic Directives

1. When implementing a new mutation, structure it as: parse input → construct command → dispatch to handler → return ID or error. Do NOT put business logic in the resolver.
2. When implementing a new query, read from the query/projection store. NEVER load aggregates or call domain services from a query resolver.
3. When naming a new command, use imperative form (`CreateMarket`). When naming an event, use past tense (`MarketCreated`). When naming a query, use `Get`/`List`/`Search` prefix (`GetMarketById`).
4. When a command handler needs to affect another aggregate, publish a domain event and handle it in a separate event handler. Do NOT modify two aggregates in the same transaction.
5. When creating an event handler, make it idempotent — check if the event has already been processed before applying side effects.
6. When adding a new read use case with different shape requirements, create a new projection rather than overloading an existing query with conditional logic.
7. When the domain is simple CRUD with no complex invariants or divergent read/write needs, use a standard repository pattern. Do NOT introduce CQRS for basic entity operations.
8. When a command creates a new entity, return only the new entity's ID. Do NOT return the full read model — let the caller issue a separate query.

### Testing CQRS

- **Commands:** Test handlers in isolation with in-memory repositories. Verify correct events are produced, state changes are persisted, and invariants are enforced. Include idempotency tests.
- **Queries:** Test against a pre-populated read store. Seed known data, assert query results.
- **Event handlers:** Feed events and assert side effects. Test idempotency (same event twice = same result). Test ordering if handler depends on sequence.
- **Projections:** Test that a projection can be rebuilt from scratch by replaying all events.
- **Integration:** Send a command, wait for projection update (with polling/timeout, NOT arbitrary sleep), then query and assert.

---

## References

- AGENTS.md convention: <https://agents.md/>
- BMAD Method: <https://github.com/bmad-code-org/BMAD-METHOD>
- Organization: <https://github.com/petry-projects>
