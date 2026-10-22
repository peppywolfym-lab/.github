---
description: TypeScript and TSX development standards for the Petry Projects organization
applyTo: "**/*.ts,**/*.tsx"
---

# TypeScript Development Standards

These rules extend the org-level `copilot-instructions.md`. TypeScript is the primary language
across all Petry Projects repositories.

## Compiler Configuration

Always use TypeScript in strict mode. All repositories MUST include these flags (or stricter):

```json
{
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "exactOptionalPropertyTypes": true,
    "noImplicitOverride": true
  }
}
```

Never use `// @ts-ignore` or `// @ts-expect-error` to silence type errors without a documented
reason. Fix the underlying type issue instead.

## Code Style

- **Formatter:** Prettier with `singleQuote: true`, `semi: true`, `trailingComma: "all"`,
  `printWidth: 100`, `tabWidth: 2`. Run `prettier --write` before committing.
- **Linter:** ESLint flat config (`eslint.config.mjs`). Zero warnings, zero errors.
- **Imports:** Use `import type { ... }` for type-only imports. Organize imports: external
  packages first, then internal modules. No circular imports.
- **No barrel files.** Avoid `index.ts` re-export files unless the project explicitly requires
  them — they increase circular dependency risk and slow down bundlers.
- **Naming:** `PascalCase` for types, interfaces, classes, and React components. `camelCase` for
  variables, functions, and methods. `SCREAMING_SNAKE_CASE` for module-level constants.
  File names match the primary export (`UserRepository.ts`, `OrderSummary.tsx`).

## Type Safety

- Prefer `unknown` over `any`. When `any` is unavoidable, add a comment explaining why.
- Use branded types / nominal typing for domain identifiers and value objects:

  ```typescript
  type UserId = string & { readonly __brand: "UserId" };
  type OrderId = string & { readonly __brand: "OrderId" };
  ```

- Use discriminated unions instead of optional fields where possible.
- Avoid type assertions (`as SomeType`) at system boundaries — validate with a type guard or
  schema parser (e.g., Zod) instead.
- Use `readonly` for arrays and object properties that should not be mutated.

## Domain-Driven Design Patterns

- **Ubiquitous language:** Use domain terminology from the bounded context in type names,
  variable names, and method names. Never rename domain concepts to generic terms.
- **Bounded contexts:** Each context lives in its own directory (e.g., `src/orders/`,
  `src/billing/`). Cross-context dependencies use well-defined interfaces or domain events —
  never direct internal imports across context boundaries.
- **Aggregate roots:** External code accesses child entities only through the aggregate root.
  Return domain objects from repositories, not raw database rows.
- **Value objects:** Model domain quantities, identifiers, and domain-specific strings as value
  objects. Validate on construction; throw on invalid input.
- **Repository pattern:** Persistence is abstracted behind repository interfaces the domain
  defines. Infrastructure implements them. Domain code never imports database drivers, ORMs, or
  storage libraries.

## CQRS Naming Conventions

| Concept | Convention | Examples |
|---------|-----------|----------|
| Command | Imperative verb + noun | `PlaceOrder`, `CancelSubscription` |
| Event | Past-tense verb + noun | `OrderPlaced`, `SubscriptionCancelled` |
| Query | `Get` / `List` / `Search` + noun | `GetOrderById`, `ListActiveUsers` |
| Command handler | `Handle(cmd)` or `<Name>Handler` | `PlaceOrderHandler` |
| Projection | Noun describing the view | `OrderSummaryProjection` |

Commands MUST NOT return domain data — return the new entity ID or void. Queries MUST NOT
mutate state.

## Structured Logging

Use **pino** as the default structured logger. Never use `console.log`, `console.error`, or
`console.warn` in application code (`console.*` is acceptable only in CLI tools and build
scripts):

```typescript
import pino from "pino";
const logger = pino();

// In Express/Fastify middleware, attach a child logger per request:
const reqLogger = logger.child({ request_id: req.id, user_id: req.user?.id });

// Log with structured fields, not interpolated strings:
reqLogger.info({ order_id: orderId, amount }, "order placed");
reqLogger.error({ err, order_id: orderId }, "payment failed");
```

Never log variables whose names end in `password`, `secret`, `token`, `api_key`, `cookie`, or
`authorization`.

## React Guidelines

- Use functional components with hooks exclusively. No class components.
- Extract business logic into custom hooks or service functions — keep components presentational.
- Use stable `data-testid` attributes for E2E test selectors; never match on CSS classes, DOM
  hierarchy, or display text.
- Props interfaces use `PascalCase`: `interface ButtonProps { ... }`. Co-locate with the
  component file.
- Do not import React explicitly (JSX transform handles it). Use `React.FC` only if required by
  the project — prefer plain function declarations.

## Error Handling

- Use typed `Result` patterns or typed error unions rather than throwing for recoverable errors
  at domain boundaries.
- Always handle the error case explicitly — never use `.catch(() => {})` silently.
- Fail fast with a clear, descriptive error when an invariant is violated.

## Testing (Vitest / Jest)

- Name tests as functional requirement specifications:
  `it("submitting a valid order creates a confirmed record with correct totals")`.
- Use `describe` blocks to group by feature or class under test.
- Mock only external I/O (databases, HTTP, file system). Never mock domain logic.
- Co-locate unit tests next to source files (`UserRepository.test.ts` beside
  `UserRepository.ts`).
- Mutation testing (Stryker) runs in CI for repos that configure it — write meaningful
  assertions, not trivial coverage padding.

## Electron-Specific (TalkTerm and desktop repos)

- Keep main-process and renderer-process code strictly separated. Never import renderer modules
  in the main process or vice versa.
- Use `contextBridge` for all IPC; never expose `ipcRenderer` directly to renderer code.
- Validate all data crossing the IPC bridge as if it were external user input.
