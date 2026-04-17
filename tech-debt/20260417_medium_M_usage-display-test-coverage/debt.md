---
title: Usage display pipeline test coverage and robustness gaps
date: 2026-04-17
criticality: medium
size: M
---

## Problem

The UsageStore test suite and UsagesFileWatcher class have several coverage gaps and robustness issues identified during code review.

### Fragile async synchronization

All 14 async tests in `UsageStoreTests.swift` use a fixed `Task.sleep(50ms)` to wait for the async stream to deliver data. Under CI load, 50ms may not be enough, causing flaky failures. A poll-with-timeout helper (e.g. `await eventually(timeout: 2) { store.menuBarText == expected }`) would be more robust.

### Missing UsageStore tests

- **Countdown refresh**: no test verifies that `countdownTask` updates `menuBarText` without new FileWatcher data (the core purpose of the countdown timer).
- **Error then countdown**: after receiving bad data, a countdown tick should keep the text at `"--"`, not restore stale data.
- **Start/stop/start cycle**: restart lifecycle is untested.
- **Multiple vendor entries**: `format()` uses `.first(where:)` but no test verifies which entry wins when multiple Claude entries exist.
- **Empty metric name**: `name.prefix(1).uppercased()` on `""` produces a leading space in the formatted output.
- **Exactly N hours**: e.g. 2h 0m remaining — should display `"2h"` without minutes.
- **Sub-minute remaining**: 30 seconds → `totalSeconds=30`, `minutes=0` → displays `"0m"`.
- **Unknown metric type**: JSON with an unrecognized `type` field causes full decode failure rather than skipping the unknown metric.
- **Lifecycle tests lack assertions**: the 3 lifecycle tests only verify no crash (no `#expect`). `startIdempotent` should verify data still flows; `stopIdempotent` should verify text is frozen.

### UsagesFileWatcher: zero tests

The production `UsagesFileWatcher` class has no tests at all. Testable behaviors include: initial emit if file exists, no emit if file absent, emit after write (poll fallback), dedup when modDate unchanged, re-open fd when file is replaced.

## Impact

- **Maintainability**: missing edge-case tests make refactoring risky; regressions may go undetected.
- **AI code generation quality**: future agents may copy the `Task.sleep(50ms)` pattern to new tests instead of using a robust helper.
- **Bug/regression risk**: the countdown-after-error scenario could hide a real bug where stale data resurfaces. Unknown metric types causing full decode failure may affect users with newer API responses.

## Affected files / areas

- `Tests/AIUsagesTrackersTests/UsageStoreTests.swift` — all test suites
- `Sources/AIUsagesTrackers/FileWatcher/UsagesFileWatcher.swift` — no test file exists

## Refactoring paths

1. Create an `eventually(timeout:interval:condition:)` async helper that polls a condition with a deadline. Replace all `Task.sleep(50ms)` calls in existing tests.
2. Add the missing UsageStore tests listed above, using the new helper.
3. Create `UsagesFileWatcherTests.swift` with integration tests using temporary files.
4. Add behavioral assertions to the 3 lifecycle tests.

## Acceptance criteria

- [ ] No test uses a fixed `Task.sleep` for synchronization; all use a poll-with-timeout helper
- [ ] Tests exist for: countdown refresh, error-then-countdown, start/stop/start, multiple vendors, empty name, exactly N hours, sub-minute, unknown type
- [ ] Lifecycle tests have behavioral `#expect` assertions
- [ ] `UsagesFileWatcher` has at least 4 integration tests (initial emit, no-file, poll emit, dedup)
- [ ] All tests pass under `swift test`

## Additional context

Identified during review pass on branch `archon/task-feat-menubar-usage-metrics`. Accepted to keep the initial implementation scope focused. The `FileWatching` protocol abstraction is already in place for UsageStore tests; this debt is specifically about testing the concrete `UsagesFileWatcher` and strengthening existing UsageStore tests.
