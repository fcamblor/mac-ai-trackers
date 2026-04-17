---
title: Minor code style nits in usage display pipeline
date: 2026-04-17
criticality: low
size: XS
---

## Problem

Two minor code style issues remain in the usage display pipeline after review:

1. **UsageStore.swift — unused destructuring binding**: `case let .timeWindow(name, resetAt, _, usagePercent)` silently discards `windowDurationMinutes` with `_`. Not a bug today, but if the enum gains new associated values, the wildcard may mask unhandled data.

2. **UsageStoreTests.swift — `try!` in test helper**: `try! JSONSerialization.data(...)` in `makeUsagesJSON` will crash with no diagnostic message if the JSON construction fails. Using `try` with the test's throwing context (or `XCTUnwrap`) would surface the root cause.

## Impact

- **Maintainability**: minimal — these are cosmetic and only relevant if the enum evolves or the test helper breaks.
- **AI code generation quality**: negligible.
- **Bug/regression risk**: very low.

## Affected files / areas

- `Sources/AIUsagesTrackers/Store/UsageStore.swift` — `formatTimeWindowSegment` method
- `Tests/AIUsagesTrackersTests/UsageStoreTests.swift` — `makeUsagesJSON` helper

## Refactoring paths

1. Replace `_` with a named binding or add a comment explaining why it's intentionally ignored.
2. Replace `try!` with `try` in the throwing test function.

## Acceptance criteria

- [ ] `windowDurationMinutes` is either named or has a comment explaining the discard
- [ ] `makeUsagesJSON` uses `try` instead of `try!`

## Additional context

Identified during review pass on branch `archon/task-feat-menubar-usage-metrics`. Extremely low priority — included for completeness.
