# Security Policy

This policy applies to all repositories in the **petry-projects** organization
(GitHub serves it as the default for any repo without its own `SECURITY.md`).

## Reporting a vulnerability

**Please do not open a public issue for security vulnerabilities.**

Report privately via **GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)**:
open the affected repository → **Security** tab → **Report a vulnerability**.

If private reporting is unavailable on a given repo, email **<donpetry@gmail.com>**
with the details and "SECURITY" in the subject.

Please include, where possible:

- The affected repository and version / commit.
- A description of the issue and its impact.
- Steps to reproduce or a proof of concept.
- Any suggested remediation.

## What to expect

- **Acknowledgement** within 5 business days.
- An assessment and, for confirmed issues, a remediation plan with a target
  timeline proportional to severity.
- Credit in the advisory once a fix is released, if you'd like it.

## Supported versions

These are actively-maintained projects; security fixes are applied to the
**default branch** and the current release line. Older tags are not patched —
please upgrade to the latest release.

## Scope

In scope: code, workflows, and configuration in this organization's repositories.
Out of scope: third-party dependencies (report those upstream), and findings that
require compromised maintainer credentials or physical access.
