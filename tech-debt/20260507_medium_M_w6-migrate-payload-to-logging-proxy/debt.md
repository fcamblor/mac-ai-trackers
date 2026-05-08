---
title: Migrate connector payload logs from maskedPayload to LoggingProxy
date: 2026-05-07
criticality: medium
size: M
---

## Problem

The three existing connectors (`ClaudeCodeConnector`, `CodexConnector`,
`CopilotConnector`) log API payloads with a private `maskedPayload()`
static method and call `logger.log(.debug, "API payload: ...")` directly
— bypassing the `LoggingProxy` abstraction introduced by the vendor plugin
framework. W6 (the SwiftLint rule that enforces proxy-first logging) fires
as a warning on 6 call sites across the three connectors. Because W6 was
intentionally set to `warning` rather than `error` to allow gradual
migration, the build stays green but the violation persists silently.

Concretely, three private `maskedPayload` methods remain:

- `ClaudeCodeConnector.maskedPayload(_:)` — duplicates `JSONFieldSanitizer`
- `CodexConnector.maskedPayload(_:)` — same
- `CopilotConnector.maskedPayload(_:)` — same

These local implementations share the same field-key heuristic but are
already superseded by the per-vendor `PayloadSanitizer` implementations
that were added alongside `LoggingProxy`.

## Impact

- **Maintainability**: duplicate sanitization logic in three places; when
  the sanitized-fields list in `docs/vendors/<vendor>.md` changes, both the
  `*PayloadSanitizer` and the private method must be updated.
- **AI code generation quality**: new agents working in a connector see
  `logger.log(.debug, "...payload...")` as the accepted pattern and copy it
  rather than using `LoggingProxy.logPayload(...)`.
- **Bug/regression risk**: low today because `maskedPayload` covers the same
  keys; medium once the `docs/vendors/<vendor>.md` sanitized-fields lists
  diverge from the heuristic (field renamed or added upstream).

## Affected files / areas

- `AIUsagesTrackers/Sources/AIUsagesTrackers/Connectors/ClaudeCodeConnector.swift` — lines 122, 144, 195: `logger.log(.debug, ...)` + private `maskedPayload`
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Connectors/CodexConnector.swift` — lines 113, 142: `logger.log(.debug, ...)` + private `maskedPayload`
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Connectors/CopilotConnector.swift` — lines 103, 119: `logger.log(.debug, ...)` + private `maskedPayload`
- `AIUsagesTrackers/.swiftlint.yml` — W6 rule; bump to `error` severity once all sites are fixed

## Refactoring paths

1. Add a `loggingProxy: LoggingProxy` parameter to each connector's `init`,
   defaulting to a proxy built from the connector's existing `logger` and
   the vendor's sanitizer (e.g. `LoggingProxy(logger: logger, sanitizer:
   ClaudePayloadSanitizer())`).
2. Replace each `logger.log(.debug, "API payload: \(Self.maskedPayload(data))")` 
   with `loggingProxy.logPayload(.debug, "API payload", payload: data)`.
3. Replace each `logger.log(.warning, "Failed payload dump: \(Self.maskedPayload(data))")` 
   with `loggingProxy.logPayload(.warning, "Failed payload dump", payload: data)`.
4. Delete the three private `maskedPayload(_:)` and `maskSensitiveFields(_:)`
   static methods — their behaviour is fully covered by the injected sanitizer.
5. Update the connector tests to pass a mock `LoggingProxy` (or verify the
   log file content using the existing `FileLogger` test patterns).
6. Bump W6 severity in `.swiftlint.yml` from `warning` to `error` and
   verify `swift build` is clean.

## Acceptance criteria

- [ ] No `maskedPayload` static method exists in any `*Connector.swift`.
- [ ] No `logger.log(.*payload)` call site fires W6.
- [ ] W6 severity is `error` in `.swiftlint.yml`.
- [ ] `swift test` passes with the same or higher test count.
- [ ] Leakage tests for all three vendors still pass (they exercise the
  sanitizer, not the maskedPayload path).

## Additional context

Introduced in the vendor-plugin-framework epic (steps 2–4). The W6 rule
was deliberately left as `warning` to unblock shipping the framework
without needing a full connector refactor in the same PR. The `LoggingProxy`
and per-vendor sanitizers are already in place and ready to receive the
migrated call sites.
