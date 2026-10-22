---
description: Shell script development standards for the Petry Projects organization
applyTo: "**/*.sh,**/*.bash"
---

# Shell Script Development Standards

These rules extend the org-level `copilot-instructions.md`. Shell scripts are used for CI
helper utilities, compliance automation, and infrastructure orchestration.

## Safety Flags

Every shell script MUST begin with:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

- `set -e` — exit immediately on any command failure
- `set -u` — treat unset variables as errors
- `set -o pipefail` — propagate failures through pipelines (not just the last command)

For scripts that intentionally handle errors inline (e.g., checking return codes manually),
disable `set -e` locally within a subshell or use `|| true` with a comment explaining why.

## ShellCheck Compliance

All scripts MUST pass `shellcheck` with zero warnings:

```bash
shellcheck --shell=bash <script>.sh
```

Run ShellCheck before committing. Common issues to fix proactively:

- Unquoted variables — always quote: `"$variable"`, `"${array[@]}"`
- Unsafe `$()` with user-controlled input — validate input first
- Deprecated constructs — use `[[ ... ]]` over `[ ... ]` for bash conditionals

## Quoting and Variable Expansion

- **Always quote variable expansions:** `"$var"`, `"${var}"`, `"${array[@]}"`.
- Use `${var:-default}` for safe defaults. Use `${var:?error message}` to fail fast on required
  variables.
- Use `$( )` for command substitution, not backticks.
- Use `[[ ... ]]` for conditionals (bash built-in, safer than `[ ]`).
- Use `(( ... ))` for arithmetic expressions.

## Function Organization

- Extract reusable logic into functions. Name functions with `snake_case`.
- Declare local variables with `local` inside functions to avoid polluting global scope.
- Functions that produce output should write to stdout. Functions that report errors should write
  to stderr: `echo "Error: message" >&2`.

  ```bash
  log_info()  { echo "[INFO]  $*"; }
  log_error() { echo "[ERROR] $*" >&2; }

  process_item() {
    local item="$1"
    local output_dir="$2"
    # ...
  }
  ```

## Error Handling

- Check return codes for commands that can fail silently (e.g., `curl`, `jq`, `aws`).
- Use `|| { log_error "..."; exit 1; }` patterns to provide descriptive failure messages.
- Use `trap 'cleanup' EXIT` to ensure cleanup runs even on error:

  ```bash
  cleanup() {
    rm -f "$tmp_file"
  }
  trap 'cleanup' EXIT
  ```

## Command Injection Prevention

- Never pass user-controlled input directly to shell commands without validation.
- Use arrays to pass arguments to commands (avoids word-splitting and globbing):

  ```bash
  # Wrong — subject to word splitting:
  run_command "$user_args"

  # Right — use an array:
  args=("--flag" "$user_value")
  run_command "${args[@]}"
  ```

- Avoid `eval` with untrusted input.

## Style and Readability

- Use heredocs for multi-line strings instead of multiple `echo` statements:

  ```bash
  cat <<'EOF'
  Usage: script.sh [options]
    -h, --help    Show this help message
  EOF
  ```

- Keep lines under 100 characters where practical. Use `\` to break long commands.
- Add a one-line comment before each function and non-obvious command explaining *why*, not
  *what*.
- Use `readonly` for constants at the top of the script:

  ```bash
  readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  readonly MAX_RETRIES=3
  ```

## Makefile Standards

- Use `.PHONY` for all non-file targets to prevent conflicts with files of the same name.
- Use `$(MAKE)` recursively, not bare `make`.
- Document each target with a `##` comment on the same line (enables `make help` patterns):

  ```makefile
  .PHONY: test lint

  test: ## Run the full test suite with coverage
  	go test ./... -coverprofile=coverage.out

  lint: ## Run golangci-lint
  	golangci-lint run
  ```

## Testing Shell Scripts

- Test scripts with `bats` (Bash Automated Testing System) where feasible.
- At minimum, test the happy path and common error paths.
- Use `shellcheck` in CI as a required status check for repositories with significant shell
  script surface area.
