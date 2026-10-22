# .gitignore Standard

**Status:** Required
**Applies to:** All repos in `petry-projects` org
**Enforced by:** [`compliance-audit.sh`](../scripts/compliance-audit.sh) (`pp_check_gitignore_baseline`, in [`scripts/lib/push-protection.sh`](../scripts/lib/push-protection.sh))

Every repository's `.gitignore` starts from the org-managed **secrets baseline**
maintained in this repo at [`/.gitignore`](../.gitignore). This standard is the
first layer of defense in the [Push Protection Standard](push-protection.md):
it keeps credentials out of the working tree before any of the scanning layers
(GitHub push protection, gitleaks pre-commit, CI gitleaks) ever run.

## Two-Layer Model

A compliant `.gitignore` has exactly two layers, in this order:

| Layer | Name | Ownership | Editable? |
|-------|------|-----------|-----------|
| **L1** | Secrets baseline | Org-managed (this repo) | **No** — copied verbatim |
| **L2** | Ecosystem / OS extension | Per-repo | Yes — freely edited |

### L1 — Secrets baseline (org-managed, verbatim, required)

- The canonical source is [`/.gitignore`](../.gitignore) in this repo. It is
  primarily **secrets-focused** and language-agnostic: the dotenv family, cloud-provider
  credential files, Kubernetes / Helm secrets, SSH/TLS/GPG key material,
  Terraform/IaC state and `*.tfvars`, secret-manager local caches (sops, age,
  vault, doppler, 1password, infisical), database dumps and DB client dotfiles,
  package-registry credential dotfiles (`.npmrc`, `.pypirc`,
  `.cargo/credentials`, etc.), cloud CLI session caches, IDE files known to
  cache credentials (JetBrains `workspace.xml`, VS Code `sftp.json`, Cursor
  `mcp.json`), and modern AI/LLM tooling config files. It also includes
  standard agent worktrees and CI tool artifacts per organization coding policy.
- Every repo MUST copy this block **verbatim**. Do not edit, re-order, or
  remove entries inside it. Changes to the baseline are made **only** in this
  repo and propagated to child repos.

### L2 — Ecosystem / OS extension (per-repo, appended below the block)

- The baseline covers **secrets and standard agent/CI paths**. Each repo MUST append its own
  language-, framework-, and OS-specific entries (`node_modules/`, `target/`,
  `__pycache__/`, `.DS_Store`, etc.).
- Source these from the matching template at
  [github/gitignore](https://github.com/github/gitignore).
- L2 entries live **below the END marker** (see [Managed-block markers](#managed-block-markers))
  and are free to edit without coordination.

## Managed-block markers

So the L1 block can be identified mechanically (for drift detection and
automated updates), it is wrapped in canonical markers in `/.gitignore`:

```gitignore
# >>> BEGIN petry-projects secrets baseline (managed by .github — do not edit) >>>
... the secrets baseline ...
# <<< END petry-projects secrets baseline <<<
```

- Everything **between** the markers is the L1 block — org-managed, byte-for-byte
  identical across repos.
- Everything **below** the END marker is L2 — per-repo, freely edited.
- Nothing goes **above** the BEGIN marker.

## Negation discipline

Several baseline patterns include `!` negations that re-allow legitimate files
(e.g. `!.env.example`, `!*.crt`, `!*.pub`, `!*.enc.yaml`). These rules MUST be
preserved:

- **Keep negations immediately after the broad pattern they carve out of.**
  Git evaluates rules top-to-bottom; a later ignore can re-hide a
  previously-negated file.
- **L2 additions MUST NOT re-ignore a file the L1 block negates.** If a repo
  re-adds a broad pattern in L2 (e.g. `*.pem`), it silently re-hides files the
  baseline intentionally re-allowed.
- **Always negate by specific file path, never by directory.** A negation
  inside an already-ignored directory does **not** re-include the file. To keep
  a single fixture, negate the exact file (`!test/fixtures/dev-cert.pem`), not
  its parent directory.

## Compliance check

The weekly audit ([`compliance-audit.sh`](../scripts/compliance-audit.sh), via
`pp_check_gitignore_baseline` in
[`scripts/lib/push-protection.sh`](../scripts/lib/push-protection.sh)) locates
the [managed-block markers](#managed-block-markers) in a repo's `.gitignore`
and compares the L1 span — by SHA-256 content hash (trailing-newline tolerant)
— against the canonical block in this repo's [`/.gitignore`](../.gitignore).
Everything **below** the END marker is never inspected, so per-repo L2
extensions can never trip the check. The finding is reported at **`error`**
(blocking) severity, as `gitignore_baseline`, in three cases:

- **no `.gitignore`** at the repo root,
- **baseline block missing** (the BEGIN … END markers are absent), or
- **baseline block drifted** (the span was edited — hash mismatch).

Repos that copy the L1 block verbatim, markers included, pass automatically.

## Application to a repository

1. Copy the L1 block from [`/.gitignore`](../.gitignore) verbatim, **including
   the BEGIN/END markers**, to the top of the repo's `.gitignore`.
2. Append L2 entries below the END marker, using the matching
   [github/gitignore](https://github.com/github/gitignore) template.
3. Do not edit inside the markers and do not re-ignore any negated path.

## Related standards

- [`push-protection.md`](push-protection.md) — the secret-prevention program
  this baseline is the first layer of.
