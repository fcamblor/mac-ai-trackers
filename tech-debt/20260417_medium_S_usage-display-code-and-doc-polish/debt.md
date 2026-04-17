---
title: Usage display pipeline code quality, comments, and documentation polish
date: 2026-04-17
criticality: medium
size: S
---

## Problem

Several code quality, comment, and documentation issues were identified during the second review pass of the menubar usage metrics feature. None affect correctness, but they reduce readability, maintainability, and documentation accuracy.

### Code quality

1. **UsageStore.swift — redundant compactMap closure**: `entry.metrics.compactMap { metric -> String? in formatTimeWindowSegment(metric) }` can be simplified to `entry.metrics.compactMap(formatTimeWindowSegment)`.

2. **UsagesFileWatcher.swift — `@unchecked Sendable` possibly unnecessary**: all stored properties are `let` and `Sendable`. The compiler may be able to derive conformance without the `@unchecked` annotation.

3. **UsageStore.swift — strong self capture without deinit cleanup**: `watchTask` and `countdownTask` capture `self` strongly. If `stop()` is never called, the store and its tasks leak. In practice the store is a singleton, but adding a `deinit` that cancels tasks would be defensive.

4. **UsageStoreTests.swift — `referenceDate` computed property recreates an ISO8601DateFormatter on every access**: making it a `static let` would be cleaner.

### Comments

5. **UsageStore.swift — excessive MARK sections**: `// MARK: Published state`, `// MARK: Dependencies`, `// MARK: Tasks`, `// MARK: Init` label single-item or trivially small groups. Remove the ones that don't aid navigation.

6. **UsageStoreTests.swift — WHAT comments**: "Let the async stream deliver" (restates Task.sleep), "No time-window metrics → fallback" (restates the assertion), "second call should be no-op" (restates test name). Remove or rewrite as WHY.

### Documentation

7. **docs/ARCHITECTURE.md — concrete values in Display pipeline section**: the section embeds specific timing values (30s, 60s) and a label format example that will drift from code. Prefer structural descriptions ("configurable polling interval").

8. **roadmap/menubar-usage-metrics.md — no completion note**: the epic is marked `done` in `index.md` but the epic file itself has no update reflecting delivery status or any deviations from original scope.

9. **plan-menubar-usage-metrics.md at repo root**: this implementation plan artifact should be removed or moved to `roadmap/` now that the epic is complete.

### Minor robustness (LOW)

10. **UsagesFileWatcher.swift — pollInterval UInt64 overflow**: `UInt64(pollInterval * 1_000_000_000)` traps for extreme values. The public init accepts any `TimeInterval`.

11. **UsageModelsTests.swift — `unknownTypeThrows` assertion too broad**: asserts `(any Error).self` instead of the specific `DecodingError` kind.

## Impact

- **Maintainability**: excessive MARK sections and WHAT comments add noise; documentation drift confuses contributors.
- **AI code generation quality**: future agents may copy verbose patterns (redundant closures, excessive MARKs).
- **Bug/regression risk**: low — item 10 (overflow) is the only runtime risk, and only for extreme inputs.

## Affected files / areas

- `Sources/AIUsagesTrackers/Store/UsageStore.swift` — compactMap, MARK sections, deinit
- `Sources/AIUsagesTrackers/FileWatcher/UsagesFileWatcher.swift` — @unchecked Sendable, overflow
- `Tests/AIUsagesTrackersTests/UsageStoreTests.swift` — referenceDate, comments
- `docs/ARCHITECTURE.md` — Display pipeline wording
- `roadmap/menubar-usage-metrics.md` — completion status
- `plan-menubar-usage-metrics.md` — stale plan at repo root

## Refactoring paths

1. Simplify `compactMap` to method reference.
2. Test removing `@unchecked Sendable`; keep it if the compiler requires it.
3. Add `deinit { stop() }` to UsageStore.
4. Make `referenceDate` a `static let` in the test suite.
5. Remove or rewrite MARK sections and WHAT comments.
6. Replace concrete values in ARCHITECTURE.md with structural descriptions.
7. Add a "Delivered" note to the epic file; remove or relocate the root-level plan.
8. Clamp pollInterval or use `min()` before the UInt64 cast.
9. Assert specific DecodingError in `unknownTypeThrows`.

## Acceptance criteria

- [ ] `compactMap` uses method reference syntax
- [ ] `@unchecked Sendable` is either justified with a comment or removed
- [ ] `UsageStore.deinit` cancels tasks
- [ ] No WHAT comments remain in test file
- [ ] ARCHITECTURE.md Display pipeline uses structural descriptions only
- [ ] Epic file and root plan are cleaned up
- [ ] All tests pass

## Additional context

Identified during the second review pass on branch `archon/task-feat-menubar-usage-metrics`. Deferred to keep the review cycle focused on correctness fixes (race condition, fd leak, log throttling).
