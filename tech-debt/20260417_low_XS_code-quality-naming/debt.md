---
title: Minor code quality and naming issues in connector layer
date: 2026-04-17
criticality: low
size: XS
---

## Problem

Six small code-quality and naming issues remain after the initial implementation:

1. **UsagePoller.swift:31-33** — Polling interval drifts: effective cadence = poll duration + sleep duration, not a fixed interval. Acceptable today but may surprise future maintainers.

2. **UsagesFileManager.swift:46** — `merge()` is `internal` but is a pure implementation detail. It should be `private`; tests can still reach it via `@testable import`.

3. **ClaudeCodeConnector.swift:142** — Keychain timeout is a magic number `10` (seconds). Should be a named constant `keychainTimeoutSeconds` for clarity and configurability.

4. **AIUsagesTrackersApp.swift:12** — Comment explaining `pollerRef` indirection describes a well-known Swift pattern; it adds noise rather than value and should be removed.

5. **UsagesFileManager.swift:64** — `// MARK: - Unsafe (caller holds lock)` — "Unsafe" is misleading: it connotes `UnsafePointer`-style memory unsafety. Rename to `// MARK: - Lock-guarded internals`.

6. **ClaudeCodeConnector.swift:104,111** — Comments `// 5 hours` and `// 7 days` describe WHAT, not WHY. Should explain that these durations match Claude Pro/Max tier rate-limit policy (not returned by the API).

## Impact

- **Maintainability**: Minor friction for future readers; low risk.
- **AI code generation quality**: Magic numbers and WHAT-comments degrade the signal-to-noise ratio for future agent context windows.
- **Bug/regression risk**: Negligible.

## Affected files / areas

- `Sources/AIUsagesTrackersLib/UsagePoller.swift:31-33` — interval drift
- `Sources/AIUsagesTrackersLib/UsagesFileManager.swift:46,64` — visibility + MARK label
- `Sources/AIUsagesTrackersLib/ClaudeCodeConnector.swift:104,111,142` — WHY comments + constant
- `Sources/AIUsagesTrackersApp/AIUsagesTrackersApp.swift:12` — redundant comment

## Refactoring paths

1. `UsagePoller`: document the drift behaviour with a comment, or switch to a `Timer`/`Clock` based approach for fixed cadence.
2. `UsagesFileManager.merge`: change `internal` → `private`.
3. `ClaudeCodeConnector`: extract `private let keychainTimeoutSeconds = 10` constant; update the two WHAT comments to WHY (Claude rate-limit tier policy).
4. `AIUsagesTrackersApp`: remove the `pollerRef` comment.
5. `UsagesFileManager`: rename `MARK` label to `// MARK: - Lock-guarded internals`.

## Acceptance criteria

- [ ] `merge` is `private`; `@testable` tests still compile and pass
- [ ] `keychainTimeoutSeconds` constant exists and is used
- [ ] `MARK` label updated
- [ ] Two WHAT-comments converted to WHY-comments
- [ ] Redundant `pollerRef` comment removed

## Additional context

Identified during the 3rd review pass of fcr-dev run `77047594ea8f699acd4d6dcb2d3bc445` (branch `feat/claude-usages-connector`). Items #9, #10, #11, #12, #13, #14 of that review. Deferred as low-impact cosmetic issues.
