# GitHub Advanced Security (GHAS) Standard

How GitHub Advanced Security is **enabled org-wide** across `petry-projects`,
what it costs, and how to **verify it is actually enforcing** (not just toggled
on in the UI).

This standard covers the *enablement and verification* layer. The detailed
secret-scanning enforcement requirements — custom patterns, local hooks, CI
secret-scan job, and incident response — live in
[`push-protection.md`](push-protection.md). The per-repo settings flags live in
[`github-settings.md`](github-settings.md#security--analysis).

---

## Scope

Applies to **every repository** in `petry-projects`, current and future,
regardless of visibility. The org is on the **GitHub Free plan** and all repos
are currently **public**, so GHAS features are free here (see
[Licensing & billing](#licensing--billing)).

---

## Enablement Mechanism — Code Security Configurations

GHAS is enabled org-wide through a **Code Security Configuration**, *not* by
toggling the legacy per-repo `security_and_analysis` flags one repo at a time
and *not* via the deprecated `POST /orgs/{org}/{security_product}/{enablement}`
(`enable_all`) endpoint.

The org standard is the built-in **"GitHub recommended"** global configuration,
which enables the full suite. As of this writing it is configuration **id 17**
(`target_type: global`); always resolve the current id by name rather than
hardcoding it:

```bash
# Resolve the "GitHub recommended" configuration id
gh api orgs/petry-projects/code-security/configurations \
  -q '.[] | select(.name=="GitHub recommended") | .id'
```

Two actions make it the org standard:

```bash
CONFIG_ID=$(gh api orgs/petry-projects/code-security/configurations \
  -q '.[] | select(.name=="GitHub recommended") | .id')

# 1. Attach the configuration to ALL existing repositories (async)
gh api --method POST \
  "orgs/petry-projects/code-security/configurations/${CONFIG_ID}/attach" \
  -f scope=all

# 2. Make it the default for ALL new repositories
gh api --method PUT \
  "orgs/petry-projects/code-security/configurations/${CONFIG_ID}/defaults" \
  -f default_for_new_repos=all
```

The `attach` call is **asynchronous** — repos move to `enforced` over the
following seconds/minutes. Confirm with the
[verification steps](#verification--proving-it-actually-works) below; do not
assume completion from a `200`/`{}` response.

---

## What the Configuration Enables

The "GitHub recommended" configuration turns on the full GHAS suite:

| Product | Field in configuration | Standard value |
|---------|------------------------|----------------|
| Code scanning (CodeQL default setup) | `code_scanning_default_setup` | `enabled` |
| Secret scanning | `secret_scanning` | `enabled` |
| Secret scanning push protection | `secret_scanning_push_protection` | `enabled` |
| Secret scanning non-provider patterns | `secret_scanning_non_provider_patterns` | `enabled` |
| Secret scanning validity checks | `secret_scanning_validity_checks` | `enabled` |
| Dependency graph | `dependency_graph` | `enabled` |
| Dependabot alerts | `dependabot_alerts` | `enabled` |
| Private vulnerability reporting | `private_vulnerability_reporting` | `enabled` |
| Enforcement | `enforcement` | `enforced` |

Code scanning default setup auto-detects supported languages per repo
(`actions`, `javascript-typescript`, `python`, `go`, etc.). Repos with no
CodeQL-supported language still receive `actions` scanning.

---

## Licensing & billing

GHAS billing is **visibility-gated**, not plan-gated:

- **Public repos** — every GHAS feature (code scanning, secret scanning, push
  protection, Dependabot) is **free**, including on the Free plan. No seat, no
  purchase, no metering.
- **Private / internal repos** — code scanning and secret scanning require a
  **GitHub Advanced Security** (or standalone **Code Security** / **Secret
  Protection**) license seat active in org/enterprise billing. Without it, the
  repo-level toggle exists but the backend will not activate.

> **Consequence for this org:** because all repos are public, there is no
> billing gate and nothing to purchase. If a **private** repo is ever added,
> GHAS on that repo will require a license seat — that is the one scenario
> where a "toggle is on but nothing happens" symptom is genuinely a billing
> gate rather than propagation lag or an ineligible pattern.

---

## Verification — proving it actually works

A green toggle is not proof. Verify at four levels; the last one is the only
true end-to-end test of push-protection enforcement.

### 1. Configuration attachment status

All repos should report `enforced`:

```bash
gh api orgs/petry-projects/code-security/configurations/${CONFIG_ID}/repositories \
  --paginate -q '.[] | "\(.status)\t\(.repository.name)"'
```

### 2. Per-repo settings flags

```bash
gh api repos/petry-projects/<repo> \
  -q '.security_and_analysis | "secret_scanning=\(.secret_scanning.status) push_protection=\(.secret_scanning_push_protection.status)"'
```

### 3. Backend liveness (secret scanning)

The data-plane alerts endpoint returns `200` when the secret-scanning backend
is **active**, `404` when it is not provisioned, and `403` when it is
license-gated. A `200` proves the product is serving — something a gated or
unpurchased product cannot do:

```bash
gh api -i "repos/petry-projects/<repo>/secret-scanning/alerts?per_page=1" | head -1
```

### 4. Push-protection live-fire test (canary)

The only way to confirm push protection actually **blocks** is to attempt to
push a real-format (but fake) secret on a throwaway branch:

```bash
# Use a PUSH-PROTECTION-ELIGIBLE pattern (see the gotcha below). A fake Stripe
# live key is regex-detected with no checksum, so a random value triggers it.
STRIPE="sk_live_$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c24)"
git checkout -b test/pp-canary
printf 'FAKE test value: stripe_live_key = %s\n' "$STRIPE" > CANARY_DELETE_ME.txt
git add CANARY_DELETE_ME.txt && git commit -m "test: pp canary"
git push -u origin test/pp-canary   # expect: GH013 push protection rejection, exit 1
```

A working configuration rejects the push with `GH013 → GITHUB PUSH PROTECTION →
Push cannot contain secrets`, naming the detected pattern. Because the push is
rejected, **nothing lands** — no remote branch, no alert.

**Cleanup** (always run, regardless of outcome):

```bash
git checkout main && git branch -D test/pp-canary
# If the push was NOT blocked (it landed), delete the remote branch and resolve
# the resulting alert as test data:
git push origin --delete test/pp-canary 2>/dev/null || true
for n in $(gh api "repos/petry-projects/<repo>/secret-scanning/alerts?state=open" -q '.[].number'); do
  gh api --method PATCH "repos/petry-projects/<repo>/secret-scanning/alerts/$n" \
    -f state=resolved -f resolution=used_in_tests
done
```

---

## Critical gotcha — not every detected pattern is push-protection-eligible

GitHub secret scanning detects **far more** pattern types than push protection
will **block**. A pattern can raise an *alert* (detect-only) while never
blocking a push. Testing push protection with a detect-only pattern produces a
**false negative**: the push succeeds and an alert appears, which looks exactly
like "push protection is broken" when it is working perfectly.

Confirmed example in this org: **Google API keys (`google_api_key`)** are
**detect-only — NOT push-protection-eligible**. Canary pushes with a fake
Google API key are *never* blocked and *always* generate an alert. Do not use
Google API keys to test push protection.

Use a pattern with push-protection support **and** no checksum/validation
gating (so a fabricated value is still detected). Verify support in
[GitHub's supported-patterns table](https://docs.github.com/en/code-security/secret-scanning/introduction/supported-secret-scanning-patterns)
(the "Push protection" column). Good fabricable canaries:

| Pattern | Why it works as a fake canary |
|---------|-------------------------------|
| **Stripe live key** (`sk_live_…`) | Push-protection-supported, regex-detected, no checksum — recommended |
| **OpenAI API key** (`sk-…`) | Push-protection-supported, regex-detected, no checksum |
| **AWS key pair** (`AKIA…` + 40-char secret) | Push-protection-supported; supply the *pair*, an access-key id alone may not block |

Avoid for canary testing:

- **GitHub PAT** (`ghp_…`) — push-protection-supported but **checksum-validated**,
  so a random fake is not detected.
- **Google API key**, and any other **detect-only** pattern — alerts but never
  blocks.

---

## Compliance audit checks

The weekly audit MUST confirm, for every repo:

1. The "GitHub recommended" configuration is attached with status `enforced`
   (verification step 1).
2. `secret_scanning` and `secret_scanning_push_protection` are `enabled`
   (verification step 2).
3. The secret-scanning alerts endpoint returns `200` (verification step 3).
4. Code scanning default setup state is `configured`:

   ```bash
   gh api repos/petry-projects/<repo>/code-scanning/default-setup -q '.state'
   ```

A periodic **push-protection live-fire test** (verification step 4) SHOULD be
run after any change to the org configuration, using a push-protection-eligible
canary, to catch enforcement regressions that the settings flags alone cannot
reveal.

---

## Related Standards

- [`push-protection.md`](push-protection.md) — secret-scanning enforcement,
  custom patterns, local hooks, CI secret-scan job, incident response.
- [`github-settings.md`](github-settings.md#security--analysis) — per-repo
  `security_and_analysis` settings and the apply/audit scripts.
- [`dependabot-policy.md`](dependabot-policy.md) — Dependabot configuration and
  auto-merge policy.
