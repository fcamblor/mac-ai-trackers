---
title: Minor code style nits in usage display pipeline
date: 2026-04-18
---

## Drift from original debt description

No drift. Both issues are exactly as described:
- `UsageStore.swift` line 132 still uses `_` to discard `windowDuration`.
- `UsageStoreTests.swift` line 46 still uses `try!` in `makeUsagesJSON`.

The enum label for the discarded binding has been identified as `windowDuration` (type `DurationMinutes`).

## Overall approach

Two independent one-line fixes in two files. Fix 1 names the discarded binding with a leading underscore (`_windowDuration`) so the association to the enum label is preserved for future maintainers. Fix 2 makes `makeUsagesJSON` a throwing function and propagates the error to callers, which are already in `async throws` test functions.

## Phases and commits

### Phase 1: Name the discarded binding in UsageStore

**Goal**: Replace the silent `_` wildcard with `_windowDuration` so the discarded label is visible.

#### Commit 1 — `fix(store): name discarded windowDuration binding in formatTimeWindowSegment`
- Files: `AIUsagesTrackers/Sources/AIUsagesTrackers/Store/UsageStore.swift`
- Changes: On line 132, change `guard case let .timeWindow(name, resetAt, _, usagePercent) = metric else {` to `guard case let .timeWindow(name, resetAt, _windowDuration, usagePercent) = metric else {`. No other change.
- Risk: None — purely cosmetic rename of a local binding that was already unused.

### Phase 2: Remove try! from test helper

**Goal**: Replace `try!` with `try` in `makeUsagesJSON`, surfacing serialization errors with a proper diagnostic instead of a crash.

#### Commit 2 — `fix(tests): replace try! with try in makeUsagesJSON helper`
- Files: `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsageStoreTests.swift`
- Changes:
  1. Change the function signature from `private func makeUsagesJSON(...) -> Data` to `private func makeUsagesJSON(...) throws -> Data`.
  2. Change line 46 from `return try! JSONSerialization.data(withJSONObject: root)` to `return try JSONSerialization.data(withJSONObject: root)`.
  3. Update every call site from `let data = makeUsagesJSON(...)` to `let data = try makeUsagesJSON(...)`. All call sites are inside `async throws` test functions, so no further signature changes are needed.
- Risk: Low. All callers are in throwing contexts. If `JSONSerialization` ever fails (malformed object graph), the test now fails with a thrown error rather than an uninformative crash.

## Validation

- Build the package: `cd AIUsagesTrackers && swift build`
- Run all tests: `swift test`
- Confirm no `try!` remains in `UsageStoreTests.swift`: `grep -n "try!" Tests/AIUsagesTrackersTests/UsageStoreTests.swift` should return nothing.
- Confirm no bare `_` in the timeWindow pattern: `grep -n ", _, " Sources/AIUsagesTrackers/Store/UsageStore.swift` should return nothing.
