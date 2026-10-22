---
description: Python development standards for the Petry Projects organization
applyTo: "**/*.py"
---

# Python Development Standards

These rules extend the org-level `copilot-instructions.md` and apply to Python files. Python
is used primarily for CI scripts, Google Apps Script companion tooling, and automation utilities.

## Code Style and Formatting

- **Formatter:** `black` (line length 88) or `ruff format`. Run before committing.
- **Linter:** `ruff` (preferred) or `flake8`. Zero errors, zero warnings.
- **Import sorting:** `isort` (or `ruff`'s `I` rule). Standard library → third-party →
  local imports, separated by blank lines.
- Follow **PEP 8** for naming:
  - `snake_case` for variables, functions, and module names
  - `PascalCase` for classes
  - `SCREAMING_SNAKE_CASE` for module-level constants
  - `_private` prefix for internal functions not part of the public API

## Type Annotations

Type annotations are **required** on all function signatures and class attributes in new code.
Use `from __future__ import annotations` for forward references in Python < 3.10.

```python
from __future__ import annotations

def process_order(order_id: str, amount: float) -> dict[str, str]:
    ...
```

Use `mypy` or `pyright` for static type checking. Target `strict` mode where feasible.

- Use `|` union syntax (Python 3.10+) or `Optional[X]` / `Union[X, Y]` for older versions.
- Use `TypedDict` for structured dictionary shapes, not plain `dict[str, Any]`.
- Avoid `Any` unless bridging untyped third-party code — document why.

## Error Handling

- Be explicit. Catch specific exception types, not bare `except:` or `except Exception:`.
- Never swallow exceptions silently. At minimum, log with context before re-raising or returning
  a typed error result.
- Use custom exception classes for domain-level errors:

  ```python
  class OrderNotFoundError(Exception):
      def __init__(self, order_id: str) -> None:
          super().__init__(f"Order not found: {order_id}")
          self.order_id = order_id
  ```

- Use `contextlib.suppress` only for truly ignorable errors (e.g., `FileNotFoundError` on
  optional cleanup).

## Structured Logging

Never use `print()` in application or library code. Use the standard `logging` module with
structured context, or a third-party library that emits JSON (`structlog`, `python-json-logger`):

```python
import logging
logger = logging.getLogger(__name__)

# Wrong:
print(f"Processing order {order_id}")

# Right:
logger.info("processing order", extra={"order_id": order_id})
```

Configure the root logger once at the application entry point. Library code uses
`logging.getLogger(__name__)` only — never configures handlers or formatters.

## Testing (pytest)

- Use **pytest** as the test runner. Tests live in a `tests/` directory mirroring the source
  structure, or co-located with source files.
- Use `pytest.mark.parametrize` for table-driven tests instead of loops.
- Use fixtures (`@pytest.fixture`) for shared setup and teardown. Prefer function-scoped
  fixtures; escalate to `session` scope only for expensive shared resources.
- Name tests descriptively: `test_submitting_valid_order_creates_confirmed_record`.
- Never use `unittest.TestCase` in new code unless integrating with a legacy suite.
- Coverage thresholds are defined per-repo. Google Apps Script repos require 100% line coverage.

## Google Apps Script Companion Code

Python used alongside Google Apps Script MUST:

- Extract all business logic into pure, testable Python functions. GAS-specific I/O is tested
  via mocks; business logic is tested directly.
- Use `pre-commit` hooks (`pre-commit/pre-commit-hooks`, `ruff`, `black`, `mypy`).
- Export coverage in `lcov` format for SonarCloud when configured.

## Security

- Never hardcode credentials, API keys, or secrets. Read them from environment variables or a
  secret manager.
- Validate and sanitize all external input before using it in file paths, SQL, or subprocess
  calls.
- Use `subprocess.run([...], check=True)` with a list (not a shell string) to avoid shell
  injection. Never use `shell=True` with untrusted input.
- Use `secrets` module (not `random`) for generating cryptographic tokens.

## Pre-Commit Configuration

Repos using Python SHOULD include a `.pre-commit-config.yaml` with at minimum:

```yaml
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks:
      - id: check-merge-conflict
      - id: check-yaml
      - id: end-of-file-fixer
      - id: trailing-whitespace
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.4.0
    hooks:
      - id: ruff
      - id: ruff-format
```
