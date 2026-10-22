#!/usr/bin/env python3
"""Validate a signals.json file against signals.schema.json.

Usage:
    validate-signals.py <signals.json> [<schema.json>]

Exit codes:
    0  valid
    1  invalid (validation error printed to stderr)
    2  usage / file error
"""

from __future__ import annotations

import json
import re
import sys
from datetime import datetime
from pathlib import Path

try:
    from jsonschema import Draft202012Validator, FormatChecker
except ImportError:
    sys.stderr.write(
        "[validate-signals] python jsonschema not installed. "
        "Install with: pip install jsonschema\n"
    )
    sys.exit(2)


def main(argv: list[str]) -> int:
    if len(argv) < 2 or len(argv) > 3:
        sys.stderr.write(
            "usage: validate-signals.py <signals.json> [<schema.json>]\n"
        )
        return 2

    signals_path = Path(argv[1])
    if len(argv) == 3:
        schema_path = Path(argv[2])
    else:
        schema_path = (
            Path(__file__).resolve().parent.parent.parent
            / "schemas"
            / "signals.schema.json"
        )

    if not signals_path.exists():
        sys.stderr.write(f"[validate-signals] not found: {signals_path}\n")
        return 2
    if not schema_path.exists():
        sys.stderr.write(f"[validate-signals] schema not found: {schema_path}\n")
        return 2

    try:
        signals = json.loads(signals_path.read_text(encoding="utf-8"))
    except OSError as exc:
        # File read errors (permissions, I/O) must also exit 2. Caught by
        # CodeRabbit review on PR petry-projects/.github#85.
        sys.stderr.write(f"[validate-signals] cannot read {signals_path}: {exc}\n")
        return 2
    except json.JSONDecodeError as exc:
        # Per the docstring contract, exit 2 means usage / file error and
        # exit 1 means schema validation error. A malformed signals file
        # is a file/data error, not a schema violation. Caught by
        # CodeRabbit review on PR petry-projects/.github#85.
        sys.stderr.write(f"[validate-signals] invalid JSON in {signals_path}: {exc}\n")
        return 2

    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except OSError as exc:
        sys.stderr.write(f"[validate-signals] cannot read schema {schema_path}: {exc}\n")
        return 2
    except json.JSONDecodeError as exc:
        sys.stderr.write(f"[validate-signals] invalid schema JSON: {exc}\n")
        return 2

    # `format` keywords (e.g. "format": "date-time") are not enforced by
    # Draft202012Validator unless an explicit FormatChecker is supplied.
    # The default FormatChecker also does NOT include `date-time` — that
    # requires the optional `rfc3339-validator` dependency. Avoid pulling
    # in extra deps by registering a small inline validator that accepts
    # ISO-8601 / RFC-3339 strings via datetime.fromisoformat (Python 3.11+
    # accepts the trailing `Z`; for older interpreters we substitute it).
    # Caught by Copilot review on PR petry-projects/.github#85.
    format_checker = FormatChecker()

    @format_checker.checks("date-time", raises=(ValueError, TypeError))
    def _check_date_time(instance) -> bool:  # noqa: ANN001 — jsonschema callback signature
        if not isinstance(instance, str):
            return True  # non-strings handled by `type` keyword, not format
        # Must look like a date-time, not just any string. Require at least
        # YYYY-MM-DDTHH:MM[:SS]
        if not re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}", instance):
            raise ValueError(f"not an ISO-8601 date-time: {instance!r}")
        # datetime.fromisoformat in Python <3.11 doesn't accept "Z"; swap it.
        candidate = instance.replace("Z", "+00:00") if instance.endswith("Z") else instance
        datetime.fromisoformat(candidate)
        return True

    validator = Draft202012Validator(schema, format_checker=format_checker)
    errors = sorted(validator.iter_errors(signals), key=lambda e: list(e.absolute_path))
    if not errors:
        print(f"[validate-signals] OK: {signals_path}")
        return 0

    sys.stderr.write(f"[validate-signals] {len(errors)} validation error(s) in {signals_path}:\n")
    for err in errors:
        path = "/".join(str(p) for p in err.absolute_path) or "<root>"
        sys.stderr.write(f"  - {path}: {err.message}\n")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
