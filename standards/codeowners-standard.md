# CODEOWNERS Standard

**Status:** Required
**Applies to:** All repos in `petry-projects` org
**Enforced by:** [`compliance-audit.sh`](../scripts/compliance-audit.sh) (`check_codeowners`)
**Migration completed:** 2026-05-04

## Rule

Every owner line in a CODEOWNERS file MUST follow these rules:

1. **`@petry-projects/org-leads` MUST be the FIRST owner** on every owner line
   (so it always satisfies `require_code_owner_review`, regardless of
   path-specific overrides).
2. **Additional teams are allowed** as subsequent owners when finer-grained
   ownership is desired (e.g., `@petry-projects/security-leads` for
   `/SECURITY.md`).
3. **Individual named users are forbidden** as owners. All owners MUST be
   teams in the form `@petry-projects/<team-slug>`. Manage individual
   membership through team membership instead.

```text
# Default — only org-leads
* @petry-projects/org-leads

# Path-specific — org-leads first, then additional team(s)
/security/      @petry-projects/org-leads @petry-projects/security-leads
/.github/       @petry-projects/org-leads @petry-projects/platform-leads
```

The legacy direct-listing pattern is **forbidden**:

```text
# DO NOT USE — individuals and bot accounts as owners
* @don-petry @dependabot-automerge-petry
```

## Why

- **Stable CODEOWNERS files** — adding/removing an owner is a team membership
  change, not a multi-repo PR
- **CODEOWNERS support for automation** — GitHub Apps **cannot** be listed in
  CODEOWNERS (platform limitation,
  [community discussion #23064](https://github.com/orgs/community/discussions/23064)).
  A machine user in the team **can** satisfy `require_code_owner_review`.
- **Centralized control** — team membership is managed in one place via the
  org admin UI; no PR churn when membership changes

## Team Composition

The [`@petry-projects/org-leads`](https://github.com/orgs/petry-projects/teams/org-leads)
team contains:

- `@don-petry` — primary maintainer (team maintainer)
- `@donpetry-bot` — automation machine user

Add additional human maintainers as needed. Bots/apps that need code-owner
standing MUST be machine-user accounts added to this team, not GitHub Apps.

## Required Setup for New Bots

When adding a new bot/automation account to the team:

1. Create a GitHub user account (machine user) — not a GitHub App
2. Add the account to the `@petry-projects/org-leads` team
3. Generate a **fine-grained PAT** with **Resource owner = `petry-projects`**
   - Resource owner MUST be the org. A PAT scoped to the bot's personal
     namespace will show "no access to any repositories" even if the bot is
     in the org.
   - Required permissions: Contents (read), Pull requests (read+write),
     Commit statuses (read), Checks (read), Metadata (read), Members (read)
4. If the org has a fine-grained PAT approval policy, an org admin must
   approve the request at
   [Settings → Personal access tokens](https://github.com/organizations/petry-projects/settings/personal-access-token-requests)
5. Store the PAT as a repo or org secret for use by GitHub Actions

## Branch Protection

Repos that require code owner review must set `require_code_owner_review: true`
on protected branches. Approvals from any member of `@petry-projects/org-leads`
will satisfy the requirement.

> **CODEOWNERS approval timing:** GitHub does not retroactively re-evaluate
> existing reviews if CODEOWNERS changes. After a CODEOWNERS edit, the next
> approval (or a re-request) is what counts.

## Verified End-to-End

The standard was validated on 2026-05-04 against
[TalkTerm#159](https://github.com/petry-projects/TalkTerm/pull/159) — a PR
in a repo with `require_code_owner_review: true`. After:

1. Migrating CODEOWNERS to `* @petry-projects/org-leads`
2. Issuing the bot a `petry-projects`-scoped fine-grained PAT
3. Adding `@donpetry-bot` to the team

`@donpetry-bot` posted an approval that flipped `reviewDecision` from
`REVIEW_REQUIRED` to `APPROVED`, confirming code-owner satisfaction via
team membership.

## Migration History

| Date | Change |
|------|--------|
| 2026-05-04 | Initial team-based standard adopted; all 6 child repos migrated (ContentTwin#128, TalkTerm#160, broodly#172, google-app-scripts#252, markets#153, bmad-bgreat-suite#133) |
