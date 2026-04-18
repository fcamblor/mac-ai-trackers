---
description: Swift production quality rules — load when writing or modifying Swift source files
globs: ["**/*.swift", "**/Package.swift"]
---

# Swift production quality

Before writing or modifying any Swift code, load and follow these docs:

- `docs/SWIFT-CONCURRENCY.md` — cooperative thread pool, NSFormatter thread safety, actors, Process timeouts
- `docs/SWIFT-ERROR-HANDLING.md` — no silent `try?`, no success-after-catch, rich error types
- `docs/SWIFT-IO-ROBUSTNESS.md` — atomic writes, flock with timeout, O(n+m) merges
- `docs/SWIFT-TESTABILITY.md` — dependency injection, test coverage, force-unwrap, comments, magic numbers
- `docs/SWIFT-VALUE-OBJECTS.md` — value objects for domain fields, struct vs enum, ExpressibleByXxx, Codable

## Non-negotiable rules

1. **Never block the cooperative thread pool** — no `Process.waitUntilExit()`, `readDataToEndOfFile()`, or `queue.sync` from an `async`/`actor` context without a background dispatch.

2. **Never use `try?` on operations whose failure affects correctness** — `createDirectory`, `write`, `flock`, file moves: propagate or handle explicitly with a log.

3. **Every external dependency must be injectable via a protocol** — `URLSession`, Keychain, `FileManager`, `Process`, clock. No direct calls to system APIs in business logic.

4. **Every public method must have at least one test** — especially network, I/O, lifecycle (start/stop idempotence), and all error paths.

5. **Always write files atomically** — use `Data.write(to:options: .atomic)` or write to a temp file then `replaceItemAt(_:withItemAt:)`. Never `removeItem` + `moveItem`.

6. **Error enums must carry associated values** with diagnostic context (status code, underlying error, path, etc.).

7. **Comment WHY, not WHAT** — no restating code in plain English. Extract magic numbers as named constants.

8. **Wrap domain primitives in value objects** — never use raw `String` or `Int` for fields with a distinct identity (emails, vendor names, ISO dates, percentages, durations). See `docs/SWIFT-VALUE-OBJECTS.md` for the pattern.

## Automated check via SwiftLint

`AIUsagesTrackers/.swiftlint.yml` declares six custom rules enforced by
SwiftLint, wired as a SwiftPM build tool plugin on every target. The rules
run on every `swift build` (and inside Xcode). Findings surface with these
codes — resolve errors before committing and avoid reintroducing warnings.

| Code | Severity | Pattern | Rule source |
|------|----------|---------|-------------|
| E1   | error    | `try?` on `createDirectory` / `moveItem` / `copyItem` / `setAttributes` | SWIFT-ERROR-HANDLING §1 |
| E2   | error    | `flock(..., LOCK_EX)` in production code without `LOCK_NB` | SWIFT-CONCURRENCY + SWIFT-IO-ROBUSTNESS |
| W1   | warning  | `nonisolated(unsafe)` in production sources | SWIFT-CONCURRENCY |
| W3   | warning  | `Task.sleep(literal)` in tests — prefer an `eventually()` poll-helper | SWIFT-TESTABILITY |
| W4   | warning  | `@unchecked Sendable` without an adjacent justification comment | SWIFT-CONCURRENCY |
| W5   | warning  | Comment embeds a bare `N unit` duration — drift risk after constant extraction | SWIFT-TESTABILITY §Comment WHY |

Violations already present when the rules were introduced are recorded in
`AIUsagesTrackers/.swiftlint.baseline` and do not fail the build; new
violations matching the same rules do. When a finding fires on a file you
did not author, fix it under the same change rather than leaving drift
behind, and regenerate the baseline with:

```
cd AIUsagesTrackers && swift package plugin --allow-writing-to-package-directory swiftlint lint --write-baseline .swiftlint.baseline
```
