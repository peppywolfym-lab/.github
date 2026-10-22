---
description: Go development standards for the Petry Projects organization, based on Effective Go and Google's Go Style Guide
applyTo: "**/*.go"
---

# Go Development Standards

These rules extend the org-level `copilot-instructions.md`. They are based on
[Effective Go](https://go.dev/doc/effective_go),
[Go Code Review Comments](https://go.dev/wiki/CodeReviewComments), and
[Google's Go Style Guide](https://google.github.io/styleguide/go/). Go is used for
infrastructure tools, CLI utilities, and backend services in this org.

## General Principles

- Write simple, clear, and idiomatic Go. Favor clarity over cleverness.
- Keep the happy path left-aligned — return early to reduce nesting.
- Make the zero value useful. Design types so the zero value is a valid, safe starting state.
- Prefer the standard library over third-party packages when equivalent functionality exists.
- Use Go modules (`go.mod` / `go.sum`) for all dependency management.

## Naming Conventions

- Package names: lowercase, single-word, no underscores or hyphens. Singular, not plural.
  Avoid generic names (`util`, `common`, `base`, `helper`).
- Variables and functions: `camelCase`. Exported symbols: `PascalCase`.
- Interfaces: `-er` suffix when describing a single behavior (`Reader`, `Writer`, `Formatter`).
  Keep interfaces small (1–3 methods is ideal).
- **Each Go file must have exactly ONE `package` declaration.** When editing an existing file,
  preserve the existing declaration. When creating a new file, check the package names of
  sibling files first.

## Code Style

- Always format with `gofmt` (or `goimports`). This is non-negotiable.
- Use `goimports` to manage import blocks automatically.
- Write comments in English. Document all exported symbols — start with the symbol name.
  Comment the *why*, not the *what*, unless the logic is complex.
- Avoid emoji in code and comments.

## Error Handling

- Check errors immediately after every function call. Never ignore with `_` without a comment.
- Wrap errors with context: `fmt.Errorf("operation description: %w", err)`.
- Place error returns as the last return value, named `err`.
- Use `errors.Is` / `errors.As` for error checking, not string comparison.
- Log errors at the point of handling — not at every intermediate propagation layer. Add context
  by wrapping, then log once at the top-level handler.
- Error messages: lowercase, no trailing punctuation.

## Project Structure

Follow standard Go project layout:

```text
cmd/           # Application entry points (one directory per binary)
internal/      # Private packages (not importable by external projects)
pkg/           # Reusable packages safe for external import
```

Avoid circular dependencies. Use `internal/` for packages that should not be imported outside
the module. Group related functionality into focused packages.

## Structured Logging

Use **`log/slog`** (Go 1.21+) as the default structured logger:

```go
import (
    "log/slog"
    "os"
)

// Wire up once at program start (e.g., main.go).
// Production — structured JSON for log aggregation:
logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
// Development — swap the handler for human-readable text:
// logger := slog.New(slog.NewTextHandler(os.Stderr, nil))

// Propagate the logger via context so OpenTelemetry can bridge trace/span IDs:
logger.InfoContext(ctx, "order placed", "order_id", orderID, "user_id", userID)
```

- **Never use the global `log` package** from the standard library.
- Propagate loggers via `context.Context`. Use `slog.InfoContext(ctx, ...)` so trace/span IDs
  are automatically bridged.
- In tests, suppress output: `slog.New(slog.NewTextHandler(io.Discard, nil))`.
- Log at the point of handling, not at every layer. Wrap errors with `fmt.Errorf` and log once.
- Never log variables named `password`, `secret`, `token`, `api_key`, `private_key`,
  `authorization`, or `cookie`.

## Concurrency

- Be cautious about creating goroutines in libraries; prefer letting the caller control
  concurrency.
- Always know how a goroutine will exit. Use `sync.WaitGroup` or channels to wait for
  goroutines. Avoid goroutine leaks.
- Use channels for communication between goroutines; use `sync.Mutex` for protecting shared
  state.
- Close channels from the sender side only.
- WaitGroup pattern:
  - Go ≥ 1.25: `sync.WaitGroup` gains a `Go(fn func())` method — use `wg.Go(fn)` directly.
  - Go < 1.25: use the classic `wg.Add(1)` / `defer wg.Done()` pattern.
  - For error propagation across goroutines, prefer `golang.org/x/sync/errgroup` (`eg.Go(fn)`) over bare `sync.WaitGroup`.

## HTTP Clients and I/O

- HTTP client structs hold configuration only (base URL, `*http.Client`, auth, default headers).
  Never store per-request state on the client struct.
- Construct a fresh `*http.Request` per method call. Never cache or reuse a request object.
- Always close response bodies: `defer resp.Body.Close()`.
- `io.Reader` streams are consumable once. To read a body multiple times, use `io.ReadAll` once
  and create fresh readers: `bytes.NewReader(buf)`.
- Set `req.GetBody` for retryable requests so the transport can recreate the body.

## HTTP Server (net/http)

- Go ≥ 1.22: use the enhanced `net/http` `ServeMux` with method + pattern routing.
- Go < 1.22: handle methods manually in handlers or use a justified third-party router.

## Type Safety

- Prefer explicit type conversions. Use `any` (Go 1.18+) instead of `interface{}`.
- Use generics over unconstrained types. Prefer specific type constraints when possible.
- Use type assertions carefully — always check the second return value:
  `v, ok := x.(SomeType); if !ok { ... }`.

## Testing

- Use table-driven tests with `t.Run` subtests.
- Name tests: `Test_FunctionName_Scenario` or `TestFunctionName`.
- Mark helper functions with `t.Helper()`. Use `t.Cleanup()` for teardown.
- Place test files next to source (`service.go` → `service_test.go`).
- White-box tests use the same package; black-box tests use the `_test` package suffix.
- Use `testify/assert` when it adds clarity, but avoid over-complicating simple assertions.

## Security

- Validate all external input at system boundaries.
- Use `crypto/rand` for random number generation. Never use `math/rand` for security-sensitive
  operations.
- Use standard library `crypto` packages — never implement cryptographic algorithms.
- Store passwords with bcrypt, scrypt, or argon2 (`golang.org/x/crypto`).
- Use TLS for all network communication.

## Tooling

- `go fmt` — format code (non-negotiable)
- `go vet` — find suspicious constructs
- `golangci-lint` — extended linting (replaces deprecated `golint`)
- `go test ./...` — run all tests
- `go mod tidy` — clean up unused dependencies

Run `golangci-lint run` before committing. Zero warnings, zero errors.
