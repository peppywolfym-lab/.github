---
description: JavaScript development standards for the Petry Projects organization
applyTo: "**/*.js,**/*.mjs,**/*.cjs"
---

# JavaScript Development Standards

These rules extend the org-level `copilot-instructions.md` and apply to JavaScript files.

> **Prefer TypeScript.** If a file can be migrated to TypeScript without significant disruption,
> prefer the migration. JavaScript is accepted for configuration files (`eslint.config.js`,
> `vite.config.mjs`, `jest.config.js`), build scripts, and legacy code during migration.

## Style and Formatting

- **Formatter:** Prettier. Run `prettier --write` before committing.
- **Linter:** ESLint. Zero warnings, zero errors.
- Never use `var`. Use `const` for all bindings that are not reassigned; use `let` only when
  reassignment is required.
- Prefer `async`/`await` over raw `.then()`/`.catch()` chains. Handle rejections — never leave
  a floating promise.
- Use ES modules (`import`/`export`) in all new code. CommonJS (`require`/`module.exports`) is
  acceptable only in config files that require it.
- Use destructuring assignment to extract values from objects and arrays.

## Naming Conventions

- `camelCase` for variables and functions. `PascalCase` for constructors and classes.
  `SCREAMING_SNAKE_CASE` for module-level constants.
- File names match the primary export or purpose (`orderService.js`, `eslint.config.mjs`).

## Type Safety Without TypeScript

- Use JSDoc annotations (`@param`, `@returns`, `@type`) in JavaScript files that cannot yet be
  migrated, to enable IDE type inference and `checkJs` validation.
- Enable `// @ts-check` at the top of critical JavaScript files to surface type errors in the
  IDE without requiring full TypeScript migration.

## Error Handling

- Always handle Promise rejections — either with `try`/`catch` in `async` functions or with an
  explicit `.catch()` handler.
- Never use empty catch blocks (`catch (e) {}`). At minimum, log the error with structured
  fields.
- Do not use `console.log` in application or library code. Use a structured logger (`pino`).
  `console.*` is acceptable only in CLI scripts and build tooling.

## Testing

- Follow the same TDD rules as TypeScript: write tests before implementing, never `.skip()`.
- Use the same test runner as the rest of the project (Vitest or Jest).
- Name tests as functional requirement specifications.
