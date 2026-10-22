# AGENTS.md Structural Check — Append-Only Cycle Log

- **Purpose:** the durable, tamper-evident, independently-auditable record of each Standards Sync / compliance-audit
  cycle's AGENTS.md **structural** finding count and every **confirmed false-positive** determination, each attributed
  to a named maintainer. This log — not the editable summary issue — is the source of truth for the
  "two consecutive clean cycles" precondition of the informational → blocking promotion gate.
- **Epic / story:** [#642](https://github.com/petry-projects/.github/issues/642) ·
  [#647 — Phase 4: promotion mechanism](https://github.com/petry-projects/.github/issues/647).
- **Reference doc:** [`agents-md-validation.md`](./agents-md-validation.md) — §4 documents the promotion gate this log feeds.
- **Reader / validator:** [`scripts/agents-md-cycle-log.sh`](../../scripts/agents-md-cycle-log.sh)
  (`validate` and `eligibility` — pure, tested, and it never promotes).

---

## Rules — this file is append-only

1. **Append only. Never edit or delete a recorded row.** Each cycle is a permanent baseline fact. Corrections are made by
   appending a new row **that reuses the same `Cycle` date** as the row it supersedes. The `Cycle` date is the stable
   identity of a cycle: `agents-md-cycle-log.sh`'s `eligibility` function collapses rows by `Cycle` date and counts
   only the **last** row recorded for each date, so a same-date correction supersedes the earlier row and each cycle is
   counted exactly once — a correction never inflates the distinct-cycle count. (Do **not** give a correction a new date;
   that would be counted as a separate cycle.) The `validate` function, by contrast, checks every row individually — a row
   that fails any validation invariant stays permanently invalid even after a well-formed same-date correction is appended,
   so a validation-failing row must itself be corrected or the log remains ineligible. The original stays visible in git
   history, which is what makes the record tamper-evident and independently auditable. Silently editing or removing a past
   row defeats the entire purpose of the gate and will be treated as tampering.
2. **Every determination names a maintainer.** The **Determined by** cell must name the maintainer (GitHub `@handle`) who
   reviewed the cycle and confirmed the false-positive count — including a clean (zero false positives) cycle. A row with
   no named maintainer is invalid; `agents-md-cycle-log.sh validate` fails on it. A "clean cycle" claim may never be
   anonymous.
3. **Finding counts come from the audit summary, not from memory.** The **Structural findings** count is the informational
   AGENTS.md structural-findings count reported by that cycle's compliance-audit summary
   ([`scripts/compliance-audit.sh`](../../scripts/compliance-audit.sh)). Copy it verbatim; do not restate or round it.
4. **Clean? is derived, not asserted.** `Clean?` is `yes` **iff** the confirmed-false-positive count is `0`. The validator
   rejects a row whose flag contradicts its count.
5. **Adding a row is a reviewable PR.** Because the log is committed, appending a cycle is a normal pull request a
   maintainer reviews — the same human gate used for the other codified org policy.

## How a cycle is recorded

After each compliance-audit cycle:

1. Read the **AGENTS.md Structural Findings (informational)** section of that cycle's audit summary issue; note the
   structural finding count.
2. A maintainer reviews the listed structural findings and decides which, if any, are **confirmed false positives**
   (a finding the deterministic linter raised that is not in fact a structural defect).
3. Append one row below with the cycle date, the finding count, the confirmed-false-positive count and details, the
   maintainer's `@handle`, and the derived `Clean?` flag — in a pull request. **Escape any literal `|` in the
   False-positive details cell as `\|`** so it stays inside the cell and does not shift later columns; the reader restores
   the escaped pipe when it parses the row. A nonzero false-positive count must record what was confirmed — an empty (or
   placeholder `—`) details cell fails `validate`.
4. `scripts/agents-md-cycle-log.sh eligibility docs/initiatives/agents-md-validation-cycle-log.md 2` then reports whether the
   clean-cycle precondition is met. Meeting it is **not** a promotion — see the gate in the reference doc.

---

## Cycle records

<!-- APPEND-ONLY: add new cycles at the bottom; never edit or remove a row above. -->

| Cycle | Structural findings | Confirmed false positives | False-positive details | Determined by | Clean? |
|-------|---------------------|---------------------------|------------------------|---------------|--------|

_No cycles recorded yet. The promotion gate's clean-cycle precondition is therefore **not** met, so the structural check
ships and remains **informational**. The first row is appended after the first compliance-audit cycle runs and a
maintainer reviews its structural findings._
