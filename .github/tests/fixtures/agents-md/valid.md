# Valid AGENTS.md Fixture

Structurally valid fixture: exactly one H1 (first heading), no skipped heading
levels, resolvable cross-references, all recommended sections present, and
balanced code fences. See [the standards](#development-standards) and the
sibling [CLAUDE.md](./CLAUDE.md).

## Development Standards

Points at the org development standards.

### Sub-detail

A deeper heading that descends by exactly one level (H2 -> H3), so the
hierarchy is valid.

## Security

Secrets-handling section. Never commit secrets.

## Testing

Test-driven development section.

```bash
# This '#' is inside a fenced code block and must NOT be read as an H1 heading.
echo "hello"
```
